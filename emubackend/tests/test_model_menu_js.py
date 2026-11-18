"""Execute P1's model-menu JavaScript against a DOM stub.

⭐ **These EXECUTE the expressions rather than asserting on their source.** The tier picker is where
a wrong answer is most expensive and least visible: it decides whether the research brief is written
by ChatGPT Pro or by Instant, and every downstream signal looks identical either way. A brief is
produced, it clears the length floor, three agents research it, a report ships. Nothing fails.

⛔ **Two of the assertions below are the 2026-08-05 incident.** A menu row was located by the bare
class ``.__menu-item`` matched against ``document``; ChatGPT's sidebar lists recent conversations as
``<a href>``, one was titled "Deep research request", the sidebar precedes the composer in document
order, and the press NAVIGATED THE TAB — proven twice from Chrome's own History DB. The Swift port
carries both arms of the fix (never an anchor; new since the menu opened) and the only way to know
they can still fire is to run them against a document that contains the trap.

⚠ Every test names the row set it builds. A pick asserted against rows the shim could not match
would pass by never ranking anything, which is the failure this whole file exists to rule out.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from emubackend.tests.test_notebook_js import _run

SWIFT = (
    Path(__file__).resolve().parents[2]
    / "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift"
)

#: The tier word, read from the Swift policy rather than written here.
#:
#: ⚠ A literal "pro" in this file would be a second copy of the policy, and a second copy is what
#: let the backend's Gemini hover helper freeze its own model list and drift from the ranker. If the
#: tier is ever renamed these tests must move with it or fail loudly — never quietly keep asserting
#: the old word.
POLICY = Path(__file__).resolve().parents[2] / (
    "ios/Sources/SuperResearchDeviceCore/ChatGPTModelPolicy.swift"
)


def _tier_word() -> str:
    match = re.search(r'public static let tierWords = \["([^"]+)"', POLICY.read_text())
    assert match, "tierWords vanished from the policy — every assertion below would be stale"
    return match.group(1)


def _js_string(value: str) -> str:
    return json.dumps(value)


def _groups(name: str) -> str:
    """Render one of the Swift `(name:css:)` group tables as the JS literal the code builds."""
    source = SWIFT.read_text()
    match = re.search(
        r'static let ' + re.escape(name) + r': \[\(name: String, css: String\)\] = \[\n(.*?)\n    \]',
        source,
        re.S,
    )
    assert match, f"{name} was not found — the extraction is stale and asserts nothing"
    pairs = re.findall(r'\("([^"]+)", "(.*?)"\),\n', match.group(1) + "\n")
    assert pairs, f"{name} parsed to no groups"
    return "[" + ", ".join(
        "{name: %s, sel: %s}" % (_js_string(n), _js_string(css.replace('\\"', '"')))
        for n, css in pairs
    ) + "]"


def _extract(member: str, **subs: str) -> str:
    """Pull one computed-property or method JS body out of `InAppPipeline.swift`."""
    source = SWIFT.read_text()
    match = re.search(
        r'(?:private )?(?:var|func) ' + re.escape(member) + r'\b[^\n{]*\{\n\s*"""\n(.*?)\n\s*"""',
        source,
        re.S,
    )
    assert match, (
        f"{member} was not found in {SWIFT.name} — it was renamed and every assertion below "
        f"would have silently stopped testing anything"
    )
    body = match.group(1)
    body = body.replace("\\(Self.jsPreamble)", _preamble("jsPreamble"))
    body = body.replace("\\(Self.rowFilterJS)", _preamble("rowFilterJS"))
    body = body.replace("\\(Self.groupsLiteral(Self.modelTriggerGroups))",
                        _groups("modelTriggerGroups"))
    body = body.replace("\\(Self.groupsLiteral(Self.modelRowGroups))", _groups("modelRowGroups"))
    body = body.replace("\\(Self.jsString(Self.clickMark))", _js_string(_click_mark()))
    body = body.replace("\\(Self.jsString(ChatGPTModelPolicy.avoidWord))",
                        _js_string(_avoid_word()))
    for name, value in subs.items():
        body = body.replace(name, value)
    # `\\s` in a Swift literal is `\s` at compile time.
    body = re.sub(r"\\\\", r"\\", body)
    assert "\\(" not in body, f"{member} still carries an unresolved interpolation:\n{body}"
    return body


def _seq(js: str, tail: str) -> str:
    """Run an extracted IIFE, then answer a follow-up question about the document it left behind.

    ⚠ Concatenation would not do: the shim evaluates ONE expression, so `js + "; …"` is a syntax
    error at worst and silently answers the wrong half at best.
    """
    return "(function(){ var __r = %s; return %s; })()" % (js, tail)


def _preamble(name: str) -> str:
    source = SWIFT.read_text()
    match = re.search(
        r'private static let ' + re.escape(name) + r' = """\n(.*?)\n    """', source, re.S
    )
    assert match, f"{name} vanished"
    return match.group(1)


def _click_mark() -> str:
    match = re.search(r'static let clickMark = "([^"]+)"', SWIFT.read_text())
    assert match, "clickMark vanished"
    return match.group(1)


def _avoid_word() -> str:
    match = re.search(
        r'public static let avoidWord = "([^"]+)"', POLICY.read_text()
    )
    assert match, "avoidWord vanished — the destructive DR-pill exclusion would be untested"
    return match.group(1)


# ── the model/effort trigger read ──────────────────────────────────────────────────────────────


def test_the_fixtures_below_still_name_the_policys_tier():
    """⛔ Every row set in this file says "Pro". If the policy is ever renamed, these tests would
    keep passing while asserting a word the picker no longer hunts — green, and testing nothing."""
    assert _tier_word() == "pro", (
        f"the tier word is now {_tier_word()!r}; the fixtures in this file must move with it"
    )


def test_the_trigger_read_finds_the_model_pill_and_reports_which_hook_answered():
    js = _extract("modelTriggerJS")
    # ⚠ UPPERCASE on purpose. The selector carries the CSS `i` flag, and the live attribute value is
    # not guaranteed lowercase — a fixture that matched either way would not tell us the flag
    # survived the port.
    got = _run(js, [{"tag": "button", "text": "Pro", "attrs": {"data-testid": "MODEL-switcher"}}])
    assert got["result"]["found"] is True
    assert got["result"]["text"] == "Pro"
    # The hook name is what makes the next rotation a one-line diagnosis rather than a bisect.
    assert got["result"]["via"] == "testid", got


def test_the_trigger_read_SKIPS_the_deep_research_pill():
    """⛔ Destructive, not merely unhelpful. The DR pill and the model pill are both
    `__composer-pill` buttons with the same tag, class and parent — no structural discriminator
    exists — and clicking the DR pill ADDS A SECOND DEEP RESEARCH rather than opening a menu."""
    js = _extract("modelTriggerJS")
    got = _run(js, [
        {"tag": "button", "class": "__composer-pill", "text": "Deep research"},
        {"tag": "button", "class": "__composer-pill", "text": "Instant"},
    ])
    assert got["result"]["text"] == "Instant", got


def test_the_trigger_read_REFUSES_a_wrapper_that_swallowed_the_composer():
    """A trigger is a short chip. Without the length cap a wrapper whose textContent concatenates
    the whole composer poses as one, and the tier is then read off the entire page."""
    js = _extract("modelTriggerJS")
    long_text = "Instant 5.5 Medium High Extra High Pro and every other word in the composer row"
    got = _run(js, [{"tag": "button", "text": long_text, "attrs": {"data-testid": "model-pill"}}])
    assert got["result"]["found"] is False, got


def test_the_trigger_read_ignores_a_control_inside_an_open_overlay():
    js = _extract("modelTriggerJS")
    got = _run(js, [
        {"tag": "div", "role": "menu", "children": [
            {"tag": "button", "text": "Pro", "attrs": {"data-testid": "model-row"}},
        ]},
    ])
    assert got["result"]["found"] is False, got


# ── marking the trigger for the press ──────────────────────────────────────────────────────────


def test_marking_the_trigger_stamps_the_attribute_the_press_resolves():
    """The search happens in JS and the press takes a handle; the mark is the only thing joining
    them. A mark that is not findable afterwards means the press never reaches the trigger."""
    js = _extract("markModelTriggerJS")
    mark = _click_mark()
    got = _run(
        _seq(js, f"[__r.marked, document.querySelectorAll('[{mark}=\"model-trigger\"]').length]"),
        [{"tag": "button", "text": "Instant", "attrs": {"data-testid": "model-switcher"}}],
    )
    assert got["result"] == [True, 1], got


def test_marking_CLEARS_a_previous_mark_first():
    """⛔ Two marked elements make `querySelector` pick by document order, which is how the wrong
    control gets pressed. The stale mark here sits FIRST, so a missing clear is visible."""
    js = _extract("markModelTriggerJS")
    mark = _click_mark()
    got = _run(
        _seq(js, f"[__r.marked, document.querySelectorAll('[{mark}]').length,"
                 f" document.querySelector('[{mark}]').textContent]"),
        [{"tag": "a", "text": "Old target", "attrs": {mark: "model-trigger", "href": "/c/1"}},
         {"tag": "button", "text": "Instant", "attrs": {"data-testid": "model-switcher"}}],
    )
    assert got["result"] == [True, 1, "Instant"], got


# ── the row read, and the two arms of the row filter ───────────────────────────────────────────

#: The menu as captured live: five effort rows, only the cheapest carrying a number.
LIVE_MENU = [
    {"tag": "div", "role": "menu", "children": [
        {"tag": "div", "role": "menuitemradio", "text": "Instant 5.5"},
        {"tag": "div", "role": "menuitemradio", "text": "Medium"},
        {"tag": "div", "role": "menuitemradio", "text": "High"},
        {"tag": "div", "role": "menuitemradio", "text": "Extra High"},
        {"tag": "div", "role": "menuitemradio", "text": "Pro"},
    ]},
]


def _rows(elements, seen=None):
    js = _extract("menuRowsJS", **{"\\(Self.jsArray(seen))": json.dumps(seen or [])})
    return _run(js, elements)["result"]


def test_the_row_read_returns_the_live_menu_and_names_its_hook():
    got = _rows(LIVE_MENU)
    assert got["rows"] == ["Instant 5.5", "Medium", "High", "Extra High", "Pro"], got
    assert got["via"] == "radio", got


def test_a_SIDEBAR_CONVERSATION_LINK_is_never_a_row():
    """⛔⛔ THE 2026-08-05 INCIDENT, reconstructed. A conversation titled with the words the picker
    hunts, rendered as an anchor, sitting BEFORE the menu in document order and carrying the same
    `__menu-item` class the overlay uses. Pressing it navigated the tab, twice.

    Arm 1 is absolute — a composer row is never a link — so it holds even with no census at all.
    """
    trap = [
        {"tag": "a", "class": "__menu-item", "text": "Pro deep research request",
         "attrs": {"href": "/c/6a72ce1e"}},
        {"tag": "div", "class": "__menu-item", "text": "Pro"},
    ]
    got = _rows(trap)
    assert got["rows"] == ["Pro"], got


def test_a_row_NESTED_INSIDE_an_anchor_is_also_refused():
    """`closest('a[href]')` rather than a tag test alone: the sidebar renders its title in a child
    of the link, and a tag test on the child sees a DIV."""
    trap = [
        {"tag": "a", "attrs": {"href": "/c/1"}, "children": [
            {"tag": "div", "class": "__menu-item", "text": "Pro deep research request"},
        ]},
    ]
    assert _rows(trap)["rows"] == [], _rows(trap)


def test_a_row_ALREADY_ON_SCREEN_before_the_press_is_refused():
    """Arm 2 — the census. Needs no knowledge of ChatGPT's DOM, so it also covers the next surface
    that borrows the class, including one that is not a link."""
    got = _rows(LIVE_MENU, seen=["Pro"])
    assert "Pro" not in got["rows"], got
    assert got["seen_used"] == ["Pro"], got


def test_when_the_census_empties_EVERYTHING_the_read_retries_without_it_and_says_so():
    """⛔ The asymmetry is deliberate. Arm 2 could cost a real row — if ChatGPT ever renders the
    rows visibly before the press, the census captures the very rows being hunted. A durability
    measure that can break a working path is not a durability measure, so it stands down and
    REPORTS that it did, rather than silently answering 'no rows'."""
    every_row = ["Instant 5.5", "Medium", "High", "Extra High", "Pro"]
    got = _rows(LIVE_MENU, seen=every_row)
    assert got["rows"] == every_row, got
    assert got["census_ignored"] is True, got
    # And the click must re-resolve against the set the READ used, not the one it was handed.
    assert got["seen_used"] == [], got


def test_the_class_fallback_is_reached_ONLY_when_no_role_group_matched():
    """A role is more durable than a class wherever a role exists. The class group exists because
    the tools menu's rows turned out to be plain DIVs whose only hook is the class."""
    both = [
        {"tag": "div", "role": "menu", "children": [
            {"tag": "div", "role": "menuitemradio", "text": "Pro"},
            {"tag": "div", "class": "__menu-item", "text": "Something else entirely"},
        ]},
    ]
    assert _rows(both)["via"] == "radio", _rows(both)
    class_only = [{"tag": "div", "class": "__menu-item", "text": "Pro"}]
    assert _rows(class_only)["via"] == "menu-item-class", _rows(class_only)


