#!/usr/bin/env python3
"""B0a — the iOS Simulator substrate gate. Credential-free, machine-verifiable.

Four things must hold, and the recipe is explicit that the last three are what stop this
gate from passing on a toy page and dying in P2:

  A. a trusted tap lands on a **plain** page, on the element it was aimed at
  B. a trusted tap lands on a **scrolled** page (URL-bar collapse moves the chrome offset)
  C. a trusted tap lands with the **keyboard open** (keyboard insets shrink the viewport)
  D. a cookie set before ``simctl shutdown``/``boot`` **survives** it

Every case asserts on the *target element*, not merely that a trusted event fired: a
calibration off by the height of the URL bar still produces a trusted event, just on the
wrong node. Verdicts are written as JSON so the result is a record, not a screenful of prose.

Usage:  python bin/b0a_gate.py [--udid UDID] [--skip-reboot] [--json-out PATH]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend.substrate import geometry, hid, iwdp  # noqa: E402

PAGE_URL = "http://127.0.0.1:8899/"
ARTIFACTS = REPO / "artifacts" / "b0a"


class GateFailure(RuntimeError):
    """A B0a case failed. Not a bug — a finding."""


# ----------------------------------------------------------------------------------------
# plumbing
# ----------------------------------------------------------------------------------------


def sh(*args: str, timeout: float = 180.0) -> str:
    proc = subprocess.run(
        args, capture_output=True, text=True, check=False, timeout=timeout
    )
    return proc.stdout + proc.stderr


def booted_udid(preferred: str | None) -> str:
    out = sh("xcrun", "simctl", "list", "devices", "booted")
    if preferred and preferred in out:
        return preferred
    for line in out.splitlines():
        if "(Booted)" in line and "(" in line:
            return line.split("(")[1].split(")")[0]
    if preferred:
        sh("xcrun", "simctl", "boot", preferred)
        sh("xcrun", "simctl", "bootstatus", preferred, "-b")
        return preferred
    raise GateFailure("no booted simulator and no --udid given")


def page_reachable(url: str = PAGE_URL, timeout: float = 3.0) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def ensure_http_server() -> subprocess.Popen | None:
    if page_reachable():
        return None
    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", "8899", "--bind", "127.0.0.1"],
        cwd=str(REPO / "fixtures" / "b0a"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(20):
        if page_reachable():
            return proc
        time.sleep(0.5)
    raise GateFailure("could not serve fixtures/b0a on 127.0.0.1:8899")


def restart_iwdp(udid: str) -> subprocess.Popen:
    """(Re)start IWDP against this device's *current* socket.

    The socket path is allocated per boot, so it must be rediscovered after every
    shutdown/boot — which is precisely what case D exercises.
    """
    sh("pkill", "-f", "ios_webkit_debug_proxy")
    time.sleep(1.0)
    sock = iwdp.discover_simulator_socket(udid)
    proc = subprocess.Popen(
        ["ios_webkit_debug_proxy", "-s", f"unix:{sock}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(2.5)
    return proc


def open_page(udid: str) -> iwdp.Page:
    sh("xcrun", "simctl", "openurl", udid, PAGE_URL)
    return iwdp.wait_for_page("127.0.0.1:8899", timeout=40)


def connect(udid: str) -> tuple[iwdp.Inspector, iwdp.Page]:
    page = open_page(udid)
    return iwdp.Inspector(page.ws_url), page


# ----------------------------------------------------------------------------------------
# the cases
# ----------------------------------------------------------------------------------------


def _tapper(udid: str):
    return lambda x, y: hid.tap(udid, x, y)


def run_case(
    name: str,
    udid: str,
    insp: iwdp.Inspector,
    screen: hid.Screen,
    element: str,
    prepare=None,
) -> dict:
    """Calibrate for the current layout, tap *element*, and assert we hit it."""
    note = prepare(insp) if prepare else None
    calib = geometry.calibrate(
        evaluate_json=insp.evaluate_json,
        tap=_tapper(udid),
        screen_width=screen.width,
        screen_height=screen.height,
    )
    viewport = insp.evaluate_json("window.__b0a.viewport()")
    event = geometry.tap_element(
        evaluate_json=insp.evaluate_json,
        tap=_tapper(udid),
        calib=calib,
        element_id=element,
    )
    ok = bool(event.get("isTrusted")) and event.get("targetId") == element
    result = {
        "case": name,
        "pass": ok,
        "element": element,
        "isTrusted": event.get("isTrusted"),
        "hit_target": event.get("targetId"),
        "calibration": calib.describe(),
        "top_chrome_pt": round(calib.offset_y, 1),
        "viewport": viewport,
        "note": note,
    }
    if not ok:
        hid.screenshot(udid, str(ARTIFACTS / f"fail_{name}.png"))
        result["screenshot"] = str(ARTIFACTS / f"fail_{name}.png")
    return result


def prepare_scrolled(udid: str, screen: hid.Screen):
    def _prep(insp: iwdp.Inspector):
        # Scroll by a real swipe, not window.scrollTo: only a genuine gesture triggers the
        # URL-bar collapse, and that collapse is the thing that moves the chrome offset.
        # A JS scroll would move the content and leave the chrome — passing a test that
        # does not exist in production.
        for _ in range(3):
            hid.swipe(
                udid,
                screen.width * 0.5,
                screen.height * 0.72,
                screen.width * 0.5,
                screen.height * 0.28,
            )
            time.sleep(0.6)
        time.sleep(1.0)
        vp = insp.evaluate_json("window.__b0a.viewport()")
        if vp["scrollY"] < 50:
            raise GateFailure(
                f"swipe did not scroll the page (scrollY={vp['scrollY']}); the scrolled "
                f"case would be vacuous"
            )
        return f"scrolled to y={vp['scrollY']:.0f}, innerHeight now {vp['innerHeight']}"

    return _prep


def prepare_keyboard(udid: str, screen: hid.Screen):
    def _prep(insp: iwdp.Inspector):
        # The keyboard must be opened by a TRUSTED tap. A JS .focus() does not raise the
        # software keyboard on iOS (it needs a user gesture), so calibrating after a JS
        # focus would measure a viewport with no keyboard in it and the case would be
        # vacuous while appearing to pass.
        insp.evaluate_json("window.scrollTo(0,0)")
        time.sleep(0.5)
        base = insp.evaluate_json("window.__b0a.viewport()")
        calib = geometry.calibrate(
            evaluate_json=insp.evaluate_json,
            tap=_tapper(udid),
            screen_width=screen.width,
            screen_height=screen.height,
        )
        geometry.tap_element(
            evaluate_json=insp.evaluate_json,
            tap=_tapper(udid),
            calib=calib,
            element_id="inp",
        )
        time.sleep(2.0)
        after = insp.evaluate_json("window.__b0a.viewport()")
        focused = insp.evaluate_json("document.activeElement && document.activeElement.id")
        # Measured on iPhone 17 Pro / iOS 26.5: opening the keyboard takes
        # visualViewport.height 714 -> 377 and leaves window.innerHeight at 714. So
        # innerHeight is the wrong signal — checking it would report "no keyboard" while
        # the keyboard is plainly up, and the case would be marked vacuous incorrectly.
        base_vis = geometry.visible_height(base)
        after_vis = geometry.visible_height(after)
        shrank = base_vis - after_vis
        if focused != "inp":
            raise GateFailure(
                f"trusted tap did not focus the input (activeElement={focused!r})"
            )
        if shrank < 40:
            raise GateFailure(
                "the input is focused but visualViewport.height did not shrink "
                f"({base_vis:.0f} -> {after_vis:.0f}), so the software keyboard is NOT up "
                "and this case proves nothing. The Simulator most likely has a hardware "
                "keyboard attached: turn off I/O > Keyboard > Connect Hardware Keyboard "
                "(or `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard 0`) "
                "and re-run."
            )
        return (
            f"keyboard up: visualViewport.height {base_vis:.0f} -> {after_vis:.0f} "
            f"(-{shrank:.0f}) while innerHeight stayed {after['innerHeight']}; "
            f"activeElement=inp"
        )

    return _prep


def cookie_stores(udid: str) -> list[Path]:
    data = (
        Path.home()
        / "Library/Developer/CoreSimulator/Devices"
        / udid
        / "data"
    )
    return list(data.rglob("Cookies.binarycookies"))


def wait_for_cookie_on_disk(udid: str, marker: str, timeout: float = 45.0) -> float:
    """Block until *marker* appears in an on-disk cookie store; return seconds waited.

    ⚠ **This is the difference between measuring persistence and measuring a flush race.**
    `document.cookie` returning the value only proves it is in MobileSafari's memory.
    `simctl shutdown` is abrupt, so shutting down straight after a write loses cookies that
    have not reached ``Cookies.binarycookies`` yet — which looks exactly like "the session
    did not survive the reboot" and would wrongly trip the recipe's kill criterion for the
    whole iOS path.

    Asserting the precondition on disk also produces a genuinely useful operational rule for
    the pipeline: never hard-stop a Simulator right after a login.
    """
    started = time.monotonic()
    deadline = started + timeout
    while time.monotonic() < deadline:
        for store in cookie_stores(udid):
            try:
                if marker.encode() in store.read_bytes():
                    return time.monotonic() - started
            except OSError:
                continue
        time.sleep(1.0)
    raise GateFailure(
        f"cookie {marker!r} never reached an on-disk cookie store within {timeout}s "
        f"(searched {len(cookie_stores(udid))} store(s)). Rebooting now would test a flush "
        f"race, not persistence."
    )


def case_reboot_persistence(udid: str) -> dict:
    """Cookie set before a Simulator reboot must still be there afterwards."""
    marker = f"b0a-{int(time.time())}"
    insp, _ = connect(udid)
    try:
        insp.evaluate_json(
            "(function(){document.cookie='b0a_marker=%s; path=/; max-age=86400'; "
            "return document.cookie;})()" % marker
        )
        before = insp.evaluate_json("document.cookie")
    finally:
        insp.close()
    if marker not in (before or ""):
        raise GateFailure(f"cookie did not even set before reboot: {before!r}")

    flush_seconds = wait_for_cookie_on_disk(udid, marker)

    sh("xcrun", "simctl", "shutdown", udid, timeout=180)
    time.sleep(2)
    sh("xcrun", "simctl", "boot", udid, timeout=180)
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
    time.sleep(3)
    restart_iwdp(udid)  # the socket path is new after a reboot

    insp2, _ = connect(udid)
    try:
        after = insp2.evaluate_json("document.cookie")
    finally:
        insp2.close()
    return {
        "case": "D_reboot_persistence",
        "pass": marker in (after or ""),
        "marker": marker,
        "cookie_before": before,
        "cookie_after": after,
        "disk_flush_seconds": round(flush_seconds, 1),
        "note": (
            f"cookie reached disk after {flush_seconds:.0f}s; the IWDP socket path is "
            f"reallocated per boot and had to be rediscovered"
        ),
    }


# ----------------------------------------------------------------------------------------


def _iwdp_version() -> str:
    """Parse the version out of IWDP's banner.

    Splitting on "v" is wrong: the help text contains other words with a "v", so the last
    fragment lands on "ersion information and exit." — a wrong value that still looks like
    a value, which is the kind of thing that quietly poisons a recorded verdict.
    """
    import re as _re

    match = _re.search(r"Proxy v([\d.]+)", sh("ios_webkit_debug_proxy", "--help"))
    return match.group(1) if match else "unknown"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", default=None)
    ap.add_argument("--skip-reboot", action="store_true")
    ap.add_argument("--json-out", default=str(ARTIFACTS / "verdict.json"))
    args = ap.parse_args()

    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    ensure_http_server()
    udid = booted_udid(args.udid)
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
    restart_iwdp(udid)
    screen = hid.screen_size(udid)
    print(f"device {udid}  screen {screen.width:.0f}x{screen.height:.0f}pt")

    results: list[dict] = []
    insp, page = connect(udid)
    try:
        print(f"page: {page.title!r} @ {page.url}")
        for name, element, prep in (
            ("A_plain", "t1", None),
            ("B_scrolled", "t2", prepare_scrolled(udid, screen)),
            ("C_keyboard_open", "t3", prepare_keyboard(udid, screen)),
        ):
            try:
                res = run_case(name, udid, insp, screen, element, prep)
            except (GateFailure, geometry.CalibrationError, iwdp.InspectorError) as exc:
                res = {"case": name, "pass": False, "element": element, "error": str(exc)}
            results.append(res)
            flag = "PASS" if res.get("pass") else "FAIL"
            print(f"  [{flag}] {name}: {res.get('note') or res.get('error') or ''}")
            if res.get("pass"):
                print(f"         {res['calibration']}  hit={res['hit_target']}")
            # Reset the page between cases so one case's scroll/keyboard state cannot
            # silently become the next case's starting condition.
            insp.evaluate_json("window.__b0a.blurInput()")
            insp.evaluate_json("window.scrollTo(0,0)")
            time.sleep(1.0)
    finally:
        insp.close()

    if args.skip_reboot:
        results.append({"case": "D_reboot_persistence", "pass": None, "note": "skipped"})
    else:
        try:
            res = case_reboot_persistence(udid)
        except (GateFailure, iwdp.InspectorError) as exc:
            res = {"case": "D_reboot_persistence", "pass": False, "error": str(exc)}
        results.append(res)
        print(
            f"  [{'PASS' if res.get('pass') else 'FAIL'}] D_reboot_persistence: "
            f"{res.get('note') or res.get('error') or ''}"
        )

    decided = [r for r in results if r.get("pass") is not None]
    verdict = {
        "gate": "B0a",
        "udid": udid,
        "screen_pt": [screen.width, screen.height],
        "toolchain": {
            "iwdp": _iwdp_version(),
            "axe": sh("axe", "--version").strip(),
            "xcode": sh("xcodebuild", "-version").splitlines()[0] if sh("xcodebuild", "-version") else "?",
        },
        "results": results,
        "pass": all(r.get("pass") for r in decided) and len(decided) > 0,
    }
    Path(args.json_out).write_text(json.dumps(verdict, indent=2) + "\n")
    print(f"\nverdict: {'PASS' if verdict['pass'] else 'FAIL'}  -> {args.json_out}")
    return 0 if verdict["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
