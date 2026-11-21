import Foundation

// MARK: - Page results kept in memory

/// Keeps each page's last finished result, so going back to a page shows it at once –
/// but only while nothing it was built from has been updated since.
///
/// While a page's request runs, every timed copy it reads through `cached()` is noted with
/// the time that copy was fetched. Coming back, the result is reused only if every one of
/// those copies is still the same copy and EVE hasn't reached its next update time for it. If any was refreshed (by this
/// page or another one), expired, or the history database was synced, the page recalculates.
///
/// Requests that read EVE directly (not through `cached()`, e.g. wallet, location, your
/// orders) or fell back to an old copy during downtime are never kept – they always run.
/// `fresh` / `force` requests always run. Any POST, Refresh (⌘R) and log out clear everything.
enum PageMemo {
    @TaskLocal static var deps: PageDeps?

    /// Bumped whenever the history database gets new data from a sync.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _historyVersion = 0
    static var historyVersion: Int { lock.withLock { _historyVersion } }
    static func historyChanged() { lock.withLock { _historyVersion += 1 } }

    /// Settings the engine reads itself (not passed in the request) – part of the key.
    static var settingsFingerprint: String {
        let prefixes = ["build.", "refinery.", "priceCheck.", "history.", "route."]
        let all = UserDefaults.standard.dictionaryRepresentation()
        return all.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
            .sorted()
            .map { "\($0)=\(all[$0].map { "\($0)" } ?? "")" }
            .joined(separator: "&")
    }

    static func key(path: String, query: [URLQueryItem]) -> String {
        let q = query.map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        return "\(path)?\(q)#\(settingsFingerprint)"
    }

    static func bypasses(_ query: [URLQueryItem]) -> Bool {
        query.contains { ($0.name == "fresh" || $0.name == "force") && ($0.value == "true" || $0.value == "1") }
    }
}

/// What one page request read, filled in while it runs.
final class PageDeps: @unchecked Sendable {
    struct Copy { let fetchedAt: Date; let expires: Date }

    private let lock = NSLock()
    private var copies: [String: Copy] = [:]
    private var history: Int?
    private var live = false

    func used(_ key: String, fetchedAt: Date, expires: Date) {
        lock.withLock {
            // If the same data is read twice, the earliest expiry wins.
            if let old = copies[key], old.expires <= expires { return }
            copies[key] = Copy(fetchedAt: fetchedAt, expires: expires)
        }
    }

    func usedHistory() { lock.withLock { if history == nil { history = PageMemo.historyVersion } } }
    func usedLiveData() { lock.withLock { live = true } }

    var canKeep: Bool { lock.withLock { !live } }

    /// Still true if nothing behind the result has been updated or expired.
    func stillCurrent() async -> Bool {
        let (copies, history) = lock.withLock { (self.copies, self.history) }
        if let history, history != PageMemo.historyVersion { return false }
        let now = Date()
        for (key, copy) in copies {
            guard now < copy.expires,
                  await TTLCache.shared.fetchedAt(key) == copy.fetchedAt else { return false }
        }
        return true
    }
}

actor PageMemoStore {
    static let shared = PageMemoStore()
    private static let limit = 80

    private var results: [String: (data: Data, deps: PageDeps, at: Date)] = [:]

    func reusable(_ key: String) async -> Data? {
        guard let entry = results[key] else { return nil }
        if await entry.deps.stillCurrent() { return entry.data }
        results.removeValue(forKey: key)
        return nil
    }

    func keep(_ key: String, _ data: Data, _ deps: PageDeps) {
        guard deps.canKeep else { results.removeValue(forKey: key); return }
        results[key] = (data, deps, Date())
        if results.count > Self.limit, let oldest = results.min(by: { $0.value.at < $1.value.at })?.key {
            results.removeValue(forKey: oldest)
        }
    }

    func clear() { results.removeAll() }
}
