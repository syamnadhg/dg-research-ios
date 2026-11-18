"""P2 runs three platforms SEQUENTIALLY and merges their reports.

Decision B1: MobileSafari has one foreground tab and HID taps reach only it, so dispatching three
runs and collecting later leaves two generating on pages nothing is watching — and on a platform
whose report is only reachable from the page holding the conversation. The cost is accepted and
real: wall-clock is the SUM of three deep-research runs, not the slowest of the three.
"""
from __future__ import annotations

import asyncio
import json

import pytest

from emubackend import phases, prompts
from emubackend.selectors import ManifestError

from emubackend.tests.test_selectors_and_phases import (
    FAKE_BRIEF, FAKE_REPORT, FakeHandle, FakePage, MANIFEST, _deps,
)
from emubackend import harvest, intents, selectors


def _deps_two_platforms(tmp_path):
    """Deps whose manifest covers chatgpt AND gemini.

    The shared fixture is single-platform, and three-platform sequencing cannot be tested against a
    one-platform manifest — the loop would have nothing to sequence and the test would pass by
    describing a list of length one.
    """
    manifest_data = {"version": 1, "platforms": dict(MANIFEST["platforms"])}
    manifest_data["platforms"]["gemini"] = dict(MANIFEST["platforms"]["chatgpt"])
    path = tmp_path / "m2.json"
    path.write_text(json.dumps(manifest_data))
    manifest = selectors.load_manifest(path)

    page = FakePage(
        dom={"#prompt-textarea": [], ".src": []}, toggles={"#dr": "false"}
    )
    page.dom["#prompt-textarea"] = [FakeHandle(page, "#prompt-textarea")]
    page.dom["#send"] = [FakeHandle(page, "#send")]
    page.dom[".src"] = [FakeHandle(page, ".src", f"source {i}") for i in range(3)]
    page.report_text = FAKE_REPORT
    # Gemini takes the DOM path (its container is unmeasured, so it keeps the response-container
    # read), and that read must find a REPORT-length answer. Pre-seeded so the send hook's
    # `setdefault` leaves it alone — otherwise the DOM path returns a brief-length string and the
    # 2000-char report floor correctly rejects it, which would make this fixture test the floor
    # rather than the sequencing.
    page.dom["#resp"] = [
        FakeHandle(page, "#resp", FAKE_REPORT, attrs={"data-state": "complete"})
    ]

    deps = phases.PhaseDeps(
        manifest=manifest,
        registry=intents.IntentRegistry(),
        history=harvest.HarvestHistory(),
        pages={"chatgpt": page, "gemini": page},
        topic="quantum error correction",
    )
    return deps, page


class TestTheConsolidatedReport:

    def test_the_three_reports_are_merged_under_named_headings(self):
        out = prompts.consolidated_report(
            "batteries", {"chatgpt": "A body", "gemini": "B body", "claude": "C body"}
        )
        assert out.startswith("# Consolidated Research Report: batteries")
        for title in ("ChatGPT Research", "Gemini Research", "Claude Research"):
            assert f"## {title}" in out

    def test_the_ORDER_is_fixed_and_not_the_order_they_arrived_in(self):
        # A dict's insertion order records which platform happened to finish first. A run that
        # reproduces its inputs should reproduce its output.
        first = prompts.consolidated_report(
            "t", {"claude": "C", "chatgpt": "A", "gemini": "B"}
        )
        second = prompts.consolidated_report(
            "t", {"chatgpt": "A", "gemini": "B", "claude": "C"}
        )
        assert first == second
        assert first.index("ChatGPT") < first.index("Gemini") < first.index("Claude")

    def test_a_MISSING_platform_is_skipped_not_written_as_an_empty_section(self):
        # A heading with nothing under it reads as a platform that found nothing, rather than one
        # that failed and was already reported as failed.
        out = prompts.consolidated_report("t", {"chatgpt": "A", "gemini": "", "claude": "   "})
        assert "ChatGPT Research" in out
        assert "Gemini Research" not in out
        assert "Claude Research" not in out

    def test_no_reports_at_all_yields_NOTHING_rather_than_a_bare_heading(self):
        # A document containing only a title would be written, linked, and open empty.
        assert prompts.consolidated_report("t", {}) == ""
        assert prompts.consolidated_report("t", {"chatgpt": "  "}) == ""


