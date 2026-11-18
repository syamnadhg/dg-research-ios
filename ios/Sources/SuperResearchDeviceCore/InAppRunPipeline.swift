import Foundation

/// Backs the executor's seam with the **real** in-app driver.
///
/// ⚠ Until this existed the executor talked to a protocol nothing implemented, so every test passed
/// against a stub and a claimed run still reached no platform. This is the join, and it is
/// deliberately the only place that knows both halves: the executor owns the ORDER of a run, the
/// driver owns one platform's STEPS, and neither should know the other's job.
public struct InAppRunPipeline: RunExecutor.Pipeline {

    /// Hands back the web view for a platform on a given worker.
    ///
    /// ⚠ A closure rather than a stored table: the app keeps one long-lived view per (worker,
    /// platform) and recreating one mid-run would destroy the session the run is driving.
    public typealias PageProvider = @Sendable (_ platform: String, _ worker: Int) -> any WebPage

    private let pages: PageProvider
    private let worker: Int
    private let manifest: [String: [String: [String]]]
    private let texts: [String: [String: String]]
    private let openers: [String: [String: String]]
    private let responseTimeout: TimeInterval
    private let extractionTimeout: Duration
    /// Where the per-platform detail goes.
    ///
    /// ⚠ The OUTCOME, not just "it ran". Every question asked after a run — did deep research
    /// actually turn on, did the plan step appear, how long was the report — is answered by these
    /// fields and by nothing else in the system.
    private let trace: RunLog
    private let activity: LiveRunActivity
    /// How long the readiness gate waits for a cold web view.
    ///
    /// ⚠ Injectable so tests do not pay it. A test that drives a page with no composer is asserting
    /// the FAILURE, and with a real clock it waits the full production timeout to find out — one
    /// such test turned a two-second suite into a ninety-six-second one.
    private let pageReadyTimeout: TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Has the owner asked to stop this run?
    ///
    /// ⛔ Supplied at last. `InAppPipeline.run` has taken a `shouldStop` since it was written and
    /// **nothing ever passed one**, so it defaulted to `{ false }` for every real run — the Stop
    /// button reached Firestore, was decoded, was acked, and was then dropped on the floor.
    private let shouldStop: @Sendable () -> Bool
    /// Put the web views back to rest when the run is done with them.
    ///
    /// ⚠ A plain closure rather than anything async: the host owns the UIKit hop, and the run loop
    /// stays free of Swift concurrency for the reasons already established (non-Sendable bridge,
    /// positional golden-fixture diff).
    private let releasePages: @Sendable () -> Void

    /// Where each panel reading goes, once it has been reduced to what is NEW.
    ///
    /// ⭐ **The channel the frontend's narration strip and raw-activity panel render from, and this
    /// device has never emitted a single one.** `agent_progress` carries the sources and the step
    /// list; `agent_narration` carries one sentence per tick. Everything the owner sees "live"
    /// during a phase comes from these two, which is why a run served by this device has always
    /// looked silent next to the same run served by the desktop.
    public typealias ActivityPublisher =
        @Sendable (_ platform: String, _ phase: Int,
                   _ delta: ActivityStream.Delta, _ totalSources: Int) -> Void
    private let publishActivity: ActivityPublisher

    public init(
        pages: @escaping PageProvider,
        worker: Int,
        manifest: [String: [String: [String]]],
        texts: [String: [String: String]] = [:],
        openers: [String: [String: String]] = [:],
        responseTimeout: TimeInterval = 2_400,
        extractionTimeout: Duration = .seconds(120),
        pageReadyTimeout: TimeInterval = 90,
        trace: RunLog = .discarding(),
        activity: LiveRunActivity = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        shouldStop: @escaping @Sendable () -> Bool = { false },
        releasePages: @escaping @Sendable () -> Void = {},
        publishActivity: @escaping ActivityPublisher = { _, _, _, _ in }
    ) {
        self.publishActivity = publishActivity
        self.releasePages = releasePages
        self.pageReadyTimeout = pageReadyTimeout
        self.sleep = sleep
        self.shouldStop = shouldStop
        self.pages = pages
        self.worker = worker
        self.manifest = manifest
        self.texts = texts
        self.openers = openers
        self.responseTimeout = responseTimeout
        self.extractionTimeout = extractionTimeout
        self.trace = trace
        self.activity = activity
    }

