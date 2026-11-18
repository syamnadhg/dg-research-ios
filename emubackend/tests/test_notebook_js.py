"""Execute P3's ported JavaScript against a DOM stub.

⭐ **These EXECUTE the expressions rather than asserting on their source.** Every other guard in this
repo that read a selector out of a file and checked it was present has, sooner or later, passed
against code that could never run — a regex that appeared only in its own failure message, a rule
check blind to file exclusion, a presence assertion satisfied by the bug. The JavaScript in
``NotebookPhase.swift`` is the largest un-executed surface left on this device, and it is the part
that decides whether a link is public, which podcast gets downloaded, and whether a menu row is
``Download`` or ``Delete``.

⚠ **The extraction is itself asserted.** A test that silently extracted nothing would pass every
assertion below by never running one, which is the exact failure it exists to prevent.

⛔ The DOM here is a small **matcher**, not a set of canned answers: it resolves real selector
syntax — comma lists, descendant combinators, tag/class/attribute/substring tests — over a tree the
test builds. A stub that answered ``querySelectorAll`` from a lookup table would let a JS expression
pass while matching nothing at all, which is precisely the class of bug the desktop backend found in
its own NotebookLM counters (*"every count=0 → all dup-guards are dead no-ops"*).
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest

from emubackend.tests.test_gate_zero_surface import _node

SWIFT = (
    Path(__file__).resolve().parents[2]
    / "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift"
)

#: Swift-source interpolations that have to be resolved before the JS can run.
#:
#: ⚠ Resolved by SUBSTITUTION rather than by stripping. Dropping `\(labelJS)` would leave the
#: expression referencing an `nlmLabel` that does not exist, node would throw, and the test would
#: report a JS error for a file that is perfectly correct in production.
_SHARED = ("labelJS", "onScreenJS")


def _extract(name: str) -> str:
    """Pull one `static let <name> = \"\"\"…\"\"\"` block out of the Swift source."""
    source = SWIFT.read_text()
    match = re.search(
        r'static (?:let|func) ' + re.escape(name) + r'\b[^\n]*=\s*\n?\s*"""\n(.*?)\n\s*"""',
        source,
        re.S,
    )
    assert match, (
        f"{name} was not found in {SWIFT.name} — the constant was renamed and every assertion "
        f"below would have silently stopped testing anything"
    )
    body = match.group(1)
    # Swift strips the indentation of the closing delimiter; the exact amount does not matter to
    # node, so only the interpolations have to go.
    for shared in _SHARED:
        if f"\\({shared})" in body:
            body = body.replace(f"\\({shared})", _extract(shared))
    body = body.replace('\\(js(dialogScopes))', json.dumps(_dialog_scopes()))
    # `\\(` in a Swift literal is an escaped backslash followed by a paren — a JS regex, not an
    # interpolation. Swift also un-escapes `\\s` to `\s` and `\\1` to `\1` at compile time.
    body = re.sub(r"\\\\", r"\\", body)
    assert "\\(" not in body, f"{name} still carries an unresolved interpolation"
    return body


def _dialog_scopes() -> str:
    source = SWIFT.read_text()
    match = re.search(r'static let dialogScopes = "(.*?)"\n', source)
    assert match, "dialogScopes vanished"
    return match.group(1).replace('\\"', '"')


def _pick_option_js(label: str) -> str:
    """`pickOptionJS` is a FUNCTION whose body is the literal, so it needs its own extraction."""
    source = SWIFT.read_text()
    match = re.search(
        r'static func pickOptionJS\([^)]*\)[^{]*\{\s*\n\s*"""\n(.*?)\n\s*"""', source, re.S
    )
    assert match, "pickOptionJS was not found — the length pick would be testing nothing"
    body = match.group(1)
    body = body.replace("\\(js(label))", json.dumps(label))
    body = body.replace("\\(labelJS)", _extract("labelJS"))
    body = re.sub(r"\\\\", r"\\", body)
    assert "\\(" not in body, "pickOptionJS still carries an unresolved interpolation"
    return body


# ── the shim ──────────────────────────────────────────────────────────────────────────────────

_SHIM = r"""
const spec = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const clicks = [];

function parseSimple(sel) {
  const out = { tag: null, cls: [], attrs: [] };
  let rest = sel;
  const tag = rest.match(/^[a-zA-Z][\w-]*/);
  if (tag) { out.tag = tag[0].toLowerCase(); rest = rest.slice(tag[0].length); }
  let m;
  // ⚠ The trailing `i` flag (`[data-testid*="model" i]`) is parsed rather than ignored, and the
  // difference is not cosmetic. Without it this regex fails to match the whole bracket, the
  // attribute test is DROPPED from the parse, and `button[data-testid*="model" i]` silently
  // degrades to `button` — matching every button on the page. A selector that widens inside the
  // test harness lets a scoped expression pass while it is in fact unscoped, which is the exact
  // class of defect the scoping exists to prevent.
  // ⛔ **`#id` is parsed, and it was not.** Without this arm `#prompt-textarea` parses to an EMPTY
  // matcher — no tag, no class, no attribute — which matches EVERY element, so `querySelector`
  // returned whatever came first in the document. Every test that asked for the ChatGPT composer by
  // id was really asking for "the first element", and passed only while the composer happened to be
  // it. The moment a fixture wrapped the composer in anything — a modal backdrop, say — the tests
  // were silently asserting about the wrapper.
  const re = /#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:([*^$]?=)"([^"]*)")?\s*(i)?\]/g;
  while ((m = re.exec(rest))) {
    if (m[1]) out.attrs.push({ name: 'id', op: '=', value: m[1], ci: false });
    else if (m[2]) out.cls.push(m[2]);
    else out.attrs.push({ name: m[3], op: m[4] || null, value: m[5], ci: !!m[6] });
  }
  return out;
}

