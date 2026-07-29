"""`PageShim` — the Playwright-`Page`-shaped surface the ported P0–P3 functions call.

The recipe's §5 spec, second half. The measured porting cost is 135 functions taking
``page``/``browser`` (~24,764 lines), and ~225 of those calls are ``page.evaluate`` — so the
value of this shim is almost entirely in how faithfully ``evaluate``, ``query_selector`` and
the composer-text path behave. Everything else is a thin route to the backend.

**Handles are the interesting part.** Playwright's ``query_selector`` returns a live object
reference; ``Runtime.evaluate`` returns JSON. Elements are therefore parked in the injected
runtime's registry and referenced by integer id (see :mod:`emubackend.substrate.runtime_js`).
A handle whose node has since been detached reports ``detached`` rather than silently doing
nothing — a no-op on a stale handle is exactly the failure that reads as "the click landed
but the page did not react", which is the pipeline's single most expensive symptom
(cf. the P1 raw-activity incident: every click landed, extraction returned zero all run).

**One deliberate divergence from Playwright, and it is a safety feature.** Playwright's
``element.click()`` synthesises a trusted event because it drives the browser. Here, a
trusted event requires the HID channel, which requires the page to be *foreground* and the
element to be *visible* — the geometry cannot be faked. So :meth:`ElementHandleShim.click`
scrolls into view and taps for real, and raises rather than falling back to an in-page
``el.click()``. The fallback is available as :meth:`ElementHandleShim.js_click` and is
explicitly opt-in, because the chat SPAs reject untrusted events and a silent downgrade
would produce a run that appears to work and accomplishes nothing.
"""

from __future__ import annotations

from typing import Any

from emubackend.substrate import runtime_js
from emubackend.substrate.backend import BackendUnsupported, BrowserBackend, Tab

__all__ = [
    "ElementHandleShim",
    "KeyboardShim",
    "MouseShim",
    "PageShim",
    "StaleHandleError",
]

NS = runtime_js.NS


class StaleHandleError(RuntimeError):
    """The handle's node is gone from the document, or the runtime was reloaded."""


def _unwrap(result: Any, what: str) -> Any:
    """Raise on the runtime's ``{err: …}`` envelope instead of returning a falsy value.

    ``None`` counts as a failure, not a success. Every runtime call that reaches here returns
    an object, so a ``None`` means the expression threw or ``window.__sr`` was absent — and
    letting that pass silently is precisely the "the click landed but nothing happened" class
    of bug this seam exists to make impossible.
    """
    if result is None:
        raise StaleHandleError(
            f"{what}: the runtime returned nothing, which means the expression threw or "
            f"window.{NS} is absent (usually: the page navigated). Re-query the selector."
        )
    if isinstance(result, dict) and result.get("err"):
        err = result["err"]
        if err in ("detached", "no-such-handle"):
            raise StaleHandleError(
                f"{what}: handle is {err}. The node was removed or the page navigated and "
                f"the runtime was re-injected; re-query the selector."
            )
        raise RuntimeError(f"{what}: {err}")
    return result


class ElementHandleShim:
    """A reference to one DOM node, valid until it detaches or the page navigates."""

    def __init__(self, page: PageShim, handle_id: int):
        self._page = page
        self.id = handle_id

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<ElementHandleShim id={self.id}>"

    async def inner_text(self) -> str:
        res = _unwrap(await self._page.evaluate(f"window.{NS}.textOf({self.id})"), "inner_text")
        return res["text"]

    async def get_attribute(self, name: str) -> str | None:
        res = _unwrap(
            await self._page.evaluate(f"window.{NS}.attrOf({self.id}, {name!r})"),
            "get_attribute",
        )
        return res["value"]

    async def bounding_box(self) -> dict | None:
        """``{x, y, width, height}`` in CSS pixels, matching Playwright's key names."""
        res = await self._page.evaluate(f"window.{NS}.rectOf({self.id})")
        if isinstance(res, dict) and res.get("err"):
            return None  # Playwright returns None for a non-rendered element
        return {
            "x": res["left"],
            "y": res["top"],
            "width": res["width"],
            "height": res["height"],
        }

    async def is_visible(self) -> bool:
        res = await self._page.evaluate(f"window.{NS}.visibleOf({self.id})")
        return bool(res and res.get("visible"))

    async def scroll_into_view_if_needed(self) -> None:
        _unwrap(
            await self._page.evaluate(f"window.{NS}.scrollIntoView({self.id})"),
            "scroll_into_view_if_needed",
        )

    async def click(self) -> dict:
        """A **trusted** tap on this element's centre. Returns the observed event.

        Scrolls into view first, then re-reads the rect: the scroll changes it, and using the
        pre-scroll rect is a mistake that lands the tap on whatever moved into that position.
        """
        await self.scroll_into_view_if_needed()
        rect = _unwrap(await self._page.evaluate(f"window.{NS}.rectOf({self.id})"), "click")
        return await self._page._backend.tap(self._page._tab, rect["cx"], rect["cy"])

    async def js_click(self) -> bool:
        """An **untrusted** in-page ``el.click()``. Opt-in, and usually the wrong tool.

        Kept because a few controls are plain anchors or non-SPA buttons where trust is not
        checked, and a JS click is faster and needs no geometry. Never use it on a composer,
        a send control, or anything a chat SPA gates — those reject ``isTrusted === false``
        and the failure is silent.
        """
        res = await self._page.evaluate(
            f"(function(){{var h=window.{NS}.get({self.id}); if(h.err) return h;"
            f" h.el.click(); return {{ok:true}};}})()"
        )
        _unwrap(res, "js_click")
        return True

    async def fill(self, text: str) -> dict:
        """Replace this element's text, using the path its editor actually understands."""
        await self.click()  # focus by real tap, so the composer's own handlers run
        _unwrap(await self._page.evaluate(f"window.{NS}.selectAll({self.id})"), "fill")
        return _unwrap(
            await self._page.evaluate(f"window.{NS}.insertText({self.id}, {text!r})"), "fill"
        )

    async def release(self) -> None:
        """Drop the registry entry. Optional, but keeps long runs from accumulating nodes."""
        await self._page.evaluate(f"window.{NS}.release({self.id})")


