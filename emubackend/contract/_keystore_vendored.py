"""VENDORED from `dg-research-backend/auth/keystore.py` — DO NOT EDIT BY HAND.

Regenerate with ``python bin/vendor_auth.py``. Edits made here are lost on the next run, and
worse, they make the drift check meaningless.

    upstream: auth/keystore.py
    sha256:   c50726a8474a64966e0efa4e45a4ba80410625f66c5cc978b07f44c8044ca027

Only two lines differ from upstream — the keyring SERVICE name and the state dir — plus an
injected parameterisation block. Everything else is byte-identical on purpose: this store's
subtler behaviours (the keyring shadow purge on write, the retry-OSError-but-not-ValueError
file loader, the audit record written before deletion) are exactly what a reimplementation
would drop, and a credential store is the wrong place to find that out.

⚠ A8: this file is a copy living in the iOS repo. The backend is never modified.
"""

# --- upstream module docstring, verbatim ---
# """OS keystore wrapper with three-slot rotation for refresh-token atomicity.
#
# The slots — `current`, `previous`, `pending` — exist because Windows DPAPI
# (via the `keyring` library) does NOT expose atomic rename. A refresh-token
# rotation is a multi-step sequence (POST to securetoken, persist new value,
# discard old). If the BE process is killed between persisting the new value
# and overwriting the old one, we need to recover without forcing a re-pair.
#
# The slot dance:
# 1. Refresh starts → write new refresh_token to `pending` slot first.
# 2. Then promote: `previous = current`, `current = pending`, clear `pending`.
# 3. On startup self-heal (`try_recover`), try `pending` → `current` → `previous`
#    in that order. The first slot that produces a valid token wins.
#
# If `keyring` is unavailable (headless Linux without secret-service), fall
# back to a chmod-0600 file at `~/.super-research/auth.json` — same three-slot
# shape, atomic via `os.replace`.
# """


from __future__ import annotations

import contextlib
import json
import logging
import os
import stat
import sys
import tempfile
import traceback
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Final, Literal

log = logging.getLogger(__name__)

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

SERVICE: Final = _ios_service()  # A10: distinct from the backend's
Slot = Literal["current", "previous", "pending"]
SLOTS: Final[tuple[Slot, ...]] = ("current", "previous", "pending")
RECOVER_ORDER: Final[tuple[Slot, ...]] = ("pending", "current", "previous")

# File fallback location. Created only if keyring access fails.
_FALLBACK_DIR = _ios_state_dir()  # A10: NOT the production state dir
_FALLBACK_PATH = _FALLBACK_DIR / "auth.json"
_INSTALL_UUID_PATH = _FALLBACK_DIR / "install_uuid"
# Durable, append-only audit of every destructive keystore op. Survives
# os._exit / pythonw (no stdout) / taskkill — written BEFORE deletion so a
# wipe always names its culprit even if the supervisor's console log is lost.
_WIPE_LOG = _FALLBACK_DIR / "keystore-audit.log"
# Cross-process lock file serialising refresh-token rotation across the N
# separate `--serve` worker processes (a per-process threading.Lock can't —
# see auth/credentials.py). Co-located with the keystore it guards.
_REFRESH_LOCK_PATH = _FALLBACK_DIR / ".refresh.lock"


