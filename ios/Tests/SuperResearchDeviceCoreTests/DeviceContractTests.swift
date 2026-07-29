import XCTest
@testable import SuperResearchDeviceCore

/// The write shapes, pinned. These mirror the Python `test_contract_core.py` assertions so both
/// implementations of the same contract are held to identical rules.
final class DeviceContractTests: XCTestCase {

    // MARK: - The heartbeat, which is also the pair-confirm

    func testTheHeartbeatSetsPairConfirmedAndDeletesExpireAt() {
        let hb = DeviceContract.Heartbeat(lastHeartbeatMillis: 1_785_319_607_000)
        XCTAssertEqual(hb.fieldsToSet["pairConfirmedAt"] as? Bool, true)
        XCTAssertEqual(hb.fieldsToSet["status"] as? String, "active")
        XCTAssertEqual(hb.fieldsToDelete, ["expireAt"])
        XCTAssertNil(
            hb.fieldsToSet["expireAt"],
            "expireAt must be DELETED, never set — a null write leaves the TTL armed while "
                + "reporting success, and the document then disappears on schedule"
        )
    }

    func testPairConfirmedAtIsABooleanDespiteItsName() {
        let hb = DeviceContract.Heartbeat(lastHeartbeatMillis: 1)
        XCTAssertTrue(hb.fieldsToSet["pairConfirmedAt"] is Bool)
        XCTAssertFalse(hb.fieldsToSet["pairConfirmedAt"] is Date)
    }

    func testLastHeartbeatIsAnIntegerNotADate() {
        // The frontend computes `Date.now() - lastHeartbeat` directly, so a Timestamp breaks the
        // offline calculation rather than merely being a different encoding.
        let hb = DeviceContract.Heartbeat(lastHeartbeatMillis: 1_785_319_607_000)
        XCTAssertTrue(hb.fieldsToSet["lastHeartbeat"] is Int64)
        XCTAssertFalse(hb.fieldsToSet["lastHeartbeat"] is Date)
    }

    func testTheHeartbeatSatisfiesTheSynthRule() {
        let hb = DeviceContract.Heartbeat(lastHeartbeatMillis: 1, workerCount: 2)
        XCTAssertTrue(hb.satisfiesSynthRule, "every touched key must be in the synth allow-list")
        XCTAssertEqual(
            hb.touchedKeys,
            ["lastHeartbeat", "status", "pairConfirmedAt", "workerCount", "expireAt"]
        )
    }

    func testWorkerCountIsOmittedWhenNotProvided() {
        let hb = DeviceContract.Heartbeat(lastHeartbeatMillis: 1)
        XCTAssertNil(hb.fieldsToSet["workerCount"])
    }

    func testAnOwnerOnlyFieldWouldFailTheSynthRule() {
        // The rules are ORed and each carries its own hasOnly() list, so mixing lists satisfies
        // NEITHER and the whole write is rejected — including the parts that were fine.
        XCTAssertFalse(DeviceContract.synthWritableKeys.contains("name"))
        XCTAssertTrue(DeviceContract.ownerOnlyKeys.contains("name"))
        XCTAssertTrue(
            DeviceContract.synthWritableKeys.isDisjoint(
                with: DeviceContract.ownerOnlyKeys.subtracting(["supervised"])
            ),
            "only `supervised` legitimately appears in both branches"
        )
    }

    func testThePairConfirmDeadlineIsFiveMinutes() {
        XCTAssertEqual(DeviceContract.pairConfirmDeadline, 300)
    }

    // MARK: - pipeline_events omission rules

    private func event(phase: Int? = nil, agent: String? = nil, data: [String: Any]? = nil)
        -> [String: Any]
    {
        DeviceContract.PipelineEvent(
            type: "phase_start",
            timestampMillis: 1_785_319_607_000,
            seq: 1_785_319_607_000,
            deviceId: "dev-1",
            expireAt: Date(timeIntervalSince1970: 0),
            phase: phase,
            agent: agent,
            data: data
        ).document
    }

    func testPhaseZeroIsWrittenBecauseTheGuardIsNonNilNotTruthy() {
        XCTAssertEqual(event(phase: 0)["phase"] as? Int, 0, "P0 is a real phase")
        XCTAssertNil(event()["phase"])
        XCTAssertEqual(event(phase: 3)["phase"] as? Int, 3)
    }

    func testAnEmptyAgentIsOmittedAndARealOneIsNotLowercased() {
        XCTAssertNil(event(agent: "")["agent"])
        XCTAssertNil(event()["agent"])
        XCTAssertEqual(event(agent: "ChatGPT")["agent"] as? String, "ChatGPT")
    }

    func testEmptyDataIsOmittedEntirely() {
        XCTAssertNil(event(data: [:])["data"])
        XCTAssertNil(event()["data"])
        XCTAssertNotNil(event(data: ["k": "v"])["data"])
    }

    func testDeviceIdIsTopLevelNotNestedInData() {
        let doc = event(data: ["k": "v"])
        XCTAssertEqual(doc["deviceId"] as? String, "dev-1")
        let data = doc["data"] as? [String: Any]
        XCTAssertNil(data?["deviceId"], "the device branch of the rule reads the TOP-LEVEL field")
    }

    func testTimestampAndSeqAreIntegers() {
        let doc = event()
        XCTAssertTrue(doc["timestamp"] is Int64, "a Timestamp fails the rule's `is number` check")
        XCTAssertTrue(doc["seq"] is Int64)
    }

    // MARK: - seq

    func testTwoEventsInTheSameMillisecondStillDiffer() {
        let gen = DeviceContract.SeqGenerator()
        XCTAssertEqual(gen.next(nowMillis: 1000), 1000)
        XCTAssertEqual(gen.next(nowMillis: 1000), 1001)
        XCTAssertEqual(gen.next(nowMillis: 1000), 1002)
    }

    func testABackwardsClockCannotProduceARegression() {
        // NTP correction and sleep/wake are routine on a device running a long pipeline, and either
        // would produce a value the frontend's strictly-greater-than cursor discards.
        let gen = DeviceContract.SeqGenerator()
        _ = gen.next(nowMillis: 5000)
        XCTAssertEqual(gen.next(nowMillis: 4000), 5001)
    }

    func testObserveRaisesTheFloorForAResumedRun() {
        let gen = DeviceContract.SeqGenerator()
        gen.observe(9999)
        XCTAssertEqual(gen.next(nowMillis: 500), 10000)
    }

    func testObserveNeverLowersTheFloor() {
        let gen = DeviceContract.SeqGenerator()
        _ = gen.next(nowMillis: 5000)
        gen.observe(10)
        XCTAssertEqual(gen.lastIssued, 5000)
    }

    func testSeqIsEpochMillisNotAZeroBasedCounter() {
        // A 0-based counter restarts each run BELOW the frontend's stored cursor, so every event of
        // that run is filtered out and the run appears to produce nothing at all.
        let gen = DeviceContract.SeqGenerator()
        XCTAssertGreaterThan(gen.next(nowMillis: 1_785_319_607_000), 1_000_000_000_000)
    }

    func testSeqIsUniqueUnderConcurrency() {
        let gen = DeviceContract.SeqGenerator()
        let lock = NSLock()
        var seen = Set<Int64>()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<200 {
                let v = gen.next(nowMillis: 1000)
                lock.lock()
                seen.insert(v)
                lock.unlock()
            }
        }
        XCTAssertEqual(seen.count, 1600, "an unlocked read-modify-write hands out duplicates")
    }
}
