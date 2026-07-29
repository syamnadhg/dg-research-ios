"""The two guards that stand between a capture session and a plausible-but-wrong manifest.

Both were written **after** running ``bin/capture_selectors.py`` against the real platforms for the
first time, and both encode something the run measured rather than something the design predicted.

*The signed-out refusal.* The first real capture ran against ``https://chatgpt.com`` on a device
nobody had signed in. The page it found was the anonymous visitor shell — which has a working
composer — so the tool proposed ``#mobile-composer-prompt`` for ``composer`` with provenance
``captured:stable id``. Nothing about that entry looks wrong in the file. It is wrong, and it is the
expensive kind of wrong: the P1 failure, where every click resolves and lands, the harvest returns
nothing, and the run reports success. All four platforms surveyed as signed out in the same session,
each announcing it differently (a "Log in" button, a ``login-with-google`` testid, the word "Sign
in", an SSO redirect), which is why the check reads *controls* rather than any one platform's marker.

*The post-response refusal.* The acceptance rule had to be relaxed to admit ``tag[aria-label=…]``
targets, because real mobile ChatGPT ships neither a testid nor an id on its send button
(``button[aria-label="Send message"]``) or its deep-research control — under the strict rule a
perfectly good page yielded 1 of 7 keys. But relaxing it alone would have drafted ``sources`` from
ChatGPT's *nav chrome*: with no answer rendered, the ``a[href^=http]`` probe returns
``a[aria-label="Images"]``, ``a[aria-label="Plugins"]`` and ``a[aria-label="See plans and pricing"]``
— visible, unique, rank 4, and utterly wrong. So post-response keys are refused unless a response is
actually on screen.

The candidate payloads below are transcribed from ``artifacts/selectors/chatgpt_candidates.json`` as
that run wrote it, not invented, because a guard tested against invented input is a guard tested
against the author's imagination.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent


def _capture_module():
    spec = importlib.util.spec_from_file_location(
        "capture_selectors", REPO / "bin" / "capture_selectors.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["capture_selectors"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def cap():
    return _capture_module()


# --- the signed-out refusal ------------------------------------------------------------------


def test_a_signed_in_page_has_no_auth_controls_and_no_auth_host(cap):
    verdict = cap.login_verdict(
        {"url": "https://chatgpt.com/c/abc", "authControls": [], "testids": {}}
    )
    assert verdict["signed_in"] is True
    assert verdict["reasons"] == []


def test_the_real_signed_out_chatgpt_shell_is_refused(cap):
    """As measured: a visible "Log in" button beside a working composer."""
    verdict = cap.login_verdict(
        {
            "url": "https://chatgpt.com/",
            "authControls": [
                {"tag": "button", "name": "Log in", "testid": None},
                {"tag": "button", "name": "Sign up for free", "testid": None},
            ],
            "testids": {"mobile-app-shell-fallback": 1},
        }
    )
    assert verdict["signed_in"] is False
    assert any("Log in" in reason for reason in verdict["reasons"])


def test_the_real_signed_out_claude_page_is_refused(cap):
    verdict = cap.login_verdict(
        {
            "url": "https://claude.ai/login",
            "authControls": [{"tag": "button", "name": "Continue with Google",
                              "testid": "login-with-google"}],
            "testids": {"login-with-google": 1},
        }
    )
    assert verdict["signed_in"] is False


def test_the_real_notebooklm_sso_bounce_is_refused_by_host(cap):
    """No controls needed — landing on accounts.google.com is already the answer."""
    verdict = cap.login_verdict(
        {
            "url": "https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2F"
                   "notebook.google.com%2F",
            "authControls": [],
            "testids": {},
        }
    )
    assert verdict["signed_in"] is False
    assert any("accounts.google.com" in reason for reason in verdict["reasons"])


def test_sign_out_does_not_read_as_signed_out(cap):
    """The anchoring matters: a signed-in page's own "Sign out" must not trip the refusal.

    ``/^sign ?in/`` and ``/^log ?in/`` are anchored for exactly this. An unanchored search would
    make every signed-in page refuse itself, and the refusal would then be indistinguishable from
    a genuine one — the failure mode where a guard is disabled by being always-on.
    """
    verdict = cap.login_verdict(
        {"url": "https://claude.ai/new", "authControls": [], "testids": {}}
    )
    assert verdict["signed_in"] is True


def test_prose_about_logging_in_cannot_trip_the_refusal(cap):
    """ChatGPT's signed-in page carries prose like "Log in to get answers based on saved chats".

    The verdict reads controls, never body text, so prose is structurally incapable of tripping it.
    Asserted rather than assumed, because "we only look at controls" is a property of the JS that a
    later edit could quietly drop.
    """
    verdict = cap.login_verdict(
        {
            "url": "https://chatgpt.com/",
            "authControls": [],
            "bodyTextHead": "Log in to get answers based on saved chats, plus create images",
            "testids": {},
        }
    )
    assert verdict["signed_in"] is True


# --- the acceptance rule --------------------------------------------------------------------

#: Verbatim from the real capture: rank 4, visible, unique. The only stable handle ChatGPT gives.
REAL_SEND = {
    "probe": "button[aria-label*=Send]",
    "tag": "button",
    "name": "Send message",
    "suggested": 'button[aria-label="Send message"]',
    "rank": 4,
    "why": "tag + aria-label",
    "matches": 1,
    "visible": True,
    "disabled": True,
}

#: Also verbatim: ChatGPT's nav chrome, which the ``sources`` probe returns when nothing is answered.
REAL_NAV_LINK = {
    "probe": "a[href^=http]",
    "tag": "a",
    "name": "Images",
    "suggested": 'a[aria-label="Images"]',
    "rank": 4,
    "why": "tag + aria-label",
    "matches": 1,
    "visible": True,
}


def _draft(cap, candidates, response_present):
    return cap.draft_manifest(
        {
            "platform": "chatgpt",
            "candidates": candidates,
            "response": {"present": response_present},
        }
    )["platforms"]["chatgpt"]


def test_a_unique_aria_label_target_is_accepted(cap):
    entries = _draft(cap, {"send": [REAL_SEND]}, response_present=False)
    assert entries["send"]["css"] == ['button[aria-label="Send message"]']


def test_an_accepted_aria_label_target_is_marked_weak(cap):
    entries = _draft(cap, {"send": [REAL_SEND]}, response_present=False)
    assert "weak" in entries["send"]["provenance"]
    assert "driving" in entries["send"]["provenance"]


def test_an_ambiguous_aria_label_target_is_rejected(cap):
    """Three matches is a category, not a target — and ``resolve`` would take document order."""
    ambiguous = {**REAL_SEND, "matches": 3}
    entries = _draft(cap, {"send": [ambiguous]}, response_present=False)
    assert "send" not in entries


def test_a_testid_target_is_accepted_without_the_uniqueness_condition(cap):
    """Rank 1–3 keeps its original latitude; the uniqueness clause is the price of rank 4 only."""
    entry = {
        "suggested": '[data-testid="send-button"]',
        "rank": 1,
        "why": "data-testid",
        "matches": None,
        "visible": True,
        "tag": "button",
    }
    entries = _draft(cap, {"send": [entry]}, response_present=False)
    assert entries["send"]["css"] == ['[data-testid="send-button"]']
    assert "weak" not in entries["send"]["provenance"]


def test_a_tapped_key_will_not_accept_a_wrapper_div(cap):
    """Gemini puts the testid on `send-button-container` and only an aria-label on the button.

    Rank alone therefore preferred the wrapper — a div — over the button that was successfully driven.
    Requiring a control settles it without a name heuristic: you tap controls, not their boxes.
    """
    wrapper = {
        "suggested": '[data-test-id="send-button-container"]',
        "rank": 1,
        "why": "data-test-id",
        "matches": 1,
        "visible": True,
        "tag": "div",
        "role": None,
    }
    entries = _draft(cap, {"send": [wrapper]}, response_present=False)
    assert "send" not in entries


def test_a_role_button_counts_as_a_control(cap):
    """Not every control is a <button> element; Angular Material and Gemini both use role=button."""
    div_button = {
        "suggested": '[data-test-id="x"]',
        "rank": 1,
        "why": "data-test-id",
        "matches": 1,
        "visible": True,
        "tag": "div",
        "role": "button",
    }
    entries = _draft(cap, {"send": [div_button]}, response_present=False)
    assert entries["send"]["css"] == ['[data-test-id="x"]']


def test_a_read_key_does_not_require_a_control(cap):
    """The gate is scoped to tapped keys — a response container is a div and must stay acceptable."""
    assert "response_container" not in cap.TAPPED_KEYS
    assert "sources" not in cap.TAPPED_KEYS
    assert "logged_in_marker" not in cap.TAPPED_KEYS


def test_an_attribute_marker_probe_is_a_durable_handle(cap):
    """Claude's assistant turn is identified by `div[data-is-streaming]` and nothing else.

    Sixteen testids on the page with an answer up, none of them on the response — and
    `[data-testid*=message]` matched `user-message`, so the capture proposed the user's own prompt as
    the response container.
    """
    assert cap.durable_probe("div[data-is-streaming]")
    assert cap.durable_probe("[data-is-streaming]")
    assert not cap.durable_probe("div[class]")


def test_an_invisible_candidate_is_rejected(cap):
    entries = _draft(cap, {"send": [{**REAL_SEND, "visible": False}]}, response_present=False)
    assert "send" not in entries


def test_chatgpts_images_nav_link_never_becomes_sources(cap):
    """The regression this guard exists for, stated as the exact wrong value it must not write."""
    entries = _draft(cap, {"sources": [REAL_NAV_LINK]}, response_present=False)
    assert "sources" not in entries


def test_post_response_keys_are_skipped_with_a_reason_not_silently(cap):
    draft = cap.draft_manifest(
        {
            "platform": "chatgpt",
            "candidates": {"sources": [REAL_NAV_LINK]},
            "response": {"present": False},
        }
    )
    assert "no response on screen" in draft["_skipped"]["sources"]


def test_post_response_keys_are_capturable_once_a_response_is_on_screen(cap):
    entries = _draft(cap, {"sources": [REAL_NAV_LINK]}, response_present=True)
    assert entries["sources"]["css"] == ['a[aria-label="Images"]']


def test_a_missing_pre_response_key_is_reported_as_a_failed_rule_not_as_a_missing_pass(cap):
    """Two different "no value" outcomes must not print the same sentence.

    "no candidate met the rule" means look at the candidates file; "no response on screen" means
    re-run with an answer up. Collapsing them sends the reviewer to the wrong place.
    """
    draft = cap.draft_manifest(
        {
            "platform": "chatgpt",
            "candidates": {"composer": [{**REAL_SEND, "visible": False}]},
            "response": {"present": False},
        }
    )
    assert draft["_skipped"]["composer"] == "no candidate met the acceptance rule"


def test_the_draft_still_loads_as_a_manifest_despite_the_skip_report(cap, tmp_path):
    """``_skipped`` rides along for the reviewer; it must not make the file unloadable.

    The runbook's promise is that a draft "loads as-is", and the loader *rejects* unknown keys inside
    a platform. Top-level extras are ignored — asserted here so adding the report cannot have
    quietly broken the promise.
    """
    import json

    from emubackend import selectors

    draft = cap.draft_manifest(
        {
            "platform": "chatgpt",
            "candidates": {"send": [REAL_SEND]},
            "response": {"present": False},
        }
    )
    path = tmp_path / "draft.json"
    path.write_text(json.dumps(draft))
    loaded = selectors.load_manifest(path)
    assert loaded.source == str(path)
    assert loaded.entry("chatgpt", "send").css == ('button[aria-label="Send message"]',)


def test_a_presence_only_key_does_not_require_visibility(cap):
    """Gemini's login markers exist but have no rect — the sidebar is collapsed at 402pt.

    Requiring visibility rejected all three of them and left Gemini with no marker at all, while the
    app's own check is `!!document.querySelector(…)` and would have accepted any. The rule was
    measuring the wrong property for this key.
    """
    invisible_marker = {
        "suggested": "[data-test-id=new-chat-button]",
        "rank": 1,
        "why": "data-test-id",
        "matches": 1,
        "visible": False,
    }
    entries = _draft(cap, {"logged_in_marker": [invisible_marker]}, response_present=False)
    assert entries["logged_in_marker"]["css"] == ["[data-test-id=new-chat-button]"]


def test_visibility_is_still_required_for_anything_tapped(cap):
    """The exemption is scoped to presence keys. A send button you cannot see is not a send button."""
    entries = _draft(
        cap, {"send": [{**REAL_SEND, "visible": False}]}, response_present=False
    )
    assert "send" not in entries


def test_only_logged_in_marker_is_presence_only(cap):
    """Stated as an assertion so widening the exemption has to be deliberate."""
    assert cap.PRESENCE_ONLY_KEYS == {"logged_in_marker"}


def test_composer_scoped_keys_cover_every_control_that_shares_a_word_with_content():
    """send + the three research controls. Each names a concept that also appears in chat titles."""
    module = _capture_module()
    assert module.COMPOSER_SCOPED_KEYS == {
        "send",
        "deep_research_toggle",
        "research_toggle",
        "start_research",
    }


def test_the_describe_script_emits_the_testid_attribute_it_actually_found(cap):
    """Gemini spells it `data-test-id`; ChatGPT and Claude spell it `data-testid`.

    The script read either and always emitted `[data-testid="…"]`, so every Gemini value it proposed
    would have matched zero elements — a whole platform of selectors that resolve to nothing while
    looking perfectly reasonable in the file. Measured on the live page: `[data-testid]` → 0 nodes,
    `[data-test-id]` → 41.
    """
    js = cap._DESCRIBE_JS
    assert "hasAttribute('data-testid')" in js
    assert "hasAttribute('data-test-id')" in js
    # The emitted selector must be built from the found attribute name, never a literal.
    assert "'[' + attr + '=\"' + tid + '\"]'" in js


def test_generated_ids_are_rejected_by_the_describe_script(cap):
    """`#_r_3q_` and `#base-ui-_r_15_` were both proposed from real Claude DOM before this."""
    js = cap._DESCRIBE_JS
    assert "GENERATED_ID" in js
    for pattern in ("_r_", "radix-", "base-ui-"):
        assert pattern in js, f"{pattern} must be in the generated-id rejection"
    assert "!GENERATED_ID.test(el.id)" in js


def test_the_composer_scope_is_applied_in_the_describe_script(cap):
    js = cap._DESCRIBE_JS
    assert "anchor.closest('form')" in js
    assert "root.querySelectorAll(probe)" in js


def test_the_composer_scope_walks_up_when_there_is_no_form(cap):
    """ChatGPT wraps its composer in a <form>; Claude and Gemini do not.

    With `|| parentElement` as the fallback the scope collapsed to the contenteditable's immediate
    parent, which holds no buttons — so both platforms reported "no controls appeared" after a
    *successful* fill. That reads as the platform having no send button rather than as the scope being
    wrong, which is the worst kind of wrong: a confident negative.
    """
    js = cap._DESCRIBE_JS
    assert "node.querySelectorAll('button,[role=button]').length > 0" in js, (
        "the scope must walk up to an ancestor that actually contains controls"
    )


def test_the_driver_shares_the_same_composer_root_rule():
    """Two implementations of one rule is two chances to fix it in one place."""
    driver = (REPO / "bin" / "drive_selectors.py").read_text()
    assert "function composerRoot" in driver
    assert "node.querySelectorAll('button,[role=button]').length > 0" in driver


def test_every_platform_with_composer_scoped_keys_has_an_anchor(cap):
    """A scope that resolves to nothing silently falls back to the whole document.

    So a platform declaring a scoped key without an anchor gets page-wide matching while appearing to
    be scoped — the failure looks like the guard working.
    """
    for platform, probes in cap.PROBES.items():
        scoped = set(probes) & cap.COMPOSER_SCOPED_KEYS
        if scoped:
            assert cap.COMPOSER_ANCHOR.get(platform), (
                f"{platform} has scoped keys {sorted(scoped)} but no composer anchor"
            )


def test_gemini_probes_use_the_hyphenated_attribute_everywhere(cap):
    """One un-migrated `data-testid` in Gemini's table is a silently dead probe."""
    flat = " ".join(
        probe for probes in cap.PROBES["gemini"].values() for probe in probes
    )
    assert "data-testid" not in flat.replace("data-test-id", "")