# ── clicking the picked row ────────────────────────────────────────────────────────────────────


def _click(elements, via, index, expect, seen=None):
    js = _extract(
        "clickRowJS",
        **{
            "\\(Self.jsString(via))": _js_string(via),
            "\\(index)": str(index),
            "\\(Self.jsString(expect))": _js_string(expect),
            "\\(Self.jsArray(seen))": json.dumps(seen or []),
        },
    )
    mark = _click_mark()
    tail = (f"[__r.clicked, __r.reason || '',"
            f" (document.querySelector('[{mark}=\"model-row\"]') || {{}}).textContent || '']")
    return _run(_seq(js, tail), elements)


def test_the_click_marks_the_row_the_ranker_actually_picked():
    got = _click(LIVE_MENU, via="radio", index=4, expect="Pro")
    assert got["result"] == [True, "", "Pro"], got


def test_the_click_REFUSES_when_the_label_at_that_index_changed():
    """⛔ IDENTITY DECIDES, not position. Ranking happens between two round trips, and if the menu
    re-rendered in that gap the index now points at a different row — clicking by position alone is
    exactly the mis-click the leaf/wrapper work was about."""
    got = _click(LIVE_MENU, via="radio", index=0, expect="Pro")
    assert got["result"][0] is False
    assert got["result"][1] == "label_changed", got