    /// Does the owner's config skip this **per-platform** phase?
    ///
    /// ⛔ **The two phase numberings COLLIDE, and mapping them by equality is a silent bug.** The
    /// product's phases are run-wide — 1 brief, 2 research, 3 PODCAST, 4 video — while this
    /// pipeline's are per-platform: 0 login, 1 brief, 2 report, **3 the source harvest**. Passing
    /// `skipPhases` straight through would therefore make "I don't want a podcast" delete the
    /// source telemetry from every platform, which nothing would report and nobody would connect
    /// back to the toggle they pressed.
    ///
    /// So the mapping is written out rather than inferred, and only the two phases that genuinely
    /// mean the same thing on both sides are wired:
    ///
    /// * **0** — the login walk, answered by `skipInitVerify` (which is opt-OUT: see `RunConfig`);
    /// * **1** — the brief, the one product phase this pipeline actually performs.
    ///
    /// Phase 2 never appears here: an agent the owner switched off is not driven at all, which the
    /// executor decides before this type is reached. Phase 3 is telemetry and is not the owner's
    /// podcast setting.
    static func skips(phase: Int, config: RunConfig) -> Bool {
        switch phase {
        case 0: return config.skipInitVerify
        case 1: return config.skipPhases.contains(1)
        default: return false
        }
    }

    /// Every web view back to rest — called by the executor when the run is over, however it ended.
    public func release() { releasePages() }

