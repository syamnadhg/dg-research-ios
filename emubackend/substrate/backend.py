"""`BrowserBackend` — the substrate transport, and its iOS Simulator implementation.

The seam the recipe specifies (§5): ``BrowserBackend`` owns the substrate (tabs, transport,
native input) and ``PageShim`` presents the ``Page`` surface the forked P0–P3 functions call.
This module is the first half.

The surface is **async** because the code being ported awaits it, while the transport
(``ios_webkit_debug_proxy`` HTTP/WebSocket, ``axe`` subprocesses) is blocking. Blocking calls
are pushed to a thread with ``asyncio.to_thread`` rather than rewritten as async: the
transport is exactly the part B0a validated against a real device, and reimplementing it
asynchronously would put unproven code under a proven result.

⚠ **The iOS-specific asymmetry that has no desktop analogue.** The two channels do *not* have
the same reach. IWDP will happily ``Runtime.evaluate`` in a **backgrounded** MobileSafari tab,
but AXe HID taps land on whatever tab is **foreground**. So a read against a background tab
succeeds while a tap against that same tab silently hits different content — the automation
appears to work and operates on the wrong page. Every input path here therefore asserts the
target page is foreground first; see :meth:`IOSSimulatorBackend._assert_foreground`.
"""

from __future__ import annotations

import asyncio
import subprocess
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from emubackend.substrate import geometry, hid, iwdp, runtime_js

__all__ = ["BackendUnsupported", "BrowserBackend", "IOSSimulatorBackend", "Tab"]


class BackendUnsupported(NotImplementedError):
    """This substrate cannot do this primitive — degrade, do not crash.

    A *typed* exception because the pipeline is expected to catch it and take a documented
    alternative path (the JS clipboard hijack instead of the OS clipboard, a per-platform
    upload substitute, and so on). The important property is that every primitive is either
    implemented or *explicitly* degraded: a silent no-op would look like success and corrupt
    a run far downstream. `emubackend/tests/test_backend_contract.py` enforces that no
    abstract method is left merely unimplemented.
    """


@dataclass
class Tab:
    """One inspectable page, plus the per-tab state the transport needs."""

    url: str
    ws_url: str
    inspector: iwdp.Inspector | None = None
    calibration: geometry.Calibration | None = None
    #: Set once the injected JS runtime is known to be present for the current document.
    runtime_ready: bool = False
    meta: dict[str, Any] = field(default_factory=dict)


class BrowserBackend(ABC):
    """Substrate transport. One implementation per surface (iOS Simulator, desktop, …).

    Method set follows the recipe's §5 spec. Anything a substrate genuinely cannot do must
    raise :class:`BackendUnsupported` explicitly.
    """

    @abstractmethod
    async def start(self) -> None: ...

    @abstractmethod
    async def close(self) -> None: ...

    @abstractmethod
    async def health(self) -> bool: ...

    @abstractmethod
    async def new_tab(self, url: str) -> Tab: ...

    @abstractmethod
    async def open_isolated_tab(self, url: str) -> Tab: ...

    @abstractmethod
    async def switch_to(self, tab: Tab) -> None: ...

    @abstractmethod
    async def bring_to_front(self, tab: Tab) -> None: ...

    @abstractmethod
    async def evaluate(self, tab: Tab, js: str) -> Any: ...

    @abstractmethod
    async def tap(self, tab: Tab, client_x: float, client_y: float) -> dict: ...

    @abstractmethod
    async def key(self, tab: Tab, combo: str) -> None: ...

    @abstractmethod
    async def scroll(self, tab: Tab, dx: float, dy: float) -> None: ...

    @abstractmethod
    async def upload(self, tab: Tab, selector: str, host_paths: list[str]) -> None: ...

    @abstractmethod
    async def download_capture(self, tab: Tab, trigger) -> Any: ...

    @abstractmethod
    async def read_clipboard(self, tab: Tab) -> str: ...

    @abstractmethod
    async def screenshot(self, tab: Tab) -> bytes: ...

    @abstractmethod
    def viewport(self, tab: Tab) -> tuple[int, int]: ...