function matchesSimple(el, sel) {
  const p = parseSimple(sel.trim());
  if (p.tag && el.tag !== p.tag) return false;
  for (const c of p.cls) if (!(el.className || '').split(/\s+/).includes(c)) return false;
  for (const a of p.attrs) {
    let v = el.getAttribute(a.name);
    if (v === null || v === undefined) return false;
    let want = a.value;
    if (a.ci) { v = String(v).toLowerCase(); want = String(want).toLowerCase(); }
    if (!a.op) continue;
    if (a.op === '=' && v !== want) return false;
    if (a.op === '*=' && v.indexOf(want) === -1) return false;
    if (a.op === '^=' && v.indexOf(want) !== 0) return false;
    if (a.op === '$=' && v.slice(-want.length) !== want) return false;
  }
  return true;
}

// ⛔ **The one rule both focus and selection obey, in a browser and here.** A subtree that is
// `inert`, `visibility:hidden` or `display:none` refuses focus AND refuses to hold a caret —
// WebKit drops a Range added inside it, which is precisely what the 2026-08-17 failure reported
// (`activeIsEditor=false`, `selectionIsInside()=false`, on an element with a real 341x42 rect).
// Modelled once so a fixture cannot be un-focusable but still selectable, a combination no page
// produces and which would let the caret path pass against a page it could never work on.
function neutralised(el) {
  let n = el;
  while (n) {
    const st = n.style || {};
    if (('inert' in (n.attrs || {})) || st.visibility === 'hidden' || st.display === 'none') return true;
    n = n.parentElement;
  }
  return false;
}

function descendants(root) {
  const out = [];
  (function walk(node) {
    for (const child of node.children) { out.push(child); walk(child); }
  })(root);
  return out;
}

function queryAll(root, selector) {
  const found = [];
  for (const part of selector.split(',')) {
    const steps = part.trim().split(/\s+(?![^\[]*\])/).filter(Boolean);
    if (!steps.length) continue;
    let pool = descendants(root);
    for (let i = 0; i < steps.length; i++) {
      const next = [];
      for (const el of pool) {
        if (!matchesSimple(el, steps[i])) continue;
        if (i === steps.length - 1) next.push(el);
        else for (const d of descendants(el)) next.push(d);
      }
      pool = next;
    }
    for (const el of pool) if (found.indexOf(el) === -1) found.push(el);
  }
  return found;
}

function make(node, parent) {
  const el = {
    tag: (node.tag || 'div').toLowerCase(),
    className: node.class || '',
    attrs: node.attrs || {},
    ownText: node.text || '',
    icons: node.icons || [],
    visible: node.visible !== false,
    rect: node.rect || { left: 0, top: 0, width: 100, height: 30 },
    value: node.value,
    disabled: !!node.disabled,
    children: [],
    parentElement: parent || null,
    escapeRemoves: !!node.escapeRemoves,
    // ⛔ **Computed style, because `visibility:hidden` is the one blocker that survives every other
    // check the runtime makes.** It keeps the box — `getBoundingClientRect()` still reports real
    // width and height — while refusing focus and refusing to hold a selection. A shim with no
    // `getComputedStyle` sends the runtime down its `catch` branch, so the rule that reads it would
    // be present, "covered", and structurally incapable of firing in a test.
    style: node.style || {},
  };
  if (node.role) el.attrs.role = node.role;
  if (node.ariaLabel !== undefined) el.attrs['aria-label'] = node.ariaLabel;
  el.getAttribute = (n) => (n in el.attrs ? el.attrs[n] : null);
  el.hasAttribute = (n) => n in el.attrs;
  // ⛔ `tagName` is UPPERCASE in a browser, and the model-menu row filter's first arm reads
  // `el.tagName === 'A'` to refuse a sidebar conversation link — the 2026-08-05 navigation. Without
  // this property that comparison is `undefined === 'A'`, permanently false: the guard would be
  // present, tested, and incapable of ever firing.
  Object.defineProperty(el, 'tagName', { get: () => el.tag.toUpperCase() });
  el.setAttribute = (n, v) => { el.attrs[n] = String(v); };
  el.removeAttribute = (n) => { delete el.attrs[n]; };
  // Visibility, the other spelling. `vis()` tries `getClientRects().length` FIRST, so a shim
  // without it throws before `offsetParent` is ever consulted.
  el.getClientRects = () => (el.visible ? [{ width: el.rect.width, height: el.rect.height }] : []);
  el.getBoundingClientRect = () => ({
    left: el.rect.left, top: el.rect.top, width: el.rect.width, height: el.rect.height,
  });
  el.click = () => { clicks.push(el.attrs['data-id'] || el.ownText || el.tag); };
  // ⛔ **Focus REFUSES on a neutralised subtree, exactly as a browser does.** Derived from the same
  // conditions the runtime looks for — `inert`, `visibility:hidden`, `display:none` on the element
  // or any ancestor — rather than from a bespoke "focusable" flag, so a fixture cannot declare an
  // element focusable that a real browser would refuse. This is what makes the caret failure the
  // live run hit reproducible at all: before it, `el.focus` did not exist and `S.insertText` threw
  // on its first line.
  el.focus = () => { if (!neutralised(el)) document.activeElement = el; };
  el.contains = (other) => {
    let n = other;
    while (n) { if (n === el) return true; n = n.parentElement; }
    return false;
  };
  Object.defineProperty(el, 'isContentEditable', {
    get: () => el.attrs['contenteditable'] === 'true',
  });
  Object.defineProperty(el, 'lastElementChild', {
    get: () => el.children[el.children.length - 1] || null,
  });
  el.querySelector = (s) => queryAll(el, s)[0] || null;
  el.querySelectorAll = (s) => queryAll(el, s);
  // ⛔ Splits on commas. `matchesSimple` parses ONE compound selector, so a comma list handed to it
  // whole becomes a single impossible AND — `[role="menu"], [role="listbox"], [role="dialog"]` would
  // require all three roles on one element and `closest` would return null for every document. The
  // in-overlay exclusion is written exactly that way, so without this it is a guard that cannot
  // fire, and a test asserting it would pass against a page where it never ran.
  el.closest = (s) => {
    const parts = s.split(',').map((x) => x.trim()).filter(Boolean);
    let n = el;
    while (n) {
      for (const part of parts) if (matchesSimple(n, part)) return n;
      n = n.parentElement;
    }
    return null;
  };
  for (const child of node.children || []) el.children.push(make(child, el));
  // ICONS are separate child elements whose text bleeds into innerText — the real markup.
  for (const icon of el.icons) {
    el.children.unshift(make({ tag: 'mat-icon', text: icon }, el));
  }
  Object.defineProperty(el, 'offsetParent', { get: () => (el.visible ? { tag: 'body' } : null) });
  Object.defineProperty(el, 'innerText', {
    get: () => [...el.children.map((c) => c.innerText), el.ownText].filter(Boolean).join(' ').trim(),
  });
  Object.defineProperty(el, 'textContent', { get: () => el.innerText });
  Object.defineProperty(el, 'childNodes', {
    get: () => el.children.concat(
      el.ownText ? [{ nodeType: 3, nodeValue: el.ownText }] : []
    ),
  });
  Object.defineProperty(el, 'nextElementSibling', {
    get: () => {
      if (!el.parentElement) return null;
      const sibs = el.parentElement.children;
      return sibs[sibs.indexOf(el) + 1] || null;
    },
  });
  return el;
}

