import XCTest

@testable import SuperResearchDeviceCore

/// The catalogue, and the rules encoded in it.
///
/// Worth pinning because the old catalogue's defects were all *data* defects, not code defects: a
/// `retire` entry whose summary said "Unpair and mark the device retired" (the inverted-retire bug
/// written into copy), an `upgrade` that duplicated `update`, and eleven entries scoped to a Mac
/// bridge that was never built. None of that could fail a test, because nothing tested the data.
final class OperationsCatalogueTests: XCTestCase {

    func testEveryOperationIsInAListedGroup() {
        for op in Operations.all {
            XCTAssertTrue(
                Operations.groups.contains(op.group),
                "\(op.id) is in group '\(op.group)', which Settings never renders — the row would "
                + "be unreachable"
            )
        }
    }

    func testEveryListedGroupHasOperations() {
        for group in Operations.groups {
            XCTAssertFalse(Operations.inGroup(group).isEmpty,
                           "'\(group)' renders an empty collapsible section")
        }
    }

    func testOperationIDsAreUnique() {
        let ids = Operations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "byID would silently pick the first of a pair")
    }

    // MARK: - What the owner asked to be gone

    func testTheDuplicateUpgradeAndUpdateRowsAreBothGone() {
        XCTAssertNil(Operations.byID("upgrade"),
                     "upgrade and update meant the same thing")
        // ⚠ `update` folded into `version` too. They were two rows answering one question, and
        // Update's report always began by restating Version's — so the owner tapped twice to learn
        // one thing. The row TITLE now carries the update state.
        XCTAssertNil(Operations.byID("update"))
        XCTAssertNotNil(Operations.byID("version"))
    }

    func testTheVersionRowAnnouncesAnUpdateInItsTitle() {
        let op = try! XCTUnwrap(Operations.byID("version"))
        XCTAssertEqual(op.title(updateAvailable: nil), "Version")
        XCTAssertEqual(op.title(updateAvailable: ""), "Version",
                       "an empty string is not an update — it must not shout")
        XCTAssertTrue(op.title(updateAvailable: "0.1.14").contains("0.1.14"),
                      "the list must show an update without anything being opened")
    }

    /// ⚠ Only `version` may rewrite its title. A row whose label changes under you is disorienting
    /// unless it is the one row whose whole job is to report a changing fact.
    func testNoOtherOperationRewritesItsTitle() {
        for op in Operations.all where op.id != "version" {
            XCTAssertEqual(op.title(updateAvailable: "9.9.9"), op.title,
                           "\(op.id) must not change its label")
        }
    }

    func testUninstallIsGoneAndUnpairIsLastInTheOneGroup() {
        XCTAssertNil(Operations.byID("uninstall"), "iOS uninstalls apps itself")
        XCTAssertEqual(Operations.byID("unpair")?.group, "Runtime")
        XCTAssertEqual(Operations.all.last?.id, "unpair",
                       "the irreversible one goes last — same reason it is .destructive")
    }

    /// ⚠ Maintenance was folded into Runtime. Splitting them put Restart and Reset in different
    /// collapsed sections despite being the same kind of act on the same loop.
    func testThereIsExactlyOneGroupAndTheOrderIsTheOwnersOrder() {
        XCTAssertEqual(Operations.groups, ["Runtime"])
        XCTAssertEqual(
            Operations.all.map(\.id),
            ["serve", "restart", "reset", "version", "doctor", "daemon-loop", "collect", "unpair"]
        )
    }

    func testThereIsNoPairingGroupAndNoPairOperation() {
        XCTAssertFalse(Operations.groups.contains("Pairing"))
        XCTAssertNil(Operations.byID("pair"), "Settings is only reachable once already paired")
    }

    func testRetireResurrectAndResumeAreAllGone() {
        // Retire/resurrect ARE the On Startup toggle, and a resumable run belongs on the main
        // screen. Each of these previously rendered a row that either did nothing or did the wrong
        // thing — `retire` shared a code path with `unpair` and differed only in its toast.
        for id in ["retire", "resurrect", "resume"] {
            XCTAssertNil(Operations.byID(id), "\(id) should no longer exist")
        }
    }

    // MARK: - The supervision rule

    func testStartServingIsOfferedOnlyWhenAutostartIsOff() {
        let op = try! XCTUnwrap(Operations.byID("serve"))
        XCTAssertNil(op.unavailableReason(supervised: false),
                     "Start serving is exactly what a non-autostarting device needs")
        XCTAssertNotNil(op.unavailableReason(supervised: true),
                        "it is pointless while the device already comes online by itself")
    }

    /// ⚠ Restart is ungated in BOTH directions — owner correction 2026-08-07. A wedged worker loop
    /// is just as likely on an autostarting device, and there it is the only manual way out.
    func testRestartIsAvailableWhetherOrNotAutostartIsOn() {
        let op = try! XCTUnwrap(Operations.byID("restart"))
        XCTAssertNil(op.unavailableReason(supervised: false))
        XCTAssertNil(op.unavailableReason(supervised: true))
    }

    func testDaemonLoopIsUsableOnlyWhenAutostartIsOn() {
        let op = try! XCTUnwrap(Operations.byID("daemon-loop"))
        XCTAssertNotNil(op.unavailableReason(supervised: false))
        XCTAssertNil(op.unavailableReason(supervised: true))
    }

    /// The reason has to name the control that governs it, or a dimmed row is just a dead end.
    func testAnUnavailableOperationExplainsWhichToggleGovernsIt() {
        let daemon = try! XCTUnwrap(Operations.byID("daemon-loop"))
        let reason = try! XCTUnwrap(daemon.unavailableReason(supervised: false))
        XCTAssertTrue(reason.contains("On Startup"),
                      "a greyed row with no named cause reads as broken, not as conditional")
    }

    func testTheNonRuntimeOperationsAreAlwaysAvailable() {
        for op in Operations.all where !["serve", "daemon-loop"].contains(op.id) {
            XCTAssertNil(op.unavailableReason(supervised: true))
            XCTAssertNil(op.unavailableReason(supervised: false),
                         "\(op.id) must not depend on the autostart toggle")
        }
    }

    // MARK: - The confirmation gate

    func testDestructiveOperationsRequireConfirmation() {
        for op in Operations.all where op.risk == .destructive {
            XCTAssertTrue(op.requiresConfirmation, "\(op.id) is destructive and must be confirmed")
        }
        XCTAssertEqual(Operations.byID("unpair")?.risk, .destructive)
        XCTAssertEqual(Operations.byID("reset")?.risk, .destructive)
    }

    func testSafeOperationsAreOneTap() {
        for id in ["doctor", "version", "collect", "serve"] {
            XCTAssertFalse(try! XCTUnwrap(Operations.byID(id)).requiresConfirmation,
                           "\(id) changes nothing that needs a confirmation step")
        }
    }

    /// ⚠ The copy itself. `retire`'s old summary read "Unpair and mark the device retired" — the
    /// inverted-retire bug, written into the description rather than into the code. A summary that
    /// describes a different operation is a defect a type checker cannot see.
    func testNoSummaryPromisesUnpairingExceptUnpair() {
        for op in Operations.all where op.id != "unpair" {
            XCTAssertFalse(
                op.summary.lowercased().contains("unpair"),
                "\(op.id) describes itself as unpairing, which is what retire's summary used to do"
            )
        }
    }

    func testNoSummaryMentionsTheMacOrABridge() {
        for op in Operations.all {
            let text = (op.title + " " + op.summary).lowercased()
            for word in ["mac ", "bridge", "relay"] {
                XCTAssertFalse(text.contains(word),
                               "\(op.id) still describes the never-built Mac bridge: \(op.summary)")
            }
        }
    }
}
