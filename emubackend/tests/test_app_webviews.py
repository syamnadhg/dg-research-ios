"""Source-level invariants of the app's two web-view surfaces — the login sheet and the live run view.

These are asserted against the Swift source from Python for the same reason
``test_the_swift_and_python_registries_agree`` is: the app sources are not in the SwiftPM package (they
need an app bundle and a WebProcess host, which ``swift test`` does not provide), so a real Swift unit
test is not available for them without an Xcode project. The properties below are nonetheless
*structural* — they hold or fail by reading the code — so they are checkable here, and checking them
here is strictly better than not checking them.

The bug that motivated the first group is worth stating plainly, because it is the kind that survives
review: ``LivePlatformWebView.makeUIView`` originally returned the cached ``WKWebView`` directly, with
an empty ``updateUIView``. That compiles, reads correctly, and silently never switches tabs — SwiftUI
calls ``makeUIView`` once per representable identity and thereafter only ``updateUIView``. Tapping GEM
in the Simulator kept rendering ChatGPT. No unit test of the cache would have caught it; the defect
was in the lifecycle contract, not the logic.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
APP = REPO / "ios" / "App"
LIVE = APP / "LiveRunView.swift"
LOGIN = APP / "LoginFlow.swift"


def _code_only(source: str) -> str:
    """Strip comments, so a prohibition can be asserted without the prose that explains it matching.

    Found the honest way: the first version of ``test_no_ephemeral_data_store_anywhere`` failed on the
    doc comment that says *never use* ``.nonPersistent()``. A grep-shaped test that cannot tell code
    from commentary reports the documentation of a rule as a violation of it.
    """
    without_blocks = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return "\n".join(
        line for line in without_blocks.splitlines() if not line.lstrip().startswith("//")
    )


def _body_of(source: str, signature_fragment: str) -> str:
    """Return the brace-balanced body of the first function whose signature contains the fragment.

    Brace-counted rather than regex-matched: a regex for a Swift function body either stops at the
    first ``}`` (wrong) or needs recursion Python's ``re`` does not have.
    """
    start = source.index(signature_fragment)
    open_brace = source.index("{", start)
    depth = 0
    for i in range(open_brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace + 1 : i]
    raise AssertionError(f"unbalanced braces after {signature_fragment!r}")


# ======================================================================================
# the tab-switching regression
# ======================================================================================


def test_the_live_web_view_representable_does_not_return_the_web_view_itself():
    """The exact regression. Returning the cached ``WKWebView`` from ``makeUIView`` pins the

    displayed page to whichever platform happened to be selected first.
    """
    text = LIVE.read_text(encoding="utf-8")
    match = re.search(r"func makeUIView\(context: Context\) -> (\w+)", text)
    assert match, "could not find makeUIView in LiveRunView.swift — did its shape change?"
    assert match.group(1) != "WKWebView", (
        "makeUIView returns the cached WKWebView directly. SwiftUI calls makeUIView once per "
        "representable identity, so the displayed page can then never change and tab switching "
        "silently does nothing. Return a container and re-parent in updateUIView."
    )


def test_the_live_web_view_actually_reparents_on_update():
    """An empty ``updateUIView`` is the other half of the same bug."""
    body = _body_of(LIVE.read_text(encoding="utf-8"), "func updateUIView(_ container:")
    assert "PlatformWebViews.shared.view(for: platform, worker: workerID)" in body, (
        "updateUIView must resolve the web view for the *current* platform AND worker — that call is "
        "what makes a tab switch change what is on screen. The worker half matters just as much now "
        "that each worker is its own browser profile: resolving without it would show worker 1's "
        "session while claiming to show worker 2's."
    )
    assert "addSubview" in body, "the resolved view must be attached to the container"


def test_reparenting_is_guarded_so_it_does_not_thrash():
    """SwiftUI calls ``updateUIView`` on unrelated state changes too — the run's clock ticks every

    second. Re-attaching the view each time would restart layout, and constraints would accumulate.
    """
    body = _body_of(LIVE.read_text(encoding="utf-8"), "func updateUIView(_ container:")
    assert "superview !== container" in body, (
        "updateUIView must early-return when the right view is already attached"
    )


def test_the_live_view_pins_the_web_view_with_constraints():
    """Autoresizing would clip rather than resize the page when the keyboard or an inset changes —

    the same class of mistake as reading ``innerHeight`` while the keyboard is up.
    """
    body = _body_of(LIVE.read_text(encoding="utf-8"), "func updateUIView(_ container:")
    for anchor in ("topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor"):
        assert anchor in body, f"missing {anchor} constraint"
    assert "translatesAutoresizingMaskIntoConstraints = false" in body


# ======================================================================================
# the session must survive being off screen, and being backgrounded
# ======================================================================================


@pytest.mark.parametrize("path", [LIVE, LOGIN])
def test_no_ephemeral_data_store_anywhere(path):
    """``.nonPersistent()`` would lose the platform login on teardown, which presents *identically*

    to the platform having signed the user out — the same symptom class as shutting a Simulator down
    before its cookie flush. It must never appear.
    """
    code = _code_only(path.read_text(encoding="utf-8"))
    assert "nonPersistent" not in code, f"{path.name} uses an ephemeral data store"
    # ⚠ The anchor moved when workers became browser profiles. Each surface used to write
    # `websiteDataStore = .default()` inline; both now route through `WorkerDataStores`, which is
    # where the persistence decision lives — including the rule that worker 1 KEEPS `.default()` so
    # the owner's existing hand-made logins survive. Asserting the old literal here would have made
    # this test demand the very duplication the refactor removed.
    assert "websiteDataStore = WorkerDataStores.store(" in code, (
        f"{path.name} must resolve its data store through WorkerDataStores, which is the only place "
        "that decides persistence and per-worker isolation"
    )


def test_the_store_resolver_itself_is_persistent_and_isolates_workers():
    """The file the two surfaces now delegate to — so the rule is checked where it is decided.

    Moving the decision into one place is only an improvement if that place is also guarded;
    otherwise the refactor just moved an unchecked line somewhere the old test could not see it.
    """
    stores = APP / "WorkerDataStores.swift"
    assert stores.exists(), "WorkerDataStores.swift is where persistence is decided"
    code = _code_only(stores.read_text(encoding="utf-8"))
    assert "nonPersistent" not in code, "an ephemeral store loses every platform login on teardown"
    assert ".default()" in code, (
        "worker 1 MUST keep the default store. Giving it an identified store like the others would "
        "be tidier and would sign the device out of every platform on the first launch after the "
        "update, with no error and nothing in any log — the cookies are still on disk, WebKit is "
        "simply looking somewhere else."
    )
    assert "WKWebsiteDataStore(forIdentifier:" in code, (
        "workers 2+ need their own identified stores, or 'worker' is a label rather than a profile"
    )


def test_the_web_view_cache_is_a_cache_and_not_a_factory():
    """If ``view(for:)`` built a new web view per call, every tab switch would abort a phase."""
    body = _body_of(
        LIVE.read_text(encoding="utf-8"), "func view(for platform: String, worker: Int = 1)"
    )
    assert "if let existing = views[key] { return existing }" in body, (
        "view(for:worker:) must return the retained instance rather than constructing a new one"
    )
    assert 'let key = "\\(worker)/\\(platform)"' in body, (
        "the cache key must include the WORKER. Keyed by platform alone — as it was — every worker "
        "shares one web view per platform, so two concurrent runs drive the same page and the whole "
        "point of separate browser profiles is lost."
    )


def test_the_live_view_is_read_only_until_the_user_takes_over():
    """A stray tap during a run is trusted input competing with the automation for the composer."""
    text = LIVE.read_text(encoding="utf-8")
    assert "@State private var interactive = false" in text, "must default to read-only"
    assert "allowsHitTesting(interactive)" in text, "the gate must actually be applied"


# ======================================================================================
# login is confirmed by observation, never by a tap
# ======================================================================================


def test_signed_in_is_only_ever_concluded_from_an_observed_marker():
    """The whole correctness property of the login sheet.

    Concluding "signed in" from the user tapping *Done* would record a half-finished 2FA as success,
    and the run would then fail much later with a symptom that points nowhere near the login.
    """
    text = _code_only(LOGIN.read_text(encoding="utf-8"))
    occurrences = re.findall(r"onStatus\(\.signedIn\)", text)
    assert len(occurrences) == 1, (
        f"expected exactly one place that concludes signed-in, found {len(occurrences)}"
    )
    guarded = _body_of(text, "if present == true {")
    assert "onStatus(.signedIn)" in guarded, (
        "the single signed-in conclusion must sit inside the `present == true` branch"
    )


def test_the_embedded_web_view_block_is_a_distinct_state():
    """Google's OAuth refusal is served as an ordinary page, so there is no status to catch — only

    text to read. It needs its own state because no amount of user action in the sheet fixes it.
    """
    text = LOGIN.read_text(encoding="utf-8")
    assert "case blockedByPlatform(String)" in text
    assert "disallowed_useragent" in text


def test_a_safari_like_user_agent_is_set_on_both_surfaces():
    """Matched as an *assignment*, not as a substring.

    Mutation testing caught the substring version passing: renaming the property to
    ``customUserAgentDISABLED`` still contains ``customUserAgent``, so the test approved a build with
    no UA override at all — which is precisely the state that makes Google refuse OAuth.
    """
    for path in (LOGIN, LIVE):
        code = _code_only(path.read_text(encoding="utf-8"))
        assert re.search(r"\.customUserAgent\s*=", code), f"{path.name} must override the UA"
        assert "Safari/604.1" in code, f"{path.name}'s UA must look like mobile Safari"


# ======================================================================================
# cross-language drift, again
# ======================================================================================


def _swift_case_strings(body: str) -> dict[str, str]:
    """Map each ``case "<name>":`` to its returned string, joining concatenated literals.

    The first version was a single regex, ``case "(\\w+)": return "([^"]*)"``, and it silently
    returned *nothing* for two platforms once their markers grew past one line — the mirror check then
    compared a two-entry dict against a four-entry one and reported drift where there was none, while
    real drift in the two it could not see would have gone unnoticed. Escaped quotes matter for the
    same reason: NotebookLM's marker is ``button[aria-label=\\"Create new notebook\\"]``.
    """
    out: dict[str, str] = {}
    current: str | None = None
    for line in body.splitlines():
        # Comments are skipped, or the prose explaining a marker becomes part of it — the parser
        # happily concatenated the phrase from a `// … "can I see it"` note onto ChatGPT's selector.
        if line.lstrip().startswith("//"):
            continue
        case = re.match(r'\s*case "(\w+)"', line)
        if case:
            current = case.group(1)
            out.setdefault(current, "")
        if current is None:
            continue
        for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', line.split("case", 1)[-1]):
            if literal == current:
                continue
            out[current] += literal.replace('\\"', '"')
    return out


def test_the_swift_fallback_markers_match_the_python_probe_candidates():
    """A third hand-maintained mirror, so a third drift check.

    The app's fallback markers exist so a login can be *confirmed* before the owner-gated selector
    capture has run. If they drift from ``bin/capture_selectors.py``, the app and the pipeline
    disagree about what "logged in" looks like — and the app's copy is the one a human sees, so the
    disagreement would be read as the pipeline being wrong.
    """
    from importlib.util import module_from_spec, spec_from_file_location

    spec = spec_from_file_location("capture_selectors", REPO / "bin" / "capture_selectors.py")
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)

    swift = LOGIN.read_text(encoding="utf-8")
    body = _body_of(swift, "static func candidateMarkers(for platform: String)")
    swift_markers = _swift_case_strings(body)

    expected = {
        platform: ", ".join(probes["logged_in_marker"])
        for platform, probes in module.PROBES.items()
    }
    assert swift_markers == expected, (
        "the app's fallback logged-in markers drifted from bin/capture_selectors.py.\n"
        f"  Swift:  {swift_markers}\n  Python: {expected}"
    )


def test_every_platform_the_app_shows_has_a_login_url_and_markers():
    """A platform row with no URL would open an empty sheet — a dead end with no explanation."""
    login = LOGIN.read_text(encoding="utf-8")
    urls = _body_of(login, "static func url(for platform: String)")
    markers = _body_of(login, "static func candidateMarkers(for platform: String)")
    for platform in ("chatgpt", "gemini", "claude", "notebooklm"):
        assert f'case "{platform}"' in urls, f"{platform} has no login URL"
        assert f'case "{platform}"' in markers, f"{platform} has no fallback marker"
