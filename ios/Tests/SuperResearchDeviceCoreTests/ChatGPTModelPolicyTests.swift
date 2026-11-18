import XCTest
@testable import SuperResearchDeviceCore

/// The ranking rule, against the menu ChatGPT actually renders.
///
/// ⭐ **The live capture is the fixture**: `Instant 5.5 / Medium / High / Extra High / Pro`. It is
/// worth stating why that one list is the whole test: only the CHEAPEST row carries a number, so
/// every "pick the highest version" instinct picks exactly the wrong row, and does so while
/// reporting success.
final class ChatGPTModelPolicyTests: XCTestCase {

    /// The menu as captured live.
    static let liveMenu = ["Instant 5.5", "Medium", "High", "Extra High", "Pro"]

    // MARK: - The rule that inverts

    func testTheHIGHESTNumberOnTheMenuIsTheLOWESTTierAndIsNotPicked() throws {
        let pick = try XCTUnwrap(ChatGPTModelPolicy.pickEffortTier(labels: Self.liveMenu))
        XCTAssertEqual(pick.label, "Pro")
        XCTAssertEqual(pick.index, 4)
        // Said explicitly, because this is the whole point: 5.5 is the biggest number on the menu.
        XCTAssertNotEqual(pick.label, "Instant 5.5", "ranked by version, which inverts this menu")
    }

    func testAVersionOnlyBreaksATieBETWEENRowsThatAlreadyNameTheTier() throws {
        let pick = try XCTUnwrap(
            ChatGPTModelPolicy.pickEffortTier(labels: ["Instant 5.5", "Pro", "Pro 5.5"])
        )
        XCTAssertEqual(pick.label, "Pro 5.5")
        XCTAssertEqual(pick.version, 5.5)
    }

    /// ⛔ A container that carries the tier word as well as the row does — clicking an ancestor never
    /// reaches the row's handler, while the caller happily reports success.
    ///
    /// ⚠ **The fixture is a row-plus-its-description, not a glued run of every row.** Mutation found
    /// the difference: a fully concatenated `"Instant 5.5MediumHighExtra HighPro"` has no word
    /// boundary before the tier word, so `hasTerm` rejects it and the tie-break is never reached —
    /// the test passed while asserting nothing about the rule it named. This shape reaches the
    /// tie-break, which is the only thing that separates the two.
    func testAWRAPPERThatCarriesTheTierWordLosesToTheLeaf() throws {
        let container = "Pro Best for the hardest problems"
        let pick = try XCTUnwrap(
            ChatGPTModelPolicy.pickEffortTier(labels: [container, "Instant 5.5", "Pro"])
        )
        XCTAssertEqual(pick.label, "Pro", "the container outranked the real row")
        XCTAssertEqual(pick.index, 2)
    }

    /// And the glued case is handled one step earlier, by the boundary rule rather than the
    /// tie-break — recorded so the two are not confused again.
    func testAFULLYGluedRunOfRowsDoesNotNameTheTierAtAll() {
        XCTAssertFalse(ChatGPTModelPolicy.hasTerm(Self.liveMenu.joined(), ["pro"]))
    }

    /// ⛔ NO FALLBACK TO A LOWER TIER. Settling for the next one down would present a lapsed
    /// subscription as a successful pick — the exact silent downgrade the confirm exists to catch.
    func testNothingIsPickedWhenNoRowNamesTheTier() {
        XCTAssertNil(ChatGPTModelPolicy.pickEffortTier(
            labels: ["Instant 5.5", "Medium", "High", "Extra High"]
        ))
    }

    func testAnUPGRADECallToActionNamesTheTierWithoutBeingEvidenceOfIt() {
        XCTAssertNil(ChatGPTModelPolicy.pickEffortTier(labels: ["Upgrade to Pro", "Instant 5.5"]))
        XCTAssertFalse(ChatGPTModelPolicy.triggerIsOnTarget("Upgrade to Pro"))
        XCTAssertFalse(ChatGPTModelPolicy.triggerIsOnTarget("Try Pro"))
    }

    /// An empty tier list already selects nothing — asserted so the "dead early-return" the backend
    /// removed is never re-added here as a guard that cannot change an answer.
    func testAnEmptyTierListSelectsNothingWithoutNeedingAGuard() {
        XCTAssertNil(ChatGPTModelPolicy.pickEffortTier(labels: Self.liveMenu, tierWords: []))
    }

    // MARK: - Word boundaries

    func testTheTierWordDoesNotMatchInsideAnotherWord() {
        // These two are rejected by the RIGHT boundary.
        XCTAssertFalse(ChatGPTModelPolicy.hasTerm("great for productivity", ["pro"]))
        XCTAssertFalse(ChatGPTModelPolicy.hasTerm("improve your writing", ["pro"]))
        XCTAssertTrue(ChatGPTModelPolicy.hasTerm("3.1 pro", ["pro"]))
        XCTAssertTrue(ChatGPTModelPolicy.hasTerm("Pro", ["pro"]))
    }

