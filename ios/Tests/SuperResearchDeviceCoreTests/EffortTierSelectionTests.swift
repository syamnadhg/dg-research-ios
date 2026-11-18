import XCTest
@testable import SuperResearchDeviceCore

/// A page whose model menu can be posed in each of the states a real run hits.
///
/// ⚠ **Answers the four expressions by their distinctive marker**, and records what was ASKED as
/// well as what was answered. The verdicts below turn on call counts — "was a menu opened at all" is
/// not visible in a return value, and it is the invariant that matters most.
final class ModelMenuPage: WebPage, @unchecked Sendable {
    /// What the model/effort trigger's own label reads. Changed mid-test to model a click landing.
    var triggerText = "Instant 5.5"
    /// What the trigger reads AFTER a row is pressed. Nil means it does not move.
    var triggerTextAfterPress: String?
    /// Rows the menu mounts once opened. Empty models the React overlay that never opens.
    var rows: [String] = []
    /// Which hook group answered.
    var rowsVia = "radio"
    var triggerIsFindable = true

    private(set) var evaluated: [String] = []
    private(set) var clicked: [Int] = []
    private(set) var keys: [String] = []
    private var rowWasPressed = false

    private static let triggerHandle = 31
    private static let rowHandle = 32

    /// Did anything at all get opened? The `already` path must answer NO to every one of these.
    var openedAMenu: Bool {
        evaluated.contains { $0.contains("'model-trigger'") } || !clicked.isEmpty
    }

    func evaluateJSON(_ expression: String) async throws -> Any? {
        evaluated.append(expression)
        if expression.contains("'model-trigger'") {
            return ["marked": triggerIsFindable, "via": "testid"]
        }
        if expression.contains("'model-row'") {
            rowWasPressed = true
            return ["clicked": true]
        }
        if expression.contains("census_ignored") {
            return ["rows": rows, "via": rows.isEmpty ? "" : rowsVia, "seen_used": [String]()]
        }
        if expression.contains("out.indexOf(t)") { return [String]() }
        if expression.contains("found: false") {
            let text = rowWasPressed ? (triggerTextAfterPress ?? triggerText) : triggerText
            return ["found": true, "via": "testid", "text": text]
        }
        return nil
    }

    func querySelector(_ css: String) async throws -> Int? {
        if css.contains("model-trigger") { return triggerIsFindable ? Self.triggerHandle : nil }
        if css.contains("model-row") { return Self.rowHandle }
        return nil
    }

    func querySelectorAll(_ css: String) async throws -> [Int] { [] }
    func attribute(_ handle: Int, _ name: String) async throws -> String? { nil }
    func innerText(_ handle: Int) async throws -> String? { nil }
    func click(_ handle: Int) async throws { clicked.append(handle) }
    func insertText(_ handle: Int, _ text: String) async throws -> String? { "execCommand" }
    func key(_ name: String) async throws { keys.append(name) }
}

/// The five verdicts, and the one invariant that is only visible as a call count.
final class EffortTierSelectionTests: XCTestCase {

    private func driver(_ page: ModelMenuPage) -> InAppPhaseDriver {
        InAppPhaseDriver(platform: "chatgpt", manifest: [:], page: page)
    }

    /// No sleeping in tests — the poll loop would otherwise cost 3.5 real seconds per no-rows case.
    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    // MARK: - already

    /// ⭐ **The #744 invariant, asserted as a call count.** ChatGPT persists the tier per account, so
    /// on every run after the first this is a single read. Opening a menu it has nothing to do in
    /// leaves a popover COVERING THE COMPOSER, and the next phase's send then taps the overlay —
    /// which is a failure two steps away from its cause.
    func testAnAlreadyOnTargetTriggerOpensNOTHING() async throws {
        let page = ModelMenuPage()
        page.triggerText = "ChatGPT Pro"

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        XCTAssertEqual(verdict, .already("\"ChatGPT Pro\""))
        XCTAssertFalse(page.openedAMenu, "a menu was opened for a trigger already on target")
        XCTAssertEqual(page.clicked, [], "nothing should have been pressed")
        XCTAssertTrue(verdict.isOnTier)
    }

    // MARK: - selected / unverified

    func testARowIsPressedAndTheTriggerMovingIsWhatMakesItSelected() async throws {
        let page = ModelMenuPage()
        page.rows = ["Instant 5.5", "Medium", "High", "Extra High", "Pro"]
        page.triggerTextAfterPress = "ChatGPT Pro"

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        XCTAssertEqual(verdict, .selected("\"ChatGPT Pro\""))
        XCTAssertTrue(verdict.isOnTier)
        // Two presses: the trigger, then the row. Neither is optional.
        XCTAssertEqual(page.clicked.count, 2, "expected the trigger and then the row")
    }

