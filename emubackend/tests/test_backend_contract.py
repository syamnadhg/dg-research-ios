"""The seam's contract tests.

The recipe requires that *every* primitive a forked function might call is either implemented
or **explicitly** degraded (§5 / §8.1). The reason is specific: a silently no-op'ing primitive
looks like success and corrupts a run far downstream, which is the most expensive class of
bug this pipeline has actually suffered (the P1 raw-activity incident — every click landed,
extraction returned zero for an entire run, and the run reported success).

Tests run the async surface with ``asyncio.run`` rather than pulling in ``pytest-asyncio``:
one fewer dependency, and the call sites read the same.
"""

from __future__ import annotations

import ast
import asyncio
import inspect
from pathlib import Path

import pytest

from emubackend.substrate import geometry, page_shim
from emubackend.substrate.backend import (
    BackendUnsupported,
    BrowserBackend,
    IOSSimulatorBackend,
    Tab,
)

BACKEND_SRC = Path(inspect.getfile(IOSSimulatorBackend))


# --------------------------------------------------------------------------------------
# the ABC contract
# --------------------------------------------------------------------------------------


def _abstract_names() -> set[str]:
    return {
        name
        for name, val in vars(BrowserBackend).items()
        if getattr(val, "__isabstractmethod__", False)
    }


def test_the_ios_backend_implements_every_abstract_primitive():
    missing = _abstract_names() - set(vars(IOSSimulatorBackend))
    assert not missing, (
        f"IOSSimulatorBackend inherits {sorted(missing)} abstractly — it cannot be "
        f"instantiated, and more importantly the seam would be incomplete"
    )


def test_the_ios_backend_is_instantiable():
    """An abstract leftover would surface here as a TypeError."""
    IOSSimulatorBackend(udid="NOT-A-REAL-UDID")


def test_backend_unsupported_is_catchable_as_notimplementederror():
    """Ported code that already guards `except NotImplementedError` must keep working."""
    assert issubclass(BackendUnsupported, NotImplementedError)


def _method_bodies() -> dict[str, ast.FunctionDef]:
    tree = ast.parse(BACKEND_SRC.read_text(encoding="utf-8"))
    cls = next(
        n
        for n in tree.body
        if isinstance(n, ast.ClassDef) and n.name == "IOSSimulatorBackend"
    )
    return {
        n.name: n
        for n in cls.body
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


def test_no_primitive_is_a_silent_no_op():
    """A primitive may do nothing only if its docstring says so and why.

    This is the guard that stops the seam from *appearing* complete. A method whose body is
    `pass` satisfies the ABC and the type checker while doing nothing at all.
    """
    bodies = _method_bodies()
    offenders = []
    for name in sorted(_abstract_names()):
        node = bodies.get(name)
        if node is None:
            continue
        stmts = [s for s in node.body if not isinstance(s, ast.Expr) or not isinstance(s.value, ast.Constant)]
        trivial = not stmts or all(
            isinstance(s, ast.Pass)
            or (isinstance(s, ast.Return) and (s.value is None or _is_none(s.value)))
            for s in stmts
        )
        if not trivial:
            continue
        doc = ast.get_docstring(node) or ""
        if "no-op" not in doc.lower():
            offenders.append(
                f"{name}() does nothing and its docstring does not say 'No-op' + why"
            )
    assert not offenders, "\n".join(offenders)


def _is_none(node: ast.expr) -> bool:
    return isinstance(node, ast.Constant) and node.value is None


def test_every_degraded_primitive_explains_the_alternative():
    """`BackendUnsupported` is only useful if it names what to do instead."""
    src = BACKEND_SRC.read_text(encoding="utf-8")
    tree = ast.parse(src)
    messages = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Raise)
            and isinstance(node.exc, ast.Call)
            and getattr(node.exc.func, "id", None) == "BackendUnsupported"
            and node.exc.args
        ):
            arg = node.exc.args[0]
            text = " ".join(
                v.value for v in ast.walk(arg) if isinstance(v, ast.Constant) and isinstance(v.value, str)
            )
            messages.append((node.lineno, text))
    assert messages, "no degraded primitives found — did the module change shape?"
    for lineno, text in messages:
        assert len(text) > 80, f"line {lineno}: BackendUnsupported message is too terse to act on"


