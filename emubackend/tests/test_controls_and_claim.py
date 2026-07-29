"""Tests for the orchestration invariants — the "months of production fixes" material.

Each test names the incident or the silent failure it prevents. That framing is the point: these
invariants look arbitrary without it, and an invariant whose reason is lost is one the next
refactor deletes.
"""

from __future__ import annotations

import asyncio
import json
import os

import pytest

from emubackend import claim
from emubackend.controls import RunControls, SkipOrigin

# ======================================================================================
# stop / pause / resume
# ======================================================================================


def test_pause_then_resume_round_trips():
    c = RunControls()
    assert c.paused is False
    c.request_pause()
    assert c.paused is True
    c.request_resume()
    assert c.paused is False


def test_resume_must_not_revive_a_stopped_run():
    """Stop is terminal. A Resume tap on a card the stop already invalidated would otherwise

    restart work the operator deliberately ended — and the symptom is a duplicated run.

    Two independent guards protect this, so both are asserted separately: `paused` accounts for
    the stop, AND `request_resume` refuses outright. Checking only `paused` leaves the second
    guard unobservable — the resume signal itself would still be raised, and anything reading
    `resume_event` to decide whether to continue would proceed. (Found by bin/mutate.py.)
    """
    c = RunControls()
    c.request_pause()
    c.request_stop()
    c.request_resume()
    assert c.stopped is True
    assert c.paused is False, "a stopped run is not paused"
    assert c.resume_event.is_set() is False, (
        "a stopped run must never raise the resume signal — a consumer watching resume_event "
        "would take it as permission to continue"
    )
    assert c.pause_event.is_set() is True, (
        "and the stopped run's pause must not be silently cleared either"
    )


def test_a_pause_on_a_stopped_run_is_a_no_op():
    c = RunControls()
    c.request_stop()
    c.request_pause()
    assert c.paused is False


def test_wait_while_paused_returns_false_when_stopped_mid_wait():
    """The caller's own control flow decides what a stop means at that point in the phase."""
    c = RunControls()
    c.request_pause()

    async def scenario():
        async def stopper():
            await asyncio.sleep(0.05)
            c.request_stop()

        task = asyncio.create_task(stopper())
        result = await c.wait_while_paused()
        await task
        return result

    assert asyncio.run(scenario()) is False


def test_wait_while_paused_returns_true_on_a_normal_resume():
    c = RunControls()
    c.request_pause()

    async def scenario():
        async def resumer():
            await asyncio.sleep(0.05)
            c.request_resume()

        task = asyncio.create_task(resumer())
        result = await c.wait_while_paused()
        await task
        return result

    assert asyncio.run(scenario()) is True


# ======================================================================================
# the overloaded skip set — the 2026-07-11 incident
# ======================================================================================


def test_only_a_real_tap_counts_as_a_user_skip():
    """The incident: stamping every skipped_agents member as a user skip reported an agent whose

    brief never sent as a *user decision*, and since agent_skipped is in the pendingDecision clear
    set, the emit retracted the honest Retry/Skip card about four seconds after it was raised.
    """
    c = RunControls()
    c.request_skip_agent("ChatGPT", origin=SkipOrigin.USER_TAP)
    c.request_skip_agent("Gemini", origin=SkipOrigin.INTERNAL, reason="brief never sent")

    assert c.skipped_agents == {"chatgpt", "gemini"}, "both are queued for skip"
    assert c.is_user_skip("chatgpt") is True
    assert c.is_user_skip("gemini") is False, (
        "an internal marker must never be reported to the frontend as a user decision"
    )


def test_the_honest_reason_is_preserved_for_an_internal_skip():
    c = RunControls()
    c.request_skip_agent("gemini", origin=SkipOrigin.INTERNAL, reason="2B setup failed")
    assert c.skip_reason("gemini") == "2B setup failed"
    assert c.skip_reason("nobody") == "skipped internally"


