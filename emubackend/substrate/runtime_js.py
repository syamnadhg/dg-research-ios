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
  S.insertText = function (id, text) {
    var h = S.get(id); if (h.err) return h;
    var el = h.el;
    el.focus();
    var editable = el.isContentEditable
      || (el.getAttribute && el.getAttribute('contenteditable') === 'true');
    if (editable) {
      var ok = document.execCommand('insertText', false, text);
      return { ok: ok, path: 'execCommand' };
    }
    if ('value' in el) {
      el.value = (el.value || '') + text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true, path: 'value+input' };
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