@pytest.mark.parametrize("name", ["open_isolated_tab", "switch_to", "upload", "download_capture"])
def test_known_degraded_primitives_raise_backend_unsupported(name):
    backend = IOSSimulatorBackend(udid="NOT-A-REAL-UDID")
    tab = Tab(url="about:blank", ws_url="")
    args = {
        "open_isolated_tab": ("about:blank",),
        "switch_to": (tab,),
        "upload": (tab, "input", ["/tmp/x"]),
        "download_capture": (tab, None),
    }[name]
    with pytest.raises(BackendUnsupported):
        asyncio.run(getattr(backend, name)(*args))


def test_bring_to_front_is_a_documented_no_op_not_a_failure():
    """Callers use it as a hint; raising would abort work that is about to succeed."""
    backend = IOSSimulatorBackend(udid="NOT-A-REAL-UDID")
    assert asyncio.run(backend.bring_to_front(Tab(url="", ws_url=""))) is None


def test_viewport_refuses_to_invent_a_desktop_default():
    """1280x800 is load-bearing on desktop; silently returning it here would be poison."""
    backend = IOSSimulatorBackend(udid="NOT-A-REAL-UDID")
    with pytest.raises(RuntimeError, match="1280x800"):
        backend.viewport(Tab(url="", ws_url=""))


# --------------------------------------------------------------------------------------
# the foreground asymmetry — the iOS-specific hazard with no desktop analogue
# --------------------------------------------------------------------------------------


class _StubBackend(IOSSimulatorBackend):
    """IOSSimulatorBackend with only `evaluate` faked, so the guards run for real."""

    def __init__(self, visibility="visible", vv_height=714.0, inner_height=714.0):
        super().__init__(udid="NOT-A-REAL-UDID")
        self.visibility = visibility
        self.vv_height = vv_height
        self.inner_height = inner_height
        self.evaluated: list[str] = []

    async def evaluate(self, tab, js):
        self.evaluated.append(js)
        if "visibilityState" in js:
            return {
                "visibility": self.visibility,
                "hidden": self.visibility != "visible",
            }
        if "viewport()" in js:
            return {
                "innerWidth": 402,
                "innerHeight": self.inner_height,
                "vvHeight": self.vv_height,
                "vvOffsetTop": 0,
                "vvOffsetLeft": 0,
                "vvScale": 1,
            }
        if "typeof window." in js:
            return True
        return None


def test_input_is_refused_on_a_background_tab():
    """IWDP reads a background tab happily; an AXe tap would hit the foreground one.

    Nothing else in the stack notices, so without this the automation operates confidently
    on the wrong page.
    """
    backend = _StubBackend(visibility="hidden")
    with pytest.raises(BackendUnsupported) as exc:
        asyncio.run(backend.tap(Tab(url="https://x/", ws_url=""), 100.0, 100.0))
    assert "non-foreground" in str(exc.value)
    assert "would land on different content" in str(exc.value)


def test_input_is_refused_when_the_keyboard_covers_the_target():
    backend = _StubBackend(visibility="visible", vv_height=377.0, inner_height=714.0)
    with pytest.raises(geometry.CalibrationError) as exc:
        asyncio.run(backend.tap(Tab(url="https://x/", ws_url=""), 100.0, 600.0))
    assert "keyboard" in str(exc.value)


def test_key_refuses_an_unmapped_combo_rather_than_guessing():
    backend = _StubBackend()
    with pytest.raises(BackendUnsupported, match="no reliable iOS route"):
        asyncio.run(backend.key(Tab(url="https://x/", ws_url=""), "Control+Shift+P"))


