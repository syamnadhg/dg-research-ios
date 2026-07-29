"""The coverage gate must FAIL when a platform clears C0 without an in-app run.

Written because the gate's whole value is what it does in a state that does not exist yet: today every
real platform is blocked on #82, so the gate passes trivially. A gate that has only ever been observed
passing is indistinguishable from one that cannot fail — and this one exists specifically to catch a
future omission, which means today is the only chance to verify it catches anything.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent


def _gate():
    spec = importlib.util.spec_from_file_location("coverage_gate", REPO / "bin" / "coverage_gate.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["coverage_gate"] = module
    spec.loader.exec_module(module)
    return module


class FakeEntry:
    def __init__(self, resolvable: bool):
        self.resolvable = resolvable


class FakeManifest:
    def __init__(self, platforms):
        self.platforms = platforms
        self.source = "test"


def test_a_platform_with_every_required_selector_counts_as_cleared():
    gate = _gate()
    manifest = FakeManifest(
        {"chatgpt": {key: FakeEntry(True) for key in gate.REQUIRED}}
    )
    assert gate.cleared_platforms(manifest) == {"chatgpt": []}


def test_a_platform_missing_one_selector_has_not_cleared():
    """One unresolved selector is enough: a step whose target is missing cannot run."""
    gate = _gate()
    entries = {key: FakeEntry(True) for key in gate.REQUIRED}
    entries["sources"] = FakeEntry(False)
    manifest = FakeManifest({"claude": entries})
    assert gate.cleared_platforms(manifest) == {"claude": ["sources"]}


def test_an_absent_key_counts_as_missing_not_as_satisfied():
    """A key not present at all must not read as cleared — that is the silent version of the gap."""
    gate = _gate()
    entries = {key: FakeEntry(True) for key in gate.REQUIRED if key != "composer"}
    manifest = FakeManifest({"gemini": entries})
    assert gate.cleared_platforms(manifest) == {"gemini": ["composer"]}


def test_the_optional_activity_panel_does_not_block_clearing():
    """Demanding it would mark a platform unclear for a selector its phases never require."""
    gate = _gate()
    assert "activity_panel" not in gate.REQUIRED


def test_a_failing_c1_verdict_covers_nothing():
    """Otherwise a red gate would still be credited with coverage."""
    gate = _gate()
    original = gate.C1_VERDICT
    try:
        temp = REPO / "artifacts" / "coverage" / "_test_c1.json"
        temp.parent.mkdir(parents=True, exist_ok=True)
        temp.write_text(json.dumps({"pass": False, "platform": "chatgpt"}))
        gate.C1_VERDICT = temp
        assert gate.c1_covered() == set()
    finally:
        gate.C1_VERDICT = original


def test_a_passing_c1_verdict_credits_the_platform_it_names():
    gate = _gate()
    original = gate.C1_VERDICT
    try:
        temp = REPO / "artifacts" / "coverage" / "_test_c1.json"
        temp.parent.mkdir(parents=True, exist_ok=True)
        # The real verdict names its platform with a trailing parenthetical.
        temp.write_text(json.dumps({"pass": True, "platform": "mockplatform (the only one)"}))
        gate.C1_VERDICT = temp
        assert gate.c1_covered() == {"mockplatform"}
    finally:
        gate.C1_VERDICT = original


def test_a_missing_c1_verdict_covers_nothing():
    gate = _gate()
    original = gate.C1_VERDICT
    try:
        gate.C1_VERDICT = REPO / "artifacts" / "coverage" / "_does_not_exist.json"
        assert gate.c1_covered() == set()
    finally:
        gate.C1_VERDICT = original


def test_the_gate_fails_when_a_cleared_platform_was_never_run_in_app(monkeypatch, capsys):
    """The state that matters, simulated: selectors have arrived and nobody ran C1.

    This is the only assertion in this file that exercises what the gate is *for*.
    """
    gate = _gate()
    manifest = FakeManifest({"chatgpt": {key: FakeEntry(True) for key in gate.REQUIRED}})
    monkeypatch.setattr(gate.selectors_mod, "load_manifest", lambda _path: manifest)
    monkeypatch.setattr(gate, "c1_covered", lambda: {"mockplatform"})
    monkeypatch.setattr(sys, "argv", ["coverage_gate.py"])

    assert gate.main() == 1, "a cleared-but-unrun platform must fail the gate"
    assert "cleared C0 but never run in-app: ['chatgpt']" in capsys.readouterr().out


def test_the_gate_passes_once_that_platform_has_been_run(monkeypatch):
    gate = _gate()
    manifest = FakeManifest({"chatgpt": {key: FakeEntry(True) for key in gate.REQUIRED}})
    monkeypatch.setattr(gate.selectors_mod, "load_manifest", lambda _path: manifest)
    monkeypatch.setattr(gate, "c1_covered", lambda: {"mockplatform", "chatgpt"})
    monkeypatch.setattr(sys, "argv", ["coverage_gate.py"])

    assert gate.main() == 0


def test_the_real_repo_state_is_what_the_report_claims():
    """Guards against the summary drifting from the repo — the reason this gate exists."""
    gate = _gate()
    manifest = gate.selectors_mod.load_manifest(None)
    gaps = gate.cleared_platforms(manifest)
    assert set(gaps) == {"chatgpt", "gemini", "claude", "notebooklm"}
    assert all(missing for missing in gaps.values()), (
        "a real platform reports as cleared — if selectors have genuinely landed, run C1 against it; "
        "this test failing is the intended signal, not a nuisance"
    )
