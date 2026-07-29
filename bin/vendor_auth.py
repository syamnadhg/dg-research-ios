#!/usr/bin/env python3
"""Vendor the backend's `auth/keystore.py`, parameterising its state dir (decision A10).

Why vendor at all, and why only this one file
--------------------------------------------
Measured: of the backend's four `auth/` modules, `pairing.py`, `credentials.py` and
`v2_flow.py` contain **zero** filesystem or state-dir references — they are pure logic and
genuinely importable, so they are **not** copied. Only `keystore.py` is welded to
``~/.super-research`` (21 references, all reachable from one constant).

Why the iOS pipeline cannot share that directory: the keystore's slots are keyed by an
`install_uuid` stored *inside* it, and its refresh-token rotation lock lives beside it. Sharing
it would either overwrite the production daemon's device identity outright, or make the iOS
pipeline authenticate as the *same* `deviceId` — two listeners on one `devices/{id}/queue`,
racing a file-based worker-sentinel protocol the iOS side does not participate in.

Why a script instead of a hand-typed copy
-----------------------------------------
A credential store is the wrong place for a behavioural divergence, and this one carries
semantics a reimplementation would plausibly drop — the keyring **shadow purge** on write (so
`auth.json` can never serve a stale token after a transient keyring read miss), the
OSError-retry-but-not-ValueError-retry asymmetry in the file loader, the audit record written
*before* deletion so a wipe is always attributable. Copying byte-for-byte and applying a small,
asserted set of substitutions keeps all of that, keeps the diff readable, and records the
upstream hash so drift raises an alarm rather than going unnoticed
(`test_identity.py::test_vendored_keystore_is_not_stale`).

Run from the repo root:  python bin/vendor_auth.py
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import berepo  # noqa: E402

TARGET = REPO / "emubackend" / "contract" / "_keystore_vendored.py"

# Injected ahead of the original constants. Everything the original derives from
# `_FALLBACK_DIR` keeps deriving from it, so exactly one substitution moves the whole store.
_HEADER = '''
# ======================================================================================
# VENDORED-IN PARAMETERISATION (decision A10) — added by bin/vendor_auth.py
# ======================================================================================
import os as _os

#: The production daemon's state dir. Pointing the iOS keystore here is the failure the
#: whole of A10 exists to prevent, so it is refused outright rather than warned about.
PRODUCTION_STATE_DIR = Path.home() / ".super-research"

#: Default state dir for the iOS pipeline's own device identity.
DEFAULT_IOS_STATE_DIR = Path.home() / ".super-research-ios"


class StateDirRefused(RuntimeError):
    """Someone tried to point the iOS keystore at the production state dir."""


def _check_state_dir(path: Path) -> Path:
    path = Path(path).expanduser()
    try:
        same = path.resolve() == PRODUCTION_STATE_DIR.resolve()
    except OSError:
        same = str(path) == str(PRODUCTION_STATE_DIR)
    if same:
        raise StateDirRefused(
            f"refusing to use {path} — that is the production daemon's state dir. Sharing it "
            f"would overwrite its device identity, or make this pipeline authenticate as the "
            f"SAME deviceId and race it on one devices/{{id}}/queue (decision A10). Use a "
            f"separate dir, e.g. {DEFAULT_IOS_STATE_DIR}."
        )
    return path


def _ios_state_dir() -> Path:
    return _check_state_dir(
        Path(_os.environ.get("DG_IOS_STATE_DIR") or DEFAULT_IOS_STATE_DIR)
    )


def _ios_service() -> str:
    """A distinct keyring service name.

    Belt and braces: a distinct state dir already yields a distinct `install_uuid`, and the
    keyring account is `f"{slot}:{install_uuid}"`, so accounts cannot collide. Changing the
    service too means the iOS entries are also *identifiable* in a keychain UI, and a future
    change to how the uuid is derived cannot reintroduce a collision.
    """
    return _os.environ.get("DG_IOS_KEYRING_SERVICE") or "super-research-ios"


def configure(state_dir) -> Path:
    """Repoint this keystore at *state_dir*, rebinding every derived path.

    Present because the paths are module-level constants evaluated at import time, which is
    fine for the backend (one fixed location) but not for a second device whose location is a
    deployment choice — and not for tests, which must never touch a real state dir.
    """
    global _FALLBACK_DIR, _FALLBACK_PATH, _INSTALL_UUID_PATH, _WIPE_LOG, _REFRESH_LOCK_PATH
    _FALLBACK_DIR = _check_state_dir(state_dir)
    _FALLBACK_PATH = _FALLBACK_DIR / "auth.json"
    _INSTALL_UUID_PATH = _FALLBACK_DIR / "install_uuid"
    _WIPE_LOG = _FALLBACK_DIR / "keystore-audit.log"
    _REFRESH_LOCK_PATH = _FALLBACK_DIR / ".refresh.lock"
    return _FALLBACK_DIR


def state_dir() -> Path:
    """The directory currently in use — handy in diagnostics and required by the tests."""
    return _FALLBACK_DIR


# ======================================================================================
'''

# Each substitution must match EXACTLY ONCE, or the upstream file changed shape and a silent
# partial vendor would be worse than a loud failure.
SUBSTITUTIONS = [
    (
        'SERVICE: Final = "super-research"',
        "SERVICE: Final = _ios_service()  # A10: distinct from the backend's",
    ),
    (
        '_FALLBACK_DIR = Path.home() / ".super-research"',
        "_FALLBACK_DIR = _ios_state_dir()  # A10: NOT the production state dir",
    ),
]


def main() -> int:
    source = berepo.be_root() / "auth" / "keystore.py"
    original = source.read_text(encoding="utf-8")
    digest = hashlib.sha256(original.encode()).hexdigest()

    text = original
    for old, new in SUBSTITUTIONS:
        count = text.count(old)
        if count != 1:
            print(
                f"ABORT: expected exactly 1 occurrence of {old!r}, found {count}. "
                f"The upstream keystore changed shape — re-read it before re-vendoring.",
                file=sys.stderr,
            )
            return 1
        text = text.replace(old, new, 1)

    # Inject the parameterisation just above the constants it replaces.
    anchor = "SERVICE: Final = _ios_service()"
    assert text.count(anchor) == 1
    text = text.replace(anchor, _HEADER.strip() + "\n\n" + anchor, 1)

    banner = f'''"""VENDORED from `dg-research-backend/auth/keystore.py` — DO NOT EDIT BY HAND.

