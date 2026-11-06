import Foundation
import NFSServer
import Testing
@testable import StreamDiskCore

/// Copies files into a real mount backed by the fake Drive. Opt in with STREAMDISK_MOUNT_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STREAMDISK_MOUNT_TESTS"] == "1"))
struct DriveMountTests {
    @Test func copyRenameDeleteThroughFinderAPIsReachDrive() async throws {
        let drive = FakeDrive()
        await drive.add("existing.mov", data: Data(repeating: 3, count: 4096))
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("sd-state-\(UUID().uuidString)")
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state, uploadDelay: .milliseconds(300))
        await fs.start()
        let server = try LocalNFSServer(backend: fs)
        let port = try await server.start()
        defer { server.stop() }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("sd-mount-\(UUID().uuidString)")
        try NFSMount.mount(port: port, at: mount)
        defer {
            try? NFSMount.unmount(mount, force: true)
            try? FileManager.default.removeItem(at: mount)
        }
        let fm = FileManager.default

        // copyItem behaves like a Finder copy: data, dates and extended attributes.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("sd-src-\(UUID().uuidString).bin")
        let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try payload.write(to: source)
        defer { try? fm.removeItem(at: source) }
        try fm.copyItem(at: source, to: mount.appendingPathComponent("copied.bin"))

        func eventually(_ check: () async -> Bool) async -> Bool {
            for _ in 0..<300 {
                if await check() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        #expect(await eventually { await drive.item(at: "copied.bin")?.data == payload })
        #expect(try Data(contentsOf: mount.appendingPathComponent("copied.bin")) == payload)

        try fm.createDirectory(at: mount.appendingPathComponent("Films"), withIntermediateDirectories: false)
        try fm.moveItem(at: mount.appendingPathComponent("copied.bin"), to: mount.appendingPathComponent("Films/moved.bin"))
        #expect(await drive.item(at: "Films/moved.bin")?.data == payload)

        try fm.removeItem(at: mount.appendingPathComponent("existing.mov"))
        #expect(await drive.trashed("existing.mov"))
        #expect(await drive.item(at: "._copied.bin") == nil)  // Finder metadata never uploads
    }
}
