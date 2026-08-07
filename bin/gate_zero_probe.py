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

# --- the four probes, verbatim from recipe §3.2 -------------------------------------

PROBE_COMPLETION = """
(() => {
  const stop = document.querySelector('button[data-testid="stop-button"], button[aria-label*="Stop"]');
  return { stopControlPresent: !!stop, stopLabel: stop ? (stop.getAttribute('aria-label') || stop.getAttribute('data-testid')) : null,
           url: location.href, title: document.title };
})()
"""

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

PROBE_4_LONGEST = """
(() => { let best = {chars: 0};
  for (const el of document.querySelectorAll('*')) { const n = (el.innerText||'').length;
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


def _verdict(turns, iframes, shadow, longest) -> list[str]:
    """Judge against the PRE-DECLARED observable, not against whatever we happened to see."""
    lines = []
    best_turn = max((t.get("chars", 0) for t in turns), default=0)
    lines.append(f"longest [data-turn] text  : {best_turn} chars")
    lines.append(f"longest element anywhere  : {longest.get('chars', 0)} chars "
                 f"({longest.get('tag')} {longest.get('cls', '')[:40]})")
    cross = [f for f in iframes
             if f.get("access", "").startswith("THREW") or f.get("access") == "null contentDocument"]
    same = [f for f in iframes if f.get("access", "").startswith("SAME-ORIGIN")]
    lines.append(f"iframes                   : {len(iframes)} total, "
                 f"{len(same)} same-origin, {len(cross)} cross-origin/inaccessible")
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
    elif same:
        lines.append("")
        lines.append("VERDICT: H3 — same-origin sub-frame. Traverse contentDocument in resolve(). "
                     "JS-only, no new transport.")
    elif cross:
        lines.append("")
        lines.append("VERDICT: H4 — cross-origin iframe, the ONE branch that costs architecture. "
                     "Now run the two H4 half-experiments in §3.2 before building anything.")
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
    ap.add_argument("--force", action="store_true",
                    help="probe even if the stop control is still present (NOT recommended)")
    args = ap.parse_args()

    proc = _start_proxy(args.udid, args.port)
    try:
        page = iwdp.wait_for_page(args.url, port=args.port, timeout=30)
        print(f"[iwdp] page: {page.url}\n")
        with iwdp.Inspector(page.ws_url) as insp:
            done = insp.evaluate_json(PROBE_COMPLETION)
            print("=== COMPLETION CHECK (absence of the stop control, never elapsed time) ===")
            print(json.dumps(done, indent=2))
            if done.get("stopControlPresent") and not args.force:
                print("\n⛔ The stop control is STILL PRESENT — this run has not finished.")
                print("   Probing now would reproduce the original mis-measurement exactly.")
                print("   Wait for it to disappear, then re-run (or pass --force to override).")
                return 2

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
