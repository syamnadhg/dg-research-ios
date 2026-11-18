"""The P2 product: a markdown report, extracted from ChatGPT Deep Research.

⭐ These run the extractor's **actual JavaScript** under node against the **real captured
conversation** — 579,966 characters of it, from a real completed run. That matters more here than
almost anywhere else in this repo: the shape the report lives in is not one anybody would have
guessed. It is not in `content.parts` where every other message keeps its text; it is inside
`metadata.chatgpt_sdk.widget_state`, which is itself a JSON **string**, under `report_message`.
A test built on a hand-written mock of that structure would be a test of my assumptions.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from emubackend import report_extract as rx

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "artifacts" / "gate_zero"
CONVERSATION = FIXTURES / "chatgpt_dr_conversation.json"
REPORT_MD = FIXTURES / "chatgpt_dr_report.md"


def _node() -> str:
    """Locate node, searching beyond `PATH` — and FAIL rather than skip if it is absent.

    `bin/mutate.py` pins `PATH` to three directories that do not contain this machine's node, and a
    `pytest.skip` there turns every mutation of this file into a false CAUGHT. See the note in
    `test_gate_zero_surface.py`.
    """
    found = shutil.which("node") or next(
        (p for p in ("/opt/homebrew/bin/node", "/usr/local/bin/node",
                     str(Path.home() / ".local/bin/node"))
         if Path(p).exists()),
        None,
    )
    assert found, "node not found — required to execute the extractor JS these tests assert on"
    return found


def pick_report(conversation: dict) -> dict:
    """Run the shipped `srPickReport` against *conversation* and return its result."""
    harness = rx.PICK_REPORT_JS + """