const body = make({ tag: 'body', children: spec.elements || [] }, null);
// ⛔ **Dispatched events are RECORDED, and before this they could not even be constructed.** The
// shim had no `KeyboardEvent` and no `document.dispatchEvent`, so every Escape the runtime sends
// threw inside its own `try` and was swallowed — the overlay-dismissal path had never once executed
// under test, while two tests asserted on its aftermath and passed on the survival of the blocker
// rather than on any keypress. A test double that cannot perform the action cannot witness it.
const events = [];
class KeyboardEvent {
  constructor(type, init) { this.type = type; Object.assign(this, init || {}); }
}
class ClipboardEvent {
  constructor(type, init) { this.type = type; Object.assign(this, init || {}); }
}
class InputEvent {
  constructor(type, init) { this.type = type; Object.assign(this, init || {}); }
}
const document = {
  body: body,
  querySelector: (s) => queryAll(body, s)[0] || null,
  querySelectorAll: (s) => queryAll(body, s),
  getElementById: (id) => queryAll(body, '[id="' + id + '"]')[0] || null,
  addEventListener: () => {},
  activeElement: null,
  dispatchEvent: (e) => {
    events.push({ type: e.type, key: e.key || null });
    // A modal that CLOSES on Escape, which is the whole reason the runtime presses it. Declared by
    // the fixture (`"escapeRemoves": true`) so a test can have a dismissible dialog and a stuck one
    // and tell the outcomes apart — without this, "Escape recovered the page" is unobservable and
    // the recovery path can only ever be asserted by its absence.
    if (e.key === 'Escape' && e.type === 'keydown') {
      for (const el of [body].concat(descendants(body))) {
        if (el.escapeRemoves && 'inert' in el.attrs) delete el.attrs['inert'];
      }
    }
    return true;
  },
  createRange: () => ({
    node: null,
    selectNodeContents(n) { this.node = n; },
    collapse() {},
    get commonAncestorContainer() { return this.node; },
  }),
  execCommand: (cmd, _ui, text) => {
    if (cmd !== 'insertText') return false;
    const sel = selection.range && selection.range.commonAncestorContainer;
    if (!sel) return false;
    sel.ownText = (sel.ownText || '') + String(text);
    return true;
  },
  hasFocus: () => true,
};
const selection = {
  range: null,
  get rangeCount() { return this.range ? 1 : 0; },
  // WebKit DROPS a range added inside a neutralised subtree — the caret simply does not land, with
  // no error. Accepting it here would make `selectionIsInside()` true on exactly the pages where
  // the live run measured it false.
  addRange(r) {
    if (r && r.commonAncestorContainer && neutralised(r.commonAncestorContainer)) return;
    this.range = r;
  },
  removeAllRanges() { this.range = null; },
  getRangeAt() { return this.range; },
};
const window = {
  innerWidth: 390,
  innerHeight: 844,
  // Defaults match a browser's: everything is visible and displayed unless the fixture says
  // otherwise, so a node that declares no style can never accidentally read as blocked.
  getSelection: () => selection,
  getComputedStyle: (el) => ({
    visibility: (el && el.style && el.style.visibility) || 'visible',
    display: (el && el.style && el.style.display) || 'block',
  }),
};
const HTMLAnchorElement = { prototype: { click: function () {} } };
const result = EXPRESSION;
console.log(JSON.stringify({
  result: result === undefined ? null : result, clicks: clicks, events: events,
}));
"""


def _run(expression: str, elements: list) -> dict:
    harness = _SHIM.replace("EXPRESSION", expression)
    out = subprocess.run(
        [_node(), "-e", harness],
        input=json.dumps({"elements": elements}),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


# ── the shim's own honesty check ──────────────────────────────────────────────────────────────


def test_the_shim_actually_matches_selectors_rather_than_answering_from_a_table():
    """⛔ If this fails, every assertion below is meaningless — they would all be running against a
    document that matches nothing, which is indistinguishable from JS that finds nothing."""
    got = _run(
        "[document.querySelectorAll('[role=\"dialog\"] button').length,"
        " document.querySelectorAll('button').length]",
        [{"tag": "div", "role": "dialog", "children": [{"tag": "button", "text": "Inside"}]},
         {"tag": "button", "text": "Outside"}],
    )
    assert got["result"] == [1, 2], got


def test_the_shim_reports_an_UPPERCASE_tagName():
    """⛔ Guards the row filter's absolute arm. `el.tagName === 'A'` against a shim with no
    `tagName` is false for every element, so the anchor exclusion would be dead and the test
    asserting it would pass on a document where it never ran."""
    got = _run("[document.querySelectorAll('a')[0].tagName]",
               [{"tag": "a", "text": "Deep research request", "attrs": {"href": "/c/1"}}])
    assert got["result"] == ["A"], got


def test_the_shim_honours_the_case_insensitive_attribute_flag_AND_still_scopes():
    """⛔ Both halves. If ` i` were ignored the bracket would not parse and the selector would widen
    to every button — so the test asserts a MATCH on differing case and a MISS on a different
    value, which a widened selector could not produce."""
    got = _run(
        "[document.querySelectorAll('button[data-testid*=\"model\" i]').length,"
        " document.querySelectorAll('button').length]",
        [{"tag": "button", "text": "Pro", "attrs": {"data-testid": "MODEL-switcher"}},
         {"tag": "button", "text": "Send", "attrs": {"data-testid": "send-button"}}],
    )
    assert got["result"] == [1, 2], got


def test_the_shim_closest_honours_a_COMMA_LIST():
    """⛔ Without the split, `closest('[role="menu"], [role="dialog"]')` demands both roles on one
    element and answers null for every page — so the in-overlay exclusion never fires."""
    got = _run(
        "(function(){ var b = document.querySelector('button');"
        " return [!!b.closest('[role=\"menu\"], [role=\"dialog\"]'),"
        "         !!b.closest('[role=\"listbox\"]')]; })()",
        [{"tag": "div", "role": "dialog", "children": [{"tag": "button", "text": "Pro"}]}],
    )
    assert got["result"] == [True, False], got


def test_the_shim_can_set_and_re_query_an_attribute():
    """The mark-then-press handoff is only real if a mark is findable afterwards."""
    got = _run(
        "(function(){ var b = document.querySelector('button'); b.setAttribute('data-x', 'y');"
        " var n = document.querySelectorAll('[data-x=\"y\"]').length;"
        " b.removeAttribute('data-x');"
        " return [n, document.querySelectorAll('[data-x=\"y\"]').length]; })()",
        [{"tag": "button", "text": "Pro"}],
    )
    assert got["result"] == [1, 0], got


# ── inert vs aria-hidden, executed against the shipped runtime ────────────────────────────────


def _blocking_ancestor_js() -> str:
    """The shipped `S.blockingAncestor` body, wrapped so node can call it.

    ⚠ Extracted from the runtime the app actually injects, not retyped. A copy here would pass
    while the shipped rule said something else — which is the failure this whole file exists for.
    """
    src = (Path(__file__).resolve().parents[2] / "emubackend/substrate/runtime_js.py").read_text()
    marker = "S.blockingAncestor = function (el) {"
    assert marker in src, "blockingAncestor vanished — these tests would assert nothing"
    body = src.split(marker, 1)[1].split("\n  };", 1)[0]
    return (
        "(function(){ var el = document.querySelector('#prompt-textarea');"
        " var fn = function (el) {" + body + "};"
        " return fn(el); })()"
    )


def test_ARIA_HIDDEN_alone_is_not_reported_as_blocking():
    """⛔ **Measured on the live page, 2026-08-14.** ChatGPT's own composer — `#prompt-textarea`,
    class `ProseMirror`, label "Chat with ChatGPT" — carries `aria-hidden="true"` as NORMAL markup.
    `aria-hidden` is an accessibility-tree hint with no effect on focus, editing or `execCommand`;
    only `inert` makes a subtree non-editable. Conflating them made every ChatGPT run report
    *"composer was blocked … Escape did not dismiss it"* about a perfectly writable composer.
    """
    src = (Path(__file__).resolve().parents[2] / "emubackend/substrate/runtime_js.py").read_text()
    body = src.split("S.blockingAncestor = function (el) {", 1)[1].split("\n  };", 1)[0]
    js = (
        "(function(){ var el = document.querySelector('#prompt-textarea');"
        " var fn = function (el) {" + body + "};"
        " return fn(el); })()"
    )
    got = _run(js, [{"tag": "div", "attrs": {"id": "prompt-textarea", "aria-hidden": "true"},
                     "class": "ProseMirror", "text": "x"}])
    assert got["result"]["why"] == "aria-hidden", got
    assert got["result"]["blocking"] is False, "aria-hidden was reported as a real block"


def test_a_REAL_blocker_ABOVE_an_aria_hidden_composer_is_still_found():
    """⛔⛔ **THE 2026-08-17 P1 FAILURE, in one fixture.** The walk used to RETURN at the first node
    carrying either attribute — and on ChatGPT that node is the composer ITSELF, which was reported
    `blocking:false`. Whatever was neutralising the page sat ABOVE it and this function could not
    see it: the overlay handler waved the page through as advisory, the fill walked into a subtree
    that took neither focus nor a caret, and P1 died with a message naming the composer as the only
    finding. The nearest REAL blocker has to win over an advisory one found earlier.
    """
    got = _run(_blocking_ancestor_js(), [{
        "tag": "div", "attrs": {"inert": ""}, "class": "modal-backdrop",
        "children": [{"tag": "div", "attrs": {"id": "prompt-textarea", "aria-hidden": "true"},
                      "class": "ProseMirror", "text": "x"}],
    }])

    result = got["result"]
    assert result["why"] == "inert", f"the walk stopped at the composer's own aria-hidden: {result}"
    assert result["blocking"] is True, result
    # ...and the advisory finding is still REPORTED, one entry earlier in the chain, so the next
    # failure can say what was between the element and the blocker.
    assert [c["why"] for c in result["chain"]] == ["aria-hidden", "inert"], result
    assert result["chain"][0]["self"] is True, "the composer's own finding lost its identity"


def test_VISIBILITY_HIDDEN_blocks_even_though_the_element_still_has_a_rect():
    """⭐ The blocker that survives every other check. `visibility:hidden` keeps the box — the live
    failure reported `rect=341x42` on an element that could not be focused — while refusing focus
    and refusing to hold a selection. A rect therefore proves nothing about writability, which is
    exactly how the last run's evidence was read.
    """
    got = _run(_blocking_ancestor_js(), [{
        "tag": "div", "style": {"visibility": "hidden"},
        "children": [{"tag": "div", "attrs": {"id": "prompt-textarea"}, "text": "x"}],
    }])

    assert got["result"]["why"] == "visibility:hidden", got
    assert got["result"]["blocking"] is True, got


def test_an_ORDINARY_composer_in_an_ordinary_page_is_not_blocked_at_all():
    """The negative that keeps the rest honest: with computed style now consulted on every ancestor,
    a page that declares no style must still come back `null` rather than inventing a blocker."""
    got = _run(_blocking_ancestor_js(), [{
        "tag": "div", "children": [{"tag": "div", "attrs": {"id": "prompt-textarea"}, "text": "x"}],
    }])

    assert got["result"] is None, got


def _clear_overlay_js() -> str:
    """The shipped `S.clearOverlay`, wired to a minimal `S` so node can run it.

    ⚠ Builds `S` from the SHIPPED bodies of both functions rather than stubbing `blockingAncestor` —
    a stub would let `clearOverlay` be tested against a verdict the real detector never produces,
    which is how the two halves of a rule drift apart while both look covered.
    """
    src = (Path(__file__).resolve().parents[2] / "emubackend/substrate/runtime_js.py").read_text()
    anc = src.split("S.blockingAncestor = function (el) {", 1)[1].split("\n  };", 1)[0]
    clear = src.split("S.clearOverlay = function (id) {", 1)[1].split("\n  };", 1)[0]
    return (
        "(function(){ var S = {};"
        " S.blockingAncestor = function (el) {" + anc + "};"
        " S.get = function (id) { return {el: document.querySelector('#prompt-textarea')}; };"
        " S.clearOverlay = function (id) {" + clear + "};"
        " return S.clearOverlay(1); })()"
    )


def test_an_ARIA_HIDDEN_composer_is_ESCAPED_but_still_reported_as_ADVISORY():
    """⛔⛔ **The premise this rule used to rest on is disproved by the repo's own capture.** The old
    branch returned immediately, pressing nothing, because `aria-hidden` was believed to be part of
    ChatGPT's normal composer markup. `artifacts/gate_zero/chatgpt_dr_completed.html` — captured
    through this app's own web view on 2026-08-08, during a run where the fill SUCCEEDED — shows the
    composer as `contenteditable="true" class="ProseMirror ProseMirror-focused"` with no
    `aria-hidden` on it or above it. Marked ⇒ the fill failed (2026-08-17); unmarked ⇒ the fill
    worked (2026-08-08). It is a symptom of a dialog, and worth one Escape.

    ⚠ Still `advisory` and still `ok`: an attribute never decides whether the run may proceed. Only
    the caret test does, and failing here would kill a recoverable page on an accessibility hint.
    """
    got = _run(_clear_overlay_js(),
               [{"tag": "div", "attrs": {"id": "prompt-textarea", "aria-hidden": "true"},
                 "class": "ProseMirror", "text": "x"}])
    result = got["result"]
    assert result["advisory"] is True, result
    assert result["ok"] is True, result
    # ⚠ The MECHANISM: an Escape really was dispatched at the document, not merely contemplated.
    # Asserting on `cleared:false` alone would pass against a branch that presses nothing at all.
    assert [e["key"] for e in got["events"]] == ["Escape", "Escape"], got["events"]
    assert result["cleared"] is False, result
    assert "did not dismiss it" not in result["note"], result


def _insert_text_js(text: str = "hello") -> str:
    """The shipped `S.insertText`, wired to the same `S` helpers the runtime gives it.

    ⚠ Extracted, never retyped: the point is to run the bytes the device runs.
    """
    src = (Path(__file__).resolve().parents[2] / "emubackend/substrate/runtime_js.py").read_text()
    anc = src.split("S.blockingAncestor = function (el) {", 1)[1].split("\n  };", 1)[0]
    ins = src.split("S.insertText = function (id, text) {", 1)[1].split("\n  };", 1)[0]
    return (
        "(function(){ var S = {};"
        " S.blockingAncestor = function (el) {" + anc + "};"
        " S.get = function (id) { return {el: document.querySelector('#prompt-textarea')}; };"
        " S.elementText = function (el) { return el.innerText || ''; };"
        " S.insertText = function (id, text) {" + ins + "};"
        f" return S.insertText(1, {text!r}); }})()"
    )


def test_a_caret_that_cannot_be_placed_is_RETRIED_after_one_ESCAPE():
    """⭐ **The recovery the live P1 needed.** On 2026-08-17 the fill gave up the moment the caret
    would not go in, and the run died on a page that was one keypress from working — a dialog had
    neutralised the editor and nothing ever tried to dismiss it, because the detector had already
    classified the composer's own `aria-hidden` as harmless.

    ⚠ Asserts the ESCAPE, not merely the failure. A version that gave up without pressing anything
    reaches the identical `no-caret` return, so the outcome alone cannot tell the two apart.
    """
    got = _run(_insert_text_js("hello"), [{
        # A dialog that neutralises the page and DOES close on Escape — the ordinary case: a login
        # nag, a "what's new", a consent sheet.
        "tag": "div", "attrs": {"inert": ""}, "class": "modal", "escapeRemoves": True,
        "children": [{
            "tag": "div", "class": "ProseMirror",
            "attrs": {"id": "prompt-textarea", "contenteditable": "true", "aria-hidden": "true"},
        }],
    }])

    # The MECHANISM: an Escape was dispatched...
    assert [e["key"] for e in got["events"]][:2] == ["Escape", "Escape"], got["events"]
    # ...and the fill then SUCCEEDED, by the path that says it needed rescuing.
    assert got["result"]["ok"] is True, got["result"]
    assert got["result"]["path"] == "execCommand-after-escape", got["result"]


def test_a_STUCK_dialog_still_fails_rather_than_typing_into_nothing():
    """The other half: Escape is one attempt, not a guarantee. A dialog that does not close must
    still produce the distinct `no-caret` verdict — the run typing into a neutralised editor and
    reporting success is the outcome this whole path exists to prevent."""
    got = _run(_insert_text_js(), [{
        "tag": "div", "attrs": {"inert": ""}, "class": "stuck-modal",
        "children": [{
            "tag": "div", "class": "ProseMirror",
            "attrs": {"id": "prompt-textarea", "contenteditable": "true"},
        }],
    }])

    assert got["result"]["ok"] is False, got["result"]
    assert got["result"]["path"] == "no-caret", got["result"]


def test_the_no_caret_message_reports_BLOCKED_from_the_verdict_not_from_truthiness():
    """⛔ It printed `'inert=' + !!S.blockingAncestor(el)` — and that function returns a truthy
    OBJECT in the non-blocking case too, so an advisory finding was reported as `inert=true` right
    next to its own `blocking:false`. The message contradicted itself, and the contradiction is what
    sent the first reading of this failure after a modal that was not there.
    """
    got = _run(_insert_text_js(), [{
        "tag": "div", "attrs": {"inert": ""}, "class": "stuck-modal",
        "children": [{
            "tag": "div", "class": "ProseMirror",
            "attrs": {"id": "prompt-textarea", "contenteditable": "true", "aria-hidden": "true"},
        }],
    }])

    err = got["result"]["err"]
    assert "blocked=true" in err, err
    assert "focusTook=false" in err, f"the message does not say whether focus took: {err}"
    # ⭐ The whole chain, so the next failure names what was ABOVE the first hit instead of stopping
    # at the composer's own advisory attribute — which is what made the live one unreadable.
    assert '"why":"aria-hidden"' in err and '"why":"inert"' in err, err

    # ⛔ And the coercion itself must not come back. The message read `'inert=' + !!blockingAncestor`,
    # which is `true` for a finding that says `blocking:false`; a behavioural test cannot catch its
    # RETURN, because the same words would be printed either way on a page that really is blocked.
    src = (Path(__file__).resolve().parents[2] / "emubackend/substrate/runtime_js.py").read_text()
    assert "!!S.blockingAncestor" not in src, "a truthiness test against the finding object is back"


def test_clearOverlay_STILL_tries_to_dismiss_a_genuinely_INERT_subtree():
    """The advisory path must not swallow the real one — `inert` genuinely prevents editing, and a
    modal that neutralised the page is exactly what Escape is for."""
    got = _run(_clear_overlay_js(),
               [{"tag": "div", "attrs": {"inert": ""}, "children": [
                   {"tag": "div", "attrs": {"id": "prompt-textarea"}, "text": "x"},
               ]}])
    result = got["result"]
    assert result.get("advisory") is not True, result
    assert result["blocker"]["why"] == "inert", result


def test_INERT_is_reported_as_blocking():
    src = (Path(__file__).resolve().parents[2] / "emubackend/substrate/runtime_js.py").read_text()
    body = src.split("S.blockingAncestor = function (el) {", 1)[1].split("\n  };", 1)[0]
    js = (
        "(function(){ var el = document.querySelector('#prompt-textarea');"
        " var fn = function (el) {" + body + "};"
        " return fn(el); })()"
    )
    got = _run(js, [{"tag": "div", "attrs": {"inert": ""}, "children": [
        {"tag": "div", "attrs": {"id": "prompt-textarea"}, "text": "x"},
    ]}])
    assert got["result"]["why"] == "inert", got
    assert got["result"]["blocking"] is True, "inert must still block — it genuinely prevents editing"


# ── the public-access verdict ─────────────────────────────────────────────────────────────────


def test_the_strict_verify_reads_the_triggers_OWN_text_and_not_its_options():
    """⛔ Material-style dropdowns put the option list INSIDE the trigger when open, so reading
    `innerText` matches the phrase on a dropdown that is merely open — and reports a PRIVATE
    notebook as verified public."""
    js = _extract("verifyPublicJS")
    open_dropdown = [{
        "tag": "div", "role": "dialog",
        "children": [{
            "tag": "button", "role": "combobox", "text": "Restricted",
            "children": [{"tag": "div", "role": "option", "text": "Anyone with the link"}],
        }],
    }]
    assert _run(js, open_dropdown)["result"] is False


def test_the_strict_verify_accepts_the_triggers_own_text():
    js = _extract("verifyPublicJS")
    settled = [{
        "tag": "div", "role": "dialog",
        "children": [{"tag": "button", "role": "combobox", "text": "Anyone with the link"}],
    }]
    assert _run(js, settled)["result"] is True


def test_an_aria_selected_option_also_verifies():
    js = _extract("verifyPublicJS")
    selected = [{
        "tag": "div", "role": "dialog",
        "children": [{"tag": "div", "role": "option", "text": "Anyone with the link",
                      "attrs": {"aria-selected": "true"}}],
    }]
    assert _run(js, selected)["result"] is True


def test_a_page_with_no_dialog_verifies_nothing():
    js = _extract("verifyPublicJS")
    assert _run(js, [{"tag": "div", "text": "Anyone with the link"}])["result"] is False


# ── opening the access control, and picking the option ────────────────────────────────────────


def test_the_access_opener_fires_on_a_RESTRICTED_control():
    js = _extract("openAccessJS")
    got = _run(js, [{"tag": "button", "text": "Restricted", "attrs": {"data-id": "access"}}])
    assert got["result"] == "opened"
    assert got["clicks"] == ["access"]


def test_the_access_opener_does_NOT_fire_when_nothing_names_an_access_level():
    """⚠ The desktop's diagnostic recorded a run choosing `control='Search results'` — the people
    picker's listbox — simply because it was the first combobox in document order."""
    js = _extract("openAccessJS")
    got = _run(js, [{"tag": "button", "role": "combobox", "text": "Search results"}])
    assert got["result"] == ""
    assert got["clicks"] == []