def test_chatgpt_and_claude_probes_use_the_unhyphenated_attribute(cap):
    """The converse: the fix must not have been applied where it is wrong."""
    for platform in ("chatgpt", "claude"):
        flat = " ".join(
            probe for probes in cap.PROBES[platform].values() for probe in probes
        )
        assert "data-test-id" not in flat, f"{platform} does not use the hyphenated spelling"


# --- indexed handles, and probes that are themselves handles ----------------------------------


def test_indexed_handles_are_rejected_by_the_describe_script(cap):
    """`conversation-turn-1` is stable across renders and still wrong: it means turn ONE.

    Measured with an answer on screen: `response_container` was proposed as
    `[data-testid="conversation-turn-1"]`, rank 1, unique, visible. Turn 2 onward would never match,
    so a multi-turn run harvests the opening exchange and reports success.
    """
    js = cap._DESCRIBE_JS
    assert "INDEXED" in js
    assert "!INDEXED.test(tid)" in js
    assert "!INDEXED.test(el.id)" in js


@pytest.mark.parametrize(
    "handle",
    ["conversation-turn-1", "mat-button-toggle-1-button", "message-2", "3-col"],
)
def test_the_indexed_pattern_matches_positional_handles(cap, handle):
    pattern = re.compile(r"(^|-)[0-9]+(-|$)")
    assert pattern.search(handle), f"{handle} should read as positional"


