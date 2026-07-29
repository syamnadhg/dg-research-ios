"""`enable_deep_research` must be idempotent, because toggle state outlives the session.

This is a regression suite for a bug that a single run against fresh state cannot see. The e2e gate had
passed repeatedly while the defect was live: the first run of the day starts with the toggle off, taps
it on, and everything is correct. The *second* run starts with it on — as every real device does, since
persistent login is the point — taps it off, and completes a full P0–P3 with deep research disabled
while reporting success.

So the tests below are written from both starting states. A test that only covers "off, then enable" is
precisely the test that shipped the bug.
"""

from __future__ import annotations

import asyncio

from emubackend import harvest, intents, phases
from emubackend.selectors import SelectorEntry, SelectorManifest


class FakeHandle:
    """A toggle that reports and flips its own `aria-pressed`, like the real control."""

    def __init__(self, pressed: bool):
        self.pressed = pressed
        self.clicks = 0

    async def get_attribute(self, name: str) -> str | None:
        if name == "aria-pressed":
            return "true" if self.pressed else "false"
        return None

    async def click(self) -> None:
        self.clicks += 1
        self.pressed = not self.pressed   # a real toggle toggles; it does not "enable"


class FakePage:
    def __init__(self, handle: FakeHandle):
        self.handle = handle

    async def query_selector(self, css: str):
        return self.handle

    async def query_selector_all(self, css: str):
        return [self.handle]

    async def evaluate(self, script: str, *args):
        return None


def _driver(pressed: bool) -> tuple[phases.PlatformDriver, FakeHandle]:
    handle = FakeHandle(pressed)
    manifest = SelectorManifest(
        platforms={
            "chatgpt": {
                key: SelectorEntry(css=(css,), provenance="test")
                for key, css in {
                    "logged_in_marker": "#marker",
                    "composer": "#composer",
                    "send": "#send",
                    "deep_research_toggle": "#toggle",
                    "sources": "#src",
                    "response_container": "#resp",
                }.items()
            }
        },
        source="test fixture",
    )
    driver = phases.PlatformDriver(
        "chatgpt",
        phases.PhaseDeps(
            manifest=manifest,
            registry=intents.IntentRegistry(),
            history=harvest.HarvestHistory(),
            pages={"chatgpt": FakePage(handle)},
            topic="anything",
        ),
    )
    return driver, handle


def test_an_already_enabled_toggle_is_left_alone():
    async def body():
        """The bug. One unconditional tap here disables deep research for the whole run."""
        driver, handle = _driver(pressed=True)
        outcome = await driver.enable_deep_research()

        assert handle.clicks == 0, "tapping an already-on toggle turns deep research OFF"
        assert handle.pressed is True, "deep research must still be enabled afterwards"
        assert outcome is not None and outcome.predicate_passed

    asyncio.run(body())


def test_a_disabled_toggle_is_enabled():
    async def body():
        """The other half — the case that was always covered, kept so the fix cannot overshoot."""
        driver, handle = _driver(pressed=False)
        outcome = await driver.enable_deep_research()

        assert handle.clicks == 1
        assert handle.pressed is True
        assert outcome is not None and outcome.predicate_passed

    asyncio.run(body())


def test_calling_it_repeatedly_converges_rather_than_oscillating():
    async def body():
        """Three calls in a row must leave it on, not flip-flop.

        The property that actually matters operationally: a resumed run may re-enter the phase, and an
        oscillating step means the outcome depends on how many times it happened to run.
        """
        driver, handle = _driver(pressed=False)
        for _ in range(3):
            await driver.enable_deep_research()

        assert handle.pressed is True
        assert handle.clicks == 1, "only the first call should have needed to act"

    asyncio.run(body())


def test_the_no_op_is_not_counted_as_an_execution():
    async def body():
        """The bake ledger counts real executions, and a skipped tap is not one.

        Inflating it would let an intent reach its bake threshold without ever having acted — and the bake
        threshold is what gates live escalation.
        """
        driver, _ = _driver(pressed=True)
        await driver.enable_deep_research()

        intent = driver.deps.registry.get("chatgpt.deep_research_toggle")
        assert getattr(intent, "executions", 0) == 0

    asyncio.run(body())


def test_a_platform_without_a_toggle_reports_nothing_to_do():
    async def body():
        """NotebookLM has no research toggle. Absence must be `None`, not a manufactured failure."""
        driver, _ = _driver(pressed=False)
        driver.deps.manifest.platforms["chatgpt"].pop("deep_research_toggle", None)
        assert await driver.enable_deep_research() is None

    asyncio.run(body())