def test_anyone_with_the_link_is_the_option_that_gets_picked():
    js = _extract("pickAnyoneJS")
    got = _run(js, [
        {"tag": "li", "role": "option", "text": "Only people you add", "attrs": {"data-id": "no"}},
        {"tag": "li", "role": "option", "text": "Anyone with the link", "attrs": {"data-id": "yes"}},
    ])
    assert got["result"] == "selected"
    assert got["clicks"] == ["yes"]


# ── reading the link ──────────────────────────────────────────────────────────────────────────


def test_the_share_link_is_read_from_a_readonly_input():
    js = _extract("readShareLinkJS")
    got = _run(js, [{
        "tag": "div", "role": "dialog", "rect": {"left": 0, "top": 0, "width": 400, "height": 300},
        "children": [{"tag": "input", "attrs": {"readonly": ""},
                      "value": "https://notebook.google.com/notebook/abc"}],
    }])
    assert got["result"]["url"] == "https://notebook.google.com/notebook/abc"
    assert got["result"]["via"] == "input"


def test_a_NON_GOOGLE_url_in_the_dialog_is_not_taken_as_the_notebook_link():
    """The read ranges over the page, so the host predicate is the only thing standing between a
    stray input and an arbitrary link published as the owner's notebook."""
    js = _extract("readShareLinkJS")
    got = _run(js, [{
        "tag": "div", "role": "dialog", "rect": {"left": 0, "top": 0, "width": 400, "height": 300},
        "children": [{"tag": "input", "attrs": {"readonly": ""},
                      "value": "https://evil.test/notebook/abc"}],
    }])
    assert got["result"]["url"] == ""


