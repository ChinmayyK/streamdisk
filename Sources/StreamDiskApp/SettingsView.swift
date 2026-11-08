import AppKit
import StreamDiskCore
import SwiftUI

enum SettingsWindow {
    static let id = "settings"
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case kept = "Kept on This Mac"
    case about = "About"

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    TabButton(title: tab.rawValue, selected: model.settingsTab == tab) { model.settingsTab = tab }
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 12)
            Divider()
            ScrollView {
                Group {
                    switch model.settingsTab {
                    case .general: GeneralSettings()
                    case .kept: KeptSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 520)
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .onAppear { NSApp.activate() }
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.inkSoft)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.card : (hovered ? Theme.track : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.stroke : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Building blocks

/// A titled group of rows on a card, as in Link All's settings.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).padding(.leading, 2)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    var divider = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 16) }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

private struct SmallButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? Theme.danger : Theme.ink)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.track))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Section(title: "Account") {
                Row(title: "Google account", detail: model.email ?? "Not signed in") {
                    if model.phase != .signedOut {
                        Button("Sign Out…") { confirmSignOut = true }.buttonStyle(SmallButtonStyle(destructive: true))
                    }
                }
                Row(title: "Shows", detail: model.fullDrive
                    ? "Your whole Drive"
                    : "The StreamDisk folder in your Drive. Sign in again to show your whole Drive.", divider: true) {
                    EmptyView()
                }
            }
            Section(title: "Disk") {
                Row(title: "Location", detail: "~/StreamDisk") {
                    Button("Show in Finder") { model.openInFinder() }.buttonStyle(SmallButtonStyle())
                        .disabled(model.phase != .mounted)
                }
                Row(title: "Open at login", detail: "Keeps your Drive mounted after a restart.", divider: true) {
                    Toggle("", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                }
            }
        }
        .confirmationDialog("Sign out of Google Drive?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("StreamDisk ejects the disk and deletes the files kept on this Mac. Nothing is deleted from your Drive.")
        }
    }
}

// MARK: - Kept on this Mac

private struct KeptSettings: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kept items open without the internet. They stay in your Drive, and changes made elsewhere download automatically.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.kept.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.kept.enumerated()), id: \.element.id) { index, status in
                        KeptRow(status: status, divider: index > 0)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.accent : Theme.stroke, lineWidth: dropTargeted ? 1.5 : 1))
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }

            HStack {
                Button("Add…") { choose() }
                    .buttonStyle(SmallButtonStyle())
                    .disabled(model.phase != .mounted)
                Spacer()
                if model.keptBytes > 0 {
                    Text("Using \(Format.bytes(model.keptBytes)) on this Mac")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accentInk)
            Text("Nothing kept yet").font(.system(size: 13, weight: .semibold))
            Text("Right-click a file or folder on the StreamDisk disk and choose Keep on This Mac, or drag it here.")
                .font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(dropTargeted ? Theme.accent : Theme.stroke,
                          style: StrokeStyle(lineWidth: dropTargeted ? 1.5 : 1, dash: dropTargeted ? [] : [4, 3])))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = model.mountPoint
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Keep on This Mac"
        panel.message = "Choose files or folders on the StreamDisk disk to keep on this Mac."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        error = nil
        Task {
            do { try await model.keep(urls) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct KeptRow: View {
    @Environment(AppModel.self) private var model
    let status: OfflineStore.PinStatus
    let divider: Bool

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 56) }
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.pin.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if case .downloading = status.state, status.bytes > 0 {
                        Meter(value: Double(status.stored) / Double(status.bytes), height: 3).frame(maxWidth: 220)
                    }
                    Text(detail).font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(isFailed ? Theme.danger : Theme.inkSoft)
                }
                Spacer(minLength: 8)
                if let url = model.location(of: status.pin) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(SmallButtonStyle())
                    .help("Show in Finder")
                }
                Button("Remove") { Task { await model.removeKept(id: status.pin.driveID) } }
                    .buttonStyle(SmallButtonStyle())
                    .help("Remove the copy from this Mac. The original stays in your Drive.")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private var icon: some View {
        Group {
            if let url = model.location(of: status.pin) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: status.pin.isFolder ? "folder" : "doc")
                    .font(.system(size: 18)).foregroundStyle(Theme.inkSoft)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var isFailed: Bool {
        if case .failed = status.state { return true }
        return false
    }

    private var detail: String {
        let count = status.pin.isFolder ? "\(status.files) \(status.files == 1 ? "file" : "files") · " : ""
        switch status.state {
        case .ready:
            return "\(count)On this Mac · \(Format.bytes(status.bytes))"
        case .downloading:
            return status.bytes == 0 ? "Checking…"
                : "\(count)Downloading · \(Format.bytes(status.stored)) of \(Format.bytes(status.bytes))"
        case .failed(let reason):
            return status.stored > 0 ? "\(reason) · \(Format.bytes(status.stored)) on this Mac" : reason
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Mark(size: 72)
            VStack(spacing: 3) {
                Text("StreamDisk").font(.system(size: 20, weight: .bold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.inkSoft)
            }
            Text("Your Google Drive as a disk on your Mac.")
                .font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}
