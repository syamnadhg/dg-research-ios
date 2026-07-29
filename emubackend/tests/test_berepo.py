"""Tests for the read-only BE bridge.

The load-bearing assertions here are the two that would let A8 be violated quietly:
that the claimed-names list actually matches the BE checkout (so a new BE module cannot
sneak past it), and that `import research` really is side-effect-free.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from emubackend import berepo, purity

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


# --------------------------------------------------------------------------------------
# Locating the checkout
# --------------------------------------------------------------------------------------


def test_be_root_resolves_to_a_real_backend_checkout():
    root = berepo.be_root()
    assert root.is_dir()
    for marker in ("research.py", "auth", "models.py", "prompts.py"):
        assert (root / marker).exists(), f"{marker} missing from {root}"


def test_be_root_rejects_a_directory_that_is_not_the_backend(tmp_path, monkeypatch):
    """A wrong path must fail loudly here, not as a confusing ModuleNotFoundError later."""
    monkeypatch.setenv("DG_BE_CHECKOUT", str(tmp_path))
    with pytest.raises(berepo.BEHRepoError) as exc:
        berepo.be_root()
    assert "does not look like dg-research-backend" in str(exc.value)
    # The message must name what is missing, or the operator cannot act on it.
    assert "research.py" in str(exc.value)


def test_be_root_rejects_a_nonexistent_path(tmp_path, monkeypatch):
    monkeypatch.setenv("DG_BE_CHECKOUT", str(tmp_path / "nope"))
    with pytest.raises(berepo.BEHRepoError, match="not found"):
        berepo.be_root()


def test_ensure_on_path_is_idempotent_and_appends():
    root = berepo.ensure_on_path()
    first = list(sys.path)
    berepo.ensure_on_path()
    assert sys.path == first, "second call must not add a duplicate entry"
    assert sys.path.count(str(root)) == 1
    # Appended, never prepended: this repo's own modules must win a name resolution so
    # an accidental collision shows up as our code being used, not silently shadowed.
    assert sys.path.index(str(root)) > 0


# --------------------------------------------------------------------------------------
# The namespace hazard
# --------------------------------------------------------------------------------------


def test_claimed_names_list_matches_the_actual_backend_checkout():
    """If the BE gains a top-level module, this test is how we find out.

    A stale hard-coded list is worse than no list, because it reads as verified.
    """
    root = berepo.be_root()
    actual_modules = {p.stem for p in root.glob("*.py")}
    actual_dirs = {
        p.name
        for p in root.iterdir()
        if p.is_dir() and not p.name.startswith((".", "_")) and p.name != "logs"
    }
    # Every real importable/mergeable top-level name must be in the frozen list.
    unlisted = (actual_modules | actual_dirs) - berepo.CLAIMED_TOP_LEVEL_NAMES
    # Directories that are neither packages nor collision risks for us are fine to omit
    # only if they contain no Python at all.
    unlisted = {
        name
        for name in unlisted
        if (root / name).is_file() or any((root / name).rglob("*.py"))
    }
    assert not unlisted, (
        "the BE checkout claims top-level name(s) missing from "
        f"berepo.CLAIMED_TOP_LEVEL_NAMES: {sorted(unlisted)} — add them, and make sure "
        "this repo does not define them"
    )


def test_this_repo_defines_no_name_the_backend_claims():
    """The collision is structural, so check the structure, not our intentions."""
    ours = {p.stem for p in REPO_ROOT.glob("*.py")}
    ours |= {
        p.name
        for p in REPO_ROOT.iterdir()
        if p.is_dir() and not p.name.startswith((".", "_"))
    }
    collisions = ours & berepo.CLAIMED_TOP_LEVEL_NAMES
    assert not collisions, (
        f"top-level name(s) {sorted(collisions)} collide with the BE checkout, which is "
        "on sys.path — rename them or nest them under emubackend/"
    )


def test_import_be_rejects_a_name_the_backend_does_not_claim():
    with pytest.raises(berepo.BEHRepoError, match="not a name the BE checkout claims"):
        berepo.import_be("reserch")  # typo, deliberately


# --------------------------------------------------------------------------------------
# `import research` is cheap and side-effect-free — the premise A8 rests on
# --------------------------------------------------------------------------------------


def test_research_module_level_imports_are_only_models_and_prompts():
    """This is *why* the path injection needs no third-party dependency.

    Measured over ``ast.Module.body`` only, so function-local and lazily-deferred
    imports are excluded — the distinction a grep would get wrong.
    """
    root = berepo.be_root()
    third_party = berepo.module_level_third_party_imports(root / "research.py")
    assert third_party == {"models", "prompts"}, (
        f"research.py's module-level non-stdlib imports changed to {sorted(third_party)}; "
        "the zero-dependency claim in docs/DEVIATIONS.md D-1 needs revisiting"
    )


def test_importing_research_in_a_subprocess_writes_nothing_to_the_guarded_repos():
    """`import research` must be a pure read. Proven, not assumed.

    Run in a subprocess so that a module-level side effect cannot be masked by another
    test having already imported it.
    """
    code = (
        "import sys; sys.path.insert(0, %r)\n"
        "from emubackend import berepo\n"
        "berepo.ensure_on_path()\n"
        "import research\n"
        "print('OK', bool(research.__file__))\n" % str(REPO_ROOT)
    )
    with purity.no_queue_writes():
        before = purity.capture()
        proc = subprocess.run(
            [sys.executable, "-c", code], capture_output=True, text=True, timeout=180
        )
        after = purity.capture()

    assert proc.returncode == 0, f"import research failed:\n{proc.stderr}"
    assert "OK True" in proc.stdout
    problems = purity.compare(before, after)
    assert not problems, "importing research modified a guarded repo:\n" + "\n".join(
        problems
    )