class TestSequentialExecution:

    def _run_p2(self, tmp_path, platforms):
        deps, page = _deps_two_platforms(tmp_path)
        deps.brief = FAKE_BRIEF
        bodies = phases.build_phase_bodies(deps, platforms, response_timeout=1.0)
        asyncio.run(bodies[2](None))
        return deps, page

    def test_each_platform_is_CARRIED_TO_COMPLETION_before_the_next_is_started(self, tmp_path):
        # The mechanism, and the whole of B1: the log must show dispatch→report for one platform
        # before the next platform is dispatched. Three dispatches followed by three reports would
        # be the concurrent shape this deliberately does not use.
        deps, _ = self._run_p2(tmp_path, ("chatgpt", "gemini"))
        order = [e for e in deps.log if e.startswith("p2:") and (
            ":dispatched" in e or ":waited:" in e or ":report:" in e)]
        # ⚠ The WAIT is asserted, not just dispatch-then-report. Without it, a P2 that never waited
        # at all produces the same dispatch/report ordering whenever extraction happens to succeed
        # immediately — which is exactly what a fake does, and a mutation proved it.
        assert order[0].startswith("p2:chatgpt:dispatched")
        assert order[1].startswith("p2:chatgpt:waited:")
        assert order[2].startswith("p2:chatgpt:report:")
        assert order[3].startswith("p2:gemini:dispatched")
        assert order[4].startswith("p2:gemini:waited:")
        assert order[5].startswith("p2:gemini:report:")

    def test_the_reports_are_collected_per_platform(self, tmp_path):
        deps, _ = self._run_p2(tmp_path, ("chatgpt", "gemini"))
        assert set(deps.reports) == {"chatgpt", "gemini"}
        # Stored reports are rstripped as they are annotated, so compare against the same shape.
        assert deps.reports["chatgpt"] == FAKE_REPORT.rstrip()

    def test_the_consolidated_document_is_built_from_them(self, tmp_path):
        deps, _ = self._run_p2(tmp_path, ("chatgpt", "gemini"))
        assert deps.consolidated.startswith("# Consolidated Research Report:")
        assert "ChatGPT Research" in deps.consolidated
        assert any(e.startswith("p2:consolidated:") for e in deps.log)

    def test_ONE_platform_failing_does_not_throw_away_the_others(self, tmp_path):
        # Two good reports and one failure is a degraded run worth finishing — raising would discard
        # deep-research units already spent.
        deps, page = _deps_two_platforms(tmp_path)
        deps.brief = FAKE_BRIEF
        page.report_state = {"state": "error", "error": "session HTTP 401"}
        bodies = phases.build_phase_bodies(deps, ("chatgpt", "gemini"), response_timeout=1.0)

        asyncio.run(bodies[2](None))

        # ChatGPT took the fetch path and failed; Gemini took the DOM path and did not.
        assert "chatgpt" not in deps.reports
        assert "gemini" in deps.reports
        assert any("chatgpt" in e and ("rejected" in e or "fetch_failed" in e) for e in deps.log)

    def test_ALL_platforms_failing_RAISES_rather_than_handing_P3_nothing(self, tmp_path):
        deps, page = _deps(tmp_path, toggle="false")
        deps.brief = FAKE_BRIEF
        page.report_state = {"state": "error", "error": "session HTTP 401"}
        page.dom["#resp"] = []           # and the DOM path finds nothing either
        bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=1.0)

        with pytest.raises(ManifestError) as exc:
            asyncio.run(bodies[2](None))

        assert "no usable report" in str(exc.value)

    def test_a_SHORT_READ_is_not_accepted_as_the_report(self, tmp_path):
        # A truncated report is still markdown and still clears the floor — it would ship as
        # research with its conclusions missing.
        deps, page = _deps(tmp_path, toggle="false")
        deps.brief = FAKE_BRIEF
        page.report_text = FAKE_REPORT
        page.report_state = {"state": "ok", "chars": len(FAKE_REPORT) + 10_000}  # claims more
        bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=1.0)

        with pytest.raises(ManifestError):
            asyncio.run(bodies[2](None))

        assert any("short_read" in e for e in deps.log)

    def test_the_platform_ORDER_is_the_backends_and_not_the_callers(self, tmp_path):
        # Passed in reverse; must still run ChatGPT, Gemini, Claude.
        deps, _ = self._run_p2(tmp_path, ("gemini", "chatgpt"))
        dispatched = [e.split(":")[1] for e in deps.log if e.endswith(":dispatched")]
        assert dispatched == ["chatgpt", "gemini"]


