import CoreImage
import XCTest
@testable import SuperResearchDeviceCore

/// The QR half of "pairs like the BE does (code + QR)".
///
/// The assertions that matter are about the *payload* and the *scaling*, not about pixels: a QR that
/// encodes the bare code, or one rendered at a fractional scale, both look correct and both fail in
/// practice — the first because a camera has nothing to open, the second because soft module edges
/// do not decode.
final class QRCodeTests: XCTestCase {

    func testTheQREncodesTheClaimURLNotTheBareCode() {
        // Eight characters in a QR gives a phone camera nothing to open, so the human types the
        // code anyway and the QR is decoration.
        let url = QRCode.claimURL(baseURL: "https://app.example.com", pairCode: "JPNTY4F9")
        XCTAssertEqual(url, "https://app.example.com/account?pair=JPNTY4F9")
        XCTAssertNotEqual(url, "JPNTY4F9")
    }

    func testTheBaseURLIsTakenNotHardcoded() {
        // A QR pointing at the wrong host fails in the least debuggable way there is: it scans
        // perfectly and opens the wrong site.
        XCTAssertEqual(
            QRCode.claimURL(baseURL: "http://localhost:3000", pairCode: "AAAA2345"),
            "http://localhost:3000/account?pair=AAAA2345"
        )
    }

    func testATrailingSlashDoesNotProduceADoubleSlash() {
        XCTAssertEqual(
            QRCode.claimURL(baseURL: "https://app.example.com/", pairCode: "AAAA2345"),
            "https://app.example.com/account?pair=AAAA2345"
        )
    }

    func testAQRIsActuallyProducedForARealisticPayload() throws {
        let image = try QRCode.imageForPairCode("JPNTY4F9", baseURL: "https://app.example.com")
        XCTAssertGreaterThan(image.extent.width, 0)
        XCTAssertGreaterThan(image.extent.height, 0)
        XCTAssertEqual(image.extent.width, image.extent.height, accuracy: 1, "a QR is square")
    }

    func testTheProducedQRDecodesBackToTheClaimURL() throws {
        // The strongest available check short of pointing a camera at it: generate, then detect.
        let payload = QRCode.claimURL(baseURL: "https://app.example.com", pairCode: "JPNTY4F9")
        let image = try QRCode.image(for: payload)
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        // Scale up first: the raw generator output is one pixel per module, which is below the
        // detector's minimum feature size — the same reason the on-screen render must be scaled.
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let features = detector?.features(in: scaled) as? [CIQRCodeFeature] ?? []
        XCTAssertEqual(features.first?.messageString, payload)
    }

    func testEveryCorrectionLevelProducesAScannableQR() throws {
        for level in QRCode.Correction.allCases {
            let image = try QRCode.image(for: "https://app.example.com/account?pair=AAAA2345",
                                        correction: level)
            XCTAssertGreaterThan(image.extent.width, 0, "level \(level.rawValue) produced nothing")
        }
    }

    func testHigherCorrectionCostsModules() throws {
        // Which is why M is the default: more modules on a 402pt screen means a smaller feature
        // size, and that is what actually makes a close-range scan fail.
        let low = try QRCode.image(for: "https://app.example.com/account?pair=AAAA2345",
                                   correction: .low)
        let high = try QRCode.image(for: "https://app.example.com/account?pair=AAAA2345",
                                    correction: .high)
        XCTAssertGreaterThanOrEqual(high.extent.width, low.extent.width)
    }

    func testAnEmptyPayloadIsRefused() {
        XCTAssertThrowsError(try QRCode.image(for: "")) { error in
            XCTAssertEqual(error as? QRCode.QRError, .emptyPayload)
        }
    }

    func testAnOversizedPayloadIsRefusedWithItsSize() {
        let huge = String(repeating: "x", count: QRCode.conservativeByteLimit + 1)
        XCTAssertThrowsError(try QRCode.image(for: huge)) { error in
            guard case .payloadTooLarge(let bytes) = (error as? QRCode.QRError) else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(bytes, QRCode.conservativeByteLimit + 1)
        }
    }

    func testTheByteLimitIsAConservativeBoundNotAPrecisePretence() {
        // Documented as approximate on purpose: the real limit varies by version, correction level
        // and encoding mode, and a table pretending to precision would be worse than a bound that
        // admits it is one. A claim URL is nowhere near it.
        let realistic = QRCode.claimURL(baseURL: "https://app.example.com", pairCode: "JPNTY4F9")
        XCTAssertLessThan(realistic.utf8.count, QRCode.conservativeByteLimit / 10)
    }

    // MARK: - Scaling

    func testTheScaleIsAnIntegerSoModuleEdgesStaySharp() {
        // A fractional scale puts module boundaries between pixels, and the soft edges that result
        // are a common cause of a QR that looks fine to a human and will not scan.
        let scale = QRCode.integerScale(for: 27, targetPoints: 240)
        XCTAssertEqual(scale, 8, "floor(240/27) = 8, not 8.888…")
        XCTAssertEqual(scale, scale.rounded(), "must be a whole number")
    }

    func testTheScaleNeverDropsBelowOne() {
        // A tiny target degrades to "small but sharp" rather than vanishing.
        XCTAssertEqual(QRCode.integerScale(for: 100, targetPoints: 10), 1)
    }

    func testDegenerateScaleInputsAreHandled() {
        XCTAssertEqual(QRCode.integerScale(for: 0, targetPoints: 240), 1)
        XCTAssertEqual(QRCode.integerScale(for: 27, targetPoints: 0), 1)
    }

    func testAScaledQRStillDecodes() throws {
        let payload = QRCode.claimURL(baseURL: "https://app.example.com", pairCode: "MNPQ2345")
        let image = try QRCode.image(for: payload)
        let scale = QRCode.integerScale(for: image.extent.width, targetPoints: 240)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: scaled) as? [CIQRCodeFeature] ?? []
        XCTAssertEqual(
            features.first?.messageString, payload,
            "the integer-scaled render must still decode — that is the whole point of the scale rule"
        )
    }
}