def _write_wipe_audit(install_id: str, reason: str) -> None:
    """Durable, append-only, fsync'd record of every destructive keystore op.

    Written from inside `clear_all` BEFORE any deletion, so a wipe is always
    attributable — even when the calling process is a console-attached
    supervisor whose own log() is lost, a pythonw daemon with no stdout, or a
    worker about to `os._exit`. The traceback names the exact caller (a
    crash-loop wipe vs a genuine-revoke wipe vs an --unpair are otherwise
    indistinguishable post-hoc). Best-effort: never raises, never blocks the
    operation it audits.
    """
    try:
        _FALLBACK_DIR.mkdir(parents=True, exist_ok=True)
        rec = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "event": "clear_all",
            "reason": reason,  # unpair | retire | revoke | crash-loop | ...
            "install": (install_id or "")[:8],
            "pid": os.getpid(),
            "worker_id": os.environ.get("DG_WORKER_ID", os.environ.get("SR_WORKER_ID", "?")),
            "exe": Path(sys.executable).name,  # python.exe vs pythonw.exe
            "argv": " ".join(sys.argv[:6]),
            # Last frames of the call stack → WHO called clear_all and why.
            "stack": [ln.strip() for ln in traceback.format_stack()[-8:-1]],
        }
        with open(_WIPE_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
            fh.flush()
            try:
                os.fsync(fh.fileno())  # survive an immediate os._exit
            except OSError:
                pass
    except Exception:
        pass  # an audit failure must never stop (or crash) the real op


@contextlib.contextmanager
def cross_process_refresh_lock(timeout: float = 15.0):
    """Serialise refresh-token rotation ACROSS the N separate `--serve` worker
    processes. The in-process `threading.Lock` in credentials.py only serialises
    threads within ONE interpreter; N worker processes each get their own and so
    can POST the same `current` refresh token concurrently. This OS-level
    advisory lock (msvcrt.locking on Windows / fcntl.flock on POSIX) closes that
    gap. Best-effort: if the platform lock primitive is unavailable or the wait
    times out, we proceed UNLOCKED rather than block a refresh forever — the
    re-read-before-POST + re-read-before-wipe guards still prevent a spurious
    revoke; the lock is the primary defence, those are the safety net.
    """
    import time as _time

    # --- Acquire (all acquisition errors handled HERE, before the single yield;
    # we must never yield twice — a body exception thrown back into the generator
    # at the yield would otherwise be masked by a second yield). ---
    fh = None
    locked = False
    try:
        _FALLBACK_DIR.mkdir(parents=True, exist_ok=True)
        fh = open(_REFRESH_LOCK_PATH, "a+")
    except Exception:
        fh = None  # can't even create the lock file → degrade to unlocked
    if fh is not None:
        try:
            start = _time.monotonic()
            if sys.platform == "win32":
                import msvcrt
                while True:
                    try:
                        fh.seek(0)
                        msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                        locked = True
                        break
                    except OSError:
                        if _time.monotonic() - start > timeout:
                            break
                        _time.sleep(0.1)
            else:
                import fcntl
                while True:
                    try:
                        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        locked = True
                        break
                    except OSError:
                        if _time.monotonic() - start > timeout:
                            break
                        _time.sleep(0.1)
        except Exception:
            locked = False  # lock primitive unusable → degrade to unlocked

    # --- The ONE yield. The body runs here; its exceptions propagate normally. ---
    try:
        yield locked
    finally:
        if fh is not None:
            try:
                if locked:
                    if sys.platform == "win32":
                        import msvcrt
                        try:
                            fh.seek(0)
                            msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
                        except OSError:
                            pass
                    else:
                        import fcntl
                        try:
                            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
                        except OSError:
                            pass
            finally:
                try:
                    fh.close()
                except OSError:
                    pass


def _keyring_account(slot: Slot, install_uuid: str) -> str:
    return f"{slot}:{install_uuid}"


def _try_keyring() -> "object | None":
    """Lazy import keyring so the module loads even on systems without it.

    Returns the keyring module ONLY when a real secret-store backend is wired.
    `keyring.get_keyring()` never raises on a headless host — it returns the
    `fail.Keyring` sentinel (and `chainer.ChainerBackend` with no usable
    children), whose every get/set/delete THROWS. Treating that sentinel as a
    live backend made every keystore op throw + log a WARNING on file-fallback
    hosts (headless Linux / WSL). Detect the sentinel and fall back to the file
    store cleanly instead. (cross-platform parity)
    """
    try:
        import keyring  # type: ignore[import-not-found]
        from keyring.backends import fail as _fail  # type: ignore[import-not-found]

        kr = keyring.get_keyring()
        if isinstance(kr, _fail.Keyring):
            log.debug("keyring has no real backend (fail.Keyring) — using file fallback")
            return None
        # A ChainerBackend with no usable children is equivalent to no backend.
        children = getattr(kr, "backends", None)
        if children is not None and not list(children):
            log.debug("keyring chainer has no usable backend — using file fallback")
            return None
        return keyring
    except Exception as e:  # pragma: no cover - environment-specific
        log.debug("keyring unavailable, falling back to file (%s)", e)
        return None


def _file_load() -> dict[str, str]:
    if not _FALLBACK_PATH.exists():
        return {}
    import time as _time
    # Retry ONLY transient OS read failures: a sibling worker mid-`os.replace`
    # can briefly make the read hit a Windows sharing violation or catch a
    # half-written file. Without the retry, a transient error would falsely
    # report "not signed in" under multi-worker contention.
    #
    # A ValueError (corrupt/incomplete JSON) on a STABLE file is NOT transient —
    # retrying it just burns ~1.4s of blocking sleeps on the file-fallback hot
    # path (headless Linux) before returning {} anyway. Read once; on persistent
    # ValueError treat as empty immediately. (A torn half-write also raises
    # ValueError, but the OSError-retry loop already re-reads across the
    # os.replace window, so a genuinely mid-write file is caught there.)
    for i in range(8):
        try:
            return json.loads(_FALLBACK_PATH.read_text())
        except ValueError:
            log.warning("auth.json contained invalid JSON, treating as empty")
            return {}
        except OSError:
            if i < 7:
                _time.sleep(0.05 * (i + 1))
                continue
            log.warning("auth.json unreadable after retries, treating as empty")
            return {}
    return {}


def _replace_with_retry(src: str, dst) -> None:
    """`os.replace` with retry for the Windows sharing-violation race. On Windows,
    replacing auth.json fails with PermissionError (WinError 5) or WinError 32 if
    a sibling process (e.g. another multi-worker `--serve`) has it open at that
    instant. The holder releases in milliseconds, so retry with a short backoff
    rather than failing the keystore write — an unretried failure cascaded into a
    transient Firestore-init error and a cross-worker reconnect-respawn loop that
    left the device perpetually offline under workerCount > 1. POSIX rename is
    atomic and never hits this (first attempt succeeds)."""
    import time as _time
    for i in range(15):
        try:
            os.replace(src, dst)
            return
        except OSError as e:
            transient = isinstance(e, PermissionError) or getattr(e, "winerror", None) in (5, 32)
            if not transient or i == 14:
                raise
            _time.sleep(min(0.4, 0.05 * (i + 1)))


def _file_save(blob: dict[str, str]) -> None:
    _FALLBACK_DIR.mkdir(parents=True, exist_ok=True)
    # Write to tmp + atomic replace; _replace_with_retry absorbs the Windows
    # multi-worker sharing-violation race on auth.json.
    fd, tmp = tempfile.mkstemp(dir=str(_FALLBACK_DIR), prefix=".auth.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(blob, fh)
        _replace_with_retry(tmp, _FALLBACK_PATH)
        try:
            os.chmod(_FALLBACK_PATH, stat.S_IRUSR | stat.S_IWUSR)  # 0600
        except OSError:
            pass  # Windows ignores POSIX mode bits
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def install_uuid() -> str:
    """Get-or-create a stable per-install UUID, persisted to disk.

    Each install has one UUID for the life of `~/.super-research/`. It scopes
    the keyring accounts so multiple installs on the same user account don't
    clobber each other.
    """
    if _INSTALL_UUID_PATH.exists():
        try:
            val = _INSTALL_UUID_PATH.read_text().strip()
            if val:
                return val
        except OSError:
            pass
    _FALLBACK_DIR.mkdir(parents=True, exist_ok=True)
    val = uuid.uuid4().hex
    _INSTALL_UUID_PATH.write_text(val)
    try:
        os.chmod(_INSTALL_UUID_PATH, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass
    return val


def get(slot: Slot, install_id: str) -> str | None:
    kr = _try_keyring()
    if kr is not None:
        try:
            val = kr.get_password(SERVICE, _keyring_account(slot, install_id))  # type: ignore[attr-defined]
            if val:
                return val
        except Exception as e:
            log.warning("keyring read of slot=%s failed: %s", slot, e)
    blob = _file_load()
    return blob.get(_keyring_account(slot, install_id))


def set(slot: Slot, install_id: str, value: str) -> None:  # noqa: A001 - dict-ish API
    kr = _try_keyring()
    if kr is not None:
        try:
            kr.set_password(SERVICE, _keyring_account(slot, install_id), value)  # type: ignore[attr-defined]
            # Keyring is the live store → purge any file-fallback shadow for
            # this slot so auth.json can never hold a STALE token that a later
            # get() would return on a transient keyring read miss. Only rewrites
            # the file when a shadow actually exists (no churn on the hot path).
            try:
                acct = _keyring_account(slot, install_id)
                blob = _file_load()
                if acct in blob:
                    blob.pop(acct, None)
                    _file_save(blob)
            except Exception:
                pass  # shadow purge is best-effort; never fail a good keyring write
            return
        except Exception as e:
            log.warning("keyring write of slot=%s failed, using file: %s", slot, e)
    blob = _file_load()
    blob[_keyring_account(slot, install_id)] = value
    _file_save(blob)


def delete(slot: Slot, install_id: str) -> None:
    kr = _try_keyring()
    if kr is not None:
        try:
            kr.delete_password(SERVICE, _keyring_account(slot, install_id))  # type: ignore[attr-defined]
        except Exception:
            pass  # Already gone or backend complaint — fall through to file
    blob = _file_load()
    blob.pop(_keyring_account(slot, install_id), None)
    _file_save(blob)


def promote_pending(install_id: str) -> None:
    """Atomic-ish slot rotation: previous <- current, current <- pending, pending cleared.

    Used at the tail of a successful refresh-token rotation. Read pending
    first; if it's absent, no-op (caller didn't actually persist a new
    token).
    """
    new_token = get("pending", install_id)
    if not new_token:
        return
    old_current = get("current", install_id)
    if old_current:
        set("previous", install_id, old_current)
    set("current", install_id, new_token)
    delete("pending", install_id)


def try_recover(install_id: str) -> tuple[Slot, str] | None:
    """Startup self-heal: probe slots in recovery order, return first usable.

    Returns (slot, token) so the caller knows which slot a recovered token
    came from. Caller is responsible for testing it against securetoken and
    deciding whether to promote or discard.
    """
    for slot in RECOVER_ORDER:
        try:
            val = get(slot, install_id)
        except Exception as e:
            log.warning("recover: slot=%s read failed: %s", slot, e)
            continue
        if val:
            return slot, val
    return None


def clear_all(install_id: str, *, reason: str) -> None:
    """Wipe all slots. De-authenticates the WHOLE install (slots are keyed by
    install_uuid, NOT per-worker), so this is only ever correct on a PROVEN
    refresh-token revoke or an explicit user action (--unpair / --retire).

    `reason` is REQUIRED and recorded to the durable wipe-audit log BEFORE any
    deletion — so a future forensic can tell a genuine-revoke wipe from a
    user-intent wipe (and never again has to reconstruct an unattributed wipe
    from absence-of-evidence). Pass one of: "unpair", "retire", "revoke",
    "crash-loop", or a precise short tag.
    """
    _write_wipe_audit(install_id, reason)
    for slot in SLOTS:
        try:
            delete(slot, install_id)
        except Exception:
            pass
