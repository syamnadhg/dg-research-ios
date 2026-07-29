"""Tests for the golden-fixture capture/replay engine.

The engine's whole value rests on getting normalisation right in both directions: too strict and
it fails on every run so the suite gets abandoned; too loose and it passes a broken
reimplementation. Both halves are asserted here.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from emubackend.contract import events, fixtures, rest, values

WR = fixtures.WriteRecord


def _norm(rec, **kw):
    return fixtures.normalize(rec, **kw)


# ======================================================================================
# normalisation: stable enough to pass twice, strict enough to catch a defect
# ======================================================================================


def test_volatile_values_become_type_markers_so_two_runs_agree():
    """seq/timestamp are epoch millis. Comparing them raw fails every single run."""
    a = _norm(WR(op="create", path="p", fields={"seq": 1785319607000, "type": "phase_start"}))
    b = _norm(WR(op="create", path="p", fields={"seq": 1785319999999, "type": "phase_start"}))
    assert a.fields == b.fields
    assert a.fields["seq"] == "<int>"


def test_a_volatile_field_that_changes_TYPE_still_fails():
    """The marker keeps the assertion meaningful: int millis becoming a string is a real bug."""
    good = _norm(WR(op="create", path="p", fields={"seq": 1785319607000}))
    bad = _norm(WR(op="create", path="p", fields={"seq": "1785319607000"}))
    assert good.fields["seq"] == "<int>"
    assert bad.fields["seq"] == "<str>"
    assert fixtures.compare([good], [bad])


def test_a_missing_volatile_field_still_fails():
    """Normalising the value must not normalise away its presence."""
    good = _norm(WR(op="create", path="p", fields={"seq": 1, "type": "x"}))
    bad = _norm(WR(op="create", path="p", fields={"type": "x"}))
    diffs = fixtures.compare([good], [bad])
    assert any(d.kind == "field-missing" and "seq" in d.detail for d in diffs)


def test_non_volatile_values_are_compared_exactly():
    good = _norm(WR(op="create", path="p", fields={"type": "phase_start", "phase": 0}))
    bad = _norm(WR(op="create", path="p", fields={"type": "phase_start", "phase": 1}))
    assert fixtures.compare([good], [bad])


def test_phase_zero_survives_normalisation():
    """`phase: 0` is contract, and a truthiness-based normaliser would erase it."""
    n = _norm(WR(op="create", path="p", fields={"phase": 0}))
    assert n.fields["phase"] == 0


def test_known_identifiers_are_tokenised_consistently():
    rec = WR(
        op="patch",
        path="users/uid-abc/researches/rid-xyz",
        fields={"deviceId": "dev-123"},
    )
    n = _norm(rec, tokens={"uid-abc": "{uid}", "rid-xyz": "{rid}", "dev-123": "{deviceId}"})
    assert n.path == "users/{uid}/researches/{rid}"
    assert n.fields["deviceId"] == "{deviceId}"


def test_unknown_long_path_segments_are_tokenised_positionally():
    """A server-assigned auto id differs every run; without this every fixture fails."""
    n = _norm(WR(op="create", path="users/u/researches/r/pipeline_events/AbCdEf0123456789xyz"))
    assert n.path.endswith("/{id}")


def test_short_path_segments_are_not_mistaken_for_ids():
    """`devices` and `queue` must survive; over-tokenising would compare nothing useful."""
    n = _norm(WR(op="patch", path="devices/d1/queue"))
    assert n.path == "devices/d1/queue"


def test_nested_maps_are_normalised_too():
    n = _norm(
        WR(op="patch", path="p", fields={"data": {"seq": 123, "kind": "login_required"}})
    )
    assert n.fields["data"]["seq"] == "<int>"
    assert n.fields["data"]["kind"] == "login_required"


def test_delete_paths_are_order_insensitive():
    a = _norm(WR(op="patch", path="p", delete_paths=["expireAt", "pendingDecision"]))
    b = _norm(WR(op="patch", path="p", delete_paths=["pendingDecision", "expireAt"]))
    assert fixtures.compare([a], [b]) == []


def test_a_dropped_delete_path_fails():
    """The atomic pair-confirm's whole point is deleting expireAt; dropping it is fatal."""
    good = _norm(WR(op="patch", path="devices/d", delete_paths=["expireAt"]))
    bad = _norm(WR(op="patch", path="devices/d", delete_paths=[]))
    diffs = fixtures.compare([good], [bad])
    assert any(d.kind == "delete-paths" for d in diffs)


# ======================================================================================
# comparison: order, completeness, and useful reporting
# ======================================================================================


def test_an_identical_sequence_compares_clean():
    seq = [_norm(WR(op="create", path="p", fields={"type": "x", "seq": 1}))]
    assert fixtures.compare(seq, list(seq)) == []


def test_order_is_significant():
    """The frontend consumes by an ascending seq cursor and pendingDecision is single-valued,

    so a reordered sequence changes what the user sees even when every write is individually
    correct.
    """
    a = _norm(WR(op="create", path="events", fields={"type": "phase_start"}))
    b = _norm(WR(op="create", path="events", fields={"type": "phase_complete"}))
    assert fixtures.compare([a, b], [b, a])


