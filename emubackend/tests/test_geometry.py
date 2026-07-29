"""Unit tests for the CSS-pixel -> screen-point geometry.

The B0a gate exercises this against a real Simulator, which is slow, stateful, and cannot
run in CI. These tests pin the *logic* against a fake page that reproduces the two device
behaviours that actually cost time to discover:

* **The straggler.** MobileSafari emits a tap as ``pointerdown`` -> ``touchstart`` ->
  ``click``, with ``click`` late. On the device, tap *N*'s ``click`` landed in the event list
  **ahead of** tap *N+1*'s own ``pointerdown``, so picking "the first trusted event with
  coordinates" returned the *previous* tap's (integer-rounded) position. That produced a
  derived scale of 241 instead of 1 — an error far from its cause.
* **The keyboard.** It shrinks ``visualViewport.height`` and leaves ``window.innerHeight``
  alone, so an innerHeight-based visibility check taps straight through the keyboard.

Both are encoded in :class:`FakePage` so a regression fails here in milliseconds rather than
as a puzzling Simulator flake.
"""

from __future__ import annotations

import re

import pytest

from emubackend.substrate import geometry


@pytest.fixture(autouse=True)
def _no_settle_delay(monkeypatch):
    """Zero the real-device settle pause; the fake controls its own timing explicitly."""
    monkeypatch.setattr(geometry, "SETTLE_SECONDS", 0.0)


class FakePage:
    """A stand-in for the B0a probe page plus MobileSafari's geometry.

    Screen points map to CSS pixels by ``client = (screen - offset) / scale``. Taps outside
    the visible band record nothing, matching the device's behaviour when a tap lands on
    Safari's chrome or the keyboard.

    ``click_mode`` selects when the terminal ``click`` is delivered:

    * ``"poll"`` (default) — on the second ``.events`` read, i.e. while ``tap_and_capture``
      is still polling. This is the normal device case.
    * ``"immediate"`` — synchronously inside ``tap``.
    * ``"leak"`` — held until the *next* ``tap``, where it is appended **before** that tap's
      own events. This is the pathological ordering observed on the device.
    """

    def __init__(
        self,
        *,
        scale: float = 1.0,
        top_chrome: float = 62.0,
        inner_height: float = 714.0,
        vv_height: float | None = None,
        screen_h: float = 874.0,
        click_mode: str = "poll",
    ):
        self.scale = scale
        self.top_chrome = top_chrome
        self.inner_height = inner_height
        self.vv_height = vv_height if vv_height is not None else inner_height
        self.screen_h = screen_h
        self.click_mode = click_mode
        self.events: list[dict] = []
        self._held_click: dict | None = None
        self._reads_since_tap = 0
        self.elements = {
            "t1": {"cx": 201.0, "cy": 108.0, "left": 91, "top": 76, "width": 220, "height": 64},
            "t3": {"cx": 201.0, "cy": 271.0, "left": 91, "top": 239, "width": 220, "height": 64},
            "deep": {"cx": 201.0, "cy": 690.0, "left": 91, "top": 658, "width": 220, "height": 64},
        }
        self.taps: list[tuple[float, float]] = []

    # -- the JS surface ----------------------------------------------------------

    def viewport(self) -> dict:
        return {
            "innerWidth": 402,
            "innerHeight": self.inner_height,
            "dpr": 3,
            "scrollX": 0,
            "scrollY": 0,
            "vvWidth": 402,
            "vvHeight": self.vv_height,
            "vvOffsetLeft": 0,
            "vvOffsetTop": 0,
            "vvPageLeft": 0,
            "vvPageTop": 0,
            "vvScale": 1,
        }

    def evaluate_json(self, expression: str):
        if "reset()" in expression:
            self.events = []
            return True
        if "calib(" in expression:
            return True
        if "viewport()" in expression:
            return self.viewport()
        if ".events" in expression:
            self._reads_since_tap += 1
            if (
                self.click_mode == "poll"
                and self._held_click is not None
                and self._reads_since_tap >= 2
            ):
                self.events.append(self._held_click)
                self._held_click = None
            return list(self.events)
        match = re.search(r"rect\('([^']+)'\)", expression)
        if match:
            el = self.elements.get(match.group(1))
            return dict(el, id=match.group(1)) if el else None
        return None

    def tap(self, x: float, y: float) -> None:
        self.taps.append((x, y))
        self._reads_since_tap = 0
        # In "leak" mode the previous tap's click arrives NOW — ahead of this tap's events.
        if self.click_mode == "leak" and self._held_click is not None:
            self.events.append(self._held_click)
            self._held_click = None
        client_y = (y - self.top_chrome) / self.scale
        client_x = x / self.scale
        if client_y < 0 or client_y > self.vv_height:
            return  # hit chrome or the keyboard: nothing recorded, as on the device
        base = {
            "isTrusted": True,
            "clientX": client_x,
            "clientY": client_y,
            "targetId": self._hit_target(client_y),
            "viewport": self.viewport(),
        }
        self.events.append({**base, "type": "pointerdown"})
        self.events.append({**base, "type": "touchstart"})
        # `click` carries integer-rounded coordinates on the real device — which is how the
        # misattributed sample was identifiable as a previous tap's click.
        click = {
            **base,
            "type": "click",
            "clientX": round(client_x),
            "clientY": round(client_y),
        }
        if self.click_mode == "immediate":
            self.events.append(click)
        else:
            self._held_click = click

    def _hit_target(self, client_y: float) -> str:
        for name, el in self.elements.items():
            if el["top"] <= client_y <= el["top"] + el["height"]:
                return name
        return "calib"


