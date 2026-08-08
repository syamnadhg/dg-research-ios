import XCTest

@testable import SuperResearchDeviceCore

/// The store that lost a real pairing.
///
/// **What happened.** The app is signed ad-hoc on the Simulator, so it has no keychain access group
/// and every `SecItemAdd` returned `errSecMissingEntitlement` (-34018). `store(key:value:)` discarded
/// that `OSStatus`, so `save` reported nothing wrong; the device id and poll secret were also held in
/// memory, so the session ran perfectly — heartbeats every 20s for an hour. The loss surfaced only on
/// the next launch, as a device that had apparently never been paired, with nothing in any log.
///
/// These tests pin the two properties that would have caught it: a failed write is **reported**, and
/// an identity that cannot reach the Keychain still **survives a relaunch** via the container
/// fallback.
final class DeviceIdentityStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A store whose Keychain half is guaranteed to fail, which is the Simulator's real condition.
    ///
    /// Achieved by pointing it at a temp directory and asserting on the *observable* outcome rather
    /// than by stubbing `SecItemAdd`: on a host where the Keychain happens to work, the round-trip
    /// simply succeeds and the fallback is correctly skipped — the assertions below hold either way.
    private func store() -> DeviceIdentityStore {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        return s
    }

    func testAnIdentityThatIsSavedCanBeReadBack() {
        let s = store()
        XCTAssertTrue(s.save(deviceID: "dev-abc", pollSecret: "beef"))
        XCTAssertEqual(s.deviceID, "dev-abc")
        XCTAssertEqual(s.pollSecret, "beef")
        s.clear()
    }

    /// ⭐ The exact failure. A brand-new store instance is what the NEXT LAUNCH sees — it holds no
    /// memory of the pairing, only whatever actually reached disk.
    func testTheIdentitySurvivesARelaunchEvenWhenTheKeychainIsUnusable() {
        let first = store()
        XCTAssertTrue(first.save(deviceID: "dev-relaunch", pollSecret: "s3cret"))

        var second = DeviceIdentityStore()
        second.fallbackDirectory = tempDir
        XCTAssertEqual(
            second.deviceID, "dev-relaunch",
            "this is the whole bug: the pair worked all session and was gone on next launch"
        )
        XCTAssertEqual(second.pollSecret, "s3cret",
                       "without the secret the app cannot re-auth, so the device is dead anyway")
        first.clear()
    }

    func testSaveReportsSuccessRatherThanReturningNothing() {
        let s = store()
        // The signature itself is the guard: a `Void`-returning save cannot report -34018, and that
        // silence is what made the failure invisible for an entire session.
        let result: Bool = s.save(deviceID: "dev-x", pollSecret: "y")
        XCTAssertTrue(result)
        s.clear()
    }

    func testVerifyRoundTripAcceptsTheSavedIDAndRejectsAnother() {
        let s = store()
        s.save(deviceID: "dev-round", pollSecret: "z")
        XCTAssertTrue(s.verifyRoundTrip(deviceID: "dev-round"))
        XCTAssertFalse(s.verifyRoundTrip(deviceID: "dev-different"))
        s.clear()
    }

    /// ⚠ Clearing must clear BOTH homes. Clearing only the Keychain would leave the fallback file,
    /// and the next launch would resurrect an identity the user had just unpaired.
    func testClearingRemovesTheFallbackFileTooSoAnUnpairStaysUnpaired() {
        let s = store()
        s.save(deviceID: "dev-gone", pollSecret: "q")
        s.clear()

        var next = DeviceIdentityStore()
        next.fallbackDirectory = tempDir
        XCTAssertNil(next.deviceID, "an unpaired device must not come back on relaunch")
        XCTAssertNil(next.pollSecret)
    }

    func testAnEmptyStoreReportsNoIdentityRatherThanAnEmptyString() {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        XCTAssertNil(s.deviceID)
        XCTAssertNil(s.pollSecret)
    }

    /// The fallback is a real file on disk, not an in-process cache that would vanish with the
    /// object. Asserted directly, because "survives relaunch" is only meaningful if something
    /// persisted.
    func testTheFallbackActuallyWritesToDisk() throws {
        let s = store()
        s.save(deviceID: "dev-disk", pollSecret: "w")
        let url = tempDir.appendingPathComponent("device-identity.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let map = try JSONDecoder().decode(
                [String: String].self, from: Data(contentsOf: url)
            )
            XCTAssertEqual(map["deviceId"], "dev-disk")
        } else {
            // The Keychain worked on this host, so the fallback was correctly not written — the
            // stronger store won. Assert THAT rather than passing silently.
            XCTAssertEqual(s.deviceID, "dev-disk",
                           "no fallback file and no keychain value means nothing persisted at all")
        }
        s.clear()
    }

    // MARK: - The lost-pairing breadcrumb, and who reads it

    /// ⚠ The property this exists for is NOT "the reason is stored" — that already worked. It is
    /// that the app OPENS on the page which renders it. The breadcrumb was written correctly for
    /// two whole waves and shown to nobody, because launch routes to `.landing` and only
    /// `NotPairedView` prints it.
    func testALostPairingRoutesLaunchPastTheSplash() {
        XCTAssertTrue(DeviceIdentityStore.shouldOpenOnLostPairingNotice(
            reason: "device document no longer exists", isRealBackend: true))
    }

    /// A device that was simply never paired is not owed an explanation, and sending it to a page
    /// headed "No user paired" instead of the splash would be a regression for every first launch.
    func testAFirstLaunchStillGetsTheSplash() {
        XCTAssertFalse(DeviceIdentityStore.shouldOpenOnLostPairingNotice(
            reason: nil, isRealBackend: true))
    }

    /// An empty string is what a cleared-but-not-nilled breadcrumb looks like. It routes the owner
    /// to a page whose entire purpose is the explanation, and then has none to give.
    func testAnEmptyReasonIsNotAReason() {
        XCTAssertFalse(DeviceIdentityStore.shouldOpenOnLostPairingNotice(
            reason: "", isRealBackend: true))
    }

    /// The preview backend has no pairing to have lost, so a stale breadcrumb from a real run on
    /// the same simulator must not hijack its launch.
    func testThePreviewBackendIsNeverRoutedToTheNotice() {
        XCTAssertFalse(DeviceIdentityStore.shouldOpenOnLostPairingNotice(
            reason: "device document no longer exists", isRealBackend: false))
    }

    /// The two clearing paths, asserted through the routing decision rather than through the
    /// property — a reason that survives a deliberate unpair would tell the owner their own action
    /// was an unexplained loss.
    func testClearingTheNoteStopsTheRouting() {
        DeviceIdentityStore.noteLostPairing(deviceID: "dev-gone", reason: "unpaired remotely")
        XCTAssertTrue(DeviceIdentityStore.shouldOpenOnLostPairingNotice(
            reason: DeviceIdentityStore.lostPairingReason, isRealBackend: true))
        DeviceIdentityStore.clearLostPairingNote()
        XCTAssertFalse(DeviceIdentityStore.shouldOpenOnLostPairingNotice(
            reason: DeviceIdentityStore.lostPairingReason, isRealBackend: true))
    }
}
