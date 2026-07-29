#!/usr/bin/env python3
"""Enforce *"the same runs inside the native app for every platform that cleared C0"*.

That clause was being tracked in prose — "met for the mock, the only platform that cleared C0" — which
is exactly the kind of claim that stays true in a summary long after it has stopped being true in the
repo. This computes the cleared set and asserts the C1 gate covered all of it, so the clause becomes a
gate rather than an assertion by whoever wrote the last report.

**"Cleared C0" is defined here, once:** a platform has cleared C0 when every selector its phases need is
resolvable in the loaded manifest. Missing selectors are the honest blocker (#82 — they can only come
from real logged-in mobile DOM), so a platform with gaps has not cleared and is not expected in C1.

The useful property is what happens *next*: the moment the owner supplies selectors for chatgpt, that
platform joins the cleared set and **this gate starts failing** until C1 has actually been run against
it. Nobody has to remember.

Usage: bin/coverage_gate.py [--manifest PATH]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import selectors as selectors_mod  # noqa: E402

C1_VERDICT = REPO / "artifacts" / "c1" / "verdict.json"
OUT = REPO / "artifacts" / "coverage" / "verdict.json"

#: Keys a platform must have before its P0-P3 can run at all. Deliberately narrower than the full key
#: set: `activity_panel` is optional, and demanding it would mark a platform unclear for a selector its
#: phases never require.
REQUIRED = ("logged_in_marker", "composer", "send", "sources", "response_container")


def cleared_platforms(manifest) -> dict[str, list[str]]:
    """platform -> the required keys it is still missing. Empty list means cleared."""
    out: dict[str, list[str]] = {}
    for platform, entries in sorted(manifest.platforms.items()):
        missing = [
            key
            for key in REQUIRED
            if key in entries and not entries[key].resolvable
        ]
        absent = [key for key in REQUIRED if key not in entries]
        out[platform] = sorted(missing + absent)
    return out


def c1_covered() -> set[str]:
    """Which platforms the C1 gate actually ran against."""
    if not C1_VERDICT.exists():
        return set()
    verdict = json.loads(C1_VERDICT.read_text())
    if not verdict.get("pass"):
        return set()   # a failing C1 covers nothing, whatever it names
    # The verdict names its platform in prose (e.g. "mockplatform (the only platform ...)"), so the
    # token before any parenthesis is the identifier.
    named = str(verdict.get("platform", "")).split("(")[0].strip()
    return {named} if named else set()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="where to write the verdict; defaults to artifacts/coverage/verdict.json",
    )
    args = parser.parse_args()

    manifest = selectors_mod.load_manifest(args.manifest)
    gaps = cleared_platforms(manifest)
    cleared = {platform for platform, missing in gaps.items() if not missing}
    blocked = {platform: missing for platform, missing in gaps.items() if missing}
    covered = c1_covered()

    # The mock is a platform in its own right and it is what C1 has cleared. It never appears in the
    # selector manifest (it is a fixture), so it is credited explicitly rather than inferred.
    if "mockplatform" in covered:
        cleared.add("mockplatform")

    uncovered = sorted(cleared - covered)
    failures = []
    if uncovered:
        failures.append(
            f"cleared C0 but never run in-app: {uncovered}. Clause 2 of the goal requires the same "
            f"P0-P3 run inside the app for EVERY platform that cleared C0 — run bin/c1_in_app.sh "
            f"against each."
        )

    verdict = {
        "gate": "coverage",
        "what": "every platform that cleared C0 has also run P0-P3 inside the native app",
        "definition_of_cleared": f"all of {list(REQUIRED)} resolvable in the manifest",
        "cleared": sorted(cleared),
        "covered_by_c1": sorted(covered),
        "blocked_on_selectors": {k: v for k, v in sorted(blocked.items())},
        "manifest_source": manifest.source,
        "failures": failures,
        "pass": not failures,
        "note": (
            "The blocked platforms are blocked on #82 — selectors can only come from real logged-in "
            "mobile DOM, which is an owner checkpoint. When selectors arrive, those platforms join "
            "'cleared' and this gate FAILS until C1 has been run against them."
        ),
    }
    # ⚠ A run against an alternate manifest must NOT overwrite the real verdict. Proving the gate
    # blocks (with fixtures/manifests/one_platform_cleared.json) wrote a FAIL over the repo's genuine
    # PASS the first time — a self-test that corrupts the artifact it is testing.
    out = args.out or (OUT if args.manifest is None else
                       OUT.parent / f"verdict-{args.manifest.stem}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(verdict, indent=2))

    for failure in failures:
        print(f"  [FAIL] {failure}")
    if not failures:
        print(f"  [PASS] cleared={sorted(cleared)} all covered by C1")
    if blocked:
        print(f"  [note] awaiting selectors (#82): {sorted(blocked)}")
    print(f"\ncoverage: {'PASS' if not failures else 'FAIL'} -> {out}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
