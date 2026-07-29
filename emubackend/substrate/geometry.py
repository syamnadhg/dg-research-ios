"""Translating a DOM rect into an AXe screen point — by measurement, not assumption.

This is the part of the iOS substrate the recipe flags as most likely to pass on a toy page
and then die in P2. The mapping from CSS pixels to screen points passes through, in order:

* Safari's top chrome (URL bar), whose height **changes** as the page scrolls — iOS
  collapses and expands it;
* Safari's bottom toolbar;
* ``visualViewport`` scroll and pinch-zoom offsets;
* the software keyboard's inset when an input has focus.

Hardcoding those offsets is what makes a substrate layer rot: each is a function of device,
iOS version, orientation, and *current interaction state*. So this module does not hardcode
any of them. It derives the transform empirically:

1. Cover the viewport with a surface that records where a tap landed in CSS pixels.
2. Tap **two** known screen points.
3. Solve the affine map ``screen = client * scale + offset`` from the pair.

Two points rather than one because that measures ``scale`` instead of trusting
``visualViewport.scale``; a one-point calibration silently assumes scale 1 and is wrong the
moment a page permits pinch-zoom (the chat platforms do — our own probe page disables it,
which is exactly the kind of difference that would make a one-point calibration pass the
gate and fail in production).

A :class:`Calibration` records the viewport state it was measured in and refuses to be used
in a different one — see :meth:`Calibration.is_valid_for`. That refusal is the mechanism
that makes the scrolled and keyboard-open cases work: instead of trying to *predict* the new
offset, we notice the layout moved and measure again.
"""

from __future__ import annotations

import time as _time
from dataclasses import dataclass
from typing import Any, Callable

__all__ = ["Calibration", "CalibrationError", "calibrate", "tap_and_capture", "tap_element"]

#: Pause used to let a previous tap's late `click` land so it can be discarded. Exposed as
#: a module constant so the unit tests can zero it — otherwise the pure-logic suite pays
#: real device latency it does not need, and a slow suite is a suite that stops being run.
SETTLE_SECONDS = 0.45

#: Viewport fields that change the CSS-pixel -> screen-point transform. If any of these
#: differs from the value present at calibration time, the calibration is stale.
#:
#: ⚠ ``vvHeight`` is deliberately NOT here, and the distinction is measured, not guessed.
#: When the software keyboard opens, iOS Safari shrinks ``visualViewport.height``
#: (714 -> 377 on an iPhone 17 Pro) while leaving ``window.innerHeight`` at 714 and
#: ``vvOffsetTop`` at 0. So the keyboard changes *what part of the page you can see*, not
#: where a given CSS pixel sits on the screen — the transform is unaffected. Treating
#: ``vvHeight`` as transform-relevant would force a recalibration whose own probe taps
#: would land on the keyboard, turning a valid calibration into a failure.
_TRANSFORM_RELEVANT = (
    "innerHeight",
    "innerWidth",
    "vvOffsetTop",
    "vvOffsetLeft",
    "vvScale",
)


def visible_height(viewport: dict[str, Any]) -> float:
    """The CSS-pixel height actually visible — i.e. not behind the keyboard.

    ``window.innerHeight`` is the wrong number for a visibility check on iOS: it does not
    change when the keyboard opens, so an element half a screen down passes an
    innerHeight-based check and is then tapped *through* the keyboard. Only
    ``visualViewport.height`` reflects the occlusion.
    """
    vv = viewport.get("vvHeight")
    return float(vv) if vv else float(viewport.get("innerHeight", 0))


@dataclass(frozen=True)
class Probe:
    """The JS surface calibration needs, as expressions.

    Two surfaces provide it: the B0a fixture page (which ships its own) and the injected
    production runtime (:mod:`emubackend.substrate.runtime_js`). Parameterising the names
    keeps one calibration implementation for both, so the algorithm that was validated
    against a real Simulator in B0a is the same code that runs in production rather than a
    reimplementation of it.
    """

    ns: str = "__sr"
    rect_fn: str = "rectOf"

    def calib(self, on: bool) -> str:
        return f"window.{self.ns}.calib({'true' if on else 'false'})"

    def reset(self) -> str:
        return f"window.{self.ns}.reset()"

    def events(self) -> str:
        return f"window.{self.ns}.events"

    def viewport(self) -> str:
        return f"window.{self.ns}.viewport()"

    def rect(self, target: Any) -> str:
        arg = repr(target) if isinstance(target, str) else str(target)
        return f"window.{self.ns}.{self.rect_fn}({arg})"


#: The injected production runtime.
SR_PROBE = Probe()
#: The B0a fixture page, which predates the runtime and names things slightly differently.
B0A_PROBE = Probe(ns="__b0a", rect_fn="rect")


class CalibrationError(RuntimeError):
    """Calibration could not be measured, or was used in a state it is not valid for."""


