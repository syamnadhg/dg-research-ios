"""Tests for the vendored contract core: REST encoding, event shape, pendingDecision rules.

These are the semantics the recipe warns took months of production fixes to get right, and
every one of them fails *silently* in production — a denied write reported as a permissions
problem, a dropped event, a decision card the user never sees. So they are pinned here as pure
predicates with the failure each test prevents stated in its docstring.
"""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone

import pytest

from emubackend.contract import events, pending_decision, values

UTC_NOW = datetime(2026, 7, 29, 12, 0, 0, tzinfo=timezone.utc)


# ======================================================================================
# values.py — encoding, where the wire type decides whether a rule passes
# ======================================================================================


def test_int_encodes_as_integervalue_so_rules_see_a_number():
    """`seq is number` / `timestamp is number` pass for integerValue and DENY for stringValue.

    The failure mode is a permission denial, which points at the rules rather than the encoder.
    """
    assert values.to_value(1785319607000) == {"integerValue": "1785319607000"}


def test_bool_is_checked_before_int():
    """bool IS an int in Python; encoding True as integerValue would change the stored type."""
    assert values.to_value(True) == {"booleanValue": True}
    assert values.to_value(False) == {"booleanValue": False}


def test_strings_floats_none_and_containers():
    assert values.to_value("x") == {"stringValue": "x"}
    assert values.to_value(1.5) == {"doubleValue": 1.5}
    assert values.to_value(None) == {"nullValue": None}
    assert values.to_value([1, "a"]) == {
        "arrayValue": {"values": [{"integerValue": "1"}, {"stringValue": "a"}]}
    }
    assert values.to_value({"k": 2}) == {
        "mapValue": {"fields": {"k": {"integerValue": "2"}}}
    }


def test_datetime_is_refused_rather_than_coerced():
    """Upstream to_value() raises here too — expireAt's encoding is a deliberate decision."""
    with pytest.raises(values.ValueEncodingError, match="timestamp_value"):
        values.to_value(UTC_NOW)


def test_timestamp_value_emits_zulu_iso8601():
    assert values.timestamp_value(UTC_NOW) == {"timestampValue": "2026-07-29T12:00:00Z"}


def test_timestamp_value_refuses_a_naive_datetime():
    """A naive value read as local time shifts a TTL by the UTC offset.

    For the device doc that means expiring hours early — and an early expiry deletes it outright
    with no recovery path (`allow create: if false`).
    """
    with pytest.raises(values.ValueEncodingError, match="naive"):
        values.timestamp_value(datetime(2026, 7, 29, 12, 0, 0))


def test_timestamp_value_normalises_a_non_utc_offset():
    tz = timezone(timedelta(hours=5, minutes=30))
    local = datetime(2026, 7, 29, 17, 30, 0, tzinfo=tz)
    assert values.timestamp_value(local) == {"timestampValue": "2026-07-29T12:00:00Z"}


def test_unencodable_types_are_named_in_the_error():
    with pytest.raises(values.ValueEncodingError, match="set"):
        values.to_value({1, 2})


def test_update_mask_lists_deleted_paths_that_are_absent_from_the_body():
    """That pairing IS the delete operation over REST — there is no DELETE_FIELD sentinel."""
    body = {"status": "active", "lastHeartbeat": 1}
    mask = values.update_mask_for(body, delete_paths=["expireAt"])
    assert set(mask) == {"status", "lastHeartbeat", "expireAt"}
    assert "expireAt" not in body


def test_update_mask_refuses_a_field_that_is_both_set_and_deleted():
    """Firestore would apply the set; failing loudly beats a clear that silently didn't."""
    with pytest.raises(values.ValueEncodingError, match="both the body and the delete list"):
        values.update_mask_for({"expireAt": 1}, delete_paths=["expireAt"])


# ======================================================================================
# events.py — seq is not a counter
# ======================================================================================


def test_seq_is_epoch_millis_not_a_zero_based_counter():
    """A 0-based counter restarts each run BELOW the frontend's stored cursor.

    The consumer queries `where("seq", ">", lastSeq)`, so every event of the new run would be
    filtered out and the run would appear to produce nothing at all.
    """
    guard = events.SeqGuard()
    first = guard.next(now_ms=1785319607000)
    assert first == 1785319607000
    assert first > 1_000_000_000_000


