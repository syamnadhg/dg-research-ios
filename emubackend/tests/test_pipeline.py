"""The run loop, driven end to end against a fake substrate.

This is the closest thing to an e2e that exists for this pipeline: a complete P0–P3 sequence runs,
its Firestore write sequence is captured, and the sequence is asserted — order included. The
browser work is injected, so the loop is verified without needing real platform DOM, which is the
whole point of the fixture engine per §0.5.7b.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from emubackend import pipeline
from emubackend.contract import fixtures, pending_decision as pd, rest
from emubackend.controls import RunControls

BASE = datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc)


class _Resp:
    status_code = 200
    ok = True
    content = b"{}"

    def json(self):
        return {}


def _ctx(**kw):
    capture = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=capture)
    ticks = iter(range(1, 10_000))
    ctx = pipeline.RunContext(
        uid="uid-a",
        research_id="rid-b",
        device_id="dev-1",
        run_id="run-9",
        client=client,
        now=lambda: BASE + timedelta(seconds=next(ticks)),
        **kw,
    )
    return ctx, capture


def _phases(record=None, bodies=None):
    record = record if record is not None else []

    def make(n):
        def body(ctx):
            record.append(n)
            if bodies and n in bodies:
                return bodies[n](ctx)
            return None

        return body

    return [pipeline.Phase(number=n, name=f"P{n}", body=make(n)) for n in range(4)], record


def _events(capture):
    """(type, phase) for each pipeline_events write, in order."""
    out = []
    for rec in capture.records:
        if rec.op == "create" and rec.path.endswith("pipeline_events"):
            out.append((rec.fields.get("type"), rec.fields.get("phase")))
    return out


# ======================================================================================
# a complete run
# ======================================================================================


def test_a_full_p0_to_p3_run_emits_the_expected_sequence():
    ctx, capture = _ctx()
    phases, record = _phases()
    result = asyncio.run(pipeline.run_pipeline(ctx, phases))

    assert result.status == "complete"
    assert record == [0, 1, 2, 3], "every phase body ran, in order"
    assert _events(capture) == [
        ("phase_start", 0), ("phase_complete", 0),
        ("phase_start", 1), ("phase_complete", 1),
        ("phase_start", 2), ("phase_complete", 2),
        ("phase_start", 3), ("phase_complete", 3),
        ("pipeline_complete", None),
    ]
    assert [p.status for p in result.phases] == ["complete"] * 4


def test_the_run_flips_to_ongoing_then_complete():
    ctx, capture = _ctx()
    phases, _ = _phases()
    asyncio.run(pipeline.run_pipeline(ctx, phases))
    patches = [r for r in capture.records if r.op == "patch"]
    assert patches[0].fields["status"] == "ongoing"
    assert patches[0].fields["backendRunId"] == "run-9"
    assert patches[-1].fields["status"] == "complete"


def test_phase_zero_is_emitted_as_phase_zero_not_omitted():
    """P0 is a real phase; a truthiness guard anywhere in the chain would erase it."""
    ctx, capture = _ctx()
    phases, _ = _phases()
    asyncio.run(pipeline.run_pipeline(ctx, phases))
    assert ("phase_start", 0) in _events(capture)


def test_seq_strictly_increases_across_the_whole_run():
    """The frontend consumes with `seq > lastSeq`; a repeat drops an event silently."""
    ctx, capture = _ctx()
    phases, _ = _phases()
    asyncio.run(pipeline.run_pipeline(ctx, phases))
    seqs = [
        r.fields["seq"]
        for r in capture.records
        if r.op == "create" and r.path.endswith("pipeline_events")
    ]
    assert seqs == sorted(seqs)
    assert len(seqs) == len(set(seqs))


# ======================================================================================
# the startup patch
# ======================================================================================


def test_a_non_queued_start_wipes_the_decision_slot_in_the_same_patch():
    """Otherwise there is a window where a new run is visible alongside the previous run's card."""
    ctx, capture = _ctx()
    pipeline.start_patch(ctx, queued=False)
    rec = capture.records[0]
    assert rec.op == "patch"
    assert set(rec.fields) == {"status", "backendRunId"}
    assert rec.delete_paths == ["pendingDecision"], "same patch, as a field delete"


