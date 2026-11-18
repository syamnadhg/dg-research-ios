"""Model selection: by family and highest offered, never by a version literal.

The fixtures here are the REAL rows measured on the live in-app Gemini picker on 2026-08-08:

    "Gemini Flash"                          (the picker button itself, not an option)
    "3.5 Flash-Lite Fastest answers New"
    "3.6 Flash All-around help"
    "3.1 Pro Advanced maths and code"
    "Extended thinking Complex problem solving"
"""
from __future__ import annotations

from emubackend import models

LIVE_MENU = [
    "Gemini Flash",
    "3.5 Flash-Lite Fastest answers New",
    "3.6 Flash All-around help",
    "3.1 Pro Advanced maths and code",
    "Extended thinking Complex problem solving",
]


class TestAgainstTheLiveMenu:

    def test_the_latest_flash_is_chosen(self):
        assert models.pick_latest(LIVE_MENU, "Flash") == "3.6 Flash All-around help"

    def test_FLASH_LITE_IS_NOT_FLASH(self):
        # ⛔ The trap, and the whole reason this is not a substring match. Flash-Lite is the
        # fastest/cheapest tier; picking it for a deep-research phase makes the research worse and
        # nothing fails.
        assert models.pick_latest(LIVE_MENU, "Flash-Lite") == "3.5 Flash-Lite Fastest answers New"
        assert "Lite" not in (models.pick_latest(LIVE_MENU, "Flash") or "")

    def test_a_NEWER_flash_lite_still_does_not_win_the_flash_slot(self):
        # The forward-looking case: the day the account is offered 3.7 Flash-Lite, a naive
        # highest-version-containing-"Flash" switches P2 onto it.
        menu = LIVE_MENU + ["3.7 Flash-Lite Fastest answers"]
        assert models.pick_latest(menu, "Flash") == "3.6 Flash All-around help"

    def test_a_newer_flash_DOES_win_without_any_code_change(self):
        # The point of family-plus-highest: the numbering moves and nothing here does.
        menu = LIVE_MENU + ["4.0 Flash All-around help"]
        assert models.pick_latest(menu, "Flash") == "4.0 Flash All-around help"

    def test_the_pro_family_is_selectable_too(self):
        assert models.pick_latest(LIVE_MENU, "Pro") == "3.1 Pro Advanced maths and code"

    def test_extended_thinking_is_recognised_and_is_not_a_model(self):
        assert models.is_extended_thinking("Extended thinking Complex problem solving")
        assert models.parse_option("Extended thinking Complex problem solving") is None

    def test_the_picker_BUTTON_is_not_mistaken_for_an_option(self):
        # "Gemini Flash" is the control that opens the menu; treating it as a row would make the
        # menu appear to offer a version-less Flash.
        assert models.parse_option("Gemini Flash") is None


class TestVersionOrdering:

    def test_minor_versions_order_numerically_not_lexically(self):
        # "3.10" > "3.9" numerically and "3.10" < "3.9" as text — the classic.
        menu = ["3.9 Flash a", "3.10 Flash b"]
        assert models.pick_latest(menu, "Flash") == "3.10 Flash b"

    def test_a_major_bump_beats_any_minor(self):
        menu = ["3.99 Flash a", "4.0 Flash b"]
        assert models.pick_latest(menu, "Flash") == "4.0 Flash b"

    def test_a_version_with_no_minor_is_read_as_zero(self):
        menu = ["4 Flash a", "3.9 Flash b"]
        assert models.pick_latest(menu, "Flash") == "4 Flash a"


class TestRefusals:

    def test_a_family_that_is_NOT_OFFERED_returns_None_rather_than_a_near_miss(self):
        # ⚠ A picker that stops offering the family is a real change the caller must handle.
        # Silently taking the closest thing switches a deep-research phase onto a model nobody
        # chose.
        assert models.pick_latest(LIVE_MENU, "Ultra") is None

    def test_an_empty_menu_returns_None(self):
        assert models.pick_latest([], "Flash") is None

    def test_rows_with_no_version_are_ignored(self):
        assert models.pick_latest(["Flash", "Some heading"], "Flash") is None

    def test_the_family_match_is_case_insensitive_but_still_exact(self):
        assert models.pick_latest(["3.6 flash all-round"], "Flash") == "3.6 flash all-round"
        assert models.pick_latest(["3.6 flash-lite fast"], "Flash") is None


def test_no_version_literal_is_hardcoded_anywhere_in_the_module():
    """⛔ The standing rule: family-only, zero version literals.

    Executed rather than eyeballed, because a pinned version is invisible in review and rots in both
    directions — stranding the run on an old model, or matching something else entirely when the
    numbering scheme changes.
    """
    import inspect
    import re

    source = inspect.getsource(models)
    # Strip comments and docstrings, where measured examples are legitimately quoted.
    code = "\n".join(
        line.split("#")[0] for line in source.splitlines() if not line.strip().startswith("#")
    )
    code = re.sub(r'"""(?:.|\n)*?"""', "", code)
    assert not re.search(r"\b\d+\.\d+\s*(Flash|Pro)\b", code, re.IGNORECASE), (
        "a model version literal reached the code path"
    )


# --------------------------------------------------------------------------------------------
# The Gemini P2 setup the owner specified: latest Flash + extended thinking, then Deep Research
# from the "+" drawer. These assert the WIRING, because the logic was already right and unusable.


class TestGeminisControlsAreActuallyWired:
    """⛔ Both of these were missing while every model-selection test above passed.

    The pick logic had no selector to drive on Gemini at all, and the deep-research item's two-step
    path was written in the manifest's PROSE while the machine-readable opener field sat empty — so
    the resolver never tapped the drawer. Prose the code cannot read is not wiring.
    """

    def _gemini(self):
        from emubackend import selectors
        return selectors.load_manifest()

    def test_the_model_picker_is_RESOLVABLE_so_the_family_pick_can_be_applied(self):
        entry = self._gemini().entry("gemini", "model_selector")
        assert entry is not None and entry.resolvable, (
            "the family+highest-offered pick has no control to drive on this platform"
        )

    def test_the_picker_is_matched_on_the_LABEL_PREFIX_not_the_whole_string(self):
        # ⚠ The label ends with the CURRENT model. An exact match breaks the moment the control
        # does its job — the failure arrives only after a successful switch.
        css = self._gemini().entry("gemini", "model_selector").css
        assert any(c.startswith('button[aria-label^=') for c in css), css
        assert not any("currently" in c for c in css), (
            f"a selector pinned to the current model will not survive changing it: {css}"
        )

    def test_deep_research_declares_its_OPENER_and_not_only_in_prose(self):
        # Measured live: with the drawer shut there are ZERO drawer items on the page, so without
        # an opener the entry resolves to nothing and reads as "this platform lost deep research".
        entry = self._gemini().entry("gemini", "deep_research_toggle")
        assert entry.opener, "the drawer is never tapped, so the item is unreachable"
        assert "Upload and tools" in entry.opener

    def test_the_owners_gemini_spec_is_encoded_with_no_version_literal(self):
        from emubackend import models
        assert models.P2_MODEL_FAMILY["gemini"] == "Flash"
        assert "gemini" in models.P2_EXTENDED_THINKING
        # And it follows the picker without an edit — "rn 3.6" is a fact about today, not a pin.
        offered = ["3.5 Flash-Lite fastest", "3.6 Flash all-round", "3.1 Pro advanced"]
        assert models.pick_latest(offered, "Flash") == "3.6 Flash all-round"
        assert models.pick_latest(offered + ["4.0 Flash next"], "Flash") == "4.0 Flash next"
