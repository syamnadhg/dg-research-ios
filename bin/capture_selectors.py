#!/usr/bin/env python3
"""Capture candidate mobile selectors from a logged-in page in the Simulator.

The point of this tool is to make the one owner-gated step cheap. Once a platform is signed in,
the remaining work is 25 named values in a JSON file — and finding them by hand means reading
minified mobile DOM in a 402pt-wide viewport. This dumps ranked candidates instead, so the login
converts directly into a draft manifest.

It is also phase A2 in embryo: the recipe's plan is that the offline repair agent *generates*
``selectors_mobile.json`` from captured Simulator DOM rather than anyone hand-deriving hundreds of
entries. This is the capture half of that, and its output is the agent's input.

**It proposes; it does not decide.** Output goes to a draft file with a ``provenance`` of
``captured`` and a confidence note per candidate, because a plausible-looking wrong selector is the
expensive failure here — it produces the P1 shape, where every click lands and extraction returns
nothing. A human (or the agent, gated) promotes a draft entry into the real manifest.

Ranking prefers what survives a redesign, in this order:
  1. ``data-testid`` — put there for automation, changed deliberately
  2. a stable ``id``
  3. ARIA role plus accessible name — semantic, and what the platform's own a11y tests rely on
  4. a tag + attribute combination
  5. text content — last, because it breaks on any copy or i18n change

Usage:
    python bin/capture_selectors.py --udid <UDID> --platform chatgpt --url https://chatgpt.com
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import selectors as sel  # noqa: E402
from emubackend.substrate import iwdp, runtime_js  # noqa: E402

# What to look for per manifest key: CSS probes plus the accessible-name hints that usually
# identify the control on mobile. Hints are *search terms*, not selectors — they narrow the
# candidate set so a human reviews five elements instead of five hundred.
PROBES: dict[str, dict[str, list[str]]] = {
    "chatgpt": {
        "logged_in_marker": ["#prompt-textarea", "[data-testid*=composer]"],
        "composer": ["#prompt-textarea", "div[contenteditable=true]", "textarea"],
        "send": ["[data-testid*=send]", "button[aria-label*=Send]", "button[type=submit]"],
        "deep_research_toggle": ["[data-testid*=research]", "button[aria-label*=research]"],
        "activity_panel": ["[data-testid*=activity]", "[aria-label*=activity]"],
        "sources": ["[data-testid*=source]", "a[href^=http]", "cite"],
        "response_container": ["[data-message-author-role=assistant]", "[data-testid*=conversation]"],
    },
    "gemini": {
        "logged_in_marker": ["rich-textarea", "div[contenteditable=true]"],
        "composer": ["rich-textarea div[contenteditable=true]", "div[contenteditable=true]"],
        "send": ["button[aria-label*=Send]", "button[aria-label*=send]"],
        "deep_research_toggle": ["button[aria-label*=Research]", "[data-test-id*=research]"],
        "start_research": ["button[aria-label*=Start]", "button"],
        "sources": ["a[href^=http]", "[data-test-id*=source]"],
        "response_container": ["model-response", "message-content"],
    },
    "claude": {
        "logged_in_marker": ["div.ProseMirror", "div[contenteditable=true]"],
        "composer": ["div.ProseMirror", "div[contenteditable=true]"],
        "send": ["button[aria-label*=Send]", "button[type=submit]"],
        "research_toggle": ["button[aria-label*=Research]", "[data-testid*=research]"],
        "artifact_panel": ["[data-testid*=artifact]", "[aria-label*=artifact]"],
        "sources": ["a[href^=http]", "[data-testid*=citation]"],
        "response_container": ["[data-testid*=message]", "div[data-is-streaming]"],
    },
    "notebooklm": {
        "logged_in_marker": ["[aria-label*=Notebook]", "button[aria-label*=Add]"],
        "add_source": ["button[aria-label*=Add source]", "button[aria-label*=Add]"],
        "generate_audio": ["button[aria-label*=Generate]", "button[aria-label*=Audio]"],
        "audio_ready_marker": ["audio", "[aria-label*=Play]"],
    },
}

# Runs in the page. Returns a ranked candidate list for one CSS probe, with the evidence that
# justified each rank so a reviewer can judge rather than trust.
_DESCRIBE_JS = """
(function (probe) {
  function nameOf(el) {
    return (el.getAttribute('aria-label') || el.getAttribute('title') ||
            (el.innerText || '').trim().slice(0, 60) || '');
  }
  function suggest(el) {
    var tid = el.getAttribute('data-testid') || el.getAttribute('data-test-id');
    if (tid) return { css: '[data-testid="' + tid + '"]', rank: 1, why: 'data-testid' };
    if (el.id && !/^[0-9]/.test(el.id)) return { css: '#' + el.id, rank: 2, why: 'stable id' };
    var role = el.getAttribute('role'), label = el.getAttribute('aria-label');
    if (role && label) {
      return { css: '[role="' + role + '"][aria-label="' + label + '"]', rank: 3,
               why: 'role + accessible name' };
    }
    if (label) {
      return { css: el.tagName.toLowerCase() + '[aria-label="' + label + '"]', rank: 4,
               why: 'tag + aria-label' };
    }
    if (el.isContentEditable) {
      return { css: el.tagName.toLowerCase() + '[contenteditable="true"]', rank: 4,
               why: 'contenteditable' };
    }
    return { css: null, rank: 5, why: 'no stable attribute — text match only' };
  }
  var out = [];
  try {
    var els = document.querySelectorAll(probe);
    for (var i = 0; i < els.length && i < 8; i++) {
      var el = els[i], r = el.getBoundingClientRect(), s = suggest(el);
      out.push({
        probe: probe, tag: el.tagName.toLowerCase(), name: nameOf(el),
        suggested: s.css, rank: s.rank, why: s.why,
        visible: !!(r.width && r.height), width: Math.round(r.width), height: Math.round(r.height),
        disabled: !!el.disabled, ariaPressed: el.getAttribute('aria-pressed'),
      });
    }
  } catch (e) { out.push({ probe: probe, error: String(e) }); }
  return out;
})(%s)
"""


def capture(udid: str, platform: str, url: str, port: int = 9222) -> dict:
    if platform not in PROBES:
        raise SystemExit(f"unknown platform {platform!r}; known: {sorted(PROBES)}")

    sock = iwdp.discover_simulator_socket(udid)
    subprocess.run(["pkill", "-f", "ios_webkit_debug_proxy"], capture_output=True)
    time.sleep(1)
    proxy = subprocess.Popen(
        ["ios_webkit_debug_proxy", "-s", f"unix:{sock}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(2.5)
        subprocess.run(["xcrun", "simctl", "openurl", udid, url], capture_output=True)
        host = url.split("//", 1)[-1].split("/", 1)[0]
        page = iwdp.wait_for_page(host, port, 60)
        with iwdp.Inspector(page.ws_url) as insp:
            insp.evaluate_json(runtime_js.RUNTIME_JS)
            viewport = insp.evaluate_json(f"window.{runtime_js.NS}.viewport()")
            findings: dict[str, list] = {}
            for key, probes in PROBES[platform].items():
                hits = []
                for probe in probes:
                    got = insp.evaluate_json(_DESCRIBE_JS % json.dumps(probe)) or []
                    hits.extend(got)
                # Best rank first, and visible before invisible: an off-screen match is usually a
                # different instance of the same component (a desktop-only sibling, a hidden menu).
                hits.sort(key=lambda h: (not h.get("visible", False), h.get("rank", 9)))
                findings[key] = hits[:6]
            return {
                "platform": platform,
                "url": page.url,
                "viewport": viewport,
                "candidates": findings,
            }
    finally:
        proxy.terminate()


def draft_manifest(captured: dict) -> dict:
    """Turn candidates into a DRAFT manifest entry — proposed, never promoted.

    Only rank 1–3 candidates are proposed at all. A rank 4–5 match is a guess, and a guess here is
    worse than a gap: a gap fails loudly at first use, a wrong selector produces a run that reports
    success having done nothing.
    """
    entries: dict[str, object] = {}
    for key, hits in captured["candidates"].items():
        best = next(
            (h for h in hits if h.get("suggested") and h.get("rank", 9) <= 3 and h.get("visible")),
            None,
        )
        if best is None:
            continue
        entries[key] = {
            "css": [best["suggested"]],
            "provenance": f"captured:{best['why']}",
        }
    return {"version": 1, "surface": "ios-mobile-safari", "platforms": {captured["platform"]: entries}}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--platform", required=True, choices=sorted(PROBES))
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", default=None, help="draft manifest path (default: artifacts/selectors/)")
    args = ap.parse_args()

    captured = capture(args.udid, args.platform, args.url)
    out_dir = REPO / "artifacts" / "selectors"
    out_dir.mkdir(parents=True, exist_ok=True)
    raw_path = out_dir / f"{args.platform}_candidates.json"
    raw_path.write_text(json.dumps(captured, indent=2) + "\n")

    draft = draft_manifest(captured)
    draft_path = Path(args.out) if args.out else out_dir / f"{args.platform}_draft.json"
    draft_path.write_text(json.dumps(draft, indent=2) + "\n")

    proposed = draft["platforms"][args.platform]
    wanted = set(sel.ALLOWED_KEYS[args.platform])
    print(f"viewport: {captured['viewport'].get('innerWidth')}x{captured['viewport'].get('innerHeight')}")
    print(f"candidates -> {raw_path.relative_to(REPO)}")
    print(f"draft      -> {draft_path.relative_to(REPO)}")
    print(f"\nproposed {len(proposed)}/{len(wanted)} keys for {args.platform}:")
    for key in sorted(wanted):
        entry = proposed.get(key)
        if entry:
            print(f"  ✓ {key:24} {entry['css'][0]}  ({entry['provenance']})")
        else:
            print(f"  · {key:24} no rank-1..3 visible candidate — review the candidates file")
    print(
        "\n⚠ These are PROPOSALS. Review them before merging into selectors_mobile.json: a "
        "plausible-but-wrong selector produces a run that reports success having harvested nothing."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
