import Foundation
import NFSServer
import Testing
@testable import StreamDiskCore

@Suite struct DriveFileSystemActivityTests {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("sd-state-\(UUID().uuidString)")

    @Test func readsShowAsAStreamUntilTheyStop() async throws {
        let drive = FakeDrive()
        await drive.add("film.mov", data: Data(repeating: 7, count: 300_000))
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state)
        let film = try await fs.lookup("film.mov", in: fs.rootID)
        _ = try await fs.read(film.id, offset: 0, count: 150_000)
        _ = try await fs.read(film.id, offset: 150_000, count: 150_000)

        let now = await fs.activity()
        #expect(now.streams == [.init(name: "film.mov", bytesPerSecond: 100_000)])

        let later = await fs.activity(now: Date().addingTimeInterval(DriveFileSystem.rateWindow + 1))
        #expect(later.streams.isEmpty)
    }

    @Test func stagedFilesShowAsUploadsUntilDone() async throws {
        let drive = FakeDrive()
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state,
                                     uploadDelay: .milliseconds(150))
        await fs.start()
        let f = try await fs.create("notes.txt", in: fs.rootID, mode: .guarded)
        _ = try await fs.write(f.id, offset: 0, data: Array("hello".utf8))
        let finderMeta = try await fs.create("._notes.txt", in: fs.rootID, mode: .guarded)
        _ = try await fs.write(finderMeta.id, offset: 0, data: [1])

        // Local-only Finder files never upload, so they are not listed.
        #expect(await fs.activity().uploads == [.init(name: "notes.txt", sent: 0, total: 5)])

        var done = false
        for _ in 0..<100 where !done {
            try await Task.sleep(for: .milliseconds(10))
            done = await fs.activity().uploads.isEmpty
        }
        #expect(done)
    }
}