def _calibrate(page: FakePage) -> geometry.Calibration:
    return geometry.calibrate(
        evaluate_json=page.evaluate_json,
        tap=page.tap,
        screen_width=402.0,
        screen_height=page.screen_h,
    )


# --------------------------------------------------------------------------------------
# the transform
# --------------------------------------------------------------------------------------


def test_to_screen_applies_scale_then_offset():
    calib = geometry.Calibration(
        scale_x=2.0, scale_y=3.0, offset_x=10.0, offset_y=20.0, measured_in={}
    )
    assert calib.to_screen(5, 5) == (20.0, 35.0)


def test_calibrate_recovers_a_known_transform():
    page = FakePage(top_chrome=62.0, scale=1.0)
    calib = _calibrate(page)
    assert calib.offset_y == pytest.approx(62.0, abs=0.5)
    assert calib.offset_x == pytest.approx(0.0, abs=0.5)
    assert calib.scale_y == pytest.approx(1.0, abs=0.01)


def test_calibrate_recovers_a_pinch_zoomed_transform():
    """A one-point calibration would assume scale 1 here and be silently wrong."""
    page = FakePage(top_chrome=48.0, scale=1.5)
    calib = _calibrate(page)
    assert calib.scale_y == pytest.approx(1.5, abs=0.02)
    assert calib.offset_y == pytest.approx(48.0, abs=1.0)


def test_calibrate_survives_the_leaking_click_ordering():
    """End-to-end: the exact device conditions that produced scale_x = 241."""
    page = FakePage(top_chrome=62.0, scale=1.0, click_mode="leak")
    calib = _calibrate(page)
    assert calib.scale_x == pytest.approx(1.0, abs=0.02)
    assert calib.offset_y == pytest.approx(62.0, abs=1.0)


def test_calibrate_rejects_an_implausible_scale():
    page = FakePage()
    # Every tap reports the same coordinate — the shape the straggler bug produced.
    page.tap = lambda x, y: page.events.extend(  # type: ignore[assignment]
        [
            {"type": "pointerdown", "isTrusted": True, "clientX": 100, "clientY": 100, "targetId": "calib"},
            {"type": "click", "isTrusted": True, "clientX": 100, "clientY": 100, "targetId": "calib"},
        ]
    )
    with pytest.raises(geometry.CalibrationError, match="same CSS coordinate|implausible"):
        _calibrate(page)


def test_calibrate_reports_when_no_tap_lands():
    page = FakePage()
    page.tap = lambda x, y: None  # type: ignore[assignment]
    with pytest.raises(geometry.CalibrationError, match="fewer than two probe taps"):
        _calibrate(page)


# --------------------------------------------------------------------------------------
# the straggler, isolated
# --------------------------------------------------------------------------------------


def test_a_previous_taps_click_is_not_misattributed():
    """The load-bearing defence is the event-TYPE filter.

    In "leak" mode tap 1's ``click`` sits at index 0 of the list when tap 2 is read, so a
    "first trusted event with coordinates" pick returns tap 1's rounded position. Only
    restricting the positioning event to ``pointerdown``/``touchstart`` rejects it.
    """
    page = FakePage(click_mode="leak")
    first = geometry.tap_and_capture(page.evaluate_json, page.tap, (140.0, 250.0), timeout=0.3)
    second = geometry.tap_and_capture(page.evaluate_json, page.tap, (260.0, 400.0), timeout=0.3)

    # Tap 1's stale click really is present and really is first — the trap is armed.
    assert page.events[0]["type"] == "click"
    assert page.events[0]["clientY"] == round(250.0 - 62.0)

    assert first["clientY"] == pytest.approx(250.0 - 62.0)
    assert second["clientY"] == pytest.approx(400.0 - 62.0)


