"""The `pipeline_events` writer contract — shape, sequence, and the omission rules.

Evidence: ``research.py · emit_event → _emit_to_firestore`` (the single producer in the whole
backend), via ``docs/FIRESTORE_CONTRACT.md`` §4.5.

The collection is **append-only** (``allow update: if false``), and the frontend consumes it with
``where("seq", ">", lastSeq).orderBy("seq", "asc")`` against a cursor persisted in
``localStorage``. Two consequences that shape everything here:

* **``seq`` is not a counter.** It is *epoch millis, forced monotonic*. Implementing it as a
  0-based per-run counter is the mistake that looks obviously right and breaks the consumer: a
  new run would restart at 0, land below the frontend's stored cursor, and every event of that
  run would be filtered out. The run would appear to produce nothing.
* **Absence is meaningful.** ``data`` is omitted entirely when empty, ``agent`` is omitted when
  falsy, but ``phase`` is written even when it is ``0``. One collection carries three different
  absence semantics (backend device events, backend owner events, frontend-authored events), so
  "just write everything" is not a safe simplification.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

__all__ = [
    "EVENT_TTL_DAYS",
    "OWNER_BRANCH_TYPES",
    "STRIPPED_DATA_KEYS",
    "SeqGuard",
    "build_event",
]

#: ``expireAt`` convention on every backend-authored event. No rule enforces it.
EVENT_TTL_DAYS = 30

#: Keys ``emit_event`` pops off the data dict before writing. They are *control flags for the
#: mirror decision*, never payload — and upstream pops them off the **same dict object** the
#: event references, so a caller that reuses the dict afterwards sees them gone. Mirrored here
#: so a vendored writer cannot leak them into Firestore.
STRIPPED_DATA_KEYS = ("suppress_generic_mirror", "force_mirror")

#: The *owner* branch of the rules restricts `type` to these. The **device branch is not
#: type-restricted** — worth stating, because it means a device may emit any type and a
#: reviewer looking only at the owner rule would wrongly conclude otherwise.
OWNER_BRANCH_TYPES = (
    "phase_start",
    "phase_complete",
    "phase_skipped",
    "pipeline_complete",
)


class SeqGuard:
    """Monotonic ``seq`` generator: epoch millis, never repeating or going backwards.

    Upstream logic, verbatim in behaviour::

        new = int(time.time() * 1000)
        if new <= _fb_seq:
            new = _fb_seq + 1

    Two events inside the same millisecond therefore differ by one, and a clock that steps
    backwards (NTP correction, sleep/wake — routine on a laptop running a 90-minute pipeline)
    cannot produce a duplicate or a regression. Either would silently drop events at the
    consumer, whose cursor is strictly ``seq > lastSeq``.

    Guarded by a lock because the vendored orchestrator writes events from more than one task,
    and an unlocked read-modify-write can hand the same value to two callers.
    """

    def __init__(self, start: int = 0):
        self._last = int(start)
        self._lock = threading.Lock()

    @property
    def last(self) -> int:
        return self._last

    def next(self, now_ms: int | None = None) -> int:
        with self._lock:
            candidate = int(now_ms if now_ms is not None else time.time() * 1000)
            if candidate <= self._last:
                candidate = self._last + 1
            self._last = candidate
            return candidate

    def observe(self, seq: int) -> None:
        """Raise the floor to *seq* — e.g. after reading the last event of a resumed run.

        Without this, a resumed run restarts its floor from 0, emits values below the
        frontend's stored cursor, and its events are filtered out entirely.
        """
        with self._lock:
            self._last = max(self._last, int(seq))


@dataclass(frozen=True)
class BuiltEvent:
    """A ready-to-write event document plus the flags that were stripped from its data."""

    document: dict[str, Any]
    suppress_generic_mirror: bool
    force_mirror: bool


def build_event(
    *,
    event_type: str,
    device_id: str,
    seq: int,
    data: dict[str, Any] | None = None,
    phase: int | None = None,
    agent: str | None = None,
    now: datetime | None = None,
    ttl_days: int = EVENT_TTL_DAYS,
) -> BuiltEvent:
    """Build one ``pipeline_events`` document in the backend's exact shape.

    The omission rules are the contract, not tidiness:

    * ``phase`` — guarded on ``is not None``, so **``phase=0`` IS written**. A truthiness guard
      would drop phase 0, and P0 is a real phase.
    * ``agent`` — guarded on truthiness, so ``agent=""`` is **omitted**. Not lowercased.
    * ``data`` — omitted **entirely** when empty. The frontend's own emitter always writes
      ``{}``, so the same collection carries both, and a consumer must tolerate both.
    * ``deviceId`` — **top level**, a sibling of ``type`` and ``data``. Nesting it inside
      ``data`` fails the device branch of the rule, which reads the top-level field.
    * ``timestamp``/``seq`` — ints. A Firestore ``Timestamp`` fails ``is number``.
    """
    payload = dict(data or {})
    suppress = bool(payload.pop("suppress_generic_mirror", False))
    force = bool(payload.pop("force_mirror", False))

    when = now or datetime.now(timezone.utc)
    if when.tzinfo is None:
        raise ValueError(
            "now must be timezone-aware; a naive value shifts expireAt by the local offset"
        )

    document: dict[str, Any] = {
        "type": event_type,
        "timestamp": int(when.timestamp() * 1000),
        "seq": int(seq),
        "deviceId": device_id,
        "expireAt": when + timedelta(days=ttl_days),
    }
    if phase is not None:
        document["phase"] = int(phase)
    if agent:
        document["agent"] = agent
    if payload:
        document["data"] = payload

    return BuiltEvent(
        document=document, suppress_generic_mirror=suppress, force_mirror=force
    )