def test_a_queued_start_deliberately_does_not_wipe_the_slot():
    """A queued run has not started, so the card it would erase belongs to the running one."""
    ctx, capture = _ctx()
    pipeline.start_patch(ctx, queued=True)
    rec = capture.records[0]
    assert rec.fields["status"] == "queued"
    assert rec.delete_paths == []


# ======================================================================================
# stop / pause / skip
# ======================================================================================


def test_a_stop_before_a_phase_ends_the_run_and_emits_pipeline_stopped():
    controls = RunControls()
    ctx, capture = _ctx(controls=controls)
    record = []
    phases, _ = _phases(record)

    def stopper(_ctx):
        controls.request_stop()

    phases[1] = pipeline.Phase(number=1, name="P1", body=stopper)
    result = asyncio.run(pipeline.run_pipeline(ctx, phases))

    assert result.status == "stopped"
    assert ("pipeline_stopped", 2) in _events(capture)
    assert 3 not in record, "no phase runs after a stop"
    assert capture.records[-1].fields["status"] == "stopped"


def test_a_stop_takes_precedence_over_a_queued_phase_skip():
    """The stop check runs BEFORE the skip check, and that order is the whole point of it.

    Without it, a run the operator stopped would still emit `phase_skipped` for a phase that was
    queued for skip — reporting work as *skipped* when the run was *ended*. The two are different
    outcomes to a reader of the event stream, and only one of them is true.

    This is the only case that distinguishes the pre-check from the pause gate, which also
    catches a stop (`wait_while_paused` returns `not stopped`). Found by bin/mutate.py.
    """
    controls = RunControls()
    controls.request_stop()
    controls.skipped_phases.add(0)
    ctx, capture = _ctx(controls=controls)
    phases, record = _phases()
    result = asyncio.run(pipeline.run_pipeline(ctx, phases))

    assert result.status == "stopped"
    assert record == [], "no phase body ran"
    seq = _events(capture)
    assert ("pipeline_stopped", 0) in seq
    assert ("phase_skipped", 0) not in seq, (
        "a stopped run must not report a phase as skipped — the run was ended, not skipped"
    )


def test_a_stop_during_a_park_takes_effect_at_the_park():
    """A stop that only lands after a long pause would leave the operator waiting for the park."""
    controls = RunControls()
    controls.request_pause()
    ctx, capture = _ctx(controls=controls)
    phases, record = _phases()

    async def scenario():
        async def stopper():
            await asyncio.sleep(0.05)
            controls.request_stop()

        task = asyncio.create_task(stopper())
        res = await pipeline.run_pipeline(ctx, phases)
        await task
        return res

    result = asyncio.run(scenario())
    assert result.status == "stopped"
    assert "while paused" in result.detail
    assert record == [], "no phase body ran"


def test_a_pause_then_resume_lets_the_run_continue():
    controls = RunControls()
    controls.request_pause()
    ctx, _capture = _ctx(controls=controls)
    phases, record = _phases()

    async def scenario():
        async def resumer():
            await asyncio.sleep(0.05)
            controls.request_resume()

        task = asyncio.create_task(resumer())
        res = await pipeline.run_pipeline(ctx, phases)
        await task
        return res

    assert asyncio.run(scenario()).status == "complete"
    assert record == [0, 1, 2, 3]


def test_phase_start_is_emitted_after_the_pause_gate_not_before():
    """Emitting first renders a running tile for a parked phase, and it never updates."""
    controls = RunControls()
    controls.request_pause()
    ctx, capture = _ctx(controls=controls)
    phases, _ = _phases()

    async def scenario():
        async def watcher():
            await asyncio.sleep(0.05)
            # While parked, nothing may have been emitted yet.
            assert _events(capture) == [], "a parked phase must not have announced itself"
            controls.request_stop()

        task = asyncio.create_task(watcher())
        res = await pipeline.run_pipeline(ctx, phases)
        await task
        return res

    asyncio.run(scenario())


