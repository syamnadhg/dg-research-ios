"""The A8 guard: prove `dg-research-backend` and `dg-research` are untouched.

This is the test that makes the recipe's definition of done ("both existing repos show
zero modifications") checkable rather than aspirational.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path

import pytest

from emubackend import berepo, purity

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BASELINE = REPO_ROOT / "fixtures" / "a8_baseline.json"


# --------------------------------------------------------------------------------------
# The live check
# --------------------------------------------------------------------------------------


def test_baseline_exists_and_covers_both_guarded_repos():
    assert BASELINE.exists(), (
        "no A8 baseline recorded — run: python -c "
        "'from emubackend import purity; print(purity.save_baseline())'"
    )
    raw = json.loads(BASELINE.read_text())
    assert set(raw) == set(purity.GUARDED_REPOS), (
        f"baseline covers {sorted(raw)} but A8 guards {sorted(purity.GUARDED_REPOS)}"
    )
    for name, state in raw.items():
        assert state["head"], f"{name}: baseline has no HEAD pinned"


def test_guarded_repos_are_pristine():
    """The headline assertion. If this fails, A8 has been violated — stop and fix it."""
    purity.assert_pristine()


# --------------------------------------------------------------------------------------
# The guard itself must actually detect things (a guard nobody tested is decoration)
# --------------------------------------------------------------------------------------


def test_compare_detects_a_moved_head():
    base = purity.capture()
    mutated = {
        name: purity.RepoState.from_json(
            {**st.to_json(), "head": "0" * 40}
        )
        for name, st in base.items()
    }
    problems = purity.compare(base, mutated)
    assert any("HEAD moved" in p for p in problems)


def test_compare_detects_a_modified_tracked_file():
    base = purity.capture()
    name = purity.GUARDED_REPOS[0]
    mutated = dict(base)
    st = base[name].to_json()
    st["tracked_changes"] = [*st["tracked_changes"], " M research.py"]
    mutated[name] = purity.RepoState.from_json(st)
    problems = purity.compare(base, mutated)
    assert any("tracked files changed" in p and "research.py" in p for p in problems)


def test_compare_detects_a_new_untracked_file():
    base = purity.capture()
    name = purity.GUARDED_REPOS[0]
    mutated = dict(base)
    st = base[name].to_json()
    st["untracked"] = [*st["untracked"], "sneaky_new_file.py"]
    mutated[name] = purity.RepoState.from_json(st)
    problems = purity.compare(base, mutated)
    assert any("new untracked" in p and "sneaky_new_file.py" in p for p in problems)


def test_compare_detects_a_change_gitignore_would_have_hidden():
    """The D-1 scenario: an editable install regenerating superresearch.egg-info/.

    git status cannot see this, which is the entire reason the digest exists.
    """
    base = purity.capture()
    name = "dg-research-backend"
    if name not in base or not base[name].ignored_digests:
        pytest.skip("no ignored-but-live dirs present to fingerprint")
    mutated = dict(base)
    st = base[name].to_json()
    key = sorted(st["ignored_digests"])[0]
    st["ignored_digests"] = {**st["ignored_digests"], key: "deadbeef"}
    mutated[name] = purity.RepoState.from_json(st)
    problems = purity.compare(base, mutated)
    assert any(".gitignore hid this" in p for p in problems)


def test_compare_detects_a_newly_created_ignored_dir():
    base = purity.capture()
    name = purity.GUARDED_REPOS[0]
    mutated = dict(base)
    st = base[name].to_json()
    st["ignored_digests"] = {**st["ignored_digests"], "brand_new.egg-info": "abc"}
    mutated[name] = purity.RepoState.from_json(st)
    problems = purity.compare(base, mutated)
    assert any("newly created" in p for p in problems)


def test_compare_is_quiet_when_nothing_changed():
    """A guard that fires on a pristine tree is a guard that gets switched off."""
    base = purity.capture()
    assert purity.compare(base, purity.capture()) == []


def test_no_queue_writes_detects_a_path_appearing(tmp_path):
    """Simulate the setup_firestore_run contamination against a fake parent dir."""
    fake_be = tmp_path / "dg-research-backend"
    (fake_be / "queues").mkdir(parents=True)
    with pytest.raises(purity.PurityViolation, match="setup_firestore_run"):
        with purity.no_queue_writes(parent=tmp_path):
            (fake_be / "queues" / "run-123").mkdir()
            (fake_be / "queues" / "run-123" / "owner.json").write_text("{}")


def test_no_queue_writes_is_quiet_when_nothing_appears(tmp_path):
    fake_be = tmp_path / "dg-research-backend"
    (fake_be / "queues").mkdir(parents=True)
    with purity.no_queue_writes(parent=tmp_path):
        pass  # must not raise


def test_digest_ignores_mtime_but_catches_content(tmp_path):
    """Rewriting identical bytes is not a modification; changing one byte is."""
    d = tmp_path / "tree"
    d.mkdir()
    f = d / "a.txt"
    f.write_text("hello")
    first = purity._digest_tree(d)
    f.write_text("hello")  # same content, new mtime
    assert purity._digest_tree(d) == first
    f.write_text("hellp")
    assert purity._digest_tree(d) != first


# --------------------------------------------------------------------------------------
# Static ban on the two BE symbols that would contaminate the running product
# --------------------------------------------------------------------------------------


def _our_python_files() -> list[Path]:
    return [
        p
        for p in REPO_ROOT.rglob("*.py")
        if ".venv" not in p.parts and "build" not in p.parts
    ]


def test_no_forbidden_be_calls_anywhere_in_this_repo():
    """Grep would false-positive on our own docstrings; match real call nodes instead."""
    offenders: list[str] = []
    for path in _our_python_files():
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except SyntaxError as exc:  # pragma: no cover - would fail elsewhere loudly
            pytest.fail(f"{path} does not parse: {exc}")
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            name = (
                func.id
                if isinstance(func, ast.Name)
                else func.attr
                if isinstance(func, ast.Attribute)
                else None
            )
            if name in berepo.FORBIDDEN_BE_SYMBOLS:
                offenders.append(
                    f"{path.relative_to(REPO_ROOT)}:{node.lineno} calls {name}() — "
                    f"{berepo.FORBIDDEN_BE_SYMBOLS[name]}"
                )
    assert not offenders, "forbidden BE call(s):\n" + "\n".join(offenders)


def test_forbidden_symbols_still_exist_in_the_backend():
    """If a banned symbol were renamed, the static ban would silently stop protecting.

    Cheap insurance against the ban rotting into a no-op.
    """
    research = (berepo.be_root() / "research.py").read_text(
        encoding="utf-8", errors="replace"
    )
    for symbol in berepo.FORBIDDEN_BE_SYMBOLS:
        assert f"def {symbol}" in research, (
            f"{symbol} no longer defined in research.py — the static ban in "
            "berepo.FORBIDDEN_BE_SYMBOLS may be stale"
        )