# --------------------------------------------------------------------------------------------
# The plan-confirmation step, found by watching a LIVE Gemini deep-research run (2026-08-09).
#
# ⛔ Sending does NOT start Gemini's deep research. It replies with a ~1,200-character research
# PLAN and stops: generation ends, the text is stable, nothing is empty, and it reads like a good
# answer. So the wait completes, the extractor harvests the plan, and the run ships a document
# describing what it was GOING to research. The control that starts the real work was in the schema
# and had never been captured, and nothing had ever pressed it.


class _PlanPage:
    """A platform that answers with a plan and waits, exactly as measured.

    The plan control appears LATE, which is why the production code polls: a single look straight
    after send finds nothing and concludes the platform has no such step.
    """

    def __init__(self, appears_after=2):
        self.appears_after = appears_after
        self.looks = 0
        self.clicked = 0

    async def query_selector(self, css):
        if "Start research" not in css:
            return None
        self.looks += 1
        if self.looks <= self.appears_after:
            return None
        page = self

        class _H:
            async def click(self_inner):
                page.clicked += 1

            async def inner_text(self_inner):
                return "Start research"

        return _H()

    async def query_selector_all(self, css):
        return []


def _plan_driver(page, captured=True):
    from emubackend import harvest, intents, phases
    from emubackend.selectors import SelectorEntry, SelectorManifest

    entries = {
        key: SelectorEntry(css=("#x",), provenance="test")
        for key in ("logged_in_marker", "composer", "send", "sources", "response_container")
    }
    if captured:
        entries["start_research"] = SelectorEntry(
            css=('button[aria-label="Start research"]',), provenance="measured"
        )
    manifest = SelectorManifest(platforms={"gemini": entries}, source="test")
    return phases.PlatformDriver(
        "gemini",
        phases.PhaseDeps(
            manifest=manifest,
            registry=intents.IntentRegistry(),
            history=harvest.HarvestHistory(),
            pages={"gemini": page},
            topic="t",
        ),
    )


class TestThePlanIsConfirmedBeforeTheReportIsRead:

    def test_the_plan_control_is_PRESSED_and_not_merely_found(self):
        import asyncio

        page = _PlanPage()
        pressed = asyncio.run(_plan_driver(page).start_research_if_offered(timeout=5, poll=0.01))

        assert pressed is True
        # ⚠ The mechanism: the CLICK happened. "the selector resolved" is the assertion that would
        # pass against a step that found the button and walked past it — which is the bug.
        assert page.clicked == 1

    def test_it_is_POLLED_because_the_plan_arrives_late(self):
        import asyncio

        # The control is absent on the first two looks, exactly as it is for the tens of seconds the
        # plan takes to render. A read-once implementation returns False here and the run harvests
        # the plan.
        page = _PlanPage(appears_after=2)
        assert asyncio.run(_plan_driver(page).start_research_if_offered(timeout=5, poll=0.01))
        assert page.looks >= 3, "a single look would have missed a plan that had not rendered yet"

    def test_a_platform_with_NO_plan_stage_is_not_a_failure(self):
        import asyncio

        # ChatGPT and Claude start on send. An uncaptured entry must mean "no such step here",
        # never "this run is broken".
        page = _PlanPage()
        assert asyncio.run(
            _plan_driver(page, captured=False).start_research_if_offered(timeout=5, poll=0.01)
        ) is False
        assert page.clicked == 0

    def test_a_control_that_NEVER_appears_gives_up_rather_than_hanging(self):
        import asyncio

        page = _PlanPage(appears_after=10_000)
        assert asyncio.run(_plan_driver(page).start_research_if_offered(timeout=0.05, poll=0.01)) is False

    def test_the_navigation_the_press_causes_is_not_treated_as_a_failure(self):
        """Pressing it navigates and the inspector connection drops. That is the SUCCESS path."""
        import asyncio

        class _NavigatingPage(_PlanPage):
            async def query_selector(self, css):
                handle = await super().query_selector(css)
                if handle is None:
                    return None
                page = self

                class _H:
                    async def click(self_inner):
                        page.clicked += 1
                        raise RuntimeError("inspector connection lost")

                return _H()

        page = _NavigatingPage()
        assert asyncio.run(_plan_driver(page).start_research_if_offered(timeout=5, poll=0.01))
        assert page.clicked == 1