def test_a_short_sequence_reports_what_is_missing():
    a = _norm(WR(op="create", path="one"))
    b = _norm(WR(op="create", path="two"))
    diffs = fixtures.compare([a, b], [a])
    assert [d.kind for d in diffs] == ["missing"]
    assert "two" in diffs[0].detail


def test_an_over_long_sequence_reports_the_extra_write():
    a = _norm(WR(op="create", path="one"))
    b = _norm(WR(op="create", path="two"))
    diffs = fixtures.compare([a], [a, b])
    assert [d.kind for d in diffs] == ["extra"]


def test_every_difference_is_reported_not_just_the_first():
    """A reimplementation diverges in clusters; one-per-round-trip is how suites get abandoned."""
    good = _norm(WR(op="patch", path="a", fields={"x": 1, "y": 2, "z": 3}))
    bad = _norm(WR(op="patch", path="b", fields={"x": 9, "y": 2, "w": 4}))
    diffs = fixtures.compare([good], [bad])
    kinds = {d.kind for d in diffs}
    assert {"path", "field-value", "field-missing", "field-extra"} <= kinds


def test_an_op_change_is_reported():
    diffs = fixtures.compare(
        [_norm(WR(op="patch", path="p"))], [_norm(WR(op="create", path="p"))]
    )
    assert any(d.kind == "op" for d in diffs)


# ======================================================================================
# capture: records our own client's writes, no credentials needed
# ======================================================================================


class _Resp:
    status_code = 200
    ok = True
    content = b"{}"

    def json(self):
        return {}


def test_capture_records_a_patch_with_its_mask_and_deletes():
    inner = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=inner)
    client.patch(
        "devices/dev-1",
        {"pairConfirmedAt": True, "status": "active"},
        delete_paths=["expireAt"],
    )
    rec = inner.records[0]
    assert rec.op == "patch"
    assert rec.path == "devices/dev-1"
    assert rec.fields == {"pairConfirmedAt": True, "status": "active"}
    assert rec.delete_paths == ["expireAt"]


def test_capture_decodes_the_body_so_a_failing_diff_is_readable():
    """Raw {"integerValue": "1785…"} envelopes make a diff unreadable, and unreadable diffs
    get ignored."""
    inner = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=inner)
    client.patch("devices/d", {"lastHeartbeat": 1785319607000})
    assert inner.records[0].fields == {"lastHeartbeat": 1785319607000}


def test_capture_records_creates_queries_and_gets():
    inner = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=inner)
    client.create_with_auto_id("users/u/researches/r/pipeline_events", {"type": "x"})
    client.get_document("devices/d")
    try:
        client.run_query("", {"from": [{"collectionId": "devices"}]})
    except Exception:
        pass  # the fake reply is not a list; we only care that the call was recorded
    assert [r.op for r in inner.records] == ["create", "get", "query"]


def test_reads_are_captured_because_a_missing_read_is_also_a_divergence():
    """A reimplementation that skips the queued->ongoing read writes the right things from the
    wrong state."""
    inner = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=inner)
    client.get_document("devices/d/queue/q1")
    golden = [_norm(inner.records[0])]
    assert fixtures.compare(golden, []) , "dropping the read must be reported"


def test_capture_passes_the_response_through_unchanged():
    sentinel = _Resp()
    inner = fixtures.CaptureTransport(lambda *a, **k: sentinel)
    assert inner("GET", "https://x/documents/a") is sentinel


# ======================================================================================
# round trip
# ======================================================================================


def test_a_fixture_round_trips_through_disk(tmp_path):
    recs = [
        _norm(WR(op="patch", path="devices/d", fields={"status": "active"}, delete_paths=["expireAt"])),
        _norm(WR(op="create", path="users/u/researches/r/pipeline_events", fields={"type": "phase_start", "seq": 1})),
    ]
    path = fixtures.save_fixture(tmp_path / "golden.jsonl", recs)
    assert fixtures.compare(recs, fixtures.load_fixture(path)) == []


def test_a_real_event_document_normalises_to_a_stable_fixture_row():
    """End to end: build a real event, encode it, capture it, normalise it — twice."""
    def build_and_capture(seq, when):
        inner = fixtures.CaptureTransport(lambda *a, **k: _Resp())
        client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=inner)
        built = events.build_event(
            event_type="phase_start", device_id="dev-1", seq=seq, phase=0, now=when
        )
        doc = dict(built.document)
        doc["expireAt"] = values.timestamp_value(doc["expireAt"])["timestampValue"]
        client.create_with_auto_id("users/uid-a/researches/rid-b/pipeline_events", doc)
        return _norm(inner.records[0], tokens={"uid-a": "{uid}", "rid-b": "{rid}", "dev-1": "{deviceId}"})

    first = build_and_capture(1785319607000, datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc))
    second = build_and_capture(1799999999999, datetime(2026, 8, 30, 9, 30, tzinfo=timezone.utc))
    assert fixtures.compare([first], [second]) == [], (
        "two runs of the same step must normalise identically, or the suite fails every run"
    )
    assert first.path == "users/{uid}/researches/{rid}/pipeline_events"
    assert first.fields["phase"] == 0
    assert first.fields["deviceId"] == "{deviceId}"
    assert first.fields["expireAt"] == "<iso8601>"
