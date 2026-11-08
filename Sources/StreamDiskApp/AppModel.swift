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
    /// A short message about the last action that failed, such as an eject refused while a file is open.
    var notice: String?

    let mountPoint = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("StreamDisk")

    private var auth: GoogleAuth?
    private var drive: DriveClient?
    private var fs: DriveFileSystem?
    private var server: LocalNFSServer?
    private var watcher: Task<Void, Never>?

    var needsOnboarding: Bool { phase == .signedOut }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                notice = "Could not change the login item: \(error.localizedDescription)"
            }
        }
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
        email = nil
        quota = nil
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
            let fs = try DriveFileSystem(drive: drive, root: root)
            await fs.start()
            let server = try LocalNFSServer(backend: fs, exportPath: "/StreamDisk")
            let port = try await server.start()
            do {
                try NFSMount.mount(port: port, export: server.exportPath, at: mountPoint)
            } catch {
                server.stop()
                throw error
            }
            (self.drive, self.fs, self.server) = (drive, fs, server)
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
        (server, fs) = (nil, nil)
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
                if tick % 60 == 0, let account = try? await self.drive?.account() {
                    self.email = account.email
                    self.quota = account.quota
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
