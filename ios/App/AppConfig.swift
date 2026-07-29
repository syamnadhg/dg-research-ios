import Foundation

/// Process-wide configuration set once at launch.
///
/// Exists because two places need the frontend origin — the `initiate-pair` POST and the QR's claim
/// URL — and they were allowed to disagree. They did: the POST read it from the environment while the
/// QR hardcoded a different domain, so a scanned code went somewhere the device had never contacted.
/// One holder, set from one value, removes the possibility rather than documenting against it.
enum AppConfig {
    /// The frontend the device pairs against. Overridden in `AppDelegate` at launch.
    ///
    /// Default matches the backend's own (`RESEARCH_FE_BASE_URL`, default `https://superresearch.io`).
    nonisolated(unsafe) static var frontendBaseURL = "https://superresearch.io"
}
