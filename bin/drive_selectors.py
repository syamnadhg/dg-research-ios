#!/usr/bin/env python3
"""Verify captured selectors by DRIVING them, and capture the controls that only exist mid-interaction.

The companion to ``capture_selectors.py``, and the reason both exist: **resolution is not
acceptance.** A selector that resolves proves an element matched. Driving it proves the element was
the right one — which is the only thing that rules out the failure this codebase keeps circling, where
every click lands, the harvest returns nothing, and the run reports success.

It also unlocks the keys a capture structurally cannot see. Measured on real ChatGPT: at rest the
composer's button row holds "Add files and more", the model picker, dictation and voice — and no send
control at all. Type one character and ``[data-testid="send-button"]`` appears while dictation and
voice leave. A capture of an idle page is not a capture of a partial page; the send button is simply
not in the DOM yet.

What it does per platform:

1. resolve the composer from the manifest and fill it through ``window.__sr.insertText`` — the same
   runtime the pipeline uses, so a pass here is a pass for the pipeline and not for this script;
2. read the text back, because ``execCommand`` returning ``true`` is not evidence that a
   contenteditable took the text;
3. diff the composer's controls before and after, which *is* the capture of ``send``;
4. dispatch a full pointer/mouse/click sequence at send and report ``isTrusted`` alongside whether the
   message actually went — the two are independent, and conflating them is how "WKWebView reports
   isTrusted === false" became "the app cannot drive platforms". On ChatGPT every event reported
   ``false`` and the message sent regardless.

It sends a real prompt on a real account, so the prompt is short, obviously a probe, and asks for a
one-word answer.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import selectors as sel  # noqa: E402
from emubackend.substrate import iwdp, runtime_js  # noqa: E402

#: Set by the app's `customUserAgent`, and the only thing separating the app's web view from a Safari
#: tab on the same URL. See `capture_selectors.APP_UA_TOKEN`.
APP_UA_TOKEN = "Version/17.0"

HOSTS = {
    "chatgpt": "chatgpt.com",
    "gemini": "gemini.google.com",
    "claude": "claude.ai",
    "notebooklm": "notebooklm.google.com",
}

#: How each platform says "a message of mine is on screen". Distinct from `response_container`, which
#: is the *assistant's* turn: the send assertion needs the user's turn, because that appears
#: immediately while a response takes seconds to minutes.
USER_TURN_PROBES = {
    "chatgpt": "[data-message-author-role=user]",
    "gemini": "user-query, [data-test-id=user-query]",
    "claude": "[data-testid=user-message]",
}

PROBE_PROMPT = "SR selector probe — reply with the single word OK."

#: Shared with ``capture_selectors``: the composer's control region.
#:
#: Scoped rather than page-wide for the same reason the capture is — a page-wide button inventory
#: includes the nav and the sidebar, so a before/after diff drowns in unrelated churn and a probe for
#: a *concept* finds it in content.
#:
#: ``closest('form')`` alone is not the answer, and the fallback matters more than it looks. ChatGPT
#: wraps its composer in a ``<form>``; Claude and Gemini do not. With ``|| c.parentElement`` as the
#: fallback the scope collapsed to the contenteditable's immediate parent, which contains no buttons at
#: all — so both platforms reported "no controls appeared" after a *successful* fill, which reads as
#: the platform having no send button rather than as the scope being wrong. Walking up to the nearest
#: ancestor that actually holds buttons finds the real row on all three.
COMPOSER_ROOT_JS = """
  function composerRoot(c) {
    var form = c.closest('form');
    if (form) return form;
    var node = c;
    for (var i = 0; i < 6 && node && node.parentElement; i++) {
      node = node.parentElement;
      if (node.querySelectorAll('button,[role=button]').length > 0) return node;
    }
    return document;
  }
