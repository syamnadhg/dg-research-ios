"""Device identity for the iOS pipeline — a genuine *second* paired device (decision A10).

The problem this solves, stated concretely because the recipe rates it as the finding that
would otherwise dead-end the first queue-triggered e2e: the backend's keystore keys its
credential slots by an ``install_uuid`` stored inside ``~/.super-research``, and its
refresh-token rotation lock lives in the same directory. If the iOS pipeline used that
directory it would either **overwrite the production daemon's device identity** (Appendix E's
``--pair`` does exactly this) or authenticate as the **same ``deviceId``** — putting two
listeners on one ``devices/{deviceId}/queue``, racing a file-based worker-sentinel protocol
the iOS side does not participate in, and attributing every iOS write to the production Mac in
the web app.

What is vendored and what is imported, measured rather than assumed
------------------------------------------------------------------
Of the backend's four ``auth/`` modules, only ``keystore.py`` touches the filesystem (21
references). ``pairing.py``, ``credentials.py`` and ``v2_flow.py`` have **zero** — they are pure
logic, so they are imported, not copied. Copying pure functions would be duplication with no
upside and a drift risk with no alarm.

``keystore.py`` is vendored by :mod:`bin.vendor_auth` into ``_keystore_vendored.py`` with two
lines changed (the state dir and the keyring service). It is *not* reimplemented, because its
behaviour carries details a fresh implementation would plausibly drop — the keyring shadow purge
on write, the retry-OSError-but-not-ValueError file loader, the audit record written *before*
deletion — and a credential store is the wrong place to discover an omission.

``auth/pairing.py`` is loaded **by file path**, deliberately: ``auth/__init__.py`` eagerly
imports ``credentials`` and ``keystore``, so a plain ``import auth.pairing`` would both pull in
``google.auth`` and import the backend's own keystore with its production paths. Loading the one
file means the production keystore is never imported at all, which is a stronger position than
"imported but not called".
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from emubackend import berepo
from emubackend.contract import _keystore_vendored as _ks

__all__ = [
    "DEFAULT_IOS_STATE_DIR",
    "PRODUCTION_STATE_DIR",
    "DeviceIdentity",
    "StateDirRefused",
    "clear_all",
    "configure",
    "cross_process_refresh_lock",
    "current_identity",
    "delete",
    "format_for_display",
    "generate_code",
    "get",
    "install_uuid",
    "normalize_code",
    "pairing_module",
    "promote_pending",
    "set",
    "state_dir",
    "try_recover",
]

# -- the guarded state dir ---------------------------------------------------------------

PRODUCTION_STATE_DIR = _ks.PRODUCTION_STATE_DIR
DEFAULT_IOS_STATE_DIR = _ks.DEFAULT_IOS_STATE_DIR
StateDirRefused = _ks.StateDirRefused

configure = _ks.configure
state_dir = _ks.state_dir

# -- the slot API, verbatim from the vendored keystore -----------------------------------

get = _ks.get
set = _ks.set  # noqa: A001 - deliberately mirrors the upstream dict-ish API
delete = _ks.delete
promote_pending = _ks.promote_pending
try_recover = _ks.try_recover
clear_all = _ks.clear_all
install_uuid = _ks.install_uuid
cross_process_refresh_lock = _ks.cross_process_refresh_lock
SLOTS = _ks.SLOTS
RECOVER_ORDER = _ks.RECOVER_ORDER
SERVICE = _ks.SERVICE

# -- the backend's pure pairing logic, imported ------------------------------------------

_pairing: Any | None = None


def pairing_module():
    """The backend's ``auth/pairing.py``, loaded lazily by file path.

    Lazy so that merely importing this module does not require ``requests`` — the identity
    slots are useful without the pairing helpers, and the import cost belongs to whoever pairs.
    """
    global _pairing
    if _pairing is None:
        _pairing = berepo.import_be_file("auth/pairing.py", alias="be_auth_pairing")
    return _pairing


def generate_code() -> str:
    """An 8-char pair code from the backend's own alphabet.

    ⚠ Present for completeness and for tests only. **In the real pairing flow the SERVER mints
    the code** — ``POST /api/devices/initiate-pair`` allocates it and creates the device doc,
    and client creation of that doc is ``allow create: if false``. A device that generates its
    own code has misunderstood the protocol; the only genuinely device-side pairing logic is
    :func:`format_for_display` and the QR render.
    """
    return pairing_module().generate_code()


def normalize_code(raw: str) -> str | None:
    return pairing_module().normalize_code(raw)


def format_for_display(code: str) -> str:
    """Hyphenate a code for a human to read off a screen. Genuinely device-side."""
    return pairing_module().format_for_display(code)


# -- identity ----------------------------------------------------------------------------


@dataclass(frozen=True)
class DeviceIdentity:
    """Who this pipeline is, from the credential store's point of view."""

    install_id: str
    state_dir: Path
    keyring_service: str
    has_current_token: bool

    def describe(self) -> str:
        return (
            f"install={self.install_id[:8]}… dir={self.state_dir} "
            f"service={self.keyring_service} "
            f"credential={'present' if self.has_current_token else 'ABSENT (not paired)'}"
        )


def current_identity() -> DeviceIdentity:
    """Read the current identity without creating credentials.

    ⚠ Calling this *does* create the state dir and an ``install_uuid`` if absent — that is
    upstream ``install_uuid()`` behaviour, kept deliberately rather than worked around, because
    a second device needs a stable id from its first moment and inventing one per call would
    silently orphan credentials.
    """
    install_id = install_uuid()
    return DeviceIdentity(
        install_id=install_id,
        state_dir=state_dir(),
        keyring_service=SERVICE,
        has_current_token=bool(get("current", install_id)),
    )


def assert_not_production() -> Path:
    """Re-check the guard at the point of use.

    :func:`configure` validates on the way in, but the environment can change between import
    and use (a test fixture, a wrapper script exporting ``DG_IOS_STATE_DIR``), and this is the
    one invariant whose violation is unrecoverable rather than merely wrong: overwriting the
    production daemon's keystore de-authenticates the running product.
    """
    current = state_dir()
    env = os.environ.get("DG_IOS_STATE_DIR")
    if env:
        _ks._check_state_dir(env)
    return _ks._check_state_dir(current)
