import Foundation

/// ChatGPT's activity panel — the shimmering line, and what is behind it.
///
/// ⭐ **With Pro selected, this is the only place the run's progress exists.** Measured live
/// 2026-08-17: seven minutes into a Pro brief the response container still held **45 characters**,
/// byte-identical for 1250 consecutive polls, while the model worked. A run watching only that
/// container can say nothing truthful about what is happening — and the frontend's narration strip
/// and raw-activity panel, which both render from events this device has never emitted, stayed
/// empty for every run it has ever served.
///
/// The anchors below are the desktop backend's, ported rather than invented: `research.py`'s
/// `_open_chatgpt_activity_panel` and its host-page panel scrape. Where the two could drift, the
/// desktop's wording wins — a shared account means one of them is always about to meet a page the
/// other has already learned.
public enum ActivityPanel {

    /// One reading of the panel.
    public struct Snapshot: Equatable, Sendable {
        public var panelFound: Bool = false
        /// Step rows, newest last — the narration lines.
        public var steps: [String] = []
        /// Source links, already unwrapped and filtered.
        public var sources: [Source] = []
        /// The strip's own text ("Pro thinking", "Research completed in 8m · 17 citations").
        public var progress: String = ""

        public init(panelFound: Bool = false, steps: [String] = [],
                    sources: [Source] = [], progress: String = "") {
            self.panelFound = panelFound
            self.steps = steps
            self.sources = sources
            self.progress = progress
        }
    }

    public struct Source: Equatable, Hashable, Sendable {
        public let url: String
        public let title: String
        public init(url: String, title: String) {
            self.url = url
            self.title = title
        }
    }

    /// The attribute stamped on the strip about to be pressed.
    ///
    /// ⚠ Marked in JS, pressed through the page's own click path — never `el.click()`. Measured on
    /// this device's own corpus: a synthetic click opened ChatGPT's React overlays 0 times out of 7
    /// attempts across two menus, because their handlers listen on `pointerdown`. The desktop
    /// reaches the same conclusion from the other side and dispatches a full pointer sequence.
    public static let stripMark = "data-sr-activity-strip"

    /// Find the live activity strip and mark it, ranked.
    ///
    /// The scoring is the desktop's, tier for tier: an ellipsis-bearing verb line is the actual
    /// click target with the React handler on it, so it outranks the presentational wrappers that
    /// merely contain a count. `ELLIPSIS` is the structural anchor — live narration always ends in
    /// one, whatever the wording of the week is — and the verb list is only the fallback for a
    /// strip that has not materialised a count yet.
    public static let markStripJS = """
    (function(){
      var COUNT = /\\b\\d+\\s+(?:searches?|sources?|results?|citations?)\\b/i;
      var COMPLETED = /\\bresearch\\s+completed\\b|\\bcompleted\\s+in\\s+\\d+\\s*(?:s|m|min|h)\\b/i;
      var STATUS_LINE = /^(?:[\\w.+-]{1,12}\\s+)?(?:thinking|reasoning|researching)\\b/i;
      var VERB = /^(thinking|reasoning|searching|looking|browsing|investigating|analyzing|reading|exploring|checking|visiting|researching)\\b/i;
      var ELLIPSIS = /(?:\\.{3}|\\u2026)\\s*$/;
      var prev = document.querySelector('[\\(stripMark)]');
      if (prev) { prev.removeAttribute('\\(stripMark)'); }
      var best = null, bestScore = 0, scanned = 0;
      var all = document.querySelectorAll('div, span, button, [role="button"], p, li');
      for (var i = 0; i < all.length && scanned < 8000; i++) {
        var el = all[i];
        scanned++;
        // A leaf-ish node only: the strip's own text, not a section that contains it.
        if (el.querySelector('div, span, button, p, li')) { continue; }
        var t = (el.innerText || '').trim();
        // ⚠ Length-capped so prose cannot match a status line. The desktop caps at 60 for the same
        // reason: "thinking" appears in ordinary sentences all day.
        if (!t || t.length > 60) { continue; }
        var rect = el.getBoundingClientRect();
        if (rect.width < 40 || rect.height < 8) { continue; }
        var hasEllipsis = ELLIPSIS.test(t), hasVerb = VERB.test(t);
        var hasCount = COUNT.test(t), hasCompleted = COMPLETED.test(t);
        var hasStatus = STATUS_LINE.test(t);
        var score = 0;
        if (hasEllipsis && hasVerb) { score = 5; }
        else if (hasEllipsis && hasCount) { score = 4.5; }
        else if (hasCompleted) { score = 4; }
        else if (hasEllipsis) { score = 3.5; }
        else if (hasStatus) { score = 3.2; }
        else if (hasVerb && hasCount) { score = 3; }
        else if (hasVerb) { score = 2; }
        else if (hasCount) { score = 1; }
        if (score > bestScore) { bestScore = score; best = el; }
      }
      if (!best) { return { found: false, scanned: scanned }; }
      best.setAttribute('\\(stripMark)', '1');
      return {
        found: true, score: bestScore, scanned: scanned,
        text: (best.innerText || '').trim().slice(0, 60)
      };
    })()
    """