def test_two_events_in_the_same_millisecond_still_differ():
    guard = events.SeqGuard()
    a = guard.next(now_ms=1000)
    b = guard.next(now_ms=1000)
    c = guard.next(now_ms=1000)
    assert (a, b, c) == (1000, 1001, 1002)


def test_a_backwards_clock_cannot_produce_a_regression():
    """NTP correction and sleep/wake are routine on a laptop running a 90-minute pipeline."""
    guard = events.SeqGuard()
    guard.next(now_ms=5000)
    assert guard.next(now_ms=4000) == 5001


def test_observe_raises_the_floor_for_a_resumed_run():
    """Without this a resumed run emits below the frontend's cursor and vanishes."""
    guard = events.SeqGuard()
    guard.observe(9999)
    assert guard.next(now_ms=500) == 10000


def test_observe_never_lowers_the_floor():
    guard = events.SeqGuard()
    guard.next(now_ms=5000)
    guard.observe(10)
    assert guard.last == 5000


def test_seq_is_unique_under_concurrency():
    """The orchestrator emits from more than one task; an unlocked RMW hands out duplicates."""
    guard = events.SeqGuard()
    seen: list[int] = []
    lock = threading.Lock()

    def worker():
        for _ in range(200):
            v = guard.next(now_ms=1000)
            with lock:
                seen.append(v)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(seen) == len(set(seen)) == 1600


# ======================================================================================
# events.py — the omission rules ARE the contract
# ======================================================================================


def _build(**kw):
    kw.setdefault("event_type", "phase_start")
    kw.setdefault("device_id", "dev-1")
    kw.setdefault("seq", 1000)
    kw.setdefault("now", UTC_NOW)
    return events.build_event(**kw)


def test_phase_zero_is_written_because_the_guard_is_is_not_none():
    """P0 is a real phase; a truthiness guard would drop it."""
    assert _build(phase=0).document["phase"] == 0


def test_phase_is_omitted_only_when_none():
    assert "phase" not in _build().document
    assert _build(phase=3).document["phase"] == 3


def test_an_empty_agent_is_omitted_and_a_real_one_is_not_lowercased():
    assert "agent" not in _build(agent="").document
    assert "agent" not in _build(agent=None).document
    assert _build(agent="ChatGPT").document["agent"] == "ChatGPT"


def test_empty_data_is_omitted_entirely():
    """The frontend's own emitter always writes {}, so consumers see both shapes."""
    assert "data" not in _build(data={}).document
    assert "data" not in _build(data=None).document
    assert _build(data={"a": 1}).document["data"] == {"a": 1}


def test_device_id_is_top_level_not_nested_in_data():
    """The device branch of the rule reads the TOP-LEVEL field; nesting it is denied."""
    doc = _build(data={"a": 1}).document
    assert doc["deviceId"] == "dev-1"
    assert "deviceId" not in doc["data"]


def test_timestamp_and_seq_are_ints():
    """A Firestore Timestamp fails `is number` and the write is denied."""
    doc = _build().document
    assert isinstance(doc["timestamp"], int) and not isinstance(doc["timestamp"], bool)
    assert isinstance(doc["seq"], int)
    assert doc["timestamp"] == int(UTC_NOW.timestamp() * 1000)


def test_expire_at_is_thirty_days_out_and_timezone_aware():
    doc = _build().document
    assert doc["expireAt"] == UTC_NOW + timedelta(days=events.EVENT_TTL_DAYS)
    assert doc["expireAt"].tzinfo is not None


def test_mirror_control_flags_are_stripped_from_data_and_returned_separately():
    """They are control flags, never payload — upstream pops them off before the write."""
    built = _build(data={"a": 1, "suppress_generic_mirror": True, "force_mirror": True})
    assert built.document["data"] == {"a": 1}
    assert built.suppress_generic_mirror is True
    assert built.force_mirror is True


def test_stripping_the_only_data_keys_leaves_data_omitted():
    built = _build(data={"suppress_generic_mirror": True})
    assert "data" not in built.document


