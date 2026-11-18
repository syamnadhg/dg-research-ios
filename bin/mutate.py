#!/usr/bin/env python3
"""Mutation harness: prove each guard's test actually fails when the guard is broken.

A passing test says nothing about whether it *could* fail. Every guard in this repo protects
against a specific silent-failure mode, so each one gets an entry here that breaks the guard
and asserts the corresponding test turns red. Sources are restored byte-identically
(sha256-verified) after every mutation, and a mismatch aborts.

The `simulates:` line on each entry names the real defect, not the code change — that is the
part worth reading when one of these starts failing.

    python bin/mutate.py        # from the repo root

Two entry shapes:
  * source mutation - break the guard, expect the named test to fail
  * positive fixture (`probe_forbidden_call_detector`) - plant a real violation and expect the
    scanner to find it. For a static scanner this direction matters more: one that finds
    nothing looks exactly like a clean repo.
"""
from __future__ import annotations

import hashlib
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / ".venv/bin/python"

#: The file currently holding a mutation, and its original bytes. Empty except inside the window
#: between writing a mutant and restoring it.
#:
#: ⛔ **This exists because the harness corrupted the repo once.** `finally` restores on an
#: exception, but `SIGTERM` — what `pkill` and most job supervisors send — terminates the process
#: without unwinding, so `finally` never runs and the mutant is simply LEFT IN THE SOURCE. It
#: happened to `_dismiss_opener`, whose `if not state.get("open")` stayed `if False` in the working
#: tree. Nothing announced it: the next full run showed four unrelated-looking failures in
#: `test_selectors_and_phases.py`, and the obvious reading was "my last change broke the opener
#: logic" — a debugging session aimed at entirely the wrong file. A tool that edits sources in
#: place has to survive being killed.
_IN_FLIGHT: dict[Path, bytes] = {}


def _restore_in_flight() -> None:
    for path, original in list(_IN_FLIGHT.items()):
        try:
            path.write_bytes(original)
        finally:
            _IN_FLIGHT.pop(path, None)


def _on_signal(signum, _frame):
    _restore_in_flight()
    print(f"\nsignal {signum}: restored the in-flight mutation before exiting.", file=sys.stderr)
    # 128+n is the shell's own convention for death-by-signal, and preserving it keeps the exit
    # code honest — a restored-then-aborted run is not a passing run.
    sys.exit(128 + signum)

