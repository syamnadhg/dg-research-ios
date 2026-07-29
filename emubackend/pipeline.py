"""The P0–P3 run loop — the orchestration half of the second backend.

This composes everything the contract layer provides into one run lifecycle: claim, the
queued→ongoing flip, the phase sequence, event emission, pause/resume/stop, skips, and
completion. It is the layer decision A8 converts from *reuse* to *reimplement*, and the recipe is
blunt that its cost is not line count but the behaviours it re-derives.

**What is here and what is not.** The *loop* is complete and verifiable without a browser: phase
bodies are injected, so the same sequence can be driven by a fake substrate and its Firestore write
sequence compared against a golden fixture (:mod:`emubackend.contract.fixtures`). What is *not*
here is the per-platform phase bodies — those need selectors and geometry from real logged-in DOM
in the Simulator, and inventing them would manufacture precisely the read-drift failure
:mod:`emubackend.harvest` exists to catch.

Ordering rules that are contract, not style:

* ``phase_start`` is emitted **after** the pause gate, not before. Emitting first makes the
  frontend render a running tile for a phase that is actually parked, and the tile then never
  updates because nothing is happening.
* A **skipped** phase emits ``phase_skipped`` and no ``phase_start``/``phase_complete`` pair. A
  frontend counting starts against completes would otherwise report the run as permanently
  in-flight.
* A **stop** is checked before every phase and inside the pause gate, so a stop during a long park
  takes effect at the park rather than after it.
* The startup patch writes ``pendingDecision`` as a **field delete** in the *same* patch as
  ``status``/``backendRunId`` for a non-queued start, so there is no window in which a new run is
  visible alongside the previous run's decision card. A **queued** start deliberately does not wipe
  it — that card belongs to the run currently executing.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Sequence

from emubackend import claim as claim_mod
from emubackend import harvest, intents
from emubackend.contract import events as events_mod
from emubackend.contract import pending_decision as pd
from emubackend.contract import values
from emubackend.controls import RunControls

__all__ = [
    "Phase",
    "PhaseOutcome",
    "RunContext",
    "RunResult",
    "emit_event",
    "run_pipeline",
    "start_patch",
]


@dataclass
class RunContext:
    """Everything one run needs, gathered so the loop takes no globals.

    Explicitly not module globals — that is what makes the backend's contract helpers unusable by
    import (they are welded to state only ``setup_firestore_run`` arms), and reproducing that
    coupling here would recreate the problem A8 forced us around.
    """

    uid: str
    research_id: str
    device_id: str
    run_id: str
    client: Any  # FirestoreRest, or anything with .patch / .create_with_auto_id
    controls: RunControls = field(default_factory=RunControls)
    seq: events_mod.SeqGuard = field(default_factory=events_mod.SeqGuard)
    history: harvest.HarvestHistory = field(default_factory=harvest.HarvestHistory)
    registry: intents.IntentRegistry = field(default_factory=intents.IntentRegistry)
    pending: pd.PendingState = field(default_factory=pd.PendingState)
    #: Injected so tests are deterministic and so no code path reaches for wall-clock directly.
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)

    @property
    def research_path(self) -> str:
        return f"users/{self.uid}/researches/{self.research_id}"

    @property
    def events_path(self) -> str:
        return f"{self.research_path}/pipeline_events"

    @property
    def device_path(self) -> str:
        return f"devices/{self.device_id}"


@dataclass
class Phase:
    """One pipeline phase. *body* does the browser work and is injected."""

    number: int
    name: str
    body: Callable[[RunContext], Awaitable[Any] | Any]
    agents: tuple[str, ...] = ()


@dataclass
class PhaseOutcome:
    number: int
    name: str
    status: str  # "complete" | "skipped" | "stopped" | "failed"
    detail: str = ""


@dataclass
class RunResult:
    run_id: str
    status: str  # "complete" | "stopped" | "failed"
    phases: list[PhaseOutcome] = field(default_factory=list)
    detail: str = ""


# --------------------------------------------------------------------------------------
# writes
# --------------------------------------------------------------------------------------


def emit_event(
    ctx: RunContext,
    event_type: str,
    *,
    data: dict | None = None,
    phase: int | None = None,
    agent: str | None = None,
) -> dict:
    """Build and write one ``pipeline_events`` document, and run the clear seam.

    The clear seam is here rather than at the call sites deliberately: the backend scopes the
    pendingDecision clear at its central ``emit_event``, and scattering that decision across
    call sites is what let ``phase_restart`` be treated inconsistently.
    """
    built = events_mod.build_event(
        event_type=event_type,
        device_id=ctx.device_id,
        seq=ctx.seq.next(),
        data=data,
        phase=phase,
        agent=agent,
        now=ctx.now(),
    )
    doc = dict(built.document)
    # expireAt is the one field with no implicit encoding — hand it over as a timestampValue.
    doc["expireAt"] = values.timestamp_value(doc["expireAt"])["timestampValue"]
    ctx.client.create_with_auto_id(ctx.events_path, doc)

    scoped = pd.clear_agent_scope(event_type, agent)
    if event_type in _CLEAR_ON and pd.should_clear(ctx.pending, scoped):
        _clear_pending(ctx)
    return doc


#: Event types that resolve a decision. `phase_restart` is present because Retry emits it and
#: does NOT emit `pipeline_resumed`, so omitting it strands the card it just resolved.
_CLEAR_ON = (
    "agent_skipped",
    "pipeline_resumed",
    "pipeline_stopped",
    "phase_skipped",
    "phase_restart",
)


def _clear_pending(ctx: RunContext) -> None:
    """Retract the decision mirror. A field delete, never null.

    The frontend distinguishes absent from present-but-null, so writing null reports success and
    leaves the card on screen.
    """
    ctx.client.patch(ctx.research_path, {}, delete_paths=["pendingDecision"])
    ctx.pending = pd.PendingState()


def start_patch(ctx: RunContext, *, queued: bool) -> dict:
    """The run-start patch. Wipes the decision slot in the SAME patch for a non-queued start."""
    fields = {
        "status": "queued" if queued else "ongoing",
        "backendRunId": ctx.run_id,
    }
    deletes = ["pendingDecision"] if pd.startup_clear_field(queued=queued) else None
    ctx.client.patch(ctx.research_path, fields, delete_paths=deletes)
    if deletes:
        ctx.pending = pd.PendingState()
    return fields


# --------------------------------------------------------------------------------------
# the loop
# --------------------------------------------------------------------------------------


async def run_pipeline(
    ctx: RunContext,
    phases: Sequence[Phase],
    *,
    queued: bool = False,
    worker_id: int | None = None,
    lock_dir=None,
) -> RunResult:
    """Drive the phases in order, honouring the controls, and report honestly.

    Returns a :class:`RunResult` rather than raising on a stop: a stop is an ordinary outcome the
    caller records, not an exception, and modelling it as one made the completion path skip its
    own bookkeeping.
    """
    if worker_id is not None:
        allowed, why = claim_mod.may_claim(
            ctx.research_id,
            self_worker_id=worker_id,
            worker_ids=[worker_id],
            lock_dir=lock_dir,
        )
        if not allowed:
            return RunResult(ctx.run_id, "stopped", detail=f"not claimed: {why}")
        claim_mod.write_lock(worker_id, ctx.research_id, ctx.run_id, lock_dir=lock_dir)

    start_patch(ctx, queued=queued)
    result = RunResult(run_id=ctx.run_id, status="complete")

    try:
        for phase in phases:
            if ctx.controls.stopped:
                result.status = "stopped"
                result.detail = f"stopped before phase {phase.number}"
                emit_event(ctx, "pipeline_stopped", phase=phase.number)
                break

            if ctx.controls.is_phase_skip_requested(phase.number):
                # No phase_start/phase_complete pair — a frontend counting starts against
                # completes would otherwise report the run as permanently in flight.
                emit_event(ctx, "phase_skipped", phase=phase.number)
                result.phases.append(
                    PhaseOutcome(phase.number, phase.name, "skipped", "skip requested")
                )
                continue

            # The pause gate comes BEFORE phase_start, or the frontend renders a running tile
            # for a phase that is parked and the tile never updates.
            if not await ctx.controls.wait_while_paused():
                result.status = "stopped"
                result.detail = f"stopped while paused at phase {phase.number}"
                emit_event(ctx, "pipeline_stopped", phase=phase.number)
                break

            emit_event(ctx, "phase_start", phase=phase.number)
            try:
                outcome = phase.body(ctx)
                if hasattr(outcome, "__await__"):
                    outcome = await outcome
            except Exception as exc:  # noqa: BLE001 - a phase failure is data, not a crash
                emit_event(
                    ctx,
                    "pipeline_error",
                    phase=phase.number,
                    data={"message": f"{type(exc).__name__}: {exc}", "actions": ["retry", "skip"]},
                )
                result.status = "failed"
                result.detail = f"phase {phase.number} raised: {type(exc).__name__}: {exc}"
                result.phases.append(
                    PhaseOutcome(phase.number, phase.name, "failed", str(exc))
                )
                break

            emit_event(ctx, "phase_complete", phase=phase.number)
            result.phases.append(PhaseOutcome(phase.number, phase.name, "complete"))
        else:
            emit_event(ctx, "pipeline_complete")
    finally:
        if worker_id is not None:
            # Always released, including on a stop or a failure: a retained lock makes the next
            # claim look like a live sibling and wedges the device until the age guard expires.
            claim_mod.release_lock(worker_id, lock_dir)

    if result.status == "complete":
        ctx.client.patch(ctx.research_path, {"status": "complete"})
    elif result.status == "stopped":
        ctx.client.patch(ctx.research_path, {"status": "stopped"})
    return result
