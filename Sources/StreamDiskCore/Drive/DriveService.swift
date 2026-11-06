import Foundation

/// The Drive operations the file system needs. `DriveClient` talks to Google; tests use an
/// in-memory implementation.
public protocol DriveService: Sendable {
    func children(of folderID: String) async throws -> [DriveFile]
    func download(_ fileID: String, range: Range<UInt64>) async throws -> Data
    func createFolder(named name: String, in parentID: String) async throws -> DriveFile
    func upload(_ fileURL: URL, to target: DriveClient.UploadTarget, modified: Date?, session: URL?,
                onSession: @Sendable (URL) -> Void,
                progress: @Sendable (UInt64, UInt64) -> Void) async throws -> DriveFile
    func update(_ fileID: String, name: String?, moveFrom oldParent: String?, to newParent: String?,
                modified: Date?) async throws -> DriveFile
    func trash(_ fileID: String) async throws
    func quota() async throws -> DriveQuota
}

extension DriveClient: DriveService {}
