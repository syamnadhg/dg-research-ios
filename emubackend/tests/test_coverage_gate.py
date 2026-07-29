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


def test_a_failing_c1_verdict_covers_nothing(tmp_path, monkeypatch):
    """Otherwise a red gate would still be credited with coverage."""
    gate = _gate()
    directory = tmp_path / "c1"
    directory.mkdir()
    (directory / "verdict-chatgpt.json").write_text(
        json.dumps({"pass": False, "platform": "chatgpt", "manifest_source": "selectors.json"})
    )
    monkeypatch.setattr(gate, "C1_VERDICT", directory / "verdict.json")
    assert gate.c1_covered() == set()


def test_a_passing_c1_verdict_credits_the_platform_it_names(tmp_path, monkeypatch):
    gate = _gate()
    directory = tmp_path / "c1"
    directory.mkdir()
    # The real verdict may name its platform with a trailing parenthetical.
    (directory / "verdict-mockplatform.json").write_text(
        json.dumps({
            "pass": True,
            "platform": "mockplatform (the only one)",
            "manifest_source": "fixtures/mockplatform/selectors_mock.json",
        })
    )
    monkeypatch.setattr(gate, "C1_VERDICT", directory / "verdict.json")
    assert gate.c1_covered() == {"mockplatform"}


def test_no_verdicts_at_all_covers_nothing(tmp_path, monkeypatch):
    gate = _gate()
    monkeypatch.setattr(gate, "C1_VERDICT", tmp_path / "nonexistent" / "verdict.json")
    assert gate.c1_covered() == set()


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


# ======================================================================================
# end-to-end: the real CLI, no monkeypatching
# ======================================================================================


def test_the_real_cli_exits_nonzero_when_a_cleared_platform_has_no_in_app_run(tmp_path):
    """The enforcement proof, run as a subprocess against a real manifest file.

    The monkeypatched tests above check the logic; this checks the **thing that will actually run** —
    argument parsing, manifest loading, exit code. A mechanism verified only through its internals is
    the kind that turns out to be wired to nothing.

    `fixtures/manifests/one_platform_cleared.json` describes the state that does not exist yet: chatgpt
    fully captured. Its selectors are plausible placeholders and are NOT a claim about real DOM — the
    file exists to make the gate demonstrate that it blocks.
    """
    import subprocess

    fixture = REPO / "fixtures" / "manifests" / "one_platform_cleared.json"
    assert fixture.exists(), "the fixture manifest is missing"
    out = tmp_path / "verdict.json"

    result = subprocess.run(
        [
            sys.executable,
            str(REPO / "bin" / "coverage_gate.py"),
            "--manifest", str(fixture),
            "--out", str(out),
        ],
        capture_output=True,
        text=True,
        cwd=REPO,
    )

    assert result.returncode == 1, (
        f"the gate must BLOCK when a platform clears C0 without an in-app run.\n{result.stdout}"
    )
    assert "cleared C0 but never run in-app: ['chatgpt']" in result.stdout
    verdict = json.loads(out.read_text())
    assert verdict["pass"] is False
    assert "chatgpt" in verdict["cleared"]
    assert "chatgpt" not in verdict["covered_by_c1"]


def test_an_alternate_manifest_run_does_not_clobber_the_real_verdict(tmp_path):
    """Found by doing it: the first proof run wrote a FAIL over the repo's genuine PASS.

    A self-test that corrupts the artifact it is testing is worse than no self-test, because the
    corrupted artifact then gets read as the current state.
    """
    import subprocess

    real = REPO / "artifacts" / "coverage" / "verdict.json"
    before = real.read_text() if real.exists() else None

    subprocess.run(
        [
            sys.executable,
            str(REPO / "bin" / "coverage_gate.py"),
            "--manifest", str(REPO / "fixtures" / "manifests" / "one_platform_cleared.json"),
        ],
        capture_output=True,
        text=True,
        cwd=REPO,
    )

    after = real.read_text() if real.exists() else None
    assert after == before, "a --manifest run must write to its own verdict path"