@dataclass(frozen=True)
class Calibration:
    """An affine CSS-pixel -> screen-point transform, plus the state it holds in."""

    scale_x: float
    scale_y: float
    offset_x: float
    offset_y: float
    measured_in: dict[str, Any]

    def to_screen(self, client_x: float, client_y: float) -> tuple[float, float]:
        return (
            client_x * self.scale_x + self.offset_x,
            client_y * self.scale_y + self.offset_y,
        )

    def is_valid_for(self, viewport: dict[str, Any]) -> bool:
        """True if *viewport* is in the same layout state this was measured in."""
        return all(
            _close(viewport.get(k), self.measured_in.get(k)) for k in _TRANSFORM_RELEVANT
        )

    def why_invalid(self, viewport: dict[str, Any]) -> list[str]:
        """Human-readable reasons the calibration no longer applies."""
        return [
            f"{k}: measured {self.measured_in.get(k)!r} -> now {viewport.get(k)!r}"
            for k in _TRANSFORM_RELEVANT
            if not _close(viewport.get(k), self.measured_in.get(k))
        ]

    def describe(self) -> str:
        return (
            f"scale=({self.scale_x:.4g},{self.scale_y:.4g}) "
            f"offset=({self.offset_x:.4g},{self.offset_y:.4g}) "
            f"[top chrome {self.offset_y:.0f}pt]"
        )


def _close(a: Any, b: Any, tol: float = 0.75) -> bool:
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) <= tol
    return a == b


def tap_and_capture(
    evaluate_json: Callable[[str], Any],
    tap: Callable[[float, float], None],
    point: tuple[float, float],
    timeout: float = 4.0,
    probe: Probe = SR_PROBE,
) -> dict:
    """Tap a screen point and return *this* tap's positioning event.

    ⚠ **The trap this exists for.** iOS Safari emits a tap as a *sequence* —
    ``pointerdown``, ``touchstart``, then ``click`` roughly 300 ms later. Reading the event
    list once after ``axe tap`` returns therefore races the sequence, and worse: the late
    ``click`` from tap *N* arrives after the reset for tap *N+1* and gets attributed to it.
    That misattribution is silent and produces a plausible-looking coordinate, so it shows
    up as an absurd derived scale far from the cause rather than as an obvious error.

    Two defences: drain any stragglers with a settle pause before arming, and wait for the
    terminal ``click`` of this tap before reading, which guarantees the sequence is complete
    and nothing can leak into the next capture.
    """
    evaluate_json(probe.reset())
    _time.sleep(SETTLE_SECONDS)  # let stragglers from a previous tap land...
    evaluate_json(probe.reset())  # ...then discard them
    tap(*point)

    deadline = _time.monotonic() + timeout
    events: list[dict] = []
    while _time.monotonic() < deadline:
        events = evaluate_json(probe.events()) or []
        if any(e.get("type") == "click" for e in events):
            break
        _time.sleep(0.1)

    positioning = next(
        (
            e
            for e in events
            if e.get("isTrusted")
            and e.get("clientX") is not None
            and e.get("type") in ("pointerdown", "touchstart")
        ),
        None,
    )
    if positioning is None:
        raise CalibrationError(
            f"no trusted pointerdown/touchstart with coordinates for screen tap {point} "
            f"within {timeout}s. Recorded: {events!r}. Either the tap missed the web content "
            f"area, or the HID channel is not delivering trusted events."
        )
    return positioning