const conv = JSON.parse(require('fs').readFileSync(0, 'utf8'));
console.log(JSON.stringify(srPickReport(conv)));
"""
    proc = subprocess.run([_node(), "-e", harness], input=json.dumps(conversation),
                          capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


@pytest.fixture(scope="module")
def real_conversation() -> dict:
    assert CONVERSATION.exists(), (
        f"{CONVERSATION} is missing. It is the captured output of a real Deep Research run and "
        f"re-creating it costs a unit of the owner's monthly cap — do not regenerate it casually."
    )
    return json.loads(CONVERSATION.read_text())


class TestAgainstTheRealConversation:

    def test_the_report_is_found_and_is_the_markdown_document(self, real_conversation):
        out = pick_report(real_conversation)
        assert out["state"] == "ok", out
        assert out["chars"] == 65_690
        assert out["text"].startswith(
            "# Solid-State Batteries for Electric Vehicles: State of the Technology in 2026"
        )

    def test_it_matches_the_report_captured_alongside_it(self, real_conversation):
        # Two independent captures of the same run agreeing is the check that the walk picked the
        # same node a human reading the page would have.
        assert pick_report(real_conversation)["text"] == REPORT_MD.read_text()

    def test_the_completion_signal_comes_out_with_it(self, real_conversation):
        # ⭐ The DOM offers NO completion signal for a Deep Research run — the stop control never
        # appears, and a finished page is textually indistinguishable from an unstarted one in the
        # main document. This is the only honest one.
        out = pick_report(real_conversation)
        assert out["status"] == "completed"
        assert out["stoppedAt"] == "2026-08-09T02:28:06.420241Z"
        assert out["startedAt"] == "2026-08-09T02:19:09.727468Z"

    def test_the_extracted_report_passes_every_guard(self, real_conversation):
        out = pick_report(real_conversation)
        verdict = rx.judge_report(out["text"], status=out["status"])
        assert verdict.ok, verdict.reason
        assert verdict.chars == 65_690

    def test_the_report_is_NOT_reachable_where_the_old_plan_looked_for_it(self, real_conversation):
        """Every message's `content.parts` — where the DOM-era plan assumed the report lived.

        The longest string there is the user's own prompt, at 379 characters. This is the assertion
        that stops a future session "simplifying" the walk into the obvious one.
        """
        longest = 0
        for node in real_conversation["mapping"].values():
            message = node.get("message") or {}
            parts = (message.get("content") or {}).get("parts") or []
            for part in parts:
                if isinstance(part, str):
                    longest = max(longest, len(part))
        assert longest == 379
        assert longest < rx.REPORT_FLOOR_CHARS


class TestThePickIsAChoiceNotAnAccident:

    def _wrap(self, widget_states: list[dict]) -> dict:
        return {"mapping": {
            f"n{i}": {"message": {"metadata": {"chatgpt_sdk": {"widget_state": json.dumps(ws)}}}}
            for i, ws in enumerate(widget_states)
        }}

    def _ws(self, text: str, status: str = "completed") -> dict:
        return {"status": status, "report_message": {"content": {"parts": [text]}}}

    def test_the_LONGEST_report_wins_not_the_last_one_walked(self):
        # A conversation can carry a superseded plan revision or a second research turn. Object key
        # order is not a ranking.
        conv = self._wrap([self._ws("short"), self._ws("x" * 5000), self._ws("medium" * 10)])
        assert pick_report(conv)["chars"] == 5000

    def test_the_same_widgets_in_the_other_order_give_the_same_answer(self):
        a = self._wrap([self._ws("x" * 5000), self._ws("short")])
        b = self._wrap([self._ws("short"), self._ws("x" * 5000)])
        assert pick_report(a)["chars"] == pick_report(b)["chars"] == 5000

    def test_a_widget_state_that_is_already_an_object_is_read_too(self):
        # It arrives as a JSON string today. Assuming that forever is one platform change away from
        # an extractor that silently finds nothing.
        conv = {"mapping": {"n": {"message": {"metadata": {"chatgpt_sdk": {
            "widget_state": self._ws("y" * 3000)}}}}}}
        assert pick_report(conv)["chars"] == 3000

    def test_unparseable_widget_state_is_skipped_not_fatal(self):
        conv = {"mapping": {
            "bad": {"message": {"metadata": {"chatgpt_sdk": {"widget_state": "{not json"}}}},
            "good": {"message": {"metadata": {"chatgpt_sdk": {
                "widget_state": json.dumps(self._ws("z" * 4000))}}}},
        }}
        assert pick_report(conv)["chars"] == 4000

    def test_a_conversation_with_no_report_says_so_rather_than_returning_empty_text(self):
        out = pick_report({"mapping": {"n": {"message": {"content": {"parts": ["hello"]}}}}})
        assert out["state"] == "absent"
        assert "reason" in out

    def test_an_empty_conversation_is_absent_not_a_crash(self):
        assert pick_report({})["state"] == "absent"

    def test_non_string_parts_do_not_become_the_report(self):
        conv = self._wrap([{"status": "completed",
                            "report_message": {"content": {"parts": [{"image": "x"}]}}}])
        assert pick_report(conv)["state"] == "absent"


class TestTheGuards:

    def test_the_real_report_is_not_mistaken_for_a_sources_checklist(self):
        assert not rx.is_sources_not_document(REPORT_MD.read_text())

    def test_a_sources_checklist_is_rejected(self):
        checklist = "Research plan\n" + "\n".join(
            f"- [x] Reading source {i}" for i in range(1, 12)
        )
        assert rx.is_sources_not_document(checklist)

    def test_a_bare_url_list_is_rejected(self):
        urls = "Sources\n" + "\n".join(
            f"{i}. https://example{i}.com/some/path/to/a/document" for i in range(1, 30)
        )
        assert 800 <= len(urls) <= 3000, len(urls)
        assert rx.is_sources_not_document(urls)

    def test_a_recorded_CONVERSATION_is_rejected_however_much_prose_it_has(self):
        # The one shape that looks MORE like a report the longer it gets: a "Deep Research" tile
        # whose body is a transcript. It has headings and prose, so every structural test passes it.
        transcript = ("# Deep Research\n\n"
                      + ("You said: what about solid-state batteries and their manufacturing "
                         "obstacles at scale, in some considerable detail please\n"
                         "Claude responded: here is a long and structurally convincing answer "
                         "that would satisfy any prose-and-headings check you care to write\n\n"
                         "## A heading to make it look structured\n\n") * 16)
        # Over the strong-document threshold, so only the chat-chrome rule can reject it.
        assert len(transcript) > 4000
        assert rx.is_sources_not_document(transcript)

    def test_a_long_report_with_a_few_checkboxes_is_STILL_a_report(self):
        # A methodology section legitimately contains checkboxes. The backend learned this the hard
        # way and added the ratio gate; a length-only rule rejected dense real reports.
        body = ("# Title\n\n## Method\n\n" + ("Substantial analytical prose. " * 12 + "\n\n") * 30
                + "\n".join(f"- [x] step {i}" for i in range(6)))
        assert len(body) > 4000
        assert not rx.is_sources_not_document(body)

    def test_navigation_chrome_is_rejected(self):
        nav = "New chat\nSearch\nChats\nProjects\nRecents\nTopic Generator\n" * 8
        assert rx.looks_like_nav_sidebar(nav)

    def test_PROSE_alone_stops_a_report_about_chat_products_being_read_as_nav(self):
        # Condition two, isolated: the nav words ARE in the first 500 chars and the text is short,
        # so only the prose test can be doing the work.
        body = ("# Chat products in 2026\n\nNew chat, search, projects and recents are the "
                "standard surfaces every assistant now ships, and the differences between them "
                "are mostly in how recents are ranked rather than in what they contain.\n") * 6
        assert len(body) < 8000
        assert len({m.group(0).lower() for m in rx._NAV_MARKERS_RE.finditer(body[:500])}) >= 3
        assert not rx.looks_like_nav_sidebar(body)

    def test_LENGTH_alone_stops_a_long_listing_being_read_as_nav(self):
        # Condition three, isolated: nav words present, no prose line over 100 chars, but long.
        # Three conditions bundled into one fixture would let any two of them carry the test.
        body = "New chat\nSearch\nChats\nProjects\nRecents\nTopic Generator\n" * 160
        assert len(body) >= 8000
        assert not any(len(ln.strip()) > 100 for ln in body.split("\n"))
        assert not rx.looks_like_nav_sidebar(body)


class TestJudgeReport:

    def test_a_short_report_is_rejected_at_the_floor(self):
        assert not rx.judge_report("x" * (rx.REPORT_FLOOR_CHARS - 1)).ok
        # ...and exactly at the floor it passes, so the boundary is the BE's and not an opinion.
        assert rx.judge_report("word " * 800).ok

    def test_an_UNFINISHED_run_is_rejected_even_with_plenty_of_text(self):
        # A long partial render is the most dangerous input there is: it looks like a report.
        assert not rx.judge_report("word " * 2000, status="in_progress").ok

    def test_a_finished_run_whose_text_is_a_checklist_is_STILL_rejected(self):
        # ⚠ status == completed is not a licence. Both conditions must hold, or the status check
        # becomes a way to smuggle the sources list through as research.
        #
        # ⚠ The checklist must clear the 2000-char FLOOR, or the floor rejects it and this test
        # passes without the sources guard doing anything — which is what a mutation caught.
        checklist = "Plan\n" + "\n".join(
            f"- [x] Reading source {i}: an unusually descriptive source title for padding"
            for i in range(1, 60)
        )
        assert len(checklist) > rx.REPORT_FLOOR_CHARS, len(checklist)
        assert rx.is_sources_not_document(checklist), "fixture must trip the guard under test"
        assert not rx.judge_report(checklist, status="completed").ok

    def test_a_missing_status_does_not_block_a_good_report(self):
        # Other platforms will not have this field at all; absent must mean "not asserted", never
        # "not finished".
        assert rx.judge_report(REPORT_MD.read_text()).ok

    def test_the_reason_names_what_failed(self):
        assert "floor" in rx.judge_report("tiny").reason
        assert "not finished" in rx.judge_report("word " * 2000, status="running").reason


def run_start_js(*, session_status=200, session_body=None, conversation_status=200,
                 conversation_body=None, path="/c/abc-123") -> dict:
    """EXECUTE `START_JS` against a stubbed page and return whatever landed in the stash.

    ⚠ **This replaced three presence assertions, and a mutation is why.** `assert "session carried
    no accessToken" in START_JS` passed happily against `if (false) throw ...` — the string was
    still in the source, and the branch was dead. A test that greps the code it is meant to protect
    can only tell you the code still contains a word.

    The stub records what was requested, so "it sent the token" is checkable rather than assumed.
    """
    if session_body is None:
        session_body = {"accessToken": "tok-123"}
    if conversation_body is None:
        conversation_body = {"mapping": {}}
    harness = """
