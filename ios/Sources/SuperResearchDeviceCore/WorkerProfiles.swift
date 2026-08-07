import Foundation

// Workers, which are browser profiles.
//
// A "worker" on this device is one isolated browser session — its own cookie jar, its own platform
// logins, its own `WKWebsiteDataStore`. Two workers mean two runs can be in flight at once against
// the same platform without one run's navigation stealing the other's page.
//
// ⚠ **The concept did not exist before this file.** `workerCount` was the literal `1` at both
// `confirmPairing` and every heartbeat, and every web view shared `WKWebsiteDataStore.default()`.
// So the device always told the frontend it had exactly one worker — which is why the pair flow
// never offered to add browser instances, and why the People capacity UI was sized off a constant.

/// One worker: an ordinal the backend knows about, and a cookie jar only this worker uses.
struct WorkerProfile: Identifiable, Hashable, Codable {
    /// 1-based and contiguous, because the device-doc contract keys `workers` by `"1"`, `"2"`, … and
    /// `busyWorkerIds` holds the same ordinals. This is not a display index — the backend assigns
    /// runs by it.
    let id: Int

    /// The `WKWebsiteDataStore` identity that gives this worker its own cookie jar (iOS 17+
    /// `WKWebsiteDataStore(forIdentifier:)`). Persisted rather than derived, because the identifier
    /// is what the *stored cookies on disk* are filed under: regenerating it silently signs the
    /// worker out of every platform, which presents as "the app forgot my logins" with nothing in
    /// any log to explain it.
    let storeID: UUID

    /// platform id -> whether this worker's jar was signed in, as last measured.
    ///
    /// A **missing** key means never measured. Never conflate that with `false`: telling the owner a
    /// platform is signed out when nobody has checked sends them to redo a login they may not need.
    var logins: [String: Bool] = [:]
}

/// Why a worker could not be removed. Cases rather than a bare `false` so the UI can say which.
enum WorkerRemovalRefusal: Equatable {
    /// Worker 1 is the device. Removing it would leave a backend with no browser to drive.
    case lastRemainingWorker
    /// Only the highest-numbered worker may go — see `removeLastWorker`.
    case notTheLastWorker(highest: Int)
    /// It is running something right now.
    case busy(id: Int)
}

/// Where the registry persists between launches.
///
/// A protocol so the tests can run against memory. These are identifiers and booleans, not
/// credentials — the credentials are the *cookies*, which live in WebKit's own store, and the API
/// keys, which live in the Keychain. So `UserDefaults` is the right home for this and the Keychain
/// would be cargo-culting.
protocol WorkerProfileStorage: AnyObject {
    func loadWorkers() -> Data?
    func saveWorkers(_ data: Data)
}

final class UserDefaultsWorkerStorage: WorkerProfileStorage {
    private let key = "com.distributedglobal.superresearch.workers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadWorkers() -> Data? { defaults.data(forKey: key) }
    func saveWorkers(_ data: Data) { defaults.set(data, forKey: key) }
}

final class InMemoryWorkerStorage: WorkerProfileStorage {
    private var data: Data?
    init(seed: Data? = nil) { self.data = seed }
    func loadWorkers() -> Data? { data }
    func saveWorkers(_ newValue: Data) { data = newValue }
}

/// The device's browser profiles, and the only place that decides how many workers it has.
final class WorkerRegistry {
    static let shared = WorkerRegistry(storage: UserDefaultsWorkerStorage())

    private let storage: WorkerProfileStorage
    private(set) var workers: [WorkerProfile]

    /// Every device has worker 1 from the moment it exists. A backend with zero browser profiles can
    /// take no work at all, so "no workers" is not a state worth being able to represent.
    init(storage: WorkerProfileStorage, makeID: () -> UUID = UUID.init) {
        self.storage = storage
        if let data = storage.loadWorkers(),
           let decoded = try? JSONDecoder().decode([WorkerProfile].self, from: data),
           !decoded.isEmpty {
            workers = decoded.sorted { $0.id < $1.id }
        } else {
            workers = [WorkerProfile(id: 1, storeID: makeID())]
            persist()
        }
    }

