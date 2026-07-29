import CryptoKit
import Foundation

/// Device-side pairing logic — the small part of pairing that genuinely belongs to the device.
///
/// ⚠ **The server mints the pair code, not the device.** `POST /api/devices/initiate-pair`
/// allocates the code and creates the device document; client creation of that document is
/// `allow create: if false`. So there is no code generator here. What the device actually owns is:
/// generating a 256-bit poll secret, hashing it, displaying the returned code, and rendering a QR.
public enum Pairing {

    // MARK: - The poll secret

    /// A 256-bit poll secret, as the **64-character hex string** the backend uses.
    ///
    /// The hex *string* is the secret, not a rendering of it. That distinction is the whole of
    /// TRAP-01 below, and it is why this type stores the text rather than `Data`.
    public struct PollSecret: Equatable, Sendable {
        /// 64 lowercase hex characters. This exact text is what the backend calls the secret.
        public let hexText: String

        public init(hexText: String) {
            self.hexText = hexText
        }

        /// Generate a fresh secret from the system CSPRNG.
        ///
        /// Mirrors the backend's `secrets.token_hex(32)`: 32 random bytes rendered as 64 hex
        /// characters.
        public static func generate() -> PollSecret {
            var bytes = [UInt8](repeating: 0, count: 32)
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
            return PollSecret(hexText: bytes.map { String(format: "%02x", $0) }.joined())
        }

        /// The value sent to the server, and the document id polled under
        /// `devices/{deviceId}/pending/{secretHash}`.
        ///
        /// ⚠ **TRAP-01 — hash the hex TEXT, not the bytes it represents.** Verified against
        /// `auth/v2_flow.py`, which does `token_hex(32)` and then
        /// `sha256(poll_secret.encode("ascii")).hexdigest()`. Hashing the decoded 32 bytes instead
        /// produces a completely different, perfectly valid-looking digest — so the device polls a
        /// document id that will never exist, waits out its timeout, and reports a pairing that
        /// "just didn't work" with nothing anywhere to indicate why. There is no error to read:
        /// the pending document is simply not at that path.
        public var secretHash: String {
            let digest = SHA256.hash(data: Data(hexText.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Displaying the code

    /// The 31-character alphabet the backend's codes use.
    ///
    /// Digits 2–9 and A–Z minus I, L and O. `0`/`1` are excluded so they cannot be confused with
    /// `O` and `I`/`L` by someone reading a code off one screen and typing it into another — which
    /// is exactly what pairing asks of them.
    public static let alphabet = Set("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    /// Hyphenate a code for a human to read: `"JPNTY4F9"` → `"JPNT-Y4F9"`.
    ///
    /// One of only two genuinely device-side pieces of pairing logic (the other being the QR
    /// render). Mirrors the backend's `format_for_display`.
    public static func formatForDisplay(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 8 else { return upper }
        let mid = upper.index(upper.startIndex, offsetBy: 4)
        return "\(upper[upper.startIndex..<mid])-\(upper[mid...])"
    }

    /// Accept what a human typed and recover the canonical code, or `nil` if it cannot be one.
    ///
    /// Tolerant of case, hyphens and surrounding whitespace, because all three are things people
    /// add when copying a code by hand. Not tolerant of characters outside the alphabet — a `0`
    /// or an `I` means they misread the screen, and silently mapping it to `O` would send a
    /// *different* code to a claim endpoint that rate-limits attempts per user.
    public static func normalize(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard cleaned.count == 8, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }
}
