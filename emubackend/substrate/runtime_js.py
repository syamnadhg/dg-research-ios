"""The in-page JS runtime the seam injects — `window.__sr`.

B0a proved the substrate against a fixture page that *shipped* its own probe surface. A real
platform page obviously does not, so that surface becomes an injectable runtime. It provides
three things the seam cannot work without:

1. **A handle registry.** Playwright's ``query_selector`` returns an opaque handle that stays
   valid across later calls. Over ``Runtime.evaluate`` there is no such object, so elements
   are parked in a JS-side ``Map`` and referenced by integer id. Detached nodes are detected
   and reported rather than silently no-op'ing.
2. **A calibration surface.** The CSS-pixel → screen-point transform must be *measured*
   (see :mod:`emubackend.substrate.geometry`), which needs a surface that reports where a tap
   landed. On a real page that means briefly overlaying one. Taps during calibration hit the
   overlay and never reach the page, so the site cannot observe them — the overlay is the
   isolation, not just the sensor.
3. **An event recorder** carrying ``isTrusted``, which is the whole reason the HID channel
   exists: JS-dispatched events report ``isTrusted === false`` and the chat SPAs reject them.

Idempotent by construction: re-injecting is safe and cheap, which matters because a
navigation wipes the runtime and there is no reliable "did we navigate" signal to trust.
"""

from __future__ import annotations

__all__ = ["NS", "RUNTIME_JS", "ensure_js"]

#: The single global this runtime installs. Deliberately one name, and deliberately obscure
#: enough not to collide with a platform's own globals.
NS = "__sr"

