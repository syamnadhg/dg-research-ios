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

#: Where each real platform's run starts. Kept here rather than passed every time, because a typo'd URL
#: lands on a signed-out marketing page whose DOM is a different site wearing the same hostname — and
#: capture already drafted a whole manifest from exactly that mistake once.
REAL_URLS = {
    "chatgpt": "https://chatgpt.com/",
    "claude": "https://claude.ai/new",
    "gemini": "https://gemini.google.com/app",
    "notebooklm": "https://notebooklm.google.com/",
}

#: A real deep-research run takes minutes; the mock answers in under a second. One constant cannot serve
#: both — see ``phases.build_phase_bodies``.
#:
#: ⚠ 300s was measured to be too short and the failure was informative: the wait returned at 7 polls
#: with the assistant turn reading ``Pro thinking``, because content stability had not yet learned to
#: defer to the platform's stop control. With that veto in place the wait now correctly keeps waiting —
#: which means the budget has to be honest about how long a Pro deep-research run actually takes. This
#: is the real cost of testing the real thing, and shortening it would only reintroduce a timeout that
#: looks like a broken page.
MOCK_RESPONSE_TIMEOUT = 20.0
REAL_RESPONSE_TIMEOUT = 1200.0


#: What the page looked like when a harvest came back empty.
#:
#: Deliberately broad, and deliberately not selector-driven: the question this answers is "was the
#: manifest wrong, or was there genuinely nothing to cite" — so reading it through the manifest would
#: beg the question. Every field distinguishes one of the candidate explanations.
_EMPTY_HARVEST_DUMP_JS = """(() => {
  const clip = (s, n) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, n);
  const turns = [...document.querySelectorAll('[data-turn]')].map(t => ({
      turn: t.getAttribute('data-turn'),
      state: t.getAttribute('data-state'),
      chars: (t.innerText || '').length,
      text: clip(t.innerText, 1200),
  }));
  return {
      url: location.href,
      // Did the answer even finish, and is it an answer or a question back?
      turns,
      // A deep-research run that is still working, or waiting on the user, looks like this.
      visible_controls: [...document.querySelectorAll('button,[role=button]')]
          .filter(e => !!e.offsetParent)
          .map(e => clip((e.innerText || '') + ' | ' + (e.getAttribute('aria-label') || ''), 60))
          .filter(s => s !== '|'),
      // The candidate shapes a `sources` selector could plausibly be aiming at.
      anchors_http: document.querySelectorAll('a[href^="http"]').length,
      elements_with_citation_ish_attrs: [...document.querySelectorAll('*')]
          .filter(e => [...e.attributes].some(a =>
              /cite|source|reference|footnote/i.test(a.name + ' ' + a.value)))
          .slice(0, 25)
          .map(e => clip(e.tagName + '[' + [...e.attributes]
              .map(a => a.name + '=' + a.value).join('][') + ']', 120)),
      deep_research_pill: [...document.querySelectorAll('form *')]
          .filter(e => /deep research/i.test(e.innerText || ''))
          .map(e => clip(e.innerText, 40)),
  };
})()"""


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


