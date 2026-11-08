import SwiftUI

enum WelcomeWindow {
    static let id = "welcome"
}

/// First-run setup: what StreamDisk does, which part of Drive to show, Google sign-in, done.
struct WelcomeView: View {
    private enum Step { case intro, access, signingIn, ready }

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: Step = .intro
    @State private var fullDrive = false
    @State private var signIn: Task<Void, Never>?
    @State private var error: String?
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .intro: intro
                case .access: access
                case .signingIn: signingIn
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .padding(.horizontal, 40).padding(.top, 52).padding(.bottom, 32)
        .frame(width: 480, height: 500)
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: step)
        .onAppear { NSApp.activate() }
    }

    // MARK: Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mark(size: 56)
            Text("Your Google Drive,\nas a disk on your Mac")
                .font(.system(size: 26, weight: .bold)).tracking(-0.4)
                .padding(.top, 28)
            VStack(alignment: .leading, spacing: 14) {
                point("externaldrive", "Shows up in Finder like any other disk.")
                point("play", "Files stream when you open them, so big videos start in a second or two.")
                point("internaldrive", "Nothing is downloaded to your Mac, so it takes no space.")
            }
            .padding(.top, 24)
            Spacer()
            Button("Get Started") { step = .access }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle("What should StreamDisk show?",
                      "You can change this later by signing in again.")
            VStack(spacing: 10) {
                option(selected: !fullDrive, title: "A StreamDisk folder",
                       detail: "Only files you add through StreamDisk. Your other files stay private to Google.",
                       tag: "Recommended") { fullDrive = false }
                option(selected: fullDrive, title: "Your whole Drive",
                       detail: "Everything in My Drive. Google will ask you to allow full access.") { fullDrive = true }
            }
            .padding(.top, 24)
            Spacer()
            HStack(spacing: 10) {
                Button("Back") { step = .intro }.buttonStyle(SecondaryButtonStyle())
                Button("Continue with Google") { startSignIn() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var signingIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle("Finish signing in in your browser",
                      "Google opened in your browser. Choose your account and allow access, then come back here.")
            if let error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .mounting ? "Mounting your Drive…" : "Waiting for Google…")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
                }
                .padding(.top, 24)
            }
            Spacer()
            HStack(spacing: 10) {
                Button("Back") { cancelSignIn() }.buttonStyle(SecondaryButtonStyle())
                if error != nil {
                    Button("Try Again") { startSignIn() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle().fill(Theme.accentWash).frame(width: 56, height: 56)
                Image(systemName: "checkmark").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accentInk)
            }
            stepTitle("StreamDisk is ready",
                      model.fullDrive ? "Your Drive is in Finder, under StreamDisk in your home folder."
                        : "Files you put in the StreamDisk disk go to a StreamDisk folder in your Drive.")
                .padding(.top, 28)
            Toggle(isOn: $openAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.system(size: 13, weight: .medium))
                    Text("Keeps your Drive mounted after a restart.").font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .card()
            .padding(.top, 24)
            Spacer()
            HStack(spacing: 10) {
                Button("Done") { finish(open: false) }.buttonStyle(SecondaryButtonStyle())
                Button("Open in Finder") { finish(open: true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Pieces

    private func stepTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.3)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accentInk)
                .frame(width: 18)
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(selected: Bool, title: String, detail: String, tag: String? = nil,
                        choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.accent : Theme.inkFaint, lineWidth: 1.5)
                    if selected { Circle().fill(Theme.accent).padding(4) }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13.5, weight: .semibold))
                        if let tag {
                            Text(tag).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentInk)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accentWash))
                        }
                    }
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Actions

    private func startSignIn() {
        error = nil
        step = .signingIn
        signIn = Task {
            do {
                try await model.signIn(fullDrive: fullDrive)
                if case .failed(let reason) = model.phase {
                    error = reason
                } else if !Task.isCancelled {
                    step = .ready
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = String(describing: error) }
            }
        }
    }

    private func cancelSignIn() {
        signIn?.cancel()
        signIn = nil
        error = nil
        step = .access
    }

    private func finish(open: Bool) {
        if openAtLogin != model.openAtLogin { model.openAtLogin = openAtLogin }
        if open { model.openInFinder() }
        dismissWindow(id: WelcomeWindow.id)
    }
}