"""

CONTROLS_JS = """
(function (composerSel, userTurnSel) {
""" + COMPOSER_ROOT_JS + """
  var c = document.querySelector(composerSel);
  if (!c) return { err: 'composer not found: ' + composerSel };
  var root = composerRoot(c);
  var out = { text: (c.innerText || c.value || '').trim(), controls: [] };
  root.querySelectorAll('button,[role=button]').forEach(function (b) {
    var r = b.getBoundingClientRect();
    if (!(r.width && r.height)) return;
    var attr = b.hasAttribute('data-testid') ? 'data-testid'
             : (b.hasAttribute('data-test-id') ? 'data-test-id' : null);
    out.controls.push({
      name: (b.getAttribute('aria-label') || (b.innerText || '').trim()).slice(0, 40),
      testidAttr: attr,
      testid: attr ? b.getAttribute(attr) : null,
      id: b.id || null,
      disabled: !!b.disabled,
    });
  });
  try { out.userTurns = userTurnSel ? document.querySelectorAll(userTurnSel).length : null; }
  catch (e) { out.userTurns = null; }
  return out;
})(%s, %s)
"""

CLICK_JS = """
(function (sel) {
  var el = document.querySelector(sel);
  if (!el) return { err: 'not found: ' + sel };
  var r = el.getBoundingClientRect();
  var opts = { bubbles: true, cancelable: true, view: window,
               clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
  var seen = [];
  ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (t) {
    var E = t.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
    var ev;
    try { ev = new E(t, opts); } catch (e) { ev = new MouseEvent(t, opts); }
    el.dispatchEvent(ev);
    seen.push({ type: t, isTrusted: ev.isTrusted });
  });
  return { dispatched: seen };
})(%s)
"""


def app_page(host: str, port: int = 9222, timeout: float = 25.0):
    """The app's web view for this host. Polled — app targets appear later than Safari's tabs."""
    deadline = time.time() + timeout
    while True:
        for page in iwdp.list_pages(port):
            if host not in page.url.split("//", 1)[-1].split("/", 1)[0]:
                continue
            try:
                with iwdp.Inspector(page.ws_url) as insp:
                    if APP_UA_TOKEN in str(insp.evaluate_json("navigator.userAgent") or ""):
                        return page
            except Exception:  # noqa: BLE001
                continue
        if time.time() >= deadline:
            raise SystemExit(
                f"no app web view on {host}. Open 'Watch the browser' in the app and visit that "
                f"platform's tab — the login sheet's web view is torn down on dismiss, those are not."
            )
        time.sleep(1.5)


def _key(control: dict) -> tuple:
    return (control["name"], control["testid"], control["id"])


def drive(platform: str, send_it: bool) -> dict:
    manifest = sel.load_manifest()
    composer = manifest.require(platform, "composer")
    composer_css = composer.css[0]
    user_turns = USER_TURN_PROBES.get(platform)

    page = app_page(HOSTS[platform])
    report: dict = {"platform": platform, "url": page.url, "composer_css": composer_css}
    with iwdp.Inspector(page.ws_url) as insp:
        insp.evaluate_json(runtime_js.RUNTIME_JS)
        state = CONTROLS_JS % (json.dumps(composer_css), json.dumps(user_turns))

        before = insp.evaluate_json(state)
        if before.get("err"):
            raise SystemExit(f"{platform}: {before['err']}")
        report["before"] = before

        handle = insp.evaluate_json(f"window.{runtime_js.NS}.query({json.dumps(composer_css)})")
        report["handle"] = handle
        report["insertText"] = insp.evaluate_json(
            f"window.{runtime_js.NS}.insertText({json.dumps(handle)}, {json.dumps(PROBE_PROMPT)})"
        )
        time.sleep(2.5)

        after = insp.evaluate_json(state)
        report["after"] = after
        # The acceptance test for `composer`: not "execCommand returned true" but "the text is there".
        report["composer_driven"] = PROBE_PROMPT[:20] in (after.get("text") or "")
        report["appeared"] = [c for c in after["controls"] if _key(c) not in {_key(x) for x in before["controls"]}]
        report["vanished"] = [c for c in before["controls"] if _key(c) not in {_key(x) for x in after["controls"]}]

        # Which control is send, and why "what appeared" is not enough.
        #
        # ChatGPT swaps the control in: at rest its composer row holds dictation and voice, and
        # `[data-testid="send-button"]` only exists once there is text. Claude and Gemini keep
        # `button[aria-label="Send message"]` mounted the whole time. So the appearance diff — which
        # found ChatGPT's send perfectly — reported "no controls appeared" on both of the others after a
        # *successful* fill, and that reads as the platform having no send button.
        #
        # Appeared-first, then by accessible name, so the stronger evidence still wins where it exists.
        candidates = report["appeared"] or [
            c for c in after["controls"] if c["name"].lower().startswith("send")
        ]
        report["send_candidates"] = candidates
        if send_it and candidates:
            target = candidates[0]
            css = (
                f'[{target["testidAttr"]}="{target["testid"]}"]'
                if target["testid"]
                else f'button[aria-label="{target["name"]}"]'
            )
            report["send_css"] = css
            report["click"] = insp.evaluate_json(CLICK_JS % json.dumps(css))
            for wait in (2, 4, 8):
                time.sleep(wait)
                post = insp.evaluate_json(state)
                report["post"] = post
                if post.get("text") == "" or (
                    (post.get("userTurns") or 0) > (before.get("userTurns") or 0)
                ):
                    break
            # Independent of isTrusted on purpose. Both facts get reported; neither implies the other.
            report["send_driven"] = bool(
                report["post"].get("text") == ""
                or (report["post"].get("userTurns") or 0) > (before.get("userTurns") or 0)
            )
    return report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True, choices=sorted(HOSTS))
    ap.add_argument(
        "--send",
        action="store_true",
        help="also click send. Sends a real prompt on the owner's account.",
    )
    args = ap.parse_args()

    report = drive(args.platform, args.send)
    out = REPO / "artifacts" / "selectors" / f"{args.platform}_driven.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(
        json.dumps(report, indent=2, ensure_ascii=True).encode("ascii", "backslashreplace") + b"\n"
    )

    print(f"{args.platform} @ {report['url'][:60]}")
    print(f"  composer {report['composer_css']}")
    print(f"    insertText -> {report['insertText']}")
    print(f"    text read back -> {report['composer_driven']}   {'DRIVEN' if report['composer_driven'] else 'NOT DRIVEN'}")
    print("  controls that APPEARED once the composer was non-empty:")
    for c in report["appeared"] or [{"name": "(none)", "testid": None, "id": None}]:
        print(f"    {c['name']!r:34} {c.get('testidAttr') or '-'}={c['testid']!r} id={c['id']!r}")
    if report["vanished"]:
        print(f"  and VANISHED: {[c['name'] for c in report['vanished']]}")
    if "click" in report:
        trust = {d["isTrusted"] for d in report["click"].get("dispatched", [])}
        print(f"  send {report['send_css']}")
        print(f"    dispatched isTrusted values: {trust}")
        print(f"    message actually sent -> {report['send_driven']}")
        if report["send_driven"] and trust == {False}:
            print("    => this control does NOT gate on isTrusted; evaluateJavaScript is enough")
        elif not report["send_driven"]:
            print("    => untouched by a script click. This control needs an HID tap.")
    print(f"\n-> {out.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