    var count: Int { workers.count }

    func worker(id: Int) -> WorkerProfile? { workers.first { $0.id == id } }

    /// Add a browser profile. Its jar is empty, so it is signed in to nothing yet.
    @discardableResult
    func addWorker(makeID: () -> UUID = UUID.init) -> WorkerProfile {
        // `count + 1`, not `max(id) + 1` — they are the same only while ids stay contiguous, and
        // keeping them contiguous is exactly what `removeLastWorker` exists to guarantee. Deriving
        // from `count` makes a gap impossible to introduce here rather than merely unlikely.
        let next = WorkerProfile(id: workers.count + 1, storeID: makeID())
        workers.append(next)
        persist()
        return next
    }

    /// Remove the highest-numbered worker, if it is idle.
    ///
    /// ⚠ Only the last one, and never worker 1. The device-doc contract keys `workers` and
    /// `busyWorkerIds` by contiguous 1-based ordinals, so removing a worker from the middle would
    /// force a renumber — and a renumber hands a *running* worker a different id from the one the
    /// backend assigned its run to. The run would keep going while the frontend attributed it to
    /// someone else, and `busyWorkerIds` would name a worker that no longer does that work.
    ///
    /// Refusing is the cheap correct answer: browser profiles are added far more often than removed.
    func removeLastWorker(busyWorkerIDs: Set<Int>) -> WorkerRemovalRefusal? {
        guard let last = workers.last else { return .lastRemainingWorker }
        guard workers.count > 1 else { return .lastRemainingWorker }
        if busyWorkerIDs.contains(last.id) { return .busy(id: last.id) }
        workers.removeLast()
        persist()
        return nil
    }

    /// Refuse to remove anything but the top of the list, with the reason spelled out.
    func removalRefusal(for id: Int, busyWorkerIDs: Set<Int>) -> WorkerRemovalRefusal? {
        guard let highest = workers.last?.id else { return .lastRemainingWorker }
        if workers.count <= 1 { return .lastRemainingWorker }
        if id != highest { return .notTheLastWorker(highest: highest) }
        if busyWorkerIDs.contains(id) { return .busy(id: id) }
        return nil
    }

    /// Record what a login check actually observed for one worker.
    func setLogin(worker id: Int, platform: String, signedIn: Bool) {
        guard let index = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[index].logins[platform] = signedIn
        persist()
    }

    /// What the *device* should report for `logins`, given every worker's own state.
    ///
    /// ⚠ The **intersection**, not the union, and the difference is not academic. The backend assigns
    /// a run to a specific worker; a P2 handed to worker 2 fails outright if only worker 1 holds the
    /// ChatGPT cookie. A union would report the device ready for work it cannot do, and the failure
    /// would surface three phases later as an unexplained login wall.
    ///
    /// Tri-state, matching the wire format's own honesty: any worker measured signed-out ⇒ `false`;
    /// every worker measured signed-in ⇒ `true`; otherwise the key is **omitted**, meaning nobody has
    /// checked. Omission is what keeps the UI saying "not checked" instead of inventing an answer.
    func deviceLogins() -> [String: Bool] {
        var seen: Set<String> = []
        for worker in workers { seen.formUnion(worker.logins.keys) }

        var out: [String: Bool] = [:]
        for platform in seen {
            let values = workers.map { $0.logins[platform] }
            if values.contains(where: { $0 == false }) {
                out[platform] = false
            } else if values.allSatisfy({ $0 == true }) {
                out[platform] = true
            }
            // else: at least one worker has never been checked — say nothing rather than guess.
        }
        return out
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(workers) else { return }
        storage.saveWorkers(data)
    }
}
