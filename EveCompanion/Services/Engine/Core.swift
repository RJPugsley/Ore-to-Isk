import Foundation
import SQLite3

// Shared plumbing for the engine. The modules work with JSON-style values ([String: Any],
// [Any], NSNumber, String, NSNull) and NativeBackend turns the result into JSON for the models.

typealias JSONDict = [String: Any]

/// Error a route raises – status code + message.
struct RouteError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { detail }
}

// MARK: - Reading JSON-style values 

extension Dictionary where Key == String, Value == Any {
    func value(_ key: String) -> Any? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        return v
    }
    func int(_ key: String) -> Int? { (value(key) as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { value(key) as? String }
    /// Python truthiness for bool-ish fields.
    func bool(_ key: String) -> Bool {
        if let n = value(key) as? NSNumber { return n.boolValue }
        if let b = value(key) as? Bool { return b }
        return false
    }
    func dict(_ key: String) -> JSONDict? { value(key) as? JSONDict }
    func dicts(_ key: String) -> [JSONDict] { (value(key) as? [Any])?.compactMap { $0 as? JSONDict } ?? [] }
}

func asDicts(_ value: Any?) -> [JSONDict] {
    (value as? [Any])?.compactMap { $0 as? JSONDict } ?? []
}

// MARK: - Writing JSON

enum JSON {
    /// Optionals → NSNull (None), non-finite numbers → null, recursively.
    static func clean(_ value: Any?) -> Any {
        guard let value = unwrap(value) else { return NSNull() }
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { clean($0) }
        case let array as [Any]:
            return array.map { clean($0) }
        case let number as NSNumber:
            return number.doubleValue.isFinite ? value : NSNull()
        default:
            return value
        }
    }

    private static func unwrap(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return nil }
            return unwrap(child.value)
        }
        if value is NSNull { return nil }
        return value
    }

    static func data(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: clean(value), options: [.fragmentsAllowed])
    }

    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - Dates 

enum ISODate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // "2026-11-13" (mining ledger) → midnight UTC
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }

    /// "2026-11-13T21:05:00Z" – no fractional seconds (the app's decoder is .iso8601).
    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// "2026-11-13" in UTC.
    static func day(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }
}

// MARK: - Cache (cache with time-to-live)

actor TTLCache {
    static let shared = TTLCache()

    private var store: [String: (at: Date, value: Any)] = [:]

    func get(_ key: String, ttl: TimeInterval) -> Any? {
        guard let entry = store[key], Date().timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.value
    }

    func set(_ key: String, _ value: Any) { store[key] = (Date(), value) }
    func remove(_ key: String) { store.removeValue(forKey: key) }
    func fetchedAt(_ key: String) -> Date? { store[key]?.at }
    /// The last value stored, however old – used when EVE can't be reached.
    func stale(_ key: String) -> Any? { store[key]?.value }
    func removeAll() { store.removeAll() }
}

func cached<T>(_ key: String, ttl: TimeInterval, _ loader: () async throws -> T) async throws -> T {
    if let hit = await TTLCache.shared.get(key, ttl: ttl) as? T { return hit }
    do {
        let value = try await loader()
        await TTLCache.shared.set(key, value)
        return value
    } catch {
        // EVE down (daily downtime) or a timeout: use the last copy we had rather than fail.
        // Its time stays as when it was fetched, so "Prices as of" shows how old it is.
        if EveDowntime.isTemporary(error), let old = await TTLCache.shared.stale(key) as? T {
            return old
        }
        throw error
    }
}

// MARK: - EVE's daily downtime

/// Tranquility shuts down every day at 11:00 UTC and is usually back by 11:15–11:30.
enum EveDowntime {
    /// 10:58–11:35 UTC – a little either side of the usual downtime.
    static func isNow(_ date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minutes >= 10 * 60 + 58 && minutes <= 11 * 60 + 35
    }

