import AppKit
import SwiftUI

/// First-run onboarding: welcome → permissions → done. Shown once (`AppSettings.didOnboard`),
/// and again from Settings › About.
enum OnboardingWindow {
    private static var window: NSWindow?

    static func showIfNeeded() {
        guard !AppSettings.shared.didOnboard else { return }
        show()
    }

    static func show() {
        AppSettings.shared.didOnboard = true
        OnboardingModel.shared.step = 0
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView())
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to Perch"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 520, height: 460))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        PermissionCenter.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func close() { window?.close() }
}

final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    @Published var step = 0
    static let stepCount = 3
}

struct OnboardingView: View {
    @ObservedObject var model = OnboardingModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case 0: welcome
                case 1: permissions
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(model.step)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<OnboardingModel.stepCount, id: \.self) { i in
                        Circle().fill(i == model.step ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if model.step > 0 && model.step < OnboardingModel.stepCount - 1 {
                    Button("Back") { go(-1) }
                }
                if model.step < OnboardingModel.stepCount - 1 {
                    Button(model.step == 1 ? "Continue" : "Get Started") { go(1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { OnboardingWindow.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
    }

    private func go(_ delta: Int) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            model.step = min(max(model.step + delta, 0), OnboardingModel.stepCount - 1)
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            NotchGlyph().frame(width: 180, height: 44)
            Text("Welcome to Perch").font(.system(size: 24, weight: .bold))
            Text("Your notch becomes a live surface for music, calendar, HUDs and quick files.\nHover the notch to open it, or swipe down on it with two fingers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .padding(24)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(.system(size: 20, weight: .bold))
            Text("Allow what you want to use. You can change these any time in Settings › Permissions.")
                .foregroundStyle(.secondary)
            Form {
                ForEach(Permission.allCases) { PermissionRow(permission: $0, promptWhenUndecided: true) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("You're all set").font(.system(size: 24, weight: .bold))
            Text("Settings live behind the gear in the open notch, or at perch://settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Open Settings") {
                OnboardingWindow.close()
                SettingsWindow.show()
            }
        }
        .padding(24)
    }
}

/// Small black notch shape for the welcome step.
private struct NotchGlyph: View {
    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
            .fill(Color.black)
            .overlay(
                HStack {
                    Image(systemName: "music.note")
                    Spacer()
                    Image(systemName: "waveform")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16)
            )
    }
}
