"""Tests for the wrapped-intent layer (phase A1 under A8).

The headline requirement from the recipe is explicit: *"Nothing acts with flags off, and the iOS
repo's own suites must prove the wrapper is a no-op."* That is the first test here.

The rest pin the safety discipline, because every one of these failing is worse than the crash it
replaces: a rotted predicate escalating onto a healthy page, or a heal switching a live control
off because the predicate was a false negative.
"""

from __future__ import annotations

import asyncio

import pytest

from emubackend import intents


@pytest.fixture(autouse=True)
def _flags_off(monkeypatch):
    """Default state is OFF, matching production. Tests opt in explicitly."""
    monkeypatch.delenv("DG_IOS_SELFHEAL_ENABLED", raising=False)
    monkeypatch.delenv("DG_IOS_SELFHEAL_ACT", raising=False)


def _arm(monkeypatch, *, observe=True, act=True):
    if observe:
        monkeypatch.setenv("DG_IOS_SELFHEAL_ENABLED", "1")
    if act:
        monkeypatch.setenv("DG_IOS_SELFHEAL_ACT", "1")


class Spy:
    """A toggle whose predicate, off-signal and heal are all observable."""

    def __init__(self, *, on=False, off_confirmed=True, heal_works=True):
        self.on = on
        self.off_confirmed = off_confirmed
        self.heal_works = heal_works
        self.actions = 0
        self.heals = 0

    async def action(self):
        self.actions += 1

    async def predicate(self):
        return self.on

    async def off_signal(self):
        return self.off_confirmed

    async def heal(self):
        self.heals += 1
        if self.heal_works:
            self.on = True


def _registry(spy, *, reversible=True, with_off=True, sink=None):
    reg = intents.IntentRegistry(shadow_sink=sink)
    reg.register(
        intents.Intent(
            id="gemini.enable_deep_research",
            platform="gemini",
            description="turn on Deep Research",
            outcome_predicate=spy.predicate,
            confirmed_off=spy.off_signal if with_off else None,
            reversible=reversible,
        )
    )
    return reg


def _run(reg, spy, **kw):
    return asyncio.run(
        intents.guarded_intent(
            reg, "gemini.enable_deep_research", spy.action, escalate=spy.heal, **kw
        )
    )


def _bake(reg, intent_id="gemini.enable_deep_research"):
    for _ in range(intents.BAKE_MIN_RUNS):
        reg.record_execution(intent_id)


# ======================================================================================
# the headline requirement
# ======================================================================================


def test_the_wrapper_is_a_no_op_with_flags_off():
    """With both flags unset the wrapper must run the action, verify, and nothing else.

    This is the recipe's stated gate for A1 existing at all.
    """
    spy = Spy(on=False)
    records = []
    reg = _registry(spy, sink=records.append)
    out = _run(reg, spy)

    assert spy.actions == 1, "the action itself must still run"
    assert spy.heals == 0, "nothing may act with flags off"
    assert out.escalated is False
    assert out.shadow_only is True
    assert "acting is disabled" in out.reason
    assert records == [], "with observation off, not even telemetry is written"


def test_observation_alone_logs_but_never_acts():
    """The two flags are separate so turning observation on cannot arm an action."""
    spy = Spy(on=False)
    records = []
    reg = _registry(spy, sink=records.append)
    import os

    os.environ["DG_IOS_SELFHEAL_ENABLED"] = "1"
    try:
        out = _run(reg, spy)
    finally:
        del os.environ["DG_IOS_SELFHEAL_ENABLED"]
    assert spy.heals == 0
    assert out.shadow_only is True
    assert len(records) == 1, "observation on ⇒ the would-be heal is recorded"


def test_act_requires_both_flags(monkeypatch):
    assert intents.act_enabled() is False
    monkeypatch.setenv("DG_IOS_SELFHEAL_ACT", "1")
    assert intents.act_enabled() is False, "ACT alone must not arm anything"
    monkeypatch.setenv("DG_IOS_SELFHEAL_ENABLED", "1")
    assert intents.act_enabled() is True


# ======================================================================================
# the happy path never consults escalation
# ======================================================================================


def test_a_passing_predicate_short_circuits(monkeypatch):
    _arm(monkeypatch)
    spy = Spy(on=True)
    reg = _registry(spy)
    _bake(reg)
    out = _run(reg, spy)
    assert out.predicate_passed is True
    assert out.escalated is False
    assert spy.heals == 0, "a healthy page must never be touched"