    /// Scrape whatever panel is open.
    ///
    /// ⚠ Geometry first, wording second. The panel is identified by being a tall thing on the right
    /// of the viewport with real text in it, because every class name and aria-label ChatGPT has
    /// used for it has changed at least once; its position has not.
    public static let scrapeJS = """
    (function(){
      var out = { panelFound: false, steps: [], sources: [], progress: '' };
      var strip = document.querySelector('[\\(stripMark)]');
      if (strip) { out.progress = (strip.innerText || '').trim().slice(0, 120); }
      var sels = [
        'aside', '[role="complementary"]', '[role="region"]',
        '[aria-label*="source" i]', '[aria-label*="research" i]', '[aria-label*="activity" i]',
        '[class*="panel" i]'
      ];
      var root = null;
      for (var s = 0; s < sels.length && !root; s++) {
        var els = document.querySelectorAll(sels[s]);
        for (var i = 0; i < els.length; i++) {
          var rc = els[i].getBoundingClientRect();
          if (rc.width < 280 || rc.height < 200) { continue; }
          // Right-hand side of the viewport: the panel slides in from there on every layout this
          // has ever shipped with, and the gate is what keeps the whole conversation from matching.
          if (rc.right < window.innerWidth * 0.55) { continue; }
          if (((els[i].innerText || '').trim()).length < 50) { continue; }
          root = els[i]; break;
        }
      }
      if (!root) { return out; }
      out.panelFound = true;

      // Leaf rows only — a row that contains other rows is a container, and taking both duplicates
      // every line under its own section heading.
      var rowEls = root.querySelectorAll('li, [role="listitem"], div, p');
      var seen = {}, steps = [];
      for (var r = 0; r < rowEls.length && steps.length < 60; r++) {
        var el = rowEls[r];
        if (el.querySelector('li, [role="listitem"], div, p')) { continue; }
        var t = (el.innerText || '').trim().replace(/\\s+/g, ' ');
        if (t.length < 12 || t.length > 240) { continue; }
        if (seen[t]) { continue; }
        seen[t] = 1;
        steps.push(t);
      }
      out.steps = steps;

      var links = root.querySelectorAll('a[href]');
      var seenURL = {};
      for (var k = 0; k < links.length && out.sources.length < 50; k++) {
        var href = links[k].getAttribute('href') || '';
        if (!href) { continue; }
        // ⛔ Unwrap the redirector. ChatGPT rewrites citations through its own domain, so the raw
        // href is a chatgpt.com URL that names nothing — the desktop learned this by collecting a
        // panel full of links that all pointed at ChatGPT.
        var m = href.match(/[?&](?:url|u|q)=([^&]+)/);
        if (m) { try { href = decodeURIComponent(m[1]); } catch (e) {} }
        if (!/^https?:/i.test(href)) { continue; }
        if (/^https?:\\/\\/(?:chatgpt\\.com|chat\\.openai\\.com|openai\\.com)/i.test(href)) { continue; }
        if (seenURL[href]) { continue; }
        seenURL[href] = 1;
        out.sources.push({
          url: href,
          title: ((links[k].innerText || '').trim().replace(/\\s+/g, ' ')).slice(0, 120)
        });
      }
      return out;
    })()
    """
}

