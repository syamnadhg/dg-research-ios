import XCTest

@testable import SuperResearchDeviceCore

/// Turning uids into people.
///
/// ⚠ The device **cannot** resolve a uid on its own, and no amount of client code will change that:
/// `match /users/{userId}` is `allow read, write: if request.auth.uid == userId`, and the device
/// signs in as `device-{deviceId}`. Even the web app does not read Firestore for this — it calls an
/// Admin-SDK route. So every name here arrives pre-resolved on the device document, and the only
/// thing worth testing is that the fallbacks are honest about which one they used.
final class PeopleResolutionTests: XCTestCase {

    private func fields(_ pairs: [String: FirestoreValue]) -> [String: FirestoreValue] { pairs }

    // MARK: - The owner, whose name already exists on the document today

    func testTheOwnerIsNamedFromOwnerDisplayNameWithNoFrontendChange() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("uid-abcdefgh12345678"),
            "ownerDisplayName": .string("Sammy"),
            "ownerEmail": .string("sammy@distributedglobal.com"),
        ]))
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].label, "Sammy")
        XCTAssertEqual(users[0].secondary, "sammy@distributedglobal.com")
        XCTAssertTrue(users[0].isOwner)
        XCTAssertTrue(users[0].isResolved)
    }

    func testTheOwnerFallsBackToTheirEmailWhenThereIsNoDisplayName() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("uid-abcdefgh12345678"),
            "ownerEmail": .string("sammy@distributedglobal.com"),
        ]))
        XCTAssertEqual(users[0].label, "sammy@distributedglobal.com")
        XCTAssertNil(users[0].secondary, "the email IS the label; printing it twice reads as a bug")
        XCTAssertTrue(users[0].isResolved, "an email is a real identity")
    }

    /// ⭐ The state that produced the owner's complaint: a uid on screen.
    func testAnUnresolvableOwnerFallsBackToATruncatedUidAndSaysSo() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("An1NfSXiabcdefghijklmnrps2"),
        ]))
        XCTAssertEqual(users[0].label, "An1NfSXi…rps2")
        XCTAssertFalse(
            users[0].isResolved,
            "the UI renders this differently — a partial identity that looks confirmed is worse "
            + "than one that looks partial"
        )
    }

    // MARK: - Sharers, via the denormalised map

    func testASharerIsNamedFromThePeopleMap() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("owner-uid"),
            "sharedWith": .array([.string("sharer-uid")]),
            "people": .map([
                "sharer-uid": .map([
                    "displayName": .string("Eren"),
                    "email": .string("eren@distributedglobal.com"),
                ])
            ]),
        ]))
        let sharer = try! XCTUnwrap(users.first { !$0.isOwner })
        XCTAssertEqual(sharer.label, "Eren")
        XCTAssertEqual(sharer.secondary, "eren@distributedglobal.com")
        XCTAssertTrue(sharer.isResolved)
    }

    func testThePeopleMapWinsOverTheOwnerFallbackFields() {
        // Both present. `people` is the newer, uniform structure and is written on every claim
        // branch; `ownerDisplayName` is only refreshed on initial-pair and re-pair, so it can be
        // staler.
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("owner-uid"),
            "ownerDisplayName": .string("Stale Name"),
            "people": .map(["owner-uid": .map(["displayName": .string("Current Name")])]),
        ]))
        XCTAssertEqual(users[0].label, "Current Name")
    }

    func testASharerWithNoEntryDegradesToAUidRatherThanBorrowingTheOwnersName() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("owner-uid"),
            "ownerDisplayName": .string("Sammy"),
            "sharedWith": .array([.string("sharer-uid-that-is-long-enough")]),
        ]))
        let sharer = try! XCTUnwrap(users.first { !$0.isOwner })
        XCTAssertNotEqual(sharer.label, "Sammy",
                          "the owner's name must never leak onto someone else's tile")
        XCTAssertFalse(sharer.isResolved)
    }

    // MARK: - Shape and ordering

    func testTheOwnerIsListedFirst() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("owner-uid"),
            "sharedWith": .array([.string("a-uid"), .string("b-uid")]),
        ]))
        XCTAssertEqual(users.count, 3)
        XCTAssertTrue(users[0].isOwner)
        XCTAssertFalse(users[1].isOwner)
    }

    func testADeviceWithNoOwnerYieldsNoPeopleRatherThanAPlaceholder() {
        XCTAssertEqual(DeviceBackend.users(from: fields([:])).count, 0)
    }

    func testAMalformedPeopleEntryIsIgnoredRatherThanCrashingOrShowingBlank() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("owner-uid-long-enough-here"),
            // Not a map — a shape the device must tolerate rather than trust.
            "people": .map(["owner-uid-long-enough-here": .string("oops")]),
        ]))
        XCTAssertFalse(users[0].isResolved)
        XCTAssertFalse(users[0].label.isEmpty)
    }

    func testAnEmptyDisplayNameDoesNotBecomeABlankTile() {
        let users = DeviceBackend.users(from: fields([
            "ownerUid": .string("owner-uid-long-enough-here"),
            "people": .map(["owner-uid-long-enough-here": .map([
                "displayName": .string(""),
                "email": .string("someone@example.com"),
            ])]),
        ]))
        XCTAssertEqual(users[0].label, "someone@example.com",
                       "an empty string is not a name; it must fall through to the email")
    }

    // MARK: - Busy worker ids, which gate Remove worker

    func testBusyWorkerIDsParseBothIntegerAndStringForms() {
        XCTAssertEqual(
            DeviceBackend.busyWorkerIDs(from: ["busyWorkerIds": .array([.integer(1), .integer(3)])]),
            [1, 3]
        )
        XCTAssertEqual(
            DeviceBackend.busyWorkerIDs(from: ["busyWorkerIds": .array([.string("2")])]),
            [2]
        )
        XCTAssertEqual(
            DeviceBackend.busyWorkerIDs(from: ["busyWorkerIds": .array([.string("worker-4")])]),
            [4],
            "the contract has carried both key shapes; parsing one silently yields an EMPTY busy "
            + "set, which is exactly what lets Remove worker delete a worker mid-run"
        )
    }

    func testAnAbsentBusyListIsEmptyRatherThanNil() {
        XCTAssertEqual(DeviceBackend.busyWorkerIDs(from: [:]), [])
    }
}
