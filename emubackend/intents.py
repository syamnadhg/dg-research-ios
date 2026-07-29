"""Mutating intents, written already wrapped (phase A1 as rewritten for A8).

Under A8 there is no `research.py` refactor. Instead every mutating interaction in the iOS
orchestrator goes through :func:`guarded_intent` **from the moment it is written**, each carrying
an ``outcome_predicate``. Wrapping is a design property here, not a retrofit.

The pattern is copied from ``research.py::_selfheal_try`` — including the detail that is easy to
miss and is the whole reason that function is shaped the way it is:

⚠ **``confirmed_off`` gates the action, and it is not the inverse of the predicate.** It is a
*positive* off-signal. A predicate can be a false negative — the control is actually on, but the
selector rotted — and if a rotted predicate were allowed to drive a toggle, the heal would turn a
**live control OFF**. Requiring independent positive confirmation that the thing is off before
touching it is what makes the heal safe to enable at all.

The other half is the discipline the recipe calls mandatory and non-negotiable:

* **Fail to shadow before fail to escalate.** An unbaked predicate may log; it may never trigger
  escalation. A rotted predicate that escalates sends an agent to "fix" a **healthy** page, which
  is strictly worse than the crash it replaced.
* **A predicate bakes per-intent**, on ``≥20 runs in which that intent actually executed`` with
  zero false positives — runs, never wall-clock, because wall-clock silently means whatever the
  run rate happens to be and nobody re-checks the rate.
* **An intent that stays shadow-only forever is a valid resting state**, not a backlog item.

Flags default OFF and the wrapper is then a provable no-op:
``test_intents.py::test_the_wrapper_is_a_no_op_with_flags_off``.
"""

from __future__ import annotations

import inspect
import os
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

__all__ = [
    "BAKE_MIN_RUNS",
    "BakeStatus",
    "EscalationDecision",
    "Intent",
    "IntentOutcome",
    "IntentRegistry",
    "act_enabled",
    "guarded_intent",
    "observation_enabled",
]

#: Runs — not weeks — in which the intent actually executed, with zero false positives.
BAKE_MIN_RUNS = 20


def observation_enabled() -> bool:
    """Master switch. OFF ⇒ the whole subsystem is inert, matching the backend's default."""
    return os.environ.get("DG_IOS_SELFHEAL_ENABLED") == "1"


def act_enabled() -> bool:
    """The switch that lets it *click*. Double-gated, and both default OFF.

    Deliberately mirrors the backend's two-flag arrangement rather than collapsing to one: the
    observe flag is safe to leave on permanently, and keeping the acting flag separate means
    turning observation on can never accidentally arm an action.
    """
    return observation_enabled() and os.environ.get("DG_IOS_SELFHEAL_ACT") == "1"


@dataclass
class BakeStatus:
    """Per-intent bake ledger. Counts *executions*, not attempts to execute."""

    executions: int = 0
    false_positives: int = 0
    #: Set when a predicate has been observed firing on a demonstrably healthy page. Sticky:
    #: a predicate that has ever cried wolf is reverted or rewritten, never tuned in place, so
    #: it must not be able to bake by accumulating quiet runs afterwards.
    #:
    #: ⚠ Today this is *implied* by ``false_positives > 0``, because the only way to set it is
    #: :meth:`IntentRegistry.record_false_positive`, which also increments that counter — so the
    #: ``not self.poisoned`` clause in :attr:`baked` is currently redundant. It is kept as an
    #: **independent** invariant deliberately: the counter is the kind of thing that acquires a
    #: reset (per-run ledgers, a registry migration, a "clear the noise" utility), and the moment
    #: it does, a predicate that once fired on a healthy page must still not be able to bake.
    #: Pinned directly by ``test_the_poisoned_flag_blocks_a_bake_on_its_own``.
    poisoned: bool = False

    @property
    def baked(self) -> bool:
        return (
            not self.poisoned
            and self.false_positives == 0
            and self.executions >= BAKE_MIN_RUNS
        )

    def why_not_baked(self) -> str:
        if self.poisoned:
            return "poisoned — it fired on a healthy page; rewrite it, do not tune it"
        if self.false_positives:
            return f"{self.false_positives} false positive(s) recorded"
        return f"{self.executions}/{BAKE_MIN_RUNS} executions"