@pytest.mark.parametrize(
    "handle",
    ["send-button", "chat-input", "composer-plus-btn", "user-menu-button", "new-chat-button"],
)
def test_the_indexed_pattern_spares_real_handles(cap, handle):
    """The converse. A guard that also rejects the good values is not a guard, it is an outage."""
    pattern = re.compile(r"(^|-)[0-9]+(-|$)")
    assert not pattern.search(handle), f"{handle} must survive"


@pytest.mark.parametrize(
    "probe",
    ["[data-message-author-role=assistant]", "model-response", "message-content"],
)
def test_a_semantic_probe_is_itself_accepted_as_a_handle(cap, probe):
    assert cap.durable_probe(probe)


@pytest.mark.parametrize(
    "probe",
    [
        "a[href^=http]",
        '[data-testid*="conversation-turn"]',
        'button[aria-label*="research" i]',
        "cite",
        "audio",
        "div[contenteditable=true]",
    ],
)
def test_a_search_term_is_not_accepted_as_a_handle(cap, probe):
    """`a[href^=http]` in particular: that is how the Images nav link became a `sources` candidate."""
    assert not cap.durable_probe(probe)


def test_the_durable_probe_fallback_runs_after_the_described_candidates(cap):
    """A testid on the element must still beat the probe that found it."""
    hits = [
        {
            "probe": "[data-message-author-role=assistant]",
            "suggested": '[data-testid="better"]',
            "rank": 1,
            "why": "data-testid",
            "matches": 1,
            "visible": True,
        }
    ]
    entries = _draft(cap, {"response_container": hits}, response_present=True)
    assert entries["response_container"]["css"] == ['[data-testid="better"]']


