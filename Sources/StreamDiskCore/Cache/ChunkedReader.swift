import Foundation

/// A remote file as the reader sees it. `version` changes whenever the content does,
/// so cached chunks of an old version are never served.
public struct RemoteFile: Sendable, Hashable {
    public let id: String
    public let version: String
    public let size: UInt64

    public init(id: String, version: String, size: UInt64) {
        self.id = id
        self.version = version
        self.size = size
    }
}

/// Serves byte ranges of remote files from a bounded in-memory cache of fixed-size chunks.
///
/// Tuned for how media players read:
/// - Downloads go through a `DownloadGate`: a few at a time, with chunks a reader is blocked on
///   ahead of readahead, and earlier chunks ahead of later ones. Starting everything at once
///   would split the link and make the chunk the player needs arrive last.
/// - The first read of a file also fetches its tail urgently, where MP4/MOV `moov` atoms and
///   MKV cues often live, so the player's jump to the end does not stall.
/// - Sequential reads grow a readahead window up to `maxReadahead` chunks. A seek resets it and
///   drops queued readahead that is no longer useful.
/// - Concurrent requests for the same chunk share one download.
public actor ChunkedReader {
    public typealias Fetch = @Sendable (_ file: RemoteFile, _ range: Range<UInt64>) async throws -> Data

    public let chunkSize: UInt64
    public let capacity: Int
    public let maxReadahead: Int

    private struct Key: Hashable {
        let file: String
        let version: String
        let index: UInt64
    }

    private struct Stream {
        var lastIndex: UInt64
        var window: Int
    }

    private struct Download {
        let id: Int
        let task: Task<Data, Error>
        var urgent: Bool
    }

    /// A queued readahead was abandoned after a seek.
    struct Dropped: Error {}

    struct ShortChunk: Error, CustomStringConvertible {
        let expected: Int
        let got: Int
        var description: String { "expected \(expected) bytes, got \(got)" }
    }

    private let fetch: Fetch
    private let gate: DownloadGate
    private var chunks: [Key: (data: Data, tick: UInt64)] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    private var inflight: [Key: Download] = [:]
    private var nextDownloadID = 0
    private var streams: [String: Stream] = [:]

    /// - Parameters:
    ///   - chunkSize: Download and cache unit.
    ///   - capacity: Cache budget in bytes; least recently used chunks are dropped past it.
    ///   - maxReadahead: Most chunks fetched ahead of a sequential reader.
    ///   - concurrency: Downloads in flight at once.
    public init(chunkSize: UInt64 = 1 << 20, capacity: Int = 256 << 20, maxReadahead: Int = 32,
                concurrency: Int = 6, fetch: @escaping Fetch) {
        precondition(chunkSize > 0 && capacity >= Int(chunkSize))
        self.chunkSize = chunkSize
        self.capacity = capacity
        self.maxReadahead = maxReadahead
        self.gate = DownloadGate(limit: concurrency, reserved: concurrency > 1 ? 1 : 0)
        self.fetch = fetch
    }

    /// Up to `count` bytes at `offset`; shorter only at end of file.
    public func read(_ file: RemoteFile, offset: UInt64, count: Int) async throws -> [UInt8] {
        guard offset < file.size, count > 0 else { return [] }
        let end = min(file.size, offset + UInt64(count))
        let first = offset / chunkSize
        let last = (end - 1) / chunkSize

        // Request what this read needs before scheduling readahead, so it queues first.
        var tasks: [Task<Data, Error>] = []
        for i in first...last { tasks.append(await task(for: file, index: i, urgent: true)) }
        await noteAccess(file, first: first, last: last)

        var out = [UInt8]()
        out.reserveCapacity(Int(end - offset))
        for (i, t) in zip(first...last, tasks) {
            let data = try await value(of: t, file: file, index: i)
            let chunkStart = i * chunkSize
            let lo = Int(max(offset, chunkStart) - chunkStart)
            let hi = Int(min(end, chunkStart + UInt64(data.count)) - chunkStart)
            out.append(contentsOf: data[data.startIndex + lo..<data.startIndex + hi])
        }
        return out
    }

    /// Drops cached chunks and stream state for a file, for example after it changes or is deleted.
    public func forget(_ fileID: String) {
        for key in chunks.keys where key.file == fileID {
            bytes -= chunks.removeValue(forKey: key)!.data.count
        }
        streams[fileID] = nil
    }

    var cachedBytes: Int { bytes }
    func isCached(_ file: RemoteFile, index: UInt64) -> Bool {
        chunks[Key(file: file.id, version: file.version, index: index)] != nil
    }

    // MARK: Readahead

    private func noteAccess(_ file: RemoteFile, first: UInt64, last: UInt64) async {
        let lastChunk = (file.size - 1) / chunkSize
        guard let s = streams[file.id] else {
            // First touch: the header is being read; fetch the tail urgently and start readahead.
            let window = min(maxReadahead, 4)
            streams[file.id] = Stream(lastIndex: last, window: window)
            let tailStart = max(last + 1, lastChunk > 0 ? lastChunk - 1 : 0)
            for i in stride(from: tailStart, through: lastChunk, by: 1) {
                // Players need the index at the end as soon as the header, so rank it with chunk 0.
                _ = await task(for: file, index: i, urgent: true, rank: 0)
            }
            await readahead(file, after: last, window: window, lastChunk: lastChunk)
            return
        }
        let sequential = first >= s.lastIndex && first <= s.lastIndex + 1
        let window = sequential ? min(maxReadahead, max(1, s.window) * 2) : min(maxReadahead, 4)
        streams[file.id] = Stream(lastIndex: last, window: window)
        if !sequential {
            // Seek: queued readahead elsewhere in the file would only delay the new position.
            // Queued ones are dropped; running ones are cancelled so they stop using bandwidth.
            let keep = first...(last + UInt64(window))
            await gate.drop(group: file.id) { keep.contains($0) }
            for (key, d) in inflight where key.file == file.id && !d.urgent && !keep.contains(key.index) {
                d.task.cancel()
            }
        }
        await readahead(file, after: last, window: window, lastChunk: lastChunk)
    }

    private func readahead(_ file: RemoteFile, after last: UInt64, window: Int, lastChunk: UInt64) async {
        guard window > 0, last < lastChunk else { return }
        for i in (last + 1)...min(lastChunk, last + UInt64(window)) {
            _ = await task(for: file, index: i, urgent: false)
        }
    }

    // MARK: Cache

    /// Awaits a chunk, re-requesting it if a queued prefetch it shared was dropped by a seek.
    private func value(of first: Task<Data, Error>, file: RemoteFile, index: UInt64) async throws -> Data {
        var t = first
        for _ in 0..<3 {
            do {
                return try await t.value
            } catch is Dropped {
                t = await task(for: file, index: index, urgent: true)
            } catch is CancellationError {
                t = await task(for: file, index: index, urgent: true)
            } catch let e as URLError where e.code == .cancelled {
                t = await task(for: file, index: index, urgent: true)
            }
        }
        return try await t.value
    }

    /// - Parameter rank: Position used to order downloads of equal urgency; defaults to `index`.
    private func task(for file: RemoteFile, index: UInt64, urgent: Bool, rank: UInt64? = nil) async -> Task<Data, Error> {
        let key = Key(file: file.id, version: file.version, index: index)
        if let hit = chunks[key] {
            tick += 1
            chunks[key] = (hit.data, tick)
            return Task { hit.data }
        }
        let priority = DownloadGate.Priority(urgent: urgent, index: rank ?? index)
        if let running = inflight[key] {
            if urgent && !running.urgent {
                inflight[key]?.urgent = true
                await gate.promote(id: running.id, to: priority)
            }
            return running.task
        }

        nextDownloadID += 1
        let id = nextDownloadID
        let start = index * chunkSize
        let range = start..<min(file.size, start + chunkSize)
        let fetch = self.fetch
        let gate = self.gate
        let t = Task { [weak self] () throws -> Data in
            guard await gate.acquire(id: id, group: file.id, priority: priority) else {
                await self?.finish(key, id: id, data: nil)
                throw Dropped()
            }
            let result: Result<Data, Error>
            do {
                let data = try await fetch(file, range)
                result = data.count == range.count ? .success(data) : .failure(ShortChunk(expected: range.count, got: data.count))
            } catch {
                result = .failure(error)
            }
            await gate.release(id: id)
            await self?.finish(key, id: id, data: try? result.get())
            return try result.get()
        }
        inflight[key] = Download(id: id, task: t, urgent: urgent)
        return t
    }

    private func finish(_ key: Key, id: Int, data: Data?) {
        if inflight[key]?.id == id { inflight[key] = nil }
        guard let data else { return }
        tick += 1
        if let old = chunks.updateValue((data, tick), forKey: key) { bytes -= old.data.count }
        bytes += data.count
        evict()
    }

    private func evict() {
        guard bytes > capacity else { return }
        for (key, value) in chunks.sorted(by: { $0.value.tick < $1.value.tick }) {
            guard bytes > capacity else { break }
            chunks[key] = nil
            bytes -= value.data.count
        }
    }
}
