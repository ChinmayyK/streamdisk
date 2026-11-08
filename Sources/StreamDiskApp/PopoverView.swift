import StreamDiskCore
import SwiftUI

/// The window that opens from the menu bar icon.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            content.padding(.horizontal, 12)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
            }
            Divider().padding(.top, 12)
            footer
        }
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            Mark(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("StreamDisk").font(.system(size: 13.5, weight: .semibold))
                HStack(spacing: 5) {
                    if model.phase == .mounting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                    Text(statusText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
    }

    private var statusText: String {
        switch model.phase {
        case .signedOut: "Not set up"
        case .mounting: "Mounting…"
        case .mounted: "Mounted at ~/StreamDisk"
        case .ejected: "Ejected"
        case .failed: "Not mounted"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .mounted: Theme.accent
        case .failed: Theme.danger
        default: Theme.inkFaint
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .signedOut:
            message(title: "Connect your Google Drive",
                    body: "Your files show up in Finder and stream when you open them.",
                    action: "Set Up StreamDisk") { openWindow(id: WelcomeWindow.id) }
        case .mounting:
            driveCard.redacted(reason: .placeholder)
        case .mounted:
            VStack(spacing: 14) {
                driveCard
                ActivityList(activity: model.activity, kept: model.kept)
            }
        case .ejected:
            message(title: "StreamDisk is ejected", body: "Your files stay in Google Drive.",
                    action: "Mount") { Task { await model.mount() } }
        case .failed(let reason):
            message(title: "StreamDisk couldn't mount", body: reason,
                    action: "Try Again") { Task { await model.mount() } }
        }
    }

    private var driveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.fullDrive ? "Google Drive" : "StreamDisk folder")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let email = model.email {
                    Text(verbatim: email).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let quota = model.quota {
                VStack(alignment: .leading, spacing: 6) {
                    Meter(value: quota.limit.map { Double(quota.usage) / Double(max($0, 1)) } ?? 0, height: 5)
                    Text(usageText(quota)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !model.kept.isEmpty {
                Button { openSettings(.kept) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accentInk)
                        Text(keptText).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("Open in Finder") { model.openInFinder() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .card()
    }

    private var keptText: String {
        let n = model.kept.count
        return "\(n) \(n == 1 ? "item" : "items") kept on this Mac · \(Format.bytes(model.keptBytes))"
    }

    private func openSettings(_ tab: SettingsTab) {
        model.settingsTab = tab
        openWindow(id: SettingsWindow.id)
        NSApp.activate()
    }

    private func usageText(_ quota: DriveQuota) -> String {
        guard let limit = quota.limit else { return "\(Format.bytes(quota.usage)) used" }
        return "\(Format.bytes(quota.usage)) of \(Format.bytes(limit)) used"
    }

    private func message(title: String, body: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform).buttonStyle(PrimaryButtonStyle()).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            switch model.phase {
            case .mounted:
                footerButton("Eject") { Task { await model.eject() } }
            case .ejected, .failed:
                footerButton("Mount") { Task { await model.mount() } }
            default:
                EmptyView()
            }
            Spacer()
            if model.phase != .signedOut {
                footerButton("Settings…") { openSettings(.general) }
                Spacer()
            }
            footerButton("Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// What is streaming and uploading right now.
struct ActivityList: View {
    let activity: DriveFileSystem.Activity
    let kept: [OfflineStore.PinStatus]

    /// Kept items still downloading, with something left to fetch.
    private var downloading: [OfflineStore.PinStatus] {
        kept.filter { if case .downloading = $0.state { return $0.bytes > $0.stored } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity").font(.system(size: 13, weight: .bold)).padding(.horizontal, 4).padding(.bottom, 2)
            if activity.streams.isEmpty && activity.uploads.isEmpty && downloading.isEmpty {
                Text("Nothing streaming or uploading")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 6)
            }
            ForEach(activity.streams.prefix(2), id: \.name) { stream in
                ActivityRow(symbol: "play.fill", title: stream.name,
                            detail: "Streaming · \(Format.rate(stream.bytesPerSecond))")
            }
            if !activity.uploads.isEmpty { uploadRow }
            if !downloading.isEmpty { keepRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var keepRow: some View {
        let total = downloading.reduce(0) { $0 + $1.bytes }
        let stored = downloading.reduce(0) { $0 + $1.stored }
        ActivityRow(symbol: "arrow.down",
                    title: downloading.count == 1 ? downloading[0].pin.name : "Keeping \(downloading.count) items",
                    detail: "Downloading to this Mac · \(Format.bytes(total - stored)) left",
                    progress: total == 0 ? nil : Double(stored) / Double(total))
    }

    @ViewBuilder private var uploadRow: some View {
        let uploads = activity.uploads
        let total = uploads.reduce(0) { $0 + $1.total }
        let sent = uploads.reduce(0) { $0 + $1.sent }
        let title = uploads.count == 1 ? uploads[0].name : "Uploading \(uploads.count) files"
        let detail = sent == 0 ? "Waiting to upload · \(Format.bytes(total))"
            : "\(Format.bytes(total - sent)) left"
        ActivityRow(symbol: "arrow.up", title: title, detail: detail,
                    progress: total == 0 ? nil : Double(sent) / Double(total))
    }
}

struct ActivityRow: View {
    let symbol: String
    let title: String
    let detail: String
    var progress: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accentInk)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentWash))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let progress { Meter(value: progress, height: 3) }
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
    }
}
