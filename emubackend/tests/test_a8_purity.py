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


def _synthetic(**overrides) -> dict[str, purity.RepoState]:
    """A guarded-repo fingerprint built from nothing.

    These tests exercise :func:`purity.compare`, whose whole job is to spot a difference
    between two states. Seeding them from a *live* ``capture()`` makes the assertion a
    function of whatever the backend checkout happens to look like today — and on a
    machine holding uncommitted backend work, appending a change entry for a file that is
    already listed is a no-op after the set difference, so the test cannot fail no matter
    what ``compare`` does. Build both sides explicitly instead.
    """
    name = purity.GUARDED_REPOS[0]
    state = {
        "name": name,
        "head": "a" * 40,
        "tracked_changes": [" M research.py"],
        "untracked": ["tests/test_new_thing.py"],
        "ignored_digests": {"build": "digest-build"},
        "dirty_digests": {
            "research.py": "digest-research",
            "tests/test_new_thing.py": "digest-newthing",
        },
    }
    state.update(overrides)
    return {name: purity.RepoState.from_json(state)}


def test_compare_detects_a_modified_tracked_file():
    base = _synthetic()
    mutated = _synthetic(
        tracked_changes=[" M research.py", " M narrate.py"],
        dirty_digests={
            "research.py": "digest-research",
            "tests/test_new_thing.py": "digest-newthing",
            "narrate.py": "digest-narrate",
        },
    )
    problems = purity.compare(base, mutated)
    assert any("tracked files changed" in p and "narrate.py" in p for p in problems)


def test_compare_detects_an_edit_to_an_ALREADY_modified_file():
    """git status is byte-identical here; only the content digest can see it.

    This is the case the baseline-over-a-dirty-repo situation creates, and the one the
    porcelain set difference is structurally unable to catch.
    """
    base = _synthetic()
    mutated = _synthetic(
        dirty_digests={
            "research.py": "digest-research-EDITED",
            "tests/test_new_thing.py": "digest-newthing",
        }
    )
    problems = purity.compare(base, mutated)
    assert any("already modified" in p and "research.py" in p for p in problems)
    # and the porcelain lists really are identical, so nothing else could have caught it
    assert base[purity.GUARDED_REPOS[0]].tracked_changes == (
        mutated[purity.GUARDED_REPOS[0]].tracked_changes
    )


def test_compare_detects_a_DISCARDED_uncommitted_change():
    """Rule 1 of the handoff: never discard the backend's uncommitted files.

    A revert *removes* the porcelain entry, and ``set(current) - set(baseline)`` can never
    see a removal — so before the digests this guard was blind to the worst case it exists
    to prevent.
    """
    base = _synthetic()
    mutated = _synthetic(
        tracked_changes=[],
        dirty_digests={"tests/test_new_thing.py": "digest-newthing"},
    )
    problems = purity.compare(base, mutated)
    assert any("DISCARDED" in p and "research.py" in p for p in problems)


def test_compare_is_quiet_when_dirty_content_is_unchanged():
    """Both directions: a guard that fires on the legitimate steady state gets muted."""
    assert purity.compare(_synthetic(), _synthetic()) == []


def test_compare_detects_a_new_untracked_file():
    base = purity.capture()
    name = purity.GUARDED_REPOS[0]
    sentinel = "sneaky_new_file.py"
    assert sentinel not in base[name].untracked, (
        f"{sentinel} actually exists in {name} — this test would pass vacuously"
    )
    mutated = dict(base)
    st = base[name].to_json()
    st["untracked"] = [*st["untracked"], sentinel]
    mutated[name] = purity.RepoState.from_json(st)
    problems = purity.compare(base, mutated)
    assert any("new untracked" in p and sentinel in p for p in problems)


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


def _tiny_repo(root: Path) -> Path:
    """A real git repo with one committed file, one modified, one untracked."""
    import subprocess

    repo = root / purity.GUARDED_REPOS[0]
    repo.mkdir(parents=True)
    run = lambda *a: subprocess.run(  # noqa: E731
        ["git", "-C", str(repo), *a], check=True, capture_output=True
    )
    run("init", "-q")
    run("config", "user.email", "t@t")
    run("config", "user.name", "t")
    (repo / "research.py").write_text("original\n")
    run("add", "-A")
    run("commit", "-qm", "seed")
    (repo / "research.py").write_text("modified\n")  # tracked + dirty
    (repo / "brand_new.py").write_text("new\n")  # untracked
    return repo


def test_capture_really_digests_dirty_paths(tmp_path):
    """Guard the guard: the synthetic compare tests pass even if capture never fills it."""
    repo = _tiny_repo(tmp_path)
    state = purity.capture(parent=tmp_path)[purity.GUARDED_REPOS[0]]
    assert state.dirty_digests.get("research.py"), "modified tracked file was not digested"
    assert state.dirty_digests.get("brand_new.py"), "untracked file was not digested"
    assert state.dirty_digests["research.py"] != state.dirty_digests["brand_new.py"]


def test_an_edit_and_a_revert_are_both_caught_end_to_end(tmp_path):
    """The two blind spots, exercised against a real repo rather than a hand-built state."""
    repo = _tiny_repo(tmp_path)
    base = purity.capture(parent=tmp_path)

    (repo / "research.py").write_text("modified AGAIN\n")  # same porcelain entry
    edited = purity.capture(parent=tmp_path)
    assert base[purity.GUARDED_REPOS[0]].tracked_changes == (
        edited[purity.GUARDED_REPOS[0]].tracked_changes
    ), "precondition: git status must be identical, or this proves nothing"
    assert any("already modified" in p for p in purity.compare(base, edited))

    (repo / "research.py").write_text("original\n")  # the discard
    reverted = purity.capture(parent=tmp_path)
    assert any("DISCARDED" in p for p in purity.compare(base, reverted))


def test_porcelain_path_handles_renames_and_plain_entries():
    assert purity._porcelain_path(" M research.py") == "research.py"
    assert purity._porcelain_path("?? tests/new.py") == "tests/new.py"
    assert purity._porcelain_path("R  old.py -> new.py") == "new.py"


def test_volatile_dirs_are_not_digested(tmp_path):
    """queues/ churns on every production run; digesting it would mute the whole guard."""
    repo = _tiny_repo(tmp_path)
    (repo / "queues").mkdir()
    (repo / "queues" / "run-1").write_text("x")
    state = purity.capture(parent=tmp_path)[purity.GUARDED_REPOS[0]]
    assert not any(k.startswith("queues") for k in state.dirty_digests)


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
