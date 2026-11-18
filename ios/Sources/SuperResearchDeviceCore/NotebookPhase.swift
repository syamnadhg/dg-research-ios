import Foundation

/// P3 on the device: a notebook holding the consolidated research, made public, turned into an
/// Audio Overview at the owner's configured length, and downloaded.
///
/// ⭐ **Every JS block below is PORTED from the production backend rather than written here**, and
/// that provenance is the only reason to trust selectors nobody can measure on this surface today:
/// they were pinned from real NotebookLM DOM dumps after the guessed ones were found to match
/// nothing (`_check_audio_complete_dom`'s original selectors *"could NEVER fire"*). Where a port
/// was impossible — the desktop leans on a vision agent for the customise panel, and this device
/// has none — it is marked as an honest limit rather than smoothed over.
///
/// ⚠ **Deliberately NOT a fifth `InAppPipeline` phase.** The three research platforms share one
/// shape (compose → send → wait → extract) and NotebookLM shares none of it: no composer, no
/// response container, no completion by content stability. Forcing it into that shape is how a
/// phase ends up asserting the wrong things about itself.
public struct NotebookPhaseDriver {

    public enum NotebookError: Error, Equatable {
        /// The consolidated report is too thin to make a podcast from.
        case sourceTooShort(chars: Int)
        /// No notebook could be created or opened, so there is nothing to add a source to.
        case noNotebook(String)
        /// The paste sheet never appeared, or the source never landed.
        ///
        /// ⚠ Carries what was actually tried, because on this surface the likeliest cause is
        /// specific and worth naming: every click available to the pipeline is `isTrusted === false`,
        /// and the one time this sheet was opened it was opened by a REAL tap.
        case sourceNotAccepted(String)
        case audioNeverStarted(String)
        case audioNeverReady(waitedSeconds: Int)
        case audioNotDownloadable(String)
    }

    /// What the share flow achieved. Three facts, not one, for the reason the backend separated
    /// them: a URL read off a notebook whose access was never changed is a PRIVATE link, and it is
    /// indistinguishable from a public one by shape — same `/notebook/{id}` path. The recipient of
    /// the P5 email gets "Request access" instead of a notebook.
    public struct ShareOutcome: Equatable, Sendable {
        public let url: String
        /// The dialog confirmed "Anyone with the link" back to us — a deliberately strict read.
        public let publicVerified: Bool
        /// We actually clicked an "Anyone with the link" option (or found it already set).
        ///
        /// ⚠ This, not `publicVerified`, is the healthy-run signal. The backend records that its
        /// strict verify *"has been False on every run in the corpus"*, so gating anything on it is
        /// gating on a constant.
        public let accessSet: Bool
        public let reason: String
    }

    let driver: InAppPhaseDriver
    private var page: WebPage { driver.page }

    public init(driver: InAppPhaseDriver) {
        self.driver = driver
    }

    public init(manifest: [String: [String]], texts: [String: String] = [:],
                openers: [String: String] = [:], page: WebPage) {
        self.driver = InAppPhaseDriver(
            platform: "notebooklm", manifest: manifest, texts: texts, openers: openers, page: page
        )
    }

    // MARK: - Navigation

    /// Where the web view is.
    ///
    /// ⚠ Read through `location.href` rather than added to the `WebPage` protocol. Navigation on
    /// this platform is same-site, so `location` is a complete answer, and widening the protocol
    /// would force every existing conformer — including two test fakes — to grow a method that only
    /// this file calls.
    public func currentURL() async throws -> String {
        (try? await page.evaluateJSON("String(location.href)")) as? String ?? ""
    }

    public func navigate(_ url: String) async throws {
        _ = try? await page.evaluateJSON("(function(){ location.assign(\(Self.js(url))); return true; })()")
    }

    /// The notebook id in a NotebookLM URL, or "".
    ///
    /// ⚠ Used to detect DRIFT, which the backend records as a verified root cause: *"between
    /// generate and download the page can drift … and a drifted page surfaces a DIFFERENT
    /// notebook's audio card"*. The download then takes another run's podcast, and nothing fails.
    public static func notebookID(_ url: String) -> String {
        guard let range = url.range(of: "/notebook/") else { return "" }
        let rest = url[range.upperBound...]
        let id = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return String(id)
    }

    // MARK: - 1. The notebook

