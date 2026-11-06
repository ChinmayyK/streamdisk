import Darwin
import Foundation
import NFSServer

/// Local files holding written content until it is uploaded. Names are opaque; the journal
/// records what each one belongs to. File descriptors stay open while a file is being written.
final class StagingStore: @unchecked Sendable {
    // `open` is guarded by `lock`; file contents are only touched through the descriptors.
    let directory: URL
    private var open: [String: Int32] = [:]
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// A new, empty staging file.
    func create() throws -> String {
        let name = UUID().uuidString
        _ = try descriptor(name, create: true)
        return name
    }

    func write(_ name: String, offset: UInt64, data: [UInt8]) throws {
        let fd = try descriptor(name)
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard written == data.count else { throw Self.error() }
    }

    func read(_ name: String, offset: UInt64, count: Int) throws -> [UInt8] {
        let fd = try descriptor(name)
        var buffer = [UInt8](repeating: 0, count: count)
        let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n >= 0 else { throw Self.error() }
        return Array(buffer.prefix(n))
    }

    func truncate(_ name: String, to size: UInt64) throws {
        guard ftruncate(try descriptor(name), off_t(size)) == 0 else { throw Self.error() }
    }

    func size(_ name: String) throws -> UInt64 {
        var st = stat()
        guard fstat(try descriptor(name), &st) == 0 else { throw Self.error() }
        return UInt64(st.st_size)
    }

    func sync(_ name: String) throws {
        guard fsync(try descriptor(name)) == 0 else { throw Self.error() }
    }

    /// Closes the descriptor; the file stays.
    func close(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        if let fd = open.removeValue(forKey: name) { Darwin.close(fd) }
    }

    func delete(_ name: String) {
        close(name)
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Staging files no journal entry refers to, left by a crash between steps.
    func removeAll(except keep: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !keep.contains(name) { delete(name) }
    }

    private func descriptor(_ name: String, create: Bool = false) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let fd = open[name] { return fd }
        let fd = Darwin.open(url(name).path, O_RDWR | (create ? O_CREAT | O_EXCL : 0), 0o600)
        guard fd >= 0 else { throw Self.error() }
        open[name] = fd
        return fd
    }

    private static func error() -> NFSStatus {
        errno == ENOSPC ? .nospc : .io
    }
}
