import Foundation
import NFSServer
import StreamDiskCore

let usage = """
    usage: streamdisk <command>

      login [--full] [--client <file>]       sign in to Google Drive; --full shows your whole Drive
      logout                                 sign out and revoke access
      ls [folder]                            list files in your StreamDisk folder
      put <file>... [--to <folder>]          upload files
      mount [directory]                      mount as a disk (default ~/StreamDisk); Ctrl-C to unmount
    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

func makeAuth() throws -> GoogleAuth {
    GoogleAuth(client: try OAuthClient.locate())
}

func signedInDrive() async throws -> DriveClient {
    let auth = try makeAuth()
    guard await auth.isSignedIn else { throw AuthError.signedOut }
    return DriveClient(auth: auth)
}

/// The folder StreamDisk shows: My Drive with full access, otherwise the app's own folder.
func topFolder(_ drive: DriveClient) async throws -> DriveFile {
    await drive.auth.hasFullDriveAccess ? try await drive.myDrive() : try await drive.appFolder()
}

/// Walks slash-separated folder names below the top folder.
func resolveFolder(_ path: String?, in drive: DriveClient, create: Bool) async throws -> DriveFile {
    var folder = try await topFolder(drive)
    for part in (path ?? "").split(separator: "/").map(String.init) {
        let children = try await drive.children(of: folder.id)
        if let next = children.first(where: { $0.isFolder && $0.name == part }) {
            folder = next
        } else if create {
            folder = try await drive.createFolder(named: part, in: folder.id)
        } else {
            throw UsageError(description: "No folder named \(part)")
        }
    }
    return folder
}

func formatBytes(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
}

func login(_ args: [String]) async throws {
    if let i = args.firstIndex(of: "--client") {
        guard i + 1 < args.count else { throw UsageError(description: "--client needs a path") }
        let source = URL(fileURLWithPath: args[i + 1])
        _ = try OAuthClient.load(from: source)  // validate before installing
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let dest = AppPaths.support.appendingPathComponent("oauth_client.json")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }
    let auth = try makeAuth()
    let full = args.contains("--full")
    print("Opening Google sign-in in your browser…")
    try await auth.signIn(fullDrive: full) { url in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.absoluteString]
        try? p.run()
    }
    if await auth.hasFullDriveAccess {
        print("Signed in with access to your whole Drive.")
    } else {
        let folder = try await DriveClient(auth: auth).appFolder()
        print("Signed in. StreamDisk uses the “\(folder.name)” folder in your Google Drive.")
        if full { print("Full Drive access was not granted, so only that folder is shown.") }
    }
}

func list(_ args: [String]) async throws {
    let drive = try await signedInDrive()
    let folder = try await resolveFolder(args.first, in: drive, create: false)
    let children = try await drive.children(of: folder.id)
    if children.isEmpty { print("(empty)") }
    for f in children.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
        print(f.isFolder ? "\(f.name)/" : "\(f.name)  \(formatBytes(f.size))")
    }
}

func put(_ args: [String]) async throws {
    var files = args
    var target: String?
    if let i = files.firstIndex(of: "--to") {
        guard i + 1 < files.count else { throw UsageError(description: "--to needs a folder") }
        target = files[i + 1]
        files.removeSubrange(i...i + 1)
    }
    guard !files.isEmpty else { throw UsageError(description: "put needs at least one file") }
    let drive = try await signedInDrive()
    let folder = try await resolveFolder(target, in: drive, create: true)
    for path in files {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw UsageError(description: "\(path) is not a file")
        }
        let name = url.lastPathComponent
        let started = Date()
        let uploaded = try await drive.upload(url, name: name, to: folder.id) { done, total in
            let pct = total == 0 ? 100 : Int(Double(done) / Double(total) * 100)
            let rate = Double(done) / max(0.001, -started.timeIntervalSinceNow)
            print("\r\(name)  \(pct)%  \(formatBytes(done)) of \(formatBytes(total))  \(formatBytes(UInt64(rate)))/s",
                  terminator: "")
            fflush(stdout)
        }
        print("\r\(name)  done  \(formatBytes(uploaded.size))\u{1B}[K")
    }
}

func mount(_ args: [String]) async throws {
    let mountPoint = URL(fileURLWithPath: ((args.first ?? "~/StreamDisk") as NSString).expandingTildeInPath)
    let drive = try await signedInDrive()
    let root = try await topFolder(drive)
    let fs = try DriveFileSystem(drive: drive, root: root)
    await fs.start()
    let server = try LocalNFSServer(backend: fs)
    let port = try await server.start()
    try NFSMount.mount(port: port, at: mountPoint)
    print("Mounted at \(mountPoint.path). Press Ctrl-C to unmount.")

    // Unmount on Ctrl-C or kill so Finder is never left holding a dead mount.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let stop: @Sendable () -> Void = {
        do {
            try NFSMount.unmount(mountPoint)
        } catch {
            // Busy (a file is open): force it, since the server is about to go away.
            try? NFSMount.unmount(mountPoint, force: true)
        }
        server.stop()
        print("\nUnmounted.")
        exit(0)
    }
    let sources = [SIGINT, SIGTERM].map { sig in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler(handler: stop)
        s.resume()
        return s
    }
    while true {
        try await Task.sleep(for: .seconds(3600))
        _ = sources
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "login": try await login(Array(args.dropFirst()))
    case "logout":
        try await makeAuth().signOut()
        print("Signed out.")
    case "ls": try await list(Array(args.dropFirst()))
    case "put": try await put(Array(args.dropFirst()))
    case "mount": try await mount(Array(args.dropFirst()))
    case "-h", "--help", "help", nil: print(usage)
    default: throw UsageError(description: "unknown command \(args[0])\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("streamdisk: \(error)\n".utf8))
    exit(1)
}
