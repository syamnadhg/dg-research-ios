#!/usr/bin/env python3
"""A full P0–P3 run **in the Simulator**, through the real substrate, against a mock platform.

What this is, and what it is not. It drives the **real** stack end to end: the real
`IOSSimulatorBackend`, the real IWDP DOM channel, real AXe trusted taps, the real measured
calibration, the real `PageShim`, the real wrapped intents, the real harvest predicates, the real
`run_pipeline`, and the real Firestore write sequence — all inside a real booted iOS Simulator. The
one thing it does **not** use is a real platform, because that needs credentials.

Which makes the remaining unknown precise: **the selector values.** Everything the selectors plug
into is exercised here. When the manifest is filled from a logged-in page, the code path this
already proves is the code path that runs.

The mock page is deliberately hostile in the two ways that matter, so this is not a walkover:

* Its send button is gated on the composer's **internal model**, not its DOM text — so assigning
  `textContent` leaves it disabled, exactly as a ProseMirror composer does. Only the
  `execCommand('insertText')` path works, which is what `PageShim.fill()` does.
* Its sources render as plain **DIVs, not `<a href>`** — reproducing the P1 raw-activity incident
  where every click landed and extraction returned 0 for a whole run.

Usage:
    python bin/e2e_simulator.py --udid <UDID> [--skip-reboot]
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

from emubackend import harvest, intents, phases, pipeline, selectors  # noqa: E402
from emubackend.contract import fixtures, rest  # noqa: E402
from emubackend.substrate.backend import IOSSimulatorBackend  # noqa: E402
from emubackend.substrate.page_shim import PageShim  # noqa: E402

PORT = 8901
PAGE_URL = f"http://127.0.0.1:{PORT}/"
MANIFEST = REPO / "fixtures" / "mockplatform" / "selectors_mock.json"
ARTIFACTS = REPO / "artifacts" / "e2e"


class _Resp:
    """Firestore is stubbed at the transport, not the contract: every write is still BUILT for real,
    encoded for real, and captured — only the network hop is elided, because a real write needs the
    owner's credentials."""

    status_code = 200
    ok = True
    content = b"{}"

    def json(self):
        return {}