def test_a_skipped_phase_emits_phase_skipped_and_no_start_complete_pair():
    """A frontend counting starts against completes would otherwise never see the run finish."""
    controls = RunControls()
    controls.skipped_phases.add(2)
    ctx, capture = _ctx(controls=controls)
    phases, record = _phases()
    result = asyncio.run(pipeline.run_pipeline(ctx, phases))

    assert result.status == "complete"
    assert 2 not in record, "a skipped phase's body must not run"
    seq = _events(capture)
    assert ("phase_skipped", 2) in seq
    assert ("phase_start", 2) not in seq
    assert ("phase_complete", 2) not in seq
    assert [p.status for p in result.phases] == ["complete", "complete", "skipped", "complete"]


# ======================================================================================
# failure
# ======================================================================================


def test_a_raising_phase_becomes_a_pipeline_error_with_user_actions():
    """A phase failure is data the operator acts on, not a crash that loses the run record."""
    ctx, capture = _ctx()
    phases, _ = _phases()

    def boom(_ctx):
        raise RuntimeError("composer never appeared")

    phases[2] = pipeline.Phase(number=2, name="P2", body=boom)
    result = asyncio.run(pipeline.run_pipeline(ctx, phases))

    assert result.status == "failed"
    assert "composer never appeared" in result.detail
    errors = [
        r for r in capture.records
        if r.op == "create" and r.fields.get("type") == "pipeline_error"
    ]
    assert len(errors) == 1
    assert errors[0].fields["data"]["actions"] == ["retry", "skip"]
    assert errors[0].fields["phase"] == 2


def test_a_failed_run_emits_no_pipeline_complete():
    ctx, capture = _ctx()
    phases, _ = _phases()
    phases[1] = pipeline.Phase(
        number=1, name="P1", body=lambda _c: (_ for _ in ()).throw(RuntimeError("x"))
    )
    asyncio.run(pipeline.run_pipeline(ctx, phases))
    assert ("pipeline_complete", None) not in _events(capture)


# ======================================================================================
# the pendingDecision clear seam
# ======================================================================================


def test_a_resolving_event_clears_the_decision_slot_as_a_field_delete():
    ctx, capture = _ctx()
    ctx.pending = pd.PendingState(active=True, agent="gemini")
    pipeline.emit_event(ctx, "phase_restart", phase=1)
    deletes = [r for r in capture.records if r.op == "patch" and r.delete_paths]
    assert deletes and deletes[0].delete_paths == ["pendingDecision"]
    assert ctx.pending.active is False


def test_a_non_resolving_event_leaves_the_slot_alone():
    ctx, capture = _ctx()
    ctx.pending = pd.PendingState(active=True, agent="gemini")
    pipeline.emit_event(ctx, "phase_start", phase=1)
    assert [r for r in capture.records if r.op == "patch"] == []
    assert ctx.pending.active is True


def test_an_agent_scoped_clear_respects_the_keep_guard():
    """AgentA's late clear must not delete AgentB's live card — the cross-agent clobber."""
    ctx, capture = _ctx()
    ctx.pending = pd.PendingState(active=True, agent="agentb")
    pipeline.emit_event(ctx, "agent_skipped", agent="AgentA")
    assert [r for r in capture.records if r.op == "patch"] == [], "no clear was issued"
    assert ctx.pending.agent == "agentb", "B's card survives"


def test_the_owning_agents_clear_does_go_through():
    ctx, capture = _ctx()
    ctx.pending = pd.PendingState(active=True, agent="agentb")
    pipeline.emit_event(ctx, "agent_skipped", agent="AgentB")
    assert [r for r in capture.records if r.op == "patch" and r.delete_paths]


