import Foundation
import os
import Synchronization

/// Files and folders the user chose to keep on this Mac.
///
/// A kept item stays in Drive and on the disk as before; a full copy of its content (every file
/// inside, for a folder) is also downloaded here, so opening it needs no network. Copies follow
/// Drive: changed files download again, files no longer inside a kept folder are deleted.
///
/// The file system asks `read(_:version:offset:count:)` first and streams from Drive only when
/// there is no current copy. That check is lock-protected and never waits on the actor.
public actor OfflineStore {
    /// Something the user chose to keep.
    public struct Pin: Codable, Sendable, Equatable, Identifiable {
        public let driveID: String
        public var name: String
        public let isFolder: Bool
        /// Where it was on the disk when kept, for showing to the user.
        public var path: String
        public let added: Date

        public var id: String { driveID }

        public init(driveID: String, name: String, isFolder: Bool, path: String, added: Date) {
            self.driveID = driveID
            self.name = name
            self.isFolder = isFolder
            self.path = path
            self.added = added
        }
    }

    public struct PinStatus: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable {
            /// Every file has a current copy.
            case ready
            /// Copies are missing or out of date and are being fetched.
            case downloading
            /// The last attempt to fetch it failed; it is retried later.
            case failed(String)
        }

        public let pin: Pin
        public let files: Int
        /// The size of everything in it.
        public let bytes: UInt64
        /// How much of that is on this Mac now.
        public let stored: UInt64
        public let state: State

        public var id: String { pin.driveID }

        public init(pin: Pin, files: Int, bytes: UInt64, stored: UInt64, state: State) {
            self.pin = pin
            self.files = files
            self.bytes = bytes
            self.stored = stored
            self.state = state
        }
    }

    /// A downloaded or downloading copy of one Drive file.
    struct Copy: Codable {
        var version: String
        var size: UInt64
        /// Bytes written so far; the copy is usable once this reaches `size`.
        var stored: UInt64
        /// The pins that want this file.
        var pins: Set<String>

        var complete: Bool { stored == size }
    }

    private struct State: Codable {
        var pins: [Pin] = []
        var copies: [String: Copy] = [:]
    }

    /// Complete copies by Drive id: the version they hold.
    private let ready = Mutex<[String: String]>([:])

    private let drive: any DriveService
    private let files: URL
    private let stateURL: URL
    private let chunk: UInt64
    private let interval: Duration
    private let log = Logger(subsystem: "app.streamdisk", category: "offline")
    private var state = State()
    /// What each pin contained at the last successful sync.
    private var contents: [String: [DriveFile]] = [:]
    private var failures: [String: String] = [:]
    private var syncing: Task<Void, Never>?
    private var again = false
    private var timer: Task<Void, Never>?

    /// - Parameters:
    ///   - directory: Holds the copies and the list of kept items.
    ///   - interval: How often kept folders are checked for new and changed files.
    public init(drive: any DriveService, directory: URL, chunk: UInt64 = 8 << 20, interval: Duration = .seconds(300)) throws {
        self.drive = drive
        self.files = directory.appendingPathComponent("Files", isDirectory: true)
        self.stateURL = directory.appendingPathComponent("kept.json")
        self.chunk = chunk
        self.interval = interval
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var loaded = State()
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            loaded = saved
        }
        // Trust the files on disk over the record: a copy may have been cut short by a quit.
        for (id, copy) in loaded.copies {
            let path = files.appendingPathComponent(id).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            loaded.copies[id]?.stored = min(size, copy.size)
        }
        state = loaded
        let complete = loaded.copies.filter(\.value.complete).mapValues(\.version)
        ready.withLock { $0 = complete }
    }

    /// Starts keeping copies current: now, and then every `interval`.
    public func start() {
        sync()
        timer?.cancel()
        timer = Task { [interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self.sync()
            }
        }
    }

    public func stop() {
        timer?.cancel()
        syncing?.cancel()
    }

    // MARK: Reading

    /// Whether a complete copy of this version of the file is on this Mac.
    public nonisolated func hasCopy(_ driveID: String, version: String) -> Bool {
        ready.withLock { $0[driveID] == version }
    }

    /// Reads from the local copy, or returns nil when there is no complete copy of `version`.
    public nonisolated func read(_ driveID: String, version: String, offset: UInt64, count: Int) -> [UInt8]? {
        guard hasCopy(driveID, version: version) else { return nil }
        let fd = open(url(driveID).path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: count)
        let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n >= 0 else { return nil }
        buffer.removeSubrange(n...)
        return buffer
    }

    // MARK: Pins

    public var pins: [Pin] { state.pins }

    /// Keeps `file` (and, for a folder, everything in it) on this Mac.
    public func keep(_ file: DriveFile, path: String) {
        guard !state.pins.contains(where: { $0.driveID == file.id }) else { return }
        state.pins.append(Pin(driveID: file.id, name: file.name, isFolder: file.isFolder, path: path, added: Date()))
        save()
        sync()
    }

    /// Stops keeping the item and deletes the copies only it needed.
    public func remove(_ driveID: String) {
        state.pins.removeAll { $0.driveID == driveID }
        contents[driveID] = nil
        failures[driveID] = nil
        for (id, var copy) in state.copies where copy.pins.contains(driveID) {
            copy.pins.remove(driveID)
            if copy.pins.isEmpty { deleteCopy(id) } else { state.copies[id] = copy }
        }
        save()
    }

    /// The item was deleted from the disk: forget its pin, if it had one.
    public func forget(_ driveID: String) {
        if state.pins.contains(where: { $0.driveID == driveID }) { remove(driveID) }
    }

    /// Whether `driveIDs` (a file and the folders above it) include a kept item.
    public func isKept(_ driveIDs: [String]) -> Bool {
        let pinned = Set(state.pins.map(\.driveID))
        return driveIDs.contains { pinned.contains($0) }
    }

    /// A file inside a kept item finished uploading from `local`: move that file in as its
    /// copy instead of downloading what was just uploaded.
    /// - Parameter ancestors: The file's Drive id and those of the folders above it.
    /// - Returns: Whether the file was taken.
    public func adopt(_ file: DriveFile, from local: URL, ancestors: [String]) -> Bool {
        let wanting = Set(state.pins.map(\.driveID)).intersection(ancestors)
        guard !wanting.isEmpty else { return false }
        let target = url(file.id)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: local, to: target)
        } catch {
            return false
        }
        var pins = state.copies[file.id]?.pins ?? []
        pins.formUnion(wanting)
        state.copies[file.id] = Copy(version: file.contentVersion, size: file.size, stored: file.size, pins: pins)
        ready.withLock { $0[file.id] = file.contentVersion }
        for pin in wanting where !(contents[pin]?.contains { $0.id == file.id } ?? true) {
            contents[pin]?.append(file)
        }
        save()
        return true
    }

    // MARK: Status

    public func status() -> [PinStatus] {
        state.pins.map { pin in
            var count = 0
            var bytes: UInt64 = 0
            var stored: UInt64 = 0
            if let files = contents[pin.driveID] {
                count = files.count
                for f in files {
                    bytes += f.size
                    if let copy = state.copies[f.id], copy.version == f.contentVersion { stored += copy.stored }
                }
            } else {
                // Not checked against Drive yet (just launched, or offline): show what is here.
                for copy in state.copies.values where copy.pins.contains(pin.driveID) {
                    count += 1
                    bytes += copy.size
                    stored += copy.stored
                }
            }
            let state: PinStatus.State = if let failure = failures[pin.driveID] {
                .failed(failure)
            } else if contents[pin.driveID] == nil || stored < bytes {
                .downloading
            } else {
                .ready
            }
            return PinStatus(pin: pin, files: count, bytes: bytes, stored: stored, state: state)
        }
    }

    /// Space the copies take on this Mac.
    public var bytesOnDisk: UInt64 {
        state.copies.values.reduce(0) { $0 + $1.stored }
    }

    // MARK: Syncing

    /// Brings copies in line with Drive. Coalesces: a request during a sync runs one more after it.
    public func sync() {
        if syncing != nil { again = true; return }
        syncing = Task {
            repeat {
                again = false
                await syncOnce()
            } while again && !Task.isCancelled
            syncing = nil
        }
    }

    /// Waits for the current sync, if any. For tests.
    func idle() async {
        while let running = syncing { await running.value }
    }

    private func syncOnce() async {
        // Work out what each pin contains now. A pin that can't be read keeps its copies.
        for pin in state.pins {
            do {
                let found = try await resolve(pin)
                guard state.pins.contains(where: { $0.driveID == pin.driveID }) else { continue }
                guard let found else {
                    log.info("kept item \(pin.name, privacy: .public) is gone from Drive")
                    remove(pin.driveID)
                    continue
                }
                contents[pin.driveID] = found.files
                if found.name != pin.name, let i = state.pins.firstIndex(where: { $0.driveID == pin.driveID }) {
                    state.pins[i].name = found.name
                }
                failures[pin.driveID] = nil
            } catch is CancellationError {
                return
            } catch {
                failures[pin.driveID] = Self.describe(error)
            }
        }

        // Record which pins want which files, and delete copies nobody wants.
        var keep: [String: Set<String>] = [:]
        var current: [String: DriveFile] = [:]
        for pin in state.pins {
            if let files = contents[pin.driveID] {
                for file in files {
                    keep[file.id, default: []].insert(pin.driveID)
                    current[file.id] = file
                }
            } else {
                // Not resolved (offline): keep the copies it had.
                for (id, copy) in state.copies where copy.pins.contains(pin.driveID) {
                    keep[id, default: []].insert(pin.driveID)
                }
            }
        }
        for id in state.copies.keys where keep[id] == nil { deleteCopy(id) }
        for (id, pins) in keep { state.copies[id]?.pins = pins }
        save()

        // Download what is missing or out of date, smallest first so more files are ready sooner.
        let todo = current.values
            .filter { file in
                guard let copy = state.copies[file.id] else { return true }
                return copy.version != file.contentVersion || !copy.complete
            }
            .sorted { $0.size < $1.size }
        for file in todo {
            if Task.isCancelled { return }
            do {
                try await download(file, pins: keep[file.id] ?? [])
            } catch is CancellationError {
                return
            } catch {
                log.error("could not keep \(file.name, privacy: .public): \(String(describing: error), privacy: .public)")
                for pin in keep[file.id] ?? [] { failures[pin] = Self.describe(error) }
            }
        }
    }

    /// The streamable files in a pin, or nil if it was deleted from Drive.
    private func resolve(_ pin: Pin) async throws -> (name: String, files: [DriveFile])? {
        let top: DriveFile
        do {
            top = try await drive.file(pin.driveID)
        } catch DriveError.http(let status, _) where status == 404 {
            return nil
        }
        if top.trashed { return nil }
        guard top.isFolder else { return (top.name, top.isStreamable ? [top] : []) }
        var files: [DriveFile] = []
        var folders = [top.id]
        var seen: Set<String> = [top.id]
        while let folder = folders.popLast() {
            for child in try await drive.children(of: folder) {
                if child.isFolder {
                    if seen.insert(child.id).inserted { folders.append(child.id) }
                } else if child.isStreamable {
                    files.append(child)
                }
            }
        }
        return (top.name, files)
    }

    /// Downloads `file`, resuming a partial copy of the same version.
    private func download(_ file: DriveFile, pins: Set<String>) async throws {
        let target = url(file.id)
        var copy = state.copies[file.id] ?? Copy(version: file.contentVersion, size: file.size, stored: 0, pins: pins)
        if copy.version != file.contentVersion || copy.size != file.size {
            ready.withLock { $0[file.id] = nil }
            copy = Copy(version: file.contentVersion, size: file.size, stored: 0, pins: pins)
        }
        if copy.stored == 0 {
            try? FileManager.default.removeItem(at: target)
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        state.copies[file.id] = copy
        save()

        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.truncate(atOffset: copy.stored)
        try handle.seek(toOffset: copy.stored)
        while copy.stored < copy.size {
            try Task.checkCancellation()
            let end = min(copy.size, copy.stored + chunk)
            let data = try await drive.download(file.id, range: copy.stored..<end)
            // The file was removed from kept items while this chunk was in flight.
            guard state.copies[file.id] != nil else { return }
            try handle.write(contentsOf: data)
            copy.stored = end
            state.copies[file.id]?.stored = end
        }
        try handle.synchronize()
        ready.withLock { $0[file.id] = copy.version }
        save()
        log.info("kept \(file.name, privacy: .public) on this Mac")
    }

    // MARK: Storage

    private nonisolated func url(_ driveID: String) -> URL {
        files.appendingPathComponent(driveID)
    }

    private func deleteCopy(_ id: String) {
        ready.withLock { $0[id] = nil }
        state.copies[id] = nil
        try? FileManager.default.removeItem(at: url(id))
    }

    private func save() {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            log.error("could not save kept items: \(String(describing: error), privacy: .public)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost:
                return "Waiting for a connection"
            default: break
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain,
           (error as NSError).code == NSFileWriteOutOfSpaceError || (error as NSError).code == Int(ENOSPC) {
            return "Not enough space on this Mac"
        }
        return "Couldn't download from Drive"
    }
}