RUNTIME_JS = r"""
(function () {
  if (window.__sr && window.__sr.v === 4) { return 'already'; }
  // docId identifies THIS document's runtime install. A navigation creates a new one, so a
  // handle minted before the navigation can be reported as "the page navigated" instead of
  // the far more confusing "no-such-handle" — which reads like a bug in the registry rather
  // than a fact about the page.
  var S = { v: 4, n: 0, m: new Map(), events: [], overlay: null,
            docId: String(Date.now()) + '-' + Math.random().toString(36).slice(2, 8) };

  // ---- handle registry ------------------------------------------------------------
  S.reg = function (el) {
    if (!el) return null;
    var id = ++S.n;
    S.m.set(id, el);
    return id;
  };
  S.get = function (id) {
    var el = S.m.get(id);
    if (!el) return { err: 'no-such-handle' };
    // A node removed from the document is the common stale case, and an operation that
    // quietly does nothing on it is far worse than one that says so.
    if (!el.isConnected) return { err: 'detached' };
    return { el: el };
  };
  S.release = function (id) { return S.m.delete(id); };
  S.doc = function () { return S.docId; };

  S.query = function (sel) {
    try { return S.reg(document.querySelector(sel)); } catch (e) { return null; }
  };
  S.queryAll = function (sel) {
    try {
      return Array.prototype.map.call(document.querySelectorAll(sel), function (el) {
        return S.reg(el);
      });
    } catch (e) { return []; }
  };

  // ---- element reads --------------------------------------------------------------
  S.rectOf = function (id) {
    var h = S.get(id); if (h.err) return h;
    var r = h.el.getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height,
             cx: r.left + r.width / 2, cy: r.top + r.height / 2 };
  };
  S.textOf = function (id) {
    var h = S.get(id); if (h.err) return h;
    return { text: h.el.innerText };
  };
  S.attrOf = function (id, name) {
    var h = S.get(id); if (h.err) return h;
    return { value: h.el.getAttribute(name) };
  };
  S.visibleOf = function (id) {
    var h = S.get(id); if (h.err) return { visible: false };
    var el = h.el, r = el.getBoundingClientRect(), cs = getComputedStyle(el);
    return { visible: !!(r.width && r.height) && cs.visibility !== 'hidden'
                      && cs.display !== 'none' && cs.opacity !== '0' };
  };
  S.scrollIntoView = function (id) {
    var h = S.get(id); if (h.err) return h;
    h.el.scrollIntoView({ block: 'center', inline: 'center' });
    return { ok: true };
  };

  // ---- text entry ----------------------------------------------------------------
  // ProseMirror and other rich composers keep an internal model, so setting .value or
  // .textContent leaves the model empty and the send button disabled. execCommand
  // ('insertText') is the one path that drives the model — which is why it survives here
  // despite being deprecated.
  // ⭐ VERIFIES, and falls back. Measured 2026-08-14: ChatGPT's P1 failed with
  // `unresolved(key:"send")` because execCommand had returned FALSE, that false was discarded by
  // every caller, and ChatGPT's send button only exists while the composer is non-empty — so the
  // real failure (no text) surfaced one step later wearing the name of a selector that was fine.
  //
  // ⛔ The rule this now enforces is one the repo already wrote down, in bin/gate_zero_run.py:
  // "execCommand returning true is not evidence the editor took it." The gate read the text back;
  // the product did not. Reading it back HERE costs nothing — the element is already in hand — and
  // it is the only way to tell an editor that accepted the text from one that ignored it.
  // ⛔ **`elementText`, NOT `textOf`.** `S.textOf(id)` already exists above — it takes a HANDLE ID
  // and is what `innerText` reads go through. A second definition under the same name silently
  // replaced it, so every existing caller passed a number into a function expecting an element and
  // the page threw `TypeError: el is not an Object` on `'value' in el`. Measured live 2026-08-14:
  // it killed ChatGPT and Gemini outright, and only spared Claude because that path failed first.
  // ⛔ WHAT is blocking the editor, not merely THAT something is.
  //
  // Measured live 2026-08-14: ChatGPT's composer reported `inert=true` with real layout
  // (308x276) and a focused document — so a modal was open over the page. `inert` and
  // `aria-hidden` are how every modal library (and the `<dialog>` element) neutralise the
  // background: the content is neither focusable nor editable, `focus()` no-ops, and
  // synthetic events are ignored. Naming the blocker is the difference between "a menu is
  // open" and knowing WHICH one, which is what decides how to dismiss it.
  S.blockingAncestor = function (el) {
    try {
      var node = el;
      // ⛔⛔ **THE 2026-08-17 P1 FAILURE. This loop used to RETURN at the first node carrying
      // either attribute — and on ChatGPT that node is the composer ITSELF.** So the walk stopped
      // at `#prompt-textarea`'s own `aria-hidden`, reported `blocking:false`, `clearOverlay` waved
      // it through as advisory, and the fill then walked into a subtree that took neither focus nor
      // a caret: `activeIsEditor=false`, `selectionIsInside()=false`, on an element with a real
      // 341x42 rect. Whatever was actually neutralising the page sat ABOVE the first hit and this
      // function was structurally incapable of seeing it.
      //
      // ⚠ And `aria-hidden` on the composer is not the innocent marker the previous comment claimed.
      // It is how ChatGPT neutralises the BACKGROUND when a dialog opens — so finding it on the
      // composer is a reason to keep walking, not a reason to stop.
      var blocking = null, advisory = null, chain = [];
      while (node && node !== document.documentElement) {
        // ⛔ **`inert` blocks; `aria-hidden` DOES NOT.** They were treated as the same thing, and
        // the live page proved the difference on 2026-08-14: ChatGPT's own composer
        // (`#prompt-textarea`, class ProseMirror) carries `aria-hidden="true"` as part of its NORMAL
        // markup — a rich-text editor hiding its visual layer from assistive tech while exposing an
        // accessible twin. `aria-hidden` is an accessibility-tree hint with no effect on focus,
        // editing or `execCommand`; `inert` is what makes a subtree non-focusable and non-editable.
        //
        // Conflating them made every ChatGPT run report *"composer was blocked … Escape did not
        // dismiss it"* about a composer that was perfectly writable — a confident, wrong diagnosis
        // pointing the next session at a modal that does not exist, and an Escape press sent at a
        // page that had nothing to dismiss.
        var inert = node.hasAttribute && node.hasAttribute('inert');
        var ariaHidden = node.hasAttribute && node.getAttribute('aria-hidden') === 'true';
        // ⭐ **Two more ways to be un-focusable, and both survive the rect test that made the
        // composer look healthy.** `display:none` removes layout, but `visibility:hidden` keeps the
        // box — `getBoundingClientRect()` still reports 341x42 — while refusing focus and refusing
        // to hold a selection. A failure that reports a real rect therefore proves nothing about
        // whether the element could be typed into, which is exactly how the last run read.
        var css = null;
        try { css = window.getComputedStyle(node); } catch (e) { css = null; }
        var invisible = css && css.visibility === 'hidden' ? 'visibility:hidden'
                      : (css && css.display === 'none' ? 'display:none' : null);
        var why = inert ? 'inert' : (invisible || (ariaHidden ? 'aria-hidden' : null));
        if (why) {
          var found = {
            tag: node.tagName,
            id: node.id || '',
            cls: (node.className && String(node.className).slice(0, 60)) || '',
            label: (node.getAttribute('aria-label') || '').slice(0, 40),
            why: why,
            self: node === el,
            // Whether this actually stops the caller acting, as opposed to merely being worth
            // reporting. `aria-hidden` alone does not; everything else here does.
            blocking: why !== 'aria-hidden'
          };
          chain.push(found);
          if (found.blocking) { if (!blocking) { blocking = found; } }
          else if (!advisory) { advisory = found; }
        }
        node = node.parentElement;
      }
      // ⚠ The nearest REAL blocker wins over a merely advisory one, whichever was found first. The
      // return stays a single object so every existing caller keeps working; `chain` rides along so
      // the next failure can name what was above the first hit instead of guessing at it.
      var answer = blocking || advisory;
      if (!answer) { return null; }
      // ⛔ **A NEW object, not the finding with `chain` bolted on.** `answer` is itself an element
      // of `chain`, so assigning `answer.chain = chain` makes the structure circular — and the very
      // next thing that happens to this value is `JSON.stringify`, both in the no-caret message and
      // in the bridge that returns it to Swift. The failure path would have thrown while reporting
      // the failure, which is the one moment it must not. Caught by the shim, which serialises
      // exactly as the device does.
      return {
        tag: answer.tag, id: answer.id, cls: answer.cls, label: answer.label,
        why: answer.why, self: answer.self, blocking: answer.blocking,
        chain: chain
      };
    } catch (e) { return null; }
  };

  /// Close whatever modal is neutralising the page, and say whether it worked.
  ///
  /// ⚠ Escape at the DOCUMENT, not at the element: the element is inside the inert subtree and
  /// cannot receive anything. Modal libraries listen for keydown on document/window.
  S.clearOverlay = function (id) {
    var h = S.get(id); if (h.err) return h;
    var before = S.blockingAncestor(h.el);
    if (!before) { return { ok: true, cleared: false, note: 'nothing was blocking' }; }
    // ⛔⛔ **The advisory branch used to RETURN here, and that was built on a premise the repo's own
    // capture disproves.** It claimed ChatGPT's composer carries `aria-hidden` as normal markup —
    // but `artifacts/gate_zero/chatgpt_dr_completed.html`, captured through this app's own web view
    // on 2026-08-08 during a run where this very function filled this very element, shows
    // `<div contenteditable="true" class="ProseMirror ProseMirror-focused" id="prompt-textarea">`
    // with NO `aria-hidden` anywhere on it or above it. Two live data points now agree: marked ⇒
    // the fill fails (2026-08-17), unmarked ⇒ the fill works (2026-08-08). The mark is a SYMPTOM of
    // a dialog neutralising the page, not decoration — so it is worth one Escape.
    //
    // ⚠ Still reported as advisory rather than as a block: what decides whether the run may proceed
    // is whether a caret can actually be placed, measured by `insertText`, never an attribute.
    var advisoryOnly = !before.blocking;
    try {
      ['keydown', 'keyup'].forEach(function (type) {
        document.dispatchEvent(new KeyboardEvent(type, {
          key: 'Escape', code: 'Escape', keyCode: 27, which: 27,
          bubbles: true, cancelable: true
        }));
      });
    } catch (e) {}
    var after = S.blockingAncestor(h.el);
    return {
      // ⚠ `ok` stays TRUE for an advisory finding that survived. Escape is worth trying on the
      // symptom, but a page that still reports `aria-hidden` afterwards is not thereby proven
      // unusable — only a caret test proves that — and failing the phase here would turn a
      // recoverable page into a dead run on the strength of an accessibility attribute.
      ok: !after || advisoryOnly,
      cleared: !after,
      advisory: advisoryOnly,
      blocker: before,
      still: after,
      note: !after ? 'dismissed by Escape'
            : (advisoryOnly
               ? 'aria-hidden survived Escape — reported, not treated as a block; the caret test decides'
               : 'Escape did not dismiss it')
    };
  };

  S.elementText = function (el) {
    if (!el || typeof el !== 'object') { return ''; }
    return ('value' in el && typeof el.value === 'string') ? el.value : (el.innerText || '');
  };

  S.insertText = function (id, text) {
    var h = S.get(id); if (h.err) return h;
    var el = h.el;
    var want = String(text);
    // The first 24 characters, matching what gate_zero_run.py probes for. Full equality is the
    // wrong test: editors normalise whitespace, wrap lines and insert zero-width characters.
    var probe = want.slice(0, 24);
    var landed = function () {
      var now = S.elementText(el);
      return probe.length ? now.indexOf(probe) >= 0 : now.length > 0;
    };

    // ⛔ **Focus is ATTEMPTED and then CHECKED, and the check is new.** `el.focus()` is a silent
    // no-op on a neutralised subtree — it throws nothing and returns nothing, so the code below
    // proceeded to place a caret in an element that had never become the active one, and the whole
    // failure surfaced three steps later as "no caret". Retried once after any real blocker has
    // been cleared, because the run's own overlay handling may have just removed it.
    el.focus();
    var focusTook = document.activeElement === el;
    if (!focusTook) {
      // ProseMirror and Lexical both mount the editable as a DESCENDANT in some builds, in which
      // case focusing the queried root does nothing and the real target is one level in.
      var inner = el.querySelector && el.querySelector('[contenteditable="true"]');
      if (inner && inner !== el) { try { inner.focus(); } catch (e) {} }
      // ⚠ `!!` around the whole thing: `false || null` is NULL in JavaScript, so without it the
      // field printed `focusTook=null` — which reads as "not measured" rather than "measured, and
      // it did not take", and those send a reader to different places.
      focusTook = !!(document.activeElement === el
        || (inner && document.activeElement === inner));
    }
    var editable = el.isContentEditable
      || (el.getAttribute && el.getAttribute('contenteditable') === 'true');

    // ⛔ **A CARET INSIDE THE ELEMENT, placed explicitly.** `execCommand('insertText')` edits the
    // current SELECTION, and `el.focus()` on a rich composer does not necessarily create one —
    // ProseMirror/Lexical mount an empty contenteditable with no range at all. Measured live
    // 2026-08-14: with `document.hasFocus()===true`, `execCommand('insertText')` still returned
    // FALSE, because there was nothing selected to insert into.
    //
    // ⚠ And it must be scoped to `el`. `document.execCommand('selectAll')` selects the DOCUMENT
    // when the selection is not already inside the editor — so the clear below could select the
    // whole page and the delete would either do nothing or damage it.
    var putRange = function (collapse) {
      try {
        // ⛔ Into the LAST BLOCK CHILD, not the root. The real composer is
        // `<div id="prompt-textarea"><p><br class="ProseMirror-trailingBreak"></p></div>` — and a
        // caret collapsed on the ROOT sits *between block children*, which is a position
        // ProseMirror normalises away before the edit lands.
        var target = (collapse && el.lastElementChild) ? el.lastElementChild : el;
        var r = document.createRange();
        r.selectNodeContents(target);
        if (collapse) { r.collapse(false); }   // caret at the end
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(r);
        return true;
      } catch (e) { return false; }
    };
    var selectionIsInside = function () {
      try {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return false;
        return el.contains(sel.getRangeAt(0).commonAncestorContainer);
      } catch (e) { return false; }
    };

    // ⚠ CLEARED first, and this is a real bug fix rather than tidiness. The value branch below used
    // to APPEND (`el.value = (el.value || '') + text`), so a retry of the same research typed the
    // prompt twice into one composer. Clearing also makes the read-back unambiguous: whatever is
    // there afterwards was put there by this call.
    if (!editable && 'value' in el) { el.value = ''; }

    if (editable) {
      // ⚠ ONE transaction. This used to be select-all → delete → re-collapse → insert, which is
      // three edits and gives a controlled editor two chances to reconcile in between.
      // `insertText` over a NON-COLLAPSED range replaces it, so selecting the existing contents and
      // inserting does the clear and the fill as a single `beforeinput`.
      var existing = S.elementText(el);
      var placed = putRange(existing.length > 0 ? false : true);
      // Whether the caret only became placeable after an Escape. Reported in the success path so a
      // run that needed rescuing is distinguishable in the trace from one that never had a problem
      // — "it worked" and "it worked on the second try, because a dialog was up" are different
      // facts about the page, and only one of them is worth chasing.
      var recovered = false;

      // ⛔ Gate on the CARET, and name this failure distinctly. `execCommand('insertText')` returns
      // false *before attempting anything* when there is no range inside an editable root — which
      // is a completely different fault from an editor that took the selection and refused the
      // text, and the two were previously reported identically.
      // ⭐ **One Escape, then try again — the recovery the live failure needed.** A caret that
      // cannot be placed is the only reliable evidence that something is neutralising the editor,
      // and the overwhelmingly common cause is a dialog the page put up (a login nag, a "what's
      // new", a consent sheet). Escaping BLIND here is safe in a way it is not earlier: we are past
      // every step that opens something of our own, and we only do it once we have measured that
      // the editor is unusable. Without this the run died on a page one keypress from working.
      if (!placed || !selectionIsInside()) {
        try {
          ['keydown', 'keyup'].forEach(function (type) {
            document.dispatchEvent(new KeyboardEvent(type, {
              key: 'Escape', code: 'Escape', keyCode: 27, which: 27,
              bubbles: true, cancelable: true
            }));
          });
        } catch (e) {}
        try { el.focus(); } catch (e) {}
        placed = putRange(existing.length > 0 ? false : true);
        if (placed && selectionIsInside()) { recovered = true; }
      }
      if (!placed || !selectionIsInside()) {
        // ⛔ **ONE read, and it names what it measured.** This called `blockingAncestor` TWICE and
        // printed `'inert=' + !!<that object>` — but the function returns a truthy object in the
        // NON-blocking case too, so every advisory finding was reported as `inert=true` next to its
        // own `blocking:false`. The message contradicted itself, and the contradiction sent the
        // first read of this failure at a modal that was not there.
        var blk = S.blockingAncestor(el);
        return {
          ok: false, verified: false, path: 'no-caret',
          err: 'no caret could be placed inside the editor'
            + ' (hasFocus=' + document.hasFocus()
            + ' activeIsEditor=' + (document.activeElement === el)
            + ' focusTook=' + focusTook
            + ' blocked=' + !!(blk && blk.blocking)
            + ' blocker=' + JSON.stringify(blk)
            + ' rect=' + Math.round(el.getBoundingClientRect().width) + 'x'
            + Math.round(el.getBoundingClientRect().height) + ')'
        };
      }

      var ok = false;
      try { ok = document.execCommand('insertText', false, want); } catch (e) { ok = false; }
      if (landed()) {
        return {
          ok: true, verified: true,
          path: recovered ? 'execCommand-after-escape' : 'execCommand'
        };
      }

      // execCommand is refused when the document is not focused — which is the normal state of a
      // web view driven off-screen — and some editors decline it outright. A synthetic paste is
      // the path those editors DO handle, because paste is a first-class input for them.
      try {
        var dt = new DataTransfer();
        dt.setData('text/plain', want);
        el.dispatchEvent(new ClipboardEvent('paste', {
          clipboardData: dt, bubbles: true, cancelable: true
        }));
      } catch (e) {}
      if (landed()) return { ok: true, path: 'paste', verified: true };

      // Last resort: the input events a controlled editor listens to directly.
      try {
        el.dispatchEvent(new InputEvent('beforeinput', {
          inputType: 'insertText', data: want, bubbles: true, cancelable: true
        }));
        el.dispatchEvent(new InputEvent('input', {
          inputType: 'insertText', data: want, bubbles: true
        }));
      } catch (e) {}
      if (landed()) return { ok: true, path: 'beforeinput', verified: true };

      // ⛔ Reported as a REFUSAL, never as a path. Returning a path here is what made an empty
      // composer look like a successful fill for the whole life of this code.
      return {
        ok: false, verified: false, path: 'refused',
        err: 'the editor refused the text (execCommand=' + ok + ', paste and beforeinput also '
          + 'left it unchanged); document.hasFocus()=' + document.hasFocus()
          + ' selectionInEditor=' + selectionIsInside()
          + ' activeIsEditor=' + (document.activeElement === el),
        after: S.elementText(el).slice(0, 60)
      };
    }

    if ('value' in el) {
      el.value = want;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      if (landed()) return { ok: true, path: 'value+input', verified: true };
      return {
        ok: false, verified: false, path: 'refused',
        err: 'the field did not keep the value it was given',
        after: S.elementText(el).slice(0, 60)
      };
    }
    return { err: 'not-a-text-target' };
  };

  S.selectAll = function (id) {
    var h = S.get(id); if (h.err) return h;
    h.el.focus();
    try { document.execCommand('selectAll'); return { ok: true }; }
    catch (e) { return { err: String(e) }; }
  };

  // ---- viewport ------------------------------------------------------------------
  // Reported so the caller can use REAL mobile metrics. The desktop pipeline's 1280x800 is
  // load-bearing in geometry gates and in the CUA/Vision screen size, and carrying it onto
  // a 402x714 surface would put every computed coordinate in the wrong place.
  S.viewport = function () {
    var vv = window.visualViewport || {};
    return {
      innerWidth: window.innerWidth, innerHeight: window.innerHeight,
      dpr: window.devicePixelRatio,
      scrollX: window.scrollX, scrollY: window.scrollY,
      vvWidth: vv.width, vvHeight: vv.height,
      vvOffsetLeft: vv.offsetLeft, vvOffsetTop: vv.offsetTop,
      vvPageLeft: vv.pageLeft, vvPageTop: vv.pageTop,
      vvScale: vv.scale
    };
  };

  // ---- event recorder ------------------------------------------------------------
  S.reset = function () { S.events = []; return true; };

  S.record = function (e) {
    // TouchEvent carries no clientX of its own; the coordinates live on touches[0].
    var cx = e.clientX, cy = e.clientY;
    if (cx === undefined && e.touches && e.touches.length) {
      cx = e.touches[0].clientX; cy = e.touches[0].clientY;
    }
    var t = e.target;
    S.events.push({
      type: e.type,
      isTrusted: e.isTrusted,
      clientX: cx === undefined ? null : cx,
      clientY: cy === undefined ? null : cy,
      targetId: (t && t.id) || null,
      targetTag: (t && t.tagName) || null,
      onOverlay: !!(t && t.dataset && t.dataset.srOverlay),
      viewport: S.viewport()
    });
    if (S.events.length > 60) { S.events.shift(); }
  };

  ['pointerdown', 'touchstart', 'click'].forEach(function (t) {
    document.addEventListener(t, S.record, true);  // capture phase: nothing can pre-empt us
  });

  // ---- copy interception ---------------------------------------------------------
  // The supported way to read "what the page copied". navigator.clipboard.readText()
  // requires a user gesture plus a permission grant, and the Simulator's system pasteboard
  // is global state shared across tabs and runs — so we capture the page's own copy event
  // instead of reading the OS. Installed up front because a listener added after the copy
  // has already fired is useless.
  S.__lastCopy = undefined;
  document.addEventListener('copy', function (e) {
    try {
      var sel = String(document.getSelection());
      var dt = e.clipboardData && e.clipboardData.getData('text/plain');
      S.__lastCopy = dt || sel || undefined;
    } catch (err) { /* never let interception break the page's own copy */ }
  }, true);

  // ---- calibration overlay -------------------------------------------------------
  // Covers the visual viewport so probe taps land on a surface we control instead of on the
  // page. `position: fixed` with inset 0 tracks the visual viewport, so it stays correct
  // when the URL bar collapses or the keyboard opens.
  S.calib = function (on) {
    if (on) {
      if (!S.overlay) {
        var d = document.createElement('div');
        d.dataset.srOverlay = '1';
        d.setAttribute('style', [
          'position:fixed', 'left:0', 'top:0', 'right:0', 'bottom:0',
          'z-index:2147483647', 'background:transparent', 'pointer-events:auto',
          'margin:0', 'padding:0', 'border:0'
        ].join(';'));
        (document.body || document.documentElement).appendChild(d);
        S.overlay = d;
      }
    } else if (S.overlay) {
      S.overlay.remove();
      S.overlay = null;
    }
    return !!S.overlay;
  };

  window.__sr = S;
  return 'installed';
})()
"""


def ensure_js() -> str:
    """The expression to evaluate before using any other runtime call.

    Returns ``'installed'`` or ``'already'``. Call it after every navigation — a page load
    wipes the runtime, and there is no navigation signal over this transport worth trusting,
    so the cheap idempotent re-injection is the reliable option.
    """
    return RUNTIME_JS
