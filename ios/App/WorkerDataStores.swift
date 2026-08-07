import WebKit

/// Resolves a worker to the WebKit cookie jar it owns.
///
/// This is the piece that makes a "worker" more than a label: two web views pointed at the same
/// `WKWebsiteDataStore` share one session, so without this every worker would be signed in to
/// whatever the last one signed in to, and two concurrent runs would fight over one ChatGPT tab.
enum WorkerDataStores {

    /// ⚠ **Worker 1 keeps `.default()` and must keep it forever.**
    ///
    /// Every login the owner has already done by hand — four platforms, 2FA included — lives in the
    /// default store. Giving worker 1 an identified store like the others would be tidier and would
    /// sign the device out of everything on the very first launch after the update, with no error
    /// and nothing in any log: the cookies are still on disk, WebKit is simply looking in a different
    /// place. That is the same failure class as `bin/build_app.sh`'s removed `simctl uninstall`.
    ///
    /// Workers 2+ never existed before this change, so they have nothing to preserve and get their
    /// own identified stores.
    static func store(for worker: WorkerProfile) -> WKWebsiteDataStore {
        guard worker.id != 1 else { return .default() }
        return WKWebsiteDataStore(forIdentifier: worker.storeID)
    }

    /// Convenience for callers that hold an ordinal rather than the profile.
    ///
    /// Falls back to `.default()` for an unknown id rather than minting a fresh store: an unknown
    /// worker is a bug, and inventing an empty jar for it would present as a mysterious signed-out
    /// platform instead of as the wrong-id bug it is.
    static func store(forWorkerID id: Int, registry: WorkerRegistry = .shared) -> WKWebsiteDataStore {
        guard let worker = registry.worker(id: id) else { return .default() }
        return store(for: worker)
    }
}