def test_the_real_cli_passes_on_the_repos_actual_state():
    """The other direction, so the gate is not merely always-failing."""
    import subprocess

    result = subprocess.run(
        [sys.executable, str(REPO / "bin" / "coverage_gate.py")],
        capture_output=True, text=True, cwd=REPO,
    )
    assert result.returncode == 0, result.stdout
    assert "mockplatform" in result.stdout


# ======================================================================================
# provenance: a wiring proof must not be credited as coverage
# ======================================================================================


def test_a_wiring_proof_verdict_is_not_credited(tmp_path, monkeypatch):
    """The self-congratulation guard.

    Proving the harness can drive a non-mock platform requires running it under a proof manifest, which
    writes a PASSING `verdict-chatgpt.json`. Crediting that would have the gate report chatgpt as
    covered while nobody has captured a single real selector for it.
    """
    gate = _gate()
    directory = tmp_path / "c1"
    directory.mkdir()
    (directory / "verdict-chatgpt.json").write_text(
        json.dumps({
            "pass": True,
            "platform": "chatgpt",
            "manifest_source": "fixtures/manifests/nonmock_wiring_proof.json "
                               "(url overridden — WIRING PROOF, not real coverage)",
        })
    )
    monkeypatch.setattr(gate, "C1_VERDICT", directory / "verdict.json")
    assert gate.c1_covered() == set()


def test_a_proof_manifest_path_alone_is_enough_to_refuse_credit(tmp_path, monkeypatch):
    """Belt and braces: a proof-manifest run WITHOUT the url override must also not count."""
    gate = _gate()
    directory = tmp_path / "c1"
    directory.mkdir()
    (directory / "verdict-gemini.json").write_text(
        json.dumps({
            "pass": True, "platform": "gemini",
            "manifest_source": "fixtures/manifests/one_platform_cleared.json",
        })
    )
    monkeypatch.setattr(gate, "C1_VERDICT", directory / "verdict.json")
    assert gate.c1_covered() == set()


def test_coverage_accumulates_across_platforms(tmp_path, monkeypatch):
    """Per-platform verdicts exist so coverage is not merely whatever ran last."""
    gate = _gate()
    directory = tmp_path / "c1"
    directory.mkdir()
    for platform, source in [
        ("mockplatform", "fixtures/mockplatform/selectors_mock.json"),
        ("chatgpt", "selectors_mobile.json"),
    ]:
        (directory / f"verdict-{platform}.json").write_text(
            json.dumps({"pass": True, "platform": platform, "manifest_source": source})
        )
    monkeypatch.setattr(gate, "C1_VERDICT", directory / "verdict.json")
    assert gate.c1_covered() == {"mockplatform", "chatgpt"}


def test_the_mock_platforms_own_fixture_is_still_credited(tmp_path, monkeypatch):
    """The mock IS a fixture platform — refusing it would leave nothing ever covered."""
    gate = _gate()
    directory = tmp_path / "c1"
    directory.mkdir()
    (directory / "verdict-mockplatform.json").write_text(
        json.dumps({
            "pass": True, "platform": "mockplatform",
            "manifest_source": "fixtures/mockplatform/selectors_mock.json",
        })
    )
    monkeypatch.setattr(gate, "C1_VERDICT", directory / "verdict.json")
    assert gate.c1_covered() == {"mockplatform"}


def test_the_real_repo_refuses_to_credit_the_chatgpt_wiring_proof():
    """Against the ACTUAL artifacts on disk, which include a passing verdict-chatgpt.json."""
    gate = _gate()
    proof = REPO / "artifacts" / "c1" / "verdict-chatgpt.json"
    if not proof.exists():
        pytest.skip("no wiring-proof verdict present; run bin/c1_in_app.sh's proof invocation")
    assert json.loads(proof.read_text())["pass"] is True, "the proof run should have passed"
    assert "chatgpt" not in gate.c1_covered(), (
        "a passing wiring-proof verdict must not be credited as real coverage"
    )
