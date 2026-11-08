import Foundation

/// The app's Google OAuth client ("Desktop app" type). For installed apps Google treats the
/// secret as non-confidential; PKCE is what protects the authorization code.
public struct OAuthClient: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public enum LoadError: Error, CustomStringConvertible {
        case notFound([URL])
        case malformed(URL)

        public var description: String {
            switch self {
            case .notFound(let urls):
                return "No OAuth client found. Put oauth_client.json in one of: "
                    + urls.map(\.path).joined(separator: ", ")
            case .malformed(let url):
                return "\(url.path) is not a Google OAuth client file"
            }
        }
    }

    /// Accepts both `{"client_id","client_secret"}` and the file Google Cloud Console downloads
    /// (`{"installed": {...}}`).
    public static func load(from url: URL) throws -> OAuthClient {
        struct Flat: Decodable { let client_id: String; let client_secret: String }
        struct Console: Decodable { let installed: Flat }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let c = try? decoder.decode(Console.self, from: data) {
            return OAuthClient(clientID: c.installed.client_id, clientSecret: c.installed.client_secret)
        }
        if let f = try? decoder.decode(Flat.self, from: data) {
            return OAuthClient(clientID: f.client_id, clientSecret: f.client_secret)
        }
        throw LoadError.malformed(url)
    }

    /// `$STREAMDISK_OAUTH_CLIENT`, then the app support folder, then the copy inside the app bundle.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: Bundle = .main) throws -> OAuthClient {
        var candidates: [URL] = []
        if let path = environment["STREAMDISK_OAUTH_CLIENT"] { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(AppPaths.support.appendingPathComponent("oauth_client.json"))
        if let bundled = bundle.url(forResource: "oauth_client", withExtension: "json") { candidates.append(bundled) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        throw LoadError.notFound(candidates)
    }
}

public enum AppPaths {
    public static let support: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StreamDisk", isDirectory: true)
}
