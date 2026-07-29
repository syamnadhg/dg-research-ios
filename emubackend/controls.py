"""Run controls — pause/resume/stop, skips, and decision routing.

Mirrors ``research.py::PipelineControls``. This is the part of the port the recipe warns about
most directly: *"what makes this expensive is not the line count — it is that those 9–11k lines
re-derive behaviours that took months of production fixes"*. Every invariant below is one of
those, and each is here with the incident that produced it, because the reason is what makes it
survive the next refactor.

Four that a fresh implementation gets wrong by default:

1. **``skipped_agents`` is overloaded, and conflating its two populations is a real incident.**
   Genuine user *Skip* taps share the set with internal markers (setup failure, login-gate
   timeout). Stamping every member as a user skip reported an agent whose brief never sent as a
   *user decision*, and — because ``agent_skipped`` is in the pendingDecision clear set — the emit
   auto-retracted the honest Retry/Skip card about four seconds after it was raised. So
   :attr:`RunControls.user_skip_taps` records which entries came from an actual tap, and nothing
   else may be labelled or emitted as one.

2. **A pending decision is agent-scoped on the non-blocking path.** The blocking gate pops it
   globally; a non-blocking park consumes it *scoped*, so a decision meant for one card cannot be
   stolen by a different agent's simultaneous park.

3. **``awaiting_user`` time is excluded from the watchdog's active-time ceiling**, or a legitimate
   wait for a human gets killed as "stuck". And it **must** be cleared on reset: a stale ``True``
   means the next run's active time never accrues, so its watchdog never fires at all — the
   failure is the *absence* of a safety net, which nothing reports.

4. **A stop is not a pause.** Resume must not revive a stopped run, and the events are separate
   for that reason.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

__all__ = ["RunControls", "SkipOrigin"]


class SkipOrigin:
    """Why an agent ended up in ``skipped_agents``. The distinction is load-bearing."""

    USER_TAP = "user_tap"
    HV_AUTO = "hv_auto"
    INTERNAL = "internal"


@dataclass
class RunControls:
    """In-memory control surface for one run.

    Replaces the backend's older ``.stop``/``.pause`` file sentinels with events, and is fed from
    the device-command listener. Deliberately a plain object with explicit predicates rather than
    a bag of booleans callers interpret themselves — the interpretations are exactly what drifted.
    """

    stop_event: asyncio.Event = field(default_factory=asyncio.Event)
    pause_event: asyncio.Event = field(default_factory=asyncio.Event)
    resume_event: asyncio.Event = field(default_factory=asyncio.Event)

    #: True while a phase is blocked on a user decision. Excluded from the watchdog's
    #: active-time ceiling — see invariant 3.
    awaiting_user: bool = False

    #: Per-agent link-fail decision: "retry" | "skip" | "stop".
    pending_agent_decision: str | None = None
    #: The agent the pending decision targets. "" means agent-less (legacy, global).
    pending_agent_decision_agent: str = ""

    #: Agents to drop on the next polling tick. ⚠ OVERLOADED — see invariant 1.
    skipped_agents: set[str] = field(default_factory=set)
    #: The subset of `skipped_agents` that came from an ACTUAL user tap.
    user_skip_taps: set[str] = field(default_factory=set)
    #: Entries dropped by the human-verification auto-skip (an unacted hands-off wall).
    hv_auto_skipped: set[str] = field(default_factory=set)
    #: Internal marker -> honest reason, logged when consumed.
    auto_skip_reasons: dict[str, str] = field(default_factory=dict)

    #: Phase numbers queued for skip by the watchdog banner's "Skip phase".
    skipped_phases: set[int] = field(default_factory=set)

    #: Platforms whose trusted session cookie was falsified mid-run.
    cookie_trust_broken: set[str] = field(default_factory=set)
    #: Platforms whose work-tab login pause hit its timeout — distinct from an explicit Skip,
    #: though both land in `skipped_agents`. Callers key on this to offer a retryable card
    #: instead of a manual fallback nobody asked for.
    login_pause_timeout_agents: set[str] = field(default_factory=set)
    #: Agents confirmed behind a human-verification wall: key -> short reason.
    hv_blocked: dict[str, str] = field(default_factory=dict)

    skip_init_verify: bool = False
    retry_init_verify: bool = False
    extra_context: list = field(default_factory=list)

    # -- stop / pause / resume ---------------------------------------------------

    @property
    def stopped(self) -> bool:
        return self.stop_event.is_set()

    @property
    def paused(self) -> bool:
        """Paused means: pause requested and not yet resumed, and not stopped.

        Expressed as a predicate rather than left to callers, because "is it paused" was read
        three different ways and a resume that revived a stopped run is the kind of bug that only
        shows up as a duplicated run.
        """
        return self.pause_event.is_set() and not self.resume_event.is_set() and not self.stopped

    def request_stop(self) -> None:
        self.stop_event.set()

    def request_pause(self) -> None:
        """A pause on a stopped run is a no-op — there is nothing left to pause."""
        if self.stopped:
            return
        self.resume_event.clear()
        self.pause_event.set()

    def request_resume(self) -> None:
        """Resume clears the pause. ⚠ It must never revive a stopped run.

        Invariant 4. Stop is terminal; a queued resume arriving after a stop (the user taps
        Resume on a card the stop already invalidated) would otherwise restart work the operator
        deliberately ended.
        """
        if self.stopped:
            return
        self.pause_event.clear()
        self.resume_event.set()

    async def wait_while_paused(self) -> bool:
        """Block while paused. Returns False if the run was stopped while waiting.

        Returning a value rather than raising means the caller's normal control flow decides what
        a stop means at that point in the phase, which is where the phase-specific cleanup lives.
        """
        while self.paused:
            await asyncio.sleep(0.05)
        return not self.stopped

    # -- skips: the overloaded set, disambiguated --------------------------------

    def request_skip_agent(
        self, agent: str, *, origin: str = SkipOrigin.USER_TAP, reason: str = ""
    ) -> None:
        """Queue an agent skip, recording **where it came from**.

        Origin is required-by-default rather than inferred. Invariant 1: only a genuine tap may be
        reported to the frontend as a user decision, because an ``agent_skipped`` emit sits in the
        pendingDecision clear set and will retract the honest failure card.
        """
        key = agent.lower()
        self.skipped_agents.add(key)
        if origin == SkipOrigin.USER_TAP:
            self.user_skip_taps.add(key)
        else:
            if origin == SkipOrigin.HV_AUTO:
                self.hv_auto_skipped.add(key)
            self.auto_skip_reasons[key] = reason or origin

    def is_user_skip(self, agent: str) -> bool:
        """True only for an actual user tap. The check every emit path must make."""
        return agent.lower() in self.user_skip_taps

    def skip_origin(self, agent: str) -> str | None:
        key = agent.lower()
        if key not in self.skipped_agents:
            return None
        if key in self.user_skip_taps:
            return SkipOrigin.USER_TAP
        if key in self.hv_auto_skipped:
            return SkipOrigin.HV_AUTO
        return SkipOrigin.INTERNAL

    def skip_reason(self, agent: str) -> str:
        """The honest reason, for logs and for the frontend card."""
        key = agent.lower()
        if key in self.user_skip_taps:
            return "skipped by user"
        return self.auto_skip_reasons.get(key, "skipped internally")

    def consume_skip(self, agent: str) -> str | None:
        """Take an agent off the skip list, returning its origin. Idempotent."""
        key = agent.lower()
        origin = self.skip_origin(key)
        self.skipped_agents.discard(key)
        self.user_skip_taps.discard(key)
        self.hv_auto_skipped.discard(key)
        self.auto_skip_reasons.pop(key, None)
        return origin

    def is_phase_skip_requested(self, phase: int) -> bool:
        return phase in self.skipped_phases

    # -- decision routing --------------------------------------------------------

    def set_agent_decision(self, decision: str, agent: str = "") -> None:
        self.pending_agent_decision = decision
        self.pending_agent_decision_agent = (agent or "").lower()

    def pop_agent_decision(self) -> str | None:
        """The **blocking** gate's consumer: pops globally, whatever agent it targets."""
        decision = self.pending_agent_decision
        self.pending_agent_decision = None
        self.pending_agent_decision_agent = ""
        return decision

    def poll_agent_decision(self, agent: str) -> str | None:
        """The **non-blocking** park's consumer: agent-scoped.

        Invariant 2. A decision addressed to one agent must not be stolen by a different agent's
        simultaneous park. An agent-less decision ("") is legacy-global and may be taken by
        anyone; a targeted one is only visible to its target.
        """
        if self.pending_agent_decision is None:
            return None
        target = self.pending_agent_decision_agent
        if target and target != (agent or "").lower():
            return None
        return self.pop_agent_decision()

    # -- watchdog accounting -----------------------------------------------------

    def counts_toward_active_time(self) -> bool:
        """Invariant 3: waiting on a human is not the pipeline being stuck."""
        return not self.awaiting_user

    def begin_awaiting_user(self) -> None:
        self.awaiting_user = True

    def end_awaiting_user(self) -> None:
        self.awaiting_user = False

    # -- reset -------------------------------------------------------------------

    def reset(self) -> None:
        """Return to a clean state for the next run in the same process.

        ⚠ ``awaiting_user`` **must** be cleared here. A stale ``True`` means the next run's active
        time never accrues, so its watchdog never fires — and the symptom is the *absence* of a
        safety net, which nothing reports. Everything else is cleared for the same reason in
        miniature: a leftover skip or decision silently applies to a run that never asked for it.
        """
        self.stop_event = asyncio.Event()
        self.pause_event = asyncio.Event()
        self.resume_event = asyncio.Event()
        self.awaiting_user = False
        self.pending_agent_decision = None
        self.pending_agent_decision_agent = ""
        self.skipped_agents.clear()
        self.user_skip_taps.clear()
        self.hv_auto_skipped.clear()
        self.auto_skip_reasons.clear()
        self.skipped_phases.clear()
        self.cookie_trust_broken.clear()
        self.login_pause_timeout_agents.clear()
        self.hv_blocked.clear()
        self.skip_init_verify = False
        self.retry_init_verify = False
        self.extra_context.clear()
