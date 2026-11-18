"""Gate zero must measure the surface it was asked for, and refuse when it cannot.

Both of this device's ChatGPT pages are literally ``https://chatgpt.com/`` and only the app's is
signed in, so a URL-substring page pick is a coin flip with a login wall on one face. The gate then
reports "no report node" for the most boring possible reason and sends the reader hunting for
cross-origin frames — the one branch §3.3 says costs architecture.

These assert the **mechanism** (which page object came back, and that a miss raises rather than
falls through), not merely that a page came back.
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]


def _load():
    """Import ``bin/gate_zero_probe.py``, which is a script rather than a package module."""
    spec = importlib.util.spec_from_file_location(
        "gate_zero_probe", REPO / "bin" / "gate_zero_probe.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["gate_zero_probe"] = module
    spec.loader.exec_module(module)
    return module


gz = _load()

#: The probe under test, taken from the module so the test cannot drift from what ships.
PROBE_4 = gz.PROBE_4_LONGEST

APP_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Version/17.0 Mobile/15E148"
SAFARI_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) Version/26.5 Mobile/15E148"


def test_app_surface_picks_the_app_page_not_the_safari_one_next_to_it():
    """The discriminator is the UA, and order must not decide it."""
    safari, app = object(), object()
    assert gz.pick_by_ua([(safari, SAFARI_UA), (app, APP_UA)], "app") is app
    # ...and the same set in the other order, because "it happened to be first" is not a rule.
    assert gz.pick_by_ua([(app, APP_UA), (safari, SAFARI_UA)], "app") is app


def test_safari_surface_picks_the_safari_page():
    safari, app = object(), object()
    assert gz.pick_by_ua([(app, APP_UA), (safari, SAFARI_UA)], "safari") is safari


def test_app_surface_REFUSES_when_only_safari_pages_are_present():
    """The load-bearing assertion: no fallback.

    Returning the only page found is precisely how the signed-out surface got measured once
    already. A guard that fails open is worse than no guard.
    """
    safari = object()
    with pytest.raises(gz.SurfaceNotFound):
        gz.pick_by_ua([(safari, SAFARI_UA)], "app")


def test_safari_surface_refuses_when_only_the_app_page_is_present():
    with pytest.raises(gz.SurfaceNotFound):
        gz.pick_by_ua([(object(), APP_UA)], "safari")


def test_no_pages_at_all_refuses_rather_than_returning_none():
    with pytest.raises(gz.SurfaceNotFound):
        gz.pick_by_ua([], "app")


def test_a_missing_user_agent_is_not_treated_as_the_app():
    """An unreadable UA must not be promoted to a match.

    ``Inspector`` failures already skip a page, but a page whose UA evaluates to empty reaches
    here — and ``"" in ua`` style leniency would make every such page an app page.
    """
    with pytest.raises(gz.SurfaceNotFound):
        gz.pick_by_ua([(object(), "")], "app")
    # It IS a valid Safari answer, though: "not the app" is exactly what safari means.
    page = object()
    assert gz.pick_by_ua([(page, "")], "safari") is page


def test_an_unknown_surface_name_is_rejected_rather_than_silently_meaning_safari():
    """`surface not in ("app",)` would quietly turn a typo into "measure Safari"."""
    with pytest.raises(ValueError):
        gz.pick_by_ua([(object(), APP_UA)], "App")


class TestCompletionVerdict:
    """The gate must refuse a page it cannot establish as finished.

    Every case here is one the original single-question check ("is the stop control gone?") got
    wrong, because on a Deep Research run that control is absent from before the run starts.
    """

    def test_a_visible_stop_control_is_in_flight(self):
        state, _ = gz.completion_verdict(
            {"stopControlPresent": True, "stopLabel": "Stop answering", "longestRenderedChars": 9}
        )
        assert state == "in_flight"

    def test_a_rendered_node_over_the_floor_is_complete(self):
        state, reason = gz.completion_verdict(
            {"stopControlPresent": False, "longestRenderedChars": gz.REPORT_FLOOR_CHARS}
        )
        assert state == "complete"
        assert str(gz.REPORT_FLOOR_CHARS) in reason

    def test_one_char_under_the_floor_is_NOT_complete(self):
        """The floor is the BE's own tier floor; a boundary that slips makes it advisory."""
        state, _ = gz.completion_verdict(
            {"stopControlPresent": False, "longestRenderedChars": gz.REPORT_FLOOR_CHARS - 1}
        )
        assert state != "complete"

    def test_a_deep_research_frame_with_a_thin_main_document_REFUSES(self):
        """The measured live case: no stop control, 881 rendered chars, DR sandbox frame on screen.

        The old check called this finished and would have probed a page mid-research.
        """
        state, reason = gz.completion_verdict({
            "stopControlPresent": False,
            "longestRenderedChars": 881,
            "visibleFrames": [
                {"src": "https://connector-openai-deep-research.web-sandbox.oaiusercontent.com/",
                 "w": 402, "h": 511}
            ],
        })
        assert state == "unknown"
        assert "cross-origin" in reason

    def test_a_bare_page_with_nothing_on_it_REFUSES_rather_than_passing(self):
        """A page that never started looks exactly like a finished one to an absence check."""
        state, _ = gz.completion_verdict(
            {"stopControlPresent": False, "longestRenderedChars": 0, "visibleFrames": []}
        )
        assert state == "unknown"

    def test_an_unrelated_visible_frame_does_not_read_as_the_research_frame(self):
        """ChatGPT ships a sentinel iframe on every page; it must not change the verdict."""
        state, reason = gz.completion_verdict({
            "stopControlPresent": False,
            "longestRenderedChars": 12,
            "visibleFrames": [{"src": "https://chatgpt.com/backend-api/sentinel/frame.html",
                               "w": 1, "h": 1}],
        })
        assert state == "unknown"
        assert "cross-origin" not in reason


