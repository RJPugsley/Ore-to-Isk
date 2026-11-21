import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum AuthError: LocalizedError {
    case notLoggedIn
    case cancelled
    case stateMismatch
    case badToken(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Use Character › Log In with EVE Online…"
        case .cancelled:
            return "Login was cancelled."
        case .stateMismatch:
            return "Invalid or already-used OAuth state"
        case let .badToken(reason):
            return "EVE SSO token rejected: \(reason)"
        case let .http(code, body):
            return "EVE SSO error \(code): \(body)"
        }
    }
}

/// EVE SSO: login URL, code exchange, token refresh and checks.
/// PKCE (code verifier + S256 challenge), so the app's public application needs no secret.
/// Tokens in the Keychain.
actor EveAuth {
    static let shared = EveAuth()

    static let ssoBase = "https://login.eveonline.com"
    static let tokenURL = URL(string: "\(ssoBase)/v2/oauth/token")!
    static let authorizeURL = URL(string: "\(ssoBase)/v2/oauth/authorize")!
    static let metadataURL = URL(string: "\(ssoBase)/.well-known/oauth-authorization-server")!

    // Keychain accounts, as in auth.py.
    private static let accessAccount = "access_token"
    private static let refreshAccount = "refresh_token"
    private static let expiresAccount = "expires_at"

    struct Claims {
        let characterID: Int
        let name: String
        let expires: Double
        let scopes: [String]
    }

    /// Login requests waiting for their callback: state → when it started + the PKCE code verifier.
    private var pendingStates: [String: (created: Date, verifier: String)] = [:]
    private var signingKeys: [String: SecKey] = [:]
    private var claimsCache: (token: String, claims: Claims)?
    private var refreshTask: Task<String, Error>?

    // MARK: - create_login_url / validate_state

    func createLoginURL() throws -> URL {
        let credentials = try EveCredentials.load()
        let state = Self.randomToken()
        let verifier = Self.randomToken()
        pendingStates[state] = (Date(), verifier)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: credentials.callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: EngineSettings.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// 32 random bytes as base64url text (43 characters) – state and PKCE verifier.
    private static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }

    /// Checks the state and returns the PKCE verifier that belongs to it.
    func validateState(_ state: String) throws -> String {
        guard let pending = pendingStates.removeValue(forKey: state) else { throw AuthError.stateMismatch }
        if Date().timeIntervalSince(pending.created) > 600 {
            throw AuthError.badToken("OAuth login request expired")
        }
        return pending.verifier
    }

    // MARK: - exchange_code / save_tokens

    /// Handles the callback URL: checks error + state, swaps the code for tokens, saves them.
    func handleCallback(_ url: URL) async throws -> Claims {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") { throw AuthError.http(400, "EVE authorisation failed: \(error)") }
        guard let code = value("code"), let state = value("state") else {
            throw AuthError.badToken("Missing authorisation code or state")
        }
        let verifier = try validateState(state)
        return try await exchangeCode(code, verifier: verifier)
    }

    func exchangeCode(_ code: String, verifier: String) async throws -> Claims {
        let json = try await postToken(["grant_type": "authorization_code", "code": code, "code_verifier": verifier])
        return try await saveTokens(json)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private func postToken(_ form: [String: String]) async throws -> TokenResponse {
        let credentials = try EveCredentials.load()
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = form
        form["client_id"] = credentials.clientID        // public (PKCE) application: no secret
        request.setValue(EngineSettings.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.http(status, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private func saveTokens(_ response: TokenResponse) async throws -> Claims {
        let claims = try await verifyAccessToken(response.accessToken)
        try Keychain.set(response.accessToken, for: Self.accessAccount)
        if let refresh = response.refreshToken {
            try Keychain.set(refresh, for: Self.refreshAccount)
        }
        // Stored as an integer string.
        try Keychain.set(String(Int(claims.expires)), for: Self.expiresAccount)
        return claims
    }

    // MARK: - get_access_token

    /// Reads the Keychain every time; refreshes when < 60 s left.
    func accessToken() async throws -> String {
        guard let access = Keychain.get(Self.accessAccount),
              let refresh = Keychain.get(Self.refreshAccount),
              let expiresText = Keychain.get(Self.expiresAccount),
              let expires = Double(expiresText) else {
            throw AuthError.notLoggedIn
        }
        if expires > Date().timeIntervalSince1970 + 60 { return access }

        // Several ESI calls can arrive at once; refresh only once.
        if let running = refreshTask { return try await running.value }
        let task = Task { () throws -> String in
            do {
                let json = try await self.postToken(["grant_type": "refresh_token", "refresh_token": refresh])
                _ = try await self.saveTokens(json)
                return json.accessToken
            } catch {
                // Another refresh may have stored a newer token at the same moment.
                if let newer = Keychain.get(Self.accessAccount), newer != access,
                   let exp = Keychain.get(Self.expiresAccount).flatMap(Double.init),
                   exp > Date().timeIntervalSince1970 + 60 {
                    return newer
                }
                // EVE turned the login down (revoked, or made with a different EVE application):
                // forget it so the app shows "log in" instead of an error on every page.
                if case let AuthError.http(code, _) = error, (400..<500).contains(code) {
                    self.logOut()
                    throw AuthError.notLoggedIn
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Deletes the tokens.
    func logOut() {
        Keychain.delete(Self.accessAccount)
        Keychain.delete(Self.refreshAccount)
        Keychain.delete(Self.expiresAccount)
        claimsCache = nil
    }

    // MARK: - get_character_id (+ name / scopes from the same token)

    func claims() async throws -> Claims {
        let token = try await accessToken()
        if let cached = claimsCache, cached.token == token { return cached.claims }
        do {
            let claims = try await verifyAccessToken(token)
            claimsCache = (token, claims)
            return claims
        } catch AuthError.badToken("Invalid audience") {
            // A login from another EVE application (e.g. the old developer one): log in again.
            logOut()
            throw AuthError.notLoggedIn
        }
    }

    func characterID() async throws -> Int { try await claims().characterID }

    /// nil when not logged in.
    func characterName() async -> String? { try? await claims().name }

    func grantedScopes() async -> Set<String> { Set((try? await claims().scopes) ?? []) }

    // MARK: - verify_access_token

    func verifyAccessToken(_ jwt: String) async throws -> Claims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]),
              let payloadData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw AuthError.badToken("malformed JWT") }

        guard header["alg"] as? String == "RS256" else {
            throw AuthError.badToken("unsupported algorithm \(String(describing: header["alg"]))")
        }
        let key = try await signingKey(kid: header["kid"] as? String)
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    signed as CFData, signature as CFData, &error) else {
            throw AuthError.badToken("bad signature")
        }

        // PyJWT checks exp (signature + expiry), with no leeway.
        guard let expires = (payload["exp"] as? NSNumber)?.doubleValue else {
            throw AuthError.badToken("no expiry")
        }
        guard expires > Date().timeIntervalSince1970 else { throw AuthError.badToken("Signature has expired") }

        var issuer = payload["iss"] as? String ?? ""
        while issuer.hasSuffix("/") { issuer.removeLast() }
        guard ["https://login.eveonline.com", "login.eveonline.com"].contains(issuer) else {
            throw AuthError.badToken("Unexpected EVE SSO token issuer")
        }

        let audience: [String]
        if let list = payload["aud"] as? [String] { audience = list }
        else if let single = payload["aud"] as? String { audience = [single] }
        else { audience = [] }
        let clientID = try EveCredentials.load().clientID
        guard audience.contains(clientID) else { throw AuthError.badToken("Invalid audience") }
        guard audience.contains("EVE Online") else { throw AuthError.badToken("Invalid EVE token audience") }

        let prefix = "CHARACTER:EVE:"
        guard let subject = payload["sub"] as? String, subject.hasPrefix(prefix),
              let characterID = Int(subject.dropFirst(prefix.count)) else {
            throw AuthError.badToken("Unexpected character identity in EVE token")
        }

        let scopes: [String]
        if let list = payload["scp"] as? [String] { scopes = list }
        else if let single = payload["scp"] as? String { scopes = [single] }
        else { scopes = [] }

        return Claims(characterID: characterID,
                      name: payload["name"] as? String ?? "Character \(characterID)",
                      expires: expires,
                      scopes: scopes)
    }

    // MARK: - get_jwks_client

    private func signingKey(kid: String?) async throws -> SecKey {
        if let key = cachedKey(kid) { return key }

        let (metaData, _) = try await URLSession.shared.data(from: Self.metadataURL)
        guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let jwksString = meta["jwks_uri"] as? String,
              let jwksURL = URL(string: jwksString) else {
            throw AuthError.badToken("couldn't read SSO metadata")
        }
        let (jwksData, _) = try await URLSession.shared.data(from: jwksURL)
        guard let jwks = try JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]] else {
            throw AuthError.badToken("couldn't read SSO signing keys")
        }
        for entry in keys where entry["kty"] as? String == "RSA" {
            guard let id = entry["kid"] as? String,
                  let n = (entry["n"] as? String).flatMap({ Data(base64URL: $0) }),
                  let e = (entry["e"] as? String).flatMap({ Data(base64URL: $0) }) else { continue }
            signingKeys[id] = try Self.rsaPublicKey(modulus: n, exponent: e)
        }
        if let key = cachedKey(kid) { return key }
        throw AuthError.badToken("unknown signing key \(kid ?? "")")
    }

    private func cachedKey(_ kid: String?) -> SecKey? {
        if let kid { return signingKeys[kid] }
        return signingKeys.values.first
    }

    /// PKCS#1 RSAPublicKey DER (SEQUENCE { INTEGER n, INTEGER e }) → SecKey.
    private static func rsaPublicKey(modulus: Data, exponent: Data) throws -> SecKey {
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ data: Data) -> Data {
            var bytes = [UInt8](data)
            while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + Data(bytes)
        }

        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw AuthError.badToken("couldn't build signing key")
        }
        return key
    }
}

/// Login: EVE's login page in a secure login window; the app's own URL scheme brings the answer back.
@MainActor
enum SSOLogin {
    /// Returns the logged-in character's name.
    static func logIn() async throws -> String {
        let credentials = try EveCredentials.load()
        let loginURL = try await EveAuth.shared.createLoginURL()
        let window = LoginWindow()
        let callback = try await window.run(url: loginURL, scheme: credentials.callbackURL.scheme ?? "eveauth-oretoisk")
        NSApp.activate()
        return try await EveAuth.shared.handleCallback(callback).name
    }
}

/// macOS's secure login sheet (ASWebAuthenticationSession). It shares the browser's cookies,
/// so a player already logged in to EVE's website only has to pick a character.
@MainActor
final class LoginWindow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            var finished = false
            func finish(_ result: Result<URL, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    finish(.success(callback))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.failure(AuthError.cancelled))
                } else {
                    finish(.failure(error ?? AuthError.cancelled))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { finish(.failure(AuthError.cancelled)) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