# --------------------------------------------------------------------------------------
# PageShim
# --------------------------------------------------------------------------------------


class _FakeBackend(BrowserBackend):
    """Records JS and serves canned runtime replies, so the shim's wiring is under test."""

    def __init__(self):
        self.js: list[str] = []
        self.taps: list[tuple[float, float]] = []
        self.scrolls: list[tuple[float, float]] = []
        self.keys: list[str] = []
        self.rect = {"left": 10.0, "top": 20.0, "width": 100.0, "height": 40.0, "cx": 60.0, "cy": 40.0}
        self.detached = False

    async def evaluate(self, tab, js):
        self.js.append(js)
        if ".query(" in js:
            return None if "missing" in js else 7
        if ".queryAll(" in js:
            return [7, 8]
        if ".reg(document.activeElement)" in js:
            return 9
        if self.detached:
            return {"err": "detached"}
        if ".rectOf(" in js:
            return dict(self.rect)
        if ".textOf(" in js:
            return {"text": "hello"}
        if ".attrOf(" in js:
            return {"value": "bar"}
        if ".visibleOf(" in js:
            return {"visible": True}
        if ".scrollIntoView(" in js or ".selectAll(" in js:
            return {"ok": True}
        if ".insertText(" in js:
            return {"ok": True, "path": "execCommand"}
        if ".release(" in js:
            return True
        if "h.el.click()" in js:
            return {"ok": True}
        return None

    async def tap(self, tab, client_x, client_y):
        self.taps.append((client_x, client_y))
        return {"isTrusted": True, "clientX": client_x, "clientY": client_y}

    async def scroll(self, tab, dx, dy):
        self.scrolls.append((dx, dy))

    async def key(self, tab, combo):
        self.keys.append(combo)

    async def start(self): ...
    async def close(self): ...
    async def health(self):
        return True
    async def new_tab(self, url):
        return Tab(url=url, ws_url="")
    async def open_isolated_tab(self, url):
        raise BackendUnsupported("x" * 100)
    async def switch_to(self, tab): ...
    async def bring_to_front(self, tab): ...
    async def upload(self, tab, selector, host_paths):
        raise BackendUnsupported("y" * 100)
    async def download_capture(self, tab, trigger):
        raise BackendUnsupported("z" * 100)
    async def read_clipboard(self, tab):
        return "copied"
    async def screenshot(self, tab):
        return b"png"
    def viewport(self, tab):
        return (402, 714)


def _shim() -> tuple[page_shim.PageShim, _FakeBackend]:
    be = _FakeBackend()
    return page_shim.PageShim(be, Tab(url="https://x/", ws_url="")), be


def test_query_selector_returns_a_handle_and_none_when_absent():
    page, _ = _shim()
    assert asyncio.run(page.query_selector("#a")).id == 7
    assert asyncio.run(page.query_selector("#missing")) is None


def test_query_selector_all_returns_every_handle():
    page, _ = _shim()
    assert [h.id for h in asyncio.run(page.query_selector_all(".x"))] == [7, 8]


def test_element_reads_unwrap_the_runtime_envelope():
    page, _ = _shim()
    el = asyncio.run(page.query_selector("#a"))
    assert asyncio.run(el.inner_text()) == "hello"
    assert asyncio.run(el.get_attribute("data-x")) == "bar"
    assert asyncio.run(el.is_visible()) is True


def test_bounding_box_uses_playwrights_key_names():
    """Ported code reads box['x']/['y']; returning left/top would KeyError at the call site."""
    page, _ = _shim()
    el = asyncio.run(page.query_selector("#a"))
    assert asyncio.run(el.bounding_box()) == {"x": 10.0, "y": 20.0, "width": 100.0, "height": 40.0}


