"""Claude's P2 setup — and the retraction of a wrong negative.

⚠ **A measurement in this repo was wrong, and the reason is worth keeping — including the fact that
the FIRST explanation for it was also wrong.** Claude's composer opener was driven with a real HID
tap and the menu read in full; it held files / project / skills / connectors / plugins and **no
Research**, and that was written up as a strong negative. §14 says a script-driven negative is not a
negative — driving the tap made it feel like one, which is how it got past me.

The first diagnosis was that Claude has a **Chat / Cowork** switch and the mode had never been
checked, so Cowork's menu was what got read. That was plausible and it is NOT what happened. The
measured cause (2026-08-08) is that the enumeration asked for
``[role=menuitem],[role=menuitemradio],[role=option]`` and Research is a **``menuitemcheckbox``** —
the menu was open, in Chat mode, and the item was filtered out of the *result*. Recorded this way
because a confidently-stated wrong cause is how the same bug gets re-derived: the mode hypothesis
sent the next three attempts looking at the wrong thing entirely.

Chat mode is still what the owner specified and is still asserted — it is a requirement, just not
the explanation. Whether Cowork's menu offers Research has never actually been enumerated.

The owner's instruction, which is what these encode: Opus at the highest offered, **Chat** mode, and
Research from the "+" menu.
"""
from __future__ import annotations

from emubackend import models, prompts


class TestClaudeIsADeepResearchPlatform:

    def test_claude_HAS_deep_research(self):
        assert prompts.deep_research_available("claude") is True

    def test_all_three_p2_platforms_are_deep_research_platforms(self):
        for platform in prompts.P2_PLATFORMS:
            assert prompts.deep_research_available(platform) is True, platform

    def test_an_UNKNOWN_platform_still_defaults_to_NO(self):
        # The safe direction survives the retraction: a platform nobody has measured is one whose
        # research mode nobody has seen, and claiming a deep-research report that is really a chat
        # answer is the failure this guards.
        assert prompts.deep_research_available("perplexity") is False

    def test_no_report_is_labelled_standard_mode_any_more(self):
        # The label existed only for the retracted claim. A caveat on a real deep-research report
        # would understate the two that cost a research unit.
        for platform in prompts.P2_PLATFORMS:
            assert prompts.annotate_report(platform, "# Findings\n\nBody.") == "# Findings\n\nBody."

    def test_the_consolidated_headings_are_plain_again(self):
        out = prompts.consolidated_report("t", {"chatgpt": "A", "gemini": "B", "claude": "C"})
        assert "## Claude Research" in out
        assert "(standard mode)" not in out


class TestClaudesRequiredMode:
    """⛔ Cowork's composer menu has no Research. Landing there fails as a MISSING SELECTOR, which
    is the misdiagnosis this exists to prevent."""

    def test_claude_must_be_put_into_CHAT_mode(self):
        assert prompts.required_mode("claude") == "Chat"

    def test_the_other_platforms_have_no_mode_requirement(self):
        assert prompts.required_mode("chatgpt") is None
        assert prompts.required_mode("gemini") is None


class TestClaudesModelFamily:

    def test_claude_uses_the_OPUS_family(self):
        assert models.P2_MODEL_FAMILY["claude"] == "Opus"

    def test_the_highest_opus_offered_wins_with_no_version_in_the_code(self):
        # Owner: "Opus highest so far (rn at 5)" — the parenthesis is why there is no literal.
        menu = ["5 Opus Max", "4.5 Opus", "3.6 Sonnet"]
        assert models.pick_latest(menu, "Opus") == "5 Opus Max"
        # ...and it follows the picker without an edit.
        assert models.pick_latest(menu + ["6 Opus"], "Opus") == "6 Opus"

    def test_sonnet_is_not_opus(self):
        assert models.pick_latest(["3.6 Sonnet a"], "Opus") is None


# --------------------------------------------------------------------------------------------
# The Research control itself — measured in-app 2026-08-08, and the retraction of a SECOND wrong
# negative that had the same shape as the first.
#
# ⛔ **"Claude has no Research" was re-derived three more times, and every one was an artefact of my
# own tooling rather than of the platform.** Two independent bugs each hid the control on their own:
#
#   1. The enumeration query asked for `[role=menuitem],[role=menuitemradio],[role=option]`. Research
#      is a **`menuitemcheckbox`**, so the menu opened correctly and the item was filtered out of the
#      result — a clean read of five items that was missing exactly the two toggles.
#   2. Later taps used a hardcoded calibration (scale 1.0, top chrome 151.9pt) while the surface
#      renders at zoom ~1.067. The tap landed ~25 CSS px ABOVE the "+" and the menu never opened at
#      all. `isTrusted` was `true` on every one of those taps.
#
# ⚠ The lesson that generalises: **a trusted event is not evidence that the intended element was
# hit.** `tap_element` returns the target for precisely this reason and only the weak half of its
# result was being read. With a measured calibration the tap lands within 0.2 px and the menu
# enumerates seven items.
#
# The same missing role was in the PRODUCTION resolver, so a perfectly correct manifest entry would
# still have failed to resolve — and that failure presents as "this platform has no Research mode".