def _node() -> str:
    """Locate node, searching beyond `PATH`.

    ⚠ **This used to be `shutil.which("node")` with a `pytest.skip` fallback, and the skip made the
    guard decorative.** `bin/mutate.py` runs its subprocesses under a pinned
    `PATH=/opt/homebrew/bin:/usr/bin:/bin`, which does not contain this machine's node — so the
    probe tests skipped, pytest exited 0, and the harness recorded the mutation as CAUGHT while no
    assertion had run. A test that opts out when its dependency is missing cannot fail, and a test
    that cannot fail protects nothing.
    """
    found = shutil.which("node") or next(
        (p for p in ("/opt/homebrew/bin/node", "/usr/local/bin/node",
                     str(Path.home() / ".local/bin/node"))
         if Path(p).exists()),
        None,
    )
    # Fails rather than skips. If node is genuinely unavailable that is a broken toolchain and the
    # suite should say so, not quietly stop checking the probe.
    assert found, "node not found — required to execute the probe JS these tests assert on"
    return found


def _run_probe(js: str, elements: list[dict]) -> dict:
    """EXECUTE the probe's JavaScript against a stub document and return what it produced.

    Asserting that the source contains ``SCRIPT: 1`` would be a presence assertion — it passes
    against an exclusion list that is never consulted, which is the exact failure mode this repo
    keeps hitting. Running the probe asserts the behaviour instead: given a document whose largest
    node is a script, does it still pick the rendered one?
    """
    node = _node()
    # The document goes in on stdin, not argv: one of these fixtures is a 434k-char script body,
    # which is the shape that matters and is also enough to blow an argv limit.
    harness = """
const els = JSON.parse(require('fs').readFileSync(0, 'utf8')).map(e => ({
  tagName: e.tag, innerText: e.text, id: e.id || '', className: e.cls || '',
  attributes: (e.attrs || []).map(n => ({ name: n })),
}));
const document = { querySelectorAll: () => els };
const out = (%s);
console.log(JSON.stringify(out));
""" % js
    proc = subprocess.run(
        [node, "-e", harness], input=json.dumps(elements),
        capture_output=True, text=True, check=True,
    )
    return json.loads(proc.stdout)


def test_probe_4_ignores_a_script_and_picks_the_rendered_node():
    """The measured live shape: 434,403 chars of `<script>` innerText against 881 rendered.

    Unexcluded, the verdict reads 434k against a 2000-char floor and announces H2 — "in the main
    document, re-point the selector, no frame work" — for a page whose report is in a cross-origin
    frame. That is the single most expensive wrong turn the gate can take.
    """
    best = _run_probe(PROBE_4, [
        {"tag": "SCRIPT", "text": "x" * 434_403},
        {"tag": "DIV", "text": "y" * 881, "cls": "contents"},
    ])
    assert best["tag"] == "DIV"
    assert best["chars"] == 881