def calibrate(
    *,
    evaluate_json: Callable[[str], Any],
    tap: Callable[[float, float], None],
    screen_width: float,
    screen_height: float,
    probe: Probe = SR_PROBE,
) -> Calibration:
    """Measure the transform for the page's *current* layout state.

    Dependencies are injected as callables so this is testable without a Simulator, and so
    it is not welded to either channel's transport.

    Probe points are chosen **adaptively**, scaled to the currently visible region rather
    than to the whole screen. A fixed "40% and 60% of screen height" works on a plain page
    and breaks with the keyboard up: the visible band halves (``vvHeight`` 714 -> 377), so
    the 60% probe lands on the keyboard, captures nothing, and the calibration fails for a
    reason that looks like a broken HID channel. Several candidates are tried and the pair
    with the widest separation wins, since separation is what makes the derived scale robust
    against the sub-pixel rounding in reported CSS coordinates.
    """
    evaluate_json(probe.calib(True))
    evaluate_json(probe.reset())
    before = evaluate_json(probe.viewport())

    # Anchor the probe band to the visible height, with a conservative allowance for top
    # chrome. We cannot know the chrome height before calibrating — that is the unknown —
    # but it is reliably a modest band at the top, so offsetting by it and then working
    # within vvHeight keeps every candidate inside the content area.
    vis = visible_height(before)
    top_allowance = 70.0
    candidates = [
        (screen_width * 0.35, top_allowance + vis * 0.25),
        (screen_width * 0.65, top_allowance + vis * 0.45),
        (screen_width * 0.30, top_allowance + vis * 0.15),
        (screen_width * 0.70, top_allowance + vis * 0.55),
    ]

    samples: list[tuple[tuple[float, float], dict]] = []
    problems: list[str] = []
    for point in candidates:
        if not (0 < point[0] < screen_width and 0 < point[1] < screen_height):
            continue
        try:
            samples.append((point, tap_and_capture(evaluate_json, tap, point, probe=probe)))
        except CalibrationError as exc:
            problems.append(f"{point}: {exc}")
        if len(samples) >= 3:
            break
    if len(samples) < 2:
        raise CalibrationError(
            "fewer than two probe taps produced a trusted event, so no transform can be "
            "derived. Attempts:\n  " + "\n  ".join(problems or ["(none recorded)"])
        )

    # Widest separation in both axes gives the most numerically stable solve.
    best: tuple[float, Any, Any] | None = None
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            a, b = samples[i], samples[j]
            sep = min(
                abs(b[1]["clientX"] - a[1]["clientX"]),
                abs(b[1]["clientY"] - a[1]["clientY"]),
            )
            if best is None or sep > best[0]:
                best = (sep, a, b)
    assert best is not None
    _, (s1, e1), (s2, e2) = best
    dcx = e2["clientX"] - e1["clientX"]
    dcy = e2["clientY"] - e1["clientY"]
    if abs(dcx) < 1e-6 or abs(dcy) < 1e-6:
        raise CalibrationError(
            "the two probe taps reported the same CSS coordinate "
            f"({e1['clientX']},{e1['clientY']}) and ({e2['clientX']},{e2['clientY']}), so "
            "scale cannot be derived. The page may have scrolled between taps."
        )
    scale_x = (s2[0] - s1[0]) / dcx
    scale_y = (s2[1] - s1[1]) / dcy
    # A plausibility band, because the failure mode this catches is the nasty one: a
    # slightly-wrong scale still produces taps that land *somewhere*, so it surfaces as
    # flaky "the button moved" behaviour far from the cause. Refusing an implausible scale
    # turns that into an immediate, legible failure.
    for axis, value in (("x", scale_x), ("y", scale_y)):
        if not 0.2 <= abs(value) <= 5.0:
            raise CalibrationError(
                f"derived scale_{axis}={value:.4g} is implausible (expected ~1 for a "
                f"non-zoomed page). Probe taps: screen {s1} -> client "
                f"({e1['clientX']},{e1['clientY']}), screen {s2} -> client "
                f"({e2['clientX']},{e2['clientY']}). The page probably moved between taps, "
                f"or the reported screen size is wrong."
            )
    calib = Calibration(
        scale_x=scale_x,
        scale_y=scale_y,
        offset_x=s1[0] - e1["clientX"] * scale_x,
        offset_y=s1[1] - e1["clientY"] * scale_y,
        measured_in=before,
    )

    after = evaluate_json(probe.viewport())
    if not calib.is_valid_for(after):
        raise CalibrationError(
            "the layout changed during calibration, so the result describes neither state: "
            + "; ".join(calib.why_invalid(after))
        )
    evaluate_json(probe.calib(False))
    return calib


def tap_element(
    *,
    evaluate_json: Callable[[str], Any],
    tap: Callable[[float, float], None],
    calib: Calibration,
    element_id: str,
    probe: Probe = B0A_PROBE,
) -> dict:
    """Tap the centre of *element_id* and return the trusted event that resulted.

    The returned event is the evidence, and the caller is expected to assert on its
    ``targetId``. "A trusted event fired somewhere" is a much weaker claim than "the tap hit
    the element we aimed at", and only the second one means the substrate works — a
    calibration off by the height of the URL bar produces the first happily.
    """
    viewport = evaluate_json(probe.viewport())
    if not calib.is_valid_for(viewport):
        raise CalibrationError(
            "calibration is stale for the current layout — recalibrate: "
            + "; ".join(calib.why_invalid(viewport))
        )
    rect = evaluate_json(probe.rect(element_id))
    if rect is None:
        raise CalibrationError(f"no element with id {element_id!r}")
    vis = visible_height(viewport)
    if rect["cy"] < 0 or rect["cy"] > vis:
        occluded = (
            " (the software keyboard is covering it — visualViewport.height is "
            f"{viewport.get('vvHeight')} while innerHeight is still "
            f"{viewport.get('innerHeight')})"
            if vis < float(viewport.get("innerHeight") or 0)
            else ""
        )
        raise CalibrationError(
            f"element {element_id!r} centre is at client y={rect['cy']:.0f}, outside the "
            f"visible region (0..{vis:.0f}){occluded}. Scroll it into view first — tapping "
            f"its computed screen point would hit Safari's chrome or the keyboard."
        )
    sx, sy = calib.to_screen(rect["cx"], rect["cy"])
    hit = tap_and_capture(evaluate_json, tap, (sx, sy), probe=probe)
    hit["_aimed_at"] = {"element_id": element_id, "screen": [sx, sy], "rect": rect}
    return hit