def test_a_user_skip_reports_itself_as_such():
    c = RunControls()
    c.request_skip_agent("claude")
    assert c.skip_reason("claude") == "skipped by user"


def test_an_hv_auto_skip_is_marked_internal_not_a_user_tap():
    """It must not re-emit or re-close a tab the HV finalize already greyed and closed."""
    c = RunControls()
    c.request_skip_agent("claude", origin=SkipOrigin.HV_AUTO, reason="Cloudflare")
    assert c.skip_origin("claude") == SkipOrigin.HV_AUTO
    assert c.is_user_skip("claude") is False
    assert "claude" in c.hv_auto_skipped


def test_skip_origin_is_none_for_an_agent_that_was_never_skipped():
    assert RunControls().skip_origin("nobody") is None


def test_consuming_a_skip_clears_every_parallel_marker():
    """A leftover marker silently applies to the next tick, which is how a skip repeats."""
    c = RunControls()
    c.request_skip_agent("gemini", origin=SkipOrigin.HV_AUTO, reason="Cloudflare")
    assert c.consume_skip("gemini") == SkipOrigin.HV_AUTO
    assert c.skipped_agents == set()
    assert c.hv_auto_skipped == set()
    assert c.auto_skip_reasons == {}
    assert c.consume_skip("gemini") is None, "consuming twice must be harmless"


def test_agent_keys_are_case_insensitive_throughout():
    c = RunControls()
    c.request_skip_agent("ChatGPT")
    assert c.is_user_skip("chatgpt") and c.is_user_skip("CHATGPT")
    assert c.consume_skip("ChatGpt") == SkipOrigin.USER_TAP


def test_phase_skips_are_tracked_separately_from_agent_skips():
    c = RunControls()
    c.skipped_phases.add(2)
    assert c.is_phase_skip_requested(2) is True
    assert c.is_phase_skip_requested(1) is False


# ======================================================================================
# decision routing — scoped vs global
# ======================================================================================


def test_a_targeted_decision_cannot_be_stolen_by_another_agents_park():
    """The non-blocking park consumes agent-scoped, or a decision meant for one card is taken by

    a different agent's simultaneous park.
    """
    c = RunControls()
    c.set_agent_decision("retry", "gemini")
    assert c.poll_agent_decision("chatgpt") is None, "not addressed to chatgpt"
    assert c.pending_agent_decision == "retry", "and it must still be there for its target"
    assert c.poll_agent_decision("gemini") == "retry"
    assert c.pending_agent_decision is None


def test_an_agentless_decision_is_legacy_global_and_anyone_may_take_it():
    c = RunControls()
    c.set_agent_decision("skip")
    assert c.poll_agent_decision("anyone") == "skip"


def test_the_blocking_gate_pops_globally_whatever_it_targets():
    """The blocking gate is serialized, so only one mirror is ever live — scoping it would be a

    no-op there and would strand an agent-targeted decision.
    """
    c = RunControls()
    c.set_agent_decision("stop", "gemini")
    assert c.pop_agent_decision() == "stop"
    assert c.pending_agent_decision is None
    assert c.pending_agent_decision_agent == ""


def test_polling_an_empty_slot_returns_none():
    assert RunControls().poll_agent_decision("gemini") is None


# ======================================================================================
# watchdog accounting
# ======================================================================================


def test_waiting_on_a_human_does_not_count_as_active_time():
    """Otherwise a legitimate wait for the user gets killed by the watchdog as "stuck"."""
    c = RunControls()
    assert c.counts_toward_active_time() is True
    c.begin_awaiting_user()
    assert c.counts_toward_active_time() is False
    c.end_awaiting_user()
    assert c.counts_toward_active_time() is True


def test_reset_clears_awaiting_user_or_the_next_runs_watchdog_never_fires():
    """The nastiest of the four: a stale True means the next run's active time never accrues, so

    its watchdog never fires at all. The failure is the ABSENCE of a safety net — nothing reports
    it, and the run simply hangs forever.
    """
    c = RunControls()
    c.begin_awaiting_user()
    c.reset()
    assert c.awaiting_user is False
    assert c.counts_toward_active_time() is True


