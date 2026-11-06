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

@Suite struct DownloadSchedulingTests {
    let chunk: UInt64 = 1024

    @Test func blockedReadIsDownloadedBeforeQueuedReadahead() async throws {
        let remote = FakeRemote()
        await remote.setDelay(.milliseconds(20))
        // One download at a time makes the order observable.
        let r = ChunkedReader(chunkSize: chunk, capacity: 1 << 20, maxReadahead: 8, concurrency: 1) { _, range in
            try await remote.fetch(range)
        }
        let file = RemoteFile(id: "f", version: "1", size: 100 * 1024)
        _ = try await r.read(file, offset: 0, count: 10)
        // Readahead for chunks 1...4 is queued; a seek to chunk 50 must jump the queue.
        _ = try await r.read(file, offset: 50 * chunk, count: 10)
        let order = await remote.fetched.map { $0.lowerBound / chunk }
        let at50 = try #require(order.firstIndex(of: 50))
        // Chunk 0, the urgent tail (98, 99) and at most the one readahead already running go first.
        #expect(at50 <= 4)
    }

    @Test func seekDropsReadaheadThatIsNoLongerUseful() async throws {
        let remote = FakeRemote()
        await remote.setDelay(.milliseconds(20))
        let r = ChunkedReader(chunkSize: chunk, capacity: 1 << 20, maxReadahead: 8, concurrency: 1) { _, range in
            try await remote.fetch(range)
        }
        let file = RemoteFile(id: "f", version: "1", size: 100 * 1024)
        _ = try await r.read(file, offset: 0, count: 10)
        _ = try await r.read(file, offset: 60 * chunk, count: 10)
        try await Task.sleep(for: .milliseconds(400))
        let fetched = Set(await remote.fetched.map { $0.lowerBound / chunk })
        // Chunks 1...4 were queued behind the tail; most never download after the seek.
        #expect(fetched.intersection(2...4).isEmpty)
        #expect(fetched.isSuperset(of: [0, 60, 61, 62, 63, 64]))
    }

    @Test func readWaitingOnDroppedReadaheadStillSucceeds() async throws {
        let remote = FakeRemote()
        await remote.setDelay(.milliseconds(10))
        let r = ChunkedReader(chunkSize: chunk, capacity: 1 << 20, maxReadahead: 8, concurrency: 1) { _, range in
            try await remote.fetch(range)
        }
        let file = RemoteFile(id: "f", version: "1", size: 100 * 1024)
        _ = try await r.read(file, offset: 0, count: 10)
        // Chunk 3 is queued readahead; read it while a seek elsewhere drops the queue.
        async let a = r.read(file, offset: 3 * chunk, count: 10)
        async let b = r.read(file, offset: 80 * chunk, count: 10)
        let (x, y) = try await (a, b)
        #expect(x == expected(3 * chunk, 10))
        #expect(y == expected(80 * chunk, 10))
    }
}

@Suite struct DownloadGateTests {
    @Test func readaheadNeverTakesTheReservedSlot() async {
        let gate = DownloadGate(limit: 2, reserved: 1)
        let low = DownloadGate.Priority(urgent: false, index: 1)
        #expect(await gate.acquire(id: 1, group: "f", priority: low))
        // A second readahead must queue even though one slot is free.
        let second = Task { await gate.acquire(id: 2, group: "f", priority: low) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await gate.queuedCount == 1)
        // An urgent request gets the reserved slot immediately.
        #expect(await gate.acquire(id: 3, group: "f", priority: .init(urgent: true, index: 9)))
        await gate.release(id: 3)
        await gate.release(id: 1)
        #expect(await second.value)
    }

    @Test func seekCancelsRunningReadahead() async throws {
        let started = ManagedCounter()
        let r = ChunkedReader(chunkSize: 1024, capacity: 1 << 20, maxReadahead: 4, concurrency: 4) { _, range in
            await started.add(range.lowerBound / 1024)
            // Readahead hangs until cancelled; urgent reads answer at once.
            if range.lowerBound / 1024 != 0 && range.lowerBound / 1024 < 50 {
                try await Task.sleep(for: .seconds(30))
            }
            return Data(range.map { UInt8($0 % 251) })
        }
        let file = RemoteFile(id: "f", version: "1", size: 1024 * 1024)
        // Tail (1022, 1023) answers at once; readahead 1...4 hangs on three slots.
        _ = try await r.read(file, offset: 0, count: 10)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await r.read(file, offset: 60 * 1024, count: 10)
        }
        #expect(elapsed < .seconds(2))
    }
}

actor ManagedCounter {
    private(set) var values: [UInt64] = []
    func add(_ v: UInt64) { values.append(v) }
}

@Suite struct DownloadGatePromotionTests {
    @Test func promotedRequestReleasesItsUrgentSlot() async {
        let gate = DownloadGate(limit: 2, reserved: 1)
        #expect(await gate.acquire(id: 1, group: "f", priority: .init(urgent: true, index: 0)))
        let queued = Task { await gate.acquire(id: 2, group: "f", priority: .init(urgent: false, index: 5)) }
        try? await Task.sleep(for: .milliseconds(20))
        await gate.promote(id: 2, to: .init(urgent: true, index: 5))
        #expect(await queued.value)
        await gate.release(id: 1)
        await gate.release(id: 2)
        // Nothing urgent is left running, so readahead starts at once.
        #expect(await gate.acquire(id: 3, group: "f", priority: .init(urgent: false, index: 6)))
    }
}