    /// Create a notebook and return its URL.
    ///
    /// ⚠ Polled for the URL rather than assumed: creation navigates, and the id only exists after
    /// the server answers. Returning the pre-navigation URL would anchor every later step —
    /// including the download re-anchor — to the notebook LIST.
    public func createNotebook(
        attempts: Int = 30,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
        // Already inside a notebook (a resumed run) — do not create a second one. Every P3 creates
        // a PERMANENT notebook in the owner's real Google account and nothing anywhere cleans them
        // up, so a retry that creates rather than reuses is a cost that accumulates for ever.
        let existing = try await currentURL()
        if !Self.notebookID(existing).isEmpty { return existing }

        guard let create = try await driver.optional("create_notebook") else {
            throw NotebookError.noNotebook("no 'Create new notebook' control on the page")
        }
        try await page.click(create)
        for _ in 0..<attempts {
            let url = try await currentURL()
            if !Self.notebookID(url).isEmpty { return url }
            try? await sleep(.milliseconds(1000))
        }
        throw NotebookError.noNotebook(
            "the create control was clicked but the page never reached a /notebook/ URL"
        )
    }

    // MARK: - 2. The source

    /// Minimum characters before a consolidated report is worth generating a podcast from.
    public static let minSourceChars = 200

    /// Paste the consolidated report in as the notebook's single source.
    ///
    /// ⭐ **Pasted, not uploaded, and that is a measured result rather than a shortcut.** The page
    /// carries ZERO `input[type=file]` on mobile, so the file route the desktop backend uses is
    /// CLOSED here, while "Copied text" is a first-class source type.
    ///
    /// ⚠ ONE source, not three. One paste is one interaction; three are three chances for a sheet
    /// to close early, and the Audio Overview is generated from the notebook as a whole regardless.
    public func addSource(
        _ text: String, notebookURL: String,
        attempts: Int = 20,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= Self.minSourceChars else {
            throw NotebookError.sourceTooShort(chars: body.count)
        }

        // ⛔ The add-source sheet is reached by NAVIGATING, not by tapping. The manifest records the
        // opener as `__url:?addSource=true` — and nothing in either half of this codebase read that
        // prefix, so the machine-readable opener was inert prose. Handled here, where the one key
        // that uses it lives.
        let opener = driver.openers["add_source"] ?? ""
        if opener.hasPrefix("__url:") {
            let query = String(opener.dropFirst("__url:".count))
            let base = notebookURL.split(separator: "?").first.map(String.init) ?? notebookURL
            try await navigate(base + query)
            try? await sleep(.milliseconds(2000))
        }

        guard let copiedText = try await driver.optional("add_source") else {
            throw NotebookError.sourceNotAccepted("no 'Copied text' source type on the add-source sheet")
        }
        // Scrolled first because the control sits BELOW the fold — measured at client y=709 against
        // a 644px visible region. The tap guard refuses an off-screen target, correctly.
        _ = try? await page.evaluateJSON(
            "(function(){var h=window.__sr && window.__sr.get(\(copiedText));"
                + "if(h && h.el && h.el.scrollIntoView) h.el.scrollIntoView({block:'center'});"
                + "return true;})()"
        )
        try? await sleep(.milliseconds(500))
        try await page.click(copiedText)

        // The OUTCOME is the textarea appearing, and it is asserted rather than assumed.
        //
        // ⚠ This is the step most likely to fail on this surface and the failure would otherwise be
        // attributed to the paste. The one time this sheet was opened it was opened by a REAL tap
        // (`isTrusted=true`); every click the pipeline itself can make reports `isTrusted === false`,
        // and a synthetic click is measured elsewhere in this project to leave overlay-style
        // controls completely unmoved. So a missing textarea gets a message that names that cause.
        var textarea: Int?
        for _ in 0..<attempts {
            if let found = try await driver.optional("source_textarea") { textarea = found; break }
            try? await sleep(.milliseconds(500))
        }
        guard let textarea else {
            throw NotebookError.sourceNotAccepted(
                "'Copied text' was clicked but the paste textarea never appeared — the only click "
                + "primitive on this surface is untrusted, and this sheet has only ever been opened "
                + "by a real tap"
            )
        }

        let path = try await page.insertText(textarea, body)
        guard let path, path != "not-a-text-target" else {
            throw NotebookError.sourceNotAccepted("the paste textarea would not take the text")
        }
        guard let insert = try await driver.optional("insert_source") else {
            throw NotebookError.sourceNotAccepted("the paste sheet has no Insert control")
        }
        try await page.click(insert)
    }

    // MARK: - 3. The public link

    /// The dialog containers the share reads and clicks inside. One list, so a Material rename moves
    /// every user of it at once.
    static let dialogScopes = "[role=\"dialog\"], mat-dialog-container, [class*=\"dialog\"]"

