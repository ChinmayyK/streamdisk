import Foundation
import Testing
import NFSServer

/// Mounts a real NFS volume through /sbin/mount_nfs. Opt in with STREAMDISK_MOUNT_TESTS=1
/// because it changes system mount state and needs a macOS host.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STREAMDISK_MOUNT_TESTS"] == "1"))
struct MountTests {
    @Test func mountsListsAndReadsThroughTheSystemClient() async throws {
        // 9 MiB + 3 bytes of patterned data: spans many READs and ends off a block boundary.
        let big = (0..<(9 * 1024 * 1024 + 3)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let many = Dictionary(uniqueKeysWithValues: (0..<300).map { ("many/file-\($0).txt", Array("\($0)".utf8)) })
        let backend = MemoryBackend(files: many.merging([
            "hello.txt": Array("hello\n".utf8),
            "films/big.bin": big,
            "films/empty.bin": [],
        ]) { a, _ in a })

        let server = try LocalNFSServer(backend: backend)
        let port = try await server.start()
        defer { server.stop() }

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamdisk-test-\(UUID().uuidString)")
        try NFSMount.mount(port: port, at: mountPoint)
        defer {
            try? NFSMount.unmount(mountPoint, force: true)
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: mountPoint.path).sorted() == ["films", "hello.txt", "many"])
        #expect(try fm.contentsOfDirectory(atPath: mountPoint.appendingPathComponent("many").path).count == 300)
        #expect(try String(contentsOf: mountPoint.appendingPathComponent("hello.txt"), encoding: .utf8) == "hello\n")

        let bigURL = mountPoint.appendingPathComponent("films/big.bin")
        #expect(Array(try Data(contentsOf: bigURL)) == big)
        #expect(try Data(contentsOf: mountPoint.appendingPathComponent("films/empty.bin")).isEmpty)

        // Random access in the middle of the file, the way a video player seeks.
        let handle = try Foundation.FileHandle(forReadingFrom: bigURL)
        try handle.seek(toOffset: 5_000_001)
        #expect(Array(try handle.read(upToCount: 4096) ?? Data()) == Array(big[5_000_001..<5_004_097]))
        try handle.close()

        // Streamed files report their full size but no bytes on disk.
        let values = try bigURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == big.count)
        #expect(values.totalFileAllocatedSize == 0)
    }
}
