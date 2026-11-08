import Foundation
import NFSServer
import os

/// Exposes the app's Drive folder as a writable file system.
///
/// Reads stream from Drive through `ChunkedReader`. Writes go to a local staging file and upload
/// once the file has been quiet for a moment (see `UploadQueue`); until then the staged copy is
/// what Finder sees. A journal on disk records staged files, so uploads resume after a restart.
/// Deletes move items to Drive's trash.
public actor DriveFileSystem: WritableFileSystemBackend {
    public nonisolated let rootID: UInt64 = 1

    /// How long a folder listing is trusted before it is fetched again.
    let listingTTL: TimeInterval

    private struct Node {
        var name: String
        var parent: UInt64
        /// Nil for a file that has not been uploaded yet.
        var remote: DriveFile?
    }

    private struct Folder {
        var children: [String: UInt64]
        var ordered: [UInt64]
        var fetched: Date
        var version: UInt64
    }

    /// Written content waiting to upload (or kept local, for Finder's metadata files).
    struct Pending: Codable {
        var name: String
        var parentDriveID: String
        var staging: String
        /// The Drive file this content replaces; nil for a new file.
        var driveID: String?
        var modified: Date
        var session: URL?
        var localOnly: Bool
        var verifier: UInt64?
    }

    private let drive: any DriveService
    private let offline: OfflineStore?
    private let reader: ChunkedReader
    private let staging: StagingStore
    private let uploads: UploadQueue
    private let journalURL: URL
    private let log = Logger(subsystem: "app.streamdisk", category: "fs")
    private var nodes: [UInt64: Node] = [:]
    private var idByDriveID: [String: UInt64] = [:]
    private var folders: [UInt64: Folder] = [:]
    private var listing: [UInt64: Task<Void, Error>] = [:]
    private var materializing: [UInt64: Task<String, Error>] = [:]
    private var pending: [UInt64: Pending] = [:]
    private var quota: (value: DriveQuota, fetched: Date)?
    /// Recent reads per file, for the streaming rate shown in the app.
    private var reads: [UInt64: [(at: Date, bytes: Int)]] = [:]
    /// Bytes the server has confirmed for uploads in progress.
    private var uploadSent: [UInt64: UInt64] = [:]

    /// - Parameters:
    ///   - stateDirectory: Holds the staging files and the journal.
    ///   - uploadDelay: How long a file must go without writes before it uploads.
    ///   - offline: Copies of kept files; reads use them instead of streaming when current.
    public init(drive: any DriveService, root: DriveFile, stateDirectory: URL = AppPaths.support,
                cacheBytes: Int = 256 << 20, listingTTL: TimeInterval = 15,
                uploadDelay: Duration = .seconds(2), offline: OfflineStore? = nil) throws {
        self.drive = drive
        self.offline = offline
        self.listingTTL = listingTTL
        self.reader = ChunkedReader(capacity: cacheBytes) { file, range in
            try await drive.download(file.id, range: range)
        }
        self.staging = try StagingStore(directory: stateDirectory.appendingPathComponent("Staging"))
        self.uploads = UploadQueue(quiet: uploadDelay)
        self.journalURL = stateDirectory.appendingPathComponent("pending.json")
        nodes[rootID] = Node(name: "", parent: rootID, remote: root)
        idByDriveID[root.id] = rootID

        if let data = try? Data(contentsOf: journalURL),
           let saved = try? JSONDecoder().decode([UInt64: Pending].self, from: data) {
            pending = saved
        }
        staging.removeAll(except: Set(pending.values.map(\.staging)))
    }

    /// Starts uploading, including anything left over from the last run.
    public func start() async {
        await uploads.start { [weak self] id in try await self?.upload(id) }
        for (id, p) in pending where !p.localOnly { await uploads.enqueue(id) }
    }

    /// Files written but not yet uploaded.
    public var uploadsWaiting: Int { pending.values.filter { !$0.localOnly }.count }

    // MARK: Reading

    public func attributes(of id: UInt64) async throws -> FileAttributes {
        if let p = pending[id] {
            let size = try staging.size(p.staging)
            // Staged content really is on this Mac until it uploads.
            return FileAttributes(id: id, kind: .file, size: size, bytesOnDisk: size, modified: p.modified)
        }
        guard let remote = nodes[id]?.remote else { throw NFSStatus.stale }
        let kept = offline?.hasCopy(remote.id, version: remote.contentVersion) == true
        return FileAttributes(id: id, kind: remote.isFolder ? .directory : .file,
                              size: remote.isFolder ? 0 : remote.size, bytesOnDisk: kept ? remote.size : 0,
                              modified: remote.modifiedTime, changed: remote.modifiedTime)
    }

    public func lookup(_ name: String, in directory: UInt64) async throws -> FileAttributes {
        if name == ".." {
            guard let node = nodes[directory] else { throw NFSStatus.stale }
            return try await attributes(of: node.parent)
        }
        let folder = try await folder(directory)
        guard let id = folder.children[name] else { throw NFSStatus.noent }
        return try await attributes(of: id)
    }

    public func list(_ directory: UInt64) async throws -> DirectoryListing {
        let folder = try await folder(directory)
        var entries: [DirectoryEntry] = []
        for id in folder.ordered {
            guard let node = nodes[id], let attrs = try? await attributes(of: id) else { continue }
            entries.append(DirectoryEntry(name: node.name, attributes: attrs))
        }
        return DirectoryListing(entries: entries, version: folder.version)
    }

    public func read(_ id: UInt64, offset: UInt64, count: Int) async throws -> [UInt8] {
        if let p = pending[id] { return try staging.read(p.staging, offset: offset, count: count) }
        guard let node = nodes[id], let remote = node.remote else { throw NFSStatus.stale }
        guard !remote.isFolder else { throw NFSStatus.isdir }
        if let local = offline?.read(remote.id, version: remote.contentVersion, offset: offset, count: count) {
            return local
        }
        let file = RemoteFile(id: remote.id, version: Self.version(of: remote), size: remote.size)
        do {
            let bytes = try await reader.read(file, offset: offset, count: count)
            recordRead(id, bytes: bytes.count)
            return bytes
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

    // MARK: Writing

    public func create(_ name: String, in directory: UInt64, mode: CreateMode) async throws -> FileAttributes {
        let folder = try await folder(directory)
        if let existing = folder.children[name] {
            switch mode {
            case .unchecked: return try await attributes(of: existing)
            case .guarded: throw NFSStatus.exist
            case .exclusive(let v):
                guard pending[existing]?.verifier == v else { throw NFSStatus.exist }
                return try await attributes(of: existing)
            }
        }
        let parentDriveID = try driveID(ofFolder: directory)
        var verifier: UInt64?
        if case .exclusive(let v) = mode { verifier = v }
        let id = newNodeID()
        pending[id] = Pending(name: name, parentDriveID: parentDriveID, staging: try staging.create(),
                              driveID: nil, modified: Date(), session: nil,
                              localOnly: Self.isLocalOnly(name), verifier: verifier)
        nodes[id] = Node(name: name, parent: directory, remote: nil)
        insert(id, named: name, in: directory)
        saveJournal()
        await changed(id)
        return try await attributes(of: id)
    }

    public func write(_ id: UInt64, offset: UInt64, data: [UInt8]) async throws -> FileAttributes {
        let name = try await stage(id)
        try staging.write(name, offset: offset, data: data)
        pending[id]?.modified = Date()
        await changed(id)
        return try await attributes(of: id)
    }

    public func commit(_ id: UInt64) async throws {
        if let p = pending[id] { try staging.sync(p.staging) }
    }

    public func setAttributes(_ id: UInt64, size: UInt64?, modified: Date?) async throws -> FileAttributes {
        guard let node = nodes[id] else { throw NFSStatus.stale }
        if let size {
            if node.remote?.isFolder == true { throw NFSStatus.isdir }
            if pending[id] == nil, size == 0 {
                // Truncating to empty (how most apps start a save) needs none of the old content.
                try stageEmpty(id)
                await changed(id)
            } else if pending[id] != nil || size != node.remote?.size {
                let name = try await stage(id)
                try staging.truncate(name, to: size)
                await changed(id)
            }
        }
        if let modified {
            if pending[id] != nil {
                pending[id]?.modified = modified
                saveJournal()
            } else if let remote = node.remote {
                nodes[id]?.remote = try await call { try await self.drive.update(remote.id, name: nil, moveFrom: nil, to: nil, modified: modified) }
            }
        }
        return try await attributes(of: id)
    }

    public func makeDirectory(_ name: String, in directory: UInt64) async throws -> FileAttributes {
        let folder = try await folder(directory)
        guard folder.children[name] == nil else { throw NFSStatus.exist }
        // macOS housekeeping folders would only clutter Drive.
        guard !Self.refusedDirectories.contains(name) else { throw NFSStatus.acces }
        let parentDriveID = try driveID(ofFolder: directory)
        let created = try await call { try await self.drive.createFolder(named: Self.driveName(name), in: parentDriveID) }
        let id = nodeID(for: created.id)
        nodes[id] = Node(name: name, parent: directory, remote: created)
        folders[id] = Folder(children: [:], ordered: [], fetched: Date(), version: 1)
        insert(id, named: name, in: directory)
        return try await attributes(of: id)
    }

    public func remove(_ name: String, from directory: UInt64) async throws {
        let folder = try await folder(directory)
        guard let id = folder.children[name] else { throw NFSStatus.noent }
        if nodes[id]?.remote?.isFolder == true { throw NFSStatus.isdir }
        try await discard(id)
        removeChild(named: name, from: directory)
    }

    public func removeDirectory(_ name: String, from directory: UInt64) async throws {
        let folder = try await folder(directory)
        guard let id = folder.children[name] else { throw NFSStatus.noent }
        guard let remote = nodes[id]?.remote, remote.isFolder else { throw NFSStatus.notdir }
        guard try await self.folder(id).ordered.isEmpty else { throw NFSStatus.notEmpty }
        try await call { try await self.drive.trash(remote.id) }
        await offline?.forget(remote.id)
        folders[id] = nil
        removeChild(named: name, from: directory)
    }

    public func rename(_ name: String, from source: UInt64, to newName: String, in target: UInt64) async throws {
        guard let id = try await folder(source).children[name] else { throw NFSStatus.noent }
        let targetDriveID = try driveID(ofFolder: target)
        if let existing = try await folder(target).children[newName], existing != id {
            // POSIX rename replaces a file; this is how apps save atomically.
            guard nodes[existing]?.remote?.isFolder != true else { throw NFSStatus.exist }
            try await discard(existing)
            removeChild(named: newName, from: target)
        }
        if var p = pending[id], p.driveID == nil {
            // Not uploaded yet: only the plan changes.
            p.name = newName
            p.parentDriveID = targetDriveID
            p.localOnly = Self.isLocalOnly(newName)
            pending[id] = p
            saveJournal()
            if p.localOnly { await uploads.cancel(id) } else { await uploads.touch(id) }
        } else if let remote = nodes[id]?.remote {
            let sourceDriveID = try driveID(ofFolder: source)
            nodes[id]?.remote = try await call {
                try await self.drive.update(remote.id, name: newName == name ? nil : Self.driveName(newName),
                                            moveFrom: sourceDriveID, to: targetDriveID, modified: nil)
            }
            if pending[id] != nil {
                pending[id]?.name = newName
                pending[id]?.parentDriveID = targetDriveID
                saveJournal()
            }
        }
        nodes[id]?.name = newName
        nodes[id]?.parent = target
        removeChild(named: name, from: source)
        insert(id, named: newName, in: target)
    }

    // MARK: Staging and upload

    /// Makes sure `id` has staged content, downloading the current Drive content first.
    /// Editing part of a large remote file in place therefore downloads all of it; apps that
    /// save by rewriting the whole file (most of them) never hit this path.
    private func stage(_ id: UInt64) async throws -> String {
        if let p = pending[id] { return p.staging }
        if let running = materializing[id] { return try await running.value }
        guard let node = nodes[id], let remote = node.remote else { throw NFSStatus.stale }
        guard !remote.isFolder else { throw NFSStatus.isdir }
        let parentDriveID = try driveID(ofFolder: node.parent)
        let name = try staging.create()
        let task = Task { [drive, staging] () throws -> String in
            var offset: UInt64 = 0
            while offset < remote.size {
                let end = min(remote.size, offset + (8 << 20))
                let data = try await drive.download(remote.id, range: offset..<end)
                try staging.write(name, offset: offset, data: Array(data))
                offset = end
            }
            return name
        }
        materializing[id] = task
        defer { materializing[id] = nil }
        do {
            _ = try await task.value
        } catch {
            staging.delete(name)
            throw Self.status(for: error)
        }
        pending[id] = Pending(name: node.name, parentDriveID: parentDriveID, staging: name, driveID: remote.id,
                              modified: remote.modifiedTime, session: nil, localOnly: false, verifier: nil)
        saveJournal()
        return name
    }

    private func stageEmpty(_ id: UInt64) throws {
        guard let node = nodes[id], let remote = node.remote else { throw NFSStatus.stale }
        pending[id] = Pending(name: node.name, parentDriveID: try driveID(ofFolder: node.parent),
                              staging: try staging.create(), driveID: remote.id, modified: Date(),
                              session: nil, localOnly: false, verifier: nil)
        saveJournal()
    }

    private func changed(_ id: UInt64) async {
        guard let p = pending[id], !p.localOnly else { return }
        await uploads.touch(id)
    }

    /// Removes an entry's content: staged data is deleted, Drive items go to the trash.
    private func discard(_ id: UInt64) async throws {
        if let p = pending[id] {
            await uploads.cancel(id)
            staging.delete(p.staging)
            pending[id] = nil
            uploadSent[id] = nil
            saveJournal()
        }
        if let remote = nodes[id]?.remote {
            try await call { try await self.drive.trash(remote.id) }
            await reader.forget(remote.id)
            await offline?.forget(remote.id)
        }
    }

    /// Uploads a staged file. Called by `UploadQueue` once writes have stopped.
    private func upload(_ id: UInt64) async throws {
        guard let p = pending[id], !p.localOnly else { return }
        try staging.sync(p.staging)
        staging.close(p.staging)
        let target: DriveClient.UploadTarget = p.driveID.map { .replace(fileID: $0) }
            ?? .new(name: Self.driveName(p.name), parentID: p.parentDriveID)
        log.info("uploading \(p.name, privacy: .public)")
        uploadSent[id] = 0
        let file = try await drive.upload(staging.url(p.staging), to: target, modified: p.modified, session: p.session,
                                          onSession: { [weak self] url in Task { await self?.setSession(id, url) } },
                                          progress: { [weak self] sent, _ in Task { await self?.setSent(id, sent) } })
        try Task.checkCancellation()
        guard let current = pending[id], current.staging == p.staging else {
            // Deleted while the last bytes were in flight: don't leave the upload behind.
            if pending[id] == nil && nodes[id] == nil && p.driveID == nil { try? await drive.trash(file.id) }
            return
        }
        // Inside a kept item: the staged file becomes the offline copy.
        if let offline {
            _ = await offline.adopt(file, from: staging.url(p.staging), ancestors: [file.id] + driveAncestors(of: id))
        }
        pending[id] = nil
        uploadSent[id] = nil
        staging.delete(p.staging)
        saveJournal()
        idByDriveID[file.id] = id
        nodes[id]?.remote = file
        log.info("uploaded \(p.name, privacy: .public)")
    }

    private func setSent(_ id: UInt64, _ sent: UInt64) {
        guard pending[id] != nil else { return }
        uploadSent[id] = sent
    }

    private func setSession(_ id: UInt64, _ url: URL) {
        pending[id]?.session = url
        saveJournal()
    }

    private func saveJournal() {
        do {
            try JSONEncoder().encode(pending).write(to: journalURL, options: .atomic)
        } catch {
            log.error("could not save upload journal: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Activity

    /// What the file system is doing right now, for the app's status UI.
    public struct Activity: Sendable, Equatable {
        public struct Stream: Sendable, Equatable {
            public let name: String
            public let bytesPerSecond: UInt64

            public init(name: String, bytesPerSecond: UInt64) {
                self.name = name
                self.bytesPerSecond = bytesPerSecond
            }
        }
        public struct Upload: Sendable, Equatable {
            public let name: String
            public let sent: UInt64
            public let total: UInt64

            public init(name: String, sent: UInt64, total: UInt64) {
                self.name = name
                self.sent = sent
                self.total = total
            }
        }
        /// Files being read, fastest first.
        public var streams: [Stream] = []
        /// Files waiting to upload or uploading, by name.
        public var uploads: [Upload] = []

        public init(streams: [Stream] = [], uploads: [Upload] = []) {
            self.streams = streams
            self.uploads = uploads
        }
    }

    /// A file counts as streaming while it has been read within this window.
    static let rateWindow: TimeInterval = 3

    public func activity(now: Date = Date()) -> Activity {
        var result = Activity()
        for id in Array(reads.keys) {
            pruneReads(id, now: now)
            guard let window = reads[id], let name = nodes[id]?.name else { continue }
            let bytes = window.reduce(0) { $0 + $1.bytes }
            result.streams.append(.init(name: name, bytesPerSecond: UInt64(Double(bytes) / Self.rateWindow)))
        }
        result.streams.sort { $0.bytesPerSecond > $1.bytesPerSecond }
        for (id, p) in pending where !p.localOnly {
            let total = (try? staging.size(p.staging)) ?? 0
            result.uploads.append(.init(name: p.name, sent: min(uploadSent[id] ?? 0, total), total: total))
        }
        result.uploads.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    private func recordRead(_ id: UInt64, bytes: Int) {
        let now = Date()
        reads[id, default: []].append((now, bytes))
        pruneReads(id, now: now)
    }

    private func pruneReads(_ id: UInt64, now: Date) {
        reads[id]?.removeAll { now.timeIntervalSince($0.at) > Self.rateWindow }
        if reads[id]?.isEmpty == true { reads[id] = nil }
    }

    // MARK: Listings

    private func folder(_ id: UInt64) async throws -> Folder {
        guard let node = nodes[id] else { throw NFSStatus.stale }
        guard let remote = node.remote, remote.isFolder else { throw NFSStatus.notdir }
        if let f = folders[id], f.fetched.timeIntervalSinceNow > -listingTTL { return f }

        // One listing per folder at a time; concurrent lookups wait for it.
        if let running = listing[id] {
            try await running.value
        } else {
            let task = Task { try await self.refresh(id, driveID: remote.id) }
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
        // Files written here but not uploaded yet come first, so they keep the names they were given.
        for (pid, p) in pending.sorted(by: { $0.key < $1.key }) where p.driveID == nil && p.parentDriveID == driveID {
            if nodes[pid] == nil { nodes[pid] = Node(name: p.name, parent: id, remote: nil) }
            nodes[pid]?.name = p.name
            children[p.name] = pid
            ordered.append(pid)
        }
        // Listing is ordered by creation, so the older of two same-named files keeps the plain name.
        for file in files where file.isFolder || file.isStreamable {
            let childID = nodeID(for: file.id)
            let name = pending[childID]?.name ?? Self.uniqueName(Self.displayName(file.name), taken: children)
            nodes[childID] = Node(name: name, parent: id, remote: file)
            children[name] = childID
            ordered.append(childID)
        }
        var hasher = Hasher64()
        for child in ordered {
            hasher.combine(nodes[child]?.name ?? "")
            hasher.combine(nodes[child]?.remote.map(Self.version(of:)) ?? "pending-\(child)")
        }
        folders[id] = Folder(children: children, ordered: ordered, fetched: Date(), version: hasher.value | 1)
    }

    private func insert(_ id: UInt64, named name: String, in directory: UInt64) {
        guard var f = folders[directory] else { return }
        f.children[name] = id
        if !f.ordered.contains(id) { f.ordered.append(id) }
        f.version = (f.version &+ 2) | 1
        folders[directory] = f
    }

    private func removeChild(named name: String, from directory: UInt64) {
        guard var f = folders[directory], let id = f.children.removeValue(forKey: name) else { return }
        f.ordered.removeAll { $0 == id }
        f.version = (f.version &+ 2) | 1
        folders[directory] = f
    }

    // MARK: Paths

    /// The Drive item at a slash-separated path below the root, as Finder shows it.
    /// The empty path is the root.
    public func item(atPath path: String) async throws -> DriveFile {
        var id = rootID
        for name in path.split(separator: "/").map(String.init) {
            guard let child = try await folder(id).children[name] else { throw NFSStatus.noent }
            id = child
        }
        guard let remote = nodes[id]?.remote else { throw NFSStatus.noent }  // not uploaded yet
        return remote
    }

    /// Drive ids of the folders above `id`, nearest first.
    private func driveAncestors(of id: UInt64) -> [String] {
        var result: [String] = []
        var current = id
        while current != rootID, let parent = nodes[current]?.parent {
            if let remote = nodes[parent]?.remote { result.append(remote.id) }
            current = parent
        }
        return result
    }

    // MARK: Helpers

    private func driveID(ofFolder id: UInt64) throws -> String {
        guard let remote = nodes[id]?.remote, remote.isFolder else { throw NFSStatus.notdir }
        return remote.id
    }

    /// Stable id derived from the Drive id, so handles survive a restart; probes on collision.
    private func nodeID(for driveID: String) -> UInt64 {
        if let id = idByDriveID[driveID] { return id }
        var h = Hasher64()
        h.combine(driveID)
        var id = h.value & 0x7FFF_FFFF_FFFF_FFFF
        while id <= rootID || nodes[id] != nil || pending[id] != nil { id &+= 1 }
        idByDriveID[driveID] = id
        return id
    }

    /// Id for a file that exists only locally so far. Kept in the journal, so it survives restarts.
    private func newNodeID() -> UInt64 {
        var id: UInt64
        repeat { id = UInt64.random(in: 2...0x7FFF_FFFF_FFFF_FFFF) } while nodes[id] != nil || pending[id] != nil
        return id
    }

    /// Runs a Drive call, mapping failures to NFS status codes.
    private func call<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            log.error("drive call failed: \(String(describing: error), privacy: .public)")
            throw Self.status(for: error)
        }
    }

    static func version(of file: DriveFile) -> String {
        file.contentVersion
    }

    /// Finder's metadata files: kept on this Mac, never uploaded.
    static func isLocalOnly(_ name: String) -> Bool {
        name.hasPrefix("._") || [".DS_Store", ".localized", "Icon\r", ".VolumeIcon.icns"].contains(name)
    }

    static let refusedDirectories: Set<String> = [
        ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100",
    ]

    /// Drive allows "/" in names; Finder shows ":" in a POSIX name as "/".
    static func displayName(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: ":")
        return n.isEmpty || n == "." || n == ".." ? "_\(n)" : n
    }

    /// The inverse of `displayName` for names created on the Mac.
    static func driveName(_ name: String) -> String {
        name.replacingOccurrences(of: ":", with: "/")
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
