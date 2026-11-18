#!/usr/bin/env python3
"""Drive ONE real ChatGPT Deep Research run **in the app**, so gate zero has a page to measure.

`bin/gate_zero_probe.py` measures a completed run; nothing in this repo could *reach* one. The
recipe's §3.2 step 0 said "drive it by hand", which in practice meant a human tapping through the
Simulator — and the one time that was attempted it was driven in **Simulator Safari**, which is
signed out (`docs/DEVIATIONS.md`, *"Gate zero must run IN-APP"*). This script removes both the
hand-driving and that whole class of mistake: it picks the surface by **user agent**, not by URL.

⛔ **It sends a real Deep Research prompt on the owner's real, paid account**, which is a hard
monthly cap (recipe §0.1). One invocation is one unit. It refuses to send twice against the same
conversation without `--force`, because the expensive mistake here is not a crash, it is a silent
second send.

What it does, in the order the manifest's provenance says works:

1. find the app's web view for `chatgpt.com` by the UA the app pins;
2. inject the runtime and **measure** the CSS-px → screen-point transform (the app's web view sits
   below the platform tab bar, so the transform is not the identity and cannot be assumed);
3. **HID-tap** the composer's plus opener — a scripted click does not open it (`§1.1` defect 1);
4. poll for the *Deep research* item by text among the menu roles, and activate it;
5. confirm with the **page-level** pill predicate rather than a handle the activation destroys;
6. re-establish composer readiness (activating it navigates), fill through `insertText`, and send;
7. assert the user's turn appeared — "send was clicked" is not "the message went".
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

from emubackend import phases  # noqa: E402
from emubackend.substrate import geometry, hid, iwdp, runtime_js  # noqa: E402

#: The app pins this in `customUserAgent`; Simulator Safari reports `Version/26.5`. See
#: `bin/capture_selectors.py`'s note — matching on URL or title picks the wrong page, and on this
#: device the wrong page is the signed-out one.
APP_UA_TOKEN = "Version/17.0"

HOST = "chatgpt.com"
PLUS_OPENER = '[data-testid="composer-plus-btn"]'
COMPOSER = "#prompt-textarea"
SEND = '[data-testid="send-button"], #composer-submit-button'
USER_TURN = "[data-message-author-role=user]"

#: Is Deep Research armed? **The pipeline's own predicate**, not a second opinion.
#:
#: Reused verbatim from `phases._TOGGLE_STATE_JS` rather than reimplemented, because a bespoke
#: "does the page say 'deep research' anywhere" check is how this has gone wrong before in both
#: directions: it matches the menu item that is the *control*, and it matches tooltips and help
#: copy. Its exclusion of state-carrying elements is the part that distinguishes an indicator from
#: the toggle itself. It asks the **page**, not a handle, because activation replaces the composer
#: subtree — any handle taken before the tap is stale by the time you would read it. `aria-pressed`
#: is unusable here: measured false throughout an activation that plainly happened.
DR_PILL_JS = phases._TOGGLE_STATE_JS % json.dumps("Deep research")

#: The menu item, by text among the roles a menu uses. Deliberately not a CSS selector: the plus
#: menu paints 19 items and a broad `[role=menuitem]` matches "Camera", the first of them.
MENU_ITEM_JS = """
((needle) => {
  const items = [...document.querySelectorAll('[role=menuitem],[role=menuitemradio],[role=option],[role=menuitemcheckbox]')];
  const hit = items.find(el => (el.innerText || '').toLowerCase().includes(needle.toLowerCase()));
  return { count: items.length,
           labels: items.map(el => (el.innerText || '').trim().slice(0, 30)),
           found: !!hit };
})(%s)
"""

ACTIVATE_MENU_ITEM_JS = """
((needle) => {
  const items = [...document.querySelectorAll('[role=menuitem],[role=menuitemradio],[role=option],[role=menuitemcheckbox]')];
  const hit = items.find(el => (el.innerText || '').toLowerCase().includes(needle.toLowerCase()));
  if (!hit) return { err: 'no menu item matching ' + needle };
  hit.click();
  return { clicked: (hit.innerText || '').trim().slice(0, 40) };
})(%s)
"""

#: A conversation that already holds a turn is one we have already spent a unit on.
EXISTING_TURNS_JS = """
(() => ({ user: document.querySelectorAll('[data-message-author-role=user]').length,
          turns: document.querySelectorAll('[data-turn]').length,
          url: location.href }))()
