"""The multi-worker claim sentinel — the guard against two workers running one pipeline.

Mirrors ``research.py``'s worker-lock protocol, and it exists because of a specific reproduction
worth restating in full, since every design choice below follows from it:

    STOP killed worker 1. Worker 2 claimed the next submission via the start-listener, deleted the
    Firestore queue doc, and flipped the research to *ongoing*. Worker 1 then rehydrated, saw an
    ongoing research with an on-disk queue dir, and auto-resumed locally — so **both workers ran
    the same pipeline**.

Three consequences, each of which looks like an odd choice until you have that repro in mind:

* **Flat layout** (``.worker.{N}.lock`` at the queues root), not per-run. The per-run directory is
  created at *dequeue*, not at *claim*, and between the two (~1–2s) it does not exist — so a
  sibling checking a per-run path sees nothing and proceeds. Flat means the lock can be written the
  moment the worker dequeues and is discoverable without knowing the run id.
* **Not a Firestore signal.** Both claim paths delete the device-queue doc immediately on a
  successful claim, so by the time a rebooting sibling rehydrates (4s later in the repro) there is
  no document left to query. The filesystem is the only surviving evidence.
* **PID *and* start time.** PID liveness alone cannot tell a live claim from a recycled PID, and a
  recycled PID reads as "a sibling owns this" forever. The recorded start time bounds that with an
  8-hour age guard.

⚠ **A8/A10:** the backend puts these locks in ``Path(__file__).parent/"queues"`` — *inside the
backend checkout*, which this repo must not write to and which the production daemon's
disk-restore scans. The lock directory here is therefore parameterised and defaults under the iOS
state dir, and pointing it at the backend checkout is **refused**.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "PID_REUSE_MAX_AGE_MS",
    "ClaimError",
    "WorkerLock",
    "default_lock_dir",
    "may_claim",
    "read_lock",
    "release_lock",
    "write_lock",
]

#: A recorded start time older than this makes the lock stale even if its PID is alive, because
#: PIDs are recycled and a coincidence would otherwise look like a live claim indefinitely.
PID_REUSE_MAX_AGE_MS = 8 * 60 * 60 * 1000


class ClaimError(RuntimeError):
    """The lock directory is unusable, or points somewhere it must not."""


def default_lock_dir() -> Path:
    """``<iOS state dir>/queues`` — never the backend checkout."""
    from emubackend.contract import identity

    return identity.state_dir() / "queues"


def _validate_dir(lock_dir: Path) -> Path:
    """Refuse a lock dir inside either guarded repo.

    Checked rather than documented because the backend's own constant points at its checkout, so
    copying the protocol faithfully and forgetting to reparameterise the path is the natural
    mistake — and the consequence is writing into a directory the production daemon scans.
    """
    lock_dir = Path(lock_dir).expanduser()
    resolved = lock_dir.resolve() if lock_dir.exists() else lock_dir.absolute()
    for guarded in ("dg-research-backend", "dg-research"):
        if guarded in resolved.parts:
            raise ClaimError(
                f"refusing to use {resolved} — it is inside {guarded}, which A8 forbids writing "
                f"to and whose queues/ the production daemon's disk-restore scans. Use "
                f"{default_lock_dir()} or another dir outside both repos."
            )
    return lock_dir


@dataclass(frozen=True)
class WorkerLock:
    """One worker's claim: what it owns, and enough to tell live from stale."""

    worker_id: int
    research_id: str
    run_id: str
    pid: int
    started_at_ms: int

    def to_json(self) -> dict:
        return {
            "worker_id": self.worker_id,
            "research_id": self.research_id,
            "run_id": self.run_id,
            "pid": self.pid,
            "started_at_ms": self.started_at_ms,
        }

    @classmethod
    def from_json(cls, raw: dict) -> WorkerLock:
        return cls(
            worker_id=int(raw["worker_id"]),
            research_id=str(raw["research_id"]),
            run_id=str(raw["run_id"]),
            pid=int(raw["pid"]),
            started_at_ms=int(raw["started_at_ms"]),
        )

    def is_stale(self, *, now_ms: int | None = None, pid_alive=None) -> tuple[bool, str]:
        """(stale, why). Stale means the claim may be ignored."""
        alive = (pid_alive or _pid_alive)(self.pid)
        if not alive:
            return True, f"pid {self.pid} is not running"
        now = int(now_ms if now_ms is not None else time.time() * 1000)
        age = now - self.started_at_ms
        if age > PID_REUSE_MAX_AGE_MS:
            return True, (
                f"pid {self.pid} is alive but the claim is {age / 3_600_000:.1f}h old "
                f"(> {PID_REUSE_MAX_AGE_MS / 3_600_000:.0f}h), so it is a recycled PID rather "
                f"than a live claim"
            )
        return False, f"pid {self.pid} alive, claim {age / 1000:.0f}s old"