    /// Open Share, set access to "Anyone with the link", read the link, save.
    ///
    /// ⛔ **Degrades, never fails.** Ported from the backend's shape deliberately: a run that has
    /// spent three deep-research units and produced a podcast must not die because sharing was
    /// refused. The notebook's own URL comes back with `publicVerified` false and a reason, and the
    /// caller writes it with `verified: false` so the truth travels with the link.
    public func share(
        notebookURL: String,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> ShareOutcome {
        var accessSet = false
        var alreadyPublic = false
        var url = ""

        guard let shareButton = try await driver.optional("share") else {
            return ShareOutcome(
                url: notebookURL, publicVerified: false, accessSet: false,
                reason: "no Share control on the notebook — the link is the private notebook URL"
            )
        }
        try await page.click(shareButton)
        try? await sleep(.milliseconds(1500))

        let opened = (try? await page.evaluateJSON(Self.openAccessJS)) as? String ?? ""
        if opened == "opened" {
            try? await sleep(.milliseconds(1000))
            let picked = (try? await page.evaluateJSON(Self.pickAnyoneJS)) as? String ?? ""
            try? await sleep(.milliseconds(1000))
            if picked == "selected" {
                accessSet = true
            } else if let state = (try? await page.evaluateJSON(Self.accessAlreadyPublicJS)) as? Bool,
                      state {
                // ⭐ Finding the control already on target and not touching it is the BEST outcome,
                // not a failure — the opener only fires on a control reading Restricted/Private, so
                // on a second share of an already-public notebook there is by design nothing left
                // to click.
                accessSet = true
                alreadyPublic = true
            }
        }

        let read = (try? await page.evaluateJSON(Self.readShareLinkJS)) as? [String: Any] ?? [:]
        let channel = read["via"] as? String ?? "unknown"
        let candidate = read["url"] as? String ?? ""
        if candidate == "clipboard" {
            try? await sleep(.milliseconds(500))
            if let clip = (try? await page.evaluateJSON(
                "(async () => { try { return String(await navigator.clipboard.readText()); }"
                    + " catch (e) { return ''; } })()"
            )) as? String, Self.isNotebookURL(clip) {
                url = clip.trimmingCharacters(in: .whitespaces)
            }
        } else if Self.isNotebookURL(candidate) {
            url = candidate.trimmingCharacters(in: .whitespaces)
        }

        let verified = ((try? await page.evaluateJSON(Self.verifyPublicJS)) as? Bool) ?? false
        // Save AFTER the verify — the dialog's own state is what is being read, and saving closes it.
        _ = try? await page.evaluateJSON(Self.saveShareJS)
        try? await sleep(.milliseconds(1000))

        // ⚠ Falling back to the notebook URL is the degrade, and it is recorded as one. Returning
        // "" instead would leave the P3 tile with no NotebookLM row at all, which reads as "P3 never
        // ran" rather than as "the link may be private".
        let finalURL = url.isEmpty ? notebookURL : url
        let reason: String
        if verified {
            reason = "the dialog confirmed 'Anyone with the link'"
        } else if alreadyPublic {
            reason = "access already read 'Anyone with the link' — nothing to change"
        } else if accessSet {
            reason = "the 'Anyone with the link' option was clicked but the dialog did not confirm "
                + "it back; the strict check is inconclusive here, not negative"
        } else {
            reason = "access was NEITHER set nor verified — this link may genuinely be private "
                + "(share-link read channel: \(channel))"
        }
        return ShareOutcome(
            url: finalURL, publicVerified: verified, accessSet: accessSet, reason: reason
        )
    }

    /// Is this a NotebookLM notebook URL?
    ///
    /// ⚠ Host-family, never a hostname literal. Google renamed this product's host once already and
    /// four separate gates keyed on the old literal went dark at the same moment — the outage
    /// presented as "the platform is signed out".
    public static func isNotebookURL(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        guard host == "google.com" || host.hasSuffix(".google.com") else { return false }
        return url.path.hasPrefix("/notebook/") && url.path.count > "/notebook/".count
    }

    // MARK: - 4. The Audio Overview

    /// Open the customise panel and generate one audio overview at *length*.
    ///
    /// ⛔ **The CUSTOMISE ARROW, never the card body.** Clicking the card body fires NotebookLM's
    /// one-click DEFAULT audio — the confirmed source of duplicate podcasts, and the reason the
    /// backend carries a whole prevention path for it. The arrow is a separate control.
    ///
    /// ⛔ **And NOT ONE CLICK AFTER Generate.** The duplicate the backend chased for weeks fires on
    /// the interaction *right after* Generate, so this returns immediately and the readiness poll is
    /// read-only.
    ///
    /// ⚠ **HONEST LIMIT.** The desktop hands the customise panel to a vision agent, so its controls
    /// have never been pinned as selectors — the backend's own code says the panel dump exists
    /// precisely because the Generate and length controls are *"un-supplied"*. What is ported here
    /// is the arrow (pinned from a real console dump) plus a text-driven pick of the format and
    /// length options by their measured labels. If the panel's labels have moved, this returns
    /// false with the state it saw rather than clicking something adjacent.
    @discardableResult
    public func generateAudio(
        length: AudioLength,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Bool {
        // Already generating, or already generated: do not press Generate again. A second press is
        // how the account ends up with two podcasts and the download picks the wrong one.
        if try await audioIsReady() { return false }
        if try await audioIsGenerating() { return false }

        let panelOpened = ((try? await page.evaluateJSON(Self.openCustomiseJS)) as? Bool) ?? false
        try? await sleep(.milliseconds(1500))

        if panelOpened {
            _ = try? await page.evaluateJSON(Self.pickOptionJS(length.format))
            try? await sleep(.milliseconds(1000))
            if let option = length.lengthOption {
                _ = try? await page.evaluateJSON(Self.pickOptionJS(option))
                try? await sleep(.milliseconds(1000))
            }
        }

        let generated = ((try? await page.evaluateJSON(Self.clickGenerateJS)) as? Bool) ?? false
        guard generated else {
            throw NotebookError.audioNeverStarted(
                panelOpened
                    ? "the customise panel opened but no Generate control could be pressed — the "
                        + "panel's controls have never been pinned as selectors on this surface"
                    : "the 'Customise Audio Overview' arrow was not found, and the card BODY must "
                        + "never be clicked as a fallback: that fires the one-click default audio"
            )
        }
        return true
    }

    /// Is an Audio Overview finished?
    ///
    /// ⭐ Pinned from a real DOM dump, and the pinning MATTERS: the selectors this replaced gated on
    /// an `<audio>` element and a progressbar inside an article card, *none of which exist* in the
    /// live panel — so the desktop's DOM-complete check could never once fire and completion
    /// detection rested entirely on a vision agent.
    ///
    /// ⚠ Asks for a positive signal and treats an unreadable page as NOT ready. Generation takes up
    /// to ninety minutes, so a false "ready" reports a podcast that does not exist while a false
    /// "not ready" costs more waiting. Those are not symmetrical.
    public func audioIsReady() async throws -> Bool {
        ((try? await page.evaluateJSON(Self.audioCompleteJS)) as? Bool) ?? false
    }

    public func audioIsGenerating() async throws -> Bool {
        ((try? await page.evaluateJSON(Self.audioGeneratingJS)) as? Bool) ?? false
    }

    /// Wait for the Audio Overview, polling read-only.
    public func awaitAudio(
        timeout: TimeInterval, poll: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Bool {
        let started = now()
        while now().timeIntervalSince(started) < timeout {
            if try await audioIsReady() { return true }
            try? await sleep(poll)
        }
        return false
    }

    // MARK: - 5. The download

    /// Fetch the finished audio as bytes.
    ///
    /// ⭐ **In-page fetch rather than a file download, because there is no download to catch.** The
    /// desktop attaches to Playwright's `download` event and saves to disk; a `WKWebView` inside an
    /// app has neither that event nor a Downloads folder to scan as a fallback. So the row's own URL
    /// is captured at the moment it is clicked and re-fetched with the page's credentials — the same
    /// move gate zero settled for ChatGPT's report, and for the same reason: the bytes are reachable
    /// over the session even when the UI's own delivery path is not.
    ///
    /// ⚠ Read back in CHUNKS. A podcast is tens of megabytes and base64 inflates it by a third;
    /// pushing that through the JS bridge as one string is the kind of thing that fails only on the
    /// long runs, which are the ones that cost the most to repeat.
    public func downloadAudio(
        notebookURL: String,
        chunkBytes: Int = 512 * 1024,
        attempts: Int = 30,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Data {
        // ⚠ Re-anchor first. The backend records a verified root cause: the page drifts between
        // generate and download, and a drifted page surfaces a DIFFERENT notebook's audio card —
        // the download then succeeds and delivers another run's podcast.
        let here = try await currentURL()
        if !Self.notebookID(notebookURL).isEmpty,
           Self.notebookID(here) != Self.notebookID(notebookURL) {
            try await navigate(notebookURL)
            try? await sleep(.seconds(5))
        }

        _ = try? await page.evaluateJSON(Self.armDownloadCaptureJS)
        guard ((try? await page.evaluateJSON(Self.clickDownloadRowJS)) as? Bool) ?? false else {
            throw NotebookError.audioNotDownloadable(
                "no Download row in the audio card's overflow menu"
            )
        }

        var source = ""
        for _ in 0..<attempts {
            if let captured = (try? await page.evaluateJSON(
                "(window.__srAudioCapture && window.__srAudioCapture.url) || ''"
            )) as? String, !captured.isEmpty {
                source = captured
                break
            }
            try? await sleep(.milliseconds(500))
        }
        if source.isEmpty {
            // Fallback: the player's own media source. Reached only when the row produced no
            // navigable URL at all, which is a different failure from an empty fetch.
            source = ((try? await page.evaluateJSON(Self.playerSourceJS)) as? String) ?? ""
        }
        guard !source.isEmpty else {
            throw NotebookError.audioNotDownloadable(
                "the Download row was pressed but no media URL was produced, and the page carries "
                + "no <audio> source to fall back on"
            )
        }

        let total = ((try? await page.evaluateJSON(Self.fetchAudioJS(source))) as? Int) ?? -1
        guard total > 0 else {
            throw NotebookError.audioNotDownloadable(
                total == 0 ? "the audio URL fetched zero bytes"
                           : "the audio URL could not be fetched from the page"
            )
        }

        var data = Data()
        var offset = 0
        while offset < total {
            guard let chunk = (try? await page.evaluateJSON(
                "window.__srAudioRead(\(offset), \(chunkBytes))"
            )) as? String, let decoded = Data(base64Encoded: chunk) else {
                throw NotebookError.audioNotDownloadable(
                    "the audio read stalled at \(offset) of \(total) bytes"
                )
            }
            // ⛔ A zero-length chunk before the end would loop for ever. Treated as a failure rather
            // than as an end-of-stream, because "we got less than the length the page reported" is a
            // truncated podcast and truncated audio plays fine right up to where it stops.
            guard !decoded.isEmpty else {
                throw NotebookError.audioNotDownloadable(
                    "the audio read returned nothing at \(offset) of \(total) bytes"
                )
            }
            data.append(decoded)
            offset += decoded.count
        }
        _ = try? await page.evaluateJSON("(function(){ window.__srAudio = null; return true; })()")
        return data
    }

    // MARK: - The ported JavaScript

    static func js(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'\(escaped)'"
    }

    /// Material icon ligatures BLEED into `innerText`: the audio card's ⋮ menu reads `share Share`,
    /// `save_alt Download`, `delete Delete`.
    ///
    /// ⛔ The strip is STRUCTURAL — subtract the text of every icon element inside the row — because
    /// no regex can tell `edit Rename` (ligature + different label) from a real two-word label. This
    /// matters here specifically: `Delete` sits two rows under `Download` in that menu, and a row
    /// identified by its icon name is a row identified by position.
    static let labelJS = """
      var ICON_SEL = 'mat-icon, .material-icons, .material-icons-extended, '
        + '[class*="material-symbols"], [class*="google-symbols"]';
      var nlmLabel = function (el) {
        var t = el.innerText || el.textContent || '';
        if (el.querySelectorAll) {
          var icons = el.querySelectorAll(ICON_SEL);
          for (var i = 0; i < icons.length; i++) {
            var it = icons[i].innerText || icons[i].textContent || '';
            if (!it) continue;
            var at = t.indexOf(it);
            if (at !== -1) t = t.slice(0, at) + ' ' + t.slice(at + it.length);
          }
        }
        t = t.replace(/\\s+/g, ' ').trim();
        t = t.replace(/^([\\w]+)\\s+(?=\\1\\b)/i, '');
        t = t.replace(/^[a-z]+(?:_[a-z]+)+\\s+/, '');
        return t;
      };
    """

    /// ⚠ NEITHER `offsetParent !== null` NOR a non-zero rect means clickable. NotebookLM parks
    /// `button[aria-label="Chat options"]` at x=-36 with a full-size rect and a live `offsetParent`,
    /// and it matches an `aria-label*="options"` query — one of the hooks the audio ⋮ search uses.
    /// The honest test is the point a click would land on.
    static let onScreenJS = """
      var onScreen = function (el) {
        if (!el || !el.getBoundingClientRect) return false;
        var r = el.getBoundingClientRect();
        if (r.width < 8 || r.height < 8) return false;
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var W = window.innerWidth || 0, H = window.innerHeight || 0;
        if (cx < 0 || cy < 0) return false;
        if (W && cx > W) return false;
        if (H && cy > H) return false;
        return true;
      };
    """

    static let openAccessJS = """
    (function () {
      var btns = document.querySelectorAll(
        'button, [role="button"], [role="combobox"], [role="listbox"], select, [aria-haspopup]'
      );
      for (var i = 0; i < btns.length; i++) {
        var b = btns[i];
        var txt = (b.innerText || b.textContent || '').toLowerCase();
        var parent = b.closest('div');
        var parentTxt = (parent && parent.innerText || '').toLowerCase();
        if (txt.indexOf('restricted') !== -1 || txt.indexOf('only people') !== -1
            || txt.indexOf('not shared') !== -1 || txt.indexOf('private') !== -1
            || (parentTxt.indexOf('notebook access') !== -1
                && (txt.indexOf('off') !== -1 || txt.length < 30))) {
          b.click();
          return 'opened';
        }
      }
      var labels = document.querySelectorAll('label, span, div, h3, h4');
      for (var j = 0; j < labels.length; j++) {
        var t = (labels[j].innerText || '').toLowerCase();
        if (t.indexOf('notebook access') !== -1) {
          var next = labels[j].nextElementSibling || labels[j].parentElement;
          var btn = next && next.querySelector('button, [role="button"], select');
          if (btn) { btn.click(); return 'opened'; }
        }
      }
      return '';
    })()
    """

    static let pickAnyoneJS = """
    (function () {
      var options = document.querySelectorAll(
        '[role="option"], [role="menuitem"], [role="menuitemradio"], li, label'
      );
      for (var i = 0; i < options.length; i++) {
        var t = (options[i].innerText || options[i].textContent || '').toLowerCase();
        if (t.indexOf('anyone with the link') !== -1 || t.indexOf('anyone') !== -1) {
          options[i].click();
          return 'selected';
        }
      }
      return '';
    })()
    """

    /// Does the access control ALREADY read "Anyone with the link"?
    ///
    /// ⚠ Separated from the strict verify below on purpose. This answers "was there nothing to
    /// click", which turns the healthiest possible outcome — a second share of an already-public
    /// notebook — from a warning into the success it is.
    static let accessAlreadyPublicJS = """
    (function () {
      var scope = document.querySelector('[role="dialog"]') || document.body;
      var txt = (scope.innerText || '').toLowerCase();
      return txt.indexOf('anyone with the link') !== -1;
    })()
    """

    /// Read the share link, or click Copy and report that.
    ///
    /// ⛔ READS may range over the page; CLICKS may not. Every candidate is gated by the URL
    /// predicate, so the worst a page-wide read can do is find the same notebook's link somewhere
    /// else — while a page-wide "any button whose text contains copy" search is a stray press on
    /// whatever the notebook happens to render. So the copy fallback stays inside the dialog and
    /// reports `no_dialog` rather than guessing.
    static let readShareLinkJS = """
    (function () {
      \(onScreenJS)
      var isNb = function (s) {
        if (!s) return false;
        try {
          var u = new URL(String(s).trim());
          if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
          var h = (u.hostname || '').toLowerCase();
          if (h !== 'google.com' && h.slice(-11) !== '.google.com') return false;
          return u.pathname.indexOf('/notebook/') === 0 && u.pathname.length > 10;
        } catch (e) { return false; }
      };
      var norm = function (s) { return (s || '').replace(/\\s+/g, ' ').trim(); };
      var roots = [];
      var dialogs = document.querySelectorAll(\(js(dialogScopes)));
      for (var i = 0; i < dialogs.length; i++) {
        var r = dialogs[i].getBoundingClientRect();
        if (r.width > 200 && r.height > 100) roots.push(dialogs[i]);
      }
      var readRoots = roots.concat([document]);
      for (var k = 0; k < readRoots.length; k++) {
        var inputs = readRoots[k].querySelectorAll(
          'input[readonly], input[type="text"], input[type="url"], textarea'
        );
        for (var m = 0; m < inputs.length; m++) {
          var val = inputs[m].value || inputs[m].getAttribute('value') || '';
          if (isNb(val)) return { url: val, via: 'input' };
        }
      }
      for (var p = 0; p < roots.length; p++) {
        var btns = roots[p].querySelectorAll('button, [role="button"]');
        for (var q = 0; q < btns.length; q++) {
          if (!onScreen(btns[q])) continue;
          var t = norm(btns[q].innerText || btns[q].textContent || '').toLowerCase();
          if (!t) continue;
          if (t.indexOf('copy link') !== -1
              || (t.indexOf('copy') !== -1 && t.indexOf('copy all') === -1)) {
            try { btns[q].click(); } catch (e) { return { url: '', via: 'copy_threw' }; }
            return { url: 'clipboard', via: 'copy' };
          }
        }
      }
      return { url: '', via: roots.length ? 'no_link_in_dialog' : 'no_dialog' };
    })()
    """

    /// ⛔ The trigger's OWN text nodes only, never its descendants. Material-style dropdowns put the
    /// option list INSIDE the trigger when open, so reading `innerText` captures the option labels
    /// and matches "anyone with the link" on a dropdown that is merely open. Undercounting verifies
    /// is safe — the caller degrades — while falsely confirming a private link is not.
    static let verifyPublicJS = """
    (function () {
      var PHRASE = 'anyone with the link';
      var ownText = function (el) {
        var s = '';
        for (var i = 0; i < el.childNodes.length; i++) {
          if (el.childNodes[i].nodeType === 3) s += el.childNodes[i].nodeValue || '';
        }
        return s.toLowerCase();
      };
      var triggers = document.querySelectorAll(
        '[role="dialog"] [role="combobox"], [role="dialog"] [aria-haspopup="listbox"], '
        + '[role="dialog"] button[aria-expanded]'
      );
      for (var i = 0; i < triggers.length; i++) {
        if (ownText(triggers[i]).indexOf(PHRASE) !== -1) return true;
      }
      var dlg = document.querySelector('[role="dialog"]');
      if (dlg) {
        var active = dlg.querySelector(
          '[aria-selected="true"], [aria-checked="true"], [data-selected="true"]'
        );
        if (active && (active.innerText || '').toLowerCase().indexOf(PHRASE) !== -1) return true;
      }
      return false;
    })()
    """

    static let saveShareJS = """
    (function () {
      var btns = document.querySelectorAll('button');
      for (var i = 0; i < btns.length; i++) {
        var t = (btns[i].innerText || '').trim().toLowerCase();
        if (t === 'save' || t === 'done' || t === 'apply') { btns[i].click(); return 'saved'; }
      }
      return '';
    })()
    """

    /// The customise ARROW, pinned from a real console dump — British spelling first, then the
    /// American one, then the structural hooks, then a spelling-tolerant aria-label search.
    ///
    /// ⛔ Every candidate is a BUTTON. Not one of them can resolve to the card body, which is the
    /// whole point of the chain.
    static let openCustomiseJS = """
    (function () {
      var isVis = function (el) { return el && el.offsetParent !== null; };
      var sels = [
        'button[aria-label="Customise Audio Overview"]',
        'button[aria-label="Customize Audio Overview"]',
        'basic-create-artifact-button button[data-edit-button-type="1"]',
        'basic-create-artifact-button button.edit'
      ];
      for (var i = 0; i < sels.length; i++) {
        var el = document.querySelector(sels[i]);
        if (isVis(el)) { el.click(); return true; }
      }
      var btns = document.querySelectorAll(
        'basic-create-artifact-button button[aria-label], button[aria-label]'
      );
      for (var j = 0; j < btns.length; j++) {
        if (!isVis(btns[j])) continue;
        var lab = (btns[j].getAttribute('aria-label') || '').toLowerCase();
        if (lab.indexOf('ustom') !== -1 && lab.indexOf('udio') !== -1) {
          btns[j].click();
          return true;
        }
      }
      return false;
    })()
    """

    /// Pick a named option in the open customise panel.
    ///
    /// ⚠ EXACT label match after normalising, not `contains`. "Default" is a substring of nothing
    /// here, but "Long" is a substring of "Longer" and of "Long form", and picking a neighbouring
    /// option produces a perfectly good podcast of the wrong length — which nothing downstream flags.
    static func pickOptionJS(_ label: String) -> String {
        """
        (function () {
          var want = \(js(label)).toLowerCase();
          \(labelJS)
          var rows = document.querySelectorAll(
            '[role="option"], [role="menuitem"], [role="menuitemradio"], [role="radio"], '
            + 'button, [role="button"], mat-option, li'
          );
          for (var i = 0; i < rows.length; i++) {
            if (!rows[i].offsetParent) continue;
            if (nlmLabel(rows[i]).toLowerCase() === want) { rows[i].click(); return true; }
          }
          return false;
        })()
        """
    }

    /// The terminal Generate press.
    ///
    /// ⛔ Scoped to the customise panel/dialog when one is open. Document-wide, "Generate" also
    /// matches NotebookLM's other studio artefacts, and generating the wrong artefact consumes the
    /// step while producing no podcast.
    static let clickGenerateJS = """
    (function () {
      \(labelJS)
      var scopes = [];
      var dialogs = document.querySelectorAll(\(js(dialogScopes)));
      for (var i = 0; i < dialogs.length; i++) { scopes.push(dialogs[i]); }
      scopes.push(document);
      for (var s = 0; s < scopes.length; s++) {
        var btns = scopes[s].querySelectorAll('button, [role="button"]');
        for (var j = 0; j < btns.length; j++) {
          if (!btns[j].offsetParent) continue;
          if (btns[j].disabled) continue;
          var label = nlmLabel(btns[j]).toLowerCase();
          if (label === 'generate' || label === 'create') { btns[j].click(); return true; }
        }
      }
      return false;
    })()
    """

    /// Done → a visible audio artefact and NO "Generating Audio Overview" placeholder.
    static let audioCompleteJS = """
    (function () {
      var cont = document.querySelector('artifact-library, .artifact-library-container')
        || document.body;
      var contText = cont.innerText || cont.textContent || '';
      if (/generating audio overview/i.test(contText)) return false;
      var items = document.querySelectorAll('artifact-library-item');
      for (var i = 0; i < items.length; i++) {
        if (items[i].offsetParent === null) continue;
        if ((items[i].innerText || items[i].textContent || '').indexOf('audio_magic_eraser') !== -1) {
          return true;
        }
      }
      return false;
    })()
    """

    static let audioGeneratingJS = """
    (function () {
      var cont = document.querySelector('artifact-library, .artifact-library-container')
        || document.body;
      var text = (cont.innerText || cont.textContent || '').toLowerCase();
      return text.indexOf('generating audio overview') !== -1
        || text.indexOf('creating audio') !== -1;
    })()
    """

    /// Capture the URL the Download row is about to use, without letting it navigate.
    ///
    /// ⭐ A CAPTURE-PHASE listener plus an anchor-click override, because the two delivery shapes
    /// need different interceptions: a real `<a download>` in the DOM is caught by the listener,
    /// while a programmatically created-and-clicked anchor never reaches a document listener at the
    /// right moment. Both record and neither is allowed to navigate away — a navigation here would
    /// tear down the notebook page mid-P3.
    static let armDownloadCaptureJS = """
    (function () {
      if (window.__srAudioCapture && window.__srAudioCapture.armed) {
        window.__srAudioCapture.url = '';
        return true;
      }
      window.__srAudioCapture = { url: '', armed: true };
      var remember = function (href) {
        if (href && !window.__srAudioCapture.url) { window.__srAudioCapture.url = String(href); }
      };
      document.addEventListener('click', function (e) {
        var t = e.target;
        var a = t && t.closest ? t.closest('a[href]') : null;
        if (a) { remember(a.href); e.preventDefault(); }
      }, true);
      var nativeClick = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        if (this.href) { remember(this.href); return; }
        return nativeClick.apply(this, arguments);
      };
      return true;
    })()
    """

    /// Open the audio card's overflow menu and press the Download row.
    ///
    /// ⚠ Two beats in ONE evaluate would race the menu's render, so this is called after the menu
    /// opens — the function opens the menu on its first pass and presses Download on any pass where
    /// the row exists, which makes it safe to call more than once.
    static let clickDownloadRowJS = """
    (function () {
      \(labelJS)
      \(onScreenJS)
      var rows = document.querySelectorAll('[role="menuitem"], button, [role="button"], li');
      for (var i = 0; i < rows.length; i++) {
        if (!onScreen(rows[i])) continue;
        if (nlmLabel(rows[i]).toLowerCase() === 'download') { rows[i].click(); return true; }
      }
      var items = document.querySelectorAll('artifact-library-item');
      for (var j = 0; j < items.length; j++) {
        if (items[j].offsetParent === null) continue;
        var more = items[j].querySelectorAll('button[aria-label], [role="button"][aria-label]');
        for (var k = 0; k < more.length; k++) {
          var lab = (more[k].getAttribute('aria-label') || '').toLowerCase();
          if (!onScreen(more[k])) continue;
          if (lab.indexOf('more') !== -1 || lab.indexOf('option') !== -1) {
            more[k].click();
            return false;
          }
        }
      }
      return false;
    })()
    """

    static let playerSourceJS = """
    (function () {
      var a = document.querySelector('audio');
      return (a && (a.currentSrc || a.src)) || '';
    })()
    """

    /// Fetch the media into the page and report its byte length.
    ///
    /// ⚠ `credentials: 'include'` — the object is behind the owner's session, and an unauthenticated
    /// fetch returns a sign-in HTML page with a perfectly good 200 status. That would then be
    /// sniffed as an unknown container and uploaded as an "m4a" full of HTML.
    static func fetchAudioJS(_ url: String) -> String {
        """
        (async function () {
          try {
            var r = await fetch(\(js(url)), { credentials: 'include' });
            if (!r.ok) return -1;
            var buf = new Uint8Array(await r.arrayBuffer());
            window.__srAudio = buf;
            window.__srAudioRead = function (offset, length) {
              var slice = window.__srAudio.subarray(offset, offset + length);
              var s = '';
              for (var i = 0; i < slice.length; i++) { s += String.fromCharCode(slice[i]); }
              return btoa(s);
            };
            return buf.length;
          } catch (e) { return -1; }
        })()
        """
    }
}