# (file, old, new, test-node-id-that-MUST-fail, what-real-defect-this-simulates)
MUTATIONS = [
    # --- the FE→device direction, and the two hazards a periodic refresh introduced --------------
    (
        # ⛔ Without the push, a worker parked from the web app never reaches the phone.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            onSnapshot(snapshot)",
        "            onSnapshot(DeviceSnapshot())",
        "swift:RestSyncTests/testTheBEATPushesASnapshotSoAWebAppChangeArrivesUnprompted",
        "the web app's rest toggle never reaching the phone — the bug this whole wave is about",
    ),
    (
        # ⛔ A line only when something changed cannot tell a dead beat from a quiet document.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            beatLogger?(Self.beatSummary(snapshot: snapshot, workerCount: workers.count))",
        "            if snapshot.restingWorkerIDs != lastPublishedResting {\n"
        "                beatLogger?(Self.beatSummary(snapshot: snapshot, workerCount: workers.count))\n"
        "            }",
        "swift:RestSyncTests/testTheBeatLogsItsSTATEOnEveryTickEvenWhenNothingChanged",
        "silence during an e2e meaning any of: beat dead, read failing, or document unchanged",
    ),
    (
        # The failed read has to be NAMED, or empty sets read as 'the web app never wrote it'.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '        let doc = snapshot.online ? "ok" : "unreadable-or-offline"',
        '        let doc = "ok"',
        "swift:RestSyncTests/testAnUNREADABLETickIsNamedAsSuchRatherThanReadingAsAQuietDevice",
        "a tick that could not read the document reporting an empty resting set as fact",
    ),
    (
        # The line must report the resting set, not some other set that happens to be nearby.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '            + " resting=\\(snapshot.restingWorkerIDs.sorted())"',
        '            + " resting=\\(snapshot.busyWorkerIDs.sorted())"',
        "swift:RestSyncTests/testTheBeatLineNamesTheRestingSetTheDocumentReported",
        "the diagnostic line reporting the wrong set, so the evidence points at the wrong end",
    ),
    (
        # The run MAP is what the web app renders pills from — busyWorkerIds is a different field.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        let runMap = snapshot.workers.filter(\\.isBusy).map(\\.id).sorted()",
        "        let runMap = snapshot.busyWorkerIDs.sorted().map(String.init)",
        "swift:RestSyncTests/testTheBeatLineSeparatesTheRunMAPFromTheBusySet",
        "the two worker fields collapsed into one, hiding the stale map entry that makes the web "
        "app's rest pill unclickable while the phone shows the same worker idle",
    ),
    (
        # ⚠ The owner identifier is truncated because this log gets shared.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '        let owner = snapshot.ownerUID.isEmpty ? "none" : String(snapshot.ownerUID.prefix(8))',
        '        let owner = snapshot.ownerUID.isEmpty ? "none" : snapshot.ownerUID',
        "swift:RestSyncTests/testTheBeatLineNamesTheOWNERButOnlyItsPrefix",
        "a full account identifier written into a log the owner pastes into a chat",
    ),
    (
        # Which document was read — two tiles can share one name after a re-pair.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '        let device = snapshot.deviceID.isEmpty ? "none" : String(snapshot.deviceID.prefix(8))',
        '        let device = snapshot.deviceID.isEmpty ? "none" : snapshot.deviceID',
        "swift:RestSyncTests/testTheBeatLineNamesWHICHDeviceDocumentItRead",
        "the whole device id in a shared log, when 8 characters already identify the tile",
    ),
    (
        # ⛔ A dropped read reported as an unpairing swaps the root screen and shuts every sheet.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        snapshot.paired = true\n"
        "        // ⚠ Re-arm the session first",
        "        snapshot.paired = false\n"
        "        // ⚠ Re-arm the session first",
        "swift:RestSyncTests/testAnUNREADABLEDocumentReportsOFFLINEAndSTILLPAIRED",
        "one dropped read throwing the owner out to 'No user paired' and closing every open sheet",
    ),
    (
        # ...but the DOCUMENT must still be able to say unpaired.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '        snapshot.paired = fields["pairConfirmedAt"] != nil',
        "        snapshot.paired = true",
        "swift:RestSyncTests/testADocumentWithNoPairConfirmationDOESReportUnpaired",
        "a device that was genuinely unpaired still reporting itself paired forever",
    ),
    (
        # Stale-read revert: the pill flips, then flips back for a whole beat.
        "ios/Sources/SuperResearchDeviceCore/SnapshotOrdering.swift",
        "        return incoming > applied",
        "        return true",
        "swift:RestSyncTests/testAnOLDERSnapshotIsNotAllowedToReplaceANewerOne",
        "a beat load issued before a local toggle landing after it and reverting the screen",
    ),
    (
        # 0 means unsequenced — the unpaired snapshot must always land.
        "ios/Sources/SuperResearchDeviceCore/SnapshotOrdering.swift",
        "        if incoming == 0 { return true }",
        "        if incoming == 0 { return false }",
        "swift:RestSyncTests/testAnUNSEQUENCEDSnapshotAlwaysApplies",
        "the unpaired snapshot — the one the UI needs most — becoming the only one that never lands",
    ),
    (
        # The stamp must be taken at ISSUE time, not on completion.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        snapshotSequence += 1\n        return snapshotSequence",
        "        return snapshotSequence",
        "swift:RestSyncTests/testEachLoadCarriesAStrictlyIncreasingStamp",
        "every load sharing one stamp, which makes newer and older reads indistinguishable",
    ),
    (
        # The live trace: a crash mid-run must not lose everything that happened.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        events.append((phase, event))\n        onEvent?(phase, event)",
        "        events.append((phase, event))",
        "swift:RunTraceLivenessTests/testPhaseEventsReachTheTraceAsTheyHAPPEN",
        "a run that crashes mid-flight leaving a four-line trace that ends at <platform>.start",
    ),
    # --- the crash: one visibility transition per turn, and never orphan a live page -------------
    (
        # ⛔⛔ The 2026-08-14 crash. Orphaning the outgoing view starts a WebContent suspend.
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchHandoff.swift",
        "            steps.append(Step(move: .returnToWindow(platform: platform), turn: index + 1))",
        "            steps.append(Step(move: .present(platform: platform), turn: index + 1))",
        "swift:BrowserWatchHandoffTests/testTheOUTGOINGPageIsReturnedToTheWindowNotOrphaned",
        "a page the run owns left in no window, which suspends its WebContent process mid-run",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchHandoff.swift",
        "    public static func delayMillis(turn: Int, spacing: Int = 250) -> Int { turn * spacing }",
        "    public static func delayMillis(turn: Int, spacing: Int = 250) -> Int { 0 }",
        "swift:BrowserWatchHandoffTests/testHandoffsAreSPACEDOneTransitionPerTurn",
        "several WebContent processes changing visibility in one runloop turn — the shape that "
        "trips ProcessThrottler's assert",
    ),
    (
        # aria-hidden is an accessibility hint, not a block.
        "emubackend/substrate/runtime_js.py",
        "            blocking: why !== 'aria-hidden'",
        "            blocking: true",
        "test_notebook_js.py::test_ARIA_HIDDEN_alone_is_not_reported_as_blocking",
        "an ordinary ChatGPT composer reported as a dialog that refused to close",
    ),
    (
        # ⛔ The walk must not stop at the first hit — on ChatGPT that is the composer itself.
        "emubackend/substrate/runtime_js.py",
        "          if (found.blocking) { if (!blocking) { blocking = found; } }",
        "          if (found.blocking) { if (!blocking) { blocking = found; } }\n"
        "          if (chain.length) { node = null; }",
        "test_notebook_js.py::test_a_REAL_blocker_ABOVE_an_aria_hidden_composer_is_still_found",
        "a real blocker ABOVE the composer being invisible, because the composer's own advisory "
        "aria-hidden ended the search — the 2026-08-17 P1 failure",
    ),
    (
        # visibility:hidden keeps the box and refuses the caret — the blocker a rect cannot rule out.
        "emubackend/substrate/runtime_js.py",
        "        var invisible = css && css.visibility === 'hidden' ? 'visibility:hidden'",
        "        var invisible = false ? 'visibility:hidden'",
        "test_notebook_js.py::test_VISIBILITY_HIDDEN_blocks_even_though_the_element_still_has_a_rect",
        "an unfocusable composer reported as healthy because it still had a rect",
    ),
    (
        # One Escape and a retry is what rescues a page a dialog has neutralised.
        "emubackend/substrate/runtime_js.py",
        "        placed = putRange(existing.length > 0 ? false : true);\n"
        "        if (placed && selectionIsInside()) { recovered = true; }",
        "        if (placed && selectionIsInside()) { recovered = true; }",
        "test_notebook_js.py::test_a_caret_that_cannot_be_placed_is_RETRIED_after_one_ESCAPE",
        "P1 dying on a page one keypress from working — the run gave up the moment the caret would "
        "not go in and never tried to dismiss what was in the way",
    ),
    (
        # ...but Escape is an attempt, not a guarantee.
        "emubackend/substrate/runtime_js.py",
        "      if (!placed || !selectionIsInside()) {\n        // ⛔ **ONE read, and it names",
        "      if (false) {\n        // ⛔ **ONE read, and it names",
        "test_notebook_js.py::test_a_STUCK_dialog_still_fails_rather_than_typing_into_nothing",
        "typing into a neutralised editor and reporting success",
    ),
    (
        # The returned finding must not be an element of its own chain.
        "emubackend/substrate/runtime_js.py",
        "      return {\n        tag: answer.tag, id: answer.id, cls: answer.cls, label: answer.label,",
        "      answer.chain = chain;\n      return answer;\n      return {\n"
        "        tag: answer.tag, id: answer.id, cls: answer.cls, label: answer.label,",
        "test_notebook_js.py::test_a_REAL_blocker_ABOVE_an_aria_hidden_composer_is_still_found",
        "a circular structure that throws inside JSON.stringify — the failure path breaking while "
        "it reports the failure",
    ),
    (
        "emubackend/substrate/runtime_js.py",
        "    var advisoryOnly = !before.blocking;",
        "    var advisoryOnly = false;",
        # ⚠ Repointed twice. The detector test covers `blockingAncestor`; this classification lives
        # in `clearOverlay`, and mutation showed the detector test could not see it go. The branch
        # no longer RETURNS early — an aria-hidden composer is now Escaped like any other finding,
        # because the repo's own 2026-08-08 capture shows a healthy composer carries no such mark.
        "test_notebook_js.py::test_an_ARIA_HIDDEN_composer_is_ESCAPED_but_still_reported_as_ADVISORY",
        "pressing Escape at a page with nothing modal open, and calling a writable composer blocked",
    ),
    (
        # ⛔ Install new code, print "launched", leave the OLD process serving.
        "bin/build_app.sh",
        '  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true\n'
        '  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null\n'
        '  echo "==> launched (previous instance terminated first)',
        '  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null\n'
        '  echo "==> launched (previous instance terminated first)',
        "test_capture_guards.py::test_EVERY_launch_terminates_the_previous_instance_first",
        "every observation after a rebuild being made against the build that was replaced",
    ),
    (
        # ⛔ The same-pass double claim: `state` cannot see a claim this loop just made.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            busy: state.busy.union(locallyBusyWorkers).union(reserved),",
        "            busy: state.busy.union(locallyBusyWorkers),",
        "swift:QueueFIFOTests/"
        "testPollQueueClaimsTheEARLIESTSubmissionAndOnlyOneOnASingleWorkerDevice",
        "a one-worker device claiming every queued run onto worker 1 in a single poll",
    ),
    # --- the queue: FIFO order, and a capacity the device can actually track -------------------
    (
        # ⛔ A listing is not a queue. Without the sort the claim order is document-id order.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        let entries = RunQueuePolicy.fifoOrdered(docs.compactMap(QueueEntry.decode))",
        "        let entries = docs.compactMap(QueueEntry.decode)",
        # ⚠ Guarded by the test that drives pollQueue, NOT by the ordering unit tests. Those call
        # `fifoOrdered` directly, so they pass against a queue loop that never sorts — mutation
        # found exactly that, which is the decorative-guard shape this harness exists to catch.
        "swift:QueueFIFOTests/"
        "testPollQueueClaimsTheEARLIESTSubmissionAndOnlyOneOnASingleWorkerDevice",
        "claiming whichever queue document's id sorted first, which is a coin flip",
    ),
    (
        # The server stamp exists because a sharer's client clock ran behind the owner's.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        if let server = entry.submittedAtMillis, server > 0 { return (0, server) }",
        "        if false { return (0, 0) }",
        "swift:QueueFIFOTests/testACLIENTClockThatIsBehindDoesNotJumpTheQueue",
        "a sharer with a slow browser clock jumping ahead of an owner who submitted first",
    ),
    (
        # An unorderable document must be demoted, not promoted.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        return (1, 0)\n    }",
        "        return (0, 0)\n    }",
        "swift:QueueFIFOTests/testADocumentWithNoUsableStampGoesLASTRatherThanFirst",
        "a document with no readable submission time sorting ahead of every real one",
    ),
    (
        # Determinism: without the tiebreak the answer depends on the listing's arrival order.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "            return lhs.id < rhs.id",
        "            return false",
        "swift:QueueFIFOTests/testATIEIsBrokenByDocumentIdSoTheOrderIsDeterministic",
        "two same-millisecond submissions ordering differently depending on the listing",
    ),
    (
        # The live answer must come from the FACTS, not from a beat-old document.
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "        return (title: f.title, phase: f.platformPhase, elapsedSeconds: elapsed,",
        "        return (title: f.title, phase: f.phase, elapsedSeconds: elapsed,",
        "swift:LiveRunStateTests/testTheRUNNINGProcessCanAnswerWithoutADocumentRoundTrip",
        "the card reading the run-wide phase again, so it says 'Research brief' through P2 even "
        "when it asks the process that is driving the run",
    ),
    (
        # An idle worker must answer nil, or an idle device reads as a card that failed to load.
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "        guard let f = facts[worker] else { return nil }",
        "        let f = facts[worker] ?? RunFacts(uid: \"\", title: \"\", phase: 0)",
        "swift:LiveRunStateTests/testAnIDLEWorkerHasNoLiveRun",
        "an idle worker reporting a run with no title, so the strip claims something is happening",
    ),
    (
        # ⛔⛔ "Research brief" for forty minutes of deep research.
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "            phaseName: Self.phaseName(worker.platformPhase ?? worker.phase),",
        "            phaseName: Self.phaseName(worker.phase),",
        "swift:BrowserWatchPhaseTests/testTheStripNamesTheP2ReportWhileThePlatformIsWritingIt",
        "the strip naming the run-wide phase, which cannot advance while a platform is inside its "
        "own P1→P2→P3 — so it reads 'Research brief' through the whole report",
    ),
    (
        # The platform phase has to be FORWARDED, or there is nothing newer to render.
        "ios/Sources/SuperResearchDeviceCore/InAppRunPipeline.swift",
        '            if event == "phase_start" { activity.setPlatformPhase(worker: worker, phase: phase) }',
        "",
        # ⚠ Repointed to the test that drives the real pipeline. The strip test builds its snapshot
        # by hand, so deleting the forwarding changed nothing it could see.
        "swift:PipelineActivityReportingTests/testThePLATFORMSOwnPhaseReachesTheWorkerFactWhileItIsRunning",
        "the only writer of the platform phase removed, so the field publishes 0 for every run",
    ),
    (
        # ⛔ One agent finishing must not darken the others.
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "        byWorker[worker]?.removeAll { $0 == platform }",
        "        byWorker.removeValue(forKey: worker)",
        "swift:LiveRunActivityConcurrencyTests/testONEPlatformFinishingLeavesTheOthersGlowing",
        "the first of three concurrent agents to finish switching the other two off, so a platform "
        "mid-deep-research renders as idle",
    ),
    (
        # Several platforms can run; the set must actually hold several.
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "            if byWorker[worker, default: []].contains(platform) == false {\n"
        "                byWorker[worker, default: []].append(platform)\n"
        "            }",
        "            byWorker[worker] = [platform]",
        "swift:LiveRunActivityConcurrencyTests/testEveryRunningPlatformIsReportedNotJustTheLatest",
        "a second platform starting erasing the first — the single-string model, restored",
    ),
    (
        # ...and the handover after a finish is deterministic.
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "            foreground[worker] = byWorker[worker]?.first",
        "            foreground[worker] = byWorker[worker]?.last",
        "swift:LiveRunActivityConcurrencyTests/testTheFrontHandsOverToTheLONGESTRunningPlatform",
        "Browser watch opening a different tab on each redraw, which reads as the app choosing at "
        "random",
    ),
    (
        # ⛔⛔ The frontend stuck in phase one for a whole run: no brief document until the end.
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        try? await emitter.saveDocument(.brief, content: produced)",
        "",
        "swift:BriefStreamingTests/testTheBriefDocumentIsWrittenBEFOREDeepResearchBegins",
        "deep research beginning with no brief document written, so the web app's phase-1 tile has "
        "nothing to show and stays open for the whole run",
    ),
    (
        # ...and the phase must be announced there too, or the tile cannot close.
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        await announce(phase: 1, starting: false)\n        await announce(phase: 2, starting: true)\n        phase2Started = true",
        "        phase2Started = true",
        "swift:BriefStreamingTests/testPhaseOneIsAnnouncedCOMPLETEAsSoonAsTheBriefExists",
        "phase 1 never announced complete while a platform is inside its own P2, so the web app "
        "shows neither phase running for forty minutes",
    ),
    (
        # ⛔ The brief has to be reported when PRODUCED — awaiting the return is the old bug.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                await onBriefProduced?(brief)",
        "",
        "swift:InAppPipelineTests/testP1REPORTSTheBriefAsSoonAsItHasOne",
        "the brief reported only on return, which is after this platform's own deep research — the "
        "shape that let a P2 failure destroy a fifteen-minute brief",
    ),
    (
        # ⛔⛔ Fifteen minutes of Pro thinking, discarded by a failure in the phase after it.
        "ios/Sources/SuperResearchDeviceCore/ActivityPanel.swift",
        "        if !text.isEmpty { brief = text }",
        "        if !text.isEmpty { brief = nil }",
        "swift:BriefSurvivalTests/testABriefProducedInPhase1SurvivesAFailureInPhase2",
        "phase 1's brief lost when phase 2 throws — the run then abandoned for want of a brief that "
        "had existed for twenty minutes, with the other two agents never driven",
    ),
    (
        # ...and an empty brief must never be stored, or a failed P1 reads as a healthy one.
        "ios/Sources/SuperResearchDeviceCore/ActivityPanel.swift",
        "    public func set(_ text: String) {\n        lock.lock(); defer { lock.unlock() }\n"
        "        if !text.isEmpty { brief = text }",
        "    public func set(_ text: String) {\n        lock.lock(); defer { lock.unlock() }\n"
        "        brief = text",
        "swift:BriefSurvivalTests/testAnEmptyBriefIsNeverStoredSoAFailedP1StillReadsAsFailed",
        "an empty string kept as the brief, so a phase 1 that produced nothing carries on as though "
        "it had",
    ),
    (
        # ⛔ The clock that never moved: a literal 0 where the arithmetic belongs.
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "            elapsedSeconds: RunState.elapsed(since: worker.startedAtMillis, now: now),",
        "            elapsedSeconds: 0,",
        "swift:RunElapsedTests/testAWorkersRunReportsTheTimeSinceItSTARTED",
        "a live run showing 00:00 for its whole duration, which reads as a frozen app",
    ),
    (
        # An unknown stamp must read as zero, not as a count since 1970.
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "        guard startedAtMillis > 0 else { return 0 }",
        "        ",
        "swift:RunElapsedTests/testAnUNKNOWNStartStampReadsAsZeroRatherThanFifty_Years",
        "a document with no start stamp rendering fifty years of elapsed time",
    ),
    (
        # ...and a future stamp floors rather than counting backwards.
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "        return max(0, seconds)",
        "        return seconds",
        "swift:RunElapsedTests/testAFUTUREStampFloorsAtZeroInsteadOfCountingBackwards",
        "a negative clock whenever the phone and the server disagree by a second",
    ),
    (
        # The stamp has to be PUBLISHED or there is nothing to count from.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '                "startedAt": .integer(facts.startedAtMillis),',
        "",
        # ⚠ Repointed to the ROUND TRIP. The arithmetic test builds its snapshot by hand, so it
        # passed with the publish deleted — the map is the only channel between the run and the
        # screen, and the write has to be asserted on the wire.
        "swift:RestSyncTests/testTheDeviceWritesTheStartStampIntoTheWorkersMap",
        "the map carrying no start time, so every screen that counts from it counts from nothing",
    ),
    (
        # ⛔⛔ The inert guard itself — three crashes came from this one line.
        "ios/App/LiveRunView.swift",
        "        guard web.superview !== window else { return }   // already parked",
        "        guard web.superview == nil else { return }",
        "test_capture_guards.py::test_parking_a_page_does_not_REFUSE_one_that_has_somewhere_to_leave",
        "every rescue of a live page being refused because the page had somewhere to be rescued "
        "FROM — orphaned view, suspended WebContent process mid-JavaScript, RELEASE_ASSERT",
    ),
    (
        # The same rule where it can actually be exercised.
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchHandoff.swift",
        "        return superviewIsWindow ? .alreadyParked : .reparent",
        "        return .alreadyParked",
        "swift:BrowserWatchParkingTests/testAPageInsideTheWATCHCONTAINERIsReparentedRatherThanRefused",
        "a page left in the container it was being removed from, which is an orphan a moment later",
    ),
    (
        # ⭐ The black screen: the watched page rendered at the PARKED alpha.
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchHandoff.swift",
        "    public static let presentedAlpha: CGFloat = 1.0",
        "    public static let presentedAlpha: CGFloat = 0.01",
        "swift:BrowserWatchParkingTests/testThePARKEDAndPRESENTEDAlphasAreNotTheSameValue",
        "the owner tapping a platform and seeing a black rectangle over a page that is live, "
        "loaded, and one percent visible",
    ),
    (
        # ...and parking at zero would suspend the page's process instead of merely hiding it.
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchHandoff.swift",
        "    public static let parkedAlpha: CGFloat = 0.01",
        "    public static let parkedAlpha: CGFloat = 0",
        "swift:BrowserWatchParkingTests/testAParkedPageIsNEARLYInvisibleRatherThanFullyInvisible",
        "a parked page WebKit treats as invisible — its process suspends and the run stalls with "
        "no error anywhere",
    ),
    (
        # The restore, in the screen that presents it.
        "ios/App/LiveRunView.swift",
        "        web.alpha = BrowserWatchHandoff.presentedAlpha",
        "        web.alpha = BrowserWatchHandoff.parkedAlpha",
        "test_capture_guards.py::test_the_watched_page_is_restored_to_FULL_opacity",
        "the watched page never restored to full opacity, so Browser watch shows a dark rectangle",
    ),
    (
        # ⛔ No brief means no run — the others must not improvise one from the raw topic.
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "            if platform == Self.briefPlatform, brief.isEmpty {",
        "            if false {",
        "swift:RunExecutorNotebookPhaseTests/testWithNoBRIEFFromChatGPTTheOTHERAgentsAreNeverDriven",
        "a failed ChatGPT P1 cascading into Gemini and Claude each re-asking the raw topic — three "
        "platforms lighting up in Browser watch and two deep-research units spent on nothing",
    ),
    (
        # ...and it must be the PRODUCT that decides, not the exception: a too-short brief throws
        # nowhere and leaves `brief` empty just the same.
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "                await fail(\n"
        "                    reason: \"ChatGPT produced no brief, so there was nothing for the "
        "other agents \"\n"
        "                        + \"to research — phase 1 is ChatGPT's alone and the run stops "
        "here rather \"\n"
        "                        + \"than spending deep-research units on the raw topic\"\n"
        "                )",
        "                _ = \"the run is abandoned silently\"",
        "swift:RunExecutorNotebookPhaseTests/testARunWithNoBriefIsFAILEDWithTheReasonRatherThanLeftOngoing",
        "a run that died at phase 1 sitting `ongoing` for ever, with the owner watching a tile that "
        "never moves",
    ),

    # --- the deferred queue: what a parked worker is NOT taking, made visible -------------------
    (
        # ⛔ Without the publish, parking a worker looks exactly like the submission vanishing.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '                    path: "devices/\\(deviceID)", set: ["queueOwners": .array(owners)]',
        '                    path: "devices/\\(deviceID)", set: ["queueOwners": .array([])]',
        "swift:DeferredQueueTests/testAParkedWorkersWAITINGRunIsPublishedOntoTheDeviceDocument",
        "a run deferred by a parked worker showing on NO screen — not the owner's popup, not the "
        "phone's, not the submitter's banner",
    ),
    (
        # The claim goes to the server, not to the array this loop walks.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "                    reserved.insert(worker)\n                    settled.insert(entry.id)",
        "                    reserved.insert(worker)",
        "swift:DeferredQueueTests/testTheRunJUSTCLAIMEDIsNotPublishedAsWaiting",
        "the run that just STARTED advertised as the one queued behind itself",
    ),
    (
        # The last run leaving is exactly when the badges must go.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        if docs.isEmpty {\n            await publishDeferredQueue(",
        "        if docs.isEmpty {\n            if true { return }\n            await publishDeferredQueue(",
        "swift:DeferredQueueTests/testANOWEMPTYQueueClearsTheBadges",
        "a finished run keeping its queue badge for ever, because the empty queue is the one case "
        "that returned early",
    ),
    (
        # Remembering a failed publish as done.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "                lastPublishedDeferred = deferred\n            } catch {",
        "            } catch {\n                lastPublishedDeferred = deferred",
        "swift:DeferredQueueTests/testAFAILEDPublishIsRetriedOnTheNextBeat",
        "one dropped write leaving the queue badges wrong until the queue happens to change again",
    ),
    (
        # ⛔ The rules judge the PAYLOAD: no deviceId in the patch, no write.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '            "deviceId": .string(deviceID),\n            "queuePosition"',
        '            "queuePosition"',
        "swift:DeferredQueueTests/testTheWaitingRunsOwnDocumentIsToldWhereItStandsWithTheDeviceStamp",
        "every position write 403ing — the same trap the finish patch hit, and just as silent",
    ),
    (
        # A stale predecessor must be REMOVED, not overwritten.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '            delete = ["queuedBehindRunId", "queuedBehindTitle"]',
        '            set["queuedBehindRunId"] = .string("")',
        "swift:DeferredQueueTests/testTheHEADClearsAStalePredecessorRatherThanOverwritingIt",
        "the head of the queue still reading as waiting behind a run that finished an hour ago",
    ),
    (
        # The ahead-counts are split by account because the two say different things.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "                aheadFromOthers: index - fromSelf,",
        "                aheadFromOthers: index,",
        "swift:DeferredQueueTests/testTheRunsAheadAreSPLITByWhoSubmittedThem",
        "your own queued runs counted as other people's, so a private queue reads as a busy "
        "shared device",
    ),
    (
        # A claimed document is running, not waiting.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "            $0.action == .start && !$0.processed && $0.assignedWorker == nil",
        "            $0.action == .start && !$0.processed",
        "swift:DeferredQueueTests/testAClaimedOrProcessedDocumentIsNotAWaitingRun",
        "the RUNNING run published as queued, which shifts every real position by one",
    ),
    (
        # The positions ARE the ordering claim.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        let waiting = fifoOrdered(entries).filter {",
        "        let waiting = entries.filter {",
        "swift:DeferredQueueTests/testTheORDERIsNotTakenOnTrustFromTheCaller",
        "published positions that disagree with the order the claim path takes — the same list, "
        "two answers about who is next",
    ),
    (
        # submittedBy vs uid: they differ on a sharer's run.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        entry.submittedBy.isEmpty ? entry.uid : entry.submittedBy",
        "        entry.uid.isEmpty ? entry.submittedBy : entry.uid",
        "swift:DeferredQueueTests/testTheSUBMITTERIsWhoTheBadgeBelongsTo",
        "a sharer's queued run badged onto the device owner in the Shared-with popup",
    ),
    (
        # A parked queue that is never re-stamped is a queue the wake-side sweep eats.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        guard workersResting else { return false }",
        "        return false",
        "swift:DeferredQueueTests/testAParkedRunsAbandonmentClockIsRESTAMPEDWhileTheWorkerRests",
        "parking a worker over a weekend and coming back on Monday to find the sweep deleted the "
        "queued run",
    ),
    (
        # ...but only while RESTING, or the abandonment horizon is unbounded for every queue.
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        guard let stamp = run.restDeferredAtMillis, stamp > 0 else { return true }\n"
        "        return now - stamp > restStampRefreshMillis",
        "        return true",
        "swift:DeferredQueueTests/testAFRESHStampIsNotRewrittenOnEveryPass",
        "a write per waiting run per beat, for ever, to re-say something already true",
    ),
    (
        # ⛔ The run control channel: every active run, not the one claimed last.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        for (_, active) in activeRuns { await pollRunCommands(for: active) }",
        "        if let active = activeRuns.first?.value { await pollRunCommands(for: active) }",
        "swift:ConcurrentRunsTests/testSTOPReachesTheRunItWasWrittenForWhenTwoAreInFlight",
        "an owner's Stop reaching nothing on a run this device is genuinely executing",
    ),
    (
        # "First poll" is a fact about a RUN, not about the process.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        let isFirstPoll = !runCommandsAttached.contains(active.researchID)",
        "        let isFirstPoll = runCommandsAttached.isEmpty",
        "swift:ConcurrentRunsTests/testTheSTALECheckIsAppliedToEachRunsFirstPollSeparately",
        "a previous session's Stop executing against a brand-new run on the second worker",
    ),
    (
        # dedupeKey is unique only within one research's subcollection.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '            let key = "\\(active.researchID)/\\(entry.dedupeKey)"',
        "            let key = entry.dedupeKey",
        "swift:ConcurrentRunsTests/testTwoRunsWithIdenticallyNamedCommandsAreBothObeyed",
        "one run's handled command silencing another run's identically-named one",
    ),
    (
        # The zombie sweep must skip EVERY run in flight, not one.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            if activeRuns.values.contains(where: { $0.researchID == entry.researchId }) {",
        "            if false {",
        "swift:ConcurrentRunsTests/testAQueueEntryForANYRunInFlightIsLeftAlone",
        "deleting the queue entry of a run that is progressing perfectly well",
    ),
    # --- P1's effort tier: the ranking rule, its two guards, and the honest verdicts -------------
    (
        # ⭐ The one that inverts. This menu's only numbered row is its CHEAPEST.
        "ios/Sources/SuperResearchDeviceCore/ChatGPTModelPolicy.swift",
        "            if !hasTerm(t, tiers) { continue }",
        "            if false { continue }",
        # ⚠ NOT guarded by the picks-Pro test, and the reason is worth keeping: with the filter
        # gone, every row ranks version-less, the shortest-label tie-break runs, and "Pro" is the
        # shortest label on the live menu — so that test still passes. The filter's observable job
        # is refusing to pick ANYTHING when no row names the tier.
        "swift:ChatGPTModelPolicyTests/testNothingIsPickedWhenNoRowNamesTheTier",
        "pressing whatever row has the shortest label on an account with no Pro, then reporting it",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ChatGPTModelPolicy.swift",
        "            if !verbs.isEmpty && hasTerm(t, verbs) { continue }",
        "            if false { continue }",
        "swift:ChatGPTModelPolicyTests/testAnUPGRADECallToActionNamesTheTierWithoutBeingEvidenceOfIt",
        "an 'Upgrade to Pro' sales prompt counting as evidence of the tier it is selling",
    ),
    (
        # The leaf rule. A wrapper concatenating every row names the tier too.
        "ios/Sources/SuperResearchDeviceCore/ChatGPTModelPolicy.swift",
        "                || (rank == bestRank && t.count < bestLen)",
        "                || (rank == bestRank && t.count > bestLen)",
        "swift:ChatGPTModelPolicyTests/testAWRAPPERThatCarriesTheTierWordLosesToTheLeaf",
        "clicking a menu wrapper, which never reaches a row handler while reporting success",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ChatGPTModelPolicy.swift",
        "                let leftOK = i == 0 || !isASCIIAlnum(t[i - 1])",
        "                let leftOK = true",
        # ⚠ Repointed. The "productivity" cases are rejected by the RIGHT boundary alone, so this
        # mutation survived the test that named them — the left boundary's own case is a tier word
        # glued to the END of a concatenation, which is what a menu wrapper produces.
        "swift:ChatGPTModelPolicyTests/testTheTierWordGluedToTheENDOfAConcatenationIsNotAMatch",
        "a glued wrapper like 'Instant 5.5Pro' reading as a tier row and being clicked",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ChatGPTModelPolicy.swift",
        'for pattern in ["\\(fam)\\(sep)\\(num)", "\\(num)\\(sep)\\(fam)"] {',
        'for pattern in ["\\(num)\\(sep)\\(fam)", "\\(fam)\\(sep)\\(num)"] {',
        "swift:ChatGPTModelPolicyTests/testTheFamilyFirstPatternWinsOnAGluedWrapper",
        "a glued wrapper stealing a sibling row's version number and outranking the real leaf",
    ),
    (
        # ⛔ The invariant that is only visible as a call count.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        if ChatGPTModelPolicy.triggerIsOnTarget(pre.text) {",
        "        if false {",
        "swift:EffortTierSelectionTests/testAnAlreadyOnTargetTriggerOpensNOTHING",
        "opening a popover over the composer on every run, which the next phase's send then taps",
    ),
    (
        # ⛔ The worst outcome this path can produce.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        if ChatGPTModelPolicy.triggerIsOnTarget(post.text) {",
        "        if true {",
        "swift:EffortTierSelectionTests/"
        "testAPressedRowThatDoesNotMoveTheTriggerIsNEVERReportedAsSelected",
        "a silent downgrade reported as a successful pick — a brief written on Instant, called Pro",
    ),
    (
        # `noTarget` is read as "this account has no Pro" and may not rest on the weakest hook.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        '            if via == "menu-item-class" {',
        "            if false {",
        "swift:EffortTierSelectionTests/testTheCLASSFallbackIsNotAllowedToClaimTheAccountHasNoTier",
        "the tools menu being mistaken for the model menu and reported as a lapsed subscription",
    ),
    (
        # ⛔⛔ The 2026-08-05 navigation, arm 1.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        if (el.closest && el.closest('a[href]')) return false;",
        "        if (false) return false;",
        "test_model_menu_js.py::test_a_row_NESTED_INSIDE_an_anchor_is_also_refused",
        "pressing a sidebar conversation link, which navigates the tab mid-run",
    ),
    (
        # arm 2 — the census.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        return (seen || []).indexOf(t) === -1;",
        "        return true;",
        "test_model_menu_js.py::test_a_row_ALREADY_ON_SCREEN_before_the_press_is_refused",
        "a row that predates the menu counting as one of its rows",
    ),
    (
        # ...and the stand-down that keeps arm 2 from breaking a working path.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "          if (withCensus.rows.length || !seen.length) return withCensus;",
        "          return withCensus;",
        "test_model_menu_js.py::"
        "test_when_the_census_empties_EVERYTHING_the_read_retries_without_it_and_says_so",
        "a durability measure silently reporting no rows when it rejected every real one",
    ),
    (
        # IDENTITY DECIDES, not position.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "          if (text !== \\(Self.jsString(expect))) {",
        "          if (false) {",
        "test_model_menu_js.py::test_the_click_REFUSES_when_the_label_at_that_index_changed",
        "pressing whatever row moved into that position while the ranking round trip was in flight",
    ),
    (
        # The destructive one: the DR pill and the model pill are indistinguishable structurally.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "              if (avoid && t.toLowerCase().indexOf(avoid) !== -1) continue;\n"
        "              return {found: true, via: groups[g].name, text: t.slice(0, 60)};",
        "              return {found: true, via: groups[g].name, text: t.slice(0, 60)};",
        "test_model_menu_js.py::test_the_trigger_read_SKIPS_the_deep_research_pill",
        "reading the tier off the Deep-Research pill, whose press ADDS a second deep research",
    ),
    (
        # The phase wiring: the verdict must reach the outcome, not be dropped.
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                    outcome.effortTier = try await driver.selectEffortTier(sleep: sleep)"
        ".detail",
        "                    _ = try await driver.selectEffortTier(sleep: sleep)",
        "swift:InAppPipelineTests/"
        "testP1STILLPRODUCESTheBriefWhenTheTierCouldNotBeEstablishedAndSaysSo",
        "a run that cannot say which tier wrote its brief",
    ),
    # --- the agent's mid-wait failure catalogue -------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "            if polls % 20 == 0 {",
        "            if polls % 20 == 1000000 {",
        "test_inapp_parity.py::test_the_interruption_check_is_throttled_rather_than_run_every_poll",
        "the mid-wait watch never running, so a session that ends mid-wait reports a 45-minute timeout",
    ),

    # --- the C1-in-app extraction --------------------------------------------------------------
    (
        "ios/App/main.swift",
        "                manifestSource: SRManifest.manifestSource",
        '                manifestSource: "placeholder"',
        "test_inapp_parity.py::test_the_verdict_carries_its_manifests_provenance",
        "an entry point feeding fake provenance, so a wiring proof earns real coverage credit",
    ),

    # --- the agent's first real failure catalogue ----------------------------------------------
    (
        "emubackend/phases.py",
        # Anchored with the following line too: `await_response` now runs the same check mid-wait, so
        # the bare `if` appears twice and the harness correctly refused an ambiguous anchor.
        '        if health["state"] == "error":\n            raise PlatformStateError(\n                f"{self.platform}: the platform reported an error instead of a response "',
        '        if health["state"] == "never":\n            raise PlatformStateError(\n                f"{self.platform}: the platform reported an error instead of a response "',
        "test_response_health.py::test_harvest_refuses_to_extract_from_a_platform_error",
        "harvesting a platform error banner as research — a run reporting success with a plausible body",
    ),
    (
        "emubackend/phases.py",
        "    for fragment in PLATFORM_ERROR_FRAGMENTS:\n        if fragment in low:",
        "    for fragment in []:\n        if fragment in low:",
        "test_response_health.py::test_the_real_error_banner_is_an_error_not_content",
        "a platform error banner classified as content and harvested as research",
    ),
    (
        "emubackend/phases.py",
        "    if not stripped:",
        "    if not raw:",
        "test_response_health.py::test_the_real_empty_turn_is_empty_not_content",
        "six minutes of 'ChatGPT said: ' counting as an answer because the prefix was not stripped",
    ),

    # --- selectors verified against the wrong STATE --------------------------------------------
    (
        "selectors_mobile.json",
        '"css": [\n     "[data-turn=assistant]",',
        '"css": [\n     "[data-message-author-role=assistant]",',
        "test_capture_guards.py::test_chatgpts_response_container_prefers_the_state_independent_handle",
        "response_container blind during a deep-research run, where no author-role attribute exists",
    ),

    # --- regressions the gate re-run caught, after the predicate port -------------------------
    (
        "emubackend/selectors.py",
        "        if platform in named",
        "        if platform in ALLOWED_KEYS",
        "test_selectors_and_phases.py::test_a_single_platform_manifest_is_measured_against_that_platform",
        "a one-platform manifest judged against all 25 keys, failing the e2e gate on a correct file",
    ),
    (
        "emubackend/phases.py",
        "        if (p.hasAttribute('aria-pressed') || p.hasAttribute('aria-checked')",
        "        if (false && p.hasAttribute('aria-checked')",
        "test_toggle_idempotence.py::test_a_control_carrying_state_is_not_mistaken_for_the_indicator",
        "the toggle becoming its own on-signal, so enable_deep_research never taps and DR stays off",
    ),
    (
        "emubackend/phases.py",
        "        on = control_on or pill_visible or placeholder_research",
        "        on = pill_visible or placeholder_research",
        "test_toggle_idempotence.py::test_the_controls_own_state_is_enough_on_its_own",
        "ignoring the control's own aria-pressed, so a well-behaved toggle reports off after a tap",
    ),

    # --- the deep-research predicate ported from the backend ---------------------------------
    (
        "emubackend/phases.py",
        "        || placeholder.includes('chat with') || placeholder.includes('write a message')",
        "        || placeholder.includes('write a message')",
        "test_toggle_idempotence.py::test_chatgpts_real_placeholder_is_recognised_as_chat_mode",
        "ChatGPT never able to report confirmed_off, so escalation is refused forever",
    ),
    (
        "emubackend/phases.py",
        '            "button, a, [role=button], [role=menuitem], [role=menuitemradio], "\n'
        '            "[role=menuitemcheckbox], [role=option]"',
        '            "button, a, [role=button]"',
        "test_selectors_and_phases.py::test_the_text_fallback_reaches_menu_items_not_just_buttons",
        "the text fallback missing menu items, so ChatGPT's deep-research item is unreachable by text",
    ),
    (
        "emubackend/phases.py",
        "        on = control_on or pill_visible or placeholder_research",
        "        on = control_on or placeholder_research",
        "test_toggle_idempotence.py::test_chatgpts_visible_pill_alone_reads_as_on",
        "ChatGPT's visible DR pill no longer reading as active, so an ON toggle gets tapped OFF",
    ),
    (
        "emubackend/phases.py",
        "        on = control_on or pill_visible or placeholder_research",
        "        on = control_on or pill_visible",
        "test_toggle_idempotence.py::test_a_research_placeholder_reads_as_ON_without_any_aria_state",
        "dropping the placeholder signal — the exact aria-only read that toggled a working DR off",
    ),
    (
        "emubackend/phases.py",
        '            "off": (control_off or placeholder_chat) and not on,',
        '            "off": not on,',
        "test_toggle_idempotence.py::test_an_ambiguous_state_is_neither_on_nor_confirmed_off",
        "confirmed-off degrading to `not on`, authorising a click on a control of unknown state",
    ),
    (
        "emubackend/phases.py",
        '        name = "research" if self.platform == "claude" else "deep research"',
        '        name = "deep research"',
        "test_toggle_idempotence.py::test_the_control_name_differs_per_platform",
        "probing Claude for 'deep research', which matches nothing on that platform at all",
    ),
    (
        "emubackend/phases.py",
        "            if not entry.resolvable:\n                return False",
        "            if not entry.resolvable:\n                return True",
        "test_toggle_idempotence.py::test_an_uncaptured_toggle_never_reads_as_on_however_good_the_placeholder",
        "an uncaptured platform reading as configured off a page-level placeholder",
    ),

    # --- the guards added after the first real signed-in capture -----------------------------
    (
        "emubackend/selectors.py",
        "        platform: {key: SelectorEntry() for key in keys}\n"
        "        for platform, keys in ALLOWED_KEYS.items()",
        "        platform: {}\n"
        "        for platform, keys in ALLOWED_KEYS.items()",
        "test_selectors_and_phases.py::test_coverage_counts_every_key_of_a_named_platform_not_just_the_supplied_ones",
        "a partial manifest shrinking the denominator, so 7-of-25 captured keys report 7/7 complete",
    ),
    (
        "bin/capture_selectors.py",
        "        if key in POST_RESPONSE_KEYS and not response_present:",
        "        if key in POST_RESPONSE_KEYS and response_present:",
        "test_capture_guards.py::test_chatgpts_images_nav_link_never_becomes_sources",
        "capturing `sources` from a page with no answer, making ChatGPT's Images nav link the source list",
    ),
    (
        "bin/capture_selectors.py",
        "                    or (h.get(\"rank\") == 4 and h.get(\"matches\") == 1)",
        "                    or (h.get(\"rank\") == 4 and h.get(\"matches\") != 1)",
        "test_capture_guards.py::test_an_ambiguous_aria_label_target_is_rejected",
        "accepting an aria-label match that resolves to several nodes, so resolve() takes document order",
    ),
    (
        "bin/capture_selectors.py",
        "    signed_in = not on_auth_host and not controls",
        "    signed_in = not on_auth_host or not controls",
        "test_capture_guards.py::test_the_real_signed_out_chatgpt_shell_is_refused",
        "drafting from a signed-out page, whose anonymous composer looks exactly like the real one",
    ),
    (
        "bin/capture_selectors.py",
        "        needs_visible = key not in PRESENCE_ONLY_KEYS",
        "        needs_visible = key in PRESENCE_ONLY_KEYS",
        "test_capture_guards.py::test_visibility_is_still_required_for_anything_tapped",
        "accepting an invisible send button, which cannot be tapped",
    ),
    (
        "bin/capture_selectors.py",
        '_DATA_ATTR_PROBE = re.compile(r"^\\[data-[a-z-]+=[^*^$~|\\]]+\\]$")',
        '_DATA_ATTR_PROBE = re.compile(r"^\\[data-[a-z-]+.+\\]$")',
        "test_capture_guards.py::test_a_search_term_is_not_accepted_as_a_handle",
        "treating a `*=` search term as an identity, so a substring probe becomes the selector",
    ),
    (
        "bin/capture_selectors.py",
        "            if durable is not None:",
        "            if durable is None:",
        "test_capture_guards.py::test_the_durable_probe_fallback_rescues_an_undescribable_element",
        "the semantic-probe fallback never firing, leaving response_container to an indexed testid",
    ),
    (
        "bin/capture_selectors.py",
        '                    or h.get("tag") == "button"',
        '                    or h.get("tag") != "button"',
        "test_capture_guards.py::test_a_tapped_key_will_not_accept_a_wrapper_div",
        "a tapped key accepting a wrapper div, e.g. Gemini's send-button-container over its button",
    ),
    (
        "bin/capture_selectors.py",
        '_DATA_PRESENCE_PROBE = re.compile(r"^[a-z]*\\[data-[a-z-]+\\]$")',
        '_DATA_PRESENCE_PROBE = re.compile(r"^[a-z]*\\[.+\\]$")',
        "test_capture_guards.py::test_a_search_term_is_not_accepted_as_a_handle",
        "any bracketed selector counting as an identity, so div[contenteditable=true] becomes a handle",
    ),
    (
        "bin/capture_selectors.py",
        "            if (node.querySelectorAll('button,[role=button]').length > 0) { root = node; break; }",
        "            if (node.querySelectorAll('button,[role=button]').length < 0) { root = node; break; }",
        "test_capture_guards.py::test_the_composer_scope_walks_up_when_there_is_no_form",
        "the composer scope never widening past a button-less parent, so send looks absent",
    ),
    (
        "emubackend/berepo.py",
        "    for node in tree.body:",
        "    for node in ast.walk(tree):",
        "test_berepo.py::test_research_module_level_imports_are_only_models_and_prompts",
        "conflating module-level with function-local imports (what a grep would do)",
    ),
    (
        "emubackend/purity.py",
        "        if cur.head != base.head:",
        "        if False:",
        "test_a8_purity.py::test_compare_detects_a_moved_head",
        "a commit to the BE going unnoticed",
    ),
    (
        "emubackend/purity.py",
        "        new_untracked = sorted(set(cur.untracked) - set(base.untracked))",
        "        new_untracked = []",
        "test_a8_purity.py::test_compare_detects_a_new_untracked_file",
        "a new file dropped into the BE going unnoticed",
    ),
    (
        "emubackend/purity.py",
        "            elif cur_digest != base_digest:",
        "            elif False:",
        "test_a8_purity.py::test_compare_detects_a_change_gitignore_would_have_hidden",
        "the D-1 editable-install scenario that .gitignore hides from git status",
    ),
    (
        "emubackend/purity.py",
        '        if appeared:\n            raise PurityViolation(',
        '        if False:\n            raise PurityViolation(',
        "test_a8_purity.py::test_no_queue_writes_detects_a_path_appearing",
        "setup_firestore_run writing owner.json into the BE's queues/",
    ),
    (
        "emubackend/purity.py",
        "        h.update(hashlib.sha256(data).digest())",
        "        h.update(b'')",
        "test_a8_purity.py::test_digest_ignores_mtime_but_catches_content",
        "a content change of equal length going unnoticed",
    ),
    (
        "emubackend/berepo.py",
        '        if module_name.split(".")[0] not in CLAIMED_TOP_LEVEL_NAMES:'.lstrip()
        and '    if module_name.split(".")[0] not in CLAIMED_TOP_LEVEL_NAMES:',
        "    if False:",
        "test_berepo.py::test_import_be_rejects_a_name_the_backend_does_not_claim",
        "a typo'd module name silently importing something else",
    ),
    # ---- geometry: the two device behaviours that cost real time to find ----
    (
        "emubackend/substrate/geometry.py",
        '        if any(e.get("type") == "click" for e in events):\n            break',
        "        if True:\n            break",
        "test_geometry.py::test_tap_and_capture_waits_for_the_terminal_click",
        "not waiting for the tap's own sequence to complete, leaving a click to leak onward",
    ),
    (
        "emubackend/substrate/geometry.py",
        '            and e.get("type") in ("pointerdown", "touchstart")',
        "            and True",
        "test_geometry.py::test_a_previous_taps_click_is_not_misattributed",
        "accepting any trusted event, so a previous tap's rounded click becomes this tap's position",
    ),
    (
        "emubackend/substrate/geometry.py",
        '            and e.get("type") in ("pointerdown", "touchstart")',
        "            and True",
        "test_geometry.py::test_calibrate_survives_the_leaking_click_ordering",
        "the same defect seen end-to-end: it is what produced scale_x=241 on the device",
    ),
    (
        "emubackend/substrate/geometry.py",
        '    vv = viewport.get("vvHeight")',
        "    vv = None",
        "test_geometry.py::test_tap_element_refuses_a_target_hidden_behind_the_keyboard",
        "using innerHeight for visibility, so a target behind the keyboard is tapped through it",
    ),
    (
        "emubackend/substrate/geometry.py",
        '    "vvScale",\n)',
        '    "vvScale",\n    "vvHeight",\n)',
        "test_geometry.py::test_keyboard_does_not_invalidate_the_calibration",
        "treating the keyboard as a transform change, forcing a recalibration that taps the keyboard",
    ),
    (
        "emubackend/substrate/geometry.py",
        "def _close(a: Any, b: Any, tol: float = 0.75) -> bool:",
        "def _close(a: Any, b: Any, tol: float = 1e9) -> bool:",
        "test_geometry.py::test_a_real_layout_change_does_invalidate_the_calibration",
        "a stale calibration surviving a genuine layout change (e.g. rotation)",
    ),
    (
        "emubackend/substrate/hid.py",
        "        if value < 0:",
        "        if False:",
        "test_hid.py::test_tap_refuses_negative_coordinates",
        "a negative coordinate reaching AXe, which misreports it as a missing argument",
    ),
    # ---- the seam ----
    (
        "emubackend/substrate/backend.py",
        '        if not state or state.get("visibility") != "visible" or state.get("hidden"):',
        "        if False:",
        "test_backend_contract.py::test_input_is_refused_on_a_background_tab",
        "HID input going to a background tab, landing on whatever is in front instead",
    ),
    (
        "emubackend/substrate/backend.py",
        "        if client_y < 0 or client_y > vis:",
        "        if False:",
        "test_backend_contract.py::test_input_is_refused_when_the_keyboard_covers_the_target",
        "tapping straight through the software keyboard at a hidden target",
    ),
    (
        "emubackend/substrate/page_shim.py",
        "    if result is None:",
        "    if False:",
        "test_backend_contract.py::test_a_null_runtime_reply_is_treated_as_failure_not_success",
        "a thrown/absent-runtime call reporting success - the 'nothing happened' bug class",
    ),
    (
        "emubackend/substrate/page_shim.py",
        "        await self.scroll_into_view_if_needed()\n        rect = _unwrap(",
        "        rect = _unwrap(",
        "test_backend_contract.py::test_click_scrolls_into_view_then_re_reads_the_rect_before_tapping",
        "tapping an off-screen element's stale rect, hitting whatever occupies that position",
    ),
    # ---- contract core: REST encoding ----
    (
        "emubackend/contract/values.py",
        '        return {"booleanValue": value}',
        '        return {"integerValue": str(int(value))}',
        "test_contract_core.py::test_bool_is_checked_before_int",
        "encoding True as integerValue, silently changing the stored type",
    ),
    (
        "emubackend/contract/values.py",
        '        return {"integerValue": str(value)}',
        '        return {"stringValue": str(value)}',
        "test_contract_core.py::test_int_encodes_as_integervalue_so_rules_see_a_number",
        "seq/timestamp as stringValue - DENIED by rules, reported as a permissions problem",
    ),
    (
        "emubackend/contract/values.py",
        "    if dt.tzinfo is None:",
        "    if False:",
        "test_contract_core.py::test_timestamp_value_refuses_a_naive_datetime",
        "a naive datetime shifting a TTL by the local offset - an early expiry deletes the doc",
    ),
    (
        "emubackend/contract/values.py",
        "        if path in present:",
        "        if False:",
        "test_contract_core.py::test_update_mask_refuses_a_field_that_is_both_set_and_deleted",
        "a field set and deleted in one patch, where Firestore applies the set",
    ),
    # ---- contract core: events ----
    (
        "emubackend/contract/events.py",
        "            if candidate <= self._last:",
        "            if False:",
        "test_contract_core.py::test_two_events_in_the_same_millisecond_still_differ",
        "duplicate seq values, which the strictly-greater-than consumer cursor drops",
    ),
    (
        "emubackend/contract/events.py",
        "            self._last = max(self._last, int(seq))",
        "            self._last = int(seq)",
        "test_contract_core.py::test_observe_never_lowers_the_floor",
        "observe() lowering the floor, so a resumed run emits below the consumer cursor",
    ),
    (
        "emubackend/contract/events.py",
        "    if phase is not None:",
        "    if phase:",
        "test_contract_core.py::test_phase_zero_is_written_because_the_guard_is_is_not_none",
        "dropping phase=0, and P0 is a real phase",
    ),
    (
        "emubackend/contract/events.py",
        "    if agent:",
        "    if agent is not None:",
        "test_contract_core.py::test_an_empty_agent_is_omitted_and_a_real_one_is_not_lowercased",
        "writing agent='' where upstream omits the field entirely",
    ),
    (
        "emubackend/contract/events.py",
        "    if payload:",
        "    if payload is not None:",
        "test_contract_core.py::test_empty_data_is_omitted_entirely",
        "writing data:{} where the backend omits it - the wrong absence semantics",
    ),
    # ---- contract core: pendingDecision ----
    (
        "emubackend/contract/pending_decision.py",
        "    a = normalize_agent(agent)",
        "    a = agent",
        "test_contract_core.py::test_rule1_an_empty_agent_string_means_an_unconditional_clear",
        "skipping the lower()-or-None normalisation, inverting the keep-guard for ''",
    ),
    (
        "emubackend/contract/pending_decision.py",
        "    owner = normalize_agent(state.agent)",
        "    owner = state.agent",
        "test_contract_core.py::test_rule1_the_agent_comparison_is_case_insensitive",
        "a case-sensitive agent comparison, refusing a legitimate clear",
    ),
    (
        "emubackend/contract/pending_decision.py",
        "    if state.active and owner is not None and owner != a:",
        "    if False:",
        "test_contract_core.py::test_rule1_a_late_clear_from_a_different_agent_is_refused",
        "a late clear deleting another agent's live blocking card - invisible until reopen",
    ),
    (
        "emubackend/contract/pending_decision.py",
        '    if not inputs.data.get("actions"):',
        "    if False:",
        "test_contract_core.py::test_rule3_the_mirror_gate_is_a_four_way_and",
        "mirroring errors with no user actions, making log noise durable",
    ),
    (
        "emubackend/contract/pending_decision.py",
        '    if inputs.data.get("quiet") and not inputs.force_mirror:',
        "    if False:",
        "test_contract_core.py::test_rule3_transient_overload_banners_must_not_become_durable",
        "a transient 529 auto-retry banner becoming a permanent decision card",
    ),
    (
        "emubackend/contract/pending_decision.py",
        "    return agent if event_type in CLEAR_SET_SCOPED_BY_AGENT else None",
        "    return agent",
        "test_contract_core.py::test_rule2_phase_restart_clears_unconditionally_because_retry_emits_it",
        "scoping phase_restart by agent, so Retry strands a stale card",
    ),
    # ---- contract core: REST transport ----
    (
        "emubackend/contract/rest.py",
        "AUTH_RETRY_CODES = (401, 403)",
        "AUTH_RETRY_CODES = (401,)",
        "test_rest.py::test_an_auth_failure_retries_once_with_a_FORCE_REFRESHED_token",
        "dropping the 403 heal, so a stale credential kills a run mid-flight",
    ),
    (
        "emubackend/contract/rest.py",
        "            resp = self._send(method, url, self._token(force=True), json_body)",
        "            resp = self._send(method, url, self._token(), json_body)",
        "test_rest.py::test_an_auth_failure_retries_once_with_a_FORCE_REFRESHED_token",
        "retrying with the SAME cached token, which fails identically",
    ),
    (
        "emubackend/contract/rest.py",
        '        for field, op in (("ownerUid", "EQUAL"), ("sharedWith", "ARRAY_CONTAINS")):',
        '        for field, op in (("ownerUid", "EQUAL"),):',
        "test_rest.py::test_list_devices_issues_two_queries_and_unions_them",
        "one query instead of two, silently truncating the device list (no cross-field OR)",
    ),
    (
        "emubackend/contract/rest.py",
        "        mask = values.update_mask_for(fields, delete_paths)",
        "        mask = list(fields)",
        "test_rest.py::test_a_deleted_field_is_in_the_mask_and_absent_from_the_body",
        "omitting deleted paths from the mask, so a field delete silently does nothing",
    ),
    (
        "emubackend/contract/rest.py",
        "            if doc:\n                out.append(decode_document(doc))",
        "            out.append(decode_document(doc or {}))",
        "test_rest.py::test_run_query_tolerates_readtime_only_rows",
        "treating runQuery's readTime-only rows as documents",
    ),
    # ---- golden fixtures ----
    (
        "emubackend/contract/fixtures.py",
        "        if key in volatile:",
        "        if False:",
        "test_fixtures.py::test_volatile_values_become_type_markers_so_two_runs_agree",
        "comparing epoch-millis values raw, so the fixture suite fails every single run",
    ),
    (
        "emubackend/contract/fixtures.py",
        '_ID_SEGMENT = re.compile(r"[0-9A-Za-z_-]{16,}")',
        '_ID_SEGMENT = re.compile(r"[0-9A-Za-z_-]{4,}")',
        "test_fixtures.py::test_short_path_segments_are_not_mistaken_for_ids",
        "over-tokenising real path segments, so the comparison checks nothing useful",
    ),
    (
        "emubackend/contract/fixtures.py",
        "        if g.delete_paths != a.delete_paths:",
        "        if False:",
        "test_fixtures.py::test_a_dropped_delete_path_fails",
        "missing a dropped expireAt delete - the atomic pair-confirm's entire purpose",
    ),
    (
        "emubackend/contract/fixtures.py",
        "    for i in range(max(len(golden), len(actual))):",
        "    for i in range(min(len(golden), len(actual))):",
        "test_fixtures.py::test_a_short_sequence_reports_what_is_missing",
        "a truncated write sequence comparing clean",
    ),
    (
        "emubackend/contract/fixtures.py",
        "        for key in sorted(set(g.fields) | set(a.fields)):",
        "        for key in sorted(set(g.fields) & set(a.fields)):",
        "test_fixtures.py::test_every_difference_is_reported_not_just_the_first",
        "ignoring fields that are missing or extra rather than merely different",
    ),
    # ---- wrapped intents (phase A1) ----
    (
        "emubackend/intents.py",
        '    return observation_enabled() and os.environ.get("DG_IOS_SELFHEAL_ACT") == "1"',
        '    return os.environ.get("DG_IOS_SELFHEAL_ACT") == "1"',
        "test_intents.py::test_act_requires_both_flags",
        "ACT alone arming the actor, so turning observation on could arm actions",
    ),
    (
        "emubackend/intents.py",
        "        if not act_enabled():",
        "        if False:",
        "test_intents.py::test_the_wrapper_is_a_no_op_with_flags_off",
        "the wrapper acting with flags off - the recipe's explicit gate for A1 existing",
    ),
    (
        "emubackend/intents.py",
        "        if not status.baked:",
        "        if False:",
        "test_intents.py::test_an_unbaked_predicate_may_log_but_never_escalate",
        "an unbaked predicate escalating an agent onto a possibly-healthy page",
    ),
    (
        "emubackend/intents.py",
        "            not self.poisoned\n            and self.false_positives == 0",
        "            self.false_positives == 0",
        "test_intents.py::test_the_poisoned_flag_blocks_a_bake_on_its_own",
        "the poisoned invariant collapsing into the counter, so a future counter reset rehabilitates a wolf-crier",
    ),
    (
        "emubackend/intents.py",
        "    if off_error is not None or not off_confirmed:",
        "    if False:",
        "test_intents.py::test_an_unconfirmed_off_signal_refuses_the_action",
        "the #709 guard gone - a false-negative predicate switching a live control OFF",
    ),
    (
        "emubackend/intents.py",
        "    if pred_error is not None:",
        "    if False:",
        "test_intents.py::test_a_broken_predicate_does_not_manufacture_a_failure",
        "a raising predicate manufacturing a failure and escalating onto a fine page",
    ),
    (
        "emubackend/intents.py",
        "    outcome.healed = bool(reverified) and reverify_error is None",
        "    outcome.healed = True",
        "test_intents.py::test_a_heal_that_ran_but_did_not_work_is_not_reported_as_healed",
        "reporting 'the heal ran' as 'the heal worked'",
    ),
    (
        "emubackend/intents.py",
        "        if not intent.escalation_eligible:",
        "        if False:",
        "test_intents.py::test_shadow_only_forever_is_a_valid_resting_state",
        "acting on an intent with no positive off-signal or no reversibility",
    ),
    # ---- orchestration invariants ----
    (
        "emubackend/controls.py",
        "        return self.pause_event.is_set() and not self.resume_event.is_set() and not self.stopped",
        "        return self.pause_event.is_set() and not self.resume_event.is_set()",
        "test_controls_and_claim.py::test_resume_must_not_revive_a_stopped_run",
        "a stopped run still reading as paused, so a Resume tap restarts ended work",
    ),
    (
        "emubackend/controls.py",
        "        if self.stopped:\n            return\n        self.pause_event.clear()",
        "        if False:\n            return\n        self.pause_event.clear()",
        "test_controls_and_claim.py::test_resume_must_not_revive_a_stopped_run",
        "Resume reviving a stopped run - a duplicated pipeline",
    ),
    (
        "emubackend/controls.py",
        "        if origin == SkipOrigin.USER_TAP:",
        "        if True:",
        "test_controls_and_claim.py::test_only_a_real_tap_counts_as_a_user_skip",
        "the 2026-07-11 incident: an internal marker reported as a user decision, retracting the honest card",
    ),
    (
        "emubackend/controls.py",
        '        if target and target != (agent or "").lower():',
        "        if False:",
        "test_controls_and_claim.py::test_a_targeted_decision_cannot_be_stolen_by_another_agents_park",
        "one agent's park stealing a decision addressed to another",
    ),
    (
        "emubackend/controls.py",
        "        self.awaiting_user = False\n        self.pending_agent_decision = None",
        "        self.pending_agent_decision = None",
        "test_controls_and_claim.py::test_reset_clears_awaiting_user_or_the_next_runs_watchdog_never_fires",
        "a stale awaiting_user so the NEXT run's watchdog never fires - an absent safety net",
    ),
    (
        "emubackend/controls.py",
        "        return not self.awaiting_user",
        "        return True",
        "test_controls_and_claim.py::test_waiting_on_a_human_does_not_count_as_active_time",
        "the watchdog killing a legitimate wait-for-the-user as 'stuck'",
    ),
    # ---- claim sentinel ----
    (
        "emubackend/claim.py",
        '    for guarded in ("dg-research-backend", "dg-research"):',
        "    for guarded in ():",
        "test_controls_and_claim.py::test_the_lock_dir_inside_a_guarded_repo_is_refused",
        "writing worker locks into the BE checkout's queues/, which the daemon scans",
    ),
    (
        "emubackend/claim.py",
        "        if age > PID_REUSE_MAX_AGE_MS:",
        "        if False:",
        "test_controls_and_claim.py::test_a_live_pid_with_an_ancient_claim_is_a_recycled_pid_not_a_live_claim",
        "a recycled PID reading as a live claim forever, wedging the worker",
    ),
    (
        "emubackend/claim.py",
        "        if not alive:",
        "        if False:",
        "test_controls_and_claim.py::test_a_dead_pid_makes_the_lock_stale",
        "a crashed worker's lock blocking every future claim",
    ),
    (
        "emubackend/claim.py",
        "        if wid == self_worker_id:\n            continue",
        "        if False:\n            continue",
        "test_controls_and_claim.py::test_our_own_lock_does_not_block_us",
        "our own lock blocking us, so a resume can never proceed",
    ),
    # ---- harvest-shaped predicates (read drift) ----
    (
        "emubackend/harvest.py",
        "        if count < max(1, int(baseline * collapse_ratio)):",
        "        if False:",
        "test_harvest.py::test_a_near_total_collapse_is_caught_even_though_it_is_non_empty",
        "the P1 shape: 1 source where 40 are expected, which non_empty passes happily",
    ),
    (
        "emubackend/harvest.py",
        "    if count >= 3 and distinct == 1:",
        "    if False:",
        "test_harvest.py::test_identical_items_indicate_one_node_matched_repeatedly",
        "a selector matching one node repeatedly reading as a full harvest",
    ),
    (
        "emubackend/harvest.py",
        "    if not usable:",
        "    if False:",
        "test_harvest.py::test_items_that_are_all_unusable_fail_even_at_a_healthy_count",
        "40 empty strings counting as 40 sources",
    ),
    (
        "emubackend/harvest.py",
        "        history.record(point, 0)\n        return HarvestVerdict(False, \"empty harvest\", 0, baseline)",
        '        return HarvestVerdict(False, "empty harvest", 0, baseline)',
        "test_harvest.py::test_a_failing_harvest_is_still_recorded_so_zero_cannot_become_normal",
        "an all-zero run never establishing a baseline, so zero later looks healthy",
    ),
    (
        "emubackend/harvest.py",
        "        if count < max(1, int(baseline * collapse_ratio)):",
        "        if count <= max(1, int(baseline * collapse_ratio)):",
        "test_harvest.py::test_a_zero_baseline_does_not_trigger_a_collapse_verdict",
        "an off-by-one that makes a zero baseline call a healthy 2-item harvest a collapse",
    ),
    # ---- the P0-P3 run loop ----
    (
        "emubackend/pipeline.py",
        "            if ctx.controls.stopped:",
        "            if False:",
        "test_pipeline.py::test_a_stop_takes_precedence_over_a_queued_phase_skip",
        "a stopped run reporting a phase as SKIPPED — a different, untrue outcome",
    ),
    (
        "emubackend/pipeline.py",
        "            if ctx.controls.is_phase_skip_requested(phase.number):",
        "            if False:",
        "test_pipeline.py::test_a_skipped_phase_emits_phase_skipped_and_no_start_complete_pair",
        "a requested phase skip being ignored and the phase body running anyway",
    ),
    (
        "emubackend/pipeline.py",
        "            if not await ctx.controls.wait_while_paused():",
        "            if False:",
        "test_pipeline.py::test_a_stop_during_a_park_takes_effect_at_the_park",
        "a stop during a long park only landing after the park ends",
    ),
    (
        "emubackend/pipeline.py",
        '    deletes = ["pendingDecision"] if pd.startup_clear_field(queued=queued) else None',
        "    deletes = None",
        "test_pipeline.py::test_a_non_queued_start_wipes_the_decision_slot_in_the_same_patch",
        "a new run visible alongside the previous run's decision card",
    ),
    (
        "emubackend/pipeline.py",
        "    if event_type in _CLEAR_ON and pd.should_clear(ctx.pending, scoped):",
        "    if event_type in _CLEAR_ON:",
        "test_pipeline.py::test_an_agent_scoped_clear_respects_the_keep_guard",
        "the cross-agent clobber: one agent's late clear deleting another's live card",
    ),
    (
        "emubackend/pipeline.py",
        "    scoped = pd.clear_agent_scope(event_type, agent)",
        "    scoped = agent",
        "test_pipeline.py::test_phase_restart_clears_unconditionally_even_with_an_agent",
        "scoping phase_restart by agent, so Retry leaves the card it just resolved on screen",
    ),
    (
        "emubackend/pipeline.py",
        '            emit_event(ctx, "pipeline_complete")',
        "            pass",
        "test_pipeline.py::test_a_full_p0_to_p3_run_emits_the_expected_sequence",
        "a completed run never announcing completion, so the frontend waits forever",
    ),
    (
        "emubackend/pipeline.py",
        "            claim_mod.release_lock(worker_id, lock_dir)",
        "            pass",
        "test_pipeline.py::test_the_lock_is_released_even_when_the_run_fails",
        "a retained lock making the next claim look like a live sibling, wedging the device",
    ),
    # ---- the data-driven browser layer ----
    (
        "emubackend/selectors.py",
        "        if not found.resolvable:",
        "        if False:",
        "test_selectors_and_phases.py::test_require_fails_loudly_on_an_uncaptured_selector",
        "an uncaptured selector silently passing, so a step reports success on an untouched page",
    ),
    (
        "emubackend/selectors.py",
        "            _validate(loaded)",
        "            pass",
        "test_selectors_and_phases.py::test_a_typod_key_is_rejected_rather_than_ignored",
        "a typo'd manifest key sitting in the file doing nothing, with no symptom to trace",
    ),
    (
        "emubackend/phases.py",
        '        if handle is None:\n            raise ManifestError(\n                f"{self.platform}.{key} did not match anything on the page.',
        '        if False:\n            raise ManifestError(\n                f"{self.platform}.{key} did not match anything on the page.',
        "test_selectors_and_phases.py::test_a_selector_that_matches_nothing_names_what_was_tried",
        "a tap on a selector that matched nothing proceeding as if it worked",
    ),
    (
        "emubackend/phases.py",
        "            deps.log.append(f\"p3:{name}:{'ok' if verdict.ok else 'SUSPECT'}:{verdict.count}\")\n"
        "            if not verdict.ok:",
        "            deps.log.append(f\"p3:{name}:{'ok' if verdict.ok else 'SUSPECT'}:{verdict.count}\")\n"
        "            if False:",
        "test_selectors_and_phases.py::test_p3_raises_when_the_harvest_fails_its_predicate",
        "the P1 outcome: a run reporting success having harvested nothing",
    ),
    (
        "emubackend/phases.py",
        # Retargeted when the predicate was ported from the backend: the off-signal no longer reads
        # aria-pressed, but the invariant it guards is unchanged — a control that cannot be FOUND must
        # never read as confirmed-off, or a rotted selector authorises a click that switches a live
        # control off (#709). Dropping the not-found guard is still the way to break it.
        "            handle = await resolve(self.page, entry) if entry.resolvable else None\n            if handle is None:\n                return False\n            return bool((await self._toggle_state(key)).get(\"off\"))",
        "            return bool((await self._toggle_state(key)).get(\"off\"))",
        "test_selectors_and_phases.py::test_the_off_signal_is_positive_not_the_inverse_of_the_predicate",
        "an unfindable toggle reading as confirmed-off, authorising a click that switches a live control OFF (#709)",
    ),
    (
        "emubackend/phases.py",
        "    for css in entry.css:\n        found = await page.query_selector(css)",
        "    for css in reversed(entry.css):\n        found = await page.query_selector(css)",
        "test_selectors_and_phases.py::test_resolve_tries_the_css_chain_in_order",
        "the fallback chain evaluated backwards, so the least specific selector wins",
    ),
    # --- cancelling a pair must not create anything ---------------------------------------------
    (
        "ios/App/PairingFlow.swift",
        "        status = abandoned.isEmpty\n            ? \"Cancelled. Nothing was created.\"",
        "        await beginPairing()\n        status = abandoned.isEmpty\n            ? \"Cancelled. Nothing was created.\"",
        "test_capture_guards.py::test_cancel_does_NOT_mint_another_device_document",
        "cancel requesting a fresh pair code like restart does — the exact behaviour that accumulated "
        "SEVEN devices/* documents in one evening on the owner's project, five of them never claimed",
    ),
    (
        "ios/App/PairingFlow.swift",
        "                if controller.started && controller.stage != .ready {",
        "                if false && controller.started && controller.stage != .ready {",
        "test_capture_guards.py::test_cancel_is_reachable_from_EVERY_stage_via_the_header",
        "no reachable cancel, leaving 'start over with a new code' as the only exit — which is how a "
        "stuck flow turns into another abandoned document instead of ending",
    ),
    (
        "ios/App/PairingFlow.swift",
        "        started = false\n        stage = .pair\n        busy = false",
        "        stage = .pair\n        busy = false",
        "test_capture_guards.py::test_cancel_returns_to_the_LANDING_screen_not_to_stage_one",
        "cancel leaving `started` true, so the user is dropped straight back into the flow they just "
        "cancelled and the button reads as broken",
    ),
    (
        "ios/App/PairingFlow.swift",
        "        Task { await backend.abandonPairing() }\n        pairCode = \"\"",
        "        pairCode = \"\"",
        "test_capture_guards.py::test_cancel_clears_the_local_identity_and_stops_the_heartbeat",
        "cancel forgetting the device only LOCALLY — the heartbeat keeps running, and the "
        "half-made device keeps its synthetic Firebase login, which no TTL sweep can reach",
    ),
    # --- verification needs a render tick -------------------------------------------------------
    (
        "emubackend/intents.py",
        "        if passed or pred_error is not None or time.monotonic() >= deadline:\n            break",
        "        if True:\n            break",
        "test_intents.py::test_a_predicate_that_needs_a_render_tick_still_passes",
        "every wrapped intent verified by a SINGLE evaluation taken before the page had rendered — "
        "measured on live ChatGPT, the deep-research toggle turned on and send was accepted, and both "
        "reported predicate_passed=False. A false negative on a healthy page escalates an agent onto "
        "the one page that needed no help",
    ),
    (
        "emubackend/intents.py",
        "        if passed or pred_error is not None or time.monotonic() >= deadline:",
        "        if passed or time.monotonic() >= deadline:",
        "test_intents.py::test_a_RAISING_predicate_breaks_out_instead_of_burning_the_window",
        "a predicate with a syntax error retried for the whole window on every intent, adding latency "
        "for an outcome that was already decided",
    ),
    (
        "emubackend/intents.py",
        "    registry.record_execution(intent_id)",
        "    [registry.record_execution(intent_id) for _ in range(2)]",
        "test_intents.py::test_the_execution_LEDGER_counts_the_action_once_however_many_polls_it_took",
        "the bake ledger inflated by verification polls, so one slow action could look like a baked "
        "predicate and unlock escalation it never earned",
    ),
    # --- the platform's own in-flight control vetoes completion ---------------------------------
    (
        "emubackend/phases.py",
        "            if handle is not None and not generating:",
        "            if handle is not None:",
        "test_selectors_and_phases.py::test_the_veto_also_overrides_the_decisive_state_attribute",
        "content stability accepted while the platform is STILL GENERATING — live ChatGPT held 'Pro "
        "thinking' (27 chars) for over six seconds with 'Stop answering' on screen, so both accept "
        "signals passed on a page that had not started answering, and the empty harvest was then "
        "reported as read drift about correct selectors",
    ),
    (
        "emubackend/phases.py",
        "            if generating:\n                # The clock restarts: time spent generating is not time spent stable.\n                stable_since = None",
        "            if generating:\n                pass",
        "test_selectors_and_phases.py::test_the_stability_clock_RESTARTS_when_generation_resumes",
        "stable time banked across a generation that interrupted it, so a long run whose placeholder "
        "happens not to change accumulates a stable window while the platform is visibly working",
    ),
    (
        "emubackend/phases.py",
        '    "gemini": (\n        \'button[aria-label*="Stop"], [role="button"][aria-label*="stop" i], \'\n        \'[jsname] [role="progressbar"], [data-is-streaming="true"], \'\n        ".loading-indicator, .streaming"\n    ),',
        '    "gemini": \'button[aria-label*="Stop"]\',',
        "test_selectors_and_phases.py::test_the_in_flight_selectors_are_the_backends_own_per_platform_sets",
        "Gemini's in-flight check narrowed to the stop button alone — its collapsed composer often shows "
        "NO stop button mid-run (#897b), so a live deep-research run reads as finished and the user's "
        "mid-run chat is silently dropped",
    ),
    (
        "emubackend/phases.py",
        "                if text != last_text or stable_since is None:",
        "                if text != last_text:",
        "test_selectors_and_phases.py::test_the_stability_clock_RESTARTS_when_generation_resumes",
        "the stability clock unable to RESTART after generation reset it — settable only by a text "
        "change, so on an unchanging placeholder the wait can never complete and every real run times "
        "out. My own bug, found by asserting WHEN completion happens rather than that it does",
    ),
    (
        "emubackend/phases.py",
        "            elif time.monotonic() - present_since >= settle:\n                return True",
        "            elif True:\n                return True",
        "test_selectors_and_phases.py::test_readiness_requires_the_composer_to_SURVIVE_a_settle_window",
        "readiness satisfied by a single sighting of a composer that is mid-re-mount — measured on real "
        "ChatGPT right after deep research turned on, where type_brief then died with StaleHandleError",
    ),
    (
        "emubackend/phases.py",
        "            except RuntimeError:\n                # StaleHandleError is a RuntimeError; ManifestError is a ValueError, so this cannot\n                # swallow a manifest problem.\n                if attempt == attempts - 1:\n                    raise\n                await self.await_composer_ready()",
        "            except RuntimeError:\n                raise",
        "test_selectors_and_phases.py::test_a_stale_composer_is_RE_QUERIED_rather_than_failing_the_run",
        "a composer replaced between fill's three round trips failing the whole run, when the stale "
        "error's own message says to re-query the selector",
    ),
    (
        "emubackend/phases.py",
        "                if attempt == attempts - 1:\n                    raise",
        "                if False:\n                    raise",
        "test_selectors_and_phases.py::test_the_re_query_is_BOUNDED_not_an_infinite_loop",
        "an unbounded re-query against a composer that keeps vanishing — an infinite loop wearing a fix",
    ),
    # --- the four mechanisms a real platform needs and the mock never did -----------------------
    (
        "emubackend/phases.py",
        "        if handle is None and entry.opener:",
        "        if handle is None and entry.opener and False:",
        "test_selectors_and_phases.py::test_a_control_behind_an_opener_is_reached_by_tapping_the_opener_first",
        "the manifest's `opener` parsed and then DROPPED — the control sits in a closed menu, so P2 on "
        "real ChatGPT raises 'did not match anything' for a selector that is correct",
    ),
    (
        "emubackend/phases.py",
        "            if time.monotonic() >= deadline:\n                return None\n            await asyncio.sleep(0.3)",
        "            return None\n            await asyncio.sleep(0.3)",
        "test_selectors_and_phases.py::test_the_opener_is_POLLED_because_the_menu_renders_in_two_passes",
        "the opened menu read ONCE — ChatGPT paints 3 items then 19, so `Deep research` at index 7 "
        "looks absent and a present control is reported as unsupported on mobile",
    ),
    (
        "emubackend/phases.py",
        "        if opened and not await self._dismiss_opener(entry):",
        "        if False and opened and not await self._dismiss_opener(entry):",
        "test_selectors_and_phases.py::test_a_menu_that_refuses_to_close_FAILS_rather_than_being_assumed_shut",
        "an open menu left covering the send button, so the NEXT phase taps the overlay and the failure "
        "reads as a send problem",
    ),
    (
        "emubackend/phases.py",
        "            state = await self._popup_open(entry.opener)\n            if not state.get(\"open\"):",
        "            state = await self._popup_open(entry.opener)\n            if False:",
        "test_selectors_and_phases.py::test_an_opened_menu_is_closed_and_the_close_is_VERIFIED",
        "the dismissal check never able to observe a CLOSED popup, so every opener-reached control "
        "aborts its phase after correctly doing what it was asked",
    ),
    (
        "emubackend/phases.py",
        "            state = await self._popup_open(entry.opener)\n            if not state.get(\"open\"):\n                return True",
        "            state = {\"open\": await resolve(self.page, entry) is not None}\n            if not state.get(\"open\"):\n                return True",
        "test_selectors_and_phases.py::test_dismissal_asks_the_OPENER_not_whether_the_TARGET_is_still_findable",
        "dismissal asking whether the TARGET is still findable instead of asking the OPENER about its "
        "popup — activating ChatGPT's Deep research leaves a 'Deep research' PILL in the composer, so "
        "the run's own success signal reads as evidence the menu never closed and P2 aborts having done "
        "everything correctly",
    ),
    (
        "emubackend/substrate/backend.py",
        "            elif time.monotonic() - stable_since >= settle:\n                return True",
        "            elif True:\n                return True",
        "test_substrate_runtime_stability.py::test_a_runtime_that_lands_and_is_then_wiped_is_not_stable",
        "the injected runtime accepted as soon as it LANDS — real ChatGPT replaces its own document ~1s "
        "after first paint, so the sentinel is present, the check passes, and the very next read fails "
        "with 'undefined is not an object' from inside calibration",
    ),
    (
        "emubackend/phases.py",
        "                except RuntimeError:\n                    ready = False",
        "                except Exception:\n                    ready = False",
        "test_selectors_and_phases.py::test_a_missing_is_visible_is_a_wiring_bug_not_an_unready_composer",
        "a too-wide catch turning 'this page object is missing a contract method' into 'the composer "
        "never became ready' — a wiring bug wearing a platform symptom",
    ),
    (
        "emubackend/phases.py",
        "                    ready = bool(await handle.is_visible())",
        "                    ready = True",
        "test_selectors_and_phases.py::test_an_invisible_composer_is_not_ready",
        "readiness satisfied by mere DOM presence, so a composer that is still mounting is typed into",
    ),
    (
        "emubackend/phases.py",
        '                    and classify_response(text)["state"] != "empty"',
        "                    and True",
        "test_selectors_and_phases.py::test_an_EMPTY_container_is_never_accepted_however_stable_it_is",
        "an EMPTY container accepted as complete because emptiness is perfectly stable — live ChatGPT "
        "stayed empty for six minutes after a Retry that succeeded as a click",
    ),
    (
        "emubackend/phases.py",
        "                if polls % 10 == 0:",
        "                if polls % 10 == 1000000:",
        "test_selectors_and_phases.py::test_the_wait_raises_on_a_platform_error_instead_of_waiting_it_out",
        "the mid-wait error check never running, so 'Failed to fetch template' is waited out for the "
        "full timeout and the reason is lost",
    ),
    (
        "emubackend/phases.py",
        "            waited = await driver.await_response(timeout=response_timeout)",
        "            waited = {\"done\": True, \"reason\": \"skipped\"}",
        "test_selectors_and_phases.py::test_p3_waits_before_harvesting",
        "P3 harvesting the instant P2's send returns — fine on a mock that answers in under a second, "
        "and on a real deep-research run it harvests nothing and reports it as read drift",
    ),
    (
        "emubackend/phases.py",
        '                deps.log.append(f"p2:{name}:standard-mode:no-deep-research-on-this-surface")\n'
        "            if not await driver.await_composer_ready():",
        '                deps.log.append(f"p2:{name}:standard-mode:no-deep-research-on-this-surface")\n'
        "            if False:",
        "test_selectors_and_phases.py::test_p2_re_establishes_composer_readiness_after_enabling_deep_research",
        "readiness treated as a one-time fact — enabling deep research NAVIGATES on ChatGPT, so the "
        "pre-navigation composer is dead and typing into it succeeds silently and sends nothing",
    ),

    # --- A8 over an ALREADY-DIRTY guarded repo --------------------------------------------------
    (
        "emubackend/purity.py",
        "            if rel not in cur.dirty_digests:",
        "            if False:",
        "test_a8_purity.py::test_compare_detects_a_DISCARDED_uncommitted_change",
        "a discarded uncommitted change going unreported — the porcelain entry vanishes and a "
        "current-minus-baseline set difference cannot see a removal, so the one thing handoff "
        "rule 1 forbids was the one thing the guard could not detect",
    ),
    (
        "emubackend/purity.py",
        "            elif cur.dirty_digests[rel] != base_digest:",
        "            elif False:",
        "test_a8_purity.py::test_compare_detects_an_edit_to_an_ALREADY_modified_file",
        "editing a file that the baseline already records as modified — git status is "
        "byte-identical either way, so nothing but the content digest can notice",
    ),
    (
        "emubackend/purity.py",
        "            dirty_digests=_dirty_digests(repo, dirty_paths),",
        "            dirty_digests={},",
        "test_a8_purity.py::test_capture_really_digests_dirty_paths",
        "the digests never being collected at all, which leaves both compare branches "
        "permanently inert while every compare test still passes on hand-built states",
    ),
    (
        "emubackend/purity.py",
        '        path = path.split(" -> ", 1)[1]',
        '        path = path.split(" -> ", 1)[0]',
        "test_a8_purity.py::test_porcelain_path_handles_renames_and_plain_entries",
        "digesting a rename's OLD path, which no longer exists — every renamed file would "
        "record as absent and then read as discarded on the next check",
    ),
    (
        "emubackend/purity.py",
        '        if not rel or rel.split("/", 1)[0] in _VOLATILE:',
        "        if not rel:",
        "test_a8_purity.py::test_volatile_dirs_are_not_digested",
        "digesting queues/, which the production daemon writes on every real run — the guard "
        "would go red for reasons unrelated to us, and a guard that cries wolf gets switched off",
    ),

    # --- workers are browser profiles (the multi-worker build) -----------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        # ⚠ Both branches, deliberately. Flipping only the first comparison LOOKED like the union
        # bug and was recorded MISSED: with worker-1 true and worker-2 false, `contains(true)` is
        # also true, so the mutant still wrote `false` and the test could not tell them apart. The
        # union is a two-branch change, and only mutating both actually simulates it.
        "            if values.contains(where: { $0 == false }) {\n"
        "                out[platform] = false\n"
        "            } else if values.allSatisfy({ $0 == true }) {\n"
        "                out[platform] = true\n"
        "            }",
        "            if values.contains(where: { $0 == true }) {\n"
        "                out[platform] = true\n"
        "            } else if values.allSatisfy({ $0 == false }) {\n"
        "                out[platform] = false\n"
        "            }",
        "swift:WorkerProfileTests/testAPlatformSignedInOnOnlyOneOfTwoWorkersIsReportedSignedOut",
        "reporting device logins as the UNION, so the device advertises itself ready for a run the "
        "backend hands to a worker with no cookie — surfacing phases later as a login wall",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        "            } else if values.allSatisfy({ $0 == true }) {",
        "            } else if values.allSatisfy({ $0 != false }) {",
        "swift:WorkerProfileTests/"
        "testAPlatformNotYetCheckedOnOneWorkerIsOmittedRatherThanCalledSignedOut",
        "treating never-measured as signed-in, so an unchecked worker reads as ready",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        # ⚠ On the LOAD path, not the create path. The first attempt mutated the fresh-registry
        # branch and was recorded MISSED, because a relaunch test never reaches it — the data is
        # there, so it decodes. The defect worth simulating is the identity being regenerated on
        # the way back IN, which is what actually points WebKit at a different jar.
        "            workers = decoded.sorted { $0.id < $1.id }",
        "            workers = decoded.sorted { $0.id < $1.id }"
        ".map { WorkerProfile(id: $0.id, storeID: UUID(), logins: $0.logins) }",
        "swift:WorkerProfileTests/testAWorkerKeepsItsCookieJarAcrossRelaunch",
        "a store identifier regenerated on load, pointing WebKit at a different jar on disk — every "
        "platform login silently lost with nothing in any log to explain it",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        "        guard let data = try? JSONEncoder().encode(workers) else { return }\n"
        "        storage.saveWorkers(data)",
        "        guard (try? JSONEncoder().encode(workers)) != nil else { return }",
        "swift:WorkerProfileTests/testMeasuredLoginsSurviveARelaunch",
        "a registry that never writes back, so every added worker and every measured login is lost "
        "on the next launch while the running app looks entirely correct",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        "        if busyWorkerIDs.contains(last.id) { return .busy(id: last.id) }",
        "        if busyWorkerIDs.contains(last.id + 1000) { return .busy(id: last.id) }",
        "swift:WorkerProfileTests/testABusyWorkerIsNotRemoved",
        "removing a worker that is mid-run, orphaning the run the backend assigned to it",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        "        if id != highest { return .notTheLastWorker(highest: highest) }",
        "        if id > highest { return .notTheLastWorker(highest: highest) }",
        "swift:WorkerProfileTests/testRemovingFromTheMiddleIsRefusedSoOrdinalsAreNeverRenumbered",
        "allowing a middle removal, which renumbers ordinals and hands a running worker a different "
        "id from the one its run was assigned to",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WorkerProfiles.swift",
        "        let next = WorkerProfile(id: workers.count + 1, storeID: makeID())",
        "        let next = WorkerProfile(id: workers.count + 2, storeID: makeID())",
        "swift:WorkerProfileTests/testAddingWorkersProducesContiguousOneBasedIDs",
        "non-contiguous worker ids, which breaks the backend's 1...workerCount padding",
    ),

    # ⚠ The ios/App boundary guard is NOT mutated here. It is a scanner, so the only mutation that
    # matters is a positive one — see `probe_app_layer_boundary`. Weakening its allow-list would make
    # it pass harder, not fail, and would have been recorded as CAUGHT while proving nothing.

    # --- the app wave: unpair, session survival, autostart, names ---------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            let action = try await pairing.unpairSelf(deviceId: deviceID)",
        "            let action = \"retired\"; try await pairing.patchDevice(\n"
        "                deviceId: deviceID, set: [\"status\": \"retired\"], delete: [])",
        "swift:DeviceBackendBehaviourTests/testUnpairCallsTheServerRouteRatherThanWritingAStatusField",
        "the old unpair: writing status:retired, which NO frontend code reads, so the device stayed "
        "on the Account page forever while the app reported 'Unpaired'",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            startHeartbeat()\n"
        "            return OpResult(\n"
        "                ok: false,\n"
        "                message: \"Unpair failed, so this device is still paired: \\(error)\"\n"
        "            )",
        "            clearLocalIdentity()\n"
        "            return OpResult(\n"
        "                ok: false,\n"
        "                message: \"Unpair failed, so this device is still paired: \\(error)\"\n"
        "            )",
        "swift:DeviceBackendBehaviourTests/testAFailedUnpairKeepsTheIdentitySoItCanBeRetried",
        "clearing the local identity after a FAILED unpair, stranding a device that still exists "
        "server-side and can never be removed — the credential authorising removal is gone",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            do {\n"
        "                if try await self.pairing.readDocument(path: \"devices/\\(id)\") == nil {",
        "            do {\n"
        "                if (try? await self.pairing.readDocument(path: \"devices/\\(id)\")) == nil {",
        "swift:DeviceBackendBehaviourTests/testAThrownReadKeepsTheIdentityBecauseOfflineIsNotUnpaired",
        "the `try?` that flattened 'offline / not signed in' into 'the document is gone', so a "
        "dropped connection at launch unpaired the device permanently",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            guard Self.storedSupervised else {",
        "            guard true else {",
        "swift:DeviceBackendBehaviourTests/testAutostartOffMeansTheDeviceDoesNotComeOnlineByItself",
        "the heartbeat starting unconditionally, which made the On Startup toggle decorative — the "
        "device came online whether or not it had been asked to",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        try? await coordinator.heartbeat(deviceId: deviceID, workerCount: workers.count)",
        "        try? await coordinator.heartbeat(deviceId: deviceID, workerCount: 1)",
        "swift:DeviceBackendBehaviourTests/testTheHeartbeatReportsTheRealWorkerCount",
        "the hardcoded workerCount: 1, so the frontend sized the capacity UI off a constant and "
        "handed a multi-worker device one run at a time",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            if await !self.pairing.hasSession(), let token = self.store.refreshToken {\n"
        "                await self.pairing.restoreSession(refreshToken: token)\n"
        "            }",
        "            if false, let token = self.store.refreshToken {\n"
        "                await self.pairing.restoreSession(refreshToken: token)\n"
        "            }",
        "swift:DeviceBackendBehaviourTests/testResumeReArmsTheSessionBeforeProbingTheDocument",
        "never re-arming the session on launch, so a relaunched app holds an identity it cannot "
        "authenticate and can neither heartbeat nor unpair",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            if let label = name ?? email {",
        "            if let label = email ?? name {",
        "swift:PeopleResolutionTests/testTheOwnerIsNamedFromOwnerDisplayNameWithNoFrontendChange",
        "preferring the email over the display name, so People shows addresses where the web app "
        "shows names",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            case .string(let text):\n"
        "                return Int(text) ?? Int(text.replacingOccurrences(of: \"worker-\", with: \"\"))",
        "            case .string: return nil",
        "swift:PeopleResolutionTests/testBusyWorkerIDsParseBothIntegerAndStringForms",
        "parsing only one of the two busyWorkerIds shapes, yielding an EMPTY busy set — which is "
        "what lets Remove worker delete a worker mid-run",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/Operations.swift",
        "        guard let requiresSupervised, requiresSupervised != supervised else { return nil }",
        "        guard let requiresSupervised, requiresSupervised == supervised else { return nil }",
        "swift:OperationsCatalogueTests/testDaemonLoopIsUsableOnlyWhenAutostartIsOn",
        "inverting the supervision gate, so Daemon loop is offered exactly when it cannot work and "
        "Start serving exactly when it is pointless",
    ),

    # --- gate zero must measure the surface it was asked for ------------------------------------
    (
        "bin/gate_zero_probe.py",
        "        if is_app == (surface == \"app\"):",
        "        if is_app or (surface == \"app\"):",
        "test_gate_zero_surface.py::test_app_surface_REFUSES_when_only_safari_pages_are_present",
        "the page pick falling back to whatever it found, so gate zero measures Simulator Safari's "
        "SIGNED-OUT ChatGPT and reports 'no report node' — sending the reader after cross-origin "
        "frames, the one branch that costs architecture",
    ),
    (
        "bin/gate_zero_probe.py",
        "        is_app = APP_UA_TOKEN in (ua or \"\")",
        "        is_app = True",
        "test_gate_zero_surface.py::test_a_missing_user_agent_is_not_treated_as_the_app",
        "treating any page as the app's, which is the URL-substring pick this replaced — both "
        "surfaces serve https://chatgpt.com/ and only one is signed in",
    ),
    (
        "bin/gate_zero_probe.py",
        "    if surface not in (\"app\", \"safari\"):\n        raise ValueError(f\"unknown surface {surface!r}\")",
        "    if False:\n        raise ValueError(f\"unknown surface {surface!r}\")",
        "test_gate_zero_surface.py::test_an_unknown_surface_name_is_rejected_rather_than_silently_meaning_safari",
        "a typo'd surface name silently meaning 'not the app', so --surface App measures Safari",
    ),
    (
        "bin/gate_zero_probe.py",
        # Anchored with the line above it: PROBE_COMPLETION carries the same exclusion list, and the
        # harness correctly refused the ambiguous anchor.
        "(() => { let best = {chars: 0};\n  const skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1 };",
        "(() => { let best = {chars: 0};\n  const skip = { STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1 };",
        "test_gate_zero_surface.py::test_probe_4_ignores_a_script_and_picks_the_rendered_node",
        "reading a <script> body as the longest text on the page — MEASURED at 434,403 chars "
        "against 881 rendered — so the gate announces 'the report is in the main document, no "
        "frame work' for a page whose report is in a cross-origin frame",
    ),
    (
        "bin/gate_zero_probe.py",
        "    if signals.get(\"stopControlPresent\"):",
        "    if False:",
        "test_gate_zero_surface.py::TestCompletionVerdict::test_a_visible_stop_control_is_in_flight",
        "probing a page that is still generating — the exact 2026-07-30 mis-measurement the gate exists to prevent",
    ),
    (
        "bin/gate_zero_probe.py",
        "    if dr_frames:\n        return \"unknown\", (",
        "    if False:\n        return \"unknown\", (",
        "test_gate_zero_surface.py::TestCompletionVerdict::test_a_deep_research_frame_with_a_thin_main_document_REFUSES",
        "treating 'no stop control' as completion on a Deep Research page, where that control never "
        "appears at all — a guard that cannot fire, passing a mid-research page as finished",
    ),
    (
        "bin/gate_zero_probe.py",
        "    if rendered >= REPORT_FLOOR_CHARS:",
        "    if rendered >= 0:",
        "test_gate_zero_surface.py::TestCompletionVerdict::test_one_char_under_the_floor_is_NOT_complete",
        "an advisory floor — any page at all reads as a completed report",
    ),

    # --- run intake: the claim is the half that corrupts data if it is wrong --------------------
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        "        if let ifUpdateTime {\n            query.append(URLQueryItem(name: \"currentDocument.updateTime\", value: ifUpdateTime))\n        }",
        "        if false, let ifUpdateTime {\n            query.append(URLQueryItem(name: \"currentDocument.updateTime\", value: ifUpdateTime))\n        }",
        "swift:RunQueueTests/testTheClaimSendsAnUpdateTimePreconditionOnTheWire",
        "a claim written with NO precondition — which is not a weaker claim but no claim at all: a "
        "Mac backend and this phone paired to one account both run the same research",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        "    guard status == 400 || status == 409 else { return false }",
        "    guard status == 409 else { return false }",
        "swift:RunQueueTests/testALostPreconditionSurfacesAsItsOwnCaseAndNotAsAGenericHTTPError",
        "reading a lost precondition as a generic HTTP error — Firestore reports it as 400, not "
        "409, so the caller's transient-retry policy RETRIES it and a clean race-loss becomes a "
        "stolen run",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        "                    where ifUpdateTime != nil && isFailedPrecondition(status: status, body: body) {",
        "                    where isFailedPrecondition(status: status, body: body) {",
        "swift:RunQueueTests/testAPlain400WithoutAPreconditionRequestStaysAGenericHTTPError",
        "reporting a rules-evaluation failure as a lost race the caller never entered — and the "
        "caller's response to a lost race is to move on quietly",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        guard let updateTime = entry.updateTime else {",
        "        guard let updateTime = entry.updateTime ?? \"\" as String? else {",
        "swift:RunIntakeTests/testADocumentWithNoUpdateTimeIsNEVERClaimED",
        "claiming a document whose version is unknown — a blind claim races every sibling",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        # ⚠ The mutant DROPS the `return nil`, so the catch falls through to the code after the
        # do/catch and the run proceeds as though the claim had succeeded. It used to delete the bare
        # `return` of a Void function; `claimAndRun` returns the claimed worker id now, and deleting
        # `return` alone left a dangling `nil` that does not compile — a mutant that cannot build is
        # scored as neither caught nor missed, and it aborted the whole harness before every entry
        # after it had run.
        "            NSLog(\"[SR] queue: %@ was claimed by a sibling first — standing down\", entry.id)\n            return nil",
        "            NSLog(\"[SR] queue: %@ was claimed by a sibling first — standing down\", entry.id)",
        "swift:RunIntakeTests/testALOSTRaceStandsDownQuietlyAndDoesNotRunTheResearch",
        "running the research after LOSING the claim — two backends on one run, both writing the "
        "same documents",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        let path = \"devices/\\(deviceID)/queue\"",
        "        let path = \"devices/\\(deviceID)/commands\"",
        "swift:RunIntakeTests/testTheQueueIsPolledANDItIsNotTheCommandsCollection",
        "polling the device-OPERATIONS collection instead of the research lifecycle one — the exact "
        "confusion that makes a reviewer read intake as already done",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "                return (Set(1...max(workers.count, 1)), [])\n            }\n            // \u26d4 UNIONED",
        "                return ([], [])\n            }\n            // \u26d4 UNIONED",
        "swift:RunIntakeTests/testAMISSINGDeviceDocumentAlsoPlacesNothing",
        "assuming every worker is free when the device doc is MISSING (a 404 returns nil rather "
        "than throwing), so a busy device claims work it cannot run",
    ),
    (
        # The catch branch, which is a DIFFERENT guard from the nil branch above and shares its
        # expression. A mutation aimed at one and a test exercising the other reported CAUGHT while
        # the branch under test was never touched.
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        } catch {\n            return (Set(1...max(workers.count, 1)), [])\n        }",
        "        } catch {\n            return ([], [])\n        }",
        "swift:RunIntakeTests/testAFailedDeviceReadPLACESNOTHINGRatherThanAssumingWorkersAreFree",
        "assuming every worker is free when the device doc read THROWS (offline, token blip), so a "
        "busy device claims work it cannot run",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        } catch {\n            return true\n        }\n    }",
        "        } catch {\n            return false\n        }\n    }",
        "swift:RunIntakeTests/testAnAbandonedStartIsKEPTWhenTheHealthReadFAILS",
        "deleting a parked run because a health read blipped — destroying the only claim ticket the "
        "run the owner is waiting on has",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        if entry.action == .cancel { return .claim }",
        "        if false { return .claim }",
        "swift:RunQueueTests/testAnOldCANCELIsNEVERSwept",
        "sweeping a stale cancel — a terminal SIGNAL, not queued work — so the owner's Stop is "
        "dropped with no feedback anywhere",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "            return nowMillis - claimedAt > zombieGraceMillis ? .sweepZombie : .waitOutGrace",
        "            return nowMillis - claimedAt >= zombieGraceMillis ? .sweepZombie : .waitOutGrace",
        "swift:RunQueueTests/testTheGraceBoundaryIsNotOffByOne",
        "an off-by-one on the zombie grace, deleting a sibling's claim at the instant it becomes "
        "eligible rather than after",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        if workerIsResting { return .claim }",
        "        if false { return .claim }",
        "swift:RunQueueTests/testNothingIsSweptWhileTheWorkerIsRESTING",
        "sweeping parked work while the worker rests — parking a run over a weekend is the feature",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "        return (1...count).first { !busy.contains($0) && !resting.contains($0) }",
        "        return (1...count).first { !busy.contains($0) }",
        "swift:RunQueueTests/testARestingWorkerIsNotHandedARun",
        "handing a run to a RESTING worker, silently overriding the owner's explicit 'not now'",
    ),

    # --- the run's far end: P3 done here, P4/P5 in the cloud -----------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunHandoff.swift",
        "                set: [\"beDone\": .boolean(true), \"beDoneAt\": .integer(now)]",
        "                set: [\"beDoneAt\": .integer(now)]",
        "swift:RunHandoffTests/testAllThreeStepsHappenInTheDesktopsOrder",
        "omitting beDone, so the queue gate never learns this backend handed off — stalling the "
        "owner's NEXT run, not just this one",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunHandoff.swift",
        "        var beDone = false\n        var marker = false\n\n        do {",
        "        var beDone = false\n        var marker = false\n        await transport.postUploadYouTube(researchId: researchId, ownerUid: uid)\n\n        do {",
        "swift:RunHandoffTests/testTheMarkerIsWrittenBEFORETheTriggerFires",
        "firing the cloud trigger BEFORE its own backstop marker, so a failed POST leaves the run "
        "dead silently with the audio already paid for",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunHandoff.swift",
        "                  String(describing: error))\n        }\n\n        do {",
        "                  String(describing: error))\n            return HandoffOutcome(beDoneWritten: false, markerWritten: false, triggerFired: false)\n        }\n\n        do {",
        "swift:RunHandoffTests/testAFailedBeDoneStillWritesTheMarkerAndFiresTheTrigger",
        "treating the three recoveries as a transaction, so one failed stall-prevention write turns "
        "a degraded run into a dead one",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunHandoff.swift",
        "                set: [\"needsFeTrigger\": .boolean(true), \"needsFeTriggerAt\": .integer(now)]",
        "                set: [\"needsFeTrigger\": .boolean(true), \"needsFeTriggerAt\": .integer(now), \"status\": .string(\"completed\")]",
        "swift:RunHandoffTests/testStatusIsNEVERWrittenAsCompleted",
        "the phone flipping status itself, reporting a run finished that has no video and no email "
        "— status belongs to the cloud P5 chain",
    ),

    # --- the verdict must rank frames by evidence, not by branch order -------------------------
    (
        "bin/gate_zero_probe.py",
        "        if (frame.get(\"w\") or 0) < 50 or (frame.get(\"h\") or 0) < 50:\n            return False",
        "        if False:\n            return False",
        "test_gate_zero_surface.py::TestVerdictRanking::test_a_tiny_cross_origin_tracker_is_not_reported_as_the_report_container",
        "ChatGPT's 0x0 same-origin sentinel frame outranking the 402x484 cross-origin one the report "
        "is in — MEASURED: the gate said 'H3, traverse contentDocument, JS-only' for a report no "
        "contentDocument traversal can reach",
    ),
    (
        "bin/gate_zero_probe.py",
        "            return int(digits or 0) >= REPORT_FLOOR_CHARS",
        "            return True",
        "test_gate_zero_surface.py::TestVerdictRanking::test_a_LARGE_but_EMPTY_same_origin_frame_is_not_a_report_container",
        "an EMPTY same-origin frame counting as a report container, which is the same wrong verdict "
        "by the other route",
    ),
    (
        "bin/gate_zero_probe.py",
        "    elif cross:\n        # ⚠ Cross-origin is tested BEFORE same-origin.",
        "    elif False:\n        # ⚠ Cross-origin is tested BEFORE same-origin.",
        "test_gate_zero_surface.py::TestVerdictRanking::test_an_empty_same_origin_frame_does_not_outrank_the_cross_origin_one",
        "restoring the original branch ORDER, so whichever frame kind is listed first decides the "
        "architecture",
    ),

    # --- the P2 product: extracting the Deep Research report ------------------------------------
    (
        "emubackend/report_extract.py",
        "    if (!best || cand.chars > best.chars) best = cand;",
        "    best = cand;",
        "test_report_extract.py::TestThePickIsAChoiceNotAnAccident::test_the_LONGEST_report_wins_not_the_last_one_walked",
        "picking whichever widget the object-key walk happened to reach last — a superseded plan "
        "revision or an earlier research turn silently becomes the report",
    ),
    (
        "emubackend/report_extract.py",
        # Anchored WITHOUT the newline escape: the JS source carries doubled backslashes and
        # re-escaping them through this file is a reliable way to write an anchor that matches
        # nothing (the harness caught it as ANCHOR MISS rather than as a false CAUGHT).
        "if (typeof parts[i] === 'string') text +=",
        "if (true) text +=",
        "test_report_extract.py::TestThePickIsAChoiceNotAnAccident::test_non_string_parts_do_not_become_the_report",
        "stringifying a non-text part into the report, so '[object Object]' ships as research",
    ),
    (
        "emubackend/report_extract.py",
        "      if (!tok) throw new Error('session carried no accessToken');",
        "      if (false) throw new Error('session carried no accessToken');",
        "test_report_extract.py::TestTheFetchScript::test_a_missing_access_token_FAILS_rather_than_requesting_without_one",
        "requesting the conversation with no token — MEASURED to answer 404 'Log in to view this "
        "conversation', which reads as 'the conversation is gone' rather than 'we lost the session'",
    ),
    (
        "emubackend/report_extract.py",
        "(typeof raw === 'string') ? JSON.parse(raw) : raw",
        "JSON.parse(raw)",
        "test_report_extract.py::TestThePickIsAChoiceNotAnAccident::test_a_widget_state_that_is_already_an_object_is_read_too",
        "assuming widget_state is always a JSON string — one platform change from an extractor that "
        "silently finds nothing at all",
    ),
    (
        "emubackend/report_extract.py",
        "    if status is not None and status != \"completed\":",
        "    if False:",
        "test_report_extract.py::TestJudgeReport::test_an_UNFINISHED_run_is_rejected_even_with_plenty_of_text",
        "accepting a partially rendered run as the finished report — the most dangerous input there "
        "is, because it looks exactly like a report",
    ),
    (
        "emubackend/report_extract.py",
        "    if len(text) < REPORT_FLOOR_CHARS:",
        "    if len(text) < 0:",
        "test_report_extract.py::TestJudgeReport::test_a_short_report_is_rejected_at_the_floor",
        "an advisory tier floor, so a stub or an error banner passes as the document",
    ),
    (
        "emubackend/report_extract.py",
        "    if is_sources_not_document(text):",
        "    if False:",
        "test_report_extract.py::TestJudgeReport::test_a_finished_run_whose_text_is_a_checklist_is_STILL_rejected",
        "letting status=='completed' smuggle the SOURCES checklist through as the research document",
    ),
    (
        # NOTE: the STRONG-DOC override is deliberately NOT mutated. Every rejection below it
        # requires `headings < 2` and it requires `headings >= 2`, so no input can reach a negative
        # it would have to rescue — no mutation of it can be caught, and that is a fact about the
        # code, not a gap in the tests. It is documented as redundant in the source.
        "emubackend/report_extract.py",
        "    if chat_chrome >= 2:\n        return True",
        "    if False:\n        return True",
        "test_report_extract.py::TestTheGuards::test_a_recorded_CONVERSATION_is_rejected_however_much_prose_it_has",
        "a recorded CONVERSATION shipping as the research document — it has prose and headings, so "
        "every structural check passes it, and it looks more convincing the longer it gets",
    ),
    (
        "emubackend/report_extract.py",
        "    if sum(1 for ln in text.split(\"\\n\") if len(ln.strip()) > 100) >= 3:\n        return False",
        "    if False:\n        return False",
        "test_report_extract.py::TestTheGuards::test_PROSE_alone_stops_a_report_about_chat_products_being_read_as_nav",
        "a report ABOUT chat products being discarded as navigation chrome because it names them",
    ),
    (
        "emubackend/report_extract.py",
        "    return len(text) < 8000",
        "    return True",
        "test_report_extract.py::TestTheGuards::test_LENGTH_alone_stops_a_long_listing_being_read_as_nav",
        "dropping the length bound from the nav guard, so any long document mentioning three nav "
        "words is thrown away",
    ),

    # --- the in-app half of the extractor -------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/ReportExtract.swift",
        "        guard text.count == last.chars else {",
        "        guard text.count >= 0 else {",
        "swift:ReportExtractTests/testATRUNCATEDReadIsAnErrorAndNotAShortReport",
        "returning a TRUNCATED report as the research document — still markdown, still over the "
        "floor, still passes every guard, and missing its conclusions",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ReportExtract.swift",
        'chars: (dict["chars"] as? Int) ?? Int((dict["chars"] as? Double) ?? 0),',
        'chars: (dict["chars"] as? Int) ?? 0,',
        "swift:ReportExtractTests/testCharsSurvivesArrivingAsADouble",
        "reading a JSON number that crossed the bridge as Double as ZERO length, which presents as "
        "'the report is empty' rather than as a decode problem",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ReportExtract.swift",
        'public var isTerminal: Bool { state != "pending" && state != "missing" }',
        'public var isTerminal: Bool { state != "pending" }',
        "swift:ReportExtractTests/testAnUnreadablePollIsNotTreatedAsCompletion",
        "treating an UNREADABLE poll answer as a settled outcome, so the poller stops waiting on a "
        "run that is still going",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ReportExtractJS.swift",
        # A unique fragment: `report_message` itself appears twice in the generated file.
        "var rm = ws && ws.report_message;",
        "var rm = ws && ws.reportMessage;",
        "swift:ReportExtractParityTests/testTheGeneratedScriptIsCurrentWithThePythonSource",
        "the generated Swift copy of the extractor drifting from the Python source — presenting as "
        "'extraction works on Safari and returns nothing in the app'",
    ),

    # --- run control: the channel the web app's Stop button actually writes to ------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        'let path = "users/\\(active.uid)/researches/\\(active.researchID)/commands"',
        'let path = "devices/\\(active.uid)/commands"',
        "swift:RunControlTests/testTheRunsOwnCommandCollectionIsPolled",
        "polling the device-operations collection for run control, so Stop / Pause / Resume are "
        "written by the web app and read by nobody — a run the owner cannot stop",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunControl.swift",
        "        if isFirstPoll, entry.timestampMillis > 0,",
        "        if entry.timestampMillis > 0,",
        "swift:RunControlTests/testAnOldLOOKINGLIVECommandSTILLEXECUTES",
        "applying the staleness gate to LIVE commands, so browser clock skew silently discards the "
        "owner's clicks and leaves a run stuck on pause after they pressed Resume",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunControl.swift",
        "           nowMillis - entry.timestampMillis > staleMillis {\n            return .skipStale",
        "           nowMillis - entry.timestampMillis > -1 {\n            return .skipStale",
        "swift:RunControlTests/testAFreshStopREACHESTheRun",
        "acking every command as stale, so Stop reaches the run only by accident",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunControl.swift",
        '        if let decisionID, !decisionID.isEmpty { return "decision:\\(decisionID)" }',
        '        if false, let decisionID { return "decision:\\(decisionID)" }',
        "swift:RunControlTests/testADecisionIsAnsweredOnceEvenWhenTheNonceDiffers",
        "keying dedupe on the per-click nonce instead of the decision id, so two clicks on one "
        "alert card execute the decision twice",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunControl.swift",
        "        if seen.count > limit { seen.removeFirst(seen.count - limit) }",
        "        if seen.count > limit { seen.removeLast(seen.count - limit) }",
        "swift:RunControlTests/testTheSeenSetIsBOUNDED",
        "evicting the NEWEST remembered commands instead of the oldest, so the most recent command "
        "is forgotten immediately and re-executes on the next poll",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "                await ack(path: path, id: entry.id, staleSkipped: false)\n                switch entry.command {",
        "                switch entry.command {",
        "swift:RunControlTests/testACommandIsAckedBEFOREItRuns",
        "running a terminal command before acking it — stop tears down this very loop, so a crash "
        "mid-handler leaves a command that re-executes on every poll for the life of the run",
    ),

    # --- item 18 + the documents writer: the run's product ---------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/ContractEmitter.swift",
        # REMOVES the field rather than adding one — my first version added a decoy and the test
        # passed, because the real field was still there. A mutation must break the guard.
        '            // A 403 that names nothing, on the write that starts the run.\n            "deviceId": .string(deviceId),',
        '            // A 403 that names nothing, on the write that starts the run.',
        "swift:DocumentWriterTests/testTheRUNSTARTPatchCarriesTheDeviceId",
        "the research-doc patch losing its deviceId, which the rules require on every device write "
        "— a 403 that names nothing, on the write that STARTS the run",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ContractEmitter.swift",
        '            "status": .string(status), "deviceId": .string(deviceId),',
        '            "status": .string(status),',
        "swift:DocumentWriterTests/testTheRUNFINISHPatchCarriesItTOO",
        "the FINISH patch losing its deviceId, so the run works right up to the moment it tries to "
        "say it finished, and then cannot",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ContractEmitter.swift",
        "        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {",
        "        guard true else {",
        "swift:DocumentWriterTests/testAnEMPTYDocumentIsREFUSEDRatherThanWritten",
        "writing an EMPTY research document, which earns a 'Read report' button that opens an empty "
        "modal — a run that looks finished and delivered nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ContractEmitter.swift",
        '        let path = "\\(researchPath)/documents/\\(docType.rawValue)"',
        '        let path = "\\(researchPath)/documents"',
        "swift:DocumentWriterTests/testEachDocTypeWritesToItsOwnPath",
        "every document overwriting one path, so the five doc types collapse into whichever was "
        "written last",
    ),
    # --- P1 produces a brief; P2 consumes it ----------------------------------------------------
    (
        "emubackend/phases.py",
        "        await driver.type_brief(prompts.brief_prompt(deps.topic, deps.feedback))",
        "        await driver.type_brief(deps.topic)",
        "test_selectors_and_phases.py::test_all_four_phases_run_against_a_synthetic_manifest",
        "P1 sending the bare topic instead of the brief WRAPPER — the platform answers with a chat "
        "reply, and P2 is then fed a conversation instead of a research brief",
    ),
    (
        "emubackend/phases.py",
        "            await driver.type_brief(deps.brief)",
        "            await driver.type_brief(deps.topic)",
        "test_selectors_and_phases.py::test_p2_re_establishes_composer_readiness_after_enabling_deep_research",
        "P2 re-asking the TOPIC instead of sending P1's brief — three deep-research units spent on "
        "three independent answers to the same question rather than one researched brief",
    ),
    (
        "emubackend/phases.py",
        "        if not brief or len(brief) < _BRIEF_FLOOR_CHARS:",
        "        if False:",
        # Pointed at the SHORT-response test: with the pipeline fixture answering at full brief
        # length, deleting the floor changes nothing there and the mutation reported CAUGHT while
        # the floor was never consulted.
        "test_p2_guard.py::test_p1_REFUSES_a_stub_response_as_the_brief",
        "accepting a stub as the brief — the measured shape is a 15-character 'ChatGPT said:' from "
        "an unfinished response, which would then be sent to three deep-research agents",
    ),
    (
        "emubackend/phases.py",
        "        if not deps.brief:\n            raise ManifestError(",
        "        if False:\n            raise ManifestError(",
        "test_p2_guard.py::test_p2_refuses_to_run_without_a_brief",
        "P2 running with no brief at all, silently falling through to whatever the composer holds",
    ),
    (
        "emubackend/prompts.py",
        "    if not topic or not topic.strip():",
        "    if False:",
        "test_p1_brief_contract.py::TestTheWrapperPrompt"
        "::test_an_empty_topic_is_REFUSED_rather_than_sent_as_a_bare_wrapper",
        "sending the wrapper with an empty topic, which reads as a coherent request and gets a "
        "plausible answer to nothing",
    ),
    (
        "emubackend/prompts.py",
        "    return RESPONSE_TIMEOUT_SECONDS.get(phase, RESPONSE_TIMEOUT_SECONDS[1])",
        "    return RESPONSE_TIMEOUT_SECONDS.get(phase, RESPONSE_TIMEOUT_SECONDS[2])",
        "test_p1_brief_contract.py::TestTheTimeoutIsKeyedOnThePhase::test_an_unknown_phase_gets_P1s_timeout_and_never_P2s",
        "an uncharacterised phase inheriting P2's forty-minute wait, so a broken step hangs the run "
        "instead of failing it",
    ),
    (
        "emubackend/prompts.py",
        "    2: 2_400.0,   # a deep-research report, 40 minutes",
        "    2: 240.0,   # a deep-research report, 40 minutes",
        "test_p1_brief_contract.py::TestTheTimeoutIsKeyedOnThePhase::test_p2_allows_far_longer_than_the_240s_that_produced_the_bad_read",
        "restoring the 240s default that expired mid-research and let the harvest read 'Pro "
        "thinking' — 27 characters — as the report",
    ),

    # --- P2 sequential, and the consolidated document -------------------------------------------
    (
        "emubackend/phases.py",
        "            waited = await driver.await_response(timeout=_phase_timeout(2))\n            deps.log.append(f\"p2:{name}:waited:{(waited or {}).get('reason', 'done')}\")",
        "            pass",
        "test_p2_sequential.py::TestSequentialExecution::test_each_platform_is_CARRIED_TO_COMPLETION_before_the_next_is_started",
        "dispatching the next platform before this one finished — two deep-research runs left "
        "generating on pages nothing is watching, on a platform whose report is only reachable "
        "from the page holding the conversation",
    ),
    (
        "emubackend/phases.py",
        "        for name in prompts.P2_PLATFORMS:",
        "        for name in list(drivers):",
        "test_p2_sequential.py::TestSequentialExecution::test_the_platform_ORDER_is_the_backends_and_not_the_callers",
        "running P2 in whatever order the caller listed its platforms, so the consolidated report's "
        "section order depends on an argument rather than on the contract",
    ),
    (
        "emubackend/phases.py",
        "            if len(text) != chars:",
        "            if False:",
        "test_p2_sequential.py::TestSequentialExecution::test_a_SHORT_READ_is_not_accepted_as_the_report",
        "accepting a TRUNCATED report — still markdown, still over the floor, and missing its "
        "conclusions",
    ),
    (
        "emubackend/phases.py",
        "        if not deps.reports:\n            raise ManifestError(",
        "        if False:\n            raise ManifestError(",
        "test_p2_sequential.py::TestSequentialExecution::test_ALL_platforms_failing_RAISES_rather_than_handing_P3_nothing",
        "handing P3 an empty consolidated document when every platform failed, producing a podcast "
        "about nothing",
    ),
    (
        "emubackend/prompts.py",
        "    for platform in P2_PLATFORMS:",
        "    for platform in reports:",
        "test_p2_sequential.py::TestTheConsolidatedReport::test_the_ORDER_is_fixed_and_not_the_order_they_arrived_in",
        "ordering the consolidated report by which platform happened to finish first, so one run "
        "cannot reproduce another's output from the same inputs",
    ),
    (
        "emubackend/prompts.py",
        "        if text:\n            heading = CONSOLIDATED_TITLES[platform]",
        "        if True:\n            heading = CONSOLIDATED_TITLES[platform]",
        "test_p2_sequential.py::TestTheConsolidatedReport::test_a_MISSING_platform_is_skipped_not_written_as_an_empty_section",
        "writing an empty section for a platform that failed, which reads to anyone opening the "
        "document as a platform that found nothing",
    ),
    (
        "emubackend/prompts.py",
        '    return "\\n".join(parts) if len(parts) > 1 else ""',
        '    return "\\n".join(parts)',
        "test_p2_sequential.py::TestTheConsolidatedReport::test_no_reports_at_all_yields_NOTHING_rather_than_a_bare_heading",
        "writing a consolidated document containing only its title — written, linked, and opening "
        "empty",
    ),

    # --- P3: the notebook, and the readiness signal ---------------------------------------------
    (
        "emubackend/notebook.py",
        'HOST = "notebook.google.com"',
        'HOST = "notebooklm.google.com"',
        "test_notebook.py::TestTheMeasuredFacts::test_the_host_is_notebook_not_notebooklm",
        "looking the page up on the pre-redirect host, which a page lookup never sees — the platform "
        "then reports as signed out when it is signed in",
    ),
    (
        "emubackend/notebook.py",
        "    if len(body) < MIN_SOURCE_CHARS:",
        "    if False:",
        "test_notebook.py::TestTheSourceText::test_a_TOO_SHORT_consolidated_report_is_REFUSED",
        "generating a ninety-minute Audio Overview from a stub — a podcast about nothing, which "
        "cannot be undone or cheaply re-run",
    ),
    (
        "emubackend/notebook.py",
        "    if not cleaned:",
        "    if False:",
        "test_notebook.py::TestTheNotebookTitle::test_an_EMPTY_topic_is_refused_rather_than_left_untitled",
        "creating PERMANENT 'Untitled note' notebooks in the owner's real account, which nothing "
        "anywhere cleans up",
    ),
    (
        "emubackend/notebook.py",
        "  return { ready: (!!player || playing) && !generating,",
        "  return { ready: true,",
        "test_notebook.py::TestAudioReadiness::test_the_WORDS_Audio_Overview_alone_do_NOT_mean_ready",
        "reporting an Audio Overview ready the moment its card renders — the run claims a podcast it "
        "does not have",
    ),
    (
        "emubackend/notebook.py",
        "  const generating = /generating|loading|creating|preparing/.test(body);",
        "  const generating = false;",
        "test_notebook.py::TestAudioReadiness::test_a_player_that_is_still_GENERATING_is_not_ready",
        "ignoring the card's own progress text, so a player element that exists WHILE generating "
        "reads as finished",
    ),
    (
        "emubackend/notebook.py",
        "    if not isinstance(state, dict):\n        return False",
        "    if not isinstance(state, dict):\n        return True",
        "test_notebook.py::TestAudioReadiness::test_an_UNREADABLE_probe_is_not_ready",
        "an unreadable readiness probe failing OPEN, which reports a podcast that does not exist",
    ),

    # --- the IN-APP phase contract (§15.4 reconciled) --------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                let fillPath = try await driver.fillComposer(Prompts.briefPrompt(topic: topic))",
        "                let fillPath = try await driver.fillComposer(topic)",
        "swift:InAppPipelineTests/testP1SendsTheWRAPPERPromptAndNotTheBareTopic",
        "P1 sending the bare topic in-app — a chat answer instead of a brief, and P2 then fed a "
        "conversation",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                _ = try await driver.disableDeepResearch()",
        "                _ = false",
        "swift:InAppPipelineTests/testP1TURNSDEEPRESEARCHOFFWithBackspaceAndNotWithASecondTap",
        "P1 running in DEEP RESEARCH mode on every run after the first, because the toggle persists "
        "across sessions — a 30-minute report where a brief was wanted, with nothing failing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                let fillPath = try await driver.fillComposer(outcome.brief)",
        "                let fillPath = try await driver.fillComposer(topic)",
        "swift:InAppPipelineTests/testP2SendsTHEBRIEFAndNotTheTopic",
        "P2 re-asking the topic in-app instead of sending P1's brief",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                guard brief.count >= Prompts.briefFloorChars else {",
        "                guard brief.count >= 0 else {",
        # Pointed at the SHORT-response test: the other fixture answers at full brief length, so
        # removing the floor changes nothing there and the mutation reported CAUGHT for free.
        "swift:InAppPipelineTests/testP1REFUSESAStubAsTheBrief",
        "accepting a stub as the in-app brief — the measured shape is a 15-character 'ChatGPT said:' "
        "from an unfinished response",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        for _ in 0..<attempts {\n            try await page.key(\"Backspace\")",
        "        for _ in 0..<attempts {\n            try await page.key(\"Delete\")",
        "swift:InAppPipelineTests/testP1TURNSDEEPRESEARCHOFFWithBackspaceAndNotWithASecondTap",
        "pressing the wrong key to remove the Deep research pill, so it survives and P1 runs in the "
        "wrong mode",
    ),

    # --- model selection: family + highest offered, never a version literal ----------------------
    (
        "emubackend/models.py",
        "        if option is None or option.family.lower() != wanted:",
        "        if option is None or wanted not in option.family.lower():",
        "test_models.py::TestAgainstTheLiveMenu::test_a_NEWER_flash_lite_still_does_not_win_the_flash_slot",
        "matching the family as a SUBSTRING, so 'Flash' matches 'Flash-Lite' and the first newer "
        "Flash-Lite switches a deep-research phase onto the fastest/cheapest tier — worse research, "
        "nothing failing",
    ),
    (
        "emubackend/models.py",
        "        if best is None or option.version > best.version:",
        "        if best is None or option.label > best.label:",
        "test_models.py::TestVersionOrdering::test_minor_versions_order_numerically_not_lexically",
        "ordering versions as TEXT, so 3.9 beats 3.10 and the picker silently stays a version behind",
    ),
    (
        "emubackend/models.py",
        "    return best.label if best else None",
        "    return best.label if best else (labels[0] if labels else None)",
        "test_models.py::TestRefusals::test_a_family_that_is_NOT_OFFERED_returns_None_rather_than_a_near_miss",
        "falling back to whatever row is first when the family is not offered — switching the run "
        "onto a model nobody chose",
    ),

    (
        "emubackend/phases.py",
        "        || placeholder.includes('write your prompt')\n",
        "",
        "test_p1_brief_contract.py::TestTheChatModePlaceholders::test_claudes_REAL_placeholder_is_recognised_as_chat_mode",
        "Claude unable to report a positive OFF, because its MEASURED placeholder ('Write your "
        "prompt to Claude') matches no chat-mode needle — so P1's disable-deep-research step can "
        "never confirm on that platform and legitimate recovery is blocked forever",
    ),

    # --- P3's files must reach the iOS document picker ------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DocumentExport.swift",
        "        for platform in Prompts.p2Platforms {",
        "        for platform in reports.keys {",
        "swift:DocumentExportTests/testTheUPLOADORDERIsTheBackendsAndNotTheDictionarys",
        "uploading the reports in whichever order the dictionary happens to iterate, so the "
        "notebook's source list does not match the consolidated report and two identical runs "
        "produce different notebooks",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DocumentExport.swift",
        "            guard !trimmed.isEmpty else { throw ExportError.emptyDocument(platform) }",
        "            guard true else { throw ExportError.emptyDocument(platform) }",
        "swift:DocumentExportTests/testAnEMPTYReportIsREFUSEDRatherThanWritten",
        "writing an EMPTY .md file — the picker lists it, NotebookLM accepts it, and the notebook "
        "holds a source with nothing in it, indistinguishable afterwards from a platform that "
        "found nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DocumentExport.swift",
        "        guard !written.isEmpty else { throw ExportError.noDocuments }",
        "        guard true else { throw ExportError.noDocuments }",
        "swift:DocumentExportTests/testNoReportsAtAllIsAnErrorAndNotAnEmptyDirectory",
        "opening the document picker onto an EMPTY directory, which reads as the upload silently "
        "doing nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DocumentExport.swift",
        '        root.appendingPathComponent("runs", isDirectory: true)\n            .appendingPathComponent(researchID, isDirectory: true)',
        '        root.appendingPathComponent("runs", isDirectory: true)',
        "swift:DocumentExportTests/testEachRunGetsItsOWNDirectory",
        "every run sharing one export directory, so the picker shows a PREVIOUS run's reports and "
        "the owner uploads sources nobody chose into the notebook",
    ),

    # --- the Storage client the audio upload needs -----------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/FirebaseStorage.swift",
        'request.setValue("Firebase \\(token)", forHTTPHeaderField: "Authorization")',
        'request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")',
        "swift:FirebaseStorageTests/testAnUploadSendsTheFIREBASESchemeAndNotBearer",
        "using Firestore's Bearer scheme against Storage, which answers 401 and names nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirebaseStorage.swift",
        'withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))',
        'withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~/"))',
        "swift:FirebaseStorageTests/testSlashesAreENCODEDInTheObjectName",
        "leaving slashes unencoded in a FLAT key-value store, so the object lands somewhere else "
        "or 404s on read while the upload reported success",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirebaseStorage.swift",
        '        guard let downloadToken = tokens.first, !downloadToken.isEmpty else {',
        '        guard let downloadToken = tokens.first ?? "" as String? else {',
        "swift:FirebaseStorageTests/testAnUploadWithNODownloadTokenIsAnERRORAndNotASuccess",
        "reporting a tokenless upload as a success — a dead link on the Podcasts page for a run "
        "that otherwise finished",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirebaseStorage.swift",
        '        if lower.hasSuffix(".mp3") { return "audio/mpeg" }',
        '        if lower.hasSuffix(".mp3") { return "audio/*" }',
        "swift:FirebaseStorageTests/testTheContentTypeIsSpecificEnoughForABrowserToPlayIt",
        "uploading an mp3 as a generic audio type, so the browser refuses to play it and the "
        "Podcasts page shows a player that does nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirebaseStorage.swift",
        "        guard !bucket.isEmpty else { throw StorageError.noBucket }",
        "        guard true else { throw StorageError.noBucket }",
        "swift:FirebaseStorageTests/testAMissingBucketFailsBEFOREAnyRequestIsMade",
        "uploading to a syntactically valid URL with no bucket in it",
    ),

    # --- getting the podcast to the frontend ------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        '            "links.audio_file": .map([',
        '            "links.audio": .map([',
        "swift:AudioDeliveryTests/testTheLinkFieldIsAUDIOFILEAndNotAUDIO",
        "writing the audio into links.audio — the NotebookLM SHARE PAGE slot — so the YouTube step "
        "fetches an HTML page and uploads it as a video",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        '                "url": .string(url),\n                // The same label the backend writes',
        '                "u": .string(url),\n                // The same label the backend writes',
        "swift:AudioDeliveryTests/testTheLinkIsAMAPWithAUrlMemberAndNotABareString",
        "a links.audio_file map with no `url` member — the frontend reads `audio_file?.url`, so the "
        "cloud takes its no-usable-audio fast path and the finished research has no podcast and no "
        "error",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        "        guard !audio.isEmpty else { throw DeliveryError.emptyAudio }",
        "        guard true else { throw DeliveryError.emptyAudio }",
        "swift:AudioDeliveryTests/testEMPTYAudioIsRefusedBEFOREItIsUploaded",
        "uploading zero bytes, which returns a valid URL and puts a player on the Podcasts page "
        "that plays silence",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        '        "podcast-\\(researchID).\\(fileExtension)"',
        '        "podcast.\\(fileExtension)"',
        "swift:AudioDeliveryTests/testTheFilenameIsDerivedFromTheRunAndNotFromTheTitle",
        "every run writing to ONE object name, so a second run silently overwrites the first run's "
        "podcast in Storage",
    ),

    # --- who may drive a watched page -------------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchInput.swift",
        "        ownerTookOver || runIsDriving",
        "        ownerTookOver",
        "swift:BrowserWatchInputTests/testTheRUNCanDriveThePageWithoutTheOwnerTakingOver",
        "restoring the state where WATCHING blocks the automation's own taps — calibration then "
        "fails with 'fewer than two probe taps produced a trusted event', which reads as a broken "
        "input channel and is actually a SwiftUI modifier two files away",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "        return active.count == 1 ? active[0] : nil",
        "        return active.first",
        "swift:BrowserWatchInputTests/testTWOActivePlatformsIsAMBIGUOUSAndYieldsNONE",
        "guessing which platform a run is on when the device reports two as active — handing INPUT "
        "to the automation on a page it is not driving",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/BrowserWatchInput.swift",
        '        if runIsDriving { return "The run is driving this page. Avoid tapping while it works." }',
        '        if runIsDriving { return "Read-only while the run drives this page." }',
        "swift:BrowserWatchInputTests/testTheCaptionSaysINPUTISLIVEWhenTheRunIsDriving",
        "telling the owner the page is read-only while input is in fact live — worse than saying "
        "nothing, because they will trust it",
    ),

    # --- the clarifying question: deep research's fourth response state -------------------------
    (
        "emubackend/phases.py",
        '                    "state": "question",',
        '                    "state": "content",',
        "test_clarifying_question.py::TestTheQuestionIsRecognised::test_a_short_clarifying_question_is_its_own_state",
        "a clarifying question classified as CONTENT — it passes the wait, fails the harvest, and "
        "the run reports a selector problem while the platform waits for an answer nobody gave it",
    ),
    (
        "emubackend/phases.py",
        "        tail = stripped[-CLARIFYING_TAIL_CHARS:]",
        "        tail = stripped",
        # Pointed at the SHORT fixture: the long one is rejected by the LENGTH guard first, so the
        # tail restriction is not load-bearing there and the mutation reported CAUGHT for free.
        "test_clarifying_question.py::TestARealReportIsNotMistakenForAQuestion::test_a_SHORT_answer_whose_marker_is_only_at_the_START_is_content",
        "matching the question markers ANYWHERE instead of in the tail, so a report whose opening "
        "line says 'before I begin' is discarded — throwing away a deep-research unit's output",
    ),
    (
        "emubackend/phases.py",
        "    if len(stripped) <= CLARIFYING_MAX_CHARS:",
        "    if True:",
        "test_clarifying_question.py::TestARealReportIsNotMistakenForAQuestion::test_a_long_report_ending_with_a_polite_offer_is_still_CONTENT",
        "treating a 60,000-character report that ends 'let me know if you would like more detail' as "
        "a question, discarding the run's product",
    ),
    (
        "emubackend/phases.py",
        '        if health["state"] == "question":',
        '        if False:',
        "test_clarifying_question.py::TestTheHarvestStopsOnAQuestion::test_the_harvest_raises_and_NAMES_the_question",
        "harvesting straight through a clarifying question, so the failure is reported as read "
        "drift and the next session repairs selectors that were never wrong",
    ),

    # --- the modal sweep, and the gates that must survive it -------------------------------------
    # NOTE: the gate EXCLUSION inside `sweep_targets` is deliberately NOT mutated. No gate label
    # appears in `SWEEP_LABELS`, so nothing reaches it and no mutation can be caught — a fact about
    # the code, not a gap in the tests. It is kept as a second lock ("Skip" looks exactly like a
    # dismissal), and the killable form of the same property — no gate may appear in the sweep list
    # — is asserted by `test_NO_GATE_LABEL_MAY_EVER_APPEAR_IN_THE_SWEEP_LIST`.
    (
        "emubackend/phases.py",
        '    "gemini": "Start research",',
        '    "gemini": "Okay",',
        "test_modal_sweep.py::test_NO_GATE_LABEL_MAY_EVER_APPEAR_IN_THE_SWEEP_LIST",
        "a blocking gate whose label collides with the sweep list, so the sweep presses it as a "
        "dismissal and the phase reports success having started no research",
    ),
    (
        "emubackend/phases.py",
        "        if low in SWEEP_LABELS:",
        "        if low not in SWEEP_LABELS:",
        "test_modal_sweep.py::TestTheSweep::test_unrelated_controls_are_left_alone",
        "a sweep that presses everything it does NOT recognise — cancelling runs, deleting chats, "
        "and clicking upgrade prompts",
    ),
    (
        "emubackend/phases.py",
        '    "gemini": "Start research",\n    "claude": "Skip",',
        '    "claude": "Skip",',
        "test_modal_sweep.py::TestTheGatesAreNotSwept::test_the_gate_is_returned_for_the_caller_to_PRESS_deliberately",
        "losing Gemini's blocking gate, so nothing presses Start research and the phase waits "
        "forever on a page that is waiting for it",
    ),

    # --- Claude's P2 setup (owner-specified; an earlier measured "no Research" was WRONG) --------
    (
        "emubackend/prompts.py",
        '    return DEEP_RESEARCH_AVAILABLE.get(platform, False)',
        '    return DEEP_RESEARCH_AVAILABLE.get(platform, True)',
        "test_claude_standard_mode.py::TestClaudeIsADeepResearchPlatform::test_an_UNKNOWN_platform_still_defaults_to_NO",
        "an unmeasured platform assumed to HAVE deep research, so a plain chat answer ships as a "
        "deep-research report with nothing downstream able to tell",
    ),
    (
        "emubackend/prompts.py",
        'REQUIRED_MODE = {"claude": "Chat"}',
        'REQUIRED_MODE = {}',
        "test_claude_standard_mode.py::TestClaudesRequiredMode::test_claude_must_be_put_into_CHAT_mode",
        "P2 landing in Claude's COWORK mode, whose composer menu has no Research at all — the "
        "failure then reads as a missing selector, which is exactly the misdiagnosis that produced "
        "a wrong 'Claude has no deep research' finding",
    ),
    (
        "emubackend/models.py",
        '    "claude": "Opus",',
        '    "claude": "Sonnet",',
        "test_claude_standard_mode.py::TestClaudesModelFamily::test_claude_uses_the_OPUS_family",
        "running Claude's deep research on Sonnet when the owner asked for the highest Opus",
    ),

    # --- the executor: the piece that joins intake, pipeline, documents and handoff --------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        guard !reports.isEmpty else {",
        "        guard true else {",
        "swift:RunExecutorTests/testNOReportsAtAllABANDONSTheRunWithoutHandingOff",
        "handing off a run that produced NOTHING — beDone set, the queue unstalled, the cloud "
        "triggered, and a video made of an empty document: a run that reports success and delivers "
        "nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "                steps.append(\"failed:\(platform)\")",
        "                steps.append(\"failed:\(platform)\"); return;",
        "swift:RunExecutorTests/testONEPlatformFailingStillFinishesTheRun",
        "one platform's failure discarding the reports the others already spent research units to "
        "produce",
    ),
    # NOTE: `brief.isEmpty` in RunExecutor's platform loop is deliberately NOT mutated any more.
    # It used to stop the second and third platforms re-assigning the brief — a real defect, and it
    # was caught. Pinning P1 to ChatGPT retired that job: ChatGPT is now the only platform that can
    # reach the line, it runs once, and when the owner supplies a brief the pipeline ECHOES it, so
    # re-assigning is a no-op. The condition is kept as a guard against a future un-pinning, but it
    # is unreachable-by-construction today and a mutation of it describes no defect. Asserting it
    # anyway would be a decorative guard, which is the thing this harness exists to find.
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        for platform in Prompts.p2Platforms {\n            let text = (reports[platform] ?? \"\")",
        "        for platform in reports.keys {\n            let text = (reports[platform] ?? \"\")",
        "swift:RunExecutorTests/testTheConsolidatedDocumentKeepsTheContractsOrder",
        "a consolidated report whose section order depends on dictionary iteration, so two identical "
        "runs produce different documents",
    ),

    # --- the adapter that backs the executor with the real driver --------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "            case 1 where !outcome.brief.isEmpty:",
        "            case 1 where false:",
        "swift:InAppRunPipelineTests/testASUPPLIEDBriefIsUsedAndP1IsNotReRun",
        "re-deriving the brief on EVERY platform and overwriting the supplied one — three first "
        "phases spent, and three agents that were supposed to answer one brief each answering a "
        "different one",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppRunPipeline.swift",
        "        let report = outcome.report.isEmpty ? nil : outcome.report",
        "        let report = outcome.report",
        "swift:InAppRunPipelineTests/testAnEMPTYReportComesBackAsNILRatherThanAnEmptyString",
        "an empty string returned as a report, so the executor writes an empty document and hands "
        "off a run that produced nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppRunPipeline.swift",
        "            page: pages(platform, worker)",
        "            page: pages(platform, 1)",
        "swift:InAppRunPipelineTests/testTheWORKERSOwnPageIsTheOneDriven",
        "driving worker 1's web view whatever worker the run was placed on — two concurrent runs "
        "sharing one cookie jar and one composer",
    ),

    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "    var launcher: (any RunLauncher)?",
        "    weak var launcher: (any RunLauncher)?",
        "swift:RunIntakeTests/testTheLauncherSurvivesTheCallerGoingOutOfScope",
        "a WEAKLY held launcher deallocating before the run starts — the queue document keeps the "
        "claim, so the next backend to look treats an unstarted run as someone else's work",
    ),

    # --- expireAt must be a real timestamp or the TTL never collects -----------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        'case .timestamp(let v): return ["timestampValue": v]',
        'case .timestamp(let v): return ["stringValue": v]',
        "swift:ExpireAtTypeTests/testATimestampEncodesUnderTheTimestampTagAndNotAsAString",
        "expireAt written as a STRING — it looks right in the console, satisfies any rule checking "
        "the field exists, and Firestore's TTL never collects it, so a subcollection meant to age "
        "out in 30 days grows forever with nothing reporting anything",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ContractEmitter.swift",
        '            "expireAt": .timestamp(Self.iso8601(clock().addingTimeInterval(30 * 24 * 3600))),',
        '            "expireAt": .string(Self.iso8601(clock().addingTimeInterval(30 * 24 * 3600))),',
        "swift:ExpireAtTypeTests/testTheEVENTSExpireAtIsWrittenAsATimestamp",
        "the events' own expireAt regressing to a string, which is exactly the state the Swift half "
        "was in while the Python half wrote a real timestamp",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        '        if let v = tagged["timestampValue"] as? String { return .timestamp(v) }',
        '        if false, let v = tagged["timestampValue"] as? String { return .timestamp(v) }',
        "swift:ExpireAtTypeTests/testATimestampDecodesBackAsATimestampAndNotAsAString",
        "reading a real timestamp back as a string, so any read-modify-write round-trip quietly "
        "disarms a TTL that was working",
    ),

    # --- Claude's Research control: the role that hid it ----------------------------------------
    #
    # ⛔ These two mutations each reproduce a REAL bug that was live in this repo, and both present
    # identically to the operator: "Claude has no Research mode". The first is the production
    # resolver's candidate-role list missing `menuitemcheckbox` — the role Research actually
    # carries. The second is the manifest's text handle. Either one alone makes a correct,
    # fully-open menu resolve to nothing.
    (
        "emubackend/phases.py",
        '"button, a, [role=button], [role=menuitem], [role=menuitemradio], "\n            "[role=menuitemcheckbox], [role=option]"',
        '"button, a, [role=button], [role=menuitem], [role=menuitemradio], "\n            "[role=option]"',
        "test_claude_standard_mode.py::TestTheResearchControlResolves::test_research_is_found_in_the_MEASURED_menu",
        "Claude's Research toggle being unresolvable because its role is not queried — read as the "
        "platform not having deep research at all, and P2 silently running in chat mode",
    ),
    (
        "selectors_mobile.json",
        '"text_contains": "Research",\n    "opener": "button[aria-label=\\"Add files, connectors, and more\\"]"',
        '"text_contains": "Deep research",\n    "opener": "button[aria-label=\\"Add files, connectors, and more\\"]"',
        "test_claude_standard_mode.py::TestTheResearchControlResolves::test_research_is_found_in_the_MEASURED_menu",
        "the manifest naming ChatGPT's label on Claude's menu, so the entry resolves to nothing and "
        "the run proceeds with Research off",
    ),

    # --- MP3 means MP3: renaming is not converting ----------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        '        let ext = actual == .unknown ? "m4a" : actual.rawValue',
        '        let ext = "mp3"',
        "swift:AudioFormatGuardTests/testAACBytesAreNEVERUploadedUnderAnMp3Name",
        "AAC bytes published under an .mp3 name — the URL works and a lenient player may even play "
        "it, while every consumer that inspects the file fails on something that looks correct",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        "            case .encoded(let mp3) where AudioFormat.sniff(mp3) == .mp3 && !mp3.isEmpty:",
        "            case .encoded(let mp3) where true:",
        "swift:AudioFormatGuardTests/testATranscoderThatReturnsNonMP3BytesIsNOTBelieved",
        "believing a broken encoder that handed back the input, so the object is named .mp3 on the "
        "strength of the encoder having been CALLED rather than having worked",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        "        if AudioFormat.sniff(audio) == .mp3 {",
        "        if false {",
        "swift:AudioFormatGuardTests/testAlreadyMP3AudioIsNOTReEncoded",
        "re-encoding an MP3 that was already an MP3, costing a generation of quality for nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        '            "label": .string("NotebookLM Notebook"),\n            "phase": .integer(3),\n            "verified": .boolean(publicVerified),',
        '            "label": .string("NotebookLM Notebook"),\n            "phase": .integer(3),\n            "verified": .boolean(true),',
        "swift:AudioDeliveryTests/testTheNotebookPatchWritesBOTHSlotsAndCarriesTheACCESSVerdict",
        "marking a link verified when its public access was never set — the P5 email recipient gets "
        "Request access instead of a notebook, and nothing upstream can tell",
    ),

    # --- a run the owner can actually SEE ------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        await announce(phase: 1, starting: true)\n        // ⛔ **A phase that never STARTED",
        "        // ⛔ **A phase that never STARTED",
        "swift:RunExecutorNotebookPhaseTests/testEVERYPhaseIsAnnouncedAndNotJustP3",
        "a run that is INVISIBLE until NotebookLM: the web app shows a research sitting still "
        "through three deep-research runs, which is what a device that claimed and died looks like",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        # ⚠ Moved with the code. The announcement now lives in `briefArrived`, which runs the
        # moment phase 1 has a brief — mid-call — rather than after the platform's own P2 and P3.
        "        await announce(phase: 1, starting: false)\n"
        "        await announce(phase: 2, starting: true)",
        "        _ = produced",
        "swift:RunExecutorNotebookPhaseTests/testPHASE1EndsWhenTheBRIEFArrivesAndNotWhenTheLoopDoes",
        "the tile stuck on `brief` through three deep-research runs — ninety minutes of a run "
        "reporting the wrong stage",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        '                "currentPhase": .integer(Int64(phase)), "phase": .integer(Int64(phase)),',
        '                "phase": .integer(Int64(phase)),',
        "swift:RunExecutorNotebookPhaseTests/testCURRENTPHASEIsWrittenAlongsidePHASE",
        "the homepage tile glowing the stale node for ever for anyone who opens the tab after the "
        "run has moved on",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        '            try? await emitter.patchResearch(["agents.\\(platform)": .map(["status": .string("running")])])',
        "            // agent status omitted",
        "swift:RunExecutorNotebookPhaseTests/testEachAGENTIsMarkedRunningAndThenSettled",
        "three agent rows sitting at whatever they were before, so a run in flight is "
        "indistinguishable from one that never started",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        # ⚠ Shortened. The old anchor ran from this catch to the end of the loop, and the
        # no-brief guard now sits in between — an anchor that spans unrelated code breaks
        # every time something is added between its ends.
        '                steps.append("failed:\\(platform)")\n'
        '                try? await emitter.patchResearch(\n'
        '                    ["agents.\\(platform)": .map(["status": .string("errored")])]\n'
        "                )",
        '                steps.append("failed:\\(platform)")',
        "swift:RunExecutorNotebookPhaseTests/testAFAILEDPlatformIsMarkedFAILEDRatherThanLeftRunning",
        "an agent stuck on `running` for ever, which is how a degraded run reads as a hung one",
    ),

    # --- Browser watch: which tab is this run actually typing into ------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "        if let platform, !platform.isEmpty {",
        "        if let platform {",
        "swift:LiveRunActivityTests/testAnEMPTYPlatformIsTreatedAsCleared",
        "storing an empty platform id, which glows no tile at all while the store reports the "
        "worker as driving something — a card that says a run is somewhere and points nowhere",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "            byWorker.removeValue(forKey: worker)\n            foreground.removeValue(forKey: worker)\n        }\n        lock.unlock()\n        onChange?()",
        "            byWorker.removeValue(forKey: worker)\n            foreground.removeValue(forKey: worker)\n        }\n        lock.unlock()\n        // no notification",
        "swift:LiveRunActivityTests/testEVERYChangeNotifiesTheUI",
        "a glow that renders once and freezes on the first platform the run touched — the core has "
        "no Combine, so nothing else would tell SwiftUI the run had moved on",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppRunPipeline.swift",
        "        defer { activity.finished(worker: worker, platform: platform) }",
        "        // the glow is left on",
        "swift:PipelineActivityReportingTests/testTheGlowIsSETWhileTheRunIsOnAPlatformAndCLEAREDAfterItThrows",
        "a glow that outlives its run, pointing the owner at a tab where nothing is happening — and "
        "on a 90-minute run `never changes` is indistinguishable from `still working`",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        '.map(["status": .string("complete")])',
        '.map(["status": .string("completed")])',
        "swift:RunExecutorNotebookPhaseTests/testEachAGENTIsMarkedRunningAndThenSettled",
        "writing a status word the frontend's tile logic does not recognise, so a finished agent "
        "renders as neither done nor failed",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        # ⚠ Shortened for the same reason as its sibling above: the no-brief guard now sits
        # between the catch and the end of the loop.
        '                steps.append("failed:\\(platform)")\n'
        '                try? await emitter.patchResearch(\n'
        '                    ["agents.\\(platform)": .map(["status": .string("errored")])]\n'
        "                )",
        '                steps.append("failed:\\(platform)")\n'
        '                try? await emitter.patchResearch(\n'
        '                    ["agents.\\(platform)": .map(["status": .string("failed")])]\n'
        "                )",
        "swift:RunExecutorNotebookPhaseTests/testAFAILEDPlatformIsMarkedFAILEDRatherThanLeftRunning",
        "the same for the failure word — a platform that errored renders as still running",
    ),

    # --- a person's avatar must not overstate what the device knows --------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "        guard isResolved, let first = label.first(where: { $0.isLetter || $0.isNumber })",
        "        guard let first = label.first(where: { $0.isLetter || $0.isNumber })",
        "swift:PersonAvatarGlyphTests/testAnUNRESOLVEDUidGetsAQuestionMarkAndNOTALetter",
        "a confident initial pulled out of a truncated UID, so a person the device could not "
        "identify gets an avatar indistinguishable from one it did — and a glyph carries none of "
        "the caveat the line beneath it does",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceModels.swift",
        "        guard isResolved, let first = label.first(where: { $0.isLetter || $0.isNumber })\n"
        "        else { return \"?\" }",
        "        guard isResolved, let first = label.first\n        else { return \"?\" }",
        "swift:PersonAvatarGlyphTests/testLeadingPunctuationIsSKIPPEDForTheFirstRealCharacter",
        "a quote or a bullet rendered in the avatar circle, which reads as a broken layout rather "
        "than as a person",
    ),

    # --- the index goes to the FRONT: the permanent answer to "we need MP3" ---------------------
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "        guard let patched = shiftChunkOffsets(in: &index, by: delta) else {",
        "        let patched = 1; if false {",
        "swift:AudioFaststartTests/testEveryCHUNKOFFSETIsShiftedByTheIndexsOwnSIZE",
        "moving the index and leaving the chunk offsets alone — the file then starts playing "
        "IMMEDIATELY and reads garbage, because every pointer aims short by the index's own size",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "            guard type == \"stco\" || type == \"co64\" else { return }",
        "            guard type == \"stco\" else { return }",
        "swift:AudioFaststartTests/testA64BitOffsetTableIsShiftedToo",
        "patching only the 32-bit table, so exactly the LONG podcasts — the ones most worth "
        "streaming — end up pointing at nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "                    guard value <= Int(UInt32.max) else { overflowed = true; return }\n"
        "                    write32(&data, at: at, UInt32(value))",
        "                    write32(&data, at: at, UInt32(truncatingIfNeeded: value))",
        "swift:AudioFaststartTests/testAnOffsetThatWouldOVERFLOWIts32BitTableIsREFUSED",
        "silently truncating an offset that no longer fits its table, which corrupts the very "
        "chunk pointers this transform exists to keep correct",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "        guard patched > 0 else {",
        "        if false {",
        "swift:AudioFaststartTests/testAMoovWithNOOffsetTableIsREFUSEDRatherThanMoved",
        "moving an index whose offsets were never found — a file that starts instantly and then "
        "plays garbage, strictly worse than the one we were handed",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "        if moov.range.lowerBound < mdat.range.lowerBound { return .alreadyStreamable }",
        "        if false { return .alreadyStreamable }",
        "swift:AudioFaststartTests/testAFileWhoseIndexIsALREADYFirstIsUntouched",
        "rearranging a file that was already correct, shifting offsets that did not need shifting",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "        guard cursor == total, !boxes.isEmpty else { return nil }",
        "        guard !boxes.isEmpty else { return nil }",
        "swift:AudioFaststartTests/testTRAILINGGarbageIsNotParsedAsBoxes",
        "reporting the boxes read before the parse lost sync, so a rearrangement is built on a "
        "misread file",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioFaststart.swift",
        "            if containers.contains(type) {",
        "            if false {",
        "swift:AudioFaststartTests/testEveryCHUNKOFFSETIsShiftedByTheIndexsOwnSIZE",
        "never descending into moov/trak/mdia/minf/stbl, so no stco is ever found and the run "
        "reports success having patched nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        "        if AudioFormat.sniff(bytes) == .m4a {",
        "        if false {",
        "swift:AudioStreamabilityTests/testTheUPLOADEDBytesHaveTheirIndexAtTheFRONT",
        "uploading the container exactly as NotebookLM wrote it — index after the audio, so a "
        "streaming consumer cannot begin playback: the defect the MP3 transcode existed to dodge",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioDelivery.swift",
        "                streamable = false",
        "                streamable = true",
        "swift:AudioStreamabilityTests/testAContainerThatCannotBeCorrectedIsSTILLDELIVERED",
        "reporting a podcast as streamable when its index could not be corrected — the one fact "
        "about it that cannot be read off the filename",
    ),

    # --- the run the owner fires from the web app ------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        # ⚠ **The DETACHMENT half of this test is deliberately NOT mutated, and the reason is worth
        # recording.** The obvious mutation — await the launch inline instead of detaching it — makes
        # the test HANG by construction rather than fail: the double is a `BlockingLauncher` that
        # sits inside `launch` until released, so an inline await never returns and no assertion is
        # ever reached. The harness refuses to score a hang as CAUGHT, and it is right to: "the
        # process stopped" cannot distinguish a caught defect from a broken mutation. Verified
        # 2026-08-15 — the mutant aborted with signal 6 and produced no test results.
        #
        # What IS mutated is the other property the same test asserts and the same line owns: a
        # claimed run must publish its worker as busy. That one fails an assertion cleanly.
        "        markBusy(worker, running: true)\n"
        "        activeRuns[worker] = (uid: entry.uid, researchID: entry.researchId)",
        "        markBusy(worker, running: false)\n"
        "        activeRuns[worker] = (uid: entry.uid, researchID: entry.researchId)",
        "swift:RunIntakeTests/testTheRunIsDETACHEDSoTheBEATKeepsBeating",
        "a claimed run that never publishes its worker as busy — so the next poll hands a second "
        "run to the worker already running one, and the web app shows an idle pill for a live run",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        if running { locallyBusyWorkers.insert(worker) } else { locallyBusyWorkers.remove(worker) }",
        "        if !running { locallyBusyWorkers.remove(worker) }",
        "swift:RunIntakeTests/testAWorkerDrivingARunIsBUSYForTheNextPoll",
        "the next beat seeing every worker free and claiming a SECOND run onto the worker already "
        "driving one — two runs, one set of web views",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        '            try? await self.pairing.deleteDocument(path: "\\(queuePath)/\\(entry.id)")',
        "            // queue entry left in place",
        "swift:RunIntakeTests/testTheQueueEntryIsDELETEDWhenTheRunFinishes",
        "leaving the finished run's queue entry behind, so the only thing that eventually removes "
        "it is our own 30-second zombie sweep deciding the claimer is dead when the claimer is us",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        '            briefText: string("briefText") ?? "",',
        '            briefText: "",',
        "swift:RunQueueDecodeTests/testTheOWNERSOwnBriefIsCarriedThrough",
        "the device re-deriving a brief the owner had already written — a spent P1, and three "
        "agents answering a subtly different question from the one that was asked",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunQueue.swift",
        "            config: RunConfig.decode(doc.fields[\"config\"])",
        "            config: RunConfig.decode(doc.fields[\"pipelineConfig\"])",
        "swift:RunQueueDecodeTests/testThePodcastLengthIsReadFromTheNestedCONFIG",
        "reading the length from a field the web app does not write on this document, so every "
        "podcast is the fallback length while the owner's choice is silently ignored",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        var lengthAtClaim = entry.podcastLength\n        if lengthAtClaim == nil {",
        "        var lengthAtClaim: String? = nil\n        if lengthAtClaim == nil {",
        "swift:RunExecutorNotebookPhaseTests/testTheQUEUESOwnLengthIsPreferredToAReadThatMayBeRefused",
        "throwing away the length that arrived ON the queue document — the one this device can "
        "always read — in favour of a research-document read that may be refused",
    ),

    # --- the join: a claimed run actually running --------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunLauncherAssembly.swift",
        '        if let existing = entry.backendRunId, !existing.isEmpty { return existing }',
        '        if let existing = entry.backendRunId { return existing }',
        "swift:RunLauncherAssemblyTests/testAnEMPTYBackendRunIdIsTreatedAsAbsent",
        "every run whose backendRunId was created empty by the frontend sharing one blank id, so "
        "their events cannot be told apart",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunLauncherAssembly.swift",
        '        return "ios-\\(deviceID.prefix(8))-\\(Int64(now.timeIntervalSince1970 * 1000))"',
        '        return "ios-\\(deviceID.prefix(8))"',
        "swift:RunLauncherAssemblyTests/testAFreshRunGetsAnIdThatNamesTheDEVICEAndTheMOMENT",
        "two runs on one device sharing a run id, so the second run's events land against the first",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunLauncherAssembly.swift",
        '        fields["deviceId"] = .string(deviceID)',
        "        // deviceId omitted",
        "swift:RunLauncherAssemblyTests/testEveryHandoffPatchCarriesTheDEVICEID",
        "a 403 on the beDone write, which stalls the owner's NEXT run behind a queue gate that "
        "never opens",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunLauncherAssembly.swift",
        '        try await client.patchDocument(path: "users/\\(uid)/researches/\\(researchId)", set: fields)',
        '        try await client.patchDocument(path: "users/owner/researches/\\(researchId)", set: fields)',
        "swift:RunLauncherAssemblyTests/testTheHandoffPatchAddressesTheOWNERSTreeAndNotTheSubmitters",
        "writing a sharer's finished run into the wrong user's tree, where nothing reads it",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        guard let rest = pairing as? RESTPairingBackend else {",
        "        let rest = RESTPairingBackend(config: FirebaseProjectConfig(projectID: \"p\", apiKey: \"k\", apiBaseURL: URL(string: \"https://x\")!)); if false {",
        "swift:RunLauncherAttachmentTests/testATRANSPORTWithNoRESTSessionDoesNotGetAFakeLauncher",
        "a launcher with no Firestore session at all: it would claim runs and lose every one of "
        "them, which is strictly worse than not claiming",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WebAutomation.swift",
        '        expression.contains("window.__sr")',
        "        true",
        "swift:RuntimeReinjectionTests/testAFailureInSOMEONEELSESJavaScriptIsReportedAsItself",
        "retrying every page error behind a runtime injection, so a genuine failure is reported as "
        "whatever the second attempt happened to do",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RESTPairingBackend.swift",
        '            storageBucket: (plist["STORAGE_BUCKET"] as? String) ?? ""',
        '            storageBucket: "\\(projectID).appspot.com"',
        "swift:StorageBucketConfigTests/testTheBucketComesFromThePLISTAndIsNotDerivedFromTheProjectId",
        "uploading the podcast to a DERIVED bucket name — Firebase changed its default and this "
        "project is the newer `.firebasestorage.app` form, so the guess 404s on a URL that looks "
        "perfectly well formed",
    ),

    # --- a dotted key is a field PATH, and the body speaks NAMES ---------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        '            try insert(key.split(separator: ".").map(String.init)[...], set[key]!, into: &tree, at: key)',
        "            try insert([key][...], set[key]!, into: &tree, at: key)",
        "swift:FirestoreDottedFieldPathTests/testADottedKeyBecomesANESTEDMapInTheBody",
        "a body declaring a top-level field literally named links.audio_file while the mask points "
        "at links -> audio_file: the masked path is absent from the body, which is Firestore's "
        "DELETE mechanism, and the write returns 200",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/FirestoreREST.swift",
        "        var child = node[head] as? [String: Any] ?? [:]",
        "        var child: [String: Any] = [:]",
        "swift:FirestoreDottedFieldPathTests/testTWOKEYSSHARINGAPrefixMERGEIntoOneMap",
        "two links written in one patch overwriting each other's subtree, so the notebook row or "
        "the audio row is silently dropped depending on dictionary order",
    ),

    # --- P3: the notebook, its link, and the podcast ---------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        if !Self.notebookID(existing).isEmpty { return existing }",
        "        if false { return existing }",
        "swift:NotebookCreationTests/testAnExistingNotebookIsREUSEDAndNothingIsClicked",
        "a retried P3 creating a SECOND permanent notebook in the owner's real Google account, "
        "which nothing anywhere cleans up",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        guard body.count >= Self.minSourceChars else {",
        "        guard true else {",
        "swift:NotebookSourceTests/testAThinReportIsRefusedBEFOREThePageIsTouched",
        "generating an Audio Overview from a stub — a podcast about nothing, at the end of a run "
        "that has already spent three deep-research units",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        '        if opener.hasPrefix("__url:") {',
        "        if false {",
        "swift:NotebookSourceTests/testTheAddSourceSheetIsReachedByNAVIGATINGAndNotByTapping",
        "leaving the machine-readable `__url:` opener inert again — the add-source sheet is reached "
        "by NAVIGATING, and nothing navigates",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        '            let base = notebookURL.split(separator: "?").first.map(String.init) ?? notebookURL',
        "            let base = notebookURL",
        "swift:NotebookSourceTests/testAnExistingQueryOnTheNotebookURLIsReplacedRatherThanAppendedTo",
        "a URL with two `?` in it, which is not a query at all — the sheet never opens while the "
        "navigation itself reports success",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        if try await audioIsGenerating() { return false }",
        "        if false { return false }",
        "swift:NotebookAudioTests/testNothingIsGeneratedWhileOneIsSTILLGenerating",
        "pressing Generate on a notebook that is already generating, producing the duplicate "
        "podcast the whole prevention path exists to avoid",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "            guard !decoded.isEmpty else {\n"
        "                throw NotebookError.audioNotDownloadable(",
        "            guard !decoded.isEmpty else {\n"
        "                break; throw NotebookError.audioNotDownloadable(",
        "swift:NotebookDownloadTests/testAZeroLengthChunkIsAFailureAndNotAnEndOfStream",
        "treating a zero-length read as end-of-stream: a TRUNCATED podcast returned as complete, "
        "which plays perfectly right up to where it stops",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "           Self.notebookID(here) != Self.notebookID(notebookURL) {",
        "           false {",
        "swift:NotebookDownloadTests/testTheDownloadREANCHORSWhenThePageHasDrifted",
        "downloading from whatever notebook the page drifted to — the download succeeds and "
        "delivers ANOTHER run's podcast",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        let finalURL = url.isEmpty ? notebookURL : url",
        "        let finalURL = url",
        "swift:NotebookShareTests/testADialogThatYIELDSNoLinkStillReturnsTheNOTEBOOKURL",
        "a P3 tile with no NotebookLM row at all when sharing was refused, which reads as `P3 never "
        "ran` rather than as `the link may be private`",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        } else if Self.isNotebookURL(candidate) {",
        "        } else if true {",
        "swift:NotebookShareTests/testALinkThatIsNotANotebookURLIsDISCARDEDRatherThanWritten",
        "publishing whatever a stray readonly input happened to hold as the owner's notebook link",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        let verified = ((try? await page.evaluateJSON(Self.verifyPublicJS)) as? Bool) ?? false\n"
        "        // Save AFTER the verify — the dialog's own state is what is being read, and saving closes it.\n"
        "        _ = try? await page.evaluateJSON(Self.saveShareJS)",
        "        _ = try? await page.evaluateJSON(Self.saveShareJS)\n"
        "        let verified = ((try? await page.evaluateJSON(Self.verifyPublicJS)) as? Bool) ?? false",
        "swift:NotebookShareTests/testTheACCESSVerdictIsREADBeforeTheDialogIsSAVED",
        "reading the access state after the save has closed the dialog, so a notebook that was just "
        "made public is reported as possibly private",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        '        _ = try? await page.evaluateJSON(Self.armDownloadCaptureJS)\n        guard ((try? await page.evaluateJSON(Self.clickDownloadRowJS)) as? Bool) ?? false else {\n            throw NotebookError.audioNotDownloadable(\n                "no Download row in the audio card\'s overflow menu"\n            )\n        }\n',
        '        guard ((try? await page.evaluateJSON(Self.clickDownloadRowJS)) as? Bool) ?? false else {\n            throw NotebookError.audioNotDownloadable(\n                "no Download row in the audio card\'s overflow menu"\n            )\n        }\n        _ = try? await page.evaluateJSON(Self.armDownloadCaptureJS)\n',
        "swift:NotebookDownloadTests/testTheCAPTUREIsArmedBEFORETheDownloadRowIsPressed",
        "arming the URL capture after the click it was meant to intercept, so the fallback delivers "
        "whatever the player happens to hold — the wrong podcast on a notebook with two cards",
    ),

    # --- the length the owner asked for ----------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/AudioLength.swift",
        '    public var format: String { self == .short ? "Brief" : "Deep Dive" }',
        '    public var format: String { "Deep Dive" }',
        "swift:AudioLengthTests/testSHORTIsADIFFERENTFORMATAndNotAShorterDeepDive",
        "treating `short` as a shorter Deep Dive rather than as the Brief format tile it actually "
        "is, so the wrong format is generated",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioLength.swift",
        "        case .short: return nil",
        '        case .short: return "Default"',
        "swift:NotebookAudioTests/testTheSHORTVariantSetsNoLengthBecauseItHasNoLengthStep",
        "hunting for a length control the Brief variant does not have, which either stalls the "
        "phase or clicks whatever is there instead",
    ),

    # --- the ORDER of P3 within a run ------------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        await runNotebookPhase(\n"
        "            entry: entry, consolidated: consolidated, lengthAtClaim: lengthAtClaim\n"
        "        )",
        "        _ = lengthAtClaim",
        "swift:RunExecutorNotebookPhaseTests/testP3RunsAFTERTheDocumentsAndBEFORETheHandoff",
        "handing off to the cloud with no notebook, no public link and no podcast, while every "
        "document write reports success",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        await announce(phase: 3, starting: false)",
        "        if products != nil { await announce(phase: 3, starting: false) }",
        "swift:RunExecutorNotebookPhaseTests/testPHASECOMPLETE3IsEmittedEvenWhenThereIsNoPodcast",
        "withholding the event the frontend drives P4 from, stranding a degraded run at NotebookLM "
        "for ever with no error anywhere",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "            lengthAtClaim = await configReader?.podcastLength(\n"
        "                uid: entry.uid, researchId: entry.researchId\n"
        "            )",
        "            lengthAtClaim = nil",
        "swift:RunExecutorNotebookPhaseTests/testTheLengthIsReadAtCLAIMTimeAndCarriedIntoP3",
        "losing the length the run STARTED with, so the P3 re-read — which is DENIED for this "
        "device's identity — has nothing to fall back to and every podcast is the default length",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/ContractEmitter.swift",
        '        fields["deviceId"] = .string(deviceId)',
        "        // deviceId omitted",
        "swift:RunExecutorNotebookPhaseTests/testEveryResearchPatchCarriesTheDEVICEID",
        "a 403 on every P3 link write, from a rule that names neither the field nor the reason",
    ),

    # --- the ported JavaScript, executed under node --------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "          if (el.childNodes[i].nodeType === 3) s += el.childNodes[i].nodeValue || '';",
        "          s += (el.innerText || '');",
        "test_notebook_js.py::test_the_strict_verify_reads_the_triggers_OWN_text_and_not_its_options",
        "reading an OPEN dropdown's option labels as the trigger's own state, so a PRIVATE notebook "
        "verifies as public",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        'button[aria-label=\"Customise Audio Overview\"]',",
        "        '[aria-label=\"Audio Overview\"]',",
        "test_notebook_js.py::test_the_customise_arrow_is_clicked_and_the_card_body_is_NOT",
        "clicking the audio card BODY, which fires NotebookLM's one-click default audio — the "
        "confirmed source of duplicate podcasts",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        if (nlmLabel(rows[i]).toLowerCase() === 'download') { rows[i].click(); return true; }",
        "        if (i === 2) { rows[i].click(); return true; }",
        "test_notebook_js.py::test_DOWNLOAD_is_pressed_and_DELETE_two_rows_below_it_is_not",
        "identifying the row by POSITION instead of by label, which presses Delete — the backend's "
        "own note says the two sit two rows apart in the same overflow menu",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "            if (at !== -1) t = t.slice(0, at) + ' ' + t.slice(at + it.length);",
        "            if (at !== -1) t = t;",
        "test_notebook_js.py::test_an_ICON_LIGATURE_does_not_stop_an_option_from_matching",
        "losing the STRUCTURAL icon strip and falling back to the regexes, which cannot remove a "
        "single-word ligature like `tune` — so `tune Deep Dive` stops matching `Deep Dive` and the "
        "format is never selected",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "        if (cx < 0 || cy < 0) return false;",
        "        if (false) return false;",
        "test_notebook_js.py::test_a_control_parked_OFFSCREEN_is_not_pressed",
        "pressing a control parked at x=-36 with a full-size rect and a live offsetParent, which is "
        "exactly how NotebookLM renders its chat options",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "      for (var p = 0; p < roots.length; p++) {\n"
        "        var btns = roots[p].querySelectorAll('button, [role=\"button\"]');",
        "      for (var p = 0; p < readRoots.length; p++) {\n"
        "        var btns = readRoots[p].querySelectorAll('button, [role=\"button\"]');",
        "test_notebook_js.py::test_the_copy_fallback_stays_INSIDE_the_dialog_and_reports_no_dialog_otherwise",
        "a document-wide `any button whose text contains copy` search becoming a real click on "
        "whatever the notebook happens to render",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "      if (/generating audio overview/i.test(contText)) return false;",
        "      if (false) return false;",
        "test_notebook_js.py::test_a_GENERATING_placeholder_means_not_ready_even_with_an_item_present",
        "reading a still-generating notebook as finished, so the download runs against a card that "
        "has no audio yet",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "            if (nlmLabel(rows[i]).toLowerCase() === want) { rows[i].click(); return true; }",
        "            if (nlmLabel(rows[i]).toLowerCase().indexOf(want) !== -1) { rows[i].click(); return true; }",
        "test_notebook_js.py::test_the_option_pick_is_EXACT_and_does_not_take_a_neighbour",
        "picking `Longer` when the owner asked for `Long` — a perfectly good podcast of the wrong "
        "duration, which nothing downstream flags",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "          if (btns[j].disabled) continue;",
        "          if (false) continue;",
        "test_notebook_js.py::test_a_DISABLED_generate_button_is_not_pressed",
        "pressing a Generate that is still disabled — a no-op the caller reads as a started "
        "generation, so the wait then runs its full ninety minutes",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookPhase.swift",
        "            || (parentTxt.indexOf('notebook access') !== -1\n"
        "                && (txt.indexOf('off') !== -1 || txt.length < 30))) {",
        "            || txt.length < 30) {",
        "test_notebook_js.py::test_the_access_opener_does_NOT_fire_when_nothing_names_an_access_level",
        "opening the people picker's listbox instead of the access control — the desktop recorded a "
        "run choosing `Search results` for exactly this reason",
    ),

    # --- the audio-overview length, taken from the frontend's config ---------------------------
    #
    # ⛔ A wrong length produces a perfectly good audio file of the wrong duration. Nothing
    # downstream flags it — there is no error to notice, which is why each of these is mutated.
    (
        "ios/Sources/SuperResearchDeviceCore/AudioLength.swift",
        "    public static let fallback: AudioLength = .long",
        "    public static let fallback: AudioLength = .default",
        "swift:AudioLengthTests/testTheFallbackIsLONGAndNotTheOneCalledDefault",
        "falling back to the value CALLED default instead of the backend's actual default, which "
        "silently shortens every audio overview whose config predates the feature",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioLength.swift",
        "        if let overlay, let parsed = AudioLength(rawValue: overlay) {\n            return parsed\n        }",
        "",
        "swift:AudioLengthTests/testTheOVERLAYWinsOverTheDiskValue",
        "the phase-time re-read being ignored, so a length changed after the run was queued is "
        "never applied and the run uses a stale one",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/AudioLength.swift",
        "        if let disk, let parsed = AudioLength(rawValue: disk) {\n            return parsed\n        }",
        "",
        "swift:AudioLengthTests/testAnUnavailableOverlayDoesNotRESETTheLengthToTheFallback",
        "treating a DENIED overlay read as 'no configuration' and discarding a valid disk value — "
        "the denial is the normal path for this device's identity",
    ),

    # --- the app half's in-flight VETO (it had no in-flight check at all) -----------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                    if stableFor >= 8, !(try await isGenerating()) { return true }",
        "                    if stableFor >= 8 { return true }",
        "swift:InFlightVetoTests/testStableTextIsNOTAcceptedWhileThePlatformSaysItIsStillWorking",
        "the app half accepting settled text as the answer while the platform is still working — the "
        "measured 27-char 'Pro thinking' shape, harvested as the report",
    ),
    # NOTE: the app half's visibility RULE is deliberately not mutated here, and the reason is worth
    # keeping. Its fake page answers the in-flight probe from a flag instead of executing the probe's
    # JavaScript, so mutating that JS changes nothing the Swift tests can observe — the guard would be
    # satisfied by the test double rather than by the code, which is the exact shape this harness
    # exists to catch. The identical rule IS mutation-verified on the backend half, where the test
    # EXECUTES the JS under node (see the zero-height entry above). ⚠ That leaves the two halves in
    # parity by inspection only; a JS-executing test on the app side is the real fix.

    # --- the in-flight probe must test VISIBILITY, not presence ---------------------------------
    #
    # ⛔ Measured on a COMPLETED Gemini deep-research run: the page said "I've completed your
    # research", the 23k-char report was in the DOM, and a `Stop response` button was STILL PRESENT
    # at height 0. A selector-only check reports in-flight forever, so the wait never completes and
    # the run burns its whole timeout on a finished report — then reports a timeout, which invites
    # raising the budget for something no waiting fixes.
    (
        "emubackend/phases.py",
        "            \"  return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';\"",
        "            \"  return true;\"",
        "test_response_health.py::test_a_RETIRED_stop_control_at_zero_height_does_not_mean_generating",
        "a retired zero-height stop control read as in-flight, so every wait runs to its full "
        "timeout on a report that is already complete",
    ),

    # --- item 13: the platform flag must swap the MANIFEST too ---------------------------------
    (
        "bin/all_gates.sh",
        '      --platform "$PLATFORM" --manifest "$REPO/selectors_mobile.json"',
        '      --platform "$PLATFORM"',
        "test_coverage_gate.py::test_a_platform_argument_reaches_the_e2e_with_the_REAL_manifest",
        "a real platform run against the MOCK selectors, which fails in a way that reads as "
        "selector rot rather than as the wrong manifest",
    ),

    # --- item 18: deviceId on the research patch, the half that was still missing it -----------
    #
    # ⛔ The rule judges the resource being WRITTEN, so a patch omitting deviceId 403s even when the
    # stored doc already carries one. The app half was fixed earlier; THIS half still sent only
    # status+backendRunId — the "correction of a correction" the recipe warns about, because the
    # deviceId on the pipeline EVENT is a different write that both halves always had.
    (
        "emubackend/pipeline.py",
        '        "deviceId": ctx.device_id,\n    }',
        "    }",
        "test_pipeline.py::test_the_START_patch_carries_the_deviceId_the_rules_require",
        "every research status write 403ing, so the run dies before P0 with the document stuck on "
        "its previous status",
    ),
    (
        "emubackend/pipeline.py",
        '        ctx.client.patch(ctx.research_path, {"status": "complete", "deviceId": ctx.device_id})',
        '        ctx.client.patch(ctx.research_path, {"status": "complete"})',
        "test_pipeline.py::test_the_TERMINAL_patch_carries_the_deviceId_too",
        "a run that completes correctly and then 403s at the finish, leaving the document stuck on "
        "ongoing forever",
    ),

    # --- the plan-confirmation step, on the APP half (parity pair) ------------------------------
    #
    # ⛔ The app half is what actually runs the phases on the device, so a fix on the backend half
    # alone leaves the SHIPPING path harvesting a research plan as the report.
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                do { try await page.click(handle) } catch {}\n                return true",
        "                return true",
        "swift:PlanConfirmationTests/testThePlanControlIsPRESSEDAndNotMerelyFound",
        "the app half FINDING the plan control and walking past it, so the research never starts "
        "and the plan ships as the report",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "            try? await sleep(.milliseconds(2000))",
        "            break",
        "swift:PlanConfirmationTests/testItIsPOLLEDBecauseThePlanArrivesLate",
        "a read-once look on the app half for a control that takes tens of seconds to render",
    ),

    # --- the plan-confirmation step, found on a live run ---------------------------------------
    #
    # ⛔ Gemini's deep research does NOT start on send: it answers with a ~1,200-char research PLAN
    # and stops. Generation ends, the text is stable and plausible, so the wait completes and the
    # extractor harvests the plan — a document about what it was GOING to research, shipped as the
    # report. The control was in the schema, was never captured, and nothing ever pressed it.
    (
        "emubackend/phases.py",
        "                try:\n                    await handle.click()\n                except Exception:\n                    pass\n                return True",
        "                return True",
        "test_p2_sequential.py::TestThePlanIsConfirmedBeforeTheReportIsRead::test_the_plan_control_is_PRESSED_and_not_merely_found",
        "the plan control being FOUND and walked past, so the research never starts and the plan is "
        "harvested as the report",
    ),
    (
        "emubackend/phases.py",
        "            if time.monotonic() >= deadline:\n                return False\n            await asyncio.sleep(poll)",
        "            return False",
        "test_p2_sequential.py::TestThePlanIsConfirmedBeforeTheReportIsRead::test_it_is_POLLED_because_the_plan_arrives_late",
        "a read-once look for a control that takes tens of seconds to render, concluding the "
        "platform has no plan stage",
    ),

    # --- Gemini's P2 controls: logic that was right and unusable --------------------------------
    (
        "selectors_mobile.json",
        '"css": [\n     "button[aria-label^=\\"Open mode picker\\"]"\n    ],',
        '"css": [],',
        "test_models.py::TestGeminisControlsAreActuallyWired::test_the_model_picker_is_RESOLVABLE_so_the_family_pick_can_be_applied",
        "the family+highest-offered model pick having no control to drive on Gemini, so 'latest "
        "Flash + extended thinking' is silently never applied",
    ),
    (
        "selectors_mobile.json",
        '"opener": "button[aria-label=\\"Upload and tools\\"]"',
        '"opener": ""',
        "test_models.py::TestGeminisControlsAreActuallyWired::test_deep_research_declares_its_OPENER_and_not_only_in_prose",
        "the deep-research drawer never being tapped, so the item resolves to nothing and reads as "
        "the platform having lost deep research",
    ),

    # --- item 3: the `empty` verdict finally has consumers -------------------------------------
    #
    # ⛔ `classify_response` could always say "empty" and NOTHING asked it. The wait's guard was a
    # bare strip, which catches whitespace but not the measured shape — a speaker prefix, which is
    # non-empty and perfectly stable. It passed stability, became the brief for three deep-research
    # runs, and the harvest then reported READ DRIFT against selectors that were working.
    (
        "emubackend/phases.py",
        '                    and classify_response(text)["state"] != "empty"',
        "                    and text.strip()",
        "test_response_health.py::test_a_stable_SPEAKER_PREFIX_is_never_accepted_as_a_finished_response",
        "a speaker prefix accepted as the finished response, becoming the brief three deep-research "
        "agents are handed",
    ),
    (
        "emubackend/phases.py",
        '        if health["state"] == "empty":',
        '        if health["state"] == "never":',
        "test_response_health.py::test_harvest_REFUSES_an_empty_turn_rather_than_reporting_zero_sources",
        "an empty turn harvested as zero sources, which reads as read drift and sends the next "
        "session to repair healthy selectors",
    ),
    (
        "emubackend/phases.py",
        '                            and classify_response(last_text)["state"] == "empty"',
        "                            and not last_text.strip()",
        "test_response_health.py::test_the_timeout_reason_NAMES_the_stall_rather_than_blaming_the_clock",
        "a platform stall reported as a plain timeout, which invites a longer budget for a condition "
        "no amount of waiting fixes",
    ),

    # --- dismissal must ask the OPENER, not the target ------------------------------------------
    #
    # ⛔ The live bug, on the app half: dismissal polled "is the target still findable" as a stand-in
    # for "is the menu still open". Activating deep research CREATES a matching pill in the composer
    # and that entry is a text match with no CSS, so the proxy stayed true forever — the run's own
    # SUCCESS signal read as failure, and the phase aborted having done everything correctly.
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "            if try await popupIsOpen(openerCSS) == false { return true }",
        "            if try await optional(key) == nil { return true }",
        "swift:DismissalAsksTheOpenerTests/testDismissalSucceedsWhileTheTargetIsSTILLFINDABLE",
        "dismissal judged by the target's presence, so a menu that DID close is reported as stuck "
        "and the phase aborts after succeeding",
    ),

    # NOTE: `DocType`'s five cases are deliberately NOT mutated. Removing `brief` or `consolidated`
    # stops the test target COMPILING (other code names them), so `swift test --filter` selects
    # nothing and the harness — correctly — refuses to score it rather than reporting CAUGHT. The
    # membership is enforced by the compiler; the test that asserts it is documentation of the
    # "five, not three" decision, not a guard a mutation can break.

    # --- the owner's pipeline Settings, which the device used to ignore -------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        "        skipInitVerify: true,",
        "        skipInitVerify: false,",
        "swift:RunConfigTests/testAnAccountWithNoSettingsSkipsTheLoginWalk",
        "verification defaulting to ON — the exact configuration that declared three signed-in "
        "platforms signed out and abandoned a live run four seconds in",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        "            out.skipInitVerify = !verify",
        "            out.skipInitVerify = verify",
        "swift:RunConfigTests/testVerifyLoginsOnIsWhatTurnsTheLoginWalkBackOn",
        "reading `verifyLogins` without inverting it, so every account's login-check setting means "
        "the opposite of what the owner pressed",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        'let rawPhases = config["skippedPhases"] ?? config["skipPhases"]',
        'let rawPhases = config["skipPhases"]',
        "swift:RunConfigTests/testTheFrontendsSpellingOfSkippedPhasesIsRead",
        "reading only the backend's spelling, so a phase the owner switched off in the WEB APP "
        "runs anyway — the two halves write different key names",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        "                case .string(let phase): if let n = Int(phase) { out.skipPhases.insert(n) }",
        "                case .string: break",
        "swift:RunConfigTests/testPhasesArriveAsWireStringsAndAreStillRead",
        "dropping every skipped phase that arrived as a wire string, so the config reads as "
        "'nothing skipped' and the run does work the owner switched off",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        "        if out.skipPhases.contains(3) { out.skipPhases.insert(4) }",
        "        if out.skipPhases.contains(3) { out.skipPhases.insert(3) }",
        "swift:RunConfigTests/testSkippingThePodcastAlsoSkipsTheVideo",
        "a run with no podcast still asked for a video — the cloud films an empty document",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        '           ["short", "default", "long"].contains(length) {',
        "           !length.isEmpty {",
        "swift:RunConfigTests/testAnUnknownPodcastLengthIsRefusedRatherThanPassedOn",
        "an unrecognised length reaching P3's picker, which has no row for it — discovered at the "
        "END of a 90-minute run rather than the start",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunConfig.swift",
        "    public func runsAgent(_ platform: String) -> Bool {\n        agents[platform] ?? true",
        "    public func runsAgent(_ platform: String) -> Bool {\n        agents[platform] ?? false",
        "swift:RunConfigTests/testAnAbsentAgentRunsRatherThanSilentlyDisappearing",
        "an absent agent key reading as OFF, so a settings-less account runs no agents at all",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        let platforms = entry.config.enabledPlatforms",
        "        let platforms = Prompts.p2Platforms",
        "swift:RunExecutorNotebookPhaseTests/testAnAgentSwitchedOffInSettingsIsNeverDriven",
        "driving an agent the owner switched off — a deep-research unit out of a hard monthly cap, "
        "spent answering a question they said they did not want",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        '            steps.append("agent-off:\\(platform)")\n            try? await emitter.patchResearch(\n                ["agents.\\(platform)": .map(["status": .string("skipped")])]',
        '            steps.append("agent-off:\\(platform)")\n            try? await emitter.patchResearch(\n                ["agents.\\(platform)": .map(["status": .string("running")])]',
        "swift:RunExecutorNotebookPhaseTests/testASwitchedOffAgentIsReportedAsSkippedRatherThanLeftSilent",
        "a switched-off agent announced as RUNNING, so its row spins for ever on work that will "
        "never start",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        guard !entry.config.skipPhases.contains(3) else {",
        "        guard !entry.config.skipPhases.contains(99) else {",
        "swift:RunExecutorNotebookPhaseTests/testThePodcastIsNotBuiltWhenTheOwnerTurnedItOff",
        "building a podcast the owner switched off, and emitting the phase-3 events the frontend "
        "drives P4 from",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppRunPipeline.swift",
        "        case 0: return config.skipInitVerify\n        case 1: return config.skipPhases.contains(1)",
        "        case 0: return config.skipInitVerify\n        case 1: return config.skipPhases.contains(1)\n        case 3: return config.skipPhases.contains(3)",
        "swift:InAppRunPipelineSettingsTests/testTurningThePodcastOffDoesNotDeleteTheSourceHarvest",
        "the two phase numberings mapped by equality, so 'no podcast' (product phase 3) silently "
        "deletes the SOURCE HARVEST (pipeline phase 3) on every platform",
    ),

    # --- the readiness gate: the fix for the run that died in four seconds ----------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "            if WebAutomationBridge.isLoaded(\n                readyState: readyState, href: href, bodyChildren: children\n            ) {",
        "            if true {",
        "swift:PageReadinessTests/testABlankWebViewIsNotMistakenForALoadedOne",
        "treating any web view as loaded — including the about:blank one the app hands over "
        "microseconds after calling load(), which is how the original failure happened",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        '                if try await optional("composer") != nil { return .ready }',
        "                return .ready",
        "swift:PageReadinessTests/testALoadedPageWhoseComposerHasNotHydratedIsNotReady",
        "passing the gate on a splash shell whose composer has not hydrated — readyState is "
        "complete and #prompt-textarea does not exist, so P1 types into nothing",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                if let reason = try? await page.evaluateJSON(WAIT_INTERRUPTION_JS) as? String,\n                   !reason.isEmpty {\n                    return .signedOut(reason)\n                }",
        "                _ = 0",
        "swift:PageReadinessTests/testAVisibleSignInControlEndsTheWaitImmediately",
        "waiting the full timeout on a page that has already said it is signed out — four and a "
        "half minutes across three platforms to learn what the page stated at once",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        switch try await driver.awaitPageReady(timeout: pageReadyTimeout, sleep: sleep) {\n        case .ready:\n            break",
        "        switch InAppPhaseDriver.PageReadiness.ready {\n        case .ready:\n            break",
        "swift:PageReadinessTests/testTheRunRefusesToDrivePageThatNeverLoaded",
        "removing the gate entirely — the run drives a page that never loaded, which is the "
        "production failure this whole change exists to end",
    ),

    # --- a run that produced nothing must SAY so ------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        '            "status": .string("stopped"),\n            "lastError": .string(reason),',
        '            "status": .string("ongoing"),\n            "lastError": .string(reason),',
        "swift:RunExecutorNotebookPhaseTests/testARunWhereEveryAgentFailsIsMarkedStoppedRatherThanLeftOngoing",
        "a dead run left `ongoing` for ever — the web app shows it live at phase 1 all day, which "
        "is exactly what the owner watched happen",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "                reason: platforms.isEmpty\n                    ? \"no agents are enabled in Settings, so there was nothing to run\"\n                    : \"every enabled agent failed to produce a report\"",
        '                reason: "every enabled agent failed to produce a report"',
        "swift:RunExecutorNotebookPhaseTests/testARunWithNoAgentsEnabledSaysThatRatherThanBlamingTheAgents",
        "blaming the agents for a run the owner configured to have none — sending them to debug a "
        "failure that never happened",
    ),

    # --- the composer fill: the status nobody read ----------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/WebAutomation.swift",
        '        guard let ok = result["ok"] as? Bool, ok else {',
        "        guard true else {",
        "swift:TextEntryVerificationTests/testARefusedInsertIsNOTReportedAsSuccess",
        "the execCommand refusal being discarded again — an empty composer reported as a successful "
        "fill, and the run dying at `send` on a selector that was never wrong",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/WebAutomation.swift",
        '        if let err = result["err"] as? String, result["ok"] == nil {',
        '        if let err = result["err"] as? String, result["ok"] != nil {',
        "swift:TextEntryVerificationTests/testANonTextTargetKeepsItsOwnSentinel",
        "a structural miss and an editor refusal collapsing into one message, so the caller cannot "
        "tell 'this is not a text field' from 'the editor would not take it'",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        '              !path.hasPrefix("refused"), !path.hasPrefix("no-caret") else {',
        '              !path.hasPrefix("no-caret") else {',
        "swift:TextEntryVerificationTests/testAComposerThatREFUSEDTheTextFailsAtTheCOMPOSER",
        "the exact guard that shipped: a refusal passing the fill check, so the composer is empty "
        "and the failure surfaces three steps later at send",
    ),

    # --- the owner's Stop, which reached nothing -------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "            if shouldStop() { throw InAppPhaseError.stoppedByOwner(platform: platform) }",
        "            if false { throw InAppPhaseError.stoppedByOwner(platform: platform) }",
        "swift:RunStopTests/testAStopDuringTheLongResponseWaitEndsIt",
        "Stop ignored inside the 40-minute response wait — the owner presses Stop and watches the "
        "worker stay busy for the rest of the hour",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunStopSignal.swift",
        "        lock.lock(); stopped.insert(researchID); lock.unlock()",
        "        lock.lock(); lock.unlock()",
        "swift:RunStopTests/testAStopIsRememberedForTheResearchItNames",
        "a Stop that is accepted and forgotten — the button appears to work and nothing stops",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunStopSignal.swift",
        "        lock.lock(); stopped.remove(researchID); lock.unlock()",
        "        lock.lock(); stopped.insert(researchID); lock.unlock()",
        "swift:RunStopTests/testAStoppedResearchCanBeRunAgain",
        "a stopped research staying stopped for ever, so every retry of it ends instantly and looks "
        "like intake never claimed it",
    ),

    # --- whose run is it -------------------------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "        if facts[worker] != nil { facts[worker]?.phase = phase }",
        "        facts[worker] = facts[worker] ?? RunFacts(uid: \"\", title: \"\", phase: phase)",
        "swift:RunAttributionTests/testAPhaseUpdateForAWorkerWithNoRunCreatesNothing",
        "a phase update inventing a run, so a busy pill appears for a run that is not happening",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/LiveRunActivity.swift",
        "        facts.removeValue(forKey: worker)",
        "        _ = facts[worker]",
        "swift:RunAttributionTests/testARunThatENDEDLeavesNoPillBehind",
        "a finished run leaving its pill on someone's tile for ever — and the web app counting it "
        "as occupied capacity",
    ),

    # --- the device's own busy set ---------------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            await self?.reconcileBusyWorkers()\n            while !Task.isCancelled {",
        "            while !Task.isCancelled {",
        "swift:DeviceBackendBehaviourTests/testStartingToServePublishesAnEmptyBusySetOnAnIdleDevice",
        "a worker wedged by a killed run staying busy for ever — every later claim declined "
        "silently, because declining is also what a genuinely busy device does",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "        locallyBusy.sorted().map { FirestoreValue.integer(Int64($0)) }",
        "        []",
        "swift:RunPlacementTests/testAWorkerRunningSomethingIsStillPublishedAsBusy",
        "publishing an EMPTY busy set while a run is in flight — the reset path then hands a second "
        "run to the worker already driving one",
    ),

    # --- one press, one bounce -------------------------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/DeviceBackend.swift",
        "            if seenDeviceCommands.contains(doc.id) {",
        "            if false {",
        "swift:DeviceBackendBehaviourTests/testACommandIsRunONCEEvenWhenTheAckNeverLands",
        "one Online-pill press bouncing the device repeatedly — every bounce restarts the loop that "
        "re-reads the command, and only the 30s staleness window ever stops it",
    ),


    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        "        if phase2Started { await announce(phase: 2, starting: false) }\n\n        guard !reports.isEmpty else {",
        "        await announce(phase: 2, starting: false)\n\n        guard !reports.isEmpty else {",
        "swift:RunExecutorNotebookPhaseTests/testAFAILEDRunDoesNotAnnounceAPhaseItNeverSTARTED",
        "announcing phase 2 COMPLETE on a run that never reached phase 1 — the web app reports work "
        "finished that never began, which is what the owner saw",
    ),

    (
        "ios/Sources/SuperResearchDeviceCore/NotebookStage.swift",
        '        activity.set(worker: worker, platform: "notebooklm")',
        "        _ = worker",
        "swift:NotebookStageActivityTests/testNOTEBOOKLMGlowsForTheWholeOfP3AndIsClearedWhenItEnds",
        "Browser watch going dark for the whole of phase 3 — the longest stretch of a run, and the "
        "one the owner most wants to watch",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/NotebookStage.swift",
        '        activity.set(worker: worker, platform: "notebooklm")\n        defer { activity.clear(worker: worker) }',
        '        activity.set(worker: worker, platform: "notebooklm")',
        "swift:NotebookStageActivityTests/testNOTEBOOKLMGlowsForTheWholeOfP3AndIsClearedWhenItEnds",
        "a P3 glow that outlives its phase, pointing the owner at a NotebookLM tab where nothing is "
        "happening — and never changing, which is indistinguishable from still working",
    ),

    # --- a caret is not the same thing as focus ---------------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/WebAutomation.swift",
        '            let kind = (result["path"] as? String) == "no-caret" ? "no-caret" : "refused"',
        '            let kind = "refused"',
        "swift:TextEntryVerificationTests/testAMissingCARETIsReportedAsItsOwnFaultNotAsARefusal",
        "collapsing 'no range inside an editable root' into 'the editor refused the text' — two "
        "different faults with two different fixes, reported identically, which is what made the "
        "live measurement ambiguous once focus was already proven good",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        '              !path.hasPrefix("refused"), !path.hasPrefix("no-caret") else {',
        '              !path.hasPrefix("refused") else {',
        "swift:TextEntryVerificationTests/testANoCaretFillFailsAtTheComposerToo",
        "a fill that placed no caret sailing through as SUCCESS because its verdict happens not to "
        "be the word 'refused' — an empty composer certified as filled, again",
    ),
    (
        "emubackend/substrate/runtime_js.py",
        "        var target = (collapse && el.lastElementChild) ? el.lastElementChild : el;",
        "        var target = el;",
        "test_backend_contract.py::test_runtime_places_the_caret_in_the_last_block",
        "collapsing the caret on the composer ROOT instead of inside its block — a position between "
        "block children, which ProseMirror normalises away before the edit lands",
    ),

    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        try await clearBlockingOverlay(composer)\n        let path = try await page.insertText(composer, text)",
        "        let path = try await page.insertText(composer, text)",
        "swift:TextEntryVerificationTests/testTheComposerIsUNBLOCKEDBeforeTheTextIsTyped",
        "typing into a composer that a modal has made inert — focus() no-ops, every synthetic event "
        "is dropped, and the failure points at the editor instead of the dialog on top of it",
    ),

    # --- what made a meaningless run look successful ---------------------------------------------
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "                if !outcome.brief.isEmpty, Self.isSameText(report, as: outcome.brief) {",
        "                if false {",
        "swift:MeaninglessSuccessTests/testTheRunREFUSESAReportThatIsJustTheBrief",
        "P2 shipping the turn P1 already produced — the run writes its documents, hands off, and the "
        "cloud builds a podcast out of the brief, all reporting success",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        "        guard abs(a.count - b.count) <= max(8, min(a.count, b.count) / 100) else { return false }",
        "        guard true else { return false }",
        "swift:MeaninglessSuccessTests/testAGENUINEReportIsNotMistakenForTheBrief",
        "a real report rejected as a duplicate because it opens by restating the brief's title — "
        "killing healthy runs to catch a broken one",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift",
        '        case "claude": return ["Claude"]',
        '        case "claude": return ["Claude", "The paper"]',
        "swift:MeaninglessSuccessTests/testOnlyALabelAtTheVERYSTARTIsRemoved",
        "a speaker-label rule loose enough to edit the research itself — the first version stripped "
        "'The paper said:' from the opening of a report",
    ),
    (
        "ios/Sources/SuperResearchDeviceCore/RunExecutor.swift",
        '                if brief.isEmpty, !out.brief.isEmpty, platform == Self.briefPlatform {',
        "                if brief.isEmpty, !out.brief.isEmpty {",
        "swift:RunExecutorNotebookPhaseTests/testTheBRIEFComesFromChatGPTAndNotWhoeverFinishesFirst",
        "a blocked ChatGPT silently promoting another platform to brief writer — a different model "
        "answering a different prompt contract, with nothing in the run saying so",
    ),
]