    public func runPhases(
        entry: QueueEntry, platform: String, brief: String,
        onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> (brief: String, report: String?) {
        let driver = InAppPhaseDriver(
            platform: platform,
            manifest: manifest[platform] ?? [:],
            texts: texts[platform] ?? [:],
            openers: openers[platform] ?? [:],
            page: pages(platform, worker)
        )
        var pipeline = InAppPipeline(
            driver: driver, topic: entry.topic, providedBrief: brief
        )
        // ⭐ **Written as they happen, not flushed at the end.** The three post-hoc `for event in
        // pipeline.events` loops that used to live below only ran when the platform finished or
        // threw — so an app kill mid-run (twice on 2026-08-14) left a trace ending at
        // `<platform>.start` and no way to tell how far it got. The buffer is still populated for
        // callers that compare against the golden fixture; this is the durable copy.
        pipeline.onEvent = { [trace, activity, worker] phase, event in
            trace.write("\(platform).event", "p\(phase):\(event)")
            // ⭐ **The screen's phase, moved by the thing that actually knows.** The executor's
            // counter cannot advance while a platform is inside its own P1→P2→P3, so without this
            // Browser watch reads "Research brief" for the whole of deep research.
            if event == "phase_start" { activity.setPlatformPhase(worker: worker, phase: phase) }
        }
        // ⛔ **The brief is captured when it is PRODUCED, not when the platform finishes.** A
        // failure in phase 2 used to take phase 1's product with it — see `onBriefProduced` — and
        // the executor then abandoned the whole run for want of a brief that had existed for
        // twenty minutes.
        let produced = BriefBox()
        pipeline.onBriefProduced = { brief in
            produced.set(brief)
            // ⚠ Awaited here, at the P1 → P2 boundary: the document is written and streamed before
            // the platform moves on, which is the order the frontend's phase tile depends on.
            await onBriefProduced(brief)
        }
        // ⚠ A reference box, because the reduction is STATEFUL and the callback fires from the
        // pipeline's own task. The panel redraws its whole list on every step, so "what it says
        // now" and "what is new" are different questions — and the frontend APPENDS narration, so
        // publishing the former would write the same sentence into the strip sixty times.
        let stream = ActivityStreamBox()
        pipeline.driverActivity = { [trace, publishActivity] phase, snapshot in
            let delta = stream.absorb(snapshot)
            guard !delta.isEmpty else { return }
            for step in delta.steps { trace.write("\(platform).activity", step) }
            publishActivity(platform, phase, delta, stream.sourceCount)
        }
        trace.write("\(platform).start", "briefIn=\(brief.count) chars")
        // ⭐ Browser watch reads this to glow the tab this run is actually typing into. Reported
        // here — the one place that knows both the worker and the platform — rather than inferred
        // from a document the device only writes to.
        activity.set(worker: worker, platform: platform)
        // ⛔ Cleared on EVERY exit, including the throw below. A glow left on after a failure points
        // the owner at a tab where nothing is happening, and the only clue that it is stale is that
        // it never changes.
        // ⚠ `finished`, not `clear`. Clearing removes the WORKER, which is right when the run ends
        // and wrong when one of three concurrent agents finishes — with the old model the first one
        // to end darkened the two still researching.
        defer { activity.finished(worker: worker, platform: platform) }
        let outcome: InAppPipeline.Outcome
        do {
            outcome = try await pipeline.run(
                shouldStop: shouldStop,
                shouldSkip: { Self.skips(phase: $0, config: entry.config) },
                responseTimeout: responseTimeout, extractionTimeout: extractionTimeout,
                pageReadyTimeout: pageReadyTimeout, sleep: sleep
            )
        } catch {
            // ⚠ Recorded and RE-THROWN. The executor's own handling is to carry on with the other
            // platforms, which is right — but it records only `failed:<platform>`, and "why" is the
            // whole question afterwards.
            trace.write("\(platform).FAILED", "\(error)")
            // ⭐ ...EXCEPT when phase 1 already produced the brief. Then this platform failed at its
            // REPORT, which is a degraded platform rather than a dead run: the brief is the run's
            // product and the other agents are waiting for it. Returning it with no report says
            // exactly that, and the executor's existing `no-report:<platform>` path marks this one
            // errored. Re-throwing here is what abandoned a run 1.5 seconds after fifteen minutes
            // of Pro thinking had succeeded.
            if let brief = produced.value, !brief.isEmpty {
                trace.write("\(platform).brief-survived",
                            "\(brief.count) chars kept despite the failure above")
                return (brief: brief, report: nil)
            }
            throw error
        }
        // ⚠ A stop taken at a PHASE BOUNDARY comes back as a status rather than a throw, and the
        // status was being dropped here — `runPhases` returns only the brief and the report. So a
        // stopped platform looked exactly like one that produced nothing, and the executor moved
        // on to spend the next agent. Raised to the error channel, where the executor can act.
        if outcome.status == "stopped" {
            trace.write("\(platform).stopped", "the owner stopped the run")
            throw InAppPhaseError.stoppedByOwner(platform: platform)
        }
        trace.write(
            "\(platform).outcome",
            "status=\(outcome.status) deepResearchWasAlreadyOn=\(outcome.deepResearchWasAlreadyOn) "
            + "planConfirmed=\(outcome.planWasConfirmed) sources=\(outcome.sources.count)"
            // ⚠ In the DURABLE trace, not only in NSLog. "Did the brief get written on the policy
            // tier?" is the question P1 exists to answer, and it was answerable only from a system
            // log that rolls.
            + (outcome.effortTier.isEmpty ? "" : " effortTier=\(outcome.effortTier)")
        )
        trace.excerpt("\(platform).brief", outcome.brief)
        trace.excerpt("\(platform).report", outcome.report)
        // ⚠ An empty report is returned as nil rather than as "": the executor distinguishes "this
        // platform produced nothing" from "this platform produced an empty string", and only the
        // first is a fact it can act on.
        let report = outcome.report.isEmpty ? nil : outcome.report
        return (brief: outcome.brief, report: report)
    }
}