def test_a_broken_predicate_does_not_manufacture_a_failure(monkeypatch):
    """A predicate that raises is a broken predicate, not a failed intent.

    Treating the raise as a failure would escalate onto a page that was probably fine.
    """
    _arm(monkeypatch)

    async def boom():
        raise RuntimeError("selector gone")

    spy = Spy(on=False)
    reg = intents.IntentRegistry()
    reg.register(
        intents.Intent(
            id="x", platform="p", description="d",
            outcome_predicate=boom, confirmed_off=spy.off_signal, reversible=True,
        )
    )
    for _ in range(intents.BAKE_MIN_RUNS):
        reg.record_execution("x")
    out = asyncio.run(intents.guarded_intent(reg, "x", spy.action, escalate=spy.heal))
    assert out.predicate_passed is True
    assert out.escalated is False
    assert spy.heals == 0
    assert "predicate raised" in out.reason


# ======================================================================================
# fail to shadow before fail to escalate
# ======================================================================================


def test_an_unbaked_predicate_may_log_but_never_escalate(monkeypatch):
    """The mandatory, non-negotiable rule. An unbaked predicate escalating is the worst case."""
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy)
    reg.record_execution("gemini.enable_deep_research")  # 1 of 20
    out = _run(reg, spy)
    assert out.escalated is False
    assert spy.heals == 0
    assert "not baked" in out.reason
    assert "/20 executions" in out.reason


def test_bake_requires_twenty_executions_not_twenty_runs(monkeypatch):
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy)
    for i in range(intents.BAKE_MIN_RUNS - 1):
        reg.record_execution("gemini.enable_deep_research")
    assert reg.may_escalate("gemini.enable_deep_research").allowed is False
    reg.record_execution("gemini.enable_deep_research")
    assert reg.may_escalate("gemini.enable_deep_research").allowed is True


def test_a_bake_is_stated_in_runs_never_wall_clock():
    """Guards against the recalibration the recipe insists on: weeks silently mean run rate."""
    assert intents.BAKE_MIN_RUNS == 20
    status = intents.BakeStatus(executions=19)
    assert status.baked is False
    assert "19/20 executions" in status.why_not_baked()


def test_a_single_false_positive_blocks_a_bake(monkeypatch):
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy)
    _bake(reg)
    reg.record_false_positive("gemini.enable_deep_research")
    assert reg.may_escalate("gemini.enable_deep_research").allowed is False


def test_a_predicate_that_fired_on_a_healthy_page_is_poisoned_permanently(monkeypatch):
    """"Reverted or rewritten, never tuned in place" — so quiet runs must not rehabilitate it."""
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy)
    reg.record_false_positive("gemini.enable_deep_research", healthy_page=True)
    for _ in range(200):
        reg.record_execution("gemini.enable_deep_research")
    decision = reg.may_escalate("gemini.enable_deep_research")
    assert decision.allowed is False
    assert "poisoned" in decision.reason
    assert "rewrite it, do not tune it" in decision.reason


def test_the_poisoned_flag_blocks_a_bake_on_its_own():
    """Isolates the flag from the counter, which the registry always moves together.

    Constructed directly because `record_false_positive` sets both, so going through the public
    API cannot distinguish the two clauses — and an untested clause is one a refactor deletes.
    The flag is kept independent so that if the counter ever acquires a reset, a predicate that
    once fired on a healthy page still cannot bake.
    """
    counter_only = intents.BakeStatus(executions=999, false_positives=1, poisoned=False)
    assert counter_only.baked is False

    flag_only = intents.BakeStatus(executions=999, false_positives=0, poisoned=True)
    assert flag_only.baked is False, (
        "the poisoned flag must block a bake without help from the false-positive counter"
    )
    assert "poisoned" in flag_only.why_not_baked()

    clean = intents.BakeStatus(executions=999, false_positives=0, poisoned=False)
    assert clean.baked is True, "otherwise this test would pass for a gate that rejects all"


def test_shadow_only_forever_is_a_valid_resting_state(monkeypatch):
    """An intent with no positive off-signal is structurally shadow-only, by construction."""
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy, with_off=False)
    _bake(reg)
    decision = reg.may_escalate("gemini.enable_deep_research")
    assert decision.allowed is False
    assert "no positive off-signal" in decision.reason
    out = _run(reg, spy)
    assert spy.heals == 0


def test_an_irreversible_intent_is_structurally_shadow_only(monkeypatch):
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy, reversible=False)
    _bake(reg)
    decision = reg.may_escalate("gemini.enable_deep_research")
    assert "not marked reversible" in decision.reason


# ======================================================================================
# the confirmed_off gate — #709
# ======================================================================================


def test_an_unconfirmed_off_signal_refuses_the_action(monkeypatch):
    """The #709 guard. A false-negative predicate must not be allowed to toggle a live control.

    `confirmed_off` is a POSITIVE off-signal, not the inverse of the predicate: if it cannot
    confirm the thing is off, the safe move is to do nothing.
    """
    _arm(monkeypatch)
    spy = Spy(on=False, off_confirmed=False)
    reg = _registry(spy)
    _bake(reg)
    out = _run(reg, spy)
    assert spy.heals == 0, "acting here could switch a live control OFF"
    assert out.escalated is False
    assert "off-signal not positively confirmed" in out.reason
    assert "false negative" in out.reason


