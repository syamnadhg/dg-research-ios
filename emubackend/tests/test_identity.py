"""Tests for the vendored keystore and the A10 second-device identity.

The headline assertion is that the iOS keystore **cannot** be pointed at the production
daemon's state dir. Everything else is downstream of that: if the guard fails, the failure mode
is de-authenticating the running product, which is not recoverable by retrying.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
from pathlib import Path

import pytest

from emubackend import berepo
from emubackend.contract import _keystore_vendored as ks
from emubackend.contract import identity

VENDOR_DIR = Path(identity.__file__).resolve().parent


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    """Every test gets its own state dir — never a real one, never the production one."""
    monkeypatch.setenv("DG_IOS_STATE_DIR", str(tmp_path / "sr-ios"))
    identity.configure(tmp_path / "sr-ios")
    yield
    # Leave the module pointing somewhere harmless rather than at the last tmp_path.
    identity.configure(tmp_path / "sr-ios")


# --------------------------------------------------------------------------------------
# the guard — the reason A10 exists
# --------------------------------------------------------------------------------------


def test_the_production_state_dir_is_refused():
    with pytest.raises(identity.StateDirRefused) as exc:
        identity.configure(identity.PRODUCTION_STATE_DIR)
    msg = str(exc.value)
    assert "production daemon" in msg
    assert "same deviceId" in msg.lower() or "SAME deviceId" in msg


def test_the_production_dir_is_refused_via_a_relative_or_symlinked_path(tmp_path):
    """Resolution matters: a `.`-laden path to the same directory must also be refused."""
    sneaky = identity.PRODUCTION_STATE_DIR / ".." / identity.PRODUCTION_STATE_DIR.name
    with pytest.raises(identity.StateDirRefused):
        identity.configure(sneaky)


def test_a_tilde_path_is_expanded_before_the_check():
    with pytest.raises(identity.StateDirRefused):
        identity.configure("~/.super-research")


def test_the_default_is_not_the_production_dir():
    assert identity.DEFAULT_IOS_STATE_DIR != identity.PRODUCTION_STATE_DIR
    assert identity.DEFAULT_IOS_STATE_DIR.name == ".super-research-ios"


def test_assert_not_production_rechecks_the_environment(monkeypatch, tmp_path):
    """The env can change between import and use; the invariant is worth re-checking."""
    identity.configure(tmp_path / "ok")
    assert identity.assert_not_production() == (tmp_path / "ok")
    monkeypatch.setenv("DG_IOS_STATE_DIR", str(identity.PRODUCTION_STATE_DIR))
    with pytest.raises(identity.StateDirRefused):
        identity.assert_not_production()


def test_the_keyring_service_is_distinct_from_the_backends():
    """Defence in depth: distinct dir already gives a distinct uuid, but be explicit."""
    assert identity.SERVICE == "super-research-ios"
    assert identity.SERVICE != "super-research"


# --------------------------------------------------------------------------------------
# the vendor is faithful, and stays faithful
# --------------------------------------------------------------------------------------


def test_vendored_keystore_is_not_stale():
    """Alarm on upstream drift instead of silently running an old copy.

    A vendored file with no drift check is how a vendored layer becomes an unmaintained fork.
    """
    recorded = (VENDOR_DIR / "_keystore_upstream.sha256").read_text().strip()
    upstream = (berepo.be_root() / "auth" / "keystore.py").read_bytes()
    actual = hashlib.sha256(upstream).hexdigest()
    assert actual == recorded, (
        "dg-research-backend/auth/keystore.py has changed since it was vendored.\n"
        f"  recorded: {recorded}\n  actual:   {actual}\n"
        "Re-vendor with `python bin/vendor_auth.py`, then re-read the diff — this file holds "
        "credential-store semantics, so review it rather than rubber-stamping."
    )


def test_the_vendored_copy_differs_from_upstream_only_where_intended():
    upstream = (berepo.be_root() / "auth" / "keystore.py").read_text().splitlines()
    vendored = (VENDOR_DIR / "_keystore_vendored.py").read_text()
    # Every upstream line must still be present, except the two that were substituted.
    substituted = {
        'SERVICE: Final = "super-research"',
        '_FALLBACK_DIR = Path.home() / ".super-research"',
    }
    missing = [
        ln
        for ln in upstream
        if ln.strip()
        and ln not in substituted
        and ln not in vendored
        and not ln.startswith('"""')
    ]
    # The upstream docstring is re-emitted as comments, so allow those lines through.
    missing = [m for m in missing if ("# " + m) not in vendored]
    assert not missing, (
        "the vendored copy is missing upstream lines, so it is a rewrite rather than a "
        f"parameterised copy:\n  " + "\n  ".join(missing[:10])
    )


def test_the_vendored_copy_keeps_the_subtle_behaviours_a_rewrite_would_drop():
    """These three are named in the module docstring as the reason not to reimplement."""
    src = (VENDOR_DIR / "_keystore_vendored.py").read_text()
    assert "shadow" in src, "the keyring shadow purge on write is missing"
    assert "except ValueError:" in src, "the file loader's ValueError/OSError asymmetry is gone"
    assert "_write_wipe_audit(install_id, reason)" in src, "the pre-deletion audit is gone"


def test_only_keystore_was_vendored():
    """pairing/credentials/v2_flow have zero filesystem refs, so copying them is duplication."""
    for name in ("pairing", "credentials", "v2_flow"):
        assert not (VENDOR_DIR / f"_{name}_vendored.py").exists(), (
            f"{name} was vendored, but it has no filesystem references — import it instead"
        )


