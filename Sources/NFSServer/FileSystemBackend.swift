import Foundation

/// NFSv3 status codes (RFC 1813 §2.6). Backends throw these to report failures.
public enum NFSStatus: UInt32, Error, Sendable {
    case ok = 0
    case perm = 1
    case noent = 2
    case io = 5
    case acces = 13
    case exist = 17
    case notdir = 20
    case isdir = 21
    case inval = 22
    case fbig = 27
    case nospc = 28
    case rofs = 30
    case nameTooLong = 63
    case notEmpty = 66
    case stale = 70
    case badHandle = 10001
    case badCookie = 10003
    case notSupported = 10004
    case serverFault = 10006
    /// "Try again later": the client retries. Used while a remote fetch is slow.
    case jukebox = 10008
}

public struct FileAttributes: Sendable, Equatable {
    public enum Kind: Sendable { case file, directory }

    public var id: UInt64
    public var kind: Kind
    public var size: UInt64
    /// Bytes stored on this Mac. Zero for streamed files, which is what Finder reports as "on disk".
    public var bytesOnDisk: UInt64
    public var permissions: UInt16
    public var modified: Date
    public var changed: Date

    public init(id: UInt64, kind: Kind, size: UInt64, bytesOnDisk: UInt64 = 0,
                permissions: UInt16? = nil, modified: Date, changed: Date? = nil) {
        self.id = id
        self.kind = kind
        self.size = size
        self.bytesOnDisk = bytesOnDisk
        self.permissions = permissions ?? (kind == .directory ? 0o755 : 0o644)
        self.modified = modified
        self.changed = changed ?? modified
    }
}

public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var attributes: FileAttributes

    public init(name: String, attributes: FileAttributes) {
        self.name = name
        self.attributes = attributes
    }
}

public struct DirectoryListing: Sendable {
    public var entries: [DirectoryEntry]
    /// Changes whenever the listing changes, so paged reads can detect a stale cursor.
    public var version: UInt64

    public init(entries: [DirectoryEntry], version: UInt64) {
        self.entries = entries
        self.version = version
    }
}

public struct VolumeStatistics: Sendable {
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var totalFiles: UInt64
    public var freeFiles: UInt64

    public init(totalBytes: UInt64, freeBytes: UInt64, totalFiles: UInt64 = 1 << 32, freeFiles: UInt64 = 1 << 31) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.totalFiles = totalFiles
        self.freeFiles = freeFiles
    }
}

/// The file system the NFS server exposes. Node ids must stay stable for the life of the mount;
/// they become NFS file handles. Methods throw `NFSStatus`; any other error is reported as `.io`.
public protocol FileSystemBackend: Sendable {
    var rootID: UInt64 { get }
    func attributes(of id: UInt64) async throws -> FileAttributes
    func lookup(_ name: String, in directory: UInt64) async throws -> FileAttributes
    func list(_ directory: UInt64) async throws -> DirectoryListing
    /// Returns up to `count` bytes at `offset`; fewer only at end of file.
    func read(_ id: UInt64, offset: UInt64, count: Int) async throws -> [UInt8]
    func statistics() async throws -> VolumeStatistics
}