def test_the_durable_probe_fallback_rescues_an_undescribable_element(cap):
    """An assistant turn has no testid, no id and no accessible name — the probe is the identity."""
    hits = [
        {
            "probe": "[data-message-author-role=assistant]",
            "suggested": None,
            "rank": 5,
            "why": "no stable attribute — text match only",
            "matches": None,
            "visible": True,
        }
    ]
    entries = _draft(cap, {"response_container": hits}, response_present=True)
    assert entries["response_container"]["css"] == ["[data-message-author-role=assistant]"]
    assert "semantic handle" in entries["response_container"]["provenance"]


def test_the_fallback_still_honours_the_post_response_refusal(cap):
    """Otherwise the new escape hatch reopens the door the post-response guard closed."""
    hits = [
        {"probe": "[data-message-author-role=assistant]", "suggested": None, "rank": 5,
         "why": "text", "matches": None, "visible": True}
    ]
    draft = cap.draft_manifest(
        {
            "platform": "chatgpt",
            "candidates": {"response_container": hits},
            "response": {"present": False},
        }
    )
    assert "response_container" not in draft["platforms"]["chatgpt"]


# --- the app's login markers must be absent when signed out ----------------------------------


def test_the_apps_gemini_login_marker_uses_the_hyphenated_attribute():
    """The same bug in the app would report every signed-out Gemini as signed in.

    Worse there than in the capture tool: a login the app believes it already has is a login the owner
    is never prompted for, so the first symptom is a run failing on a sign-in page.
    """
    source = (REPO / "ios" / "App" / "LoginFlow.swift").read_text()
    body = source.split("static func candidateMarkers", 1)[1].split("\n    }", 1)[0]
    gemini_line = [ln for ln in body.splitlines() if "data-test" in ln and "gemini" not in ln]
    joined = " ".join(gemini_line)
    assert "data-test-id=new-chat-button" in joined