@pytest.mark.parametrize("tag", ["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"])
def test_probe_4_ignores_every_non_rendered_tag_it_claims_to(tag):
    """Each name in the list is asserted separately: a list is not evidence each entry is read."""
    best = _run_probe(PROBE_4, [
        {"tag": tag, "text": "x" * 50_000},
        {"tag": "P", "text": "y" * 10},
    ])
    assert best["tag"] == "P"


def test_probe_4_still_finds_a_genuinely_large_rendered_node():
    """The exclusion must not turn the probe into one that reports nothing."""
    best = _run_probe(PROBE_4, [
        {"tag": "SCRIPT", "text": "x" * 99_999},
        {"tag": "ARTICLE", "text": "z" * 8_000},
        {"tag": "DIV", "text": "y" * 12},
    ])
    assert best["tag"] == "ARTICLE"
    assert best["chars"] == 8_000


class TestVerdictRanking:
    """The verdict must rank frames by evidence, not by branch order.

    Measured on the real completed page: ChatGPT ships a **0×0 same-origin** `sentinel` frame with
    **0 chars** alongside the 402×484 cross-origin frame the report was actually in. Ranking
    same-origin first made the empty one win, and the gate announced *"H3 — traverse
    contentDocument, JS-only, no new transport"* for a report that no `contentDocument` traversal
    can reach.
    """

    SENTINEL = {"src": "https://chatgpt.com/backend-api/sentinel/frame.html",
                "w": 0, "h": 0, "access": "SAME-ORIGIN: 0 chars"}
    DR_FRAME = {"src": "https://connector-openai-deep-research.web-sandbox.oaiusercontent.com/",
                "w": 402, "h": 484, "access": "null contentDocument"}

    def _verdict(self, iframes):
        return "\n".join(gz._verdict(
            [{"chars": 395}], iframes, {"count": 0}, {"chars": 859, "tag": "DIV"}
        ))

    def test_an_empty_same_origin_frame_does_not_outrank_the_cross_origin_one(self):
        out = self._verdict([self.SENTINEL, self.DR_FRAME])
        assert "H4" in out
        assert "H3" not in out

    def test_the_order_the_frames_are_listed_in_does_not_change_the_verdict(self):
        assert self._verdict([self.SENTINEL, self.DR_FRAME]) \
            == self._verdict([self.DR_FRAME, self.SENTINEL])

    def test_a_substantial_same_origin_frame_still_reports_H3(self):
        """The exclusion must not make H3 unreachable — that would be a guard that cannot fire."""
        big = {"src": "https://chatgpt.com/inner", "w": 400, "h": 400,
               "access": "SAME-ORIGIN: 50000 chars"}
        out = self._verdict([self.SENTINEL, big])
        assert "H3" in out

    def test_a_tiny_cross_origin_tracker_is_not_reported_as_the_report_container(self):
        """The SIZE check, isolated. With no other frame present it is the only thing deciding."""
        tracker = {"src": "https://ads.example/px", "w": 1, "h": 1,
                   "access": "null contentDocument"}
        out = self._verdict([tracker])
        assert "H4" not in out

    def test_a_LARGE_but_EMPTY_same_origin_frame_is_not_a_report_container(self):
        """The EMPTINESS check, isolated.

        ⚠ A separate test because a mutation proved the point: with the cross-origin branch tested
        first, relaxing `_substantial` changes nothing about a page that HAS a cross-origin frame —
        so the ranking test passed while the emptiness rule was gone. A frame big enough to hold a
        report but holding nothing is a shell, and reporting H3 for it sends the reader to traverse
        a `contentDocument` with no report in it.
        """
        empty_but_big = {"src": "https://chatgpt.com/shell", "w": 400, "h": 400,
                         "access": "SAME-ORIGIN: 0 chars"}
        out = self._verdict([empty_but_big])
        assert "H3" not in out


def test_the_ua_token_is_the_one_the_other_tools_pin():
    """Three files carry this token. A drift between them reintroduces the wrong-surface bug."""
    capture = (REPO / "bin" / "capture_selectors.py").read_text()
    drive = (REPO / "bin" / "drive_selectors.py").read_text()
    assert f'APP_UA_TOKEN = "{gz.APP_UA_TOKEN}"' in capture
    assert f'APP_UA_TOKEN = "{gz.APP_UA_TOKEN}"' in drive
