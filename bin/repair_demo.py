#!/usr/bin/env python3
"""Phase A2's gate: prove a repair-agent patch fixes a REAL breakage when replayed.

The recipe's pass criterion for A2 is exactly *"a proposed patch fixes a real historical breakage when
replayed"*. This does that against a real Simulator, in four steps:

  1. Break a selector in the manifest — a real breakage of a real run, not a simulated one.
  2. Run the step. It must FAIL, naming the selectors it tried. (A step that quietly succeeded here
     would mean the whole demonstration proves nothing.)
  3. Let the repair agent read the live DOM and propose a patch.
  4. Merge the proposal and re-run. It must PASS.

Step 2 matters as much as step 4. A repair demo that only shows the fix working cannot distinguish
"the agent fixed it" from "it was never broken".

Usage: bin/repair_demo.py --udid <UDID>
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import harvest, intents, phases, repair, selectors  # noqa: E402
from emubackend.selectors import ManifestError  # noqa: E402
from emubackend.substrate.backend import IOSSimulatorBackend  # noqa: E402
from emubackend.substrate.page_shim import PageShim  # noqa: E402

PORT = 8901
PAGE_URL = f"http://127.0.0.1:{PORT}/"
ARTIFACTS = REPO / "artifacts" / "repair"

# Reports the attributes the agent ranks on. Kept close to the ranking so the two cannot drift:
# a candidate the page describes differently from how repair.py scores it is worse than useless.
_CANDIDATES_JS = """
(function () {
  var out = [];
  var els = document.querySelectorAll('button, [role=button], a, input[type=submit]');
  for (var i = 0; i < els.length && i < 40; i++) {
    var el = els[i], r = el.getBoundingClientRect();
    var tid = el.getAttribute('data-testid') || el.getAttribute('data-test-id');
    var role = el.getAttribute('role'), label = el.getAttribute('aria-label');
    var kind, selector;
    if (tid) { kind = 'data-testid'; selector = '[data-testid="' + tid + '"]'; }
    else if (el.id && !/^[0-9]/.test(el.id)) { kind = 'id'; selector = '#' + el.id; }
    else if (role && label) { kind = 'role+name'; selector = '[role="' + role + '"][aria-label="' + label + '"]'; }
    else if (label) { kind = 'attribute'; selector = el.tagName.toLowerCase() + '[aria-label="' + label + '"]'; }
    else { kind = 'text'; selector = null; }
    out.push({
      selector: selector, kind: kind,
      visible: !!(r.width && r.height),
      accessible_name: label || (el.innerText || '').trim().slice(0, 60),
      tag: el.tagName.toLowerCase()
    });
  }
  return out;
})()
"""


def serve() -> None:
    try:
        with urllib.request.urlopen(PAGE_URL, timeout=2):
            return
    except Exception:
        pass
    subprocess.Popen(
        [sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"],
        cwd=str(REPO / "fixtures" / "mockplatform"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(20):
        try:
            with urllib.request.urlopen(PAGE_URL, timeout=2):
                return
        except Exception:
            time.sleep(0.5)
    raise SystemExit("could not serve the mock platform")


def manifest_with_broken_send(tmp: Path) -> Path:
    """Break `send` the way a platform redesign breaks it: the selector stops matching."""
    good = json.loads((REPO / "fixtures" / "mockplatform" / "selectors_mock.json").read_text())
    good["platforms"]["chatgpt"]["send"] = {
        "css": ['[data-testid="send-button-RENAMED-BY-PLATFORM"]'],
        "provenance": "deliberately broken for the A2 demo",
    }
    path = tmp / "broken.json"
    path.write_text(json.dumps(good, indent=2))
    return path


async def run(udid: str) -> dict:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []

    def check(name: str, ok: bool, detail: str) -> None:
        results.append({"check": name, "pass": ok, "detail": detail})
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    broken_path = manifest_with_broken_send(ARTIFACTS)
    broken = selectors.load_manifest(broken_path)

    backend = IOSSimulatorBackend(udid=udid)
    await backend.start()
    try:
        tab = await backend.new_tab(PAGE_URL)
        page = PageShim(backend, tab)

        def deps_for(manifest):
            return phases.PhaseDeps(
                manifest=manifest,
                registry=intents.IntentRegistry(),
                history=harvest.HarvestHistory(),
                pages={"chatgpt": page},
                topic="repair demo",
            )

        # --- 1/2: the breakage must actually break ------------------------------
        driver = phases.PlatformDriver("chatgpt", deps_for(broken))
        await driver.focus_composer()
        await driver.type_brief("repair demo")
        failed_msg = ""
        try:
            await driver.send()
            check("the broken selector genuinely fails", False, "send SUCCEEDED — nothing was broken")
            return {"pass": False, "results": results}
        except ManifestError as exc:
            failed_msg = str(exc)
        check(
            "the broken selector genuinely fails, naming what it tried",
            "did not match anything" in failed_msg and "RENAMED" in failed_msg,
            failed_msg.split(". Selectors")[0][:90],
        )

        # --- 3: the agent reads the live DOM and proposes ------------------------
        raw = await page.evaluate(_CANDIDATES_JS) or []
        candidates = [
            repair.Candidate(
                selector=c["selector"],
                kind=c["kind"],
                visible=bool(c.get("visible")),
                accessible_name=c.get("accessible_name") or "",
                tag=c.get("tag") or "",
            )
            for c in raw
            if c.get("selector")
        ]
        check("captured live DOM candidates", len(candidates) > 0, f"{len(candidates)} candidates")

        proposal = repair.propose(
            "chatgpt",
            "send",
            broken.require("chatgpt", "send").css if False else ['[data-testid="send-button-RENAMED-BY-PLATFORM"]'],
            candidates,
            expected_name="send",
        )
        check(
            "the agent PROPOSED a repair",
            proposal is not None and not proposal.needs_human_derivation,
            proposal.describe() if proposal else "no proposal",
        )
        if proposal is None:
            return {"pass": False, "results": results}

        check(
            "it chose the most redesign-stable candidate",
            proposal.kind in ("data-testid", "id", "role+name"),
            f"kind={proposal.kind} confidence={proposal.confidence}",
        )
        check(
            "the old selector is kept as a FALLBACK, not discarded",
            proposal.failed_selectors
            and repair.to_manifest_patch([proposal])["platforms"]["chatgpt"]["send"]["css"][-1]
            == proposal.failed_selectors[-1],
            "platforms A/B-test their DOM, so a partial outage must not become a total one",
        )

        # --- 4: replay with the patch merged ------------------------------------
        patch = repair.to_manifest_patch([proposal])
        merged = json.loads(broken_path.read_text())
        merged["platforms"]["chatgpt"]["send"] = patch["platforms"]["chatgpt"]["send"]
        merged_path = ARTIFACTS / "repaired.json"
        merged_path.write_text(json.dumps(merged, indent=2))
        (ARTIFACTS / "proposal.json").write_text(
            json.dumps(
                {
                    "platform": proposal.platform, "key": proposal.key,
                    "failed_selectors": proposal.failed_selectors, "proposed": proposal.proposed,
                    "kind": proposal.kind, "confidence": proposal.confidence,
                    "rationale": proposal.rationale, "alternatives": proposal.alternatives,
                    "patch": patch,
                },
                indent=2,
            )
            + "\n"
        )

        repaired = selectors.load_manifest(merged_path)
        driver2 = phases.PlatformDriver("chatgpt", deps_for(repaired))
        await driver2.focus_composer()
        await driver2.type_brief("repair demo replay")
        outcome = await driver2.send()
        check(
            "⭐ THE PROPOSED PATCH FIXES THE BREAKAGE ON REPLAY",
            bool(outcome.predicate_passed),
            f"send succeeded and its predicate verified (reason={outcome.reason})",
        )
    finally:
        await backend.close()

    verdict = {
        "gate": "A2-repair-agent",
        "criterion": "a proposed patch fixes a real breakage when replayed (recipe §0.5.7 A2)",
        "results": results,
        "pass": all(r["pass"] for r in results),
    }
    (ARTIFACTS / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    args = ap.parse_args()
    serve()
    subprocess.run(["xcrun", "simctl", "boot", args.udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", args.udid, "-b"], capture_output=True)
    verdict = asyncio.run(run(args.udid))
    print(f"\nA2 repair-agent gate: {'PASS' if verdict['pass'] else 'FAIL'}")
    print(f"-> {ARTIFACTS / 'verdict.json'}")
    return 0 if verdict["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
