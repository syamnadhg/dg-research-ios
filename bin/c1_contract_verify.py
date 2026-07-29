#!/usr/bin/env python3
"""Diff the app's emitted write sequence against the golden fixture, and against the emulator.

Two checks, deliberately not one:

* **the emitted sequence vs `fixtures/golden/p0_p3_happy_path.jsonl`** — catches a write that the rules
  permit but that is WRONG: the wrong order, a missing event, phase 0 silently dropped.
* **what actually LANDED in the emulator** — catches the opposite failure, an emitter that logs
  beautifully and writes nothing. Comparing only the app's own log would trust the thing under test to
  report on itself.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GOLDEN = REPO / "fixtures" / "golden" / "p0_p3_happy_path.jsonl"
BASE = "http://127.0.0.1:8181/v1/projects/demo-sr/databases/(default)/documents"


def normalise(entry: dict, uid: str, research_id: str) -> dict:
    """Replace run-specific ids with the fixture's placeholders, leaving shape and order to compare."""
    path = entry["path"].replace(f"users/{uid}/researches/{research_id}", "users/{uid}/researches/{rid}")
    fields = {}
    for key, value in entry["fields"].items():
        if key == "backendRunId":
            fields[key] = "{runId}"
        elif key == "deviceId":
            fields[key] = "{deviceId}"
        else:
            fields[key] = value
    return {
        "op": entry["op"],
        "path": path,
        "fields": fields,
        "delete_paths": sorted(entry.get("delete_paths", [])),
    }


def main() -> int:
    log_path, uid, research_id = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    text = log_path.read_text(errors="replace")

    match = re.search(r"WRITE_LOG=(\[.*?\])\s*$", text, re.M | re.S)
    if not match:
        print("FAIL: the app produced no WRITE_LOG — it emitted nothing at all")
        return 1
    emitted = [normalise(e, uid, research_id) for e in json.loads(match.group(1))]

    golden = [
        {**json.loads(line), "delete_paths": sorted(json.loads(line).get("delete_paths", []))}
        for line in GOLDEN.read_text().splitlines()
        if line.strip()
    ]

    failures = []
    if len(emitted) != len(golden):
        failures.append(f"write COUNT differs: app emitted {len(emitted)}, fixture has {len(golden)}")
    for index, (got, want) in enumerate(zip(emitted, golden)):
        if got != want:
            failures.append(
                f"write #{index} differs:\n    app:     {json.dumps(got, sort_keys=True)}\n"
                f"    fixture: {json.dumps(want, sort_keys=True)}"
            )

    # And what actually landed — because an emitter that logs without writing would pass the diff.
    try:
        request = urllib.request.Request(
            f"{BASE}/users/{uid}/researches/{research_id}/pipeline_events",
            headers={"Authorization": "Bearer owner"},
        )
        with urllib.request.urlopen(request) as response:
            landed = json.load(response).get("documents", [])
    except Exception as error:  # noqa: BLE001 - reported, not raised
        landed = []
        failures.append(f"could not read the emulator back: {error}")

    expected_events = sum(1 for entry in golden if entry["path"].endswith("pipeline_events"))
    if len(landed) != expected_events:
        failures.append(
            f"pipeline_events in the emulator: {len(landed)}, expected {expected_events} — "
            f"an emitter that logs without writing would pass the diff alone"
        )

    # phase 0 specifically, because a truthiness guard on `phase` drops it and P0 is a real phase.
    phases = sorted(
        int(doc["fields"]["phase"]["integerValue"])
        for doc in landed
        if "phase" in doc.get("fields", {})
    )
    if 0 not in phases:
        failures.append("phase 0 is absent from the landed events — a truthiness guard on `phase`")

    verdict = {
        "gate": "C1-contract",
        "what": "the app's run writes, judged by the real rules AND diffed against the golden fixture",
        "emitted_writes": len(emitted),
        "landed_pipeline_events": len(landed),
        "phases_seen": sorted(set(phases)),
        "failures": failures,
        "pass": not failures,
    }
    out = REPO / "artifacts" / "c1contract" / "verdict.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(verdict, indent=2))

    for failure in failures:
        print(f"  [FAIL] {failure}")
    if not failures:
        print(f"  [PASS] {len(emitted)} writes match the golden fixture exactly")
        print(f"  [PASS] {len(landed)} pipeline_events landed in the emulator, phases {sorted(set(phases))}")
    print(f"\nC1 contract: {'PASS' if not failures else 'FAIL'} -> {out}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
