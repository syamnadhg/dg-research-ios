#!/usr/bin/env python3
"""GATE ZERO (EmulatorRecipe.md §3): where does the report DOM actually live?

Run this against a **completed** ChatGPT Deep Research page — not a running one. The whole
point of the gate is that the 2026-07-30 reads (15 -> 204 -> 27 chars, sitting on
``Pro thinking`` while ``Stop answering`` was still on screen) are equally consistent with
seven different causes, and only a completed page separates them.

    ios_webkit_debug_proxy -s "unix:$(...)"        # or let --udid discover it
    .venv/bin/python bin/gate_zero_probe.py --udid <UDID> --url chatgpt.com

It prints the four probe outputs verbatim, then a verdict against the recipe's
**pre-declared** pass observable so the answer is not a judgement call made after seeing
the data: a single element whose text exceeds the BE's own tier floor of 2000 chars and
which trips neither the sources-not-document nor the nav-sidebar guard.

⚠ It also prints the *completion* check first and refuses to run the probes if the stop
control is still on screen. Confirming completion by elapsed time instead of by the
absence of that control is exactly how the original measurement went wrong.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from emubackend.substrate import iwdp  # noqa: E402

#: BE research.py's tier floor. A "report" shorter than this is not a report.
REPORT_FLOOR_CHARS = 2000

#: The UA token the app pins in `customUserAgent`; Simulator Safari reports `Version/26.5`.
#:
#: ⚠ This tool originally selected its page by URL substring, which on this device is a coin flip
#: with a signed-out page on one face: BOTH surfaces serve `https://chatgpt.com/`, and only the app
#: is signed in (`docs/DEVIATIONS.md`, *"Gate zero must run IN-APP"*). A gate that measures the
#: wrong surface reports "no report node" for the most boring possible reason and sends the reader
#: looking for frames.
APP_UA_TOKEN = "Version/17.0"

# --- the four probes, verbatim from recipe §3.2 -------------------------------------

#: ⚠ **The stop control is NOT a completion signal for a Deep Research run**, and keying the gate on
#: its absence made this check a guard that cannot fire. Measured in-app: `button[data-testid=
#: "stop-button"]` was absent from the first poll onward while the run was demonstrably in flight —
#: DR renders its progress in a sandbox frame and leaves the composer idle, so "no stop control"
#: describes a page that has not started, a page mid-research, and a finished page identically.
#:
#: So this collects signals and lets `completion_verdict` judge, with **unknown treated as a
#: refusal**. An unreadable verdict must refuse, not fall through.
PROBE_COMPLETION = """
(() => {
  const stop = document.querySelector('button[data-testid="stop-button"], button[aria-label*="Stop"]');
  const skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1 };
  let rendered = 0;
  for (const el of document.querySelectorAll('*')) {
    if (skip[el.tagName]) continue;
    const n = (el.innerText||'').length;
    if (n > rendered) rendered = n;
  }
  const frames = [...document.querySelectorAll('iframe')]
    .filter(f => f.clientWidth > 0 && f.clientHeight > 0)
    .map(f => ({ src: (f.src || '').split('?')[0], w: f.clientWidth, h: f.clientHeight }));
  return { stopControlPresent: !!stop,
           stopLabel: stop ? (stop.getAttribute('aria-label') || stop.getAttribute('data-testid')) : null,
           longestRenderedChars: rendered,
           visibleFrames: frames,
           url: location.href, title: document.title };
})()
"""

#: The BE's own in-flight vocabulary, ported. Any of these on screen means "still working".
IN_FLIGHT_MARKERS = (
    "stop answering", "stop generating", "researching", "thinking",
    "working on it", "starting research", "planning",
)

PROBE_1_TURNS = """
[...document.querySelectorAll('[data-turn]')].map(t => ({
  turn: t.getAttribute('data-turn'), chars: (t.innerText||'').length,
  html: (t.innerHTML||'').length, head: (t.innerText||'').trim().slice(0,80) }))
"""

PROBE_2_IFRAMES = """
[...document.querySelectorAll('iframe')].map(f => { let access;
  try { access = f.contentDocument ? 'SAME-ORIGIN: ' + f.contentDocument.body.innerText.length + ' chars'
                                   : 'null contentDocument'; }
  catch (e) { access = 'THREW: ' + e.name; }
  return { src: f.src || '(none)', origin: (()=>{try{return new URL(f.src).origin}catch{return '?'}})(),
           pageOrigin: location.origin, w: f.clientWidth, h: f.clientHeight, access }; })
