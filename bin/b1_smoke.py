#!/usr/bin/env python3
"""B1 smoke test — drive the real Simulator through the seam, not through the raw channels.

B0a proved the two channels work. This proves the *seam* over them works: the injected
runtime, the handle registry, the calibration-on-any-page overlay, and `PageShim`'s
Playwright-shaped surface. Everything the unit tests fake is real here.

Usage:  python bin/b1_smoke.py [--udid UDID]
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

from emubackend.substrate import runtime_js  # noqa: E402
from emubackend.substrate.backend import IOSSimulatorBackend  # noqa: E402
from emubackend.substrate.page_shim import PageShim, StaleHandleError  # noqa: E402

PAGE_URL = "http://127.0.0.1:8899/"


def ensure_server() -> None:
    try:
        with urllib.request.urlopen(PAGE_URL, timeout=3):
            return
    except Exception:
        pass
    subprocess.Popen(
        [sys.executable, "-m", "http.server", "8899", "--bind", "127.0.0.1"],
        cwd=str(REPO / "fixtures" / "b0a"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(20):
        try:
            with urllib.request.urlopen(PAGE_URL, timeout=2):
                return
        except Exception:
            time.sleep(0.5)
    raise SystemExit("could not serve the fixture page")


async def main(udid: str) -> int:
    ensure_server()
    backend = IOSSimulatorBackend(udid=udid)
    results: list[dict] = []

    def record(name: str, ok: bool, detail: str = "") -> None:
        results.append({"check": name, "pass": bool(ok), "detail": detail})
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    await backend.start()
    try:
        record("backend.health", await backend.health(), f"udid={udid}")

        tab = await backend.new_tab(PAGE_URL)
        page = PageShim(backend, tab)

        # ⚠ The fixture page ships its own full-viewport calibration div, VISIBLE on load.
        # B0a happened to hide it as a side effect of calibrating through B0A_PROBE; now that
        # the seam calibrates through the injected __sr runtime, nothing hides it and it
        # intercepts every tap (the tap lands trusted, on the overlay, reporting
        # targetId='calib'). Turn it off explicitly — a fixture artifact, not a seam defect,
        # but exactly the kind that reads as "the tap missed".
        await page.evaluate("window.__b0a.calib(false)")

        installed = await page.evaluate(f"typeof window.{runtime_js.NS}")
        record("runtime injected", installed == "object", f"typeof window.{runtime_js.NS} == {installed!r}")

        # Idempotency matters: it is re-injected after every navigation.
        again = await page.evaluate(runtime_js.RUNTIME_JS)
        record("runtime re-injection is idempotent", again == "already", f"returned {again!r}")

        vp = await backend.read_viewport(tab)
        w, h = page.viewport()
        record(
            "real mobile viewport (not 1280x800)",
            (w, h) != (1280, 800) and w > 0 and h > 0,
            f"{w}x{h} CSS px, vvHeight={vp.get('vvHeight')}",
        )

        el = await page.query_selector("#t1")
        record("query_selector returns a handle", el is not None, f"handle id={el and el.id}")

        text = await el.inner_text()
        record("inner_text over the handle registry", "T1" in text, f"{text!r}")

        attr = await el.get_attribute("class")
        record("get_attribute", attr == "target", f"class={attr!r}")

        box = await el.bounding_box()
        record(
            "bounding_box uses Playwright key names",
            box is not None and set(box) == {"x", "y", "width", "height"},
            json.dumps(box),
        )

        record("is_visible", await el.is_visible(), "")

        # The headline check: a trusted tap driven entirely through the seam, including the
        # calibration overlay injected into a page that does not ship one.
        await page.evaluate("window.__b0a.reset()")
        event = await el.click()
        landed = bool(event.get("isTrusted"))
        record(
            "PageShim click is a TRUSTED tap",
            landed,
            f"isTrusted={event.get('isTrusted')} client=({event.get('clientX')},{event.get('clientY')})",
        )
        # Asserted on the RETURNED event, which is what tap_element's own contract says is the
        # evidence — "the caller is expected to assert on its targetId".
        #
        # ⚠ The previous version scanned the fixture's own `__b0a.events` recorder instead, and that
        # was wrong in a way that made the check unreliable rather than strict: the recorder
        # accumulates every tap the page sees, including the four calibration probe taps and their
        # pointerdown/touchstart/click triples, and calibration resets `__sr.events` rather than
        # `__b0a.events`. So the list it inspected was mostly calibration noise, and whether the aimed
        # tap appeared in it depended on ordering the check did not control. The returned event is
        # unambiguous: it is the event captured for THIS tap.
        hit_target = event.get("targetId")
        record(
            "the tap hit the element we aimed at",
            hit_target == "t1",
            f"targetId={hit_target!r} — the tap landed ON #t1, not merely somewhere trusted",
        )

        # The calibration overlay must be gone, or the page is left unusable.
        overlay_gone = await page.evaluate("!document.querySelector('[data-sr-overlay]')")
        record("calibration overlay removed afterwards", bool(overlay_gone), "")

        # Text entry through the editor-aware path.
        inp = await page.query_selector("#inp")
        filled = await inp.fill("seam works")
        value = await page.evaluate("document.getElementById('inp').value")
        record(
            "fill() writes via the editor-aware path",
            value == "seam works",
            f"path={filled.get('path')!r} value={value!r}",
        )

        # A detached handle must raise, never silently no-op.
        stale = await page.query_selector("#t1")
        await page.evaluate("document.getElementById('t1').remove()")
        try:
            await stale.inner_text()
            record("detached handle raises", False, "it returned instead of raising")
        except StaleHandleError as exc:
            record("detached handle raises StaleHandleError", True, str(exc)[:70])

        # Scroll by gesture, and confirm the calibration was invalidated by it.
        await page.evaluate("window.location.reload()")
        await asyncio.sleep(3)
        tab.runtime_ready = False
        await backend.scroll(tab, 0, 400)
        record(
            "scroll() invalidates the calibration",
            tab.calibration is None,
            "chrome may have moved, so a re-measure is forced",
        )
        after_scroll = await backend.read_viewport(tab)
        record(
            "gesture scroll actually moved the page",
            (after_scroll.get("scrollY") or 0) > 50,
            f"scrollY={after_scroll.get('scrollY')}",
        )
    finally:
        await backend.close()

    ok = all(r["pass"] for r in results)
    out = REPO / "artifacts" / "b1"
    out.mkdir(parents=True, exist_ok=True)
    (out / "smoke.json").write_text(
        json.dumps({"gate": "B1-smoke", "udid": udid, "pass": ok, "results": results}, indent=2)
        + "\n"
    )
    print(f"\nB1 smoke: {'PASS' if ok else 'FAIL'} -> {out / 'smoke.json'}")
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    raise SystemExit(asyncio.run(main(ap.parse_args().udid)))
