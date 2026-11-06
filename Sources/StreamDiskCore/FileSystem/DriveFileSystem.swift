import Foundation
import NFSServer
import os

/// Exposes the app's Drive folder as a `FileSystemBackend`: metadata from cached folder
/// listings, content streamed through `ChunkedReader`.
public actor DriveFileSystem: FileSystemBackend {
    public nonisolated let rootID: UInt64 = 1

    /// How long a folder listing is trusted before it is fetched again.
    let listingTTL: TimeInterval

    private struct Node {
        let file: DriveFile
        let parent: UInt64
        let name: String
    }

    private struct Folder {
        var children: [String: UInt64]
        var ordered: [UInt64]
        var fetched: Date
        var version: UInt64
    }

    private let drive: DriveClient
    private let reader: ChunkedReader
    private let log = Logger(subsystem: "app.streamdisk", category: "fs")
    private var nodes: [UInt64: Node] = [:]
    private var idByDriveID: [String: UInt64] = [:]
    private var folders: [UInt64: Folder] = [:]
    private var listing: [UInt64: Task<Void, Error>] = [:]
    private var quota: (value: DriveQuota, fetched: Date)?

    public init(drive: DriveClient, root: DriveFile, cacheBytes: Int = 256 << 20, listingTTL: TimeInterval = 15) {
        self.drive = drive
        self.listingTTL = listingTTL
        self.reader = ChunkedReader(capacity: cacheBytes) { file, range in
            try await drive.download(file.id, range: range)
        }
        nodes[rootID] = Node(file: root, parent: rootID, name: "")
        idByDriveID[root.id] = rootID
    }

    // MARK: FileSystemBackend

    public func attributes(of id: UInt64) async throws -> FileAttributes {
        guard let node = nodes[id] else { throw NFSStatus.stale }
        return attributes(id, node.file)
    }

    public func lookup(_ name: String, in directory: UInt64) async throws -> FileAttributes {
        if name == ".." {
            guard let node = nodes[directory] else { throw NFSStatus.stale }
            return try await attributes(of: node.parent)
        }
        let folder = try await folder(directory)
        guard let id = folder.children[name], let node = nodes[id] else { throw NFSStatus.noent }
        return attributes(id, node.file)
    }

    public func list(_ directory: UInt64) async throws -> DirectoryListing {
        let folder = try await folder(directory)
        let entries = folder.ordered.compactMap { id in
            nodes[id].map { DirectoryEntry(name: $0.name, attributes: attributes(id, $0.file)) }
        }
        return DirectoryListing(entries: entries, version: folder.version)
    }

    public func read(_ id: UInt64, offset: UInt64, count: Int) async throws -> [UInt8] {
        guard let node = nodes[id] else { throw NFSStatus.stale }
        guard !node.file.isFolder else { throw NFSStatus.isdir }
        let remote = RemoteFile(id: node.file.id, version: Self.version(of: node.file), size: node.file.size)
        do {
            return try await reader.read(remote, offset: offset, count: count)
        } catch {
            log.error("read \(node.name, privacy: .public) @\(offset) failed: \(String(describing: error), privacy: .public)")
            throw Self.status(for: error)
        }
    }

    public func statistics() async throws -> VolumeStatistics {
        if quota == nil || quota!.fetched.timeIntervalSinceNow < -60 {
            if let q = try? await drive.quota() { quota = (q, Date()) }
        }
        guard let q = quota?.value else { return VolumeStatistics(totalBytes: 1 << 50, freeBytes: 1 << 50) }
        // Unlimited plans have no limit; report a large volume rather than a full one.
        let total = q.limit ?? max(q.usage * 2, 1 << 50)
        return VolumeStatistics(totalBytes: total, freeBytes: total > q.usage ? total - q.usage : 0)
    }

    // MARK: Listings

    private func folder(_ id: UInt64) async throws -> Folder {
        guard let node = nodes[id] else { throw NFSStatus.stale }
        guard node.file.isFolder else { throw NFSStatus.notdir }
        if let f = folders[id], f.fetched.timeIntervalSinceNow > -listingTTL { return f }

        // One listing per folder at a time; concurrent lookups wait for it.
        if let running = listing[id] {
            try await running.value
        } else {
            let task = Task { try await self.refresh(id, driveID: node.file.id) }
            listing[id] = task
            defer { listing[id] = nil }
            do {
                try await task.value
            } catch {
                // Serve a stale listing rather than failing Finder while offline.
                if let stale = folders[id] { return stale }
                throw Self.status(for: error)
            }
        }
        guard let f = folders[id] else { throw NFSStatus.io }
        return f
    }

    private func refresh(_ id: UInt64, driveID: String) async throws {
        let files = try await drive.children(of: driveID)
        var children: [String: UInt64] = [:]
        var ordered: [UInt64] = []
        var hasher = Hasher64()
        // Listing is ordered by creation, so the older of two same-named files keeps the plain name.
        for file in files where file.isFolder || file.isStreamable {
            let name = Self.uniqueName(Self.displayName(file.name), taken: children)
            let childID = nodeID(for: file.id)
            nodes[childID] = Node(file: file, parent: id, name: name)
            children[name] = childID
            ordered.append(childID)
            hasher.combine(file.id)
            hasher.combine(name)
            hasher.combine(Self.version(of: file))
        }
        folders[id] = Folder(children: children, ordered: ordered, fetched: Date(), version: hasher.value)
    }

    // MARK: Helpers

    /// Stable id derived from the Drive id, so handles survive a restart; probes on collision.
    private func nodeID(for driveID: String) -> UInt64 {
        if let id = idByDriveID[driveID] { return id }
        var h = Hasher64()
        h.combine(driveID)
        var id = h.value & 0x7FFF_FFFF_FFFF_FFFF
        while id <= rootID || nodes[id] != nil { id &+= 1 }
        idByDriveID[driveID] = id
        return id
    }

    private func attributes(_ id: UInt64, _ file: DriveFile) -> FileAttributes {
        FileAttributes(id: id, kind: file.isFolder ? .directory : .file,
                       size: file.isFolder ? 0 : file.size, bytesOnDisk: 0,
                       modified: file.modifiedTime, changed: file.modifiedTime)
    }

    static func version(of file: DriveFile) -> String {
        file.md5Checksum ?? "\(file.modifiedTime.timeIntervalSince1970)-\(file.size)"
    }

    /// Drive allows "/" in names; Finder shows ":" in a POSIX name as "/".
    static func displayName(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: ":")
        return n.isEmpty || n == "." || n == ".." ? "_\(n)" : n
    }

    /// "clip.mov" -> "clip (2).mov" when the name is already used in this folder.
    static func uniqueName(_ name: String, taken: [String: UInt64]) -> String {
        guard taken[name] != nil else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if taken[candidate] == nil { return candidate }
            n += 1
        }
    }

    static func status(for error: Error) -> NFSStatus {
        if let s = error as? NFSStatus { return s }
        if let d = error as? DriveError, d.status == 404 { return .stale }
        if case AuthError.signedOut = error { return .acces }
        return .io
    }
}

/// FNV-1a, 64-bit. Deterministic across launches, unlike `Hasher`.
struct Hasher64 {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ s: String) {
        for b in s.utf8 {
            value ^= UInt64(b)
            value &*= 0x0000_0100_0000_01B3
        }
        // Separator so ("ab","c") and ("a","bc") differ.
        value ^= 0xFF
        value &*= 0x0000_0100_0000_01B3
    }
}