/// What has already been reported, so each tick emits only what is new.
///
/// ⛔ **A stateless emitter would republish the whole panel every two seconds.** The panel redraws
/// its full list on every step, so "what it says now" and "what changed" are entirely different
/// questions — and the frontend appends narration rather than replacing it, so the first shape
/// would fill the strip with the same sentence sixty times.
public struct ActivityStream {
    /// Step lines already emitted, in order — kept as a list, not a Set, so the CAP can drop the
    /// oldest rather than an arbitrary member.
    private var seenSteps: [String] = []
    private var seenURLs: [String] = []

    /// How many step lines are remembered. Beyond this the oldest are forgotten, which can at worst
    /// re-narrate a line from an hour ago; remembering everything on a forty-minute phase is the
    /// alternative, and that grows without bound.
    public static let stepMemory = 400
    /// The frontend unions and caps source URLs at 50; matching it here keeps the two agreeing.
    public static let urlCap = 50

    public init() {}

    /// New step lines and new sources, in the order the panel listed them.
    public struct Delta: Equatable {
        public var steps: [String] = []
        public var sources: [ActivityPanel.Source] = []
        public var isEmpty: Bool { steps.isEmpty && sources.isEmpty }
    }

    /// Total sources seen so far — what the agent card's count renders.
    public var sourceCount: Int { seenURLs.count }
    public var allURLs: [String] { seenURLs }

    public mutating func absorb(_ snapshot: ActivityPanel.Snapshot) -> Delta {
        var delta = Delta()
        for step in snapshot.steps where !seenSteps.contains(step) {
            seenSteps.append(step)
            delta.steps.append(step)
        }
        if seenSteps.count > Self.stepMemory {
            seenSteps.removeFirst(seenSteps.count - Self.stepMemory)
        }
        for source in snapshot.sources where !seenURLs.contains(source.url) {
            guard seenURLs.count < Self.urlCap else { break }
            seenURLs.append(source.url)
            delta.sources.append(source)
        }
        return delta
    }
}

/// A reference-typed `ActivityStream`, because the reduction is stateful and the readings arrive
/// from the pipeline's own task.
///
/// ⚠ Locked rather than actor-isolated: the callback is synchronous by design — it runs inside the
/// response poll and must not suspend it — and an actor would force every reading through an await
/// in the middle of the loop the whole feature exists to keep responsive.
public final class ActivityStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = ActivityStream()

    public init() {}

    public func absorb(_ snapshot: ActivityPanel.Snapshot) -> ActivityStream.Delta {
        lock.lock(); defer { lock.unlock() }
        return stream.absorb(snapshot)
    }

    public var sourceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stream.sourceCount
    }

    public var allURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return stream.allURLs
    }
}

/// Holds P1's brief the moment it exists.
///
/// ⚠ A reference type because the pipeline reports it from its own task while `runPhases` is still
/// awaiting — a captured `var` would be a copy, which is the value-type join that compiles, runs,
/// and quietly keeps nothing.
public final class BriefBox: @unchecked Sendable {
    private let lock = NSLock()
    private var brief: String?

    public init() {}

    public func set(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if !text.isEmpty { brief = text }
    }

    public var value: String? {
        lock.lock(); defer { lock.unlock() }
        return brief
    }
}