@dataclass
class Intent:
    """One mutating interaction, with the predicate that says whether it took effect."""

    id: str
    platform: str
    description: str
    #: The REAL outcome predicate. Sync or async; must not raise.
    outcome_predicate: Callable[..., Any]
    #: A POSITIVE off-signal. Without one, escalation can never act — see the module docstring.
    confirmed_off: Callable[..., Any] | None = None
    #: Reversible AND verifiable is a precondition for ever acting live (decision A2).
    reversible: bool = False

    @property
    def escalation_eligible(self) -> bool:
        """Structural eligibility, independent of bake state.

        An intent with no positive off-signal is permanently shadow-only *by construction*,
        which is the correct outcome rather than a gap to fill later: acting without one risks
        switching a live control off.
        """
        return self.reversible and self.confirmed_off is not None


@dataclass
class IntentOutcome:
    """What happened, in enough detail to be a telemetry record on its own."""

    intent_id: str
    predicate_passed: bool
    escalated: bool = False
    healed: bool = False
    shadow_only: bool = False
    reason: str = ""
    error: str | None = None

    def to_shadow_record(self) -> dict[str, Any]:
        return {
            "intent": self.intent_id,
            "outcome_pass": self.predicate_passed,
            "escalated": self.escalated,
            "healed": self.healed,
            "shadow_only": self.shadow_only,
            "reason": self.reason,
            "error": self.error,
        }


@dataclass
class EscalationDecision:
    """Why escalation was or was not permitted. Recorded so a refusal is explicable."""

    allowed: bool
    reason: str


class IntentRegistry:
    """Holds intents plus their bake ledgers, and decides whether escalation is permitted."""

    def __init__(self, shadow_sink: Callable[[dict], None] | None = None):
        self._intents: dict[str, Intent] = {}
        self._bake: dict[str, BakeStatus] = {}
        self._sink = shadow_sink or (lambda _rec: None)

    def register(self, intent: Intent) -> Intent:
        if intent.id in self._intents:
            raise ValueError(f"intent {intent.id!r} is already registered")
        self._intents[intent.id] = intent
        self._bake.setdefault(intent.id, BakeStatus())
        return intent

    def get(self, intent_id: str) -> Intent:
        try:
            return self._intents[intent_id]
        except KeyError:
            raise KeyError(f"no intent registered as {intent_id!r}") from None

    def bake(self, intent_id: str) -> BakeStatus:
        return self._bake.setdefault(intent_id, BakeStatus())

    def record_execution(self, intent_id: str) -> None:
        """Count one run in which this intent *actually executed*.

        The distinction matters: a run that never reached the intent contributes nothing to its
        bake volume. Counting attempts, or counting runs, would let a predicate bake without
        ever having been exercised — which is the false confidence the ≥20 gate exists to avoid.
        """
        self.bake(intent_id).executions += 1

    def record_false_positive(self, intent_id: str, *, healthy_page: bool = True) -> None:
        """Record a predicate firing when nothing was wrong.

        ``healthy_page=True`` poisons the predicate permanently. That is intentional: a
        predicate that has cried wolf once is rewritten, not nursed toward a bake by later quiet
        runs, and making the flag sticky is what stops it drifting back.
        """
        status = self.bake(intent_id)
        status.false_positives += 1
        if healthy_page:
            status.poisoned = True

    def may_escalate(self, intent_id: str) -> EscalationDecision:
        """All four conditions, evaluated in the order that makes a refusal most informative."""
        intent = self.get(intent_id)
        if not act_enabled():
            return EscalationDecision(False, "acting is disabled (DG_IOS_SELFHEAL_ACT unset)")
        if not intent.escalation_eligible:
            missing = []
            if not intent.reversible:
                missing.append("not marked reversible")
            if intent.confirmed_off is None:
                missing.append("no positive off-signal")
            return EscalationDecision(False, "structurally shadow-only: " + ", ".join(missing))
        status = self.bake(intent_id)
        if not status.baked:
            return EscalationDecision(False, f"predicate not baked ({status.why_not_baked()})")
        return EscalationDecision(True, "baked, reversible, and acting is enabled")

    def shadow(self, record: dict[str, Any]) -> None:
        if observation_enabled():
            try:
                self._sink(record)
            except Exception:
                pass  # telemetry must never break the pipeline it observes