"""

PROBE_3_SHADOW = """
(() => { const out = [];
  const walk = (root, depth) => { for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) { out.push({ tag: el.tagName, depth,
          chars: (el.shadowRoot.textContent||'').length });
        if (depth < 4) walk(el.shadowRoot, depth+1); } } };
  walk(document, 0); return { count: out.length, biggest: out.sort((a,b)=>b.chars-a.chars).slice(0,8) }; })()
"""

#: ⚠ **`SCRIPT` is excluded, and that is not tidiness — without it this probe is wrong.**
#: Measured on the real in-app ChatGPT page mid-run: the longest `innerText` on the whole document
#: was a `<script>` at **434,403 chars**, against 881 for the longest rendered element. `innerText`
#: is supposed to be the *rendered* text and to return "" for a non-rendered node; on this WebKit it
#: hands back the script's source. Left in, the verdict below reads 434k >= the 2000-char floor and
#: announces "the text exists in the main document — H2, re-point the selector; no frame work" while
#: the report is in fact in a cross-origin frame. That is the recipe's single most expensive wrong
#: turn, produced by the probe meant to prevent it.
PROBE_4_LONGEST = """
(() => { let best = {chars: 0};
  const skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1 };
  for (const el of document.querySelectorAll('*')) {
    if (skip[el.tagName]) continue;
    const n = (el.innerText||'').length;
    if (n > best.chars) best = { chars: n, tag: el.tagName, id: el.id,
      cls: (el.className||'').toString().slice(0,60),
      attrs: [...el.attributes].map(a=>a.name).join(','),
      inFrame: false }; }
  return best; })()
