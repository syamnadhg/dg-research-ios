"""P3's contract, and the measured facts that removed its blocking question."""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from emubackend import notebook

REPO = Path(__file__).resolve().parents[2]


def _node() -> str:
    found = shutil.which("node") or next(
        (p for p in ("/opt/homebrew/bin/node", "/usr/local/bin/node",
                     str(Path.home() / ".local/bin/node"))
         if Path(p).exists()),
        None,
    )
    assert found, "node not found — required to execute the readiness probe under test"
    return found


def run_ready_probe(*, body: str, buttons: list[dict], has_audio_el: bool) -> dict:
    """EXECUTE the shipped readiness JS against a stub page."""
    harness = """
const fixture = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const els = fixture.buttons.map(b => ({
  getAttribute: (n) => (n === 'aria-label' ? (b.label || null) : null),
  innerText: b.text || '',
}));
global.document = {
  body: { innerText: fixture.body },
  querySelector: (sel) => (fixture.hasAudioEl && sel.indexOf('audio') === 0 ? {} : null),
  querySelectorAll: (sel) => (sel.indexOf('button') === 0 ? els : []),
};
console.log(JSON.stringify(%s));
""" % notebook.AUDIO_READY_JS.strip()
    payload = json.dumps({"body": body, "buttons": buttons, "hasAudioEl": has_audio_el})
    proc = subprocess.run([_node(), "-e", harness], input=payload,
                          capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


class TestTheMeasuredFacts:
    """The two names that break every selector keyed on the old ones."""

    def test_the_host_is_notebook_not_notebooklm(self):
        # Measured: the page is on notebook.google.com. A page LOOKUP matches the host of an
        # already-open page and never sees the pre-redirect one, so the old host finds nothing —
        # which presents as "the platform is signed out".
        assert notebook.HOST == "notebook.google.com"
        assert "notebooklm" not in notebook.HOST

    def test_the_source_type_is_the_pasted_one(self):
        # The blocking question's answer: a first-class "Copied text" source, so no document picker.
        assert notebook.SOURCE_TYPE_TEXT == "Copied text"


class TestTheNotebookTitle:

    def test_the_notebook_is_named_after_the_topic(self):
        assert notebook.notebook_title("solid-state batteries") == "solid-state batteries"

    def test_whitespace_is_collapsed_rather_than_carried_into_the_title(self):
        assert notebook.notebook_title("  a   b \n c ") == "a b c"

    def test_a_long_topic_is_truncated_rather_than_rejected(self):
        title = notebook.notebook_title("x" * 500)
        assert len(title) == 100

    def test_an_EMPTY_topic_is_refused_rather_than_left_untitled(self):
        # Every P3 run creates a PERMANENT notebook in a real account with no cleanup step
        # anywhere. An account accumulating "Untitled note" entries is a real cost.
        for empty in ("", "   ", "\n\t"):
            with pytest.raises(notebook.NotebookError):
                notebook.notebook_title(empty)


class TestTheSourceText:

    def test_the_consolidated_report_is_what_gets_pasted(self):
        body = "# Consolidated\n\n" + ("prose " * 100)
        assert notebook.source_text("t", body) == body.strip()

    def test_a_TOO_SHORT_consolidated_report_is_REFUSED(self):
        # Generating a ninety-minute audio overview from a stub produces a podcast about nothing —
        # and it cannot be undone or re-run cheaply.
        with pytest.raises(notebook.NotebookError) as exc:
            notebook.source_text("t", "# Consolidated Research Report: t\n")
        assert "podcast about nothing" in str(exc.value)

    def test_an_EMPTY_consolidated_report_is_refused(self):
        with pytest.raises(notebook.NotebookError):
            notebook.source_text("t", "")


class TestAudioReadiness:
    """⚠ Asymmetric on purpose: a false "ready" reports a podcast that does not exist; a false
    "not ready" costs more waiting."""

    def test_a_player_element_means_ready(self):
        state = run_ready_probe(body="Audio Overview", buttons=[], has_audio_el=True)
        assert state["ready"] is True
        assert notebook.audio_is_ready(state)

    def test_a_play_control_means_ready(self):
        state = run_ready_probe(
            body="Audio Overview", buttons=[{"label": "Play"}], has_audio_el=False
        )
        assert state["ready"] is True

    def test_the_WORDS_Audio_Overview_alone_do_NOT_mean_ready(self):
        # The card carries that text from the moment it is created, long before anything can play.
        # This is the whole reason the probe asks for a control rather than for text.
        state = run_ready_probe(body="Audio Overview", buttons=[], has_audio_el=False)
        assert state["ready"] is False

    def test_a_player_that_is_still_GENERATING_is_not_ready(self):
        # Both signals can be true at once while the card renders its own progress.
        state = run_ready_probe(
            body="Audio Overview generating your overview", buttons=[{"label": "Play"}],
            has_audio_el=True,
        )
        assert state["ready"] is False
        assert state["generating"] is True

    def test_an_unrelated_button_beginning_with_play_does_not_count(self):
        # "Playlist" starts with "play" as a substring. The check is the whole word or a "play …"
        # label, not a prefix match on the raw string.
        state = run_ready_probe(
            body="Audio Overview", buttons=[{"label": "Playlist settings"}], has_audio_el=False
        )
        assert state["ready"] is False

    def test_an_UNREADABLE_probe_is_not_ready(self):
        # A guard that fails open here reports a podcast the run does not have.
        assert notebook.audio_is_ready(None) is False
        assert notebook.audio_is_ready("nonsense") is False
        assert notebook.audio_is_ready({}) is False


class TestTheVariantTableAgreesWithTheDeviceHalf:
    """One table, two implementations — the shape that drifts.

    ⚠ Asserted by READING the Swift source rather than by restating the values here. A second copy
    of the literals in this file would agree with itself for ever while the device picked something
    else entirely.
    """

    SWIFT = (
        Path(__file__).resolve().parents[2]
        / "ios/Sources/SuperResearchDeviceCore/AudioLength.swift"
    )

    def test_short_is_the_BRIEF_format_with_no_length_step_on_both_sides(self):
        source = self.SWIFT.read_text()
        assert notebook.AUDIO_VARIANTS["short"] == ("Brief", None)
        # ⛔ `short` selects a different FORMAT tile. Treating it as a shorter Deep Dive generates
        # the wrong format, and hunting for its non-existent length control stalls the step.
        assert 'self == .short ? "Brief" : "Deep Dive"' in source, (
            "the Swift format table no longer matches the backend's measured variant table"
        )
        assert "case .short: return nil" in source

    def test_the_two_deep_dive_lengths_agree(self):
        source = self.SWIFT.read_text()
        assert notebook.AUDIO_VARIANTS["default"] == ("Deep Dive", "Default")
        assert notebook.AUDIO_VARIANTS["long"] == ("Deep Dive", "Long")
        assert 'case .default: return "Default"' in source
        assert 'case .long: return "Long"' in source

    def test_the_MEASURED_readiness_predicate_is_the_same_on_both_sides(self):
        """The player-based fallback is not sufficient on its own — the live panel has no
        `<audio>` element at all, which is why the desktop's own DOM-complete check could never
        fire."""
        swift = (
            Path(__file__).resolve().parents[2]
            / "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift"
        ).read_text()
        for marker in ("artifact-library-item", "audio_magic_eraser",
                       "generating audio overview"):
            assert marker in notebook.AUDIO_COMPLETE_JS, marker
            assert marker in swift, f"the device half lost {marker!r}"
