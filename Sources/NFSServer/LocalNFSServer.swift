import Foundation

/// Serves a backend over NFSv3 on 127.0.0.1 and mounts it with the system NFS client.
public final class LocalNFSServer: Sendable {
    private let rpc: RPCServer

    public init(backend: any FileSystemBackend, port: UInt16 = 0) throws {
        let uid = getuid()
        rpc = try RPCServer(
            programs: [NFSProgram(backend: backend), MountProgram(rootID: backend.rootID)],
            port: port,
            // Only this user (and root, which can read their files anyway) may use the export.
            authorize: { auth in
                if case .sys(let caller, _) = auth { return caller == uid || caller == 0 }
                return false
            })
    }

    /// Starts serving and returns the bound port.
    public func start() async throws -> UInt16 {
        try await rpc.start()
    }

    public func stop() {
        rpc.stop()
    }
}

public enum NFSMount {
    public struct Failure: Error, CustomStringConvertible {
        public let status: Int32
        public let output: String
        public var description: String { "mount failed (\(status)): \(output)" }
    }

    /// Mounts the server on `port` at `directory` (created if missing). No root needed:
    /// macOS lets a user mount NFS on a directory they own.
    public static func mount(port: UInt16, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let options = [
            "port=\(port)", "mountport=\(port)", "vers=3", "tcp",
            // Locking stays local: there is no lock manager behind this server.
            "locallocks", "noresvport",
            // Soft mount with retries so a network outage returns errors instead of hanging Finder.
            "soft", "intr", "timeo=100", "retrans=3", "retrycnt=0",
            "rsize=1048576", "wsize=1048576", "readahead=16",
            "actimeo=5", "nobrowse",
        ]
        try run("/sbin/mount_nfs", ["-o", options.joined(separator: ","), "127.0.0.1:/", directory.path])
    }

    public static func unmount(_ directory: URL, force: Bool = false) throws {
        try run("/sbin/umount", (force ? ["-f"] : []) + [directory.path])
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure(status: p.terminationStatus, output: out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
