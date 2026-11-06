import Foundation
import NFSServer
import Testing
@testable import StreamDiskCore

@Suite struct DriveFileSystemWriteTests {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("sd-state-\(UUID().uuidString)")

    private func makeFS(_ drive: FakeDrive, delay: Duration = .milliseconds(40)) async throws -> DriveFileSystem {
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state, uploadDelay: delay)
        await fs.start()
        return fs
    }

    /// Waits until `check` passes or a second elapses.
    private func eventually(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func newFileStagesThenUploadsUnderTheSameID() async throws {
        let drive = FakeDrive()
        let fs = try await makeFS(drive)
        let created = try await fs.create("notes.txt", in: fs.rootID, mode: .guarded)
        _ = try await fs.write(created.id, offset: 0, data: Array("hello".utf8))

        let staged = try await fs.attributes(of: created.id)
        #expect(staged.size == 5 && staged.bytesOnDisk == 5)  // on this Mac until uploaded

        #expect(await eventually { await drive.item(at: "notes.txt")?.data == Data("hello".utf8) })
        let uploaded = try await fs.attributes(of: created.id)
        #expect(uploaded.id == created.id && uploaded.bytesOnDisk == 0)
        #expect(try await fs.read(created.id, offset: 1, count: 3) == Array("ell".utf8))
        // A fresh listing maps the Drive file back to the same node id.
        #expect(try await fs.list(fs.rootID).entries.map(\.attributes.id) == [created.id])
    }

    @Test func renameBeforeUploadUploadsUnderTheNewName() async throws {
        let drive = FakeDrive()
        let fs = try await makeFS(drive, delay: .milliseconds(150))
        let f = try await fs.create("draft", in: fs.rootID, mode: .guarded)
        _ = try await fs.write(f.id, offset: 0, data: [1, 2, 3])
        try await fs.rename("draft", from: fs.rootID, to: "final.bin", in: fs.rootID)
        #expect(await eventually { await drive.item(at: "final.bin") != nil })
        #expect(await drive.item(at: "draft") == nil)
        #expect(await drive.uploadCount == 1)
    }

    @Test func atomicSaveReplacesTheOldFile() async throws {
        let drive = FakeDrive()
        await drive.add("doc.txt", data: Data("v1".utf8))
        let fs = try await makeFS(drive)
        _ = try await fs.list(fs.rootID)
        let temp = try await fs.create("doc.txt.sb-1234", in: fs.rootID, mode: .guarded)
        _ = try await fs.write(temp.id, offset: 0, data: Array("v2".utf8))
        try await fs.rename("doc.txt.sb-1234", from: fs.rootID, to: "doc.txt", in: fs.rootID)
        #expect(await eventually { await drive.item(at: "doc.txt")?.data == Data("v2".utf8) })
        #expect(await drive.trashed("doc.txt"))  // the old version, recoverable
        #expect(try await fs.list(fs.rootID).entries.map(\.name) == ["doc.txt"])
    }

    @Test func truncateAndRewriteReplacesContentKeepingTheDriveFile() async throws {
        let drive = FakeDrive()
        let original = await drive.add("data.csv", data: Data("a,b\n".utf8))
        let fs = try await makeFS(drive)
        let attrs = try await fs.lookup("data.csv", in: fs.rootID)
        _ = try await fs.setAttributes(attrs.id, size: 0, modified: nil)
        _ = try await fs.write(attrs.id, offset: 0, data: Array("x,y\n".utf8))
        #expect(await eventually { await drive.item(at: "data.csv")?.data == Data("x,y\n".utf8) })
        #expect(await drive.item(at: "data.csv")?.file.id == original.id)
    }

    @Test func partialEditOfRemoteFileDownloadsItFirst() async throws {
        let drive = FakeDrive()
        await drive.add("big.bin", data: Data(repeating: 7, count: 20_000))
        let fs = try await makeFS(drive)
        let attrs = try await fs.lookup("big.bin", in: fs.rootID)
        _ = try await fs.write(attrs.id, offset: 10_000, data: [1, 2])
        #expect(await eventually {
            guard let d = await drive.item(at: "big.bin")?.data else { return false }
            return d.count == 20_000 && d[10_000] == 1 && d[10_001] == 2 && d[0] == 7
        })
    }

    @Test func removeMovesToTrashAndFolderOpsHitDrive() async throws {
        let drive = FakeDrive()
        await drive.add("old.mov", data: Data([1]))
        let fs = try await makeFS(drive)
        _ = try await fs.list(fs.rootID)
        try await fs.remove("old.mov", from: fs.rootID)
        #expect(await drive.trashed("old.mov"))

        let dir = try await fs.makeDirectory("Films", in: fs.rootID)
        let inner = try await fs.create("clip.mov", in: dir.id, mode: .guarded)
        _ = try await fs.write(inner.id, offset: 0, data: [9])
        #expect(await eventually { await drive.item(at: "Films/clip.mov") != nil })
        await #expect(throws: NFSStatus.notEmpty) { try await fs.removeDirectory("Films", from: fs.rootID) }
        try await fs.rename("clip.mov", from: dir.id, to: "clip.mov", in: fs.rootID)
        #expect(await drive.item(at: "clip.mov") != nil)
        try await fs.removeDirectory("Films", from: fs.rootID)
        #expect(await drive.trashed("Films"))
    }

    @Test func finderMetadataStaysLocal() async throws {
        let drive = FakeDrive()
        let fs = try await makeFS(drive)
        for name in [".DS_Store", "._clip.mov"] {
            let f = try await fs.create(name, in: fs.rootID, mode: .unchecked)
            _ = try await fs.write(f.id, offset: 0, data: [0, 1])
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await drive.uploadCount == 0)
        #expect(Set(try await fs.list(fs.rootID).entries.map(\.name)) == [".DS_Store", "._clip.mov"])
        await #expect(throws: NFSStatus.acces) { try await fs.makeDirectory(".Trashes", in: fs.rootID) }
    }

    @Test func pendingUploadsResumeAfterRestart() async throws {
        let drive = FakeDrive()
        let first = try await makeFS(drive, delay: .seconds(60))
        let f = try await first.create("unsent.txt", in: first.rootID, mode: .guarded)
        _ = try await first.write(f.id, offset: 0, data: Array("keep me".utf8))
        #expect(await drive.uploadCount == 0)

        // A new instance over the same state directory, as after quitting the app.
        let second = try await makeFS(drive, delay: .seconds(60))
        #expect(await eventually { await drive.item(at: "unsent.txt")?.data == Data("keep me".utf8) })
        // The staged copy is deleted once uploaded, giving the space back.
        let stagingDir = state.appendingPathComponent("Staging").path
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: stagingDir))?.isEmpty == true })
        #expect(await second.uploadsWaiting == 0)
    }

    @Test func writesDuringUploadRestartIt() async throws {
        let drive = FakeDrive()
        let fs = try await makeFS(drive, delay: .milliseconds(60))
        let f = try await fs.create("live.log", in: fs.rootID, mode: .guarded)
        for i in 0..<5 {
            _ = try await fs.write(f.id, offset: UInt64(i), data: [UInt8(i)])
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await eventually { await drive.item(at: "live.log")?.data == Data([0, 1, 2, 3, 4]) })
        #expect(await drive.uploadCount == 1)
    }
}
