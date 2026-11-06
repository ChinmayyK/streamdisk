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
/// - The first read of a file also fetches its last chunk, where MP4/MOV `moov` atoms and MKV
///   cues often live, so the player's jump to the end does not stall.
/// - Sequential reads grow a readahead window (up to `maxReadahead` chunks) so playback stays
///   ahead of the decoder; a seek resets it.
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

    private let fetch: Fetch
    private var chunks: [Key: (data: Data, tick: UInt64)] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    private var inflight: [Key: Task<Data, Error>] = [:]
    private var streams: [String: Stream] = [:]

    /// - Parameters:
    ///   - chunkSize: Download and cache unit.
    ///   - capacity: Cache budget in bytes; least recently used chunks are dropped past it.
    ///   - maxReadahead: Most chunks fetched ahead of a sequential reader.
    public init(chunkSize: UInt64 = 4 << 20, capacity: Int = 256 << 20, maxReadahead: Int = 8, fetch: @escaping Fetch) {
        precondition(chunkSize > 0 && capacity >= Int(chunkSize))
        self.chunkSize = chunkSize
        self.capacity = capacity
        self.maxReadahead = maxReadahead
        self.fetch = fetch
    }

    /// Up to `count` bytes at `offset`; shorter only at end of file.
    public func read(_ file: RemoteFile, offset: UInt64, count: Int) async throws -> [UInt8] {
        guard offset < file.size, count > 0 else { return [] }
        let end = min(file.size, offset + UInt64(count))
        let first = offset / chunkSize
        let last = (end - 1) / chunkSize

        noteAccess(file, first: first, last: last)

        // Start every needed chunk before awaiting any, so a read spanning two chunks fetches both at once.
        let tasks = (first...last).map { task(for: file, index: $0) }
        var out = [UInt8]()
        out.reserveCapacity(Int(end - offset))
        for (i, t) in zip(first...last, tasks) {
            let data = try await t.value
            let chunkStart = i * chunkSize
            let lo = Int(max(offset, chunkStart) - chunkStart)
            let hi = Int(min(end, chunkStart + UInt64(data.count)) - chunkStart)
            guard lo <= hi else { throw NSError(domain: "StreamDisk", code: 1, userInfo: [NSLocalizedDescriptionKey: "short chunk"]) }
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
    var cachedChunkCount: Int { chunks.count }
    func isCached(_ file: RemoteFile, index: UInt64) -> Bool {
        chunks[Key(file: file.id, version: file.version, index: index)] != nil
    }

    // MARK: Readahead

    private func noteAccess(_ file: RemoteFile, first: UInt64, last: UInt64) {
        let lastChunk = (file.size - 1) / chunkSize
        guard let s = streams[file.id] else {
            // First touch: header is being read now; fetch the tail and the next chunk too.
            streams[file.id] = Stream(lastIndex: last, window: 1)
            prefetch(file, index: lastChunk)
            prefetch(file, index: last + 1)
            return
        }
        let sequential = first == s.lastIndex || first == s.lastIndex + 1
        let window = sequential ? min(maxReadahead, s.window * 2) : 1
        streams[file.id] = Stream(lastIndex: last, window: window)
        for i in stride(from: last + 1, through: min(lastChunk, last + UInt64(window)), by: 1) {
            prefetch(file, index: i)
        }
    }

    private func prefetch(_ file: RemoteFile, index: UInt64) {
        guard index * chunkSize < file.size else { return }
        _ = task(for: file, index: index)
    }

    // MARK: Cache

    private func task(for file: RemoteFile, index: UInt64) -> Task<Data, Error> {
        let key = Key(file: file.id, version: file.version, index: index)
        if let hit = chunks[key] {
            tick += 1
            chunks[key] = (hit.data, tick)
            return Task { hit.data }
        }
        if let running = inflight[key] { return running }

        let start = index * chunkSize
        let range = start..<min(file.size, start + chunkSize)
        let fetch = self.fetch
        let t = Task { [weak self] () throws -> Data in
            do {
                let data = try await fetch(file, range)
                guard data.count == range.count else {
                    throw NSError(domain: "StreamDisk", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "expected \(range.count) bytes, got \(data.count)"])
                }
                await self?.store(key, data)
                return data
            } catch {
                await self?.dropInflight(key)
                throw error
            }
        }
        inflight[key] = t
        return t
    }

    private func store(_ key: Key, _ data: Data) {
        inflight[key] = nil
        tick += 1
        if let old = chunks.updateValue((data, tick), forKey: key) { bytes -= old.data.count }
        bytes += data.count
        evict()
    }

    private func dropInflight(_ key: Key) {
        inflight[key] = nil
    }

    private func evict() {
        guard bytes > capacity else { return }
        // Few dozen entries at most, so a sort beats maintaining a linked list.
        for (key, value) in chunks.sorted(by: { $0.value.tick < $1.value.tick }) {
            guard bytes > capacity else { break }
            chunks[key] = nil
            bytes -= value.data.count
        }
    }
}
