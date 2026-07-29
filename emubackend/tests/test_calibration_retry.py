"""Calibration gets exactly ONE retry, and only when the layout moved during the measurement.

Safari's URL bar collapses the first time the page scrolls, changing `innerHeight` — and the
calibration probes are what trigger it. So a first attempt on a fresh tab can be invalidated by its
own side effect (measured 749 -> now 714, in the case that surfaced this), while a second attempt runs
against the settled layout.

`geometry.calibrate` stays strict on purpose: a transform averaged across a moving layout is exactly
the off-by-the-URL-bar error that makes taps land near their target rather than on it. The retry is the
caller's policy, and it is capped so a genuinely unstable layout still fails instead of looping.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BACKEND = REPO / "emubackend" / "substrate" / "backend.py"


def _code() -> str:
    text = BACKEND.read_text(encoding="utf-8")
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def test_the_retry_is_scoped_to_the_layout_changed_error():
    """A blanket retry would paper over every calibration failure, including real ones."""
    code = _code()
    assert 'if "layout changed during calibration" not in str(first):' in code
    assert "raise" in code.split('if "layout changed during calibration" not in str(first):')[1][:80]


def test_there_is_exactly_one_retry_not_a_loop():
    """An unstable layout must fail, not spin."""
    code = _code()
    # Sliced FORWARD from _calibration. Anchoring on the first "async def tap(" found an earlier
    # protocol declaration (line 91) that precedes _calibration entirely, so the block was empty and
    # `.count(...) == 2` failed against "". Same shape as the parity module's parse bugs: a delimiter
    # search hitting a plausible earlier match.
    start = code.index("async def _calibration")
    block = code[start : code.index("async def tap(", start)]
    assert block.count("await asyncio.to_thread(measure)") == 2, (
        "expected exactly two attempts — one initial and one retry"
    )
    assert not re.search(r"(while|for)\s.*measure", block), "the retry must not be a loop"


def test_geometry_calibrate_itself_stays_strict():
    """The measurement must keep refusing a layout that moved — the retry belongs to the caller."""
    geometry = (REPO / "emubackend" / "substrate" / "geometry.py").read_text(encoding="utf-8")
    assert "the layout changed during calibration" in geometry, (
        "geometry.calibrate must still detect and refuse a mid-measurement layout change"
    )