def test_the_RENAMED_host_is_still_a_notebook_url():
    """⛔ Google renamed this host and four gates keyed on the old literal went dark at once."""
    js = _extract("readShareLinkJS")
    for host in ("notebook.google.com", "notebooklm.google.com"):
        got = _run(js, [{
            "tag": "div", "role": "dialog",
            "rect": {"left": 0, "top": 0, "width": 400, "height": 300},
            "children": [{"tag": "input", "attrs": {"readonly": ""},
                          "value": f"https://{host}/notebook/abc"}],
        }])
        assert got["result"]["url"].endswith("/notebook/abc"), host


def test_the_copy_fallback_stays_INSIDE_the_dialog_and_reports_no_dialog_otherwise():
    """⛔ A page-wide 'any button whose text contains copy' search is a real click on whatever the
    notebook happens to render. The channel is the diagnosis: `no_dialog` is a broken opener, an
    open dialog with no link is a moved field, and the two need different fixes."""
    js = _extract("readShareLinkJS")
    got = _run(js, [{"tag": "button", "text": "Copy link", "attrs": {"data-id": "stray"}}])
    assert got["result"] == {"url": "", "via": "no_dialog"}
    assert got["clicks"] == []


def test_the_copy_button_inside_a_dialog_IS_pressed():
    js = _extract("readShareLinkJS")
    got = _run(js, [{
        "tag": "div", "role": "dialog", "rect": {"left": 0, "top": 0, "width": 400, "height": 300},
        "children": [{"tag": "button", "text": "Copy link", "attrs": {"data-id": "copy"},
                      "rect": {"left": 10, "top": 10, "width": 90, "height": 40}}],
    }])
    assert got["result"] == {"url": "clipboard", "via": "copy"}
    assert got["clicks"] == ["copy"]


