"""The mutation harness must not be able to leave a mutant behind in the source tree.

⛔ **This is a real incident, not a hypothetical.** `bin/mutate.py` edits sources in place and
restores them in a `finally`. That covers exceptions — but `SIGTERM`, which is what `pkill` and most
job supervisors send, terminates the interpreter *without* unwinding, so the `finally` never runs.
A background run was killed mid-mutation and `_dismiss_opener`'s `if not state.get("open")` was left
in the working tree as `if False`.

⚠ **What made it expensive was the presentation, not the corruption.** Nothing announced itself. The
next full suite showed four failures in `test_selectors_and_phases.py` about menus refusing to close
— which reads exactly like "the change you just made broke the opener logic", and the change in
question was in a completely different function. The corrupted line was three edits away from
anything recently touched.

Two defences, and this file is the second one:
  * `mutate.py` now restores from a signal handler, so the window closes on SIGTERM/SIGINT/SIGHUP;
  * this test names the corruption directly, so it can never again be diagnosed as a code bug.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def _mutations():
    """Import `bin/mutate.py` by path — it is a script, not an installed module."""
    spec = importlib.util.spec_from_file_location("_mutate", ROOT / "bin" / "mutate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_no_mutant_is_left_behind_in_any_source():
    """Every mutation's BROKEN text must be absent from the tree.

    ⚠ Asserted as "the mutant is present while its original is not", rather than just "the mutant
    string appears". Some mutants are substrings of ordinary code (`if False:` is not rare), so the
    presence of the replacement alone would false-positive; the pair is what identifies a source
    that has been edited and not put back.
    """
    corrupted = []
    for rel, old, new, node, _defect in _mutations().MUTATIONS:
        text = (ROOT / rel).read_text()
        if new in text and old not in text:
            corrupted.append(f"{rel}\n    left as: {new.strip()[:100]}\n    should be: {old.strip()[:100]}\n    (guard: {node})")
    assert not corrupted, (
        "bin/mutate.py left a mutation in the source tree — the repo is CORRUPTED, and any other "
        "test failure in this run is probably a symptom of it rather than a real defect:\n\n"
        + "\n\n".join(corrupted)
    )


def test_every_mutation_anchor_still_matches_exactly_once():
    """An anchor that matches 0 or 2 times scores nothing and reports no failure.

    The harness prints `ANCHOR MISS` and moves on, so a guard silently stops being verified the
    moment someone reformats the line it points at. That is the decorative-guard shape one level up:
    the mutation harness itself going quiet.
    """
    misses = []
    for rel, old, _new, node, _defect in _mutations().MUTATIONS:
        count = (ROOT / rel).read_text().count(old)
        if count != 1:
            misses.append(f"{rel}: anchor matches {count}x (guard: {node})")
    assert not misses, "these mutations no longer verify anything:\n  " + "\n  ".join(misses)


def test_the_harness_restores_on_a_SIGNAL_not_only_on_an_exception():
    """The fix itself, driven rather than eyeballed.

    ⚠ A presence assertion (`'signal' in source`) would pass against an import that is never wired
    to anything — which is the failure mode this repo has hit repeatedly. So this actually stages an
    in-flight mutation and invokes the handler.
    """
    mutate = _mutations()
    scratch = ROOT / "emubackend" / "tests" / "_mutation_restore_probe.tmp"
    original = b"the original bytes\n"
    scratch.write_bytes(original)
    try:
        mutate._IN_FLIGHT[scratch] = original
        scratch.write_bytes(b"MUTATED\n")
        assert scratch.read_bytes() == b"MUTATED\n"

        with pytest.raises(SystemExit) as exit_info:
            mutate._on_signal(15, None)

        assert scratch.read_bytes() == original, "the signal handler did not restore the source"
        assert not mutate._IN_FLIGHT, "the in-flight record outlived the restore"
        # 128+n: a run that was killed must not look like a run that passed.
        assert exit_info.value.code == 143
    finally:
        mutate._IN_FLIGHT.pop(scratch, None)
        scratch.unlink(missing_ok=True)


def test_the_signal_handler_is_actually_INSTALLED_for_the_kill_signals():
    """A handler that exists but is never registered restores nothing.

    Read off `main`'s source because installing the handlers for real would replace this test
    process's own disposition — but the assertion is on the registration call, which is the wiring
    that was missing, not on the handler's mere existence (tested above by running it).
    """
    import inspect

    source = inspect.getsource(_mutations().main)
    for name in ("SIGTERM", "SIGINT", "SIGHUP"):
        assert name in source, f"{name} is not handled, so a kill by that signal still corrupts"
    assert "signal.signal(" in source
