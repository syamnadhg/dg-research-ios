import XCTest
@testable import SuperResearchDeviceCore

/// The device side of the contract, pinned with the same assertions as the Python side.
///
/// Both halves of a pairing have to agree exactly, so the vectors here were computed locally and
/// cross-checked against `auth/v2_flow.py` rather than taken from documentation.
final class PairingTests: XCTestCase {

    // MARK: - TRAP-01: hash the hex text, not the bytes

    func testSecretHashHashesTheHexTextNotTheBytes() {
        // 32 zero bytes rendered as 64 hex characters.
        let secret = Pairing.PollSecret(hexText: String(repeating: "0", count: 64))

        // Verified against auth/v2_flow.py: token_hex(32) then sha256(secret.encode("ascii")).
        XCTAssertEqual(
            secret.secretHash,
            "60e05bd1b195af2f94112fa7197a5c88289058840ce7c6df9693756bc6250f55",
            "must hash the hex TEXT — this is the value the server stored the pending doc under"
        )

        // The wrong variant: hashing the 32 bytes the hex represents. It produces a perfectly
        // valid-looking digest, so the device polls a path that will never exist, times out, and
        // reports a pairing that "just didn't work" with nothing anywhere explaining why.
        XCTAssertNotEqual(
            secret.secretHash,
            "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
        )
    }

    func testSecretHashOnANonDegenerateVector() {
        // An all-zeros secret could pass by coincidence in a broken implementation; this one cannot.
        let hex = (0..<32).map { String(format: "%02x", $0) }.joined()
        let secret = Pairing.PollSecret(hexText: hex)
        XCTAssertEqual(
            secret.secretHash,
            "6c86c6aac5fb24bcf5d9939cb7d7d5645ce39418f449e03b262dd4fa14b4b92b"
        )
        XCTAssertNotEqual(
            secret.secretHash,
            "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd",
            "that is the raw-bytes digest"
        )
    }

    func testGeneratedSecretsAre64LowercaseHexCharsAndDistinct() {
        let a = Pairing.PollSecret.generate()
        let b = Pairing.PollSecret.generate()
        XCTAssertEqual(a.hexText.count, 64, "32 bytes, hex-rendered — matches token_hex(32)")
        XCTAssertTrue(a.hexText.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(a.hexText, b.hexText)
        XCTAssertEqual(a.secretHash.count, 64)
    }

    // MARK: - The pair code

    func testFormatForDisplayHyphenatesInTheMiddle() {
        XCTAssertEqual(Pairing.formatForDisplay("JPNTY4F9"), "JPNT-Y4F9")
        XCTAssertEqual(Pairing.formatForDisplay("jpnty4f9"), "JPNT-Y4F9")
    }

    func testFormatForDisplayLeavesAnUnexpectedLengthAlone() {
        // Better to show the raw value than to hyphenate something that is not a code.
        XCTAssertEqual(Pairing.formatForDisplay("SHORT"), "SHORT")
    }

    func testNormalizeAcceptsWhatAHumanActuallyTypes() {
        XCTAssertEqual(Pairing.normalize("jpnt-y4f9"), "JPNTY4F9")
        XCTAssertEqual(Pairing.normalize("  JPNT Y4F9 "), "JPNTY4F9")
        XCTAssertEqual(Pairing.normalize("JPNTY4F9"), "JPNTY4F9")
    }

    func testNormalizeRejectsConfusableCharactersRatherThanGuessing() {
        // A 0 or an I means they misread the screen. Mapping it to O/L would send a DIFFERENT code
        // to a claim endpoint that rate-limits attempts per user — spending one of their tries on
        // a code nobody issued.
        XCTAssertNil(Pairing.normalize("JPNT-Y4F0"))
        XCTAssertNil(Pairing.normalize("IPNT-Y4F9"))
        XCTAssertNil(Pairing.normalize("LPNT-Y4F9"))
        XCTAssertNil(Pairing.normalize("OPNT-Y4F9"))
    }

    func testNormalizeRejectsWrongLengths() {
        XCTAssertNil(Pairing.normalize("JPNT-Y4F"))
        XCTAssertNil(Pairing.normalize("JPNT-Y4F99"))
    }

    func testTheAlphabetExcludesTheConfusableFive() {
        for c in "01ILO" {
            XCTAssertFalse(Pairing.alphabet.contains(c), "\(c) must not be in the alphabet")
        }
        XCTAssertEqual(Pairing.alphabet.count, 31)
    }

    func testFormatAndNormalizeRoundTrip() {
        let code = "MNPQ2345"
        XCTAssertEqual(Pairing.normalize(Pairing.formatForDisplay(code).lowercased()), code)
    }
}
