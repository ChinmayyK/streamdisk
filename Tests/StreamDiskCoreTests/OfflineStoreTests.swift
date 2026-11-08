import Foundation
import NFSServer
import Testing
@testable import StreamDiskCore

@Suite struct OfflineStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-offline-\(UUID().uuidString)")

    private func makeStore(_ drive: FakeDrive) throws -> OfflineStore {
        try OfflineStore(drive: drive, directory: dir, chunk: 4, interval: .seconds(3600))
    }

    @Test func keptFileIsCopiedAndReadLocally() async throws {
        let drive = FakeDrive()
        let film = await drive.add("film.mov", data: Data("0123456789".utf8))
        let store = try makeStore(drive)
        await store.keep(film, path: "film.mov")
        await store.idle()

        #expect(store.hasCopy(film.id, version: film.contentVersion))
        #expect(store.read(film.id, version: film.contentVersion, offset: 3, count: 4) == Array("3456".utf8))
        #expect(store.read(film.id, version: "other", offset: 0, count: 4) == nil)
        let status = try #require(await store.status().first)
        #expect(status.state == .ready && status.bytes == 10 && status.stored == 10 && status.files == 1)
        #expect(await store.bytesOnDisk == 10)
    }

    @Test func keptFolderFollowsDrive() async throws {
        let drive = FakeDrive()
        let trip = await drive.add("Trip", folder: true)
        let day1 = await drive.add("day1.mov", data: Data("aaaa".utf8), in: trip.id)
        let inner = await drive.add("Raw", folder: true, in: trip.id)
        let raw = await drive.add("raw.mov", data: Data("bbbbbb".utf8), in: inner.id)
        let store = try makeStore(drive)
        await store.keep(trip, path: "Trip")
        await store.idle()
        #expect(store.hasCopy(day1.id, version: day1.contentVersion))
        #expect(store.hasCopy(raw.id, version: raw.contentVersion))

        // A new file, a changed file and a deleted file are all picked up by the next sync.
        let day2 = await drive.add("day2.mov", data: Data("cc".utf8), in: trip.id)
        await drive.replaceContent(of: raw.id, with: Data("BBBBBBBB".utf8))
        try await drive.trash(day1.id)
        await store.sync()
        await store.idle()
        let changed = try await drive.file(raw.id)
        #expect(store.hasCopy(day2.id, version: day2.contentVersion))
        #expect(store.read(raw.id, version: changed.contentVersion, offset: 0, count: 8) == Array("BBBBBBBB".utf8))
        #expect(!store.hasCopy(day1.id, version: day1.contentVersion))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Files/\(day1.id)").path))
    }

    @Test func removingAPinDeletesItsCopiesButKeepsSharedOnes() async throws {
        let drive = FakeDrive()
        let trip = await drive.add("Trip", folder: true)
        let clip = await drive.add("clip.mov", data: Data("xyz".utf8), in: trip.id)
        let store = try makeStore(drive)
        await store.keep(trip, path: "Trip")
        await store.keep(clip, path: "Trip/clip.mov")
        await store.idle()
        await store.remove(trip.id)
        #expect(store.hasCopy(clip.id, version: clip.contentVersion))  // still kept on its own
        await store.remove(clip.id)
        #expect(!store.hasCopy(clip.id, version: clip.contentVersion))
        #expect(await store.bytesOnDisk == 0)
    }

    @Test func copiesSurviveARestartAndOfflineSyncKeepsThem() async throws {
        let drive = FakeDrive()
        let film = await drive.add("film.mov", data: Data("abcdef".utf8))
        do {
            let store = try makeStore(drive)
            await store.keep(film, path: "film.mov")
            await store.idle()
        }
        await drive.setOffline(true)
        let reopened = try makeStore(drive)
        #expect(reopened.hasCopy(film.id, version: film.contentVersion))
        await reopened.sync()
        await reopened.idle()
        #expect(reopened.hasCopy(film.id, version: film.contentVersion))
        #expect(await reopened.status().first?.state == .failed("Waiting for a connection"))
    }

    @Test func trashedPinIsForgotten() async throws {
        let drive = FakeDrive()
        let film = await drive.add("film.mov", data: Data("abc".utf8))
        let store = try makeStore(drive)
        await store.keep(film, path: "film.mov")
        await store.idle()
        try await drive.trash(film.id)
        await store.sync()
        await store.idle()
        #expect(await store.pins.isEmpty)
        #expect(!store.hasCopy(film.id, version: film.contentVersion))
    }
}

@Suite struct DriveFileSystemOfflineTests {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("sd-state-\(UUID().uuidString)")

    @Test func keptFilesReadWithoutTheNetworkAndShowTheirSizeOnDisk() async throws {
        let drive = FakeDrive()
        await drive.add("film.mov", data: Data("0123456789".utf8))
        let offline = try OfflineStore(drive: drive, directory: state.appendingPathComponent("Offline"), interval: .seconds(3600))
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state, offline: offline)
        let film = try await fs.lookup("film.mov", in: fs.rootID)
        #expect(film.bytesOnDisk == 0)

        await offline.keep(try await fs.item(atPath: "film.mov"), path: "film.mov")
        await offline.idle()
        #expect(try await fs.attributes(of: film.id).bytesOnDisk == 10)

        await drive.setOffline(true)
        #expect(try await fs.read(film.id, offset: 2, count: 5) == Array("23456".utf8))
    }

    @Test func filesWrittenIntoAKeptFolderBecomeCopiesWithoutDownloading() async throws {
        let drive = FakeDrive()
        await drive.add("Trip", folder: true)
        let offline = try OfflineStore(drive: drive, directory: state.appendingPathComponent("Offline"), interval: .seconds(3600))
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state,
                                     uploadDelay: .milliseconds(30), offline: offline)
        await fs.start()
        let trip = try await fs.lookup("Trip", in: fs.rootID)
        await offline.keep(try await fs.item(atPath: "Trip"), path: "Trip")
        await offline.idle()

        let f = try await fs.create("note.txt", in: trip.id, mode: .guarded)
        _ = try await fs.write(f.id, offset: 0, data: Array("hello".utf8))
        var uploaded: FakeDrive.Item?
        for _ in 0..<100 where uploaded == nil {
            try await Task.sleep(for: .milliseconds(10))
            uploaded = await drive.item(at: "Trip/note.txt")
        }
        let file = try #require(uploaded).file
        #expect(offline.hasCopy(file.id, version: file.contentVersion))
        #expect(await drive.downloadCount == 0)
        #expect(try await fs.attributes(of: f.id).bytesOnDisk == 5)
    }

    @Test func deletingAKeptFileForgetsIt() async throws {
        let drive = FakeDrive()
        await drive.add("film.mov", data: Data("abc".utf8))
        let offline = try OfflineStore(drive: drive, directory: state.appendingPathComponent("Offline"), interval: .seconds(3600))
        let fs = try DriveFileSystem(drive: drive, root: drive.root, stateDirectory: state, offline: offline)
        _ = try await fs.list(fs.rootID)
        await offline.keep(try await fs.item(atPath: "film.mov"), path: "film.mov")
        await offline.idle()
        try await fs.remove("film.mov", from: fs.rootID)
        #expect(await offline.pins.isEmpty)
    }
}