def test_an_off_signal_that_raises_also_refuses(monkeypatch):
    _arm(monkeypatch)

    async def boom():
        raise RuntimeError("off-probe broken")

    spy = Spy(on=False)
    reg = intents.IntentRegistry()
    reg.register(
        intents.Intent(
            id="x", platform="p", description="d",
            outcome_predicate=spy.predicate, confirmed_off=boom, reversible=True,
        )
    )
    for _ in range(intents.BAKE_MIN_RUNS):
        reg.record_execution("x")
    out = asyncio.run(intents.guarded_intent(reg, "x", spy.action, escalate=spy.heal))
    assert spy.heals == 0
    assert "off-signal not positively confirmed" in out.reason


# ======================================================================================
# escalation, when everything is satisfied
# ======================================================================================


def test_a_baked_reversible_intent_escalates_and_re_verifies(monkeypatch):
    _arm(monkeypatch)
    spy = Spy(on=False, heal_works=True)
    reg = _registry(spy)
    _bake(reg)
    out = _run(reg, spy)
    assert out.escalated is True
    assert spy.heals == 1
    assert out.healed is True
    assert out.reason == "escalated and verified"


def test_a_heal_that_ran_but_did_not_work_is_not_reported_as_healed(monkeypatch):
    """"The heal ran" is not "the heal worked"; only re-running the real predicate tells them apart."""
    _arm(monkeypatch)
    spy = Spy(on=False, heal_works=False)
    reg = _registry(spy)
    _bake(reg)
    out = _run(reg, spy)
    assert out.escalated is True
    assert spy.heals == 1
    assert out.healed is False
    assert out.predicate_passed is False
    assert "still failing" in out.reason


def test_an_escalator_that_raises_is_contained(monkeypatch):
    """The heal path must never raise into the pipeline; the normal failure path takes over."""
    _arm(monkeypatch)

    async def boom():
        raise RuntimeError("CUA blew up")

    spy = Spy(on=False)
    reg = _registry(spy)
    _bake(reg)
    out = asyncio.run(
        intents.guarded_intent(reg, "gemini.enable_deep_research", spy.action, escalate=boom)
    )
    assert out.escalated is True
    assert out.healed is False
    assert "escalator raised" in out.reason


def test_escalation_permitted_but_no_escalator_is_reported_honestly(monkeypatch):
    _arm(monkeypatch)
    spy = Spy(on=False)
    reg = _registry(spy)
    _bake(reg)
    out = asyncio.run(
        intents.guarded_intent(reg, "gemini.enable_deep_research", spy.action, escalate=None)
    )
    assert out.escalated is False
    assert "no escalator supplied" in out.reason


# ======================================================================================
# registry hygiene and telemetry
# ======================================================================================


def test_a_duplicate_registration_is_refused():
    spy = Spy()
    reg = _registry(spy)
    with pytest.raises(ValueError, match="already registered"):
        reg.register(
            intents.Intent(
                id="gemini.enable_deep_research", platform="g", description="d",
                outcome_predicate=spy.predicate,
            )
        )


def test_an_unknown_intent_fails_loudly():
    reg = intents.IntentRegistry()
    with pytest.raises(KeyError, match="no intent registered"):
        reg.get("nope")


def test_a_failing_shadow_sink_never_breaks_the_pipeline(monkeypatch):
    _arm(monkeypatch, act=False)

    def bad_sink(_rec):
        raise RuntimeError("disk full")

    spy = Spy(on=True)
    reg = _registry(spy, sink=bad_sink)
    out = _run(reg, spy)  # must not raise
    assert out.predicate_passed is True


def test_the_shadow_record_carries_enough_to_be_telemetry_on_its_own(monkeypatch):
    _arm(monkeypatch, act=False)
    records = []
    spy = Spy(on=False)
    reg = _registry(spy, sink=records.append)
    _run(reg, spy)
    rec = records[0]
    assert set(rec) >= {"intent", "outcome_pass", "escalated", "healed", "shadow_only", "reason"}
    assert rec["intent"] == "gemini.enable_deep_research"


def test_the_execution_ledger_counts_the_action_even_on_the_happy_path(monkeypatch):
    """Bake volume accrues from executions, so a passing run must still count."""
    _arm(monkeypatch, act=False)
    spy = Spy(on=True)
    reg = _registry(spy)
    _run(reg, spy)
    _run(reg, spy)
    assert reg.bake("gemini.enable_deep_research").executions == 2