def test_a_control_parked_OFFSCREEN_is_not_pressed():
    """⚠ NotebookLM parks `button[aria-label="Chat options"]` at x=-36 with a full-size rect and a
    live offsetParent. Neither visibility test catches it; the click point does."""
    js = _extract("readShareLinkJS")
    got = _run(js, [{
        "tag": "div", "role": "dialog", "rect": {"left": 0, "top": 0, "width": 400, "height": 300},
        "children": [{"tag": "button", "text": "Copy link",
                      "rect": {"left": -80, "top": 10, "width": 40, "height": 40}}],
    }])
    assert got["clicks"] == []
    assert got["result"]["via"] == "no_link_in_dialog"


# ── the audio card ────────────────────────────────────────────────────────────────────────────


def test_a_GENERATING_placeholder_means_not_ready_even_with_an_item_present():
    js = _extract("audioCompleteJS")
    assert _run(js, [{
        "tag": "div", "class": "artifact-library-container",
        "children": [
            {"tag": "div", "text": "Generating Audio Overview…"},
            {"tag": "artifact-library-item", "text": "audio_magic_eraser My podcast"},
        ],
    }])["result"] is False


def test_a_finished_card_is_ready():
    js = _extract("audioCompleteJS")
    assert _run(js, [{
        "tag": "div", "class": "artifact-library-container",
        "children": [{"tag": "artifact-library-item", "text": "audio_magic_eraser My podcast"}],
    }])["result"] is True


