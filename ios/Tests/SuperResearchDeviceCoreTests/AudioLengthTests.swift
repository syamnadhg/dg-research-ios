import XCTest

@testable import SuperResearchDeviceCore

/// The audio-overview length comes from the frontend's config, and every one of these encodes a way
/// it could silently be the wrong duration.
///
/// ⚠ The failure mode throughout is the same and it is why these are worth writing: a wrong length
/// produces a perfectly good audio file that nothing downstream flags. There is no error to notice.
final class AudioLengthTests: XCTestCase {

    // MARK: - The field and its values, as measured from the backend

    func testTheThreeValuesAreExactlyWhatTheBackendAccepts() {
        XCTAssertEqual(
            Set(AudioLength.allCases.map(\.rawValue)), ["short", "default", "long"]
        )
    }

    func testTheFallbackIsLONGAndNotTheOneCalledDefault() {
        // ⛔ The trap in the naming: `default` is a VALUE, not the default. The backend falls back
        // to `long` so that runs predating the feature keep their historical behaviour — a device
        // that "sensibly" fell back to `default` would quietly shorten every one of them.
        XCTAssertEqual(AudioLength.fallback, .long)
        XCTAssertNotEqual(AudioLength.fallback, .default)
    }

    // MARK: - Two sources, and the later one wins

    func testTheOVERLAYWinsOverTheDiskValue() {
        // The owner can change the setting after the run is queued. Honouring only the local copy
        // applies a stale length.
        XCTAssertEqual(
            AudioLengthResolver.resolve(disk: "long", overlay: "short"), .short
        )
    }

    func testTheDiskValueIsUsedWhenTheOverlayIsUNAVAILABLE() {
        // ⛔ Not a hypothetical: the phase-time re-read is DENIED for this device's identity, and
        // the backend tolerates that explicitly. Unavailable is a normal path.
        XCTAssertEqual(
            AudioLengthResolver.resolve(disk: "short", overlay: nil), .short
        )
    }

    func testAnUnavailableOverlayDoesNotRESETTheLengthToTheFallback() {
        // The specific regression: treating "no overlay" as "no configuration" throws away a
        // perfectly good disk value and silently lengthens every run on this device.
        XCTAssertEqual(AudioLengthResolver.resolve(disk: "default", overlay: nil), .default)
        XCTAssertNotEqual(AudioLengthResolver.resolve(disk: "default", overlay: nil), .long)
    }

    func testAnUNRECOGNISEDOverlayDoesNotOverrideAValidDiskValue() {
        // The backend's overlay applies only on a valid value. Anything else leaves the better
        // information — the disk value — in place.
        XCTAssertEqual(
            AudioLengthResolver.resolve(disk: "short", overlay: "medium"), .short
        )
    }

    // MARK: - Nothing configured at all

    func testNoConfigurationAnywhereFallsBackToLong() {
        XCTAssertEqual(AudioLengthResolver.resolve(disk: nil, overlay: nil), .long)
    }

    func testAnUnrecognisedDiskValueFallsBackRatherThanThrowing() {
        // A config written by a newer frontend must degrade to the historical behaviour, not fail
        // the phase — the audio is the last artefact of a long, expensive run.
        XCTAssertEqual(AudioLengthResolver.resolve(disk: "epic", overlay: nil), .long)
    }

    // MARK: - The variant table the customise panel is driven from

    func testSHORTIsADIFFERENTFORMATAndNotAShorterDeepDive() {
        // ⛔ Measured from the backend's own variant table: `short` selects the **Brief** format
        // tile and has NO separate length step. A flow that always sets format-then-length hunts
        // for a length control that is not on screen — and then either stalls or clicks whatever
        // is.
        XCTAssertEqual(AudioLength.short.format, "Brief")
        XCTAssertNil(AudioLength.short.lengthOption)
    }

    func testTheOtherTwoAreDeepDiveWithTheirOwnLength() {
        XCTAssertEqual(AudioLength.default.format, "Deep Dive")
        XCTAssertEqual(AudioLength.default.lengthOption, "Default")
        XCTAssertEqual(AudioLength.long.format, "Deep Dive")
        XCTAssertEqual(AudioLength.long.lengthOption, "Long")
    }

    func testNoTwoVariantsAskForTheSamePairOfControls() {
        // If two lengths resolved to one pair, one of the owner's three settings would silently be
        // an alias for another — and the artefact is a good podcast of the wrong duration.
        let pairs = AudioLength.allCases.map { "\($0.format)/\($0.lengthOption ?? "-")" }
        XCTAssertEqual(Set(pairs).count, AudioLength.allCases.count)
    }

    func testEveryValidValueSurvivesTheRoundTrip() {
        for value in AudioLength.allCases {
            XCTAssertEqual(
                AudioLengthResolver.resolve(disk: nil, overlay: value.rawValue), value
            )
        }
    }
}