def test_tap_and_capture_returns_a_positioning_event_not_the_click():
    page = FakePage(click_mode="immediate")
    ev = geometry.tap_and_capture(page.evaluate_json, page.tap, (140.0, 250.0))
    # `click` rounds its coordinates on the device, so precise positioning must not come
    # from it even when it is present and trusted.
    assert ev["type"] in ("pointerdown", "touchstart")
    assert ev["clientY"] == pytest.approx(188.0)


def test_tap_and_capture_waits_for_the_terminal_click():
    """The second defence: don't return before this tap's sequence has completed."""
    page = FakePage(click_mode="poll")
    geometry.tap_and_capture(page.evaluate_json, page.tap, (140.0, 250.0))
    assert page._held_click is None, "the terminal click should have been consumed"


# --------------------------------------------------------------------------------------
# the keyboard: vvHeight vs innerHeight
# --------------------------------------------------------------------------------------


def test_visible_height_prefers_visual_viewport():
    assert geometry.visible_height({"innerHeight": 714, "vvHeight": 377}) == 377
    assert geometry.visible_height({"innerHeight": 714}) == 714


def test_keyboard_does_not_invalidate_the_calibration():
    """Measured on the device: the keyboard changes vvHeight only, so the transform holds.

    If vvHeight were treated as transform-relevant, every keyboard-open tap would demand a
    recalibration whose own probe taps would land on the keyboard.
    """
    calib = _calibrate(FakePage())
    with_keyboard = FakePage(vv_height=377.0).viewport()
    assert calib.is_valid_for(with_keyboard), calib.why_invalid(with_keyboard)


def test_a_real_layout_change_does_invalidate_the_calibration():
    calib = _calibrate(FakePage())
    rotated = FakePage(inner_height=390.0).viewport()
    assert not calib.is_valid_for(rotated)
    assert any("innerHeight" in r for r in calib.why_invalid(rotated))


def test_tap_element_refuses_a_target_hidden_behind_the_keyboard():
    """innerHeight would pass this element; only vvHeight catches the occlusion."""
    page = FakePage(vv_height=377.0)
    calib = geometry.Calibration(
        scale_x=1.0, scale_y=1.0, offset_x=0.0, offset_y=62.0,
        measured_in=page.viewport(),
    )
    with pytest.raises(geometry.CalibrationError) as exc:
        geometry.tap_element(
            evaluate_json=page.evaluate_json,
            tap=page.tap,
            calib=calib,
            element_id="deep",  # client y 690 — under innerHeight 714, over vvHeight 377
        )
    assert "keyboard is covering it" in str(exc.value)
    assert page.taps == [], "must refuse before tapping, not tap and hope"


def test_tap_element_hits_a_visible_target_with_the_keyboard_up():
    page = FakePage(vv_height=377.0)
    calib = geometry.Calibration(
        scale_x=1.0, scale_y=1.0, offset_x=0.0, offset_y=62.0,
        measured_in=page.viewport(),
    )
    ev = geometry.tap_element(
        evaluate_json=page.evaluate_json, tap=page.tap, calib=calib, element_id="t3"
    )
    assert ev["targetId"] == "t3"
    assert ev["isTrusted"] is True


def test_tap_element_refuses_a_stale_calibration():
    page = FakePage(inner_height=390.0)
    calib = geometry.Calibration(
        scale_x=1.0, scale_y=1.0, offset_x=0.0, offset_y=62.0,
        measured_in=FakePage(inner_height=714.0).viewport(),
    )
    with pytest.raises(geometry.CalibrationError, match="stale"):
        geometry.tap_element(
            evaluate_json=page.evaluate_json, tap=page.tap, calib=calib, element_id="t1"
        )


def test_tap_element_reports_an_unknown_element():
    page = FakePage()
    calib = _calibrate(page)
    with pytest.raises(geometry.CalibrationError, match="no element with id"):
        geometry.tap_element(
            evaluate_json=page.evaluate_json, tap=page.tap, calib=calib, element_id="nope"
        )
