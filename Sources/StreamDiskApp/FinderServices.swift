import AppKit

/// "Keep on This Mac" and "Remove from This Mac" in Finder's right-click menu, as macOS
/// Services declared in Info.plist (NSServices). Services need no app extension.
@MainActor
final class FinderServices: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    @objc func keepOnMac(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(pasteboard, title: "Couldn't keep this on your Mac") { try await self.model.keep($0) }
    }

    @objc func removeFromMac(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(pasteboard, title: "Couldn't remove this from your Mac") { try await self.model.removeKept($0) }
    }

    private func run(_ pasteboard: NSPasteboard, title: String, _ action: @escaping ([URL]) async throws -> Void) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        Task {
            do {
                try await action(urls)
            } catch {
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