# --------------------------------------------------------------------------------------
# the slot API still behaves
# --------------------------------------------------------------------------------------


def _file_store_only(monkeypatch):
    """Force the file fallback so the test never writes to the developer's real keychain."""
    monkeypatch.setattr(ks, "_try_keyring", lambda: None)


def test_install_uuid_is_stable_and_lives_in_the_ios_dir(monkeypatch):
    _file_store_only(monkeypatch)
    first = identity.install_uuid()
    assert first and first == identity.install_uuid()
    assert (identity.state_dir() / "install_uuid").exists()
    assert not str(identity.state_dir()).endswith(".super-research")


def test_install_uuid_differs_from_a_different_state_dir(tmp_path, monkeypatch):
    """The whole point: a second dir means a second device, not the same one."""
    _file_store_only(monkeypatch)
    identity.configure(tmp_path / "a")
    a = identity.install_uuid()
    identity.configure(tmp_path / "b")
    b = identity.install_uuid()
    assert a != b


def test_slots_round_trip_and_are_scoped_by_install_id(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    identity.set("current", iid, "tok-1")
    assert identity.get("current", iid) == "tok-1"
    assert identity.get("current", "some-other-install") is None
    identity.delete("current", iid)
    assert identity.get("current", iid) is None


def test_promote_pending_rotates_current_into_previous(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    identity.set("current", iid, "old")
    identity.set("pending", iid, "new")
    identity.promote_pending(iid)
    assert identity.get("current", iid) == "new"
    assert identity.get("previous", iid) == "old"
    assert identity.get("pending", iid) is None


def test_promote_pending_is_a_no_op_without_a_pending_token(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    identity.set("current", iid, "keep")
    identity.promote_pending(iid)
    assert identity.get("current", iid) == "keep"
    assert identity.get("previous", iid) is None


def test_try_recover_probes_in_the_documented_order(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    assert identity.RECOVER_ORDER == ("pending", "current", "previous")
    identity.set("previous", iid, "p")
    assert identity.try_recover(iid) == ("previous", "p")
    identity.set("current", iid, "c")
    assert identity.try_recover(iid) == ("current", "c")
    identity.set("pending", iid, "n")
    assert identity.try_recover(iid) == ("pending", "n")


def test_try_recover_returns_none_when_nothing_is_stored(monkeypatch):
    _file_store_only(monkeypatch)
    assert identity.try_recover(identity.install_uuid()) is None


def test_clear_all_wipes_every_slot_and_writes_an_attributable_audit(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    for slot in identity.SLOTS:
        identity.set(slot, iid, f"tok-{slot}")
    identity.clear_all(iid, reason="unpair")
    for slot in identity.SLOTS:
        assert identity.get(slot, iid) is None
    audit = identity.state_dir() / "keystore-audit.log"
    assert audit.exists(), "a wipe must always be attributable"
    rec = json.loads(audit.read_text().strip().splitlines()[-1])
    assert rec["event"] == "clear_all"
    assert rec["reason"] == "unpair"
    assert rec["install"] == iid[:8]
    assert rec["stack"], "the audit must name the caller"


def test_the_credential_file_is_owner_only(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    identity.set("current", iid, "secret")
    path = identity.state_dir() / "auth.json"
    assert path.exists()
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode & (stat.S_IRGRP | stat.S_IROTH | stat.S_IWGRP | stat.S_IWOTH) == 0, (
        f"auth.json is mode {mode:o}; a credential file must not be group/world readable"
    )


def test_a_corrupt_credential_file_is_treated_as_empty_not_fatal(monkeypatch):
    _file_store_only(monkeypatch)
    iid = identity.install_uuid()
    identity.set("current", iid, "tok")
    (identity.state_dir() / "auth.json").write_text("{not json")
    assert identity.get("current", iid) is None  # degrades to "not signed in", does not raise


def test_the_cross_process_lock_is_acquirable_and_releases(monkeypatch):
    _file_store_only(monkeypatch)
    identity.install_uuid()  # ensures the dir exists
    with identity.cross_process_refresh_lock(timeout=2.0) as locked:
        assert locked is True
    with identity.cross_process_refresh_lock(timeout=2.0) as locked:
        assert locked is True, "the lock was not released by the first block"


# --------------------------------------------------------------------------------------
# the imported (not vendored) pure pairing logic
# --------------------------------------------------------------------------------------


def test_pairing_logic_is_imported_from_the_backend_without_its_package():
    """Loading the file directly means the backend's own keystore is never imported."""
    import sys

    identity.pairing_module()
    assert "auth" not in sys.modules, (
        "importing the auth package would also import the backend's keystore, whose "
        "module-level constants point at the production state dir"
    )


def test_format_for_display_round_trips_through_normalize():
    code = identity.generate_code()
    assert len(code) == 8
    shown = identity.format_for_display(code)
    assert "-" in shown
    assert identity.normalize_code(shown.lower()) == code


def test_the_code_alphabet_excludes_confusable_characters():
    """0/1/I/L/O are excluded upstream so a human reading a screen cannot mistype them."""
    codes = "".join(identity.generate_code() for _ in range(60))
    assert not (set("01ILO") & set(codes))


def test_current_identity_reports_an_unpaired_device_honestly(monkeypatch):
    _file_store_only(monkeypatch)
    ident = identity.current_identity()
    assert ident.has_current_token is False
    assert "ABSENT (not paired)" in ident.describe()
    identity.set("current", ident.install_id, "tok")
    assert identity.current_identity().has_current_token is True