def test_the_callers_dict_is_not_mutated():
    """Upstream pops off the SAME object; copying here is the safer divergence, so pin it."""
    original = {"a": 1, "force_mirror": True}
    _build(data=original)
    assert original == {"a": 1, "force_mirror": True}


def test_a_naive_now_is_refused():
    with pytest.raises(ValueError, match="timezone-aware"):
        _build(now=datetime(2026, 7, 29, 12, 0, 0))


def test_the_owner_branch_type_list_is_recorded_and_the_device_branch_is_not_restricted():
    assert set(events.OWNER_BRANCH_TYPES) == {
        "phase_start",
        "phase_complete",
        "phase_skipped",
        "pipeline_complete",
    }
    # A device may emit any type; this must not raise.
    assert _build(event_type="some_device_only_event").document["type"] == (
        "some_device_only_event"
    )


def test_the_full_document_matches_the_contract_shape():
    built = _build(seq=1785319607000, phase=2, agent="Gemini", data={"k": "v"})
    assert set(built.document) == {
        "type", "timestamp", "seq", "deviceId", "expireAt", "phase", "agent", "data",
    }


# ======================================================================================
# pending_decision.py — five silent-failure rules
# ======================================================================================

PS = pending_decision.PendingState


def test_rule2_only_two_event_types_scope_the_clear_by_agent():
    for et in ("agent_skipped", "pipeline_resumed"):
        assert pending_decision.clear_agent_scope(et, "ChatGPT") == "ChatGPT"
    for et in ("pipeline_stopped", "phase_skipped", "phase_restart"):
        assert pending_decision.clear_agent_scope(et, "ChatGPT") is None


def test_rule2_phase_restart_clears_unconditionally_because_retry_emits_it():
    """Retry emits phase_restart and NOT pipeline_resumed, so scoping it strands a stale card."""
    assert "phase_restart" not in pending_decision.CLEAR_SET_SCOPED_BY_AGENT
    assert pending_decision.clear_agent_scope("phase_restart", "Claude") is None


def test_rule1_a_late_clear_from_a_different_agent_is_refused():
    """The exact production sequence: A fails to launch, run advances, B takes the slot.

    Without the guard, A's late clear deletes B's live blocking card and the user never sees the
    decision the run is waiting on.
    """
    state = PS(active=True, agent="AgentB")
    assert pending_decision.should_clear(state, "AgentA") is False


def test_rule1_the_owning_agent_may_clear_its_own_card():
    state = PS(active=True, agent="AgentB")
    assert pending_decision.should_clear(state, "AgentB") is True


def test_rule1_an_agentless_clear_is_unconditional():
    state = PS(active=True, agent="AgentB")
    assert pending_decision.should_clear(state, None) is True


def test_rule1_an_inactive_slot_never_blocks_a_clear():
    assert pending_decision.should_clear(PS(active=False, agent="AgentB"), "AgentA") is True


def test_rule1_the_agent_comparison_is_case_insensitive():
    """Upstream lowercases both sides. Comparing raw strings refuses a legitimate clear,

    which leaves a resolved card to re-surface on a cold chat open.
    """
    state = PS(active=True, agent="chatgpt")
    assert pending_decision.should_clear(state, "ChatGPT") is True
    assert pending_decision.should_clear(state, "CHATGPT") is True
    assert pending_decision.should_clear(PS(active=True, agent="ChatGPT"), "chatgpt") is True
    # A genuinely different agent is still refused, whatever the casing.
    assert pending_decision.should_clear(state, "Gemini") is False


def test_rule1_an_empty_agent_string_means_an_unconditional_clear():
    """`(agent or "").lower() or None` collapses "" to None — NOT an agent named "".

    Treating "" as a name inverts the rule: the guard would protect the slot from a clear
    upstream performs unconditionally.
    """
    state = PS(active=True, agent="AgentB")
    assert pending_decision.should_clear(state, "") is True
    assert pending_decision.normalize_agent("") is None
    assert pending_decision.normalize_agent(None) is None
    assert pending_decision.normalize_agent("ChatGPT") == "chatgpt"


