import XCTest

@testable import SuperResearchDeviceCore

/// Workers are browser profiles, and the two properties worth pinning are the ones a count cannot
/// see: that a profile keeps its **cookie jar identity** across launches, and that the device reports
/// `logins` as the intersection rather than the union.
final class WorkerProfileTests: XCTestCase {

    /// Deterministic ids so a test can assert *which* jar a worker got, not merely that it got one.
    private func counter(start: Int = 1) -> () -> UUID {
        var n = start
        return {
            defer { n += 1 }
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        }
    }

    // MARK: - Existence

    func testADeviceAlwaysStartsWithExactlyOneWorker() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.workers.map(\.id), [1])
    }

    func testAddingWorkersProducesContiguousOneBasedIDs() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        let make = counter(start: 100)
        registry.addWorker(makeID: make)
        registry.addWorker(makeID: make)
        XCTAssertEqual(registry.workers.map(\.id), [1, 2, 3],
                       "the device-doc contract keys workers by contiguous 1-based ordinals")
    }

    func testEachWorkerGetsItsOwnCookieJarIdentity() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.addWorker(makeID: counter(start: 50))
        let ids = registry.workers.map(\.storeID)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "two workers sharing a store identity share a cookie jar, which is the whole "
                       + "thing multi-worker exists to avoid")
    }

    // MARK: - The property a count cannot see

    func testAWorkerKeepsItsCookieJarAcrossRelaunch() {
        let storage = InMemoryWorkerStorage()
        let first = WorkerRegistry(storage: storage, makeID: counter())
        first.addWorker(makeID: counter(start: 200))
        let before = first.workers.map(\.storeID)

        // A fresh registry over the same storage is exactly what a relaunch is.
        let second = WorkerRegistry(storage: storage, makeID: counter(start: 900))
        XCTAssertEqual(
            second.workers.map(\.storeID), before,
            "a regenerated store identifier points WebKit at a different jar on disk, which signs "
            + "the worker out of every platform with nothing in any log to explain it"
        )
    }

    func testANewWorkerIsSignedInToNothingRatherThanInheriting() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.setLogin(worker: 1, platform: "chatgpt", signedIn: true)
        let added = registry.addWorker(makeID: counter(start: 300))
        XCTAssertEqual(added.logins, [:], "a fresh jar has no cookies; it cannot inherit a session")
    }

    // MARK: - Removal keeps the ordinals honest

    func testTheOnlyWorkerCannotBeRemoved() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        XCTAssertEqual(registry.removeLastWorker(busyWorkerIDs: []), .lastRemainingWorker)
        XCTAssertEqual(registry.count, 1)
    }

    func testABusyWorkerIsNotRemoved() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.addWorker(makeID: counter(start: 400))
        XCTAssertEqual(registry.removeLastWorker(busyWorkerIDs: [2]), .busy(id: 2))
        XCTAssertEqual(registry.count, 2, "the run assigned to worker 2 is still in flight")
    }

    func testRemovingFromTheMiddleIsRefusedSoOrdinalsAreNeverRenumbered() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        let make = counter(start: 500)
        registry.addWorker(makeID: make)
        registry.addWorker(makeID: make)
        XCTAssertEqual(registry.removalRefusal(for: 2, busyWorkerIDs: []),
                       .notTheLastWorker(highest: 3))
    }

    func testRemovingTheIdleLastWorkerSucceedsAndPersists() {
        let storage = InMemoryWorkerStorage()
        let registry = WorkerRegistry(storage: storage, makeID: counter())
        registry.addWorker(makeID: counter(start: 600))
        XCTAssertNil(registry.removeLastWorker(busyWorkerIDs: [1]))
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(WorkerRegistry(storage: storage, makeID: counter(start: 700)).count, 1,
                       "the removal must survive a relaunch, not just the current process")
    }

    func testTheNextWorkerAfterARemovalReusesTheFreedOrdinal() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        let make = counter(start: 800)
        registry.addWorker(makeID: make)
        XCTAssertNil(registry.removeLastWorker(busyWorkerIDs: []))
        XCTAssertEqual(registry.addWorker(makeID: make).id, 2,
                       "ids stay contiguous; a gap would break the backend's 1...workerCount padding")
    }

    // MARK: - ⭐ Intersection, not union

    func testAPlatformSignedInOnOnlyOneOfTwoWorkersIsReportedSignedOut() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.addWorker(makeID: counter(start: 900))
        registry.setLogin(worker: 1, platform: "chatgpt", signedIn: true)
        registry.setLogin(worker: 2, platform: "chatgpt", signedIn: false)
        XCTAssertEqual(
            registry.deviceLogins()["chatgpt"], false,
            "a union would advertise the device ready for a run the backend may hand to worker 2, "
            + "which has no ChatGPT cookie — the failure would surface phases later as a login wall"
        )
    }

    func testAPlatformSignedInOnEveryWorkerIsReportedSignedIn() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.addWorker(makeID: counter(start: 1000))
        registry.setLogin(worker: 1, platform: "gemini", signedIn: true)
        registry.setLogin(worker: 2, platform: "gemini", signedIn: true)
        XCTAssertEqual(registry.deviceLogins()["gemini"], true)
    }

    func testAPlatformNotYetCheckedOnOneWorkerIsOmittedRatherThanCalledSignedOut() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.addWorker(makeID: counter(start: 1100))
        registry.setLogin(worker: 1, platform: "claude", signedIn: true)
        // worker 2 has never been checked for claude
        XCTAssertNil(
            registry.deviceLogins()["claude"],
            "omitted means 'nobody checked', which the UI renders as 'not checked'. Reporting false "
            + "here sends the owner to redo a login that may already be fine."
        )
    }

    func testAnUncheckedWorkerDoesNotMaskAMeasuredSignedOut() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        let make = counter(start: 1200)
        registry.addWorker(makeID: make)
        registry.addWorker(makeID: make)
        registry.setLogin(worker: 1, platform: "notebooklm", signedIn: true)
        registry.setLogin(worker: 2, platform: "notebooklm", signedIn: false)
        // worker 3 never checked — but a measured false is already decisive.
        XCTAssertEqual(registry.deviceLogins()["notebooklm"], false)
    }

    func testAPlatformNoWorkerHasEverSeenIsAbsentEntirely() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        XCTAssertEqual(registry.deviceLogins(), [:])
    }

    // MARK: - Persistence of the login record itself

    func testMeasuredLoginsSurviveARelaunch() {
        let storage = InMemoryWorkerStorage()
        let first = WorkerRegistry(storage: storage, makeID: counter())
        first.setLogin(worker: 1, platform: "chatgpt", signedIn: true)
        let second = WorkerRegistry(storage: storage, makeID: counter(start: 1300))
        XCTAssertEqual(second.deviceLogins()["chatgpt"], true)
    }

    func testSettingALoginForAWorkerThatDoesNotExistIsIgnored() {
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage(), makeID: counter())
        registry.setLogin(worker: 99, platform: "chatgpt", signedIn: true)
        XCTAssertEqual(registry.deviceLogins(), [:])
    }
}


