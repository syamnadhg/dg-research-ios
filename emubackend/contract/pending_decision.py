"""`pendingDecision` — one field, one slot, and five clobber rules that are all load-bearing.

Evidence: ``research.py · _persist_pending_decision`` / ``_clear_pending_decision``, via
``docs/FIRESTORE_CONTRACT.md`` §7.

This is the single densest piece of contract semantics in the port, and the recipe's warning
applies to it more than to anything else: these rules encode months of production fixes, and
every one of them fails *silently*. A wrongly-cleared decision card does not raise; the user
simply finds the prompt gone when they reopen the chat, with no error anywhere.

Kept as pure predicates rather than woven into a writer so each rule is independently testable
and independently readable. The orchestrator supplies the state; these functions decide.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

__all__ = [
    "CLEAR_SET_SCOPED_BY_AGENT",
    "KIND_SPECIFIC_KINDS",
    "KNOWN_KINDS",
    "MirrorInputs",
    "PendingState",
    "clear_agent_scope",
    "normalize_agent",
    "should_clear",
    "should_mirror",
    "suppress_for_late_upgrade",
]

#: Kinds the frontend understands. An unknown kind is **skipped** by the frontend — so an
#: invented kind is not an error, it is an invisible no-op, which is worse.
KNOWN_KINDS = (
    "login_required",
    "human_verification_required",
    "agent_link_failed",
    "pro_required",
    "pipeline_error",
)

#: Kinds whose persist sets ``suppress_generic_mirror`` so the generic ``pipeline_error`` mirror
#: cannot overwrite their richer payload.
KIND_SPECIFIC_KINDS = (
    "pro_required",
    "login_required",
    "human_verification_required",
    "agent_link_failed",
)

#: Event types whose clear is **scoped to the emitting agent**. Every other clearing event type
#: passes ``agent=None`` and therefore clears unconditionally.
#:
#: ⚠ ``phase_restart`` is deliberately NOT here even though it clears: clicking **Retry** emits
#: ``phase_restart`` and *not* ``pipeline_resumed``, so if it were agent-scoped a retry would
#: leave a stale card behind.
CLEAR_SET_SCOPED_BY_AGENT = ("agent_skipped", "pipeline_resumed")


@dataclass(frozen=True)
class PendingState:
    """The orchestrator's view of the single slot."""

    active: bool = False
    agent: str | None = None
    decision_id: str | None = None


def clear_agent_scope(event_type: str, agent: str | None) -> str | None:
    """The scoping decision made at the ``emit_event`` seam.

    Rule 2: scoping happens *here*, not inside the clear. ``agent_skipped`` and
    ``pipeline_resumed`` pass the agent through; ``pipeline_stopped``, ``phase_skipped`` and
    ``phase_restart`` always pass ``None`` and so clear unconditionally.
    """
    return agent if event_type in CLEAR_SET_SCOPED_BY_AGENT else None


def normalize_agent(agent: str | None) -> str | None:
    """Upstream's exact normalisation: ``a = (agent or "").lower() or None``.

    Two behaviours that a reimplementation gets wrong by omission, both verified against
    ``research.py · _clear_pending_decision``:

    * **The comparison is case-insensitive.** ``"ChatGPT"`` and ``"chatgpt"`` are the same agent.
      Comparing raw strings makes the keep-guard fire when it should not — refusing a legitimate
      clear, so a resolved card lingers and re-surfaces on a cold chat open.
    * **An empty string collapses to ``None``**, i.e. an *unconditional* clear — not a clear
      scoped to an agent literally named "". Treating ``""`` as a name inverts the rule: the
      guard would then protect the slot from a clear that upstream performs unconditionally.
    """
    return (agent or "").lower() or None


def should_clear(state: PendingState, agent: str | None) -> bool:
    """Rule 1 — the agent keep-guard. The subtlest rule in the contract.

    A blanket clear must **not** fire when a *different* agent currently owns the slot.

    The sequence it protects, which is not hypothetical: agent A fails to launch. Its mirror is
    non-blocking, so the run advances. Agent B then raises a genuinely blocking card and takes
    the slot. Now A's late clear arrives. Without this guard it deletes B's still-live card, and
    the loss is invisible until the user closes and reopens the chat — by which time the run is
    waiting on a decision the user was never shown.

    An agent-less clear is unconditional by design; scoping is :func:`clear_agent_scope`'s job.

    ⚠ **Not modelled here, and deliberately so:** upstream also calls ``_disarm_registry(a)``
    *before* this guard whenever an agent is given, because the auto-skip deadline registry is
    per-agent and multi-entry, so disarming the acting agent is correct even when a sibling owns
    the mirror. That registry is a separate mechanism the iOS orchestrator does not have yet;
    when it gains one, the disarm must happen **outside** this predicate or a recovered agent
    gets auto-skipped.
    """
    a = normalize_agent(agent)
    if a is None:
        return True
    owner = normalize_agent(state.agent)
    if state.active and owner is not None and owner != a:
        return False
    return True


@dataclass(frozen=True)
class MirrorInputs:
    """Everything the generic-mirror gate looks at."""

    event_type: str
    data: dict[str, Any]
    suppress_generic_mirror: bool = False
    force_mirror: bool = False


def should_mirror(inputs: MirrorInputs) -> bool:
    """The generic-mirror gate: a four-way AND (rule 3).

    ``type == "pipeline_error"`` **and** ``data["actions"]`` truthy **and**
    ``(not data.get("quiet") or force_mirror)`` **and** ``not suppress_generic_mirror``.

    Every clause earns its place. Mirroring *every* ``pipeline_error`` would make transient
    529/overload auto-retry banners **durable** — the user would come back to a permanent card
    for something the pipeline already recovered from by itself. The ``actions`` clause is what
    distinguishes "the user must choose something" from "this was just logged".
    """
    if inputs.event_type != "pipeline_error":
        return False
    if not inputs.data.get("actions"):
        return False
    if inputs.data.get("quiet") and not inputs.force_mirror:
        return False
    if inputs.suppress_generic_mirror:
        return False
    return True


def suppress_for_late_upgrade(state: PendingState, decision_id: str | None) -> bool:
    """Rule 4 — a late async upgrade must not steal the slot.

    ``owns_mirror = active and state.decision_id == decision_id``; the caller passes
    ``suppress_generic_mirror = not owns_mirror``. This is the only reader of the stored
    decision id, and its whole purpose is that an upgrade arriving after the slot changed hands
    declines to write rather than overwriting a card that now belongs to someone else.
    """
    owns_mirror = bool(state.active and decision_id is not None
                       and state.decision_id == decision_id)
    return not owns_mirror


def startup_clear_field(*, queued: bool) -> bool:
    """Rule 5 — a fresh **non-queued** run start wipes the slot in the same patch.

    The wipe rides along with ``backendRunId``/``status`` so there is no window where a new run
    is visible while the previous run's decision card is still showing.

    The **queued** branch deliberately does not wipe: a queued run has not started, so the card
    it would erase belongs to the run currently executing.
    """
    return not queued