class KeyboardShim:
    def __init__(self, page: PageShim):
        self._page = page

    async def press(self, combo: str) -> None:
        await self._page._backend.key(self._page._tab, combo)

    async def type(self, text: str) -> None:
        """Type into the focused element via the runtime's editor-aware path.

        Routed through the focused element rather than raw HID typing so ``contenteditable``
        composers get ``execCommand('insertText')``. Raw HID typing reaches the field but
        leaves a ProseMirror model empty, which disables the send button — a failure that
        looks like the page ignoring you.
        """
        handle_id = await self._page.evaluate(
            f"window.{NS}.reg(document.activeElement)"
        )
        if not handle_id:
            raise RuntimeError("keyboard.type: nothing is focused")
        _unwrap(
            await self._page.evaluate(f"window.{NS}.insertText({handle_id}, {text!r})"),
            "keyboard.type",
        )

    async def insert_text(self, text: str) -> None:
        await self.type(text)


class MouseShim:
    """Present for source compatibility; coordinates are CSS pixels, as in Playwright."""

    def __init__(self, page: PageShim):
        self._page = page

    async def click(self, x: float, y: float) -> dict:
        return await self._page._backend.tap(self._page._tab, x, y)

    async def wheel(self, dx: float, dy: float) -> None:
        await self._page._backend.scroll(self._page._tab, dx, dy)

    async def move(self, x: float, y: float) -> None:
        raise BackendUnsupported(
            "there is no hover on a touch surface — no pointer exists between taps. Any flow "
            "that depends on a hover-revealed control needs a mobile-specific alternative "
            "(long-press, or the control's own tap target), not a simulated move."
        )


class PageShim:
    """The object the forked P0–P3 driver functions call."""

    def __init__(self, backend: BrowserBackend, tab: Tab):
        self._backend = backend
        self._tab = tab
        self.keyboard = KeyboardShim(self)
        self.mouse = MouseShim(self)

    # -- navigation / JS ---------------------------------------------------------

    @property
    def url(self) -> str:
        return self._tab.url

    async def goto(self, url: str) -> None:
        await self.evaluate(f"window.location.assign({url!r})")
        self._tab.url = url
        # A navigation wipes the injected runtime and invalidates the calibration; clearing
        # both here means the next call re-establishes them instead of failing obscurely.
        self._tab.runtime_ready = False
        self._tab.calibration = None

    async def evaluate(self, js: str) -> Any:
        return await self._backend.evaluate(self._tab, js)

    # -- queries -----------------------------------------------------------------

    async def query_selector(self, selector: str) -> ElementHandleShim | None:
        handle_id = await self.evaluate(f"window.{NS}.query({selector!r})")
        return ElementHandleShim(self, handle_id) if handle_id else None

    async def query_selector_all(self, selector: str) -> list[ElementHandleShim]:
        ids = await self.evaluate(f"window.{NS}.queryAll({selector!r})") or []
        return [ElementHandleShim(self, i) for i in ids if i]

    async def wait_for_selector(
        self, selector: str, timeout: float = 30.0, poll: float = 0.25
    ) -> ElementHandleShim:
        """Poll for a selector. Explicitly *not* a Playwright waiter.

        Playwright waits inside the browser; over this transport the only option is polling
        from the host. Stated plainly because the cost differs — each poll is a round trip —
        so callers should prefer one generous wait over many tight ones.
        """
        import asyncio as _asyncio

        deadline = _asyncio.get_event_loop().time() + timeout
        while _asyncio.get_event_loop().time() < deadline:
            found = await self.query_selector(selector)
            if found is not None:
                return found
            await _asyncio.sleep(poll)
        raise TimeoutError(f"selector {selector!r} did not appear within {timeout}s")

    # -- input / misc ------------------------------------------------------------

    async def set_input_files(self, selector: str, paths: list[str]) -> None:
        await self._backend.upload(self._tab, selector, paths)

    async def screenshot(self) -> bytes:
        return await self._backend.screenshot(self._tab)

    async def bring_to_front(self) -> None:
        await self._backend.bring_to_front(self._tab)

    async def read_clipboard(self) -> str:
        return await self._backend.read_clipboard(self._tab)

    def viewport(self) -> tuple[int, int]:
        """REAL mobile CSS-pixel metrics — never the desktop 1280x800."""
        return self._backend.viewport(self._tab)