def test_reset_returns_everything_to_a_clean_state():
    c = RunControls()
    c.request_pause()
    c.request_stop()
    c.begin_awaiting_user()
    c.set_agent_decision("retry", "gemini")
    c.request_skip_agent("chatgpt")
    c.skipped_phases.add(2)
    c.cookie_trust_broken.add("claude")
    c.login_pause_timeout_agents.add("gemini")
    c.hv_blocked["claude"] = "Cloudflare"
    c.skip_init_verify = True
    c.retry_init_verify = True
    c.extra_context.append("x")

    c.reset()

    assert not c.stopped and not c.paused
    assert c.pending_agent_decision is None and c.pending_agent_decision_agent == ""
    assert c.skipped_agents == set() and c.user_skip_taps == set()
    assert c.skipped_phases == set() and c.cookie_trust_broken == set()
    assert c.login_pause_timeout_agents == set() and c.hv_blocked == {}
    assert c.skip_init_verify is False and c.retry_init_verify is False
    assert c.extra_context == []


# ======================================================================================
# the claim sentinel — the dual-spawn repro
# ======================================================================================


def test_the_lock_dir_inside_a_guarded_repo_is_refused(tmp_path):
    """The backend's own constant points at its checkout, so copying the protocol faithfully and

    forgetting to reparameterise the path is the natural mistake — and it writes into a directory
    the production daemon's disk-restore scans.
    """
    bad = tmp_path / "dg-research-backend" / "queues"
    with pytest.raises(claim.ClaimError) as exc:
        claim.lock_path(1, bad)
    assert "A8 forbids" in str(exc.value)
    assert "disk-restore scans" in str(exc.value)


def test_the_frontend_repo_is_refused_too(tmp_path):
    with pytest.raises(claim.ClaimError):
        claim.lock_path(1, tmp_path / "dg-research" / "queues")


def test_the_lock_layout_is_flat_not_per_run(tmp_path):
    """Per-run would be invisible during exactly the window it must be seen: the per-run dir is

    created at dequeue, not at claim, and a sibling checking it between the two sees nothing.
    """
    path = claim.lock_path(3, tmp_path / "q")
    assert path.name == ".worker.3.lock"
    assert path.parent == tmp_path / "q", "no run-id segment"


def test_a_lock_round_trips(tmp_path):
    lock = claim.write_lock(1, "research-a", "run-1", lock_dir=tmp_path / "q")
    read = claim.read_lock(1, tmp_path / "q")
    assert read == lock
    assert read.pid == os.getpid()


def test_a_lock_is_written_atomically(tmp_path):
    """A sibling must never read a half-written lock, so no .tmp may survive."""
    claim.write_lock(1, "r", "run", lock_dir=tmp_path / "q")
    leftovers = list((tmp_path / "q").glob("*.tmp"))
    assert leftovers == []


def test_a_corrupt_lock_is_treated_as_absent(tmp_path):
    """Refusing to claim on a corrupt file would wedge the worker permanently — worse than the

    dual-spawn risk, which the PID and age checks would have caught anyway.
    """
    d = tmp_path / "q"
    d.mkdir()
    (d / ".worker.1.lock").write_text("{not json")
    assert claim.read_lock(1, d) is None


def test_release_is_idempotent(tmp_path):
    claim.write_lock(1, "r", "run", lock_dir=tmp_path / "q")
    assert claim.release_lock(1, tmp_path / "q") is True
    assert claim.release_lock(1, tmp_path / "q") is False