def test_the_click_re_resolves_against_the_SAME_filter_the_read_ranked_with():
    """Both bodies embed one filter string. When they were merely typed identically they drifted,
    and the click then re-resolved an index against a WIDER set than the read had ranked — so index
    4 pointed somewhere else entirely."""
    with_trap = [
        {"tag": "a", "class": "__menu-item", "text": "Pro deep research request",
         "attrs": {"href": "/c/1"}},
        {"tag": "div", "role": "menu", "children": [
            {"tag": "div", "role": "menuitemradio", "text": "Instant 5.5"},
            {"tag": "div", "role": "menuitemradio", "text": "Pro"},
        ]},
    ]
    rows = _rows(with_trap)
    assert rows["rows"] == ["Instant 5.5", "Pro"], rows
    got = _click(with_trap, via="radio", index=1, expect="Pro")
    assert got["result"] == [True, "", "Pro"], got


def test_the_click_reports_a_vanished_index_rather_than_pressing_something_else():
    got = _click(LIVE_MENU, via="radio", index=99, expect="Pro")
    assert got["result"][1] == "index_gone", got


def test_the_click_reports_a_vanished_hook_group():
    got = _click(LIVE_MENU, via="a-group-that-no-longer-exists", index=0, expect="Pro")
    assert got["result"][1] == "group_gone", got


# ── the pre-open census ────────────────────────────────────────────────────────────────────────


def test_the_census_unions_EVERY_hook_group_rather_than_stopping_at_the_first():
    """Deliberately group-agnostic: the read afterwards may answer on a different group than the
    census would have, and a census taken through only one group would then miss the rows that
    matter."""
    js = _extract("rowsSeenJS")
    mixed = [
        {"tag": "div", "role": "menuitemradio", "text": "Pro"},
        {"tag": "div", "class": "__menu-item", "text": "Deep research request"},
    ]
    got = _run(js, mixed)
    assert sorted(got["result"]) == ["Deep research request", "Pro"], got