def test_a_HIDDEN_card_is_not_a_finished_podcast():
    js = _extract("audioCompleteJS")
    assert _run(js, [{
        "tag": "div", "class": "artifact-library-container",
        "children": [{"tag": "artifact-library-item", "visible": False,
                      "text": "audio_magic_eraser My podcast"}],
    }])["result"] is False


# ── the customise arrow, which must never be the card body ────────────────────────────────────


def test_the_customise_arrow_is_clicked_and_the_card_body_is_NOT():
    """⛔ Clicking the card BODY fires NotebookLM's one-click DEFAULT audio — the confirmed source
    of duplicate podcasts."""
    js = _extract("openCustomiseJS")
    got = _run(js, [{
        "tag": "basic-create-artifact-button",
        "children": [
            {"tag": "div", "ariaLabel": "Audio Overview", "attrs": {"data-id": "CARD-BODY"}},
            {"tag": "button", "ariaLabel": "Customise Audio Overview",
             "attrs": {"data-id": "arrow"}},
        ],
    }])
    assert got["result"] is True
    assert got["clicks"] == ["arrow"], "the card body was clicked — that is the duplicate"


def test_the_AMERICAN_spelling_also_resolves():
    js = _extract("openCustomiseJS")
    got = _run(js, [{"tag": "button", "ariaLabel": "Customize Audio Overview",
                     "attrs": {"data-id": "arrow"}}])
    assert got["clicks"] == ["arrow"]


