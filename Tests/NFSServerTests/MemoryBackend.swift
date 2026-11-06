import Foundation
import NFSServer

/// In-memory tree for exercising the server through the real macOS NFS client.
actor MemoryBackend: WritableFileSystemBackend {
    struct Node {
        var name: String
        var parent: UInt64
        var data: [UInt8]?  // nil for directories
        var modified: Date
        var verifier: UInt64?
    }

    nonisolated let rootID: UInt64 = 1
    private var nodes: [UInt64: Node]
    private var next: UInt64 = 2

    /// Builds a tree from slash-separated paths; directories are created as needed.
    init(files: [String: [UInt8]] = [:]) {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var nodes: [UInt64: Node] = [1: Node(name: "", parent: 1, data: nil, modified: date)]
        var byPath: [String: UInt64] = ["": 1]
        var next: UInt64 = 2
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            var parent: UInt64 = 1
            var prefix = ""
            let parts = path.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                prefix += "/" + part
                if let id = byPath[prefix] {
                    parent = id
                    continue
                }
                nodes[next] = Node(name: part, parent: parent, data: i == parts.count - 1 ? data : nil, modified: date)
                byPath[prefix] = next
                parent = next
                next += 1
            }
        }
        self.nodes = nodes
        self.next = next
    }

    func contents(_ path: String) -> [UInt8]? {
        var id = rootID
        for part in path.split(separator: "/") {
            guard let child = childID(String(part), in: id) else { return nil }
            id = child
        }
        return nodes[id]?.data
    }

    private func childID(_ name: String, in directory: UInt64) -> UInt64? {
        nodes.first { $0.key != rootID && $0.value.parent == directory && $0.value.name == name }?.key
    }

    private func attrs(_ id: UInt64) throws -> FileAttributes {
        guard let n = nodes[id] else { throw NFSStatus.stale }
        return FileAttributes(id: id, kind: n.data == nil ? .directory : .file,
                              size: UInt64(n.data?.count ?? 0), modified: n.modified)
    }

    private func directory(_ id: UInt64) throws {
        guard let n = nodes[id] else { throw NFSStatus.stale }
        guard n.data == nil else { throw NFSStatus.notdir }
    }

    // MARK: Reading

    func attributes(of id: UInt64) throws -> FileAttributes { try attrs(id) }

    func lookup(_ name: String, in directory: UInt64) throws -> FileAttributes {
        if name == ".." { return try attrs(nodes[directory]?.parent ?? rootID) }
        guard let id = childID(name, in: directory) else { throw NFSStatus.noent }
        return try attrs(id)
    }

    func list(_ directory: UInt64) throws -> DirectoryListing {
        let entries = try nodes.filter { $0.key != rootID && $0.value.parent == directory }
            .map { DirectoryEntry(name: $0.value.name, attributes: try attrs($0.key)) }
            .sorted { $0.name < $1.name }
        var h = Hasher()
        for e in entries { h.combine(e.name); h.combine(e.attributes.id) }
        return DirectoryListing(entries: entries, version: UInt64(bitPattern: Int64(h.finalize())) | 1)
    }

    func read(_ id: UInt64, offset: UInt64, count: Int) throws -> [UInt8] {
        guard let data = nodes[id]?.data else { throw NFSStatus.isdir }
        let start = Int(min(offset, UInt64(data.count)))
        return Array(data[start..<min(data.count, start + count)])
    }

    func statistics() -> VolumeStatistics { VolumeStatistics(totalBytes: 1 << 40, freeBytes: 1 << 39) }

    // MARK: Writing

    func create(_ name: String, in dir: UInt64, mode: CreateMode) throws -> FileAttributes {
        try directory(dir)
        if let existing = childID(name, in: dir) {
            switch mode {
            case .unchecked: return try attrs(existing)
            case .guarded: throw NFSStatus.exist
            case .exclusive(let v):
                guard nodes[existing]?.verifier == v else { throw NFSStatus.exist }
                return try attrs(existing)
            }
        }
        let id = next
        next += 1
        var verifier: UInt64?
        if case .exclusive(let v) = mode { verifier = v }
        nodes[id] = Node(name: name, parent: dir, data: [], modified: Date(), verifier: verifier)
        return try attrs(id)
    }

    func write(_ id: UInt64, offset: UInt64, data: [UInt8]) throws -> FileAttributes {
        guard var n = nodes[id] else { throw NFSStatus.stale }
        guard var bytes = n.data else { throw NFSStatus.isdir }
        let end = Int(offset) + data.count
        if bytes.count < end { bytes += [UInt8](repeating: 0, count: end - bytes.count) }
        bytes.replaceSubrange(Int(offset)..<end, with: data)
        n.data = bytes
        n.modified = Date()
        nodes[id] = n
        return try attrs(id)
    }

    func commit(_ id: UInt64) throws {
        guard nodes[id] != nil else { throw NFSStatus.stale }
    }

    func setAttributes(_ id: UInt64, size: UInt64?, modified: Date?) throws -> FileAttributes {
        guard var n = nodes[id] else { throw NFSStatus.stale }
        if let size {
            guard var bytes = n.data else { throw NFSStatus.isdir }
            if bytes.count > Int(size) { bytes.removeLast(bytes.count - Int(size)) }
            else { bytes += [UInt8](repeating: 0, count: Int(size) - bytes.count) }
            n.data = bytes
        }
        if let modified { n.modified = modified }
        nodes[id] = n
        return try attrs(id)
    }

    func makeDirectory(_ name: String, in dir: UInt64) throws -> FileAttributes {
        try directory(dir)
        guard childID(name, in: dir) == nil else { throw NFSStatus.exist }
        let id = next
        next += 1
        nodes[id] = Node(name: name, parent: dir, data: nil, modified: Date())
        return try attrs(id)
    }

    func remove(_ name: String, from dir: UInt64) throws {
        guard let id = childID(name, in: dir) else { throw NFSStatus.noent }
        guard nodes[id]?.data != nil else { throw NFSStatus.isdir }
        nodes[id] = nil
    }

    func removeDirectory(_ name: String, from dir: UInt64) throws {
        guard let id = childID(name, in: dir) else { throw NFSStatus.noent }
        guard nodes[id]?.data == nil else { throw NFSStatus.notdir }
        guard !nodes.contains(where: { $0.key != id && $0.value.parent == id }) else { throw NFSStatus.notEmpty }
        nodes[id] = nil
    }

    func rename(_ name: String, from source: UInt64, to newName: String, in target: UInt64) throws {
        guard let id = childID(name, in: source) else { throw NFSStatus.noent }
        try directory(target)
        if let existing = childID(newName, in: target), existing != id {
            guard nodes[existing]?.data != nil else { throw NFSStatus.exist }
            nodes[existing] = nil
        }
        nodes[id]?.name = newName
        nodes[id]?.parent = target
    }
}