def _pid_alive(pid: int) -> bool:
    """Liveness without killing anything. Signal 0 only checks permission to signal."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Someone else's process with this pid — it exists, which is all we asked.
        return True
    except OSError:
        return False
    return True


def lock_path(worker_id: int, lock_dir: Path | None = None) -> Path:
    """``<lock_dir>/.worker.{N}.lock`` — flat, not nested under a run id.

    See the module docstring: the per-run directory does not exist between claim and dequeue, so a
    per-run lock is invisible during exactly the window it needs to be seen.
    """
    base = _validate_dir(lock_dir or default_lock_dir())
    return base / f".worker.{int(worker_id)}.lock"


def write_lock(
    worker_id: int,
    research_id: str,
    run_id: str,
    *,
    lock_dir: Path | None = None,
    now_ms: int | None = None,
) -> WorkerLock:
    """Record this worker's claim. Idempotent — overwrites any prior content for this worker."""
    path = lock_path(worker_id, lock_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = WorkerLock(
        worker_id=int(worker_id),
        research_id=research_id,
        run_id=run_id,
        pid=os.getpid(),
        started_at_ms=int(now_ms if now_ms is not None else time.time() * 1000),
    )
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(lock.to_json(), sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)  # atomic, so a sibling never reads a half-written lock
    return lock


def read_lock(worker_id: int, lock_dir: Path | None = None) -> WorkerLock | None:
    path = lock_path(worker_id, lock_dir)
    if not path.exists():
        return None
    try:
        return WorkerLock.from_json(json.loads(path.read_text(encoding="utf-8")))
    except (ValueError, KeyError, OSError):
        # A corrupt lock is treated as absent. Refusing to claim on a corrupt file would wedge
        # the worker permanently, which is worse than the dual-spawn risk it guards against —
        # and the PID/age checks below would have rejected it anyway.
        return None


def release_lock(worker_id: int, lock_dir: Path | None = None) -> bool:
    path = lock_path(worker_id, lock_dir)
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False


def may_claim(
    research_id: str,
    *,
    self_worker_id: int,
    worker_ids: list[int],
    lock_dir: Path | None = None,
    now_ms: int | None = None,
    pid_alive=None,
) -> tuple[bool, str]:
    """May *self_worker_id* claim *research_id*? Returns (allowed, why).

    This is the rehydration check from the repro. A sibling's **live** lock naming this research
    means it already owns it, and proceeding would run the pipeline twice. Our own lock does not
    block us — that is the resume case, not a conflict.

    Returns a reason either way so a refusal is explicable in a log; "did not claim" with no
    explanation is indistinguishable from a bug.
    """
    for wid in worker_ids:
        if wid == self_worker_id:
            continue
        lock = read_lock(wid, lock_dir)
        if lock is None or lock.research_id != research_id:
            continue
        stale, why = lock.is_stale(now_ms=now_ms, pid_alive=pid_alive)
        if not stale:
            return False, (
                f"worker {wid} already owns research {research_id} (run {lock.run_id}): {why}"
            )
        return True, f"worker {wid}'s lock on {research_id} is stale: {why}"
    return True, "no sibling holds a live claim on this research"
