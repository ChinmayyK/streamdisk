import Foundation
import Testing
import NFSServer

/// Writes through the real macOS NFS client. Opt in with STREAMDISK_MOUNT_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STREAMDISK_MOUNT_TESTS"] == "1"))
struct WriteMountTests {
    @Test func createsWritesRenamesAndRemovesThroughTheSystemClient() async throws {
        let backend = MemoryBackend(files: ["existing.txt": Array("old contents".utf8)])
        let server = try LocalNFSServer(backend: backend)
        let port = try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streamdisk-write-\(UUID().uuidString)")
        try NFSMount.mount(port: port, at: root)
        defer {
            try? NFSMount.unmount(root, force: true)
            try? FileManager.default.removeItem(at: root)
        }
        let fm = FileManager.default

        // A 5 MiB file goes through many WRITEs and a COMMIT.
        let big = (0..<(5 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        try Data(big).write(to: root.appendingPathComponent("big.bin"))
        #expect(Array(try Data(contentsOf: root.appendingPathComponent("big.bin"))) == big)
        #expect(await backend.contents("big.bin") == big)

        // Overwrite truncates; append extends.
        try Data("new".utf8).write(to: root.appendingPathComponent("existing.txt"))
        #expect(await backend.contents("existing.txt") == Array("new".utf8))
        let handle = try Foundation.FileHandle(forWritingTo: root.appendingPathComponent("existing.txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+more".utf8))
        try handle.close()
        #expect(await backend.contents("existing.txt") == Array("new+more".utf8))

        // Directories, moves and renames.
        try fm.createDirectory(at: root.appendingPathComponent("films/2026"), withIntermediateDirectories: true)
        try fm.moveItem(at: root.appendingPathComponent("big.bin"), to: root.appendingPathComponent("films/2026/clip.bin"))
        #expect(await backend.contents("films/2026/clip.bin") == big)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("big.bin").path))

        // Modification dates set by the client are kept (Finder copies preserve them).
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent("existing.txt").path)
        let attrs = try fm.attributesOfItem(atPath: root.appendingPathComponent("existing.txt").path)
        #expect((attrs[.modificationDate] as? Date).map { abs($0.timeIntervalSince(date)) < 1 } == true)

        // Removing a non-empty directory fails; emptying it first works.
        #expect(rmdir(root.appendingPathComponent("films/2026").path) == -1 && errno == ENOTEMPTY)
        try fm.removeItem(at: root.appendingPathComponent("films/2026/clip.bin"))
        try fm.removeItem(at: root.appendingPathComponent("films"))
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") } == ["existing.txt"])
    }
}
