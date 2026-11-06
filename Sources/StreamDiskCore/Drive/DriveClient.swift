import Foundation
import os

public struct DriveFile: Sendable, Equatable, Decodable {
    public static let folderType = "application/vnd.google-apps.folder"

    public let id: String
    public let name: String
    public let mimeType: String
    public let size: UInt64
    public let modifiedTime: Date
    public let createdTime: Date
    public let md5Checksum: String?

    public var isFolder: Bool { mimeType == Self.folderType }
    /// Google Docs, Sheets and other native types have no byte content to stream.
    public var isStreamable: Bool { !isFolder && !mimeType.hasPrefix("application/vnd.google-apps.") }

    public init(id: String, name: String, mimeType: String, size: UInt64, modifiedTime: Date,
                createdTime: Date, md5Checksum: String? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.modifiedTime = modifiedTime
        self.createdTime = createdTime
        self.md5Checksum = md5Checksum
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, size, modifiedTime, createdTime, md5Checksum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        // Drive encodes int64 fields as strings.
        size = try c.decodeIfPresent(String.self, forKey: .size).flatMap(UInt64.init) ?? 0
        modifiedTime = try c.decode(Date.self, forKey: .modifiedTime)
        createdTime = try c.decode(Date.self, forKey: .createdTime)
        md5Checksum = try c.decodeIfPresent(String.self, forKey: .md5Checksum)
    }

    static let fields = "id,name,mimeType,size,modifiedTime,createdTime,md5Checksum"
}

public struct DriveQuota: Sendable {
    /// Nil for unlimited plans.
    public let limit: UInt64?
    public let usage: UInt64
}

public enum DriveError: Error, CustomStringConvertible {
    case http(status: Int, message: String)
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case .http(let status, let message): return "Google Drive returned \(status): \(message)"
        case .unexpectedResponse(let detail): return "Unexpected Google Drive response: \(detail)"
        }
    }

    var status: Int? {
        if case .http(let s, _) = self { return s }
        return nil
    }
}

/// Google Drive v3 over REST. Retries transient failures with exponential backoff and refreshes
/// the access token once on 401.
public struct DriveClient: Sendable {
    public static let appFolderName = "StreamDisk"

    let auth: GoogleAuth
    let session: URLSession
    private let api = URL(string: "https://www.googleapis.com/drive/v3")!
    private let uploadAPI = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    private let log = Logger(subsystem: "app.streamdisk", category: "drive")

