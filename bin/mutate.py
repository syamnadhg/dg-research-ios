#!/usr/bin/env python3
"""Mutation harness: prove each guard's test actually fails when the guard is broken.

A passing test says nothing about whether it *could* fail. Every guard in this repo protects
against a specific silent-failure mode, so each one gets an entry here that breaks the guard
and asserts the corresponding test turns red. Sources are restored byte-identically
(sha256-verified) after every mutation, and a mismatch aborts.

The `simulates:` line on each entry names the real defect, not the code change — that is the
part worth reading when one of these starts failing.

    python bin/mutate.py        # from the repo root

Two entry shapes:
  * source mutation - break the guard, expect the named test to fail
  * positive fixture (`probe_forbidden_call_detector`) - plant a real violation and expect the
    scanner to find it. For a static scanner this direction matters more: one that finds
    nothing looks exactly like a clean repo.
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / ".venv/bin/python"

# (file, old, new, test-node-id-that-MUST-fail, what-real-defect-this-simulates)
MUTATIONS = [
    (
        "emubackend/berepo.py",
        "    for node in tree.body:",
        "    for node in ast.walk(tree):",
        "test_berepo.py::test_research_module_level_imports_are_only_models_and_prompts",
        "conflating module-level with function-local imports (what a grep would do)",
    ),
    (
        "emubackend/purity.py",
        "        if cur.head != base.head:",
        "        if False:",
        "test_a8_purity.py::test_compare_detects_a_moved_head",
        "a commit to the BE going unnoticed",
    ),
    (
        "emubackend/purity.py",
        "        new_untracked = sorted(set(cur.untracked) - set(base.untracked))",
        "        new_untracked = []",
        "test_a8_purity.py::test_compare_detects_a_new_untracked_file",
        "a new file dropped into the BE going unnoticed",
    ),
    (
        "emubackend/purity.py",
        "            elif cur_digest != base_digest:",
        "            elif False:",
        "test_a8_purity.py::test_compare_detects_a_change_gitignore_would_have_hidden",
        "the D-1 editable-install scenario that .gitignore hides from git status",
    ),
    (
        "emubackend/purity.py",
        '        if appeared:\n            raise PurityViolation(',
        '        if False:\n            raise PurityViolation(',
        "test_a8_purity.py::test_no_queue_writes_detects_a_path_appearing",
        "setup_firestore_run writing owner.json into the BE's queues/",
    ),
    (
        "emubackend/purity.py",
        "        h.update(hashlib.sha256(data).digest())",
        "        h.update(b'')",
        "test_a8_purity.py::test_digest_ignores_mtime_but_catches_content",
        "a content change of equal length going unnoticed",
    ),
    (
        "emubackend/berepo.py",
        '        if module_name.split(".")[0] not in CLAIMED_TOP_LEVEL_NAMES:'.lstrip()
        and '    if module_name.split(".")[0] not in CLAIMED_TOP_LEVEL_NAMES:',
        "    if False:",
        "test_berepo.py::test_import_be_rejects_a_name_the_backend_does_not_claim",
        "a typo'd module name silently importing something else",
    ),
    # ---- geometry: the two device behaviours that cost real time to find ----
    (
        "emubackend/substrate/geometry.py",
        '        if any(e.get("type") == "click" for e in events):\n            break',
        "        if True:\n            break",
        "test_geometry.py::test_tap_and_capture_waits_for_the_terminal_click",
        "not waiting for the tap's own sequence to complete, leaving a click to leak onward",
    ),
    (
        "emubackend/substrate/geometry.py",
        '            and e.get("type") in ("pointerdown", "touchstart")',
        "            and True",
        "test_geometry.py::test_a_previous_taps_click_is_not_misattributed",
        "accepting any trusted event, so a previous tap's rounded click becomes this tap's position",
    ),
    (
        "emubackend/substrate/geometry.py",
        '            and e.get("type") in ("pointerdown", "touchstart")',
        "            and True",
        "test_geometry.py::test_calibrate_survives_the_leaking_click_ordering",
        "the same defect seen end-to-end: it is what produced scale_x=241 on the device",
    ),
    (
        "emubackend/substrate/geometry.py",
        '    vv = viewport.get("vvHeight")',
        "    vv = None",
        "test_geometry.py::test_tap_element_refuses_a_target_hidden_behind_the_keyboard",
        "using innerHeight for visibility, so a target behind the keyboard is tapped through it",
    ),
    (
        "emubackend/substrate/geometry.py",
        '    "vvScale",\n)',
        '    "vvScale",\n    "vvHeight",\n)',
        "test_geometry.py::test_keyboard_does_not_invalidate_the_calibration",
        "treating the keyboard as a transform change, forcing a recalibration that taps the keyboard",
    ),
    (
        "emubackend/substrate/geometry.py",
        "def _close(a: Any, b: Any, tol: float = 0.75) -> bool:",
        "def _close(a: Any, b: Any, tol: float = 1e9) -> bool:",
        "test_geometry.py::test_a_real_layout_change_does_invalidate_the_calibration",
        "a stale calibration surviving a genuine layout change (e.g. rotation)",
    ),
    (
        "emubackend/substrate/hid.py",
        "        if value < 0:",
        "        if False:",
        "test_hid.py::test_tap_refuses_negative_coordinates",
        "a negative coordinate reaching AXe, which misreports it as a missing argument",
    ),
    # ---- the seam ----
    (
        "emubackend/substrate/backend.py",
        '        if not state or state.get("visibility") != "visible" or state.get("hidden"):',
        "        if False:",
        "test_backend_contract.py::test_input_is_refused_on_a_background_tab",
        "HID input going to a background tab, landing on whatever is in front instead",
    ),
    (
        "emubackend/substrate/backend.py",
        "        if client_y < 0 or client_y > vis:",
        "        if False:",
        "test_backend_contract.py::test_input_is_refused_when_the_keyboard_covers_the_target",
        "tapping straight through the software keyboard at a hidden target",
    ),
    (
        "emubackend/substrate/page_shim.py",
        "    if result is None:",
        "    if False:",
        "test_backend_contract.py::test_a_null_runtime_reply_is_treated_as_failure_not_success",
        "a thrown/absent-runtime call reporting success - the 'nothing happened' bug class",
    ),
    (
        "emubackend/substrate/page_shim.py",
        "        await self.scroll_into_view_if_needed()\n        rect = _unwrap(",
        "        rect = _unwrap(",
        "test_backend_contract.py::test_click_scrolls_into_view_then_re_reads_the_rect_before_tapping",
        "tapping an off-screen element's stale rect, hitting whatever occupies that position",
    ),
    # ---- contract core: REST encoding ----
    (
        "emubackend/contract/values.py",
        '        return {"booleanValue": value}',
        '        return {"integerValue": str(int(value))}',
        "test_contract_core.py::test_bool_is_checked_before_int",
        "encoding True as integerValue, silently changing the stored type",
    ),
    (
        "emubackend/contract/values.py",
        '        return {"integerValue": str(value)}',
        '        return {"stringValue": str(value)}',
        "test_contract_core.py::test_int_encodes_as_integervalue_so_rules_see_a_number",
        "seq/timestamp as stringValue - DENIED by rules, reported as a permissions problem",
    ),
    (
        "emubackend/contract/values.py",
        "    if dt.tzinfo is None:",
        "    if False:",
        "test_contract_core.py::test_timestamp_value_refuses_a_naive_datetime",
        "a naive datetime shifting a TTL by the local offset - an early expiry deletes the doc",
    ),
    (
        "emubackend/contract/values.py",
        "        if path in present:",
        "        if False:",
        "test_contract_core.py::test_update_mask_refuses_a_field_that_is_both_set_and_deleted",
        "a field set and deleted in one patch, where Firestore applies the set",
    ),
    # ---- contract core: events ----
    (
        "emubackend/contract/events.py",
        "            if candidate <= self._last:",
        "            if False:",
        "test_contract_core.py::test_two_events_in_the_same_millisecond_still_differ",
        "duplicate seq values, which the strictly-greater-than consumer cursor drops",
    ),
    (
        "emubackend/contract/events.py",
        "            self._last = max(self._last, int(seq))",
        "            self._last = int(seq)",
        "test_contract_core.py::test_observe_never_lowers_the_floor",
        "observe() lowering the floor, so a resumed run emits below the consumer cursor",
    ),
    (
        "emubackend/contract/events.py",
        "    if phase is not None:",
        "    if phase:",
        "test_contract_core.py::test_phase_zero_is_written_because_the_guard_is_is_not_none",
        "dropping phase=0, and P0 is a real phase",
    ),
    (
        "emubackend/contract/events.py",
        "    if agent:",
        "    if agent is not None:",
        "test_contract_core.py::test_an_empty_agent_is_omitted_and_a_real_one_is_not_lowercased",
        "writing agent='' where upstream omits the field entirely",
    ),
    (
        "emubackend/contract/events.py",
        "    if payload:",
        "    if payload is not None:",
        "test_contract_core.py::test_empty_data_is_omitted_entirely",
        "writing data:{} where the backend omits it - the wrong absence semantics",
    ),
    # ---- contract core: pendingDecision ----
    (
        "emubackend/contract/pending_decision.py",
        "    a = normalize_agent(agent)",
        "    a = agent",
        "test_contract_core.py::test_rule1_an_empty_agent_string_means_an_unconditional_clear",
        "skipping the lower()-or-None normalisation, inverting the keep-guard for ''",
    ),
    (
        "emubackend/contract/pending_decision.py",
        "    owner = normalize_agent(state.agent)",
        "    owner = state.agent",
        "test_contract_core.py::test_rule1_the_agent_comparison_is_case_insensitive",
        "a case-sensitive agent comparison, refusing a legitimate clear",
    ),
    (
        "emubackend/contract/pending_decision.py",
        "    if state.active and owner is not None and owner != a:",
        "    if False:",
        "test_contract_core.py::test_rule1_a_late_clear_from_a_different_agent_is_refused",
        "a late clear deleting another agent's live blocking card - invisible until reopen",
    ),
    (
        "emubackend/contract/pending_decision.py",
        '    if not inputs.data.get("actions"):',
        "    if False:",
        "test_contract_core.py::test_rule3_the_mirror_gate_is_a_four_way_and",
        "mirroring errors with no user actions, making log noise durable",
    ),
    (
        "emubackend/contract/pending_decision.py",
        '    if inputs.data.get("quiet") and not inputs.force_mirror:',
        "    if False:",
        "test_contract_core.py::test_rule3_transient_overload_banners_must_not_become_durable",
        "a transient 529 auto-retry banner becoming a permanent decision card",
    ),
    (
        "emubackend/contract/pending_decision.py",
        "    return agent if event_type in CLEAR_SET_SCOPED_BY_AGENT else None",
        "    return agent",
        "test_contract_core.py::test_rule2_phase_restart_clears_unconditionally_because_retry_emits_it",
        "scoping phase_restart by agent, so Retry strands a stale card",
    ),
]


def run(node: str) -> bool:
    """True if the test PASSES."""
    p = subprocess.run(
        [str(PY), "-m", "pytest", f"emubackend/tests/{node}", "-q", "--no-header"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        env={"PYTHONPATH": ".", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"},
    )
    return p.returncode == 0


def probe_forbidden_call_detector(failures: list[str]) -> None:
    """Positive fixture: plant a real forbidden call and prove the scanner finds it.

    The other mutations break the guard and check the test notices. This one is the
    inverse and the more important direction for a static scanner: a scanner that finds
    nothing looks identical to a clean repo.
    """
    node = "test_a8_purity.py::test_no_forbidden_be_calls_anywhere_in_this_repo"
    probe = ROOT / "emubackend" / "_mutation_probe.py"
    assert not probe.exists(), "probe file already present — refusing to clobber"
    try:
        probe.write_text(
            "def _never_called():\n"
            "    # A real ast.Call node to the banned symbol.\n"
            "    return setup_firestore_run('topic')  # noqa: F821\n"
        )
        caught = not run(node)
    finally:
        probe.unlink()
    clean = run(node)
    status = "CAUGHT " if (caught and clean) else "MISSED "
    if status == "MISSED ":
        failures.append(f"{status}{node} (planted_call_detected={caught} clean_passed={clean})")
    print(f"{status} {node}\n          simulates: our own code calling setup_firestore_run()")


def main() -> int:
    failures = []
    for rel, old, new, node, defect in MUTATIONS:
        path = ROOT / rel
        original = path.read_bytes()
        digest = hashlib.sha256(original).hexdigest()
        text = original.decode()
        if text.count(old) != 1:
            failures.append(f"ANCHOR MISS  {rel}: {text.count(old)}x {old!r}")
            continue
        try:
            path.write_text(text.replace(old, new))
            passed_mutated = run(node)
        finally:
            path.write_bytes(original)
            assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, "restore failed"
        passed_clean = run(node)
        status = "CAUGHT " if (not passed_mutated and passed_clean) else "MISSED "
        if status == "MISSED ":
            failures.append(
                f"{status}{node}  (mutated_passed={passed_mutated} clean_passed={passed_clean})"
            )
        print(f"{status} {node}\n          simulates: {defect}")
    probe_forbidden_call_detector(failures)
    print()
    if failures:
        print("PROBLEMS:")
        for f in failures:
            print("  " + f)
        return 1
    print(f"All {len(MUTATIONS)} mutations caught; all sources restored byte-identically.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