class IOSSimulatorBackend(BrowserBackend):
    """iOS Simulator: IWDP for DOM/JS, AXe HID for trusted input.

    Both channels and the coordinate mapping were validated end-to-end by the B0a gate on
    iPhone 17 Pro / iOS 26.5; this class is that proven sequence packaged behind the seam.
    """

    def __init__(self, udid: str, iwdp_port: int = 9222):
        self.udid = udid
        self.iwdp_port = iwdp_port
        self._iwdp: subprocess.Popen | None = None
        self._screen: hid.Screen | None = None
        self._tabs: list[Tab] = []

    # -- lifecycle ---------------------------------------------------------------

    async def start(self) -> None:
        """Boot-check the device, start IWDP against this boot's socket, read the screen."""
        await asyncio.to_thread(
            subprocess.run,
            ["xcrun", "simctl", "bootstatus", self.udid, "-b"],
            capture_output=True,
        )
        await self._restart_iwdp()
        self._screen = await asyncio.to_thread(hid.screen_size, self.udid)

    async def _restart_iwdp(self) -> None:
        """Start IWDP on this boot's socket.

        The socket path is **reallocated on every boot** and IWDP does not discover the
        Simulator on its own, so this is rediscovery rather than a one-time setup step. Any
        code path that reboots the device must call this again or every later DOM read fails
        with an empty device list — which reads as "the page went away".
        """
        if self._iwdp is not None:
            self._iwdp.terminate()
            self._iwdp = None
        await asyncio.to_thread(
            subprocess.run, ["pkill", "-f", "ios_webkit_debug_proxy"], capture_output=True
        )
        await asyncio.sleep(1.0)
        sock = await asyncio.to_thread(iwdp.discover_simulator_socket, self.udid)
        self._iwdp = subprocess.Popen(
            ["ios_webkit_debug_proxy", "-s", f"unix:{sock}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        await asyncio.sleep(2.5)

    async def close(self) -> None:
        for tab in self._tabs:
            if tab.inspector is not None:
                tab.inspector.close()
                tab.inspector = None
        if self._iwdp is not None:
            self._iwdp.terminate()
            self._iwdp = None

    async def health(self) -> bool:
        """True if the device is booted, IWDP answers, and AXe can see the screen."""
        try:
            out = await asyncio.to_thread(
                subprocess.run,
                ["xcrun", "simctl", "list", "devices", "booted"],
                capture_output=True,
                text=True,
            )
            if self.udid not in out.stdout:
                return False
            await asyncio.to_thread(iwdp.list_pages, self.iwdp_port)
            await asyncio.to_thread(hid.screen_size, self.udid)
            return True
        except Exception:
            return False

    # -- tabs --------------------------------------------------------------------

    async def new_tab(self, url: str) -> Tab:
        await asyncio.to_thread(
            subprocess.run,
            ["xcrun", "simctl", "openurl", self.udid, url],
            capture_output=True,
        )
        marker = url.split("//", 1)[-1].split("/", 1)[0]
        page = await asyncio.to_thread(iwdp.wait_for_page, marker, self.iwdp_port, 40.0)
        tab = Tab(url=page.url, ws_url=page.ws_url)
        self._tabs.append(tab)
        await self._attach(tab)
        return tab

    async def open_isolated_tab(self, url: str) -> Tab:
        raise BackendUnsupported(
            "MobileSafari private tabs cannot be opened programmatically — `simctl openurl` "
            "always targets the normal browsing context, and there is no HID-free way to "
            "reach the tab switcher's Private toggle. Where the pipeline needs isolation, "
            "use a second Simulator (which is also how per-worker isolation should work)."
        )

    async def switch_to(self, tab: Tab) -> None:
        raise BackendUnsupported(
            "programmatic tab switching is not available in MobileSafari: `simctl openurl` "
            "re-navigates rather than switching, and the tab switcher is UI-only. Because "
            "HID taps only reach the FOREGROUND tab, a multi-tab P2 model needs either "
            "one Simulator per platform or a strictly sequential single-tab model."
        )

    async def bring_to_front(self, tab: Tab) -> None:
        """No-op: MobileSafari has one foreground tab and no programmatic ordering.

        Deliberately a no-op rather than BackendUnsupported — callers use this as a hint
        before interacting, and failing here would abort work that is about to succeed. The
        real protection is the foreground assertion inside every input path.
        """
        return None

    async def _attach(self, tab: Tab) -> iwdp.Inspector:
        if tab.inspector is None:
            tab.inspector = await asyncio.to_thread(iwdp.Inspector, tab.ws_url)
            tab.runtime_ready = False
        if not tab.runtime_ready:
            await asyncio.to_thread(
                tab.inspector.evaluate_json, runtime_js.RUNTIME_JS
            )
            tab.runtime_ready = True
        return tab.inspector

    # -- DOM / JS ----------------------------------------------------------------

    async def evaluate(self, tab: Tab, js: str) -> Any:
        insp = await self._attach(tab)
        try:
            return await asyncio.to_thread(insp.evaluate_json, js)
        except iwdp.InspectorError:
            # A navigation drops the runtime and can drop the socket. Re-attach once and
            # retry, because "the page navigated" is normal pipeline behaviour, not an error.
            tab.inspector = None
            tab.runtime_ready = False
            tab.calibration = None
            insp = await self._attach(tab)
            return await asyncio.to_thread(insp.evaluate_json, js)

    async def _ensure_runtime(self, tab: Tab) -> None:
        """Re-inject the runtime if a navigation wiped it."""
        present = await self.evaluate(tab, f"typeof window.{runtime_js.NS} === 'object'")
        if not present:
            tab.runtime_ready = False
            await self._attach(tab)
            tab.calibration = None

    # -- input -------------------------------------------------------------------

    async def read_viewport(self, tab: Tab) -> dict:
        """Read the live viewport and cache it on the tab.

        Cached because :meth:`viewport` has to be synchronous — callers that set the CUA /
        Vision screen size and the geometry gates are not async — while the value itself can
        only come from an async evaluate. Every input path refreshes it, so the cache is
        never more than one interaction stale.
        """
        vp = await self.evaluate(tab, f"window.{runtime_js.NS}.viewport()")
        if vp:
            tab.meta["viewport"] = vp
        return vp or {}

    async def _assert_foreground(self, tab: Tab) -> None:
        """Refuse to send HID input to a page that is not the foreground tab.

        This is the asymmetry between the two channels, and it has no desktop analogue: a
        read works on a background tab, so nothing else in the stack would notice. Without
        this check a tap computed from a background tab's DOM lands on whatever is in front,
        which is indistinguishable from a mis-calibration and corrupts state on the wrong page.
        """
        state = await self.evaluate(
            tab, "{visibility: document.visibilityState, hidden: document.hidden}"
        )
        if not state or state.get("visibility") != "visible" or state.get("hidden"):
            raise BackendUnsupported(
                f"refusing to send input to a non-foreground tab ({tab.url!r}: "
                f"visibilityState={state and state.get('visibility')!r}). IWDP can read a "
                f"background tab but AXe taps only reach the foreground one, so this tap "
                f"would land on different content and appear to succeed."
            )

    async def _calibration(self, tab: Tab) -> geometry.Calibration:
        """Return a calibration valid for the tab's *current* layout, measuring if needed."""
        await self._ensure_runtime(tab)
        assert self._screen is not None, "start() must run before input"
        viewport = await self.read_viewport(tab)
        if tab.calibration is not None and tab.calibration.is_valid_for(viewport):
            return tab.calibration
        insp = await self._attach(tab)
        tab.calibration = await asyncio.to_thread(
            lambda: geometry.calibrate(
                evaluate_json=insp.evaluate_json,
                tap=lambda x, y: hid.tap(self.udid, x, y, screen=self._screen),
                screen_width=self._screen.width,
                screen_height=self._screen.height,
                probe=geometry.SR_PROBE,
            )
        )
        return tab.calibration

    async def tap(self, tab: Tab, client_x: float, client_y: float) -> dict:
        """A trusted tap at CSS-pixel (client) coordinates. Returns the observed event."""
        await self._assert_foreground(tab)
        # Cheap checks before the expensive one. Calibration costs two real HID taps plus
        # settle time, so validating the target first avoids paying for a tap we are about to
        # refuse — and it keeps the failure attributable to the target rather than to the
        # calibration that happened to run alongside it.
        viewport = await self.read_viewport(tab)
        vis = geometry.visible_height(viewport)
        if client_y < 0 or client_y > vis:
            occluded = (
                " — the software keyboard is covering it"
                if vis < float(viewport.get("innerHeight") or 0)
                else ""
            )
            raise geometry.CalibrationError(
                f"client y={client_y:.0f} is outside the visible region (0..{vis:.0f})"
                f"{occluded}; scroll it into view before tapping"
            )
        calib = await self._calibration(tab)
        sx, sy = calib.to_screen(client_x, client_y)
        insp = await self._attach(tab)
        return await asyncio.to_thread(
            lambda: geometry.tap_and_capture(
                insp.evaluate_json,
                lambda x, y: hid.tap(self.udid, x, y, screen=self._screen),
                (sx, sy),
                probe=geometry.SR_PROBE,
            )
        )

    # Named keys route to real HID via hid.KEYCODES (single source of truth — a duplicated
    # table here would drift, and a wrong keycode is a silent wrong keypress: Escape is 41,
    # Return is 40). Modifier combos are handled in-page instead: AXe modifier sequences are
    # not reliable across Xcode bumps, and the in-page equivalent is both stabler and
    # observable in its return value.

    async def key(self, tab: Tab, combo: str) -> None:
        await self._assert_foreground(tab)
        if combo in hid.KEYCODES:
            await asyncio.to_thread(hid.key, self.udid, combo)
            return
        if combo.lower() in ("control+a", "meta+a", "cmd+a"):
            await self.evaluate(
                tab,
                "(function(){var el=document.activeElement; if(!el) return false;"
                " try { document.execCommand('selectAll'); return true; } catch(e){ return false; }})()",
            )
            return
        raise BackendUnsupported(
            f"key combo {combo!r} has no reliable iOS route. Named keys available: "
            f"{sorted(hid.KEYCODES)}; select-all is handled in-page. Add an explicit "
            f"mapping rather than guessing an AXe modifier sequence."
        )

    async def scroll(self, tab: Tab, dx: float, dy: float) -> None:
        """Scroll by a real swipe.

        Not ``window.scrollBy``: a JS scroll moves the content but does not reproduce the
        chrome collapse a real gesture causes, and on iOS 26 that collapse changes the
        bottom toolbar height — i.e. it changes the very geometry a subsequent tap depends
        on. Scrolling by gesture keeps the measured calibration honest about reality.
        """
        await self._assert_foreground(tab)
        assert self._screen is not None
        w, h = self._screen.width, self._screen.height
        # A downward scroll (positive dy) means content moves up: swipe upward.
        span = min(abs(dy), h * 0.5) or h * 0.4
        start_y = h * 0.72 if dy > 0 else h * 0.28
        end_y = start_y - span if dy > 0 else start_y + span
        await asyncio.to_thread(
            hid.swipe, self.udid, w * 0.5, start_y, w * 0.5, max(1.0, min(h - 1, end_y))
        )
        tab.calibration = None  # the chrome may have moved; force a re-measure

    # -- degraded primitives, explicitly ----------------------------------------

    async def upload(self, tab: Tab, selector: str, host_paths: list[str]) -> None:
        raise BackendUnsupported(
            "file upload from the host into MobileSafari has no automation path: there is no "
            "DOM.setFileInputFiles equivalent over IWDP, and a real <input type=file> tap "
            "opens the iOS document picker, which is native UI outside the web view. The "
            "pipeline must route upload-dependent phases (notably NotebookLM source upload) "
            "to the desktop backend, which is what coexistence is for."
        )

    async def download_capture(self, tab: Tab, trigger) -> Any:
        raise BackendUnsupported(
            "downloads land in the Simulator's Files container and MobileSafari gives no "
            "download-completion signal over IWDP. Where an artifact is needed, prefer "
            "fetching it in-page and returning the bytes through evaluate."
        )

    async def read_clipboard(self, tab: Tab) -> str:
        """In-page read only — never the OS clipboard.

        ``navigator.clipboard.readText()`` needs a user gesture and a permission grant, so
        the supported pattern is to intercept the page's own copy (a ``copy`` listener
        installed before triggering it) rather than to read the system pasteboard. Reading
        the Simulator's pasteboard would also be shared global state across tabs and runs.
        """
        value = await self.evaluate(
            tab, f"window.{runtime_js.NS}.__lastCopy === undefined ? null : window.{runtime_js.NS}.__lastCopy"
        )
        if value is None:
            raise BackendUnsupported(
                "no in-page copy has been intercepted. Install a `copy` listener that stores "
                "the payload on the runtime object before triggering the page's copy action; "
                "the OS pasteboard is deliberately not read."
            )
        return value

    async def screenshot(self, tab: Tab) -> bytes:
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmp:
            out = str(Path(tmp) / "shot.png")
            await asyncio.to_thread(hid.screenshot, self.udid, out)
            return Path(out).read_bytes()

    def viewport(self, tab: Tab) -> tuple[int, int]:
        """The REAL mobile viewport in CSS pixels — never the desktop 1280x800.

        Cached from the last runtime read, because callers (CUA/Vision screen size, geometry
        gates) need it synchronously. The desktop pipeline's 1280x800 is load-bearing in
        those places, and carrying it onto a 402x714 surface puts every derived coordinate in
        the wrong place while still looking like a valid number.
        """
        vp = tab.meta.get("viewport")
        if not vp:
            raise RuntimeError(
                "viewport not yet measured for this tab — await an evaluate first so the "
                "runtime can report real mobile metrics (do NOT default to 1280x800)"
            )
        return int(vp["innerWidth"]), int(vp["innerHeight"])
