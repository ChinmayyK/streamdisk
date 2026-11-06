import Foundation
import NFSServer

/// In-memory tree for exercising the server through the real macOS NFS client.
final class MemoryBackend: FileSystemBackend {
    struct Node {
        var name: String
        var parent: UInt64
        var data: [UInt8]?  // nil for directories
    }

    let rootID: UInt64 = 1
    private let nodes: [UInt64: Node]
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a tree from slash-separated paths; directories are created as needed.
    init(files: [String: [UInt8]]) {
        var nodes: [UInt64: Node] = [1: Node(name: "", parent: 1, data: nil)]
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
                let id = next
                next += 1
                nodes[id] = Node(name: part, parent: parent, data: i == parts.count - 1 ? data : nil)
                byPath[prefix] = id
                parent = id
            }
        }
        self.nodes = nodes
    }

    func attributes(of id: UInt64) async throws -> FileAttributes {
        guard let n = nodes[id] else { throw NFSStatus.stale }
        return FileAttributes(id: id, kind: n.data == nil ? .directory : .file,
                              size: UInt64(n.data?.count ?? 0), modified: date)
    }

    func lookup(_ name: String, in directory: UInt64) async throws -> FileAttributes {
        if name == ".." { return try await attributes(of: nodes[directory]?.parent ?? rootID) }
        guard let (id, _) = nodes.first(where: { $0.value.parent == directory && $0.key != directory && $0.value.name == name })
        else { throw NFSStatus.noent }
        return try await attributes(of: id)
    }

    func list(_ directory: UInt64) async throws -> DirectoryListing {
        var entries: [DirectoryEntry] = []
        for (id, n) in nodes where n.parent == directory && id != directory {
            entries.append(DirectoryEntry(name: n.name, attributes: try await attributes(of: id)))
        }
        return DirectoryListing(entries: entries.sorted { $0.name < $1.name }, version: 1)
    }

    func read(_ id: UInt64, offset: UInt64, count: Int) async throws -> [UInt8] {
        guard let data = nodes[id]?.data else { throw NFSStatus.isdir }
        let start = Int(min(offset, UInt64(data.count)))
        return Array(data[start..<min(data.count, start + count)])
    }

    func statistics() async throws -> VolumeStatistics {
        VolumeStatistics(totalBytes: 1 << 40, freeBytes: 1 << 39)
    }
}