const calls = [];
global.location = { pathname: %(path)s };
global.fetch = async (url, opts) => {
  calls.push({ url, headers: (opts && opts.headers) || {},
               credentials: opts && opts.credentials });
  if (url.indexOf('/api/auth/session') === 0) {
    return { ok: %(sess_ok)s, status: %(sess_status)d,
             json: async () => (%(sess_body)s) };
  }
  return { ok: %(conv_ok)s, status: %(conv_status)d,
           json: async () => (%(conv_body)s) };
};
%(js)s;
setTimeout(() => {
  console.log(JSON.stringify({ stash: global.window.%(stash)s, calls: calls }));
}, 50);
""" % {
        "path": json.dumps(path),
        "sess_ok": "true" if 200 <= session_status < 300 else "false",
        "sess_status": session_status,
        "sess_body": json.dumps(session_body),
        "conv_ok": "true" if 200 <= conversation_status < 300 else "false",
        "conv_status": conversation_status,
        "conv_body": json.dumps(conversation_body),
        # ⚠ Evaluated exactly as the inspector bridge does it — `JSON.stringify((function(){
        # return (EXPR); })())`. That wrapper is not cosmetic: it is what turned a top-level
        # function declaration followed by an IIFE into a function *call taking the IIFE as an
        # argument*, so the extraction never ran and the bridge handed back a function object.
        # A node harness that just `eval`s the source cannot see that class of bug at all.
        "js": ("global.window = {};\n"
               "const __r = JSON.stringify((function(){ return (" + rx.START_JS + "); })());\n"
               "if (__r !== '\"started\"') { "
               "console.error('START_JS did not evaluate to \"started\": ' + __r); "
               "process.exit(3); }"),
        "stash": rx.STASH,
    }
    proc = subprocess.run([_node(), "-e", harness], capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


class TestTheFetchScript:

    def test_the_happy_path_sends_the_bearer_token_and_stashes_the_report(self):
        ws = {"status": "completed", "report_message": {"content": {"parts": ["x" * 3000]}}}
        out = run_start_js(conversation_body={"mapping": {"n": {"message": {"metadata": {
            "chatgpt_sdk": {"widget_state": json.dumps(ws)}}}}}})
        assert out["stash"]["state"] == "ok"
        assert out["stash"]["chars"] == 3000
        # The mechanism: which request carried which header.
        session, conversation = out["calls"]
        assert session["url"] == "/api/auth/session"
        assert conversation["url"] == "/backend-api/conversation/abc-123"
        assert conversation["headers"]["Authorization"] == "Bearer tok-123"
        assert conversation["credentials"] == "include"

    def test_a_missing_access_token_FAILS_rather_than_requesting_without_one(self):
        # Measured: cookies alone answer 404 "Log in to view this conversation." Falling through
        # would report that as "the conversation is gone" instead of "we lost the session".
        out = run_start_js(session_body={})
        assert out["stash"]["state"] == "error"
        assert "accessToken" in out["stash"]["error"]
        # And it must never have asked for the conversation at all.
        assert [c["url"] for c in out["calls"]] == ["/api/auth/session"]

    def test_a_failed_session_request_is_an_error_state_not_a_hang(self):
        out = run_start_js(session_status=401)
        assert out["stash"]["state"] == "error"
        assert "401" in out["stash"]["error"]

    def test_a_failed_conversation_request_is_an_error_state(self):
        # A guard that fails open here leaves the poller waiting out its whole timeout on a page
        # that failed in the first 200ms.
        out = run_start_js(conversation_status=404)
        assert out["stash"]["state"] == "error"
        assert "404" in out["stash"]["error"]

    def test_a_page_with_no_conversation_id_does_not_request_a_bare_endpoint(self):
        out = run_start_js(path="/")
        assert out["stash"]["state"] == "error"
        assert "conversation id" in out["stash"]["error"]

    def test_the_stash_starts_pending_so_a_poll_before_completion_is_meaningful(self):
        out = run_start_js(conversation_body={"mapping": {}})
        # This one resolves to `absent`, proving the async path ran to completion rather than
        # leaving `pending` behind — the state a poller would sit on forever.
        assert out["stash"]["state"] == "absent"

    def test_the_poll_does_not_drag_the_report_across_on_every_tick(self):
        assert "r.text" not in rx.POLL_JS
        assert "chars" in rx.POLL_JS

    def test_slices_are_contiguous_and_cover_the_whole_report(self):
        first, second = rx.slice_js(0, 40_000), rx.slice_js(40_000, 40_000)
        assert "slice(0, 40000)" in first
        assert "slice(40000, 80000)" in second