async def run(
    udid: str,
    skip_reboot: bool,
    platform: str = "mockplatform",
    manifest_path: Path | None = None,
    page_url: str | None = None,
    topic: str = "quantum error correction on mobile",
) -> dict:
    """P0–P3 through the real substrate, against either the mock platform or a real one.

    The mock path is the substrate proof: a hostile page, in a real Simulator, with reboot survival —
    everything except the selector values. The real path is what closes that last variable, and it
    became runnable only once **Safari** was signed in: ``new_tab`` goes through ``simctl openurl``, so
    the page lands in Safari's cookie jar. The app's jar is a different one and cannot be shared.

    The mock-only checks are gated rather than deleted. Two of them (the trust-gated control, the
    seeded session cookie) are properties of a page written to be hostile in specific ways; asking a
    real platform for them would fail for reasons that say nothing about the substrate.
    """
    real = platform != "mockplatform"
    manifest_path = manifest_path or MANIFEST
    page_url = page_url or (REAL_URLS[platform] if real else PAGE_URL)
    # ⚠ The mock manifest declares its platform as ``chatgpt`` — the mock IS a stand-in for ChatGPT, so
    # the driver has to be built under that key. Parameterising the platform swapped in "mockplatform"
    # and the manifest lookup then failed with "Known keys for mockplatform: []", which reads as a
    # corrupt manifest rather than a renamed key.
    manifest_key = platform if real else "chatgpt"
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []

    def record(name: str, ok: bool, detail: str = "") -> None:
        results.append({"check": name, "pass": bool(ok), "detail": detail})
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    manifest = selectors.load_manifest(manifest_path)
    done, total = manifest.coverage()
    if real:
        # ⚠ The bar is "every key THIS run needs", not "every key in the file". The real manifest is
        # deliberately partial — four platforms, and the keys for a platform nobody has captured yet are
        # absent by design. Requiring done == total would gate a working ChatGPT run on NotebookLM.
        needed = ("logged_in_marker", "composer", "send", "response_container", "sources")
        absent = [k for k in needed if not manifest.entry(manifest_key, k).resolvable]
        record(
            f"{platform} manifest has every key this run needs",
            not absent,
            f"{done}/{total} resolvable overall; missing for this run: {absent or 'none'}",
        )
    else:
        record(
            "mock manifest loaded",
            done == total and total > 0,
            f"{done}/{total} selectors resolvable",
        )

    backend = IOSSimulatorBackend(udid=udid)
    await backend.start()
    capture = fixtures.CaptureTransport(lambda *a, **k: _Resp())
    client = rest.FirestoreRest(lambda force=False: "tok", "proj", transport=capture)

    try:
        tab = await backend.new_tab(page_url)
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
            pages={manifest_key: page},
            topic=topic,
        )
        driver = phases.PlatformDriver(manifest_key, deps)

        # --- P0: logged in? -----------------------------------------------------
        record(
            "P0 logged-in marker found",
            await driver.logged_in(),
            f"{manifest.entry(manifest_key, 'logged_in_marker').css or 'text probe'} present"
            + (" — a REAL session, in Safari's cookie jar" if real else ""),
        )
        if real:
            # Readiness before anything reads the page. A real platform serves a splash shell first, and
            # the whole point of asking for the composer specifically is that a shell can satisfy a
            # weaker chain while having nothing to type into.
            record(
                "the composer became interactable (not merely present)",
                await driver.await_composer_ready(timeout=45.0),
                "asked for the composer by name, because a readiness predicate must name the thing "
                "that depends on it",
            )

        # --- the channel comparison that decides C1's shape ----------------------
        # Mock-only: the control exists to be trust-gated. Skipping it on a real platform is not a
        # coverage hole — #88 answered the question on the real pages by driving send on ChatGPT, Claude
        # AND Gemini: every dispatched event reported isTrusted === false and all three sent anyway.
        if real:
            results.append(
                {
                    "check": "CHANNEL: trust-gating",
                    "pass": None,
                    "detail": "mock-only control; answered on real platforms by #88 (nothing gates on trust)",
                }
            )
        else:
            # The same page, the same control, the two available input channels. The in-app C0 gate
            # measured that a WKWebView script click reports isTrusted=false and CANNOT move a control
            # gated on it. Here, AXe delivers a genuine HID tap through the Simulator, so the same
            # control must MOVE. Asserting both halves is what makes the difference a measured fact
            # rather than an assumption about which substrate to trust — and it is the concrete reason
            # Stage 1 is not merely a stepping stone to the app.
            gated_before = await page.evaluate(
                "document.querySelector('[data-testid=\"trust-gated\"]').getAttribute('aria-pressed')"
            )
            gated_handle = await page.query_selector('[data-testid="trust-gated"]')
            if gated_handle is not None:
                await gated_handle.click()
            gated_after = await page.evaluate(
                "document.querySelector('[data-testid=\"trust-gated\"]').getAttribute('aria-pressed')"
            )
            record(
                "CHANNEL: a trusted AXe tap DOES drive a trust-gated control",
                gated_before == "false" and gated_after == "true",
                f"aria-pressed {gated_before} -> {gated_after} — the same control the in-app WKWebView "
                f"cannot move by script. Stage 1 has an input channel the app does not.",
            )

        # --- P2's toggle: a REAL trusted tap on the deep-research control --------
        #
        # ⚠ On a real platform the state is read through the PORTED PREDICATE, not `aria-pressed`. That
        # attribute is the wrong question there and the mistake is silent: driving ChatGPT's Deep
        # research item flipped it ON while `pressed` stayed FALSE throughout, so an aria-pressed reader
        # sees no change across an activation that plainly happened. The backend's own comment records
        # what that costs — "a pressed-class-only check false-negatived an ACTIVE pill last E2E and the
        # CUA fallback then toggled the working DR OFF".
        async def _dr_state() -> str:
            if real:
                for key in ("deep_research_toggle", "research_toggle"):
                    if key in manifest.platforms.get(manifest_key, {}):
                        return "true" if await driver._toggle_on_predicate(key)() else "false"
                return "n/a"
            return await page.evaluate(
                "document.querySelector('[data-testid=\"deep-research-toggle\"]')"
                ".getAttribute('aria-pressed')"
            )

        before = await _dr_state()
        outcome = await driver.enable_deep_research()
        after = await _dr_state()
        # Asserted as "ends ON", not "flipped from off to on".
        #
        # ⚠ The old assertion — `before == "false" and after == "true"` — silently required a FRESH
        # page, and that requirement is what hid a real bug for every run of this gate. Toggle state
        # persists across sessions on the real platforms (persistent login is the whole premise), so
        # the second run finds it already on; the step then tapped it OFF and the gate reported a
        # failure that looked like a flaky tap rather than an idempotence defect. A gate that only
        # passes from one starting state is a gate that cannot see the second run.
        dr_signal = "the ported ON predicate" if real else "aria-pressed"
        record(
            "deep research ends ENABLED, from either starting state",
            after in ("true", "n/a")
            and (outcome is None or outcome.predicate_passed)
            and not (real and after == "n/a"),
            f"{dr_signal} {before} -> {after}, "
            f"predicate_passed={outcome and outcome.predicate_passed}"
            + (" (already on; correctly not tapped)" if before == "true" else ""),
        )

        # --- P1/P2: type via the editor-aware path, then send -------------------
        if real and not await driver.await_composer_ready(timeout=45.0):
            record("composer came back after enabling deep research", False, "it did not")
        await driver.focus_composer()
        await driver.type_brief(deps.topic)
        if real:
            # Read back through the MANIFEST's composer, not a mock testid. The question is the same one
            # the mock asks — did the editor's internal model change, or only its DOM text — and the
            # answer still has to come from the element the run actually typed into.
            composer_entry = manifest.entry(manifest_key, "composer")
            handle = await phases.resolve(page, composer_entry)
            model_text = (await handle.inner_text()) if handle is not None else ""
            send_present = await phases.resolve(page, manifest.entry(manifest_key, "send")) is not None
            record(
                "execCommand path updated the composer's MODEL",
                deps.topic in (model_text or ""),
                f"read back {len(model_text or '')} chars from {composer_entry.css}; "
                f"send control present={send_present} "
                f"(ChatGPT MOUNTS send only once the composer is non-empty, so its presence is itself "
                f"evidence the model changed — Claude and Gemini keep it mounted always)",
            )
        else:
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

        if real:
            # The production wait, on the production path — the same `await_response` P3 uses, rather
            # than a bespoke JS poll. `[data-state=complete]` is mock-only among the platforms measured
            # here, so a real run reaches completion through content stability with the empty guard.
            waited = await driver.await_response(timeout=REAL_RESPONSE_TIMEOUT)
            record(
                "response completed (through the production wait, not a bespoke poll)",
                bool(waited["done"]),
                f"{waited['reason']}, polls={waited.get('polls')}, chars={waited.get('chars')}",
            )
        else:
            ready = await wait_for(
                page,
                "!!document.querySelector('[data-testid=\"response-container\"][data-state=\"complete\"]')",
            )
            record("response arrived (late, as on a real platform)", ready, "")

        # --- P3: harvest --------------------------------------------------------
        if real:
            if manifest.entry(manifest_key, "sources").resolvable:
                verdict = await driver.harvest_sources()
                # Asked independently of the harvest, so "nothing to harvest" and "the harvest is
                # broken" cannot be confused — the P1 incident was exactly that confusion.
                anchors = await page.evaluate(
                    "document.querySelectorAll('a[href^=\"http\"]').length"
                )
                if not verdict.count:
                    # ⚠ Record WHAT the run was looking at, not just that it found nothing.
                    #
                    # This is the P1 lesson stated as code. There, every click landed and extraction
                    # returned 0 for a whole run, and the logs said only "0 sources" — which is equally
                    # consistent with a rotted selector, an unfinished answer, and a page that had
                    # nothing to cite. Distinguishing them afterwards was impossible because the DOM
                    # was gone: `chatgpt.com/` opens a FRESH chat, so the conversation cannot be
                    # revisited. The evidence has to be captured while it exists.
                    dump = await page.evaluate(_EMPTY_HARVEST_DUMP_JS)
                    path = ARTIFACTS / f"empty_harvest_{platform}.json"
                    path.write_text(json.dumps(dump, indent=2) + "\n")
                    print(f"    ↳ empty harvest — page evidence written to {path}")
                record(
                    "harvested real sources, and the harvest was JUDGED not merely collected",
                    verdict.ok and verdict.count > 0,
                    f"{verdict.count} sources, reason={verdict.reason}, "
                    f"{anchors} http anchors on the page",
                )
            else:
                results.append(
                    {
                        "check": "P3 harvest",
                        "pass": None,
                        "detail": f"{platform}.sources not captured yet — the run cannot harvest what "
                        f"the manifest cannot name, and a hardcoded guess is the P1 failure",
                    }
                )
        else:
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
        bodies = phases.build_phase_bodies(
            deps,
            (manifest_key,),
            response_timeout=REAL_RESPONSE_TIMEOUT if real else MOCK_RESPONSE_TIMEOUT,
        )
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
            # The mock seeds a cookie it can name; a real platform's session cookie name is its own
            # business, so the durable question is asked of the JAR and then of the PAGE.
            cookie_token = "mock_session" if not real else page_url.split("//", 1)[-1].split("/", 1)[0]
            marker = await page.evaluate("document.cookie")
            record(
                "session cookie present before reboot",
                bool(marker) if real else "mock_session" in (marker or ""),
                f"{len(marker or '')} chars of document.cookie"
                + ("" if real else " containing mock_session"),
            )
            for store in (
                Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data"
            ).rglob("Cookies.binarycookies"):
                if cookie_token.encode() in store.read_bytes():
                    break
            else:
                # Wait for the flush rather than rebooting into a race — the operational rule B0a
                # produced: never hard-stop a Simulator straight after a login.
                for _ in range(30):
                    if any(
                        cookie_token.encode() in s.read_bytes()
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
            tab2 = await backend2.new_tab(page_url)
            page2 = PageShim(backend2, tab2)
            after_cookie = await page2.evaluate("document.cookie")
            driver2 = phases.PlatformDriver(
                manifest_key,
                phases.PhaseDeps(
                    manifest=manifest, registry=intents.IntentRegistry(),
                    history=harvest.HarvestHistory(), pages={manifest_key: page2}, topic="x",
                ),
            )
            still_in = await driver2.logged_in()
            record(
                "SURVIVED A SIMULATOR REBOOT STILL SIGNED IN",
                # ⚠ For a real platform the MARKER is the verdict, not the cookie. A signed-out page
                # also has cookies, so "cookies exist" would pass a run that had been logged out —
                # the exact false-positive the logged_in_marker exists to prevent.
                still_in if real else ("mock_session" in (after_cookie or "") and still_in),
                f"cookie chars={len(after_cookie or '')}, logged-in marker present={still_in}",
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
        "gate": f"e2e-simulator-{platform}",
        "udid": udid,
        "platform": platform,
        "manifest": str(manifest_path),
        "manifest_source": manifest.source,
        "page_url": page_url,
        "note": (
            f"The full real stack in a real Simulator against REAL {platform}, in Safari's cookie jar. "
            f"Nothing here is mocked except the Firestore transport, which is captured and compared."
            if real
            else "The full real stack in a real Simulator against a MOCK platform. The only "
            "unexercised variable is the selector values, which need a logged-in page."
        ),
        "results": results,
        "pass": all(r["pass"] for r in decided) and len(decided) > 0,
    }
    name = "verdict.json" if not real else f"verdict_{platform}.json"
    (ARTIFACTS / name).write_text(json.dumps(verdict, indent=2) + "\n")
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--skip-reboot", action="store_true")
    ap.add_argument(
        "--platform",
        default="mockplatform",
        choices=["mockplatform", *REAL_URLS],
        help="mockplatform (the substrate proof) or a real platform in Safari's cookie jar",
    )
    ap.add_argument("--manifest", help="defaults to the mock manifest, or selectors_mobile.json")
    ap.add_argument("--url", help="overrides the platform's default start URL")
    ap.add_argument("--topic", default="quantum error correction on mobile")
    args = ap.parse_args()
    real = args.platform != "mockplatform"
    manifest_path = Path(args.manifest) if args.manifest else (
        REPO / "selectors_mobile.json" if real else MANIFEST
    )
    if not real:
        serve()
    subprocess.run(["xcrun", "simctl", "boot", args.udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", args.udid, "-b"], capture_output=True)
    verdict = asyncio.run(
        run(
            args.udid,
            args.skip_reboot,
            platform=args.platform,
            manifest_path=manifest_path,
            page_url=args.url,
            topic=args.topic,
        )
    )
    print(f"\ne2e (Simulator, {args.platform}): {'PASS' if verdict['pass'] else 'FAIL'}")
    print(f"-> {ARTIFACTS / ('verdict.json' if not real else f'verdict_{args.platform}.json')}")
    return 0 if verdict["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