    /// 11:00 UTC in the Mac's own time zone, e.g. "11:00" in London in winter.
    static var localStartText: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date()
        return start.formatted(date: .omitted, time: .shortened)
    }

    static var message: String {
        "EVE is in its daily downtime (\(localStartText) your time, 11:00 EVE time) and is usually back within 15–30 minutes. Pages show the last prices the app had where it can – try again shortly."
    }

    /// Errors worth waiting out: server timeouts, gateway errors, dropped connections, downtime.
    static func isTemporary(_ error: Error) -> Bool {
        if error is DowntimeError { return true }
        if [502, 503, 504].contains(httpStatus(of: error) ?? 0) { return true }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(urlError.code)
        }
        return false
    }
}

struct DowntimeError: LocalizedError {
    var errorDescription: String? { EveDowntime.message }
}

// MARK: - Parallel map (parallel, limited)

/// Runs `transform` over `items` with at most `limit` at a time; results in input order.
/// The first error is thrown.
func concurrentMap<T, R>(_ items: [T], limit: Int, _ transform: @escaping (T) async throws -> R) async throws -> [R] {
    guard !items.isEmpty else { return [] }
    return try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        while next < Swift.min(limit, items.count) {
            let index = next
            let item = items[index]
            group.addTask {
                let value = try await transform(item)
                return (index, value)
            }
            next += 1
        }
        while let (index, value) = try await group.next() {
            results[index] = value
            if next < items.count {
                let newIndex = next
                let item = items[newIndex]
                group.addTask {
                    let value = try await transform(item)
                    return (newIndex, value)
                }
                next += 1
            }
        }
        return results.map { $0! }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - SQLite (rows as dictionaries)

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(message: message)
        }
    }

    deinit { sqlite3_close(handle) }

    private func error() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements without results (executescript).
    func execute(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw error() }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK { throw error() }
        return Statement(db: self, stmt: stmt)
    }

    /// SELECT → rows as dictionaries (column name → Int / Double / String / NSNull).
    func query(_ sql: String, _ params: [Any?] = []) throws -> [JSONDict] {
        let statement = try prepare(sql)
        return try statement.rows(params)
    }

    /// INSERT / UPDATE once.
    func run(_ sql: String, _ params: [Any?] = []) throws {
        let statement = try prepare(sql)
        try statement.run(params)
    }

    final class Statement {
        private let db: SQLiteDB
        private let stmt: OpaquePointer?

        fileprivate init(db: SQLiteDB, stmt: OpaquePointer?) {
            self.db = db
            self.stmt = stmt
        }

        deinit { sqlite3_finalize(stmt) }

        private func bind(_ params: [Any?]) throws {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (offset, raw) in params.enumerated() {
                let index = Int32(offset + 1)
                let value: Any? = raw.flatMap { $0 is NSNull ? nil : $0 }
                let rc: Int32
                switch value {
                case nil:
                    rc = sqlite3_bind_null(stmt, index)
                case let v as Bool:
                    rc = sqlite3_bind_int64(stmt, index, v ? 1 : 0)
                case let v as Int:
                    rc = sqlite3_bind_int64(stmt, index, Int64(v))
                case let v as Double:
                    rc = sqlite3_bind_double(stmt, index, v)
                case let v as String:
                    rc = sqlite3_bind_text(stmt, index, v, -1, SQLiteDB.transient)
                case let v as NSNumber:
                    if CFNumberIsFloatType(v) {
                        rc = sqlite3_bind_double(stmt, index, v.doubleValue)
                    } else {
                        rc = sqlite3_bind_int64(stmt, index, v.int64Value)
                    }
                default:
                    rc = sqlite3_bind_text(stmt, index, "\(value!)", -1, SQLiteDB.transient)
                }
                if rc != SQLITE_OK { throw db.error() }
            }
        }

        func run(_ params: [Any?] = []) throws {
            try bind(params)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw db.error() }
        }

        func rows(_ params: [Any?] = []) throws -> [JSONDict] {
            try bind(params)
            var result: [JSONDict] = []
            let columns = sqlite3_column_count(stmt)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw db.error() }
                var row: JSONDict = [:]
                for c in 0..<columns {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                    case SQLITE_NULL: row[name] = NSNull()
                    default: row[name] = NSNull()
                    }
                }
                result.append(row)
            }
            return result
        }
    }
}

/// "?,?,?" for an IN (...) list.
func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

/// ValueError (bad input such as an unknown hub or blueprint).
struct ValueError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
