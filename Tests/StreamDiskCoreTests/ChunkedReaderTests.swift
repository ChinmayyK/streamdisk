import Foundation
import Testing
@testable import StreamDiskCore

/// Fake remote: content byte at offset i is UInt8(i % 251). Records every fetched range.
private actor FakeRemote {
    private(set) var fetched: [Range<UInt64>] = []
    var delay: Duration = .zero
    var failNext = false

    func setDelay(_ d: Duration) { delay = d }
    func setFailNext() { failNext = true }

    func fetch(_ range: Range<UInt64>) async throws -> Data {
        fetched.append(range)
        if failNext {
            failNext = false
            throw URLError(.networkConnectionLost)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return Data(range.map { UInt8($0 % 251) })
    }
}

private func expected(_ offset: UInt64, _ count: Int) -> [UInt8] {
    (offset..<offset + UInt64(count)).map { UInt8($0 % 251) }
}

@Suite struct ChunkedReaderTests {
    let chunk: UInt64 = 1024
    let file = RemoteFile(id: "f", version: "1", size: 10 * 1024 + 100)

    private func reader(_ remote: FakeRemote, capacity: Int = 1 << 20, readahead: Int = 4) -> ChunkedReader {
        ChunkedReader(chunkSize: chunk, capacity: capacity, maxReadahead: readahead) { _, range in
            try await remote.fetch(range)
        }
    }

    /// Lets detached prefetch tasks run.
    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    @Test func readsAcrossChunkBoundariesAndEndOfFile() async throws {
        let r = reader(FakeRemote())
        #expect(try await r.read(file, offset: 1000, count: 100) == expected(1000, 100))
        #expect(try await r.read(file, offset: file.size - 10, count: 500) == expected(file.size - 10, 10))
        #expect(try await r.read(file, offset: file.size, count: 10) == [])
    }

    @Test func firstReadPrefetchesTailForPlayerIndexes() async throws {
        let remote = FakeRemote()
        let r = reader(remote)
        _ = try await r.read(file, offset: 0, count: 10)
        await settle()
        #expect(await r.isCached(file, index: 10))  // last chunk: moov / cues
        #expect(await r.isCached(file, index: 1))
    }

    @Test func sequentialReadsGrowTheReadaheadWindow() async throws {
        let remote = FakeRemote()
        let r = reader(remote, readahead: 4)
        for i in 0..<3 { _ = try await r.read(file, offset: UInt64(i) * chunk, count: Int(chunk)) }
        await settle()
        // After reading chunk 2 sequentially, the window is 4: chunks 3...6 are fetched.
        for i in 3...6 { #expect(await r.isCached(file, index: UInt64(i))) }
        #expect(await !r.isCached(file, index: 7))
    }

    @Test func concurrentReadsShareOneDownload() async throws {
        let remote = FakeRemote()
        await remote.setDelay(.milliseconds(30))
        let r = reader(remote, readahead: 0)
        async let a = r.read(file, offset: 4096, count: 10)
        async let b = r.read(file, offset: 4100, count: 10)
        _ = try await (a, b)
        await settle()
        let hits = await remote.fetched.filter { $0.lowerBound == 4096 }
        #expect(hits.count == 1)
    }

    @Test func evictsLeastRecentlyUsedPastCapacity() async throws {
        let r = reader(FakeRemote(), capacity: 3 * 1024, readahead: 0)
        let small = RemoteFile(id: "s", version: "1", size: 8 * 1024)
        for i in [0, 4, 2, 6] { _ = try await r.read(small, offset: UInt64(i) * chunk, count: 1) }
        await settle()
        #expect(await r.cachedBytes <= 3 * 1024)
        #expect(await r.isCached(small, index: 6))
    }

    @Test func failedFetchIsRetriedOnNextRead() async throws {
        let remote = FakeRemote()
        let r = reader(remote, readahead: 0)
        let tiny = RemoteFile(id: "t", version: "1", size: 100)
        await remote.setFailNext()
        await #expect(throws: URLError.self) { try await r.read(tiny, offset: 0, count: 10) }
        #expect(try await r.read(tiny, offset: 0, count: 10) == expected(0, 10))
    }

    @Test func newVersionDoesNotServeOldBytes() async throws {
        let remote = FakeRemote()
        let r = reader(remote, readahead: 0)
        _ = try await r.read(file, offset: 0, count: 1)
        let changed = RemoteFile(id: "f", version: "2", size: file.size)
        _ = try await r.read(changed, offset: 0, count: 1)
        #expect(await remote.fetched.filter { $0.lowerBound == 0 }.count == 2)
    }
}