/// The Browser-watch strip's state rule.
///
/// ⚠ The owner asked to watch **every** worker's state at once. The card previously rendered a MENU,
/// shown only when there was more than one worker — so it could not answer "what is each worker
/// doing right now" without tapping through them, and a device that had just gained a second worker
/// showed no sign of it here.
final class WorkerActivityTests: XCTestCase {

    func testABusyWorkerReadsBusy() {
        XCTAssertEqual(WorkerActivity.of(1, busy: [1], resting: []), .busy)
    }

    func testAParkedWorkerReadsResting() {
        XCTAssertEqual(WorkerActivity.of(2, busy: [], resting: [2]), .resting)
    }

    func testAFreeWorkerReadsIdle() {
        XCTAssertEqual(WorkerActivity.of(3, busy: [1], resting: [2]), .idle)
    }

    /// ⭐ The precedence, and the only case where the two sets disagree.
    ///
    /// Parking a worker mid-run does NOT stop that run — it stops the worker being handed the next
    /// one. Reporting "resting" here would tell the owner their work had stopped when it had not.
    /// Asserted explicitly rather than falling out of statement order, because statement order is
    /// exactly what a refactor reorders.
    func testBusyBeatsRestingWhenAWorkerIsParkedMidRun() {
        XCTAssertEqual(WorkerActivity.of(1, busy: [1], resting: [1]), .busy,
                       "a worker parked mid-run is still running that run")
    }

    /// Every worker resolves to exactly one state — no id can be left unclassified.
    func testEveryWorkerGetsExactlyOneState() {
        for id in 1...4 {
            let state = WorkerActivity.of(id, busy: [1, 2], resting: [2, 3])
            XCTAssertTrue([.busy, .resting, .idle].contains(state))
        }
        XCTAssertEqual(WorkerActivity.of(2, busy: [1, 2], resting: [2, 3]), .busy)
        XCTAssertEqual(WorkerActivity.of(3, busy: [1, 2], resting: [2, 3]), .resting)
        XCTAssertEqual(WorkerActivity.of(4, busy: [1, 2], resting: [2, 3]), .idle)
    }
}
