import Foundation

/// Unauthenticated ESI calls (character sheet, ID → name lookups, portraits).
struct PublicESIClient {
    static let baseURL = URL(string: "https://esi.evetech.net/latest")!
    let userAgent = "EVE-Companion/0.1 (macOS)"

    static func portraitURL(characterID: Int, size: Int = 256) -> URL {
        URL(string: "https://images.evetech.net/characters/\(characterID)/portrait?size=\(size)")!
    }

    static func typeIconURL(typeID: Int, size: Int = 64) -> URL {
        URL(string: "https://images.evetech.net/types/\(typeID)/icon?size=\(size)")!
    }

    /// Blueprint artwork: BPO ("bp") or BPC ("bpc") variant.
    static func blueprintIconURL(typeID: Int, isCopy: Bool, size: Int = 64) -> URL {
        URL(string: "https://images.evetech.net/types/\(typeID)/\(isCopy ? "bpc" : "bp")?size=\(size)")!
    }

    func characterInfo(id: Int) async throws -> CharacterInfo {
        var request = URLRequest(url: Self.baseURL.appending(path: "characters/\(id)/"))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await send(request, as: CharacterInfo.self)
    }

    /// Resolves IDs (types, corporations, etc.) to names. ESI accepts up to 1000 per call.
    func names(for ids: [Int]) async throws -> [Int: String] {
        var result: [Int: String] = [:]
        let unique = Array(Set(ids))

        for start in stride(from: 0, to: unique.count, by: 1000) {
            let chunk = Array(unique[start..<min(start + 1000, unique.count)])

            var request = URLRequest(url: Self.baseURL.appending(path: "universe/names/"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(chunk)

            let resolved = try await send(request, as: [ResolvedName].self)
            for item in resolved {
                result[item.id] = item.name
            }
        }
        return result
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await BackendClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return try BackendClient.decoder.decode(T.self, from: data)
    }
}