def test_phase_restart_clears_unconditionally_even_with_an_agent():
    """Retry emits phase_restart and NOT pipeline_resumed, so scoping it strands the card."""
    ctx, capture = _ctx()
    ctx.pending = pd.PendingState(active=True, agent="agentb")
    pipeline.emit_event(ctx, "phase_restart", agent="AgentA", phase=1)
    assert [r for r in capture.records if r.op == "patch" and r.delete_paths]


# ======================================================================================
# the claim integration
# ======================================================================================


def test_a_worker_takes_and_releases_its_lock(tmp_path):
    from emubackend import claim

    ctx, _capture = _ctx()
    phases, _ = _phases()
    result = asyncio.run(
        pipeline.run_pipeline(ctx, phases, worker_id=1, lock_dir=tmp_path / "q")
    )
    assert result.status == "complete"
    assert claim.read_lock(1, tmp_path / "q") is None, "the lock must be released"


def test_the_lock_is_released_even_when_the_run_fails(tmp_path):
    """A retained lock makes the next claim look like a live sibling and wedges the device."""
    from emubackend import claim

    ctx, _capture = _ctx()
    phases, _ = _phases()
    phases[0] = pipeline.Phase(
        number=0, name="P0", body=lambda _c: (_ for _ in ()).throw(RuntimeError("x"))
    )
    result = asyncio.run(
        pipeline.run_pipeline(ctx, phases, worker_id=1, lock_dir=tmp_path / "q")
    )
    assert result.status == "failed"
    assert claim.read_lock(1, tmp_path / "q") is None


# ======================================================================================
# the golden fixture — the mechanical contract check
# ======================================================================================

TOKENS = {"uid-a": "{uid}", "rid-b": "{rid}", "dev-1": "{deviceId}", "run-9": "{runId}"}


def _normalised_run(**kw):
    ctx, capture = _ctx(**kw)
    phases, _ = _phases()
    asyncio.run(pipeline.run_pipeline(ctx, phases))
    return [fixtures.normalize(r, tokens=TOKENS) for r in capture.records]


def test_two_identical_runs_normalise_to_the_same_write_sequence():
    """The property the whole fixture approach rests on: without it the suite fails every run."""
    assert fixtures.compare(_normalised_run(), _normalised_run()) == []


def test_the_golden_fixture_round_trips_and_matches_a_fresh_run(tmp_path):
    golden = _normalised_run()
    path = fixtures.save_fixture(tmp_path / "p0p3.jsonl", golden)
    assert fixtures.compare(fixtures.load_fixture(path), _normalised_run()) == []


def test_a_changed_run_shape_is_caught_by_the_fixture():
    """The point of the fixture: a divergence in the write sequence is reported, not tolerated."""
    golden = _normalised_run()
    controls = RunControls()
    controls.skipped_phases.add(1)
    diverged = _normalised_run(controls=controls)
    diffs = fixtures.compare(golden, diverged)
    assert diffs, "skipping a phase changes the sequence and must be reported"
    assert any("phase" in d.detail or d.kind == "field-value" for d in diffs)


def test_the_captured_sequence_covers_reads_writes_and_the_terminal_status():
    golden = _normalised_run()
    ops = [r.op for r in golden]
    paths = {r.path for r in golden}
    assert ops[0] == "patch", "the run starts with the status/backendRunId patch"
    assert ops[-1] == "patch", "and ends with the terminal status patch"
    assert "users/{uid}/researches/{rid}/pipeline_events" in paths
    assert "users/{uid}/researches/{rid}" in paths


def test_the_fixture_is_stable_against_the_volatile_fields():
    """seq/timestamp/expireAt differ every run; the fixture must not.

    Asserted explicitly because it is the one property whose failure makes the suite worthless
    rather than merely wrong.
    """
    golden = _normalised_run()
    ev = next(r for r in golden if r.path.endswith("pipeline_events"))
    assert ev.fields["seq"] == "<int>"
    assert ev.fields["timestamp"] == "<int>"
    assert ev.fields["expireAt"] == "<iso8601>"
    assert ev.fields["deviceId"] == "{deviceId}", "identifiers are tokenised, not markered"