def test_rule1_an_active_slot_with_no_owner_does_not_block():
    assert pending_decision.should_clear(PS(active=True, agent=None), "AgentA") is True


MI = pending_decision.MirrorInputs


def test_rule3_the_mirror_gate_is_a_four_way_and():
    ok = MI(event_type="pipeline_error", data={"actions": ["retry"]})
    assert pending_decision.should_mirror(ok) is True

    # clause 1: wrong type
    assert pending_decision.should_mirror(
        MI(event_type="phase_start", data={"actions": ["retry"]})
    ) is False
    # clause 2: nothing for the user to choose
    assert pending_decision.should_mirror(
        MI(event_type="pipeline_error", data={})
    ) is False
    assert pending_decision.should_mirror(
        MI(event_type="pipeline_error", data={"actions": []})
    ) is False
    # clause 3: quiet
    assert pending_decision.should_mirror(
        MI(event_type="pipeline_error", data={"actions": ["r"], "quiet": True})
    ) is False
    # clause 4: a kind-specific persist already owns the slot
    assert pending_decision.should_mirror(
        MI(
            event_type="pipeline_error",
            data={"actions": ["r"]},
            suppress_generic_mirror=True,
        )
    ) is False


def test_rule3_force_mirror_overrides_quiet_but_not_suppress():
    assert pending_decision.should_mirror(
        MI(
            event_type="pipeline_error",
            data={"actions": ["r"], "quiet": True},
            force_mirror=True,
        )
    ) is True
    assert pending_decision.should_mirror(
        MI(
            event_type="pipeline_error",
            data={"actions": ["r"], "quiet": True},
            force_mirror=True,
            suppress_generic_mirror=True,
        )
    ) is False


def test_rule3_transient_overload_banners_must_not_become_durable():
    """The reason the `quiet` clause exists, isolated so it is the ONLY clause under test.

    A transient 529 banner genuinely does carry a retry action — that is why `actions` alone is
    not enough to gate it, and why `quiet` exists as a separate clause. An earlier version of
    this test omitted `actions`, so it was blocked by a different clause and proved nothing
    about `quiet` at all (caught by bin/mutate.py).
    """
    transient = MI(
        event_type="pipeline_error",
        data={"message": "529 overload, retrying", "actions": ["retry"], "quiet": True},
    )
    assert pending_decision.should_mirror(transient) is False
    # Same event without the quiet marker IS user-actionable and must mirror — otherwise this
    # test would pass for a gate that rejects everything.
    durable = MI(
        event_type="pipeline_error",
        data={"message": "login expired", "actions": ["retry"]},
    )
    assert pending_decision.should_mirror(durable) is True


def test_rule4_a_late_upgrade_declines_when_the_slot_changed_hands():
    state = PS(active=True, decision_id="decision-1")
    assert pending_decision.suppress_for_late_upgrade(state, "decision-1") is False
    assert pending_decision.suppress_for_late_upgrade(state, "decision-2") is True


def test_rule4_an_inactive_slot_means_suppress():
    assert pending_decision.suppress_for_late_upgrade(
        PS(active=False, decision_id="d1"), "d1"
    ) is True


def test_rule4_a_missing_decision_id_means_suppress():
    assert pending_decision.suppress_for_late_upgrade(
        PS(active=True, decision_id="d1"), None
    ) is True


def test_rule5_a_fresh_run_wipes_the_slot_but_a_queued_one_does_not():
    """A queued run has not started, so the card it would erase belongs to the running one."""
    assert pending_decision.startup_clear_field(queued=False) is True
    assert pending_decision.startup_clear_field(queued=True) is False


def test_the_known_kind_list_matches_the_frontend():
    """An unknown kind is SKIPPED by the frontend — an invisible no-op, not an error."""
    assert set(pending_decision.KNOWN_KINDS) == {
        "login_required",
        "human_verification_required",
        "agent_link_failed",
        "pro_required",
        "pipeline_error",
    }
    assert set(pending_decision.KIND_SPECIFIC_KINDS) < set(pending_decision.KNOWN_KINDS)
    assert "pipeline_error" not in pending_decision.KIND_SPECIFIC_KINDS