async def _maybe_await(value: Any) -> Any:
    if inspect.isawaitable(value):
        return await value
    return value


async def _safe_call(fn: Callable[..., Any], *args) -> tuple[Any, str | None]:
    """Call a predicate without ever letting it raise into the verify path."""
    try:
        return await _maybe_await(fn(*args)), None
    except Exception as exc:  # noqa: BLE001 - isolation is the point
        return None, f"{type(exc).__name__}: {exc}"


async def guarded_intent(
    registry: IntentRegistry,
    intent_id: str,
    action: Callable[..., Awaitable[Any] | Any],
    *args,
    escalate: Callable[..., Awaitable[Any] | Any] | None = None,
) -> IntentOutcome:
    """Perform a mutating *action*, verify it, and escalate only if permitted.

    Sequence, and each step is here for a reason:

    1. **Run the action.** Its own exception is not swallowed — a genuine failure to interact is
       the caller's business.
    2. **Verify with the real predicate.** Predicate errors are captured, never raised: a broken
       predicate must not turn a successful interaction into a failed one.
    3. **Count the execution** for the bake ledger, because the intent did run.
    4. **On a pass, stop.** No escalation path is even consulted on the happy path.
    5. **On a fail, decide** via :meth:`IntentRegistry.may_escalate`. Not permitted ⇒ record to
       shadow and return; the caller's existing failure path then runs unchanged.
    6. **Before acting, require the positive off-signal.** If ``confirmed_off`` does not
       positively confirm the off state, do nothing — the predicate may be a false negative and
       acting would switch a live control off.
    7. **Re-verify after healing** with the same real predicate. "The heal ran" is not "the heal
       worked", and only re-running the predicate distinguishes them.
    """
    intent = registry.get(intent_id)

    result = action(*args)
    await _maybe_await(result)

    passed, pred_error = await _safe_call(intent.outcome_predicate, *args)
    registry.record_execution(intent_id)

    outcome = IntentOutcome(
        intent_id=intent_id,
        predicate_passed=bool(passed),
        error=pred_error,
    )

    if pred_error is not None:
        # A predicate that raises is a broken predicate, not a failed intent. Treat the intent
        # as having succeeded and flag the predicate — the opposite would manufacture failures.
        outcome.predicate_passed = True
        outcome.shadow_only = True
        outcome.reason = f"predicate raised, treated as pass: {pred_error}"
        registry.shadow(outcome.to_shadow_record())
        return outcome

    if outcome.predicate_passed:
        outcome.reason = "predicate passed"
        registry.shadow(outcome.to_shadow_record())
        return outcome

    decision = registry.may_escalate(intent_id)
    if not decision.allowed:
        outcome.shadow_only = True
        outcome.reason = f"would escalate, but {decision.reason}"
        registry.shadow(outcome.to_shadow_record())
        return outcome

    if escalate is None:
        outcome.shadow_only = True
        outcome.reason = "escalation permitted but no escalator supplied"
        registry.shadow(outcome.to_shadow_record())
        return outcome

    off_confirmed, off_error = await _safe_call(intent.confirmed_off, *args)
    if off_error is not None or not off_confirmed:
        outcome.shadow_only = True
        outcome.reason = (
            "off-signal not positively confirmed "
            f"({off_error or 'returned false'}) — refusing to act, the predicate may be a "
            "false negative and acting could switch a live control off"
        )
        registry.shadow(outcome.to_shadow_record())
        return outcome

    outcome.escalated = True
    _healed, esc_error = await _safe_call(escalate, *args)
    if esc_error is not None:
        outcome.reason = f"escalator raised: {esc_error}"
        registry.shadow(outcome.to_shadow_record())
        return outcome

    reverified, reverify_error = await _safe_call(intent.outcome_predicate, *args)
    outcome.healed = bool(reverified) and reverify_error is None
    outcome.predicate_passed = outcome.healed
    outcome.reason = (
        "escalated and verified" if outcome.healed else "escalated but predicate still failing"
    )
    registry.shadow(outcome.to_shadow_record())
    return outcome
