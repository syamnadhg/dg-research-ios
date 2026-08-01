"""The injected runtime has to SURVIVE, not merely land.

⚠ This whole file exists because of one measurement on real ChatGPT, and it is invisible against a
static page. One second after the first paint, ``document.readyState`` goes ``complete`` ->
``interactive`` **on the same URL**: the site replaces its own document. Anything injected before
that moment goes away with the old document.

The failure mode is what makes it worth pinning. It did not surface as "the runtime is missing" —
it surfaced as ``TypeError: undefined is not an object (evaluating 'window.__sr.events')`` raised
from a worker thread inside ``geometry.calibrate``, with a traceback pointing at geometry. And the
obvious fix does not work: re-injecting and immediately checking finds the sentinel present, because
the doomed document is still the current one. Only duration distinguishes the two.

Calibration is the one caller where a wipe is unrecoverable rather than retryable: it delivers a real
HID tap and then reads back the event that tap produced, so a wipe between those two steps destroys
the measurement instead of failing it cleanly.
"""

from __future__ import annotations

import asyncio

import pytest

from emubackend.substrate import runtime_js
from emubackend.substrate.backend import IOSSimulatorBackend, Tab


class _ScriptedBackend(IOSSimulatorBackend):
    """A backend whose page answers a scripted sequence of "is the runtime there?" reads.

    Subclassed rather than mocked at the socket, so the method under test runs unmodified — the thing
    being asserted is its re-injection and settle logic, not its plumbing.
    """

    def __init__(self, answers):
        super().__init__(udid="scripted")
        self._answers = list(answers)
        self.reads = 0
        self.injections = 0

    async def evaluate(self, tab, js):
        if f"typeof window.{runtime_js.NS}" in js:
            self.reads += 1
            # The last answer repeats, so a test states only the interesting prefix.
            idx = min(self.reads - 1, len(self._answers) - 1)
            return self._answers[idx]
        raise AssertionError(f"unexpected evaluate: {js!r}")

    async def _attach(self, tab):
        self.injections += 1
        return None


def _run(answers, **kwargs):
    backend = _ScriptedBackend(answers)
    tab = Tab(url="https://chatgpt.com/", ws_url="ws://x")
    ok = asyncio.run(backend.ensure_runtime_stable(tab, **kwargs))
    return ok, backend, tab


def test_a_runtime_present_for_the_whole_settle_window_is_stable():
    ok, backend, _tab = _run([True], settle=0.4, timeout=5.0)
    assert ok is True
    assert backend.injections == 0, "nothing was wiped, so nothing needed re-injecting"


def test_a_runtime_that_lands_and_is_then_wiped_is_not_stable():
    """The exact ChatGPT shape: present, then gone, then present again.

    A check that accepted the first ``True`` would return stable at the very moment the document was
    about to be replaced — which is what happened, and it failed one step later inside calibration.
    """
    # Present for two reads, wiped for two, then permanently present. The settle window is deliberately
    # LONGER than that first run of Trues, so it can only ever be satisfied after the wipes.
    #
    # ⚠ The margin matters and bin/mutate.py proved it: with settle=0.4 at a 0.25s poll, an
    # accept-on-first-presence mutation still needed 5 reads and squeaked past a `reads > 4` assertion.
    # A test that a broken implementation can satisfy by one read is not a test.
    ok, backend, _tab = _run([True, True, False, False, True], settle=1.0, timeout=10.0)
    assert ok is True
    assert backend.injections >= 1, "the wipe must have triggered a re-injection"
    assert backend.reads >= 7, (
        f"stable after {backend.reads} reads — too few. The window must be satisfied by the run of "
        f"Trues AFTER the wipe (read 5 onward, so ~4 more reads at a 0.25s poll), not by the two "
        f"before it. An accept-on-first-presence check returns at read 2."
    )


def test_a_page_that_never_stops_wiping_is_reported_rather_than_waited_on_forever():
    ok, backend, _tab = _run([False], settle=0.4, timeout=1.2)
    assert ok is False
    assert backend.injections >= 2, "every disappearance gets a fresh injection attempt"


def test_a_wipe_invalidates_the_CALIBRATION_too():
    """A new document means a new layout. Keeping the old transform would put taps near their target
    rather than on it — the off-by-the-URL-bar error calibration exists to eliminate.
    """
    backend = _ScriptedBackend([False, True])
    tab = Tab(url="https://chatgpt.com/", ws_url="ws://x")
    tab.calibration = object()
    asyncio.run(backend.ensure_runtime_stable(tab, settle=0.3, timeout=5.0))
    assert tab.calibration is None


def test_the_settle_clock_RESTARTS_on_each_disappearance():
    """Otherwise a page that flickers accumulates unrelated moments of presence into a false stable."""
    # Alternating True/False can never accumulate 0.5s of continuous presence at a 0.25s poll, so a
    # correct implementation times out. One that summed its Trues would report stable.
    ok, _backend, _tab = _run([True, False, True, False, True, False], settle=0.5, timeout=1.5)
    assert ok is False


def test_an_inspector_error_counts_as_absent_not_as_a_crash():
    """A navigation can drop the socket as well as the runtime, and that is normal pipeline behaviour."""
    from emubackend.substrate import iwdp

    class _Flaky(_ScriptedBackend):
        async def evaluate(self, tab, js):
            self.reads += 1
            if self.reads <= 2:
                raise iwdp.InspectorError("socket went away with the document")
            return True

    backend = _Flaky([True])
    tab = Tab(url="https://chatgpt.com/", ws_url="ws://x")
    assert asyncio.run(backend.ensure_runtime_stable(tab, settle=0.3, timeout=5.0)) is True
    assert backend.injections >= 1


def test_calibration_refuses_to_measure_against_an_unstable_runtime():
    """And says WHY, naming the document replacement rather than the missing property.

    The original failure named ``window.__sr.events`` from inside geometry, which sent me looking at
    the probe. The cause was a page that had thrown away the document holding it.
    """
    from emubackend.substrate import geometry

    class _NeverStable(_ScriptedBackend):
        async def ensure_runtime_stable(self, tab, settle=2.0, timeout=60.0):
            return False

    backend = _NeverStable([False])
    backend._screen = object()
    tab = Tab(url="https://chatgpt.com/", ws_url="ws://x")
    with pytest.raises(geometry.CalibrationError) as exc:
        asyncio.run(backend._calibration(tab))
    assert "replacing its own document" in str(exc.value)
    assert runtime_js.NS in str(exc.value)