#: The "+" menu exactly as measured in Chat mode (`aria-checked=true`) on Opus 5 Max. The two
#: toggles carry `aria-checked`; the five plain rows do not. Their `id`s are generated per render
#: (`base-ui-_r_5k_`) and are deliberately absent here — using one as a handle is the trap.
MEASURED_PLUS_MENU = [
    ("menuitem", "Add files or photos Ctrl+U", None),
    ("menuitem", "Add to project", None),
    ("menuitem", "Skills", None),
    ("menuitem", "Add connector", None),
    ("menuitem", "Add plugins...", None),
    ("menuitemcheckbox", "Research", "false"),
    ("menuitemcheckbox", "Web search", "false"),
]


class _RoleNode:
    def __init__(self, role, text, checked):
        self.role, self._text, self._checked = role, text, checked

    async def inner_text(self):
        return self._text

    async def get_attribute(self, name):
        return {"role": self.role, "aria-checked": self._checked}.get(name)


class _RoleAwarePage:
    """A page that REALLY matches the resolver's selector list against modelled roles.

    ⚠ Deliberately not the shared ``FakePage``: that one answers *any* comma-separated selector with
    its ``text_candidates``, so a role missing from the resolver's list is invisible to it. A test
    built on that double passes whether or not the fix is present — the exact failure mode this
    project keeps re-learning, where the guard is satisfied by the test double rather than by the
    code. Here an unlisted role genuinely returns nothing.
    """

    def __init__(self, nodes):
        self.nodes = [_RoleNode(*n) for n in nodes]

    async def query_selector(self, _css):
        return None  # Claude's entry has no CSS chain; text is the only handle.

    async def query_selector_all(self, css):
        import re
        roles = set(re.findall(r"\[role=\"?([a-z]+)\"?\]", css))
        return [n for n in self.nodes if n.role in roles]


class TestTheResearchControlResolves:

    def _entry(self):
        from emubackend import selectors
        return selectors.load_manifest().entry("claude", "research_toggle")

    def test_the_manifest_entry_is_RESOLVABLE_at_all(self):
        # An entry with neither CSS nor text is unresolvable, and `_toggle_on_predicate` returns
        # False for one — so P2 would report Claude unconfigured rather than fail loudly.
        assert self._entry().resolvable

    def test_research_is_found_in_the_MEASURED_menu(self):
        import asyncio

        from emubackend import phases

        page = _RoleAwarePage(MEASURED_PLUS_MENU)
        found = asyncio.run(phases.resolve(page, self._entry()))
        assert found is not None, (
            "Claude's Research control did not resolve against the real measured menu — which is "
            "how a missing role presents: as 'this platform has no Research mode'."
        )
        assert asyncio.run(found.inner_text()) == "Research"

    def test_it_is_a_menuitemCHECKBOX_and_the_role_list_must_carry_that(self):
        # ⛔ The mechanism, asserted by REMOVING the role from the fixture rather than by grepping
        # the resolver's selector string for it. If `menuitemcheckbox` ever drops out of the
        # resolver's candidate list this fails, because nothing else in the menu is named Research.
        import asyncio

        from emubackend import phases

        without_toggles = [n for n in MEASURED_PLUS_MENU if n[0] != "menuitemcheckbox"]
        page = _RoleAwarePage(without_toggles)
        assert asyncio.run(phases.resolve(page, self._entry())) is None, (
            "the five plain rows must not satisfy the Research entry — if one of them does, the "
            "toggle could be 'found' while the real control is never touched"
        )

    def test_the_state_attribute_is_readable_so_it_is_never_assumed(self):
        # ⭐ Research carries `aria-checked`, so `enable_deep_research` can consult the state with
        # the same predicate that judges the action. Deep-research state PERSISTS across runs; an
        # unconditional tap on run two switches it OFF and the run reports success on a shallow
        # answer.
        import asyncio

        from emubackend import phases

        page = _RoleAwarePage(MEASURED_PLUS_MENU)
        found = asyncio.run(phases.resolve(page, self._entry()))
        assert asyncio.run(found.get_attribute("aria-checked")) == "false"

    def test_the_generated_id_is_NOT_used_as_a_handle(self):
        # `base-ui-_r_5k_` is re-minted every render. Pinning it produces a selector that works in
        # the session it was captured in and never again.
        entry = self._entry()
        assert not any("base-ui" in css for css in entry.css), entry.css