def test_a_null_runtime_reply_is_treated_as_failure_not_success():
    """A None means the expression threw or the runtime is gone — never "fine".

    Letting it pass is the exact shape of the pipeline's most expensive bug class: the call
    reports success and the page was never touched.
    """
    page, be = _shim()
    el = asyncio.run(page.query_selector("#a"))

    async def always_none(tab, js):
        return None

    be.evaluate = always_none  # type: ignore[assignment]
    with pytest.raises(page_shim.StaleHandleError, match="returned nothing"):
        asyncio.run(el.inner_text())


def test_a_detached_handle_raises_instead_of_doing_nothing():
    """The load-bearing assertion: a stale handle must never silently no-op."""
    page, be = _shim()
    el = asyncio.run(page.query_selector("#a"))
    be.detached = True
    with pytest.raises(page_shim.StaleHandleError, match="detached"):
        asyncio.run(el.inner_text())


def test_click_scrolls_into_view_then_re_reads_the_rect_before_tapping():
    """Using the pre-scroll rect would tap whatever moved into that position."""
    page, be = _shim()
    el = asyncio.run(page.query_selector("#a"))
    asyncio.run(el.click())
    order = [j for j in be.js if ".scrollIntoView(" in j or ".rectOf(" in j]
    assert order[0].count("scrollIntoView") == 1, "scroll must precede the rect read"
    assert ".rectOf(" in order[1]
    assert be.taps == [(60.0, 40.0)]


def test_click_is_trusted_and_js_click_is_opt_in():
    """A silent downgrade to el.click() would produce runs that accomplish nothing."""
    page, be = _shim()
    el = asyncio.run(page.query_selector("#a"))
    asyncio.run(el.click())
    assert be.taps, "click() must go through the HID channel"
    assert not any(".el.click()" in j for j in be.js)

    asyncio.run(el.js_click())
    assert any("h.el.click()" in j for j in be.js)


def test_fill_focuses_by_real_tap_then_uses_the_editor_aware_path():
    page, be = _shim()
    el = asyncio.run(page.query_selector("#a"))
    res = asyncio.run(el.fill("hello"))
    assert be.taps, "fill must focus with a trusted tap so the composer's handlers run"
    assert res["path"] == "execCommand"
    assert any(".selectAll(" in j for j in be.js), "existing text must be replaced, not appended"


def test_keyboard_type_routes_through_the_focused_element():
    page, be = _shim()
    asyncio.run(page.keyboard.type("abc"))
    assert any(".reg(document.activeElement)" in j for j in be.js)
    assert any(".insertText(9, 'abc')" in j for j in be.js)


def test_keyboard_press_delegates_to_the_backend():
    page, be = _shim()
    asyncio.run(page.keyboard.press("Enter"))
    assert be.keys == ["Enter"]


def test_mouse_move_is_refused_because_touch_has_no_hover():
    page, _ = _shim()
    with pytest.raises(BackendUnsupported, match="no hover"):
        asyncio.run(page.mouse.move(1, 2))


def test_goto_invalidates_the_runtime_and_the_calibration():
    """A navigation wipes both; keeping either would fail obscurely on the next input."""
    page, _ = _shim()
    page._tab.runtime_ready = True
    page._tab.calibration = geometry.Calibration(1, 1, 0, 62, {})
    asyncio.run(page.goto("https://y/"))
    assert page._tab.runtime_ready is False
    assert page._tab.calibration is None
    assert page.url == "https://y/"


def test_page_viewport_reports_real_mobile_metrics():
    page, _ = _shim()
    assert page.viewport() == (402, 714)
    assert page.viewport() != (1280, 800)


def test_wait_for_selector_times_out_with_a_useful_message():
    page, be = _shim()

    async def only_missing(tab, js):
        be.js.append(js)
        return None

    be.evaluate = only_missing  # type: ignore[assignment]
    with pytest.raises(TimeoutError, match="did not appear"):
        asyncio.run(page.wait_for_selector("#never", timeout=0.3, poll=0.05))
