#!/usr/bin/env python3
"""Capture candidate mobile selectors from a logged-in page in the Simulator.

The point of this tool is to make the one owner-gated step cheap. Once a platform is signed in,
the remaining work is 25 named values in a JSON file — and finding them by hand means reading
minified mobile DOM in a 402pt-wide viewport. This dumps ranked candidates instead, so the login
converts directly into a draft manifest.

It is also phase A2 in embryo: the recipe's plan is that the offline repair agent *generates*
``selectors_mobile.json`` from captured Simulator DOM rather than anyone hand-deriving hundreds of
entries. This is the capture half of that, and its output is the agent's input.

**It proposes; it does not decide.** Output goes to a draft file with a ``provenance`` of
``captured`` and a confidence note per candidate, because a plausible-looking wrong selector is the
expensive failure here — it produces the P1 shape, where every click lands and extraction returns
nothing. A human (or the agent, gated) promotes a draft entry into the real manifest.

Ranking prefers what survives a redesign, in this order:
  1. ``data-testid`` — put there for automation, changed deliberately
  2. a stable ``id``
  3. ARIA role plus accessible name — semantic, and what the platform's own a11y tests rely on
  4. a tag + attribute combination
  5. text content — last, because it breaks on any copy or i18n change

Usage:
    python bin/capture_selectors.py --udid <UDID> --platform chatgpt --url https://chatgpt.com
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import selectors as sel  # noqa: E402
from emubackend.substrate import iwdp, runtime_js  # noqa: E402

# What to look for per manifest key: CSS probes plus the accessible-name hints that usually
# identify the control on mobile. Hints are *search terms*, not selectors — they narrow the
# candidate set so a human reviews five elements instead of five hundred.
# ⚠ Rewritten from real signed-in DOM (surveyed through the app's own web views, which are the only
# signed-in surface on this device) plus a signed-out survey of each platform in Safari to diff
# against. The original table was written before any real page had been seen, and almost none of it
# matched: ChatGPT has no `[data-testid*=composer]` at all, Claude's composer is
# `[data-testid=chat-input]` rather than a bare `.ProseMirror`, and NotebookLM ships **no testids
# whatsoever** (Angular Material — `mat-button-toggle`, `mat-menu`, icon-font labels), so it can only
# be addressed by accessible name.
#
# `aria-label` matches carry the CSS case-insensitivity flag (`[aria-label*="send" i]`). Without it
# `*=Send` and `*=send` are two different probes for one control, which is how the first table came to
# list both and still miss "Send message".
PROBES: dict[str, dict[str, list[str]]] = {
    "chatgpt": {
        # Signed-in only, both of them: the anonymous shell renders `wm-`-prefixed classes and no
        # testids, and has neither `#prompt-textarea` nor `composer-plus-btn`.
        "logged_in_marker": ["#prompt-textarea", "[data-testid=composer-plus-btn]"],
        "composer": ["#prompt-textarea", "div[contenteditable=true]"],
        # ⚠ Not present at idle. ChatGPT renders the send control only once the composer is non-empty;
        # at rest the same slot holds dictation and voice. So this key needs the *typed* pass.
        "send": [
            "[data-testid=send-button]",
            "#composer-submit-button",
            'button[aria-label*="send" i]',
        ],
        # ⚠ Also not present at idle: on mobile the research option lives *inside* the
        # `composer-plus-btn` ("Add files and more") menu, so this needs the menu open.
        #
        # `composer-plus-btn` is deliberately NOT listed as a fallback here, though it is tempting
        # because it is the only always-present control in that area. It was listed once, and the
        # capture duly accepted it: `deep_research_toggle -> [data-testid="composer-plus-btn"]`, a
        # rank-1 unique visible match that would have made "enable deep research" *open a menu* and
        # report success. A gap that says "needs the menu pass" is worth more than a value that runs.
        "deep_research_toggle": [
            '[data-testid*="research" i]',
            'button[aria-label*="research" i]',
        ],
        "activity_panel": ['[data-testid*="activity" i]', '[aria-label*="activity" i]'],
        "sources": ['[data-testid*="source" i]', "cite", "a[href^=http]"],
        "response_container": ["[data-message-author-role=assistant]", "[data-testid*=conversation-turn]"],
    },
    "gemini": {
        # ⚠ The one that mattered most. `chat-app`, `textarea-inner`, `textarea-wrapper`,
        # `bard-mode-menu-button` and `mavatar-footer-settings-button` are ALL present on the
        # signed-OUT page, so every "obvious" marker here is a false positive. These two are not.
        # ⚠ `data-test-id`, hyphenated — Gemini's spelling differs from ChatGPT's and Claude's.
        "logged_in_marker": [
            "[data-test-id=new-chat-button]",
            "[data-test-id=all-conversations]",
            "[data-test-id=my-stuff-side-nav-entry-button]",
        ],
        "composer": [
            "[data-test-id=textarea-inner] div[contenteditable=true]",
            'div[contenteditable=true][aria-label*="prompt" i]',
            "rich-textarea div[contenteditable=true]",
        ],
        "send": ['button[aria-label*="send" i]', '[data-test-id*="send" i]'],
        # ⚠ Deliberately EMPTY of the mode-picker button, and the reason is a contract mismatch rather
        # than a missing value.
        #
        # Deep Research on Gemini is a **mode**, not a toggle: `bard-mode-menu-button` ("Open mode
        # picker, currently Gemini") opens a picker from which Deep Research is chosen — two steps. But
        # `phases.py` treats this key as one tap judged by `aria-pressed`/`aria-checked`
        # (`_toggle_on_predicate`), and a menu opener carries neither. Captured here, the run would:
        # tap it, open a menu, read no pressed state, fail the predicate, correctly decline to
        # escalate (toggles are shadow-only without a positive off-signal) — and then complete a full
        # P0–P3 with deep research **off** while reporting success. Precisely the failure
        # `enable_deep_research`'s idempotence guard was written to prevent, arriving by a different
        # door.
        #
        # So this stays a gap until either the picker's Deep Research *item* is captured (it exists
        # only with the menu open) or the phase grows a mode-select shape. A gap fails loudly at the
        # first use; the value fails silently on every run.
        "deep_research_toggle": [
            '[data-test-id*="deep-research" i]',
            'button[aria-pressed][aria-label*="research" i]',
        ],
        "start_research": ['button[aria-label*="start" i]', 'button[aria-label*="research" i]'],
        "sources": ['[data-test-id*="source" i]', "a[href^=http]"],
        "response_container": ["model-response", "message-content", "[data-test-id=message]"],
    },
    "claude": {
        # Signed-in only and unambiguous — the account menu cannot exist without an account.
        # `div.ProseMirror` is kept as a second candidate purely as a fallback for the day the testid
        # changes; it is safe here because signed-out claude.ai/login has no contenteditable at all.
        "logged_in_marker": ["[data-testid=user-menu-button]", "div.ProseMirror"],
        "composer": ["[data-testid=chat-input]", "div.ProseMirror"],
        "send": ['button[aria-label*="send" i]', '[data-testid*="send" i]'],
        "research_toggle": ['button[aria-label*="research" i]', '[data-testid*="research" i]'],
        "artifact_panel": ['[data-testid*="artifact" i]', '[aria-label*="artifact" i]'],
        "sources": ['[data-testid*="citation" i]', "a[href^=http]"],
        # ⚠ NOT `[data-testid*=message]`: that matched `user-message` and proposed the user's own
        # prompt as the response container. Claude's assistant turn has no testid at all.
        "response_container": ["div[data-is-streaming]", "[data-testid=assistant-message]"],
    },
    "notebooklm": {
        # No testids anywhere on this platform, so accessible name is the only handle. Both of these
        # are signed-in only; the signed-out route never reaches notebooklm.google.com at all — it
        # bounces to accounts.google.com.
        "logged_in_marker": [
            'button[aria-label="Create new notebook"]',
            "#mat-button-toggle-1-button",
        ],
        # ⚠ Inside a notebook, not on the notebook list. Needs a notebook open.
        "add_source": ['button[aria-label*="add source" i]', 'button[aria-label*="add" i]'],
        "generate_audio": ['button[aria-label*="generate" i]', 'button[aria-label*="audio" i]'],
        "audio_ready_marker": ["audio", 'button[aria-label*="play" i]'],
    },
}

# Runs in the page. Returns a ranked candidate list for one CSS probe, with the evidence that
# justified each rank so a reviewer can judge rather than trust.
_DESCRIBE_JS = """
(function (probe, scope) {
  function nameOf(el) {
    return (el.getAttribute('aria-label') || el.getAttribute('title') ||
            (el.innerText || '').trim().slice(0, 60) || '');
  }
  // Framework-generated ids, which are NOT stable handles even though they look like ids.
  //
  // Real values this rejected on the first run against signed-in Claude: `#_r_3q_` proposed as
  // `send`, and `#base-ui-_r_15_` proposed as `research_toggle`. Both are React/Base-UI render ids —
  // they change on the next mount, so a manifest built on them works once and then silently resolves
  // nothing. ChatGPT emits the same shape (`#radix-_R_69trleal62j2al35_`). Rejecting them here makes
  // the candidate fall through to role+name or aria-label, which are properties of the control rather
  // than of this particular render.
  var GENERATED_ID = /(^|-)_r_|_R_|^radix-|^base-ui-|^headlessui-|^mui-|^:r/i;
  // Handles containing a positional index. Stable across renders, and still wrong.
  //
  // Measured: with an answer on screen, ChatGPT's `response_container` was proposed as
  // `[data-testid="conversation-turn-1"]` — rank 1, unique, visible, and bound to the FIRST turn of
  // the conversation forever. Turn 2 onwards would never match, so a multi-turn run harvests the
  // opening exchange and reports success. NotebookLM's `#mat-button-toggle-1-button` is the same
  // shape: it means "the second toggle", not "My notebooks".
  //
  // Rejecting these makes the candidate fall through to the semantic attribute
  // (`[data-message-author-role=assistant]`, `button[aria-label="Create new notebook"]`), which is
  // both more durable and what the key actually means.
  var INDEXED = /(^|-)[0-9]+(-|$)/;
  function suggest(el) {
    // ⚠ The attribute NAME matters and the two spellings are not interchangeable. Gemini uses
    // `data-test-id`; ChatGPT and Claude use `data-testid`. An earlier version read either and then
    // always emitted `[data-testid="…"]`, which on Gemini produces a selector matching zero elements
    // — every one of its captured values would have been silently dead. Caught by probing both
    // spellings on the live page: `[data-testid]` → 0 nodes, `[data-test-id]` → 41.
    var attr = el.hasAttribute('data-testid') ? 'data-testid'
             : (el.hasAttribute('data-test-id') ? 'data-test-id' : null);
    if (attr) {
      var tid = el.getAttribute(attr);
      if (!INDEXED.test(tid)) {
        return { css: '[' + attr + '="' + tid + '"]', rank: 1, why: attr };
      }
    }
    if (el.id && !/^[0-9]/.test(el.id) && !GENERATED_ID.test(el.id) && !INDEXED.test(el.id)) {
      return { css: '#' + el.id, rank: 2, why: 'stable id' };
    }
    var role = el.getAttribute('role'), label = el.getAttribute('aria-label');
    if (role && label) {
      return { css: '[role="' + role + '"][aria-label="' + label + '"]', rank: 3,
               why: 'role + accessible name' };
    }
    if (label) {
      return { css: el.tagName.toLowerCase() + '[aria-label="' + label + '"]', rank: 4,
               why: 'tag + aria-label' };
    }
    if (el.isContentEditable) {
      return { css: el.tagName.toLowerCase() + '[contenteditable="true"]', rank: 4,
               why: 'contenteditable' };
    }
    return { css: null, rank: 5, why: 'no stable attribute — text match only' };
  }
  var out = [];
  try {
    // `scope` restricts the search to the composer's own subtree when one is given.
    //
    // Needed because a page-wide search for a *concept* finds the concept in user content. Measured:
    // `button[aria-label*="research" i]` on signed-in Claude matched the sidebar's recent-chat rows —
    // "More options for Deep research report…" — and the capture proposed one of them as
    // `research_toggle`. Unique, visible, and completely wrong: the run would have opened a chat's
    // overflow menu and reported that deep research was enabled. The composer's controls live in the
    // composer, so that is where to look for them.
    //
    // The walk up matters: ChatGPT wraps its composer in a `<form>`, Claude and Gemini do not, and
    // an `|| parentElement` fallback collapses the scope to the contenteditable's immediate parent —
    // which holds no buttons, so a scoped probe finds nothing and the platform looks like it has no
    // send control.
    var root = document;
    if (scope) {
      var anchor = document.querySelector(scope);
      if (anchor) {
        root = anchor.closest('form');
        if (!root) {
          var node = anchor;
          for (var lvl = 0; lvl < 6 && node && node.parentElement; lvl++) {
            node = node.parentElement;
            if (node.querySelectorAll('button,[role=button]').length > 0) { root = node; break; }
          }
        }
        if (!root) root = document;
      }
    }
    var els = root.querySelectorAll(probe);
    for (var i = 0; i < els.length && i < 8; i++) {
      var el = els[i], r = el.getBoundingClientRect(), s = suggest(el);
      // How many elements the SUGGESTION matches, not the probe. A suggestion that resolves to
      // three nodes is not a target, it is a category — and `resolve` would silently take the
      // first in document order, which is the bug that made a run click the wrong control while
      // every step reported success.
      var matches = null;
      if (s.css) { try { matches = document.querySelectorAll(s.css).length; } catch (e) {} }
      out.push({
        probe: probe, tag: el.tagName.toLowerCase(), name: nameOf(el),
        role: el.getAttribute('role'),
        suggested: s.css, rank: s.rank, why: s.why, matches: matches,
        visible: !!(r.width && r.height), width: Math.round(r.width), height: Math.round(r.height),
        disabled: !!el.disabled, ariaPressed: el.getAttribute('aria-pressed'),
      });
    }
  } catch (e) { out.push({ probe: probe, error: String(e) }); }
  return out;
})(%s, %s)
"""

#: Keys that must be found **inside the composer**, with the CSS that anchors it per platform.
#:
#: These are the controls that belong to the act of sending a prompt — the send button and the
#: research toggles. Every one of them names a concept that also appears in page content (a chat
#: titled "Deep research report", a nav link called "Search the web"), and a page-wide probe cannot
#: tell a control from a mention.
COMPOSER_SCOPED_KEYS = {"send", "deep_research_toggle", "research_toggle", "start_research"}

#: Keys answered by **presence**, where demanding visibility is the wrong test.
#:
#: A login marker's question is "is there a session", and Gemini answers it with a sidebar that exists
#: but is collapsed at 402pt: `new-chat-button`, `all-conversations` and
#: `my-stuff-side-nav-entry-button` are each present exactly once when signed in, absent when signed
#: out, and none of them has a non-zero rect. Requiring visibility rejected all three and left Gemini
#: with no marker at all — while the app's own check is `!!document.querySelector(…)`, which would have
#: been perfectly happy with any of them. The rule was measuring the wrong property for this key.
#:
#: Everything else keeps the visibility requirement, because everything else is either tapped or read.
PRESENCE_ONLY_KEYS = {"logged_in_marker"}

COMPOSER_ANCHOR = {
    "chatgpt": "#prompt-textarea",
    "gemini": "[data-testid=textarea-inner]",
    "claude": "[data-testid=chat-input]",
    "notebooklm": None,
}


#: Keys whose elements only come into existence AFTER a response has been produced.
#:
#: ⚠ Discovered by running this against a page with no answer on screen: three of the seven keys
#: reported "no candidate", which reads as a capture failure when it is simply that the DOM does not
#: contain those nodes yet. So a capture session needs TWO passes per platform — one on the signed-in
#: idle page for the composer/send/marker/toggle, and one with a completed answer visible for the rest.
#: Saying so here costs nothing; discovering it mid-session costs the session.
POST_RESPONSE_KEYS = {
    "sources",
    "response_container",
    "activity_panel",
    "artifact_panel",
    "audio_ready_marker",
}

#: Hosts that mean "you were bounced to a sign-in flow", so the page under the URL you asked for is
#: not the page you are looking at.
#:
#: Measured: ``simctl openurl https://notebooklm.google.com`` on a signed-out device ends at
#: ``accounts.google.com/v3/signin/identifier?...`` — and because :func:`iwdp.wait_for_page` matches
#: on the *host you asked for*, the capture died with ``no inspectable page matching
#: 'notebooklm.google.com'``. That reads as a broken proxy or a broken selector list. It is neither:
#: it is "sign in first". An opaque error at the one step whose whole purpose is to tell you what the
#: page contains is worth this list.
AUTH_HOSTS = (
    "accounts.google.com",
    "auth.openai.com",
    "auth0.com",
    "login.microsoftonline.com",
    "appleid.apple.com",
)

# Runs in the page. Answers the two questions that decide whether a capture is meaningful at all:
# is this a signed-in session, and is there a finished answer on screen?
#
# Both are asked of *visible controls* rather than of cookies, because cookies are the wrong
# evidence: ``Cookies.binarycookies`` on this Simulator holds entries for all four platform domains
# and every one of them surveyed as logged OUT — a visitor cookie set by the login page itself is
# indistinguishable from a session cookie from the outside. What the page renders is the only signal
# that cannot lie about this.
_STATE_JS = r"""
(function () {
  function nameOf(el) {
    return (el.getAttribute('aria-label') || el.getAttribute('title') ||
            (el.innerText || '').trim().slice(0, 60) || '');
  }
  function visible(el) {
    var r = el.getBoundingClientRect();
    return !!(r.width && r.height);
  }
  // Deliberately anchored: /^/ so a logged-in page's "Sign out" or a body containing the words
  // "log in to save chats" inside prose cannot trip it. A *control* whose accessible name IS an
  // invitation to sign in is the signal.
  var AUTH_NAME = /^(log ?in|sign ?in|continue with (google|apple|microsoft)|sign up)\b/i;
  var authControls = [];
  document.querySelectorAll('button,[role=button],a').forEach(function (el) {
    if (!visible(el)) return;
    var n = nameOf(el);
    if (AUTH_NAME.test(n)) {
      authControls.push({ tag: el.tagName.toLowerCase(), name: n,
                          testid: el.getAttribute('data-testid') || null });
    }
  });

  // An inventory of every data-testid actually present, which is worth more than any probe list:
  // when a platform redesigns, the probes go stale but the inventory still shows what to aim at.
  var testids = {};
  document.querySelectorAll('[data-testid],[data-test-id]').forEach(function (el) {
    var t = el.getAttribute('data-testid') || el.getAttribute('data-test-id');
    testids[t] = (testids[t] || 0) + 1;
  });

  return {
    url: location.href,
    title: document.title,
    readyState: document.readyState,
    authControls: authControls.slice(0, 8),
    testids: testids,
    bodyTextHead: (document.body ? (document.body.innerText || '') : '')
                    .replace(/\s+/g, ' ').slice(0, 300),
  };
})()
"""

# "Is a finished answer on screen?" — asked structurally, per platform, because the post-response
# keys must never be drafted from a page that has no response. Without this the rank-4 relaxation
# below would happily propose ChatGPT's nav link ``a[aria-label="Images"]`` as ``sources``.
_RESPONSE_PROBES: dict[str, list[str]] = {
    "chatgpt": ["[data-message-author-role=assistant]", "[data-testid*=conversation-turn]"],
    "gemini": ["model-response", "message-content", "[data-response-index]"],
    "claude": ["[data-testid*=message]", "div[data-is-streaming]"],
    "notebooklm": ["audio", "[aria-label*=Play]"],
}

_RESPONSE_JS = """
(function (probes) {
  for (var i = 0; i < probes.length; i++) {
    try {
      var els = document.querySelectorAll(probes[i]);
      for (var j = 0; j < els.length; j++) {
        var r = els[j].getBoundingClientRect();
        if (r.width && r.height) return { present: true, by: probes[i] };
      }
    } catch (e) {}
  }
  return { present: false, by: null };
})(%s)
"""


def login_verdict(state: dict) -> dict:
    """Decide whether the surveyed page is a signed-in session, and say what said so.

    Returns a verdict rather than a bool because the *evidence* is the point: a capture that stops
    must tell you which control it saw, or it is just another opaque failure. Two independent
    signals, either of which is sufficient:

    * the final URL sits on an auth host — you were redirected out of the product;
    * a visible control invites you to sign in.

    The asymmetry here is deliberate. A false "signed out" costs one re-run and says exactly why. A
    false "signed in" writes a manifest whose composer is the *anonymous visitor's* textarea, and
    that is the P1 failure: every click lands, the harvest returns nothing, the run reports success.
    So this errs toward refusing.
    """
    url = state.get("url") or ""
    host = url.split("//", 1)[-1].split("/", 1)[0].lower()
    on_auth_host = next((h for h in AUTH_HOSTS if h in host), None)
    controls = state.get("authControls") or []
    signed_in = not on_auth_host and not controls
    reasons = []
    if on_auth_host:
        reasons.append(f"redirected to the sign-in host {on_auth_host!r} ({url})")
    for control in controls[:3]:
        label = control.get("name") or "?"
        reasons.append(f"visible <{control.get('tag')}> control named {label!r}")
    return {"signed_in": signed_in, "url": url, "reasons": reasons}


#: The `Version/` token our app's `customUserAgent` pins, and the one thing that tells the app's web
#: view apart from a Safari tab on the same URL.
#:
#: Needed because both surfaces show up in one flat proxy list with nothing to say which app they
#: belong to, and on this device the app's signed-in ChatGPT and Safari's signed-out ChatGPT are both
#: literally ``https://chatgpt.com/``. Matching on title worked for three platforms and then failed on
#: Gemini, where the app and Safari render the same ``Google Gemini`` — the sort of heuristic that
#: looks right until the one case where it silently picks the wrong page and captures a signed-out
#: DOM. The UA is not a heuristic: the app sets it, Simulator Safari reports its own (`Version/26.5`
#: here), and they cannot collide by accident.
APP_UA_TOKEN = "Version/17.0"


def find_app_page(host: str, port: int = 9222, timeout: float = 25.0) -> "iwdp.Page":
    """The app's own web view for this host, identified by the UA the app pins.

    Polled rather than read once. An app's web views take appreciably longer to appear in the proxy's
    listing than Safari's tabs do — measured the hard way: four back-to-back captures, and the first
    (ChatGPT) found its page while the next three reported "no inspectable page at all" on hosts that
    were demonstrably open. The pages were there; the freshly restarted proxy had not enumerated them
    yet, and a fixed sleep that is long enough on one machine is a flake on another.
    """
    deadline = time.time() + timeout
    candidates: list = []
    while time.time() < deadline:
        candidates = [
            p for p in iwdp.list_pages(port)
            if host in p.url.split("//", 1)[-1].split("/", 1)[0]
        ]
        if candidates:
            break
        time.sleep(1.5)
    if not candidates:
        raise SystemExit(
            f"no inspectable page on {host} at all. The app's web views are only inspectable with "
            f"`isInspectable = true` (iOS 16.4+) — and only exist while something is showing them: "
            f"the login sheet tears its web view down on dismiss, while 'Watch the browser' keeps "
            f"one per platform alive on purpose. Open that, visit each tab once, then re-run."
        )
    # The app's view may still be materialising after the host's Safari tab is already listed, so the
    # UA check gets its own patience rather than sharing the discovery loop's.
    while True:
        for page in candidates:
            try:
                with iwdp.Inspector(page.ws_url) as insp:
                    ua = insp.evaluate_json("navigator.userAgent") or ""
            except Exception:  # noqa: BLE001
                continue
            if APP_UA_TOKEN in str(ua):
                return page
        if time.time() >= deadline:
            break
        time.sleep(1.5)
        candidates = [
            p for p in iwdp.list_pages(port)
            if host in p.url.split("//", 1)[-1].split("/", 1)[0]
        ]
    raise SystemExit(
        f"found {len(candidates)} page(s) on {host} but none carrying the app's user agent "
        f"({APP_UA_TOKEN!r}) — those are Safari tabs. Open 'Watch the browser' in the app and "
        f"visit this platform's tab, then re-run."
    )


def capture(
    udid: str, platform: str, url: str, port: int = 9222, surface: str = "safari"
) -> dict:
    if platform not in PROBES:
        raise SystemExit(f"unknown platform {platform!r}; known: {sorted(PROBES)}")

    sock = iwdp.discover_simulator_socket(udid)
    subprocess.run(["pkill", "-f", "ios_webkit_debug_proxy"], capture_output=True)
    time.sleep(1)
    proxy = subprocess.Popen(
        ["ios_webkit_debug_proxy", "-s", f"unix:{sock}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(2.5)
        host = url.split("//", 1)[-1].split("/", 1)[0]
        if surface == "app":
            # No `openurl`: that drives *Safari*, and on this device Safari is signed out of all four
            # platforms while the app is signed in to them. Navigating would replace the page we want
            # to read with the one we do not.
            page = find_app_page(host, port)
        else:
            subprocess.run(["xcrun", "simctl", "openurl", udid, url], capture_output=True)
            page = _wait_for_product_page(host, port, 60)
        with iwdp.Inspector(page.ws_url) as insp:
            insp.evaluate_json(runtime_js.RUNTIME_JS)
            viewport = insp.evaluate_json(f"window.{runtime_js.NS}.viewport()")
            state = insp.evaluate_json(_STATE_JS) or {}
            response = insp.evaluate_json(
                _RESPONSE_JS % json.dumps(_RESPONSE_PROBES.get(platform, []))
            ) or {"present": False}
            findings: dict[str, list] = {}
            anchor = COMPOSER_ANCHOR.get(platform)
            for key, probes in PROBES[platform].items():
                scope = anchor if (key in COMPOSER_SCOPED_KEYS and anchor) else None
                hits = []
                for probe in probes:
                    got = insp.evaluate_json(
                        _DESCRIBE_JS % (json.dumps(probe), json.dumps(scope))
                    ) or []
                    hits.extend(got)
                # Best rank first, and visible before invisible: an off-screen match is usually a
                # different instance of the same component (a desktop-only sibling, a hidden menu).
                hits.sort(key=lambda h: (not h.get("visible", False), h.get("rank", 9)))
                findings[key] = hits[:6]
            return {
                "platform": platform,
                "surface": "ios-app-webview" if surface == "app" else "ios-mobile-safari",
                "url": page.url,
                "viewport": viewport,
                "state": state,
                "login": login_verdict({**state, "url": state.get("url") or page.url}),
                "response": response,
                "candidates": findings,
            }
    finally:
        proxy.terminate()


def _wait_for_product_page(host: str, port: int, timeout: float) -> iwdp.Page:
    """Wait for the requested host — and if a sign-in host showed up instead, say *that*.

    ``iwdp.wait_for_page`` matches on the host you asked for, so a signed-out platform that bounces
    to SSO produces ``no inspectable page matching 'notebooklm.google.com'``: a message about the
    proxy, for a problem that is entirely about the session. Same failure, named correctly.
    """
    try:
        return iwdp.wait_for_page(host, port, timeout)
    except iwdp.InspectorError:
        seen = [p.url for p in iwdp.list_pages(port)]
        bounced = [
            u for u in seen if any(auth in u.split("//", 1)[-1].split("/", 1)[0] for auth in AUTH_HOSTS)
        ]
        if bounced:
            raise SystemExit(
                f"{host} is NOT SIGNED IN — the browser was redirected to a sign-in flow instead:\n"
                f"  {bounced[0][:160]}\n"
                f"Sign in to {host} in Safari in the Simulator, wait ten seconds for the cookie "
                f"flush, then re-run this."
            ) from None
        raise


#: A probe that is *itself* a durable handle, so matching it is already the answer.
#:
#: ``suggest()`` describes the element it found — its testid, its id, its accessible name — and that
#: covers controls. It has no vocabulary for an element whose identity IS a semantic data attribute,
#: which is exactly how both ChatGPT and Gemini mark up a response:
#: ``[data-message-author-role=assistant]``, ``<model-response>``. Those matched, were described as
#: "no stable attribute — text match only", and were dropped — after which the only surviving candidate
#: for ``response_container`` was ``[data-testid="conversation-turn-1"]``, bound to turn one forever.
#:
#: Two shapes qualify, both narrow on purpose:
#:   * a plain data-attribute equality selector — ``[data-message-author-role=assistant]``. Not
#:     ``*=`` substring forms, which are search terms rather than identities, and not
#:     ``a[href^=http]``, which is how ChatGPT's "Images" nav link became a candidate for ``sources``.
#:   * a bare custom-element tag — ``model-response``, ``message-content``. A framework component name
#:     is part of the platform's own structure.
_DATA_ATTR_PROBE = re.compile(r"^\[data-[a-z-]+=[^*^$~|\]]+\]$")
_CUSTOM_ELEMENT_PROBE = re.compile(r"^[a-z]+(-[a-z]+)+$")
#: A data attribute used as a *marker*, with no value to match — ``div[data-is-streaming]``.
#: Claude's assistant turn carries no testid, no id and no accessible name; this attribute is the only
#: thing that identifies it. Measured with an answer on screen: 16 testids on the page and not one of
#: them on the response, while `[data-testid*=message]` matched `user-message` — so the capture
#: proposed the *user's own prompt* as `response_container`.
_DATA_PRESENCE_PROBE = re.compile(r"^[a-z]*\[data-[a-z-]+\]$")


def durable_probe(probe: str) -> bool:
    return bool(
        _DATA_ATTR_PROBE.match(probe)
        or _CUSTOM_ELEMENT_PROBE.match(probe)
        or _DATA_PRESENCE_PROBE.match(probe)
    )


#: Keys whose value is going to be TAPPED, so the value had better be a control.
#:
#: Gemini names the wrapper around its send button ``send-button-container``, and that wrapper carries
#: the testid while the button itself carries only ``aria-label="Send message"``. Rank alone therefore
#: prefers the container — a div — over the button that was actually driven successfully. Requiring a
#: button settles it without a name heuristic: you tap controls, not their boxes.
TAPPED_KEYS = COMPOSER_SCOPED_KEYS | {"add_source", "generate_audio"}


def draft_manifest(captured: dict) -> dict:
    """Turn candidates into a DRAFT manifest entry — proposed, never promoted.

    The acceptance rule was written against invented DOM and then **measured against the real
    thing**, which moved it twice:

    *Rank 4 is admitted now, under a uniqueness condition.* The original rule took rank 1–3 only
    (``data-testid`` / ``id`` / role+name) on the theory that a ``tag[aria-label=…]`` match is a
    guess. Real mobile ChatGPT says otherwise: its send button is ``button[aria-label="Send
    message"]`` and its deep-research control is ``button[aria-label="Deep research"]`` — neither
    carries a testid or an id, so the strict rule proposed **1 of 7 keys on a perfectly good page**
    and the other six looked like capture failures. A rule that rejects the only stable attribute a
    platform ships is not conservative, it is broken. What keeps it honest is
    ``matches == 1``: a suggestion resolving to several nodes is a category, not a target, and
    ``resolve`` would take document order and click the wrong one.

    *Post-response keys are refused outright unless a response is on screen.* This is the guard the
    rank relaxation made necessary. With no answer rendered, ChatGPT's ``a[href^=http]`` probe
    returns its nav chrome — ``a[aria-label="Images"]``, ``a[aria-label="Plugins"]``, ``a[aria-label=
    "See plans and pricing"]`` — all visible, all unique, all rank 4. Under the relaxed rule alone,
    ``sources`` would have been drafted as the *Images link*, which is the P1 failure exactly: a
    selector that resolves, a harvest that returns nothing, a run that reports success.
    """
    response_present = bool(captured.get("response", {}).get("present"))
    surface = captured.get("surface", "ios-mobile-safari")
    entries: dict[str, object] = {}
    skipped: dict[str, str] = {}
    for key, hits in captured["candidates"].items():
        if key in POST_RESPONSE_KEYS and not response_present:
            skipped[key] = "no response on screen — this key is not capturable in this pass"
            continue
        needs_visible = key not in PRESENCE_ONLY_KEYS
        must_be_control = key in TAPPED_KEYS
        best = next(
            (
                h
                for h in hits
                if h.get("suggested")
                and (h.get("visible") or not needs_visible)
                and (
                    not must_be_control
                    or h.get("tag") == "button"
                    or h.get("role") == "button"
                )
                and (
                    h.get("rank", 9) <= 3
                    or (h.get("rank") == 4 and h.get("matches") == 1)
                )
            ),
            None,
        )
        if best is None:
            # Last resort: the probe itself, when the probe is a durable handle rather than a search
            # term. After the element-described candidates, never before, so a testid still wins.
            durable = next(
                (
                    h
                    for h in hits
                    if durable_probe(h.get("probe", ""))
                    and (h.get("visible") or not needs_visible)
                ),
                None,
            )
            if durable is not None:
                entries[key] = {
                    "css": [durable["probe"]],
                    "provenance": f"captured@{surface}:the probe is itself a semantic handle",
                }
                continue
            skipped[key] = "no candidate met the acceptance rule"
            continue
        # The surface rides along with every value, because the two surfaces are not guaranteed to
        # render the same DOM: the app pins an iPhone Safari 17 user agent while Simulator Safari
        # reports 26.5, and a platform that branches on that serves different markup to each. A
        # selector that works in the app and silently misses in Safari is the P1 failure again, so
        # where a value came from must be readable in the file rather than remembered.
        provenance = f"captured@{surface}:{best['why']}"
        if best.get("rank") == 4:
            # Said in the file itself, not just in the reviewer's head. A weaker basis that travels
            # with the value is the difference between a reviewer checking one entry and a reviewer
            # having to re-derive all of them.
            provenance += " (weak — verify by driving it, not by resolving it)"
        entries[key] = {"css": [best["suggested"]], "provenance": provenance}
    return {
        "version": 1,
        "surface": surface,
        "platforms": {captured["platform"]: entries},
        "_skipped": skipped,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--platform", required=True, choices=sorted(PROBES))
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", default=None, help="draft manifest path (default: artifacts/selectors/)")
    ap.add_argument(
        "--surface",
        choices=("safari", "app"),
        default="safari",
        help="safari: navigate a Simulator Safari tab. app: read the app's own web view "
             "(open 'Watch the browser' first so one per platform is alive).",
    )
    args = ap.parse_args()

    captured = capture(args.udid, args.platform, args.url, surface=args.surface)
    out_dir = REPO / "artifacts" / "selectors"
    out_dir.mkdir(parents=True, exist_ok=True)
    suffix = "_app" if args.surface == "app" else ""
    raw_path = out_dir / f"{args.platform}{suffix}_candidates.json"
    # ASCII with escapes rather than the locale encoding: platform UI text carries emoji and, on at
    # least one page, a lone surrogate, and `write_text` died on it *after* the capture had already
    # been done — losing the whole session's work at the write step.
    raw_path.write_bytes(
        json.dumps(captured, indent=2, ensure_ascii=True).encode("ascii", "backslashreplace") + b"\n"
    )
    print(f"candidates -> {raw_path.relative_to(REPO)}   (kept — the survey is useful either way)")

    # The refusal. This is the check that would have saved the first real capture session: it ran
    # against a signed-OUT chatgpt.com, found the anonymous visitor's `<textarea
    # id="mobile-composer-prompt">`, and proposed it as `composer` with provenance "captured:stable
    # id" — a value indistinguishable from a good one by reading the file, and wrong.
    verdict = captured["login"]
    if not verdict["signed_in"]:
        print(f"\n⛔ {args.platform} is NOT SIGNED IN. No draft written.")
        for reason in verdict["reasons"]:
            print(f"   · {reason}")
        print(
            "\nA capture from a signed-out page is worse than no capture: the anonymous page has a "
            "composer too, so the draft would look correct and be wrong.\n"
            f"Sign in to {args.platform} in Safari in the Simulator, give it ten seconds to flush "
            "cookies, then re-run."
        )
        return 3

    draft = draft_manifest(captured)
    draft_path = Path(args.out) if args.out else out_dir / f"{args.platform}{suffix}_draft.json"
    draft_path.write_bytes(
        json.dumps(draft, indent=2, ensure_ascii=True).encode("ascii", "backslashreplace") + b"\n"
    )

    proposed = draft["platforms"][args.platform]
    wanted = set(sel.ALLOWED_KEYS[args.platform])
    print(f"viewport: {captured['viewport'].get('innerWidth')}x{captured['viewport'].get('innerHeight')}")
    print(f"signed in: yes ({captured['login']['url']})")
    print(f"response on screen: {'yes' if captured['response'].get('present') else 'no'}"
          f" — post-response keys are {'capturable' if captured['response'].get('present') else 'SKIPPED in this pass'}")
    print(f"draft      -> {draft_path.relative_to(REPO)}")
    print(f"\nproposed {len(proposed)}/{len(wanted)} keys for {args.platform}:")
    for key in sorted(wanted):
        entry = proposed.get(key)
        if entry:
            print(f"  ✓ {key:24} {entry['css'][0]}  ({entry['provenance']})")
        else:
            print(f"  · {key:24} {draft['_skipped'].get(key, 'not probed')}")
    testids = captured.get("state", {}).get("testids") or {}
    if testids:
        # Printed even on success, because when a platform redesigns the probe list goes stale and
        # this inventory is what tells you where to aim next. Cheap here, expensive to rediscover.
        print(f"\ndata-testids present on the page ({len(testids)}): "
              f"{', '.join(sorted(testids)[:20])}")
    print(
        "\n⚠ These are PROPOSALS. Review them before merging into selectors_mobile.json: a "
        "plausible-but-wrong selector produces a run that reports success having harvested nothing."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