def test_sync_predicates_and_actions_are_accepted(monkeypatch):
    """The orchestrator has both; forcing everything async would be needless friction."""
    _arm(monkeypatch, act=False)
    state = {"on": True, "ran": 0}

    def action():
        state["ran"] += 1

    def predicate():
        return state["on"]

    reg = intents.IntentRegistry()
    reg.register(
        intents.Intent(id="s", platform="p", description="d", outcome_predicate=predicate)
    )
    out = asyncio.run(intents.guarded_intent(reg, "s", action))
    assert state["ran"] == 1
    assert out.predicate_passed is True


# ======================================================================================
# the acceptance window
#
# ⚠ Verification used to be a SINGLE evaluation taken the instant the action returned. That is right
# for the mock, whose DOM updates synchronously on click, and wrong for every real platform — which is
# exactly why it survived every gate until a real page ran. Measured on live ChatGPT in ONE run: the
# deep-research toggle turned on (menu self-closed, composer grew its "Deep research" pill) and the
# predicate asked immediately said false; and send was accepted, the answer arrived, and the predicate
# asked immediately found no assistant turn yet. Both reported predicate_passed=False for actions that
# had plainly worked.
#
# A false negative on a HEALTHY page is worse than a crash: with acting enabled it escalates an agent
# onto the one page that needed no help. The backend has paid for this once already — its own comment
# records a pressed-class-only check false-negativing an ACTIVE pill, after which the CUA fallback
# toggled the working deep research back OFF.
# ======================================================================================


class LateSpy(Spy):
    """A toggle whose predicate only reports true after N consultations — a render tick."""

    def __init__(self, becomes_true_on=3, **kw):
        super().__init__(**kw)
        self.becomes_true_on = becomes_true_on
        self.predicate_calls = 0

    async def predicate(self):
        self.predicate_calls += 1
        return self.predicate_calls >= self.becomes_true_on


def test_a_predicate_that_needs_a_render_tick_still_passes(monkeypatch):
    _arm(monkeypatch)
    spy = LateSpy(becomes_true_on=3)
    reg = _registry(spy)
    outcome = _run(reg, spy, acceptance_window=5.0, poll=0.05)
    assert outcome.predicate_passed is True
    assert spy.predicate_calls >= 3, "the window must have re-asked, not accepted the first answer"
    assert spy.heals == 0, "and it must NOT have escalated onto a page that was merely slow"


def test_the_window_returns_EARLY_and_is_not_a_fixed_delay(monkeypatch):
    """Otherwise every mock gate pays five seconds per intent for nothing."""
    import time as _t

    _arm(monkeypatch)
    spy = Spy(on=True)  # passes on the first ask, as the mock does
    reg = _registry(spy)
    started = _t.monotonic()
    outcome = _run(reg, spy, acceptance_window=5.0, poll=0.25)
    assert outcome.predicate_passed is True
    assert _t.monotonic() - started < 1.0, "a passing predicate must not wait out the window"


def test_a_predicate_that_never_passes_still_fails_after_the_window(monkeypatch):
    """The window is an upper bound on patience, not an escape from the verdict."""
    _arm(monkeypatch)
    spy = Spy(on=False, heal_works=False)
    reg = _registry(spy)
    _bake(reg)
    outcome = _run(reg, spy, acceptance_window=0.4, poll=0.05)
    assert outcome.predicate_passed is False
    assert spy.heals == 1, "a genuinely failed intent must still reach its escalation decision"


def test_the_execution_LEDGER_counts_the_action_once_however_many_polls_it_took(monkeypatch):
    """The ledger records that the intent RAN. Counting polls would let one slow action look baked."""
    _arm(monkeypatch)
    spy = LateSpy(becomes_true_on=4)
    reg = _registry(spy)
    _run(reg, spy, acceptance_window=5.0, poll=0.05)
    assert reg.bake("gemini.enable_deep_research").executions == 1
    assert spy.predicate_calls >= 4


def test_a_RAISING_predicate_breaks_out_instead_of_burning_the_window(monkeypatch):
    """A broken predicate raises again on every retry, and it is already treated as a pass.

    Spending the full window on it would add latency to every intent whose predicate has a bug, for no
    change in outcome.
    """
    import time as _t

    _arm(monkeypatch)

    class Boom(Spy):
        def __init__(self):
            super().__init__()
            self.calls = 0

        async def predicate(self):
            self.calls += 1
            raise RuntimeError("selector syntax error")

    spy = Boom()
    reg = _registry(spy)
    started = _t.monotonic()
    outcome = _run(reg, spy, acceptance_window=5.0, poll=0.05)
    assert outcome.predicate_passed is True and outcome.shadow_only is True
    assert _t.monotonic() - started < 1.0
    assert spy.calls == 1, "asked once, not repeatedly"