def test_a_siblings_live_lock_blocks_the_claim(tmp_path):
    """The repro, directly: worker 2 owns the research, so worker 1 must not also run it."""
    d = tmp_path / "q"
    claim.write_lock(2, "research-a", "run-9", lock_dir=d)
    allowed, why = claim.may_claim(
        "research-a", self_worker_id=1, worker_ids=[1, 2], lock_dir=d, pid_alive=lambda _p: True
    )
    assert allowed is False
    assert "worker 2 already owns" in why


def test_our_own_lock_does_not_block_us(tmp_path):
    """That is the resume case, not a conflict."""
    d = tmp_path / "q"
    claim.write_lock(1, "research-a", "run-9", lock_dir=d)
    allowed, _ = claim.may_claim(
        "research-a", self_worker_id=1, worker_ids=[1, 2], lock_dir=d, pid_alive=lambda _p: True
    )
    assert allowed is True


def test_a_lock_on_a_different_research_does_not_block(tmp_path):
    d = tmp_path / "q"
    claim.write_lock(2, "research-b", "run-9", lock_dir=d)
    allowed, why = claim.may_claim(
        "research-a", self_worker_id=1, worker_ids=[1, 2], lock_dir=d, pid_alive=lambda _p: True
    )
    assert allowed is True
    assert "no sibling" in why


def test_a_dead_pid_makes_the_lock_stale(tmp_path):
    d = tmp_path / "q"
    claim.write_lock(2, "research-a", "run-9", lock_dir=d)
    allowed, why = claim.may_claim(
        "research-a", self_worker_id=1, worker_ids=[1, 2], lock_dir=d, pid_alive=lambda _p: False
    )
    assert allowed is True
    assert "not running" in why


def test_a_live_pid_with_an_ancient_claim_is_a_recycled_pid_not_a_live_claim(tmp_path):
    """PID liveness alone cannot tell the two apart, and a recycled PID would otherwise read as

    "a sibling owns this" forever, wedging the worker.
    """
    d = tmp_path / "q"
    claim.write_lock(2, "research-a", "run-9", lock_dir=d, now_ms=0)
    allowed, why = claim.may_claim(
        "research-a",
        self_worker_id=1,
        worker_ids=[1, 2],
        lock_dir=d,
        now_ms=claim.PID_REUSE_MAX_AGE_MS + 1,
        pid_alive=lambda _p: True,
    )
    assert allowed is True
    assert "recycled PID" in why


def test_a_recent_claim_by_a_live_pid_is_respected(tmp_path):
    d = tmp_path / "q"
    claim.write_lock(2, "research-a", "run-9", lock_dir=d, now_ms=1_000_000)
    allowed, _ = claim.may_claim(
        "research-a",
        self_worker_id=1,
        worker_ids=[1, 2],
        lock_dir=d,
        now_ms=1_000_000 + 5_000,
        pid_alive=lambda _p: True,
    )
    assert allowed is False


def test_the_age_guard_is_eight_hours():
    assert claim.PID_REUSE_MAX_AGE_MS == 8 * 60 * 60 * 1000


def test_pid_liveness_treats_a_permission_error_as_alive():
    """Another user's process with that pid still exists, which is all the check asks."""
    assert claim._pid_alive(os.getpid()) is True
    assert claim._pid_alive(-1) is False


def test_a_refusal_always_explains_itself(tmp_path):
    """"Did not claim" with no reason is indistinguishable from a bug."""
    d = tmp_path / "q"
    claim.write_lock(2, "research-a", "run-9", lock_dir=d)
    _allowed, why = claim.may_claim(
        "research-a", self_worker_id=1, worker_ids=[1, 2], lock_dir=d, pid_alive=lambda _p: True
    )
    assert why and len(why) > 20


def test_write_lock_records_pid_and_start_time(tmp_path):
    d = tmp_path / "q"
    claim.write_lock(1, "r", "run", lock_dir=d, now_ms=12345)
    raw = json.loads((d / ".worker.1.lock").read_text())
    assert raw["pid"] == os.getpid()
    assert raw["started_at_ms"] == 12345
    assert raw["research_id"] == "r" and raw["run_id"] == "run"
