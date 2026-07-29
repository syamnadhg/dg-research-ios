import CoreImage
import Foundation

/// QR rendering for the pair code — the second (and only other) genuinely device-side piece of
/// pairing, alongside display hyphenation.
///
/// The owner's requirement was *"this must give a QR or pair code just like the BE"*, so the QR is
/// part of the contract rather than a convenience. Built on CoreImage, which is in the SDK, so this
/// needs no dependency and can be verified offline.
///
/// ⚠ **What goes in the QR matters more than how it is drawn.** It must encode the *claim URL* the
/// web app expects, not the bare code: a QR containing eight characters gives a phone camera nothing
/// to open, so the human ends up typing the code anyway and the QR is decoration. Encoding the URL
/// is what makes scanning actually shorter than typing.
public enum QRCode {

    /// Error correction level. **M** (~15% recovery) is the default deliberately: a pair code is
    /// scanned once, from a screen, at close range and in good light — the conditions QR error
    /// correction exists to survive are absent here. Going higher costs modules, and more modules on
    /// a 402pt-wide phone screen means a *smaller* feature size, which is the thing that actually
    /// makes a close-range scan fail.
    public enum Correction: String, Sendable, CaseIterable {
        case low = "L"
        case medium = "M"
        case quartile = "Q"
        case high = "H"
    }

    public enum QRError: Error, Equatable {
        case generatorUnavailable
        case payloadTooLarge(bytes: Int)
        case emptyPayload
    }

    /// A QR payload capacity ceiling that is honest about its own approximation.
    ///
    /// The real limit depends on version, correction level and encoding mode. Rather than embed a
    /// capacity table that would be wrong in some mode, this is a conservative bound: anything under
    /// it certainly fits, and the claim URL for an 8-character code is nowhere near it. Stated as an
    /// approximation because a table pretending to precision would be worse than a bound admitting
    /// it is one.
    public static let conservativeByteLimit = 1200

    /// The URL to encode: the web app's claim page, pre-filled with the code.
    ///
    /// Takes the base URL rather than hardcoding one, because the frontend's host differs between
    /// local development, preview deployments and production — and a QR pointing at the wrong host
    /// fails in the least debuggable way possible: it scans perfectly and opens the wrong site.
    public static func claimURL(baseURL: String, pairCode: String) -> String {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        // ⚠ `repair`, not `pair`. Verified in the frontend: `account/page.tsx` reads
        // `searchParams.get("repair")`, uppercases it, strips non-alphanumerics and opens the pairing
        // slot prefilled. `?pair=` is silently ignored — the QR scans, the account page opens, and
        // nothing is filled in, which is the least debuggable kind of wrong.
        return "\(trimmed)/account?repair=\(pairCode)"
    }

    /// Render *payload* as a QR `CIImage`.
    ///
    /// Returns the raw, unscaled image. Scaling is the caller's job because the correct scale
    /// depends on the view size, and `CIImage` upscaling must use nearest-neighbour — a smooth
    /// interpolation blurs module edges and a blurred QR is a QR that does not scan.
    public static func image(
        for payload: String,
        correction: Correction = .medium
    ) throws -> CIImage {
        let data = Data(payload.utf8)
        guard !data.isEmpty else { throw QRError.emptyPayload }
        guard data.count <= conservativeByteLimit else {
            throw QRError.payloadTooLarge(bytes: data.count)
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QRError.generatorUnavailable
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correction.rawValue, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw QRError.generatorUnavailable }
        return output
    }

    /// Render the claim URL for a pair code, ready to display.
    public static func imageForPairCode(
        _ pairCode: String,
        baseURL: String,
        correction: Correction = .medium
    ) throws -> CIImage {
        try image(for: claimURL(baseURL: baseURL, pairCode: pairCode), correction: correction)
    }

    /// The integer scale factor to fill *targetPoints* without blurring module edges.
    ///
    /// Integer on purpose. A fractional scale puts module boundaries between pixels, and the
    /// resulting soft edges are a common cause of a QR that looks fine to a human and will not scan.
    /// Never below 1, so a tiny target degrades to "small but sharp" rather than vanishing.
    public static func integerScale(for qrExtentWidth: CGFloat, targetPoints: CGFloat) -> CGFloat {
        guard qrExtentWidth > 0, targetPoints > 0 else { return 1 }
        return max(1, floor(targetPoints / qrExtentWidth))
    }
}