"""

PROBES = [
    ("PROBE 1 — turn census (settles H1 and H2)", PROBE_1_TURNS),
    ("PROBE 2 — iframe census + same-origin test (separates H3 from H4)", PROBE_2_IFRAMES),
    ("PROBE 3 — shadow-root census (settles H5)", PROBE_3_SHADOW),
    ("PROBE 4 — longest text on the page, wherever it lives", PROBE_4_LONGEST),
]


def _start_proxy(udid: str, port: int) -> subprocess.Popen | None:
    """Start IWDP against this simulator's per-boot socket, if it is not already up."""
    try:
        iwdp.list_pages(port)
        print(f"[iwdp] already answering on :{port}")
        return None
    except iwdp.InspectorError:
        pass
    sock = iwdp.discover_simulator_socket(udid)
    print(f"[iwdp] socket (RE-DISCOVERED — it is reallocated on every boot): {sock}")
    proc = subprocess.Popen(
        ["ios_webkit_debug_proxy", "-s", f"unix:{sock}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(30):
        time.sleep(0.5)
        try:
            iwdp.list_pages(port)
            print(f"[iwdp] up on :{port}")
            return proc
        except iwdp.InspectorError:
            continue
    proc.terminate()
    raise SystemExit("IWDP did not come up; is ::1 localhost in /etc/hosts?")


def completion_verdict(signals: dict) -> tuple[str, str]:
    """Judge whether the page holds a FINISHED Deep Research run.

    Returns ``(state, reason)`` where state is ``"complete"``, ``"in_flight"`` or ``"unknown"``.
    ⚠ **``unknown`` is a refusal, not a pass.** The original gate asked one question — "is the stop
    control gone?" — and treated yes as completion; on a DR run that control never appears at all,
    so the answer was yes before the run had even started planning. Confirming completion by the
    absence of something that is always absent is the same mistake as confirming it by elapsed
    time, which is what this whole gate exists to avoid.
    """
    if signals.get("stopControlPresent"):
        return "in_flight", f"the stop control is on screen ({signals.get('stopLabel')!r})"

    rendered = int(signals.get("longestRenderedChars") or 0)
    if rendered >= REPORT_FLOOR_CHARS:
        return "complete", (f"the main document holds a rendered node of {rendered} chars, over the "
                            f"{REPORT_FLOOR_CHARS}-char floor")

    frames = signals.get("visibleFrames") or []
    dr_frames = [f for f in frames if "deep-research" in (f.get("src") or "")]
    if dr_frames:
        return "unknown", (
            f"the report is not in the main document (longest rendered node {rendered} chars) and a "
            f"Deep Research sandbox frame is on screen ({dr_frames[0].get('src')}). Its contents are "
            f"cross-origin, so this tool cannot see whether the run finished. Confirm on the "
            f"Simulator screen, then re-run with --force to record the measurement."
        )
    return "unknown", (
        f"no stop control, no Deep Research frame, and the longest rendered node is only {rendered} "
        f"chars — that describes a page that never started as well as one that finished. Refusing "
        f"rather than guessing."
    )


class SurfaceNotFound(RuntimeError):
    """No page on this host belongs to the requested surface."""


def pick_by_ua(candidates: list[tuple[object, str]], surface: str) -> object:
    """Choose the page belonging to *surface* from (page, user_agent) pairs.

    Split out from the I/O so the choice itself is testable, because the choice is the whole
    defect: it must **refuse** rather than fall back. Returning "the only page we found" when the
    app's view has not appeared yet is exactly how a signed-out Safari tab gets measured and
    reported as gate zero's answer — a guard that fails open is worse than no guard, since it
    reports as present.
    """
    if surface not in ("app", "safari"):
        raise ValueError(f"unknown surface {surface!r}")
    for page, ua in candidates:
        is_app = APP_UA_TOKEN in (ua or "")
        if is_app == (surface == "app"):
            return page
    raise SurfaceNotFound(
        f"none of the {len(candidates)} page(s) on this host belong to the {surface!r} surface "
        f"(UAs seen: {[ (ua or '')[-30:] for _, ua in candidates ]}). For 'app': open the app and "
        f"tap the platform's tile in Browser watch — its web view only exists while something is "
        f"showing it. ⚠ Do NOT fall back to the other surface: Safari here is signed OUT."
    )


def find_page(url: str, surface: str, port: int, timeout: float = 40.0):
    """Poll the proxy for a page on *url* belonging to *surface*, reading each one's UA."""
    deadline = time.time() + timeout
    last: Exception | None = None
    while True:
        pairs = []
        for page in iwdp.list_pages(port):
            if url not in page.url:
                continue
            try:
                with iwdp.Inspector(page.ws_url) as insp:
                    pairs.append((page, str(insp.evaluate_json("navigator.userAgent") or "")))
            except Exception:  # noqa: BLE001
                continue
        if pairs:
            try:
                return pick_by_ua(pairs, surface)
            except SurfaceNotFound as exc:
                last = exc
        if time.time() >= deadline:
            raise SystemExit(str(last) if last else f"no page matching {url!r} at all")
        time.sleep(1.5)


#: The fixture dump. §0.1 and §3.2: gate zero's completed run and the extractor's development
#: fixture are THE SAME PAGE, and reaching it costs one unit of a hard monthly cap. Probing it and
#: then navigating away pays that cost twice.
DUMP_HTML_JS = "document.documentElement.outerHTML"


def _verdict(turns, iframes, shadow, longest) -> list[str]:
    """Judge against the PRE-DECLARED observable, not against whatever we happened to see."""
    lines = []
    best_turn = max((t.get("chars", 0) for t in turns), default=0)
    lines.append(f"longest [data-turn] text  : {best_turn} chars")
    lines.append(f"longest element anywhere  : {longest.get('chars', 0)} chars "
                 f"({longest.get('tag')} {longest.get('cls', '')[:40]})")
    # ⚠ Only frames that could plausibly HOLD a report count toward the verdict.
    #
    # Measured, and it produced the wrong answer: ChatGPT ships a 0×0 same-origin `sentinel` frame
    # with **0 chars** on every page. The original ranking tested `same` before `cross`, so that
    # empty 1-pixel frame outranked the 402×484 cross-origin frame the report was actually in, and
    # the gate announced *"H3 — same-origin sub-frame, traverse contentDocument, JS-only, no new
    # transport"* on a page whose report no amount of `contentDocument` traversal can reach. Rank by
    # evidence, never by the order the branches happen to be written in.
    def _substantial(frame: dict) -> bool:
        if (frame.get("w") or 0) < 50 or (frame.get("h") or 0) < 50:
            return False
        access = frame.get("access", "")
        if access.startswith("SAME-ORIGIN"):
            # "SAME-ORIGIN: N chars" — an empty one is a shell, not a container.
            digits = "".join(ch for ch in access if ch.isdigit())
            return int(digits or 0) >= REPORT_FLOOR_CHARS
        return True

    cross = [f for f in iframes
             if _substantial(f)
             and (f.get("access", "").startswith("THREW")
                  or f.get("access") == "null contentDocument")]
    same = [f for f in iframes if _substantial(f) and f.get("access", "").startswith("SAME-ORIGIN")]
    lines.append(f"iframes                   : {len(iframes)} total, "
                 f"{len(same)} substantial same-origin, {len(cross)} substantial cross-origin "
                 f"(frames under 50px or holding under {REPORT_FLOOR_CHARS} chars are ignored)")
    lines.append(f"shadow roots              : {shadow.get('count', 0)}")

    if best_turn >= REPORT_FLOOR_CHARS:
        lines.append("")
        lines.append(f"⭐ VERDICT: H1/H2 — the report IS in the main document, in a [data-turn] "
                     f"node, above the {REPORT_FLOOR_CHARS}-char floor. NO FRAME INVOLVED.")
        lines.append("   Premise refuted and the plan gets SIMPLER: fix the timeout, add a "
                     "report key + the wrong-document guards, drop all frame work.")
    elif longest.get("chars", 0) >= REPORT_FLOOR_CHARS:
        lines.append("")
        lines.append("VERDICT: the text exists in the main document but NOT under [data-turn] "
                     "— H2 (wrong node in the right document). Re-point the selector; no frame work.")
    elif cross:
        # ⚠ Cross-origin is tested BEFORE same-origin. A page can legitimately hold both, and when
        # it does, the inaccessible one is the interesting finding — the accessible one having been
        # measured as empty already.
        lines.append("")
        lines.append("VERDICT: H4 — cross-origin iframe, the ONE branch that costs architecture. "
                     "Now run the two H4 half-experiments in §3.2 before building anything —")
        lines.append("   AND run H7 first: on ChatGPT the report turned out to be reachable as "
                     "MARKDOWN over a same-origin fetch, which is cheaper than either H4 half.")
    elif same:
        lines.append("")
        lines.append("VERDICT: H3 — same-origin sub-frame. Traverse contentDocument in resolve(). "
                     "JS-only, no new transport.")
    elif shadow.get("count", 0):
        lines.append("")
        lines.append("VERDICT: H5 — shadow DOM. Add a shadowRoot-piercing walk to resolve() AND "
                     "to the Swift querySelector; test against all four platforms.")
    else:
        lines.append("")
        lines.append("VERDICT: none of H2-H5 fit and no node clears the floor. Suspect H7 "
                     "(fetched over the network) or that the run was not actually complete.")
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--url", default="chatgpt.com", help="substring of the page to probe")
    ap.add_argument("--port", type=int, default=9222)
    ap.add_argument("--surface", choices=("app", "safari"), default="app",
                    help="which web view to measure. Defaults to the app: on this device Safari "
                         "is signed OUT, and both surfaces serve the same URL.")
    ap.add_argument("--dump-html", type=Path, default=None,
                    help="write the completed page's full HTML here — the extractor fixture. "
                         "Reaching this page costs one Deep Research unit; dump it.")
    ap.add_argument("--force", action="store_true",
                    help="probe even if the stop control is still present (NOT recommended)")
    args = ap.parse_args()

    proc = _start_proxy(args.udid, args.port)
    try:
        page = find_page(args.url, args.surface, port=args.port)
        print(f"[iwdp] page: {page.url}  (surface={args.surface})\n")
        with iwdp.Inspector(page.ws_url) as insp:
            done = insp.evaluate_json(PROBE_COMPLETION)
            print("=== COMPLETION CHECK (positive evidence, never elapsed time) ===")
            print(json.dumps(done, indent=2))
            state, reason = completion_verdict(done)
            print(f"\ncompletion: {state.upper()} — {reason}")
            if state != "complete" and not args.force:
                print("\n⛔ Refusing to probe: this page is not established as a FINISHED run.")
                print("   Probing now would reproduce the original mis-measurement exactly.")
                print("   Re-run once it is done, or pass --force to record the measurement anyway.")
                return 2

            # Dump BEFORE the probes, not after. A probe that throws on an unexpected DOM would
            # otherwise lose the fixture too, and the fixture is the expensive half: the probes
            # can be re-run against a saved page, the page cannot be re-reached without spending
            # another unit of the owner's monthly cap.
            if args.dump_html:
                html = insp.evaluate_json(DUMP_HTML_JS) or ""
                args.dump_html.parent.mkdir(parents=True, exist_ok=True)
                args.dump_html.write_text(html)
                print(f"\n[fixture] wrote {len(html)} chars to {args.dump_html}")
                if len(html) < REPORT_FLOOR_CHARS:
                    print("⚠ that is smaller than the report floor — check the surface.")

            results = {}
            for title, js in PROBES:
                print(f"\n=== {title} ===")
                out = insp.evaluate_json(js)
                results[title] = out
                print(json.dumps(out, indent=2)[:6000])

            print("\n" + "=" * 78)
            print("VERDICT vs the pre-declared pass observable")
            print("=" * 78)
            for line in _verdict(results[PROBES[0][0]], results[PROBES[1][0]],
                                 results[PROBES[2][0]], results[PROBES[3][0]]):
                print(line)
            print("\n⚠ Record all four probe outputs VERBATIM in docs/DEVIATIONS.md — the "
                  "measurement, not just the conclusion. A negative result is a finding.")
    finally:
        if proc is not None:
            proc.terminate()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