#: How long one guard may take before the harness stops waiting.
#:
#: ⛔ **This existed as no limit at all, and a mutant found out.** Replacing the empty-chunk guard in
#: the audio download with one that always passes does not make an assertion FAIL — it makes the read
#: loop advance by zero bytes for ever. The harness sat on a single `xctest` for **31 minutes** with
#: no output, which is indistinguishable from slow progress, and the whole wave stalled behind it.
#:
#: ⚠ A timeout is reported as its own outcome, NOT as "caught". A hang is not a guard doing its job:
#: in CI it is a job that never finishes, and the fix is to choose a mutation that fails rather than
#: one that diverges — see the `break`-instead-of-`throw` mutation in the download loop.
RUN_TIMEOUT_S = 600


class Hung(RuntimeError):
    """A guard did not finish inside :data:`RUN_TIMEOUT_S`."""


try:  # pytest-timeout is optional; without it a hanging pytest node is still bounded by the caller
    import pytest_timeout as _pytest_timeout  # noqa: F401
    _HAS_PYTEST_TIMEOUT = True
except Exception:
    _HAS_PYTEST_TIMEOUT = False


def run(node: str) -> bool:
    """True if the test PASSES.

    Two runners, chosen by prefix. A `swift:` node runs `swift test --filter` in `ios/`; anything
    else is a pytest node id under `emubackend/tests/`.

    ⚠ The Swift runner is not a convenience. Every Swift-source mutation here used to be verified by
    a *Python* test that reads the Swift file as text — which proves the string changed, not that
    any Swift assertion depends on it. A guard written in XCTest can only be shown to fail by
    running XCTest, so mutating Swift and checking pytest would be exactly the decorative-guard
    shape this harness exists to catch.
    """
    if node.startswith("swift:"):
        try:
            p = subprocess.run(
                ["swift", "test", "--filter", node[len("swift:"):]],
                cwd=ROOT / "ios",
                capture_output=True,
                text=True,
                timeout=RUN_TIMEOUT_S,
                env={"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": str(Path.home())},
            )
        except subprocess.TimeoutExpired:
            raise Hung(node) from None
        # `--filter` matching nothing still exits 0, so a typo'd filter would report every mutation
        # CAUGHT while running no assertions at all. Demand evidence that tests actually executed.
        if "Executed 0 tests" in p.stdout or "Executed" not in p.stdout:
            # ⚠ Two causes, and the message must name both. "No tests ran" is a typo'd filter;
            # but a mutant that TRAPS (a Swift precondition, an overflow) kills the xctest process
            # before it can print a result, which lands here looking identical. A trap is arguably
            # detection, but it is not a guard FAILING, and scoring it as caught would let a
            # mutation that crashes stand in for one the assertion actually rejects.
            raise SystemExit(
                f"swift --filter {node[len('swift:'):]!r} produced no test results — either the "
                f"filter matched nothing, or the mutant CRASHED the test process (a trap prints no "
                f"'Executed' line). Pick a mutation that makes the assertion fail rather than one "
                f"that traps.\n--- stderr ---\n{p.stderr[-1500:]}"
            )
        return p.returncode == 0

    p = subprocess.run(
        [str(PY), "-m", "pytest", f"emubackend/tests/{node}", "-q", "--no-header",
         "--timeout", str(RUN_TIMEOUT_S)] if _HAS_PYTEST_TIMEOUT else
        [str(PY), "-m", "pytest", f"emubackend/tests/{node}", "-q", "--no-header"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        env={
            "PYTHONPATH": ".",
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            # ⚠ Load-bearing. Python invalidates a cached .pyc on (mtime, size), and a
            # same-LENGTH mutation ("max" -> "min") restores to an identical size. If the
            # restore lands in the same mtime granule, the stale bytecode for the MUTATED
            # source keeps being imported — so the mutation looks uncaught AND the clean
            # verification run silently tests the mutant too. Both mutations reported MISSED
            # in this harness's first run were this, not a test gap.
            "PYTHONDONTWRITEBYTECODE": "1",
        },
    )
    # ⚠ **A skipped test exits 0, and 0 is "passed".**
    #
    # The Swift branch above already demands evidence that tests executed; the pytest branch did
    # not, and it cost exactly what you would expect. A probe test called `shutil.which("node")`
    # and skipped when it came back empty — which it always does here, because this function pins
    # `PATH` to three directories that do not contain node. So the test skipped, pytest exited 0,
    # `run()` said "passed", and the harness recorded the mutation as CAUGHT while no assertion had
    # run in either direction. The guard reported as present and protected nothing.
    #
    # So: a selection that ran no test, or ran only skipped ones, is not a result. Refuse.
    tail = (p.stdout or "") + (p.stderr or "")
    if "no tests ran" in tail or ("skipped" in tail and " passed" not in tail
                                  and " failed" not in tail):
        raise SystemExit(
            f"pytest node {node!r} ran no assertions (skipped or deselected) — the mutation "
            f"result would be meaningless. Output:\n{tail[-800:]}"
        )
    return p.returncode == 0


def probe_forbidden_call_detector(failures: list[str]) -> None:
    """Positive fixture: plant a real forbidden call and prove the scanner finds it.

    The other mutations break the guard and check the test notices. This one is the
    inverse and the more important direction for a static scanner: a scanner that finds
    nothing looks identical to a clean repo.
    """
    node = "test_a8_purity.py::test_no_forbidden_be_calls_anywhere_in_this_repo"
    probe = ROOT / "emubackend" / "_mutation_probe.py"
    assert not probe.exists(), "probe file already present — refusing to clobber"
    try:
        probe.write_text(
            "def _never_called():\n"
            "    # A real ast.Call node to the banned symbol.\n"
            "    return setup_firestore_run('topic')  # noqa: F821\n"
        )
        caught = not run(node)
    finally:
        probe.unlink()
    clean = run(node)
    status = "CAUGHT " if (caught and clean) else "MISSED "
    if status == "MISSED ":
        failures.append(f"{status}{node} (planted_call_detected={caught} clean_passed={clean})")
    print(f"{status} {node}\n          simulates: our own code calling setup_firestore_run()")


def probe_app_layer_boundary(failures: list[str]) -> None:
    """Positive fixture: plant a pure-logic file in `ios/App` and prove the boundary test finds it.

    Same inverse direction as `probe_forbidden_call_detector`, and for the same reason. The guard
    scans a directory; a scan that finds nothing is indistinguishable from a clean directory. And the
    defect it guards against is one this repo actually shipped — the whole device model layer sat in
    `ios/App` behind an `import SwiftUI` where `swift test` compiled none of it, while the suite
    reported 104 green tests.
    """
    node = "swift:AppLayerBoundaryTests/testEveryFileInTheAppDirectoryIsAView"
    probe = ROOT / "ios" / "App" / "_MutationProbe.swift"
    assert not probe.exists(), "probe file already present — refusing to clobber"
    try:
        # Foundation only: this is precisely the shape that must not be allowed to hide here.
        probe.write_text(
            "import Foundation\n\n"
            "/// Planted by bin/mutate.py. Pure logic, no UI framework — the boundary test must "
            "flag it.\n"
            "enum _MutationProbe { static let untestedLogic = 1 }\n"
        )
        caught = not run(node)
    finally:
        probe.unlink()
    clean = run(node)
    status = "CAUGHT " if (caught and clean) else "MISSED "
    if status == "MISSED ":
        failures.append(f"{status}{node} (planted_file_detected={caught} clean_passed={clean})")
    print(f"{status} {node}\n          simulates: pure logic living in ios/App, where NOTHING "
          f"compiles it under swift test")


def _purge_bytecode() -> None:
    """Remove stale __pycache__ trees before starting.

    PYTHONDONTWRITEBYTECODE stops NEW caches being written, but a cache left by an ordinary
    test run beforehand can still shadow a restored file for the same (mtime, size) reason.
    """
    import shutil

    for cache in ROOT.rglob("__pycache__"):
        if ".venv" not in cache.parts:
            shutil.rmtree(cache, ignore_errors=True)


def main() -> int:
    _purge_bytecode()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _on_signal)
    # `--only <substring>` runs the subset whose guard node matches, for iterating on a new wave
    # without paying for the whole corpus.
    #
    # ⛔ It NEVER becomes the default and the summary line says how many ran, because a filter left
    # on by accident is a harness that reports "all mutations caught" having run three of them.
    only = ""
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    selected = [m for m in MUTATIONS if not only or only in m[3]]
    if only and not selected:
        print(f"--only {only!r} matched no guard node — nothing would have been verified")
        return 1
    failures = []
    for rel, old, new, node, defect in selected:
        path = ROOT / rel
        original = path.read_bytes()
        digest = hashlib.sha256(original).hexdigest()
        text = original.decode()
        if text.count(old) != 1:
            failures.append(f"ANCHOR MISS  {rel}: {text.count(old)}x {old!r}")
            continue
        hung = False
        passed_mutated = True
        try:
            _IN_FLIGHT[path] = original
            path.write_text(text.replace(old, new))
            passed_mutated = run(node)
        except Hung:
            hung = True
        finally:
            path.write_bytes(original)
            _IN_FLIGHT.pop(path, None)
            assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, "restore failed"
        if hung:
            failures.append(
                f"HUNG    {node}  (the mutant did not FAIL, it never finished — pick a mutation "
                f"that breaks the assertion rather than one that loops)"
            )
            print(f"HUNG    {node}\n          simulates: {defect}")
            continue
        passed_clean = run(node)
        status = "CAUGHT " if (not passed_mutated and passed_clean) else "MISSED "
        if status == "MISSED ":
            failures.append(
                f"{status}{node}  (mutated_passed={passed_mutated} clean_passed={passed_clean})"
            )
        print(f"{status} {node}\n          simulates: {defect}")
    probe_forbidden_call_detector(failures)
    probe_app_layer_boundary(failures)
    print()
    if failures:
        print("PROBLEMS:")
        for f in failures:
            print("  " + f)
        return 1
    scope = f" matching {only!r}" if only else ""
    print(
        f"All {len(selected)} of {len(MUTATIONS)} mutations{scope} caught; all sources restored "
        f"byte-identically."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