"""


def app_page(host: str, port: int, timeout: float = 40.0) -> iwdp.Page:
    """The app's own web view for *host*, identified by the UA the app pins.

    Polled, because an app's web views appear in the proxy listing appreciably later than
    Safari's tabs do — and a fixed sleep that is long enough here is a flake elsewhere.
    """
    deadline = time.time() + timeout
    seen: list[str] = []
    while True:
        candidates = [
            p for p in iwdp.list_pages(port)
            if host in p.url.split("//", 1)[-1].split("/", 1)[0]
        ]
        seen = [p.url for p in candidates]
        for page in candidates:
            try:
                with iwdp.Inspector(page.ws_url) as insp:
                    ua = str(insp.evaluate_json("navigator.userAgent") or "")
            except Exception:  # noqa: BLE001
                continue
            if APP_UA_TOKEN in ua:
                return page
        if time.time() >= deadline:
            raise SystemExit(
                f"no app web view on {host} (saw {len(seen)} page(s): {seen}). Those are Safari "
                f"tabs, which on this device are signed OUT. Open the app, tap the platform's "
                f"tile in Browser watch — the view only exists while something is showing it — "
                f"then re-run."
            )
        time.sleep(1.5)


def start_proxy(udid: str, port: int) -> subprocess.Popen | None:
    try:
        iwdp.list_pages(port)
        return None
    except iwdp.InspectorError:
        pass
    sock = iwdp.discover_simulator_socket(udid)
    proc = subprocess.Popen(
        ["ios_webkit_debug_proxy", "-s", f"unix:{sock}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(30):
        time.sleep(0.5)
        try:
            iwdp.list_pages(port)
            return proc
        except iwdp.InspectorError:
            continue
    proc.terminate()
    raise SystemExit("IWDP did not come up")


def poll(fn, predicate, timeout: float, interval: float = 1.0):
    """Poll *fn* until *predicate* holds. Returns (ok, last). Polling, never a fixed sleep —
    a fixed 3 s sample is what twice produced a wrong "this control does not exist on mobile"."""
    deadline = time.time() + timeout
    last = None
    while True:
        last = fn()
        if predicate(last):
            return True, last
        if time.time() >= deadline:
            return False, last
        time.sleep(interval)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--port", type=int, default=9222)
    ap.add_argument("--brief", required=True, help="the Deep Research prompt to send")
    ap.add_argument("--force", action="store_true",
                    help="send even if this conversation already holds a user turn")
    args = ap.parse_args()

    proc = start_proxy(args.udid, args.port)
    try:
        page = app_page(HOST, args.port)
        print(f"[surface] app web view (UA {APP_UA_TOKEN}): {page.url}")
        screen = hid.screen_size(args.udid)
        print(f"[screen] {screen.width:.0f}x{screen.height:.0f}pt")

        with iwdp.Inspector(page.ws_url) as insp:
            insp.evaluate_json(runtime_js.RUNTIME_JS)

            pre = insp.evaluate_json(EXISTING_TURNS_JS)
            print(f"[state] {json.dumps(pre)}")
            if pre.get("user") and not args.force:
                print("\n⛔ This conversation already holds a user turn — a run was already sent "
                      "here. Refusing to spend a second Deep Research unit. Open a NEW chat in the "
                      "app (or pass --force if you really mean to send again).")
                return 2

            def tap(x: float, y: float) -> None:
                hid.tap(args.udid, x, y, screen=screen)

            calib = geometry.calibrate(
                evaluate_json=insp.evaluate_json,
                tap=tap,
                screen_width=screen.width,
                screen_height=screen.height,
            )
            print(f"[calib] {calib}")

            dr = insp.evaluate_json(DR_PILL_JS)
            if dr.get("pillVisible"):
                print("[dr] already armed (pill present) — not tapping the toggle again")
            else:
                handle = insp.evaluate_json(
                    f"window.{runtime_js.NS}.query({json.dumps(PLUS_OPENER)})")
                if handle is None:
                    raise SystemExit(f"no plus opener ({PLUS_OPENER}) — is the composer on screen?")
                hit = geometry.tap_element(
                    evaluate_json=insp.evaluate_json, tap=tap, calib=calib,
                    element_id=handle, probe=geometry.SR_PROBE,
                )
                print(f"[dr] HID-tapped the opener: isTrusted={hit.get('isTrusted')}")

                ok, menu = poll(
                    lambda: insp.evaluate_json(MENU_ITEM_JS % json.dumps("deep research")),
                    lambda m: bool(m.get("found")),
                    timeout=20.0, interval=0.75,
                )
                print(f"[dr] menu: {json.dumps(menu)[:400]}")
                if not ok:
                    raise SystemExit("the plus menu never painted a 'Deep research' item")

                print(f"[dr] activate: "
                      f"{insp.evaluate_json(ACTIVATE_MENU_ITEM_JS % json.dumps('deep research'))}")

                ok, dr = poll(lambda: insp.evaluate_json(DR_PILL_JS),
                              lambda d: bool(d.get("pillVisible")),
                              timeout=20.0, interval=1.0)
                if not ok:
                    raise SystemExit(f"Deep Research did not arm: {dr}")
                print("[dr] armed (pill visible)")

            # Activating the toggle navigates, so the composer handle taken before it is stale.
            ok, _ = poll(
                lambda: insp.evaluate_json(
                    f"window.{runtime_js.NS}.query({json.dumps(COMPOSER)})"),
                lambda h: h is not None, timeout=30.0, interval=1.0,
            )
            if not ok:
                raise SystemExit("composer never came back after arming Deep Research")
            insp.evaluate_json(runtime_js.RUNTIME_JS)
            handle = insp.evaluate_json(f"window.{runtime_js.NS}.query({json.dumps(COMPOSER)})")
            insp.evaluate_json(
                f"window.{runtime_js.NS}.insertText({json.dumps(handle)}, {json.dumps(args.brief)})")

            # Read the text back: execCommand returning true is not evidence the editor took it.
            ok, text = poll(
                lambda: insp.evaluate_json(
                    f"(document.querySelector({json.dumps(COMPOSER)})||{{}}).innerText || ''"),
                lambda t: args.brief[:24] in (t or ""), timeout=15.0, interval=1.0,
            )
            if not ok:
                raise SystemExit(f"the composer did not take the brief (read back {text!r:.80})")
            print(f"[compose] filled, {len(text)} chars")

            ok, _ = poll(
                lambda: insp.evaluate_json(
                    f"!!document.querySelector({json.dumps(SEND)})"),
                bool, timeout=15.0, interval=0.5,
            )
            if not ok:
                raise SystemExit("send control never appeared")
            print(f"[send] {insp.evaluate_json(f'(() => {{ const b = document.querySelector({json.dumps(SEND)}); b.click(); return true; }})()')}")

            ok, turns = poll(
                lambda: insp.evaluate_json(
                    f"document.querySelectorAll({json.dumps(USER_TURN)}).length"),
                lambda n: (n or 0) > (pre.get("user") or 0), timeout=30.0, interval=1.0,
            )
            if not ok:
                raise SystemExit("send was clicked but no user turn appeared — nothing was sent")
            print(f"[send] user turns {pre.get('user')} -> {turns}. Deep Research is RUNNING.")
            print(f"[send] url: {insp.evaluate_json('location.href')}")
            print("\nExpect 10-30 minutes. Then:\n"
                  f"  .venv/bin/python bin/gate_zero_probe.py --udid {args.udid} --surface app "
                  f"--dump-html artifacts/gate_zero/chatgpt_dr_completed.html")
    finally:
        if proc is not None:
            proc.terminate()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
