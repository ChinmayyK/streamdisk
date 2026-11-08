import SwiftUI

@main
struct StreamDiskApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(delegate.model)
        } label: {
            MenuBarLabel().environment(delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to StreamDisk", id: WelcomeWindow.id) {
            WelcomeView().environment(delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("StreamDisk Settings", id: SettingsWindow.id) {
            SettingsView().environment(delegate.model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// The menu bar icon. It is on screen for the app's whole life, so it also starts the app:
/// it mounts the Drive, or opens setup on first run.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(mounted: model.phase == .mounted))
            .task {
                await model.launch()
                if model.needsOnboarding { openWindow(id: WelcomeWindow.id) }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var services = FinderServices(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