def test_no_app_login_marker_is_one_measured_to_exist_when_signed_out():
    """The four values that surveyed as present on a signed-OUT page, named so they cannot return."""
    source = (REPO / "ios" / "App" / "LoginFlow.swift").read_text()
    body = source.split("static func candidateMarkers", 1)[1].split("\n    }", 1)[0]
    code = "\n".join(ln for ln in body.splitlines() if not ln.lstrip().startswith("//"))
    for present_when_signed_out in (
        "rich-textarea",
        "data-test-id=chat-app",
        "textarea-inner",
        "aria-label*=Notebook",
    ):
        assert present_when_signed_out not in code, (
            f"{present_when_signed_out} exists on a signed-out page — it cannot be a login marker"
        )


# --- the build script must not destroy a hand-made login -------------------------------------


def _shell_code_only(source: str) -> str:
    return "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )


def test_the_build_script_does_not_uninstall_unconditionally():
    """``simctl uninstall`` deletes the Data container — logins, API keys, pairing identity.

    Measured, not theorised: after a rebuild the app container had no ``Library/WebKit/WebsiteData``
    at all and all four platforms surveyed as signed out. It also terminates a foreground app, which
    is the "the app restarted by itself" symptom reported mid-pairing.
    """
    code = _shell_code_only((REPO / "bin" / "build_app.sh").read_text())
    assert "simctl uninstall" in code, "the --clean path should still be able to uninstall"
    # Every uninstall must sit after the --clean guard opens.
    guarded = code.split('if [ "$CLEAN" = "--clean" ]; then', 1)
    assert len(guarded) == 2, "the uninstall must be behind an explicit --clean guard"
    before_guard = guarded[0]
    assert "simctl uninstall" not in before_guard


def test_the_build_script_still_installs_over_the_top():
    code = _shell_code_only((REPO / "bin" / "build_app.sh").read_text())
    assert "simctl install" in code
