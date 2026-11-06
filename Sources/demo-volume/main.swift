// Mounts StreamDisk's NFS server over a fixed sample tree, for website screenshots.
// Finder, the mount and the server are real; only the file list is sample data.
// Reads return zeros, so files can be listed and inspected but not played.
import Foundation
import NFSServer

final class DemoBackend: FileSystemBackend {
    let rootID: UInt64 = 1
    private let nodes: [UInt64: (name: String, parent: UInt64, size: UInt64?, date: Date)]

    init() {
        let day: TimeInterval = 86_400
        let now = Date()
        let gb: UInt64 = 1_000_000_000
        let mb: UInt64 = 1_000_000
        let items: [(UInt64, String, UInt64, UInt64?, TimeInterval)] = [
            (2, "Ladakh ride 4K.mov", 1, 61 * gb + 372_118_016, 3),
            (3, "Interview A-cam.mov", 1, 128 * gb + 604_221_440, 9),
            (4, "Wedding, Pune (raw)", 1, nil, 21),
            (5, "Album stems.zip", 1, 18 * gb + 903_114_752, 34),
            (6, "Lecture 12, Fluid mechanics.mp4", 1, 2 * gb + 417_206_272, 1),
            (7, "Lightroom catalog 2019-2024.zip", 1, 87 * gb + 216_350_720, 63),
            (8, "Portfolio scans.zip", 1, 4 * gb + 98_566_144, 12),
            (9, "Tax documents 2025.pdf", 1, 3 * mb + 912_384, 40),
        ]
        var n: [UInt64: (String, UInt64, UInt64?, Date)] = [1: ("", 1, nil, now)]
        for (id, name, parent, size, ago) in items { n[id] = (name, parent, size, now.addingTimeInterval(-ago * day)) }
        nodes = n
    }

    func attributes(of id: UInt64) async throws -> FileAttributes {
        guard let n = nodes[id] else { throw NFSStatus.stale }
        return FileAttributes(id: id, kind: n.size == nil ? .directory : .file, size: n.size ?? 0, modified: n.date)
    }
    func lookup(_ name: String, in directory: UInt64) async throws -> FileAttributes {
        if name == ".." { return try await attributes(of: rootID) }
        guard let id = nodes.first(where: { $0.key != rootID && $0.value.parent == directory && $0.value.name == name })?.key
        else { throw NFSStatus.noent }
        return try await attributes(of: id)
    }
    func list(_ directory: UInt64) async throws -> DirectoryListing {
        var entries: [DirectoryEntry] = []
        for (id, n) in nodes.sorted(by: { $0.key < $1.key }) where id != rootID && n.parent == directory {
            entries.append(DirectoryEntry(name: n.name, attributes: try await attributes(of: id)))
        }
        return DirectoryListing(entries: entries, version: 1)
    }
    func read(_ id: UInt64, offset: UInt64, count: Int) async throws -> [UInt8] {
        guard let size = nodes[id]?.size else { throw NFSStatus.isdir }
        return [UInt8](repeating: 0, count: Int(min(UInt64(count), size - min(offset, size))))
    }
    func statistics() async throws -> VolumeStatistics {
        VolumeStatistics(totalBytes: 2_000 * 1_000_000_000, freeBytes: 1_697 * 1_000_000_000)
    }
}

let mountPoint = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "demo/StreamDisk")
let server = try LocalNFSServer(backend: DemoBackend())
let port = try await server.start()
try NFSMount.mount(port: port, at: mountPoint)
print("Demo volume at \(mountPoint.path). Ctrl-C to unmount.")
signal(SIGINT, SIG_IGN)
let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
source.setEventHandler {
    try? NFSMount.unmount(mountPoint, force: true)
    exit(0)
}
source.resume()
while true { try await Task.sleep(for: .seconds(3600)) }
