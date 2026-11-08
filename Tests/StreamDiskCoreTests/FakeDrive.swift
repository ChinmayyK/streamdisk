import Foundation
@testable import StreamDiskCore

/// In-memory Google Drive for file-system tests.
actor FakeDrive: DriveService {
    struct Item {
        var file: DriveFile
        var parent: String
        var data: Data
        var trashed = false
    }

    let root: DriveFile
    private(set) var items: [String: Item] = [:]
    private(set) var uploadCount = 0
    private(set) var downloadCount = 0
    /// Makes every call fail as if offline.
    var offline = false
    private var next = 0

    init() {
        let now = Date()
        root = DriveFile(id: "root-folder", name: "StreamDisk", mimeType: DriveFile.folderType, size: 0,
                         modifiedTime: now, createdTime: now)
    }

    @discardableResult
    func add(_ name: String, data: Data = Data(), folder: Bool = false, in parent: String? = nil) -> DriveFile {
        next += 1
        let now = Date().addingTimeInterval(TimeInterval(next))
        let file = DriveFile(id: "id\(next)", name: name, mimeType: folder ? DriveFile.folderType : "application/octet-stream",
                             size: UInt64(data.count), modifiedTime: now, createdTime: now, md5Checksum: folder ? nil : "v\(next)")
        items[file.id] = Item(file: file, parent: parent ?? root.id, data: data)
        return file
    }

    /// Live (not trashed) item by path below the root.
    func item(at path: String) -> Item? {
        var parent = root.id
        var found: Item?
        for part in path.split(separator: "/") {
            found = items.values.first { $0.parent == parent && $0.file.name == part && !$0.trashed }
            guard let f = found else { return nil }
            parent = f.file.id
        }
        return found
    }

    func trashed(_ name: String) -> Bool { items.values.contains { $0.file.name == name && $0.trashed } }

    // MARK: DriveService

    func children(of folderID: String) throws -> [DriveFile] {
        if offline { throw URLError(.notConnectedToInternet) }
        return items.values.filter { $0.parent == folderID && !$0.trashed }
            .map(\.file).sorted { $0.createdTime < $1.createdTime }
    }

    func file(_ id: String) throws -> DriveFile {
        if offline { throw URLError(.notConnectedToInternet) }
        guard let item = items[id] else { throw DriveError.http(status: 404, message: "not found") }
        let f = item.file
        return DriveFile(id: f.id, name: f.name, mimeType: f.mimeType, size: f.size, modifiedTime: f.modifiedTime,
                         createdTime: f.createdTime, md5Checksum: f.md5Checksum, trashed: item.trashed)
    }

    func setOffline(_ value: Bool) { offline = value }

    func replaceContent(of id: String, with data: Data) {
        next += 1
        let f = items[id]!.file
        items[id]!.data = data
        items[id]!.file = DriveFile(id: f.id, name: f.name, mimeType: f.mimeType, size: UInt64(data.count),
                                    modifiedTime: Date(), createdTime: f.createdTime, md5Checksum: "v\(next)")
    }

    func download(_ fileID: String, range: Range<UInt64>) throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        downloadCount += 1
        guard let item = items[fileID] else { throw DriveError.http(status: 404, message: "not found") }
        return item.data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    func createFolder(named name: String, in parentID: String) -> DriveFile {
        add(name, folder: true, in: parentID)
    }

    func upload(_ fileURL: URL, to target: DriveClient.UploadTarget, modified: Date?, session: URL?,
                onSession: @Sendable (URL) -> Void, progress: @Sendable (UInt64, UInt64) -> Void) throws -> DriveFile {
        uploadCount += 1
        let data = try Data(contentsOf: fileURL)
        onSession(URL(string: "https://upload.example/session/\(uploadCount)")!)
        switch target {
        case .new(let name, let parentID):
            var file = add(name, data: data, in: parentID)
            if let modified { file = retime(file.id, modified) }
            return file
        case .replace(let fileID):
            guard var item = items[fileID] else { throw DriveError.http(status: 404, message: "not found") }
            next += 1
            item.data = data
            item.file = DriveFile(id: fileID, name: item.file.name, mimeType: item.file.mimeType, size: UInt64(data.count),
                                  modifiedTime: modified ?? Date(), createdTime: item.file.createdTime, md5Checksum: "v\(next)")
            items[fileID] = item
            return item.file
        }
    }

    func update(_ fileID: String, name: String?, moveFrom oldParent: String?, to newParent: String?,
                modified: Date?) throws -> DriveFile {
        guard var item = items[fileID] else { throw DriveError.http(status: 404, message: "not found") }
        let f = item.file
        item.file = DriveFile(id: f.id, name: name ?? f.name, mimeType: f.mimeType, size: f.size,
                              modifiedTime: modified ?? f.modifiedTime, createdTime: f.createdTime, md5Checksum: f.md5Checksum)
        if let newParent { item.parent = newParent }
        items[fileID] = item
        return item.file
    }

    func trash(_ fileID: String) throws {
        guard items[fileID] != nil else { throw DriveError.http(status: 404, message: "not found") }
        items[fileID]?.trashed = true
    }

    func quota() -> DriveQuota { DriveQuota(limit: 15 << 30, usage: 1 << 30) }

    private func retime(_ id: String, _ date: Date) -> DriveFile {
        let f = items[id]!.file
        items[id]!.file = DriveFile(id: f.id, name: f.name, mimeType: f.mimeType, size: f.size,
                                    modifiedTime: date, createdTime: f.createdTime, md5Checksum: f.md5Checksum)
        return items[id]!.file
    }
}