Regenerate with ``python bin/vendor_auth.py``. Edits made here are lost on the next run, and
worse, they make the drift check meaningless.

    upstream: auth/keystore.py
    sha256:   {digest}

Only two lines differ from upstream — the keyring SERVICE name and the state dir — plus an
injected parameterisation block. Everything else is byte-identical on purpose: this store's
subtler behaviours (the keyring shadow purge on write, the retry-OSError-but-not-ValueError
file loader, the audit record written before deletion) are exactly what a reimplementation
would drop, and a credential store is the wrong place to find that out.

⚠ A8: this file is a copy living in the iOS repo. The backend is never modified.
"""

'''
    # Replace the original module docstring with the provenance banner, keeping the original
    # text beneath it so the upstream rationale is not lost.
    first_quote = text.index('"""')
    end_quote = text.index('"""', first_quote + 3) + 3
    upstream_doc = text[first_quote:end_quote]
    text = banner + "# --- upstream module docstring, verbatim ---\n" + "\n".join(
        "# " + ln if ln else "#" for ln in upstream_doc.splitlines()
    ) + "\n" + text[end_quote:]

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(text, encoding="utf-8")

    hash_file = TARGET.parent / "_keystore_upstream.sha256"
    hash_file.write_text(digest + "\n", encoding="utf-8")

    print(f"vendored {source} -> {TARGET.relative_to(REPO)}")
    print(f"  upstream sha256: {digest}")
    print(f"  lines: {len(text.splitlines())} (upstream {len(original.splitlines())})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
