"""P2 refuses to run without P1's brief.

A fallback to the topic here would be invisible: three deep-research units get spent, three reports
come back, every guard passes, and the run reports success — having answered the wrong question.
"""
from __future__ import annotations

import asyncio

import pytest

from emubackend import phases
from emubackend.selectors import ManifestError

from emubackend.tests.test_selectors_and_phases import FAKE_BRIEF, _deps


def test_p2_refuses_to_run_without_a_brief(tmp_path):
    deps, _page = _deps(tmp_path, toggle="false")
    assert deps.brief == "", "the fixture must start with no brief for this to mean anything"
    bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=1.0)

    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[2](None))

    assert "no brief" in str(exc.value)
    # And it must say WHY, because the cost of the alternative is what justifies the refusal.
    assert "deep-research units" in str(exc.value)


def test_p2_runs_once_the_brief_is_present(tmp_path):
    # The other half: a guard that refuses everything is not a guard.
    deps, page = _deps(tmp_path, toggle="false")
    deps.brief = FAKE_BRIEF
    bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=1.0)

    asyncio.run(bodies[2](None))

    assert page.typed == [FAKE_BRIEF]
    assert "p2:chatgpt:dispatched" in deps.log


def test_p1_REFUSES_a_stub_response_as_the_brief(tmp_path):
    """The floor, isolated.

    ⚠ A mutation proved this was needed: with the fake answering at full brief length, deleting the
    floor changed nothing and the whole-pipeline test still passed. The floor is only load-bearing
    against a SHORT response — which is exactly the shape measured on the live page, where the
    assistant turn read `"ChatGPT said:"` at 15 characters while the answer was still coming.
    """
    from emubackend.tests.test_selectors_and_phases import FakeHandle

    deps, page = _deps(tmp_path, toggle="false")
    # Pre-seed the response so the send hook's `setdefault` leaves it alone.
    page.dom["#resp"] = [
        FakeHandle(page, "#resp", "ChatGPT said:", attrs={"data-state": "complete"})
    ]
    bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=1.0)

    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[1](None))

    assert "floor" in str(exc.value)
    assert deps.brief == "", "a stub must not be recorded as the brief"


def test_p1_ACCEPTS_a_real_length_brief(tmp_path):
    """The other half — a floor that rejects everything is not a floor."""
    deps, _page = _deps(tmp_path, toggle="false")
    bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=1.0)

    asyncio.run(bodies[1](None))

    assert deps.brief == FAKE_BRIEF.strip()
    assert any(e.startswith("p1:chatgpt:brief_captured:") for e in deps.log)
