import CryptoKit
import Foundation

public enum AuthError: Error, Equatable, CustomStringConvertible {
    case signedOut
    case denied(String)
    case stateMismatch
    case tokenEndpoint(status: Int, body: String)

    public var description: String {
        switch self {
        case .signedOut: return "Not signed in. Run `streamdisk login`."
        case .denied(let reason): return "Google sign-in was not completed: \(reason)"
        case .stateMismatch: return "Sign-in response did not match this request; try again."
        case .tokenEndpoint(let status, let body): return "Google token endpoint returned \(status): \(body)"
        }
    }
}

/// Google sign-in for installed apps (loopback redirect + PKCE) and access-token upkeep.
/// The refresh token lives in the Keychain; access tokens only in memory.
public actor GoogleAuth {
    /// Only files the app creates: the default, and the only scope Google lets a public app use
    /// without a paid security assessment.
    public static let appFilesScope = "https://www.googleapis.com/auth/drive.file"
    /// The whole Drive. Opt-in.
    public static let fullDriveScope = "https://www.googleapis.com/auth/drive"
    static let refreshAccount = "google.refresh-token"
    static let scopesAccount = "google.granted-scopes"

    private let client: OAuthClient
    private let keychain: Keychain
    private let session: URLSession
    private var cached: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    public init(client: OAuthClient, keychain: Keychain = Keychain(), session: URLSession = .shared) {
        self.client = client
        self.keychain = keychain
        self.session = session
    }

    public var isSignedIn: Bool {
        (try? keychain.read(Self.refreshAccount)) != nil
    }

    /// Whether the user granted access to their whole Drive.
    public var hasFullDriveAccess: Bool {
        guard let data = try? keychain.read(Self.scopesAccount) else { return false }
        return String(decoding: data, as: UTF8.self).split(separator: " ").contains { $0 == Self.fullDriveScope }
    }

    /// Runs the browser sign-in. `open` is called with the Google consent URL.
    /// - Parameter fullDrive: Ask for the whole Drive instead of only the app's own files.
    public func signIn(fullDrive: Bool = false, open: @Sendable (URL) -> Void) async throws {
        let receiver = try LoopbackReceiver(successPage: Self.successPage)
        defer { receiver.stop() }
        let redirectURI = try await receiver.start()

        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirectURI.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: fullDrive ? Self.fullDriveScope : Self.appFilesScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            // Always show consent so Google issues a refresh token even on re-login.
            .init(name: "prompt", value: "consent"),
        ]
        open(auth.url!)

        let redirect = try await receiver.redirect()
        guard redirect.query["state"] == state else { throw AuthError.stateMismatch }
        if let error = redirect.query["error"] { throw AuthError.denied(error) }
        guard let code = redirect.query["code"] else { throw AuthError.denied("no authorization code") }

        let token = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
        ])
        guard let refresh = token.refresh_token else {
            throw AuthError.denied("Google did not return a refresh token")
        }
        try keychain.write(Data(refresh.utf8), for: Self.refreshAccount)
        // The user can untick access on the consent screen, so record what was actually granted.
        try keychain.write(Data((token.scope ?? "").utf8), for: Self.scopesAccount)
        cached = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in)))
    }

    /// A valid access token, refreshed when it is within a minute of expiring.
    public func accessToken() async throws -> String {
        if let cached, cached.expires.timeIntervalSinceNow > 60 { return cached.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// Drops the cached access token, for example after a 401.
    public func invalidate() {
        cached = nil
    }

    /// Revokes the grant at Google (best effort) and forgets it locally.
    public func signOut() async throws {
        if let data = try keychain.read(Self.refreshAccount) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["token": String(decoding: data, as: UTF8.self)])
            _ = try? await session.data(for: req)
        }
        try keychain.delete(Self.refreshAccount)
        try keychain.delete(Self.scopesAccount)
        cached = nil
    }

    private func refresh() async throws -> String {
        guard let data = try keychain.read(Self.refreshAccount) else { throw AuthError.signedOut }
        do {
            let token = try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": String(decoding: data, as: UTF8.self),
            ])
            cached = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in)))
            return token.access_token
        } catch AuthError.tokenEndpoint(let status, let body) where status == 400 && body.contains("invalid_grant") {
            // Revoked or expired grant: the stored token is useless.
            try? keychain.delete(Self.refreshAccount)
            throw AuthError.signedOut
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(fields.merging(["client_id": client.clientID, "client_secret": client.clientSecret]) { a, _ in a })
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AuthError.tokenEndpoint(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").utf8)
    }

    static func randomURLSafe(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) }).base64URLEncoded
    }

    static let successPage = """
        <!doctype html><html lang="en"><meta charset="utf-8"><title>Signed in to StreamDisk</title>
        <meta name="color-scheme" content="light dark">
        <style>
        :root{--bg:#F4F1EC;--card:#FFFDFA;--ink:#2A2520;--soft:rgba(42,37,32,.6);--line:rgba(42,37,32,.09);--accent:#D47A1F}
        @media (prefers-color-scheme:dark){:root{--bg:#1C1A17;--card:#26231F;--ink:#F3EEE7;--soft:rgba(243,238,231,.6);--line:rgba(243,238,231,.08);--accent:#E8923A}}
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
        font:15px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
        .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:40px 48px;text-align:center;max-width:360px}
        .mark{width:44px;height:44px;margin:0 auto 20px;border-radius:50%;border:4px solid var(--line);
        border-top-color:var(--accent);border-right-color:var(--accent);box-sizing:border-box;position:relative}
        .mark:after{content:"";position:absolute;inset:50%;width:8px;height:8px;margin:-4px;border-radius:50%;background:var(--accent)}
        h1{font-size:20px;font-weight:600;margin:0 0 6px}p{margin:0;color:var(--soft)}
        </style>
        <div class="card"><div class="mark"></div><h1>You're signed in</h1>
        <p>Go back to StreamDisk. You can close this tab.</p></div></html>
        """
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