def serve() -> subprocess.Popen | None:
    try:
        with urllib.request.urlopen(PAGE_URL, timeout=2):
            return None
    except Exception:
        pass
    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"],
        cwd=str(REPO / "fixtures" / "mockplatform"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(20):
        try:
            with urllib.request.urlopen(PAGE_URL, timeout=2):
                return proc
        except Exception:
            time.sleep(0.5)
    raise SystemExit("could not serve the mock platform")


async def wait_for(page: PageShim, js: str, timeout: float = 20.0) -> bool:
    """Poll an in-page condition.

    Needed because the mock (like a real platform) produces its response and sources *late*: reading
    straight after the tap finds nothing, which is indistinguishable from a tap that missed.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await page.evaluate(js):
            return True
        await asyncio.sleep(0.3)
    return False


async def run(udid: str, skip_reboot: bool) -> dict:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []

    def record(name: str, ok: bool, detail: str = "") -> None:
        results.append({"check": name, "pass": bool(ok), "detail": detail})
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    manifest = selectors.load_manifest(MANIFEST)
    done, total = manifest.coverage()
    record("mock manifest loaded", done == total and total > 0, f"{done}/{total} selectors resolvable")

    backend = IOSSimulatorBackend(udid=udid)
    await backend.start()
    capture = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=capture)

    try:
        tab = await backend.new_tab(PAGE_URL)
        page = PageShim(backend, tab)
        vp = await backend.read_viewport(tab)
        record(
            "real mobile viewport",
            (vp.get("innerWidth"), vp.get("innerHeight")) != (1280, 800),
            f"{vp.get('innerWidth')}x{vp.get('innerHeight')} CSS px",
        )

        deps = phases.PhaseDeps(
            manifest=manifest,
            registry=intents.IntentRegistry(),
            history=harvest.HarvestHistory(),
            pages={"chatgpt": page},
            topic="quantum error correction on mobile",
        )
        driver = phases.PlatformDriver("chatgpt", deps)

        # --- P0: logged in? -----------------------------------------------------
        record("P0 logged-in marker found", await driver.logged_in(), "#signed-in-marker present")

        # --- P2's toggle: a REAL trusted tap on the deep-research control --------
        before = await page.evaluate(
            "document.querySelector('[data-testid=\"deep-research-toggle\"]').getAttribute('aria-pressed')"
        )
        outcome = await driver.enable_deep_research()
        after = await page.evaluate(
            "document.querySelector('[data-testid=\"deep-research-toggle\"]').getAttribute('aria-pressed')"
        )
        record(
            "deep-research toggle flipped by a trusted tap",
            before == "false" and after == "true" and outcome is not None,
            f"aria-pressed {before} -> {after}, predicate_passed={outcome and outcome.predicate_passed}",
        )

        # --- P1/P2: type via the editor-aware path, then send -------------------
        await driver.focus_composer()
        await driver.type_brief(deps.topic)
        model_text = await page.evaluate(
            "document.querySelector('[data-testid=\"composer\"]').textContent"
        )
        send_enabled = await page.evaluate(
            "!document.querySelector('[data-testid=\"send-button\"]').disabled"
        )
        record(
            "execCommand path updated the composer's MODEL",
            deps.topic in (model_text or "") and bool(send_enabled),
            f"send enabled={send_enabled} — a textContent assignment would leave it disabled",
        )

        send_outcome = await driver.send()
        record(
            "send tapped and its predicate verified",
            bool(send_outcome.predicate_passed),
            f"reason={send_outcome.reason}",
        )

        ready = await wait_for(
            page,
            "!!document.querySelector('[data-testid=\"response-container\"][data-state=\"complete\"]')",
        )
        record("response arrived (late, as on a real platform)", ready, "")

        # --- P3: harvest sources that are NOT <a href> --------------------------
        await wait_for(page, "document.querySelectorAll('[data-testid=\"source\"]').length > 0")
        verdict = await driver.harvest_sources()
        anchors = await page.evaluate("document.querySelectorAll('#sources a[href]').length")
        record(
            "harvested non-anchor sources (the P1 shape)",
            verdict.ok and verdict.count >= 3 and anchors == 0,
            f"{verdict.count} sources, {anchors} <a href> present — a link-only harvest finds 0",
        )

        # --- the full P0-P3 loop, in the Simulator, writing the real contract ---
        ctx = pipeline.RunContext(
            uid="uid-e2e", research_id="rid-e2e", device_id="dev-e2e", run_id="run-e2e",
            client=client, registry=deps.registry,
        )
        bodies = phases.build_phase_bodies(deps, ("chatgpt",))
        run_phases = [
            pipeline.Phase(number=i, name=f"P{i}", body=b) for i, b in enumerate(bodies)
        ]
        result = await pipeline.run_pipeline(ctx, run_phases)
        events = [
            r.fields.get("type")
            for r in capture.records
            if r.op == "create" and r.path.endswith("pipeline_events")
        ]
        record(
            "FULL P0-P3 RUN COMPLETED IN THE SIMULATOR",
            result.status == "complete",
            f"status={result.status} phases={[p.status for p in result.phases]}",
        )
        record(
            "the contract write sequence is correct",
            events.count("phase_start") == 4
            and events.count("phase_complete") == 4
            and events[-1] == "pipeline_complete",
            f"{len(capture.records)} writes, {len(events)} events",
        )

        # --- reboot survival ---------------------------------------------------
        if not skip_reboot:
            marker = await page.evaluate("document.cookie")
            record("session cookie present before reboot", "mock_session" in (marker or ""), "")
            for store in (
                Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data"
            ).rglob("Cookies.binarycookies"):
                if b"mock_session" in store.read_bytes():
                    break
            else:
                # Wait for the flush rather than rebooting into a race — the operational rule B0a
                # produced: never hard-stop a Simulator straight after a login.
                for _ in range(30):
                    if any(
                        b"mock_session" in s.read_bytes()
                        for s in (
                            Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data"
                        ).rglob("Cookies.binarycookies")
                    ):
                        break
                    time.sleep(1)
            await backend.close()
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            time.sleep(2)
            subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True)
            time.sleep(3)

            backend2 = IOSSimulatorBackend(udid=udid)
            await backend2.start()  # rediscovers the per-boot IWDP socket
            tab2 = await backend2.new_tab(PAGE_URL)
            page2 = PageShim(backend2, tab2)
            after_cookie = await page2.evaluate("document.cookie")
            driver2 = phases.PlatformDriver(
                "chatgpt",
                phases.PhaseDeps(
                    manifest=manifest, registry=intents.IntentRegistry(),
                    history=harvest.HarvestHistory(), pages={"chatgpt": page2}, topic="x",
                ),
            )
            still_in = await driver2.logged_in()
            record(
                "SURVIVED A SIMULATOR REBOOT STILL SIGNED IN",
                "mock_session" in (after_cookie or "") and still_in,
                f"cookie present={'mock_session' in (after_cookie or '')}, marker present={still_in}",
            )
            await backend2.close()
        else:
            results.append({"check": "reboot survival", "pass": None, "detail": "skipped"})
    finally:
        try:
            await backend.close()
        except Exception:
            pass

    decided = [r for r in results if r.get("pass") is not None]
    verdict = {
        "gate": "e2e-simulator-mock",
        "udid": udid,
        "note": (
            "The full real stack in a real Simulator against a MOCK platform. The only unexercised "
            "variable is the selector values, which need a logged-in page."
        ),
        "results": results,
        "pass": all(r["pass"] for r in decided) and len(decided) > 0,
    }
    (ARTIFACTS / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--skip-reboot", action="store_true")
    args = ap.parse_args()
    serve()
    subprocess.run(["xcrun", "simctl", "boot", args.udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", args.udid, "-b"], capture_output=True)
    verdict = asyncio.run(run(args.udid, args.skip_reboot))
    print(f"\ne2e (Simulator, mock platform): {'PASS' if verdict['pass'] else 'FAIL'}")
    print(f"-> {ARTIFACTS / 'verdict.json'}")
    return 0 if verdict["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