def test_no_arrow_means_FALSE_and_no_click_at_all():
    js = _extract("openCustomiseJS")
    got = _run(js, [{"tag": "div", "ariaLabel": "Audio Overview", "attrs": {"data-id": "body"}}])
    assert got["result"] is False
    assert got["clicks"] == []


# ── picking format and length ─────────────────────────────────────────────────────────────────


def test_the_option_pick_is_EXACT_and_does_not_take_a_neighbour():
    """⚠ 'Long' is a prefix of 'Longer'. Picking a neighbouring option produces a perfectly good
    podcast of the wrong length, which nothing downstream flags."""
    got = _run(_pick_option_js("Long"), [
        {"tag": "div", "role": "option", "text": "Longer", "attrs": {"data-id": "wrong"}},
        {"tag": "div", "role": "option", "text": "Long", "attrs": {"data-id": "right"}},
    ])
    assert got["clicks"] == ["right"]


def test_an_ICON_LIGATURE_does_not_stop_an_option_from_matching():
    """Material icons bleed into innerText: the row reads `tune Deep Dive`, not `Deep Dive`."""
    got = _run(_pick_option_js("Deep Dive"), [
        {"tag": "div", "role": "option", "text": "Deep Dive", "icons": ["tune"],
         "attrs": {"data-id": "dd"}},
    ])
    assert got["clicks"] == ["dd"]


def test_a_HIDDEN_option_is_not_picked():
    got = _run(_pick_option_js("Brief"), [
        {"tag": "div", "role": "option", "text": "Brief", "visible": False},
    ])
    assert got["result"] is False


# ── the download row ──────────────────────────────────────────────────────────────────────────


def test_DOWNLOAD_is_pressed_and_DELETE_two_rows_below_it_is_not():
    """⛔ The menu reads `save_alt Download` … `delete Delete`. A row identified by its icon name is
    a row identified by position, and Delete sits two rows under Download."""
    js = _extract("clickDownloadRowJS")
    got = _run(js, [
        {"tag": "div", "role": "menuitem", "text": "Share", "icons": ["share"]},
        {"tag": "div", "role": "menuitem", "text": "Download", "icons": ["save_alt"],
         "attrs": {"data-id": "download"}},
        {"tag": "div", "role": "menuitem", "text": "Delete", "icons": ["delete"],
         "attrs": {"data-id": "DELETE"}},
    ])
    assert got["result"] is True
    assert got["clicks"] == ["download"]


def test_a_RENAME_row_whose_ligature_differs_from_its_label_is_not_mistaken_for_download():
    """⚠ `edit Rename` is the case no regex can strip — the ligature and the label are different
    words. The structural strip (subtract each icon element's text) is what handles it."""
    js = _extract("clickDownloadRowJS")
    got = _run(js, [
        {"tag": "div", "role": "menuitem", "text": "Rename", "icons": ["edit"]},
    ])
    assert got["clicks"] == []


def test_with_no_menu_open_the_overflow_control_is_pressed_and_FALSE_is_returned():
    """Two beats in one evaluate would race the menu's render, so the first pass opens it and
    reports 'not yet' — which is why this is safe to call more than once."""
    js = _extract("clickDownloadRowJS")
    got = _run(js, [{
        "tag": "artifact-library-item", "text": "audio_magic_eraser My podcast",
        "children": [{"tag": "button", "ariaLabel": "More options", "attrs": {"data-id": "more"},
                      "rect": {"left": 10, "top": 10, "width": 40, "height": 40}}],
    }])
    assert got["result"] is False
    assert got["clicks"] == ["more"]


# ── Generate ──────────────────────────────────────────────────────────────────────────────────


def test_a_DISABLED_generate_button_is_not_pressed():
    """A Generate that is still disabled means the panel has not settled; pressing it is a no-op
    that the caller would read as a started generation."""
    js = _extract("clickGenerateJS")
    got = _run(js, [{"tag": "button", "text": "Generate", "disabled": True}])
    assert got["result"] is False
    assert got["clicks"] == []


def test_generate_is_pressed_when_it_is_live():
    js = _extract("clickGenerateJS")
    got = _run(js, [{"tag": "button", "text": "Generate", "attrs": {"data-id": "gen"}}])
    assert got["clicks"] == ["gen"]


if __name__ == "__main__":  # pragma: no cover
    pytest.main([__file__])