    public init(auth: GoogleAuth, session: URLSession = DriveClient.makeSession()) {
        self.auth = auth
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    // MARK: Metadata

    /// The "StreamDisk" folder at the top of My Drive, created on first use.
    /// With the drive.file scope this is the only tree the app can see.
    public func appFolder() async throws -> DriveFile {
        let q = "name = '\(Self.appFolderName)' and mimeType = '\(DriveFile.folderType)' and 'root' in parents and trashed = false"
        let found = try await query(q, orderBy: "createdTime")
        if let existing = found.first { return existing }
        return try await createFolder(named: Self.appFolderName, in: "root")
    }

    public func children(of folderID: String) async throws -> [DriveFile] {
        try await query("'\(Self.escape(folderID))' in parents and trashed = false", orderBy: "createdTime")
    }

    public func file(_ id: String) async throws -> DriveFile {
        let url = api.appendingPathComponent("files/\(id)").appending(queryItems: [.init(name: "fields", value: DriveFile.fields)])
        let (data, _) = try await send(expecting: [200]) { URLRequest(url: url) }
        return try Self.decoder.decode(DriveFile.self, from: data)
    }

    public func createFolder(named name: String, in parentID: String) async throws -> DriveFile {
        let url = api.appendingPathComponent("files").appending(queryItems: [.init(name: "fields", value: DriveFile.fields)])
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "mimeType": DriveFile.folderType, "parents": [parentID],
        ])
        let (data, _) = try await send(expecting: [200]) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            return req
        }
        return try Self.decoder.decode(DriveFile.self, from: data)
    }

    public func quota() async throws -> DriveQuota {
        struct About: Decodable {
            struct Quota: Decodable { let limit: String?; let usage: String }
            let storageQuota: Quota
        }
        let url = api.appendingPathComponent("about").appending(queryItems: [.init(name: "fields", value: "storageQuota(limit,usage)")])
        let (data, _) = try await send(expecting: [200]) { URLRequest(url: url) }
        let about = try JSONDecoder().decode(About.self, from: data)
        return DriveQuota(limit: about.storageQuota.limit.flatMap(UInt64.init), usage: UInt64(about.storageQuota.usage) ?? 0)
    }

    private func query(_ q: String, orderBy: String) async throws -> [DriveFile] {
        struct Page: Decodable { let files: [DriveFile]; let nextPageToken: String? }
        var files: [DriveFile] = []
        var token: String?
        repeat {
            var items: [URLQueryItem] = [
                .init(name: "q", value: q),
                .init(name: "fields", value: "nextPageToken,files(\(DriveFile.fields))"),
                .init(name: "pageSize", value: "1000"),
                .init(name: "orderBy", value: orderBy),
                .init(name: "spaces", value: "drive"),
            ]
            if let token { items.append(.init(name: "pageToken", value: token)) }
            let url = api.appendingPathComponent("files").appending(queryItems: items)
            let (data, _) = try await send(expecting: [200]) { URLRequest(url: url) }
            let page = try Self.decoder.decode(Page.self, from: data)
            files += page.files
            token = page.nextPageToken
        } while token != nil
        return files
    }

    // MARK: Content

    /// Bytes `range` of a file. The range must lie inside the file.
    public func download(_ fileID: String, range: Range<UInt64>) async throws -> Data {
        precondition(!range.isEmpty)
        let url = api.appendingPathComponent("files/\(fileID)").appending(queryItems: [.init(name: "alt", value: "media")])
        let started = ContinuousClock.now
        defer {
            let ms = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
                + (ContinuousClock.now - started).components.seconds * 1000
            log.debug("download \(fileID, privacy: .public) \(range.lowerBound)+\(range.count) in \(ms) ms")
        }
        let (data, response) = try await send(expecting: [200, 206]) {
            var req = URLRequest(url: url)
            req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            return req
        }
        let expected = Int(range.count)
        if response.statusCode == 206, data.count == expected { return data }
        if response.statusCode == 200, data.count >= Int(range.upperBound) {
            // Server ignored Range and sent the whole file.
            return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        throw DriveError.unexpectedResponse("asked for \(expected) bytes, got \(data.count) (\(response.statusCode))")
    }

    /// Uploads a local file with Drive's resumable protocol, resuming within the session after
    /// network errors. `progress` receives bytes confirmed by the server.
    public func upload(_ fileURL: URL, name: String, to parentID: String,
                       progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> DriveFile {
        let total = try UInt64(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parentID]])
        let start = uploadAPI.appending(queryItems: [
            .init(name: "uploadType", value: "resumable"),
            .init(name: "fields", value: DriveFile.fields),
        ])
        let (_, created) = try await send(expecting: [200]) {
            var req = URLRequest(url: start)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
            req.httpBody = metadata
            return req
        }
        guard let location = created.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw DriveError.unexpectedResponse("resumable upload returned no session URL")
        }

        let handle = try Foundation.FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        // Chunks must be multiples of 256 KiB except the last.
        let chunkSize: UInt64 = 32 * 256 * 1024
        var offset: UInt64 = 0
        var failures = 0
        while true {
            let end = min(offset + chunkSize, total)
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: Int(end - offset)) ?? Data()
            do {
                let (data, response) = try await send(expecting: [200, 201, 308], retries: 0) {
                    var req = URLRequest(url: sessionURL)
                    req.httpMethod = "PUT"
                    req.setValue(total == 0 ? "bytes */0" : "bytes \(offset)-\(end - 1)/\(total)",
                                 forHTTPHeaderField: "Content-Range")
                    req.httpBody = chunk
                    return req
                }
                failures = 0
                if response.statusCode != 308 {
                    progress(total, total)
                    return try Self.decoder.decode(DriveFile.self, from: data)
                }
                offset = Self.confirmedBytes(response)
                progress(offset, total)
            } catch {
                failures += 1
                guard failures <= 8, Self.isTransient(error) else { throw error }
                try await Task.sleep(for: Self.backoff(attempt: failures))
                offset = try await uploadStatus(sessionURL, total: total)
            }
        }
    }

    /// Asks the upload session how many bytes it already holds.
    private func uploadStatus(_ sessionURL: URL, total: UInt64) async throws -> UInt64 {
        let (_, response) = try await send(expecting: [200, 201, 308]) {
            var req = URLRequest(url: sessionURL)
            req.httpMethod = "PUT"
            req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
            return req
        }
        return response.statusCode == 308 ? Self.confirmedBytes(response) : total
    }

    /// From a 308 "Range: bytes=0-N" header; no header means nothing was stored.
    static func confirmedBytes(_ response: HTTPURLResponse) -> UInt64 {
        guard let range = response.value(forHTTPHeaderField: "Range"),
              let last = range.split(separator: "-").last, let n = UInt64(last)
        else { return 0 }
        return n + 1
    }

    // MARK: Transport

    func send(expecting ok: Set<Int>, retries: Int = 5,
              _ make: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var reauthorized = false
        while true {
            var req = make()
            req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw DriveError.unexpectedResponse("not HTTP")
                }
                if ok.contains(http.statusCode) { return (data, http) }
                if http.statusCode == 401 && !reauthorized {
                    reauthorized = true
                    await auth.invalidate()
                    continue
                }
                throw DriveError.http(status: http.statusCode, message: Self.errorMessage(data))
            } catch {
                attempt += 1
                guard attempt <= retries, Self.isTransient(error) else { throw error }
                log.info("retrying \(req.httpMethod ?? "GET", privacy: .public) after \(String(describing: error), privacy: .public)")
                try await Task.sleep(for: Self.backoff(attempt: attempt))
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard case .http(let status, let message) = error as? DriveError else { return false }
        if [429, 500, 502, 503, 504].contains(status) { return true }
        return status == 403 && (message.contains("rateLimitExceeded") || message.contains("userRateLimitExceeded"))
    }

    static func backoff(attempt: Int) -> Duration {
        let base = min(16.0, 0.5 * pow(2.0, Double(attempt - 1)))
        return .milliseconds(Int(base * 1000 * Double.random(in: 0.75...1.25)))
    }

    private static func errorMessage(_ data: Data) -> String {
        struct Envelope: Decodable {
            struct Body: Decodable {
                struct Item: Decodable { let reason: String? }
                let message: String
                let errors: [Item]?
            }
            let error: Body
        }
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return String(decoding: data.prefix(300), as: UTF8.self)
        }
        let reasons = e.error.errors?.compactMap(\.reason).joined(separator: ",") ?? ""
        return reasons.isEmpty ? e.error.message : "\(e.error.message) [\(reasons)]"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(s, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
}