    /// ⛔ **The single worst outcome this path can produce is a silent downgrade reported as a
    /// pick.** The click landed on something; the trigger did not move; that is not success.
    func testAPressedRowThatDoesNotMoveTheTriggerIsNEVERReportedAsSelected() async throws {
        let page = ModelMenuPage()
        page.rows = ["Instant 5.5", "Pro"]
        page.triggerTextAfterPress = nil  // the trigger still reads Instant

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        XCTAssertFalse(verdict.isOnTier)
        guard case .unverified(let detail) = verdict else {
            return XCTFail("expected unverified, got \(verdict)")
        }
        // The row it pressed AND what the trigger still says — either alone is not diagnosable.
        XCTAssertTrue(detail.contains("Pro"), detail)
        XCTAssertTrue(detail.contains("Instant"), detail)
    }

    // MARK: - unsure

    /// ⚠ **The measured in-app reality.** ChatGPT's composer menus are React overlays whose triggers
    /// listen on pointerdown, and a scripted click dispatches a click event and nothing else — the
    /// model menu opened 0 of 1 times in the corpus. The verdict must say so rather than proceed as
    /// though the tier were set.
    func testAMenuThatMountsNoRowsIsUnsureAndLeavesNoPopoverBehind() async throws {
        let page = ModelMenuPage()
        page.rows = []

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        XCTAssertFalse(verdict.isOnTier)
        guard case .unsure(let detail) = verdict else {
            return XCTFail("expected unsure, got \(verdict)")
        }
        // The owner needs the ONE-TIME action, not a stack trace.
        XCTAssertTrue(detail.contains("by hand"), detail)
        XCTAssertEqual(page.keys, ["Escape"], "an unopened menu still needs the composer clear")
    }

    func testAnUnfindableTriggerIsUnsureAndPressesNothing() async throws {
        let page = ModelMenuPage()
        page.triggerIsFindable = false

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        guard case .unsure = verdict else { return XCTFail("expected unsure, got \(verdict)") }
        XCTAssertEqual(page.clicked, [])
    }

    // MARK: - noTarget, and the claim it is not allowed to make

    /// The honest no-subscription signal: the menu mounted, through a ROLE hook, and offered no row
    /// naming the tier.
    func testAMountedRoleMenuWithNoTierRowIsNoTarget() async throws {
        let page = ModelMenuPage()
        page.rows = ["Instant 5.5", "Medium", "High", "Extra High"]
        page.rowsVia = "radio"

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        guard case .noTarget(let detail) = verdict else {
            return XCTFail("expected noTarget, got \(verdict)")
        }
        XCTAssertFalse(verdict.isOnTier)
        XCTAssertTrue(detail.contains("4 rows"), detail)
    }

    /// ⛔ **`noTarget` is a STRONG claim** — it is read as "this account has no Pro" — and it must
    /// not rest on the weakest hook. The class group is shared with the TOOLS menu, whose rows name
    /// no tier either, so a class-group read finding no tier cannot tell "no Pro on this plan" from
    /// "that was the wrong menu entirely".
    func testTheCLASSFallbackIsNotAllowedToClaimTheAccountHasNoTier() async throws {
        let page = ModelMenuPage()
        page.rows = ["Deep research Get a detailed report", "Web search"]
        page.rowsVia = "menu-item-class"

        let verdict = try await driver(page).selectEffortTier(sleep: noSleep)

        guard case .unsure(let detail) = verdict else {
            return XCTFail("a class-group read claimed \(verdict) — it may not")
        }
        XCTAssertTrue(detail.contains("NOT a no-tier verdict"), detail)
    }

    // MARK: - What the phase does with each verdict

    func testEveryVerdictSaysInWordsWhetherTheTierWasEstablished() {
        // ⛔ Five answers, two of them yes. Collapsing them into a Bool is how a brief written on
        // Instant gets reported as written on Pro.
        XCTAssertTrue(InAppPhaseDriver.EffortTierVerdict.already("x").isOnTier)
        XCTAssertTrue(InAppPhaseDriver.EffortTierVerdict.selected("x").isOnTier)
        XCTAssertFalse(InAppPhaseDriver.EffortTierVerdict.noTarget("x").isOnTier)
        XCTAssertFalse(InAppPhaseDriver.EffortTierVerdict.unverified("x").isOnTier)
        XCTAssertFalse(InAppPhaseDriver.EffortTierVerdict.unsure("x").isOnTier)
        // And each says which it was, in the owner's words rather than a verdict name.
        XCTAssertTrue(
            InAppPhaseDriver.EffortTierVerdict.unsure("the menu never opened")
                .detail.contains("tier unknown")
        )
        XCTAssertTrue(
            InAppPhaseDriver.EffortTierVerdict.noTarget("4 rows").detail.contains("NOT on tier")
        )
    }
}