    /// ⚠ **The LEFT boundary needs its own case, and mutation is how that was found.** Every
    /// "productivity"-shaped example is rejected by the right boundary alone, so deleting the left
    /// one changed no answer and the test above passed against a half-dead rule. A tier word glued
    /// to the END of a concatenation is the case only the left boundary rejects — and it is exactly
    /// what a menu wrapper produces.
    func testTheTierWordGluedToTheENDOfAConcatenationIsNotAMatch() {
        XCTAssertFalse(ChatGPTModelPolicy.hasTerm("instant 5.5pro", ["pro"]))
        XCTAssertTrue(ChatGPTModelPolicy.hasTerm("instant 5.5 pro", ["pro"]))
    }

    func testATrailingStarMatchesAPrefixOnly() {
        XCTAssertTrue(ChatGPTModelPolicy.hasTerm("flash-litefastest", ["lite*"]))
        XCTAssertFalse(ChatGPTModelPolicy.hasTerm("elite", ["lite*"]))
    }

    /// ⚠ ASCII boundaries, matching the backend character for character. A Unicode-aware boundary
    /// and an ASCII one disagree at exactly the character that decides a match, and the browser's is
    /// ASCII.
    func testTheBoundaryIsASCIIJustAsTheBrowsersIs() {
        XCTAssertTrue(ChatGPTModelPolicy.hasTerm("flash pro高度", ["pro"]))
    }

    // MARK: - Adjacency

    func testAVersionIsReadInEitherOrder() {
        XCTAssertEqual(ChatGPTModelPolicy.familyVersion(in: "pro 5.5", family: "pro"), 5.5)
        XCTAssertEqual(ChatGPTModelPolicy.familyVersion(in: "5.5 pro", family: "pro"), 5.5)
    }

    /// ⭐ A letter-only exclusion is not enough — a comma is not a letter, and `"2x faster"` sits
    /// three characters from the tier word.
    func testANumberAcrossASENTENCEBreakIsNotTheTiersVersion() {
        XCTAssertNil(ChatGPTModelPolicy.familyVersion(in: "pro, 2x faster", family: "pro"))
        XCTAssertNil(
            ChatGPTModelPolicy.familyVersion(in: "prothe fastest deep research 4", family: "pro")
        )
    }

    /// ⛔ Family-first is tried FIRST. Number-first would read a glued wrapper's neighbouring number
    /// as ours — and the wrapper would then outrank the real leaf.
    func testTheFamilyFirstPatternWinsOnAGluedWrapper() {
        // ⚠ **Both patterns must MATCH for the order to decide anything**, and mutation found that
        // the first fixture here only satisfied one of them — swapping the order changed no answer.
        // A wrapper joining "Instant 5.5" and "Pro 6" satisfies both: number-first reads the 5.5
        // sitting just before the tier word, family-first reads the row's own 6. Reading 5.5 would
        // rank the wrapper ABOVE the real "Pro 6" leaf and click an ancestor.
        XCTAssertEqual(
            ChatGPTModelPolicy.familyVersion(in: "instant 5.5 pro 6", family: "pro"), 6
        )
    }

    // MARK: - Reading the trigger

    func testTheTriggerIsOnTargetOnlyWhenItNamesTheTier() {
        XCTAssertTrue(ChatGPTModelPolicy.triggerIsOnTarget("ChatGPT Pro"))
        XCTAssertFalse(ChatGPTModelPolicy.triggerIsOnTarget("ChatGPT Instant"))
        XCTAssertFalse(ChatGPTModelPolicy.triggerIsOnTarget(""))
    }

    /// The high-effort marker needs BOTH words, in any order — never one alone.
    func testTheHighEffortMarkerNeedsAThinkingWordANDATierWord() {
        XCTAssertTrue(ChatGPTModelPolicy.marksHighEffort("Extended Pro"))
        XCTAssertTrue(ChatGPTModelPolicy.marksHighEffort("Pro (extended)"))
        XCTAssertTrue(ChatGPTModelPolicy.marksHighEffort("Pro reasoning"))
        // ⛔ Either word alone must NOT mark it: a future free-tier "Extended" mode reading as
        // success is exactly the silent downgrade this is here to catch.
        XCTAssertFalse(ChatGPTModelPolicy.marksHighEffort("Extended"))
        XCTAssertFalse(ChatGPTModelPolicy.marksHighEffort("Pro"))
        XCTAssertFalse(ChatGPTModelPolicy.marksHighEffort("Upgrade to Pro thinking"))
    }
}
