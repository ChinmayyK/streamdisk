import AppKit
import NFSServer
import Observation
import ServiceManagement
import StreamDiskCore

/// The app's state: sign-in, the mounted volume, and what it is doing.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        /// Not signed in, or no OAuth client: onboarding is needed.
        case signedOut
        case mounting
        case mounted
        /// Signed in but not mounted, because the user ejected it.
        case ejected
        case failed(String)
    }

    private(set) var phase: Phase = .mounting
    private(set) var email: String?
    private(set) var quota: DriveQuota?
    private(set) var fullDrive = false
    private(set) var activity = DriveFileSystem.Activity()
    /// Items kept on this Mac, with their download state.
    private(set) var kept: [OfflineStore.PinStatus] = []
    private(set) var keptBytes: UInt64 = 0
    var settingsTab: SettingsTab = .general
    /// A short message about the last action that failed, such as an eject refused while a file is open.
    var notice: String?

    let mountPoint = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("StreamDisk")

    private var auth: GoogleAuth?
    private var drive: DriveClient?
    private var fs: DriveFileSystem?
    private var offline: OfflineStore?
    private var server: LocalNFSServer?
    private var watcher: Task<Void, Never>?

    var needsOnboarding: Bool { phase == .signedOut }

    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Could not change the login item: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called once at launch: mounts straight away if already signed in.
    func launch() async {
        do {
            let auth = GoogleAuth(client: try OAuthClient.locate())
            self.auth = auth
            if await auth.isSignedIn {
                await mount()
            } else {
                phase = .signedOut
            }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    // MARK: Sign-in

    /// Opens Google sign-in in the browser and waits for it to finish, then mounts.
    func signIn(fullDrive: Bool) async throws {
        let auth = try self.auth ?? GoogleAuth(client: OAuthClient.locate())
        self.auth = auth
        try await auth.signIn(fullDrive: fullDrive) { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        await mount()
    }

    func signOut() async {
        await unmount(force: true)
        try? await auth?.signOut()
        // Kept copies belong to the account that was signed in.
        try? FileManager.default.removeItem(at: Self.offlineDirectory)
        email = nil
        quota = nil
        kept = []
        keptBytes = 0
        phase = .signedOut
    }

    // MARK: Mounting

    func mount() async {
        guard let auth, phase != .mounted else { return }
        phase = .mounting
        notice = nil
        do {
            guard await auth.isSignedIn else { phase = .signedOut; return }
            let drive = DriveClient(auth: auth)
            fullDrive = await auth.hasFullDriveAccess
            let root = fullDrive ? try await drive.myDrive() : try await drive.appFolder()
            // A mount left behind by a crash would make mount_nfs fail.
            if Self.isMounted(mountPoint) { try? NFSMount.unmount(mountPoint, force: true) }
            // Mounting over a folder hides what is in it, so refuse rather than surprise.
            if Self.hasContents(mountPoint) {
                phase = .failed("There's already a folder named StreamDisk in your home folder with files in it. Move or rename it, then try again.")
                return
            }
            let offline = try OfflineStore(drive: drive, directory: Self.offlineDirectory)
            let fs = try DriveFileSystem(drive: drive, root: root, offline: offline)
            await fs.start()
            await offline.start()
            let server = try LocalNFSServer(backend: fs, exportPath: "/StreamDisk")
            let port = try await server.start()
            do {
                try NFSMount.mount(port: port, export: server.exportPath, at: mountPoint)
            } catch {
                server.stop()
                throw error
            }
            (self.drive, self.fs, self.offline, self.server) = (drive, fs, offline, server)
            phase = .mounted
            startWatching()
        } catch AuthError.signedOut {
            phase = .signedOut
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Ejects the volume. Refuses while a file is open unless `force` is set.
    func eject() async {
        do {
            try NFSMount.unmount(mountPoint)
            await unmount(force: false)
            phase = .ejected
        } catch {
            notice = "A file on StreamDisk is still open. Close it and try again."
        }
    }

    /// Stops serving. With `force`, also unmounts even if files are open.
    func unmount(force: Bool) async {
        watcher?.cancel()
        watcher = nil
        if force, Self.isMounted(mountPoint) {
            if (try? NFSMount.unmount(mountPoint)) == nil { try? NFSMount.unmount(mountPoint, force: true) }
        }
        server?.stop()
        await offline?.stop()
        (server, fs, offline) = (nil, nil, nil)
        activity = .init()
    }

    /// Unmounts synchronously so Finder is never left holding a dead mount after quitting.
    func shutdown() {
        if Self.isMounted(mountPoint) {
            if (try? NFSMount.unmount(mountPoint)) == nil { try? NFSMount.unmount(mountPoint, force: true) }
        }
        server?.stop()
    }

    func openInFinder() {
        NSWorkspace.shared.open(mountPoint)
    }

    // MARK: Keep on this Mac

    enum KeepError: LocalizedError {
        case notMounted, notOnDisk, stillUploading(String)

        var errorDescription: String? {
            switch self {
            case .notMounted: "StreamDisk isn't mounted. Mount it, then try again."
            case .notOnDisk: "Only items on the StreamDisk disk can be kept on this Mac."
            case .stillUploading(let name): "“\(name)” is still uploading. Try again when it's done."
            }
        }
    }

    /// Keeps the items at these Finder locations on this Mac.
    func keep(_ urls: [URL]) async throws {
        guard let fs, let offline else { throw KeepError.notMounted }
        for url in urls {
            let path = try relativePath(url)
            let file: DriveFile
            do { file = try await fs.item(atPath: path) } catch { throw KeepError.stillUploading(url.lastPathComponent) }
            await offline.keep(file, path: path)
        }
        await refreshKept()
    }

    /// Stops keeping the items at these Finder locations.
    func removeKept(_ urls: [URL]) async throws {
        guard let fs, let offline else { throw KeepError.notMounted }
        for url in urls {
            let path = try relativePath(url)
            if let file = try? await fs.item(atPath: path) { await offline.remove(file.id) }
        }
        await refreshKept()
    }

    func removeKept(id: String) async {
        await offline?.remove(id)
        await refreshKept()
    }

    /// Where a kept item is in Finder now. Nil if it moved since it was kept.
    func location(of pin: OfflineStore.Pin) -> URL? {
        let url = mountPoint.appendingPathComponent(pin.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func relativePath(_ url: URL) throws -> String {
        let root = mountPoint.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { throw KeepError.notOnDisk }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func refreshKept() async {
        guard let offline else { return }
        let status = await offline.status()
        if status != kept { kept = status }
        let bytes = await offline.bytesOnDisk
        if bytes != keptBytes { keptBytes = bytes }
    }

    // MARK: Status

    /// Refreshes activity every second and the account every minute while mounted.
    /// Notices when the volume is ejected from Finder.
    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let fs = self.fs else { return }
                if !Self.isMounted(self.mountPoint) {
                    await self.unmount(force: false)
                    self.phase = .ejected
                    return
                }
                let now = await fs.activity()
                if now != self.activity { self.activity = now }
                await self.refreshKept()
                if tick % 60 == 0, let account = try? await self.drive?.account() {
                    self.email = account.email
                    self.quota = account.quota
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static let offlineDirectory = AppPaths.support.appendingPathComponent("Offline", isDirectory: true)

    /// Whether a folder (not a mount) holds anything besides Finder's own files.
    static func hasContents(_ url: URL) -> Bool {
        guard !isMounted(url), let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return items.contains { ![".DS_Store", ".localized"].contains($0) }
    }

    static func isMounted(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == url.path
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? NFSMount.Failure { return failure.output.isEmpty ? "The disk could not be mounted." : failure.output }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "You're offline. StreamDisk mounts once you're back online."
        }
        return String(describing: error)
    }
}
