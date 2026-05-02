import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static let didCompleteKey = "hasCompletedOnboarding"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: didCompleteKey)
    }

    private var window: NSWindow?
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = OnboardingView { [weak self] in
            self?.complete()
        }

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to SolarLight"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 520, height: 600))
        window.center()
        window.level = .floating

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Treat closing via the title-bar control as completing onboarding —
        // the user has seen it and should not be shown it again next launch.
        markComplete()
        window = nil
        onFinish()
    }

    private func complete() {
        markComplete()
        window?.close()
    }

    private func markComplete() {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
    }
}

private struct OnboardingView: View {
    let getStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            steps
                .padding(.horizontal, 36)
                .padding(.top, 28)
            Spacer(minLength: 12)
            footer
                .padding(.horizontal, 36)
                .padding(.bottom, 28)
        }
        .frame(width: 520, height: 600)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.984, green: 0.988, blue: 0.996),
                    Color(red: 0.929, green: 0.949, blue: 0.984)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.345, green: 0.780, blue: 1.0),
                                Color(red: 0.043, green: 0.247, blue: 0.741)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 112, height: 112)
                    .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)

                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("Welcome to SolarLight")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.13, blue: 0.20))

                Text("Spotlight-style search and chat, anywhere on your Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.32, green: 0.36, blue: 0.45))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 44)
    }

    private var steps: some View {
        VStack(spacing: 14) {
            OnboardingStep(
                badge: "⌘L",
                title: "Press ⌘L from anywhere",
                description: "Opens the SolarLight panel over any app. Press again to dismiss it."
            )
            OnboardingStep(
                badge: "✦",
                title: "Lives in your menu bar",
                description: "Click the sparkle icon any time you want to bring SolarLight back."
            )
            OnboardingStep(
                badge: "⚙",
                title: "Optional: bring your own key",
                description: "SolarLight works out of the box. Click the gear inside the panel to use your own Upstage or OpenAI-compatible API key."
            )
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: getStarted) {
                Text("Get Started")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.40, blue: 0.95),
                                Color(red: 0.04, green: 0.25, blue: 0.74)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Text("You can revisit settings any time from the gear button.")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.55))
        }
    }
}

private struct OnboardingStep: View {
    let badge: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(badge)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.27, green: 0.55, blue: 0.95),
                            Color(red: 0.10, green: 0.32, blue: 0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.13, blue: 0.20))

                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0.34, green: 0.38, blue: 0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(red: 0.85, green: 0.89, blue: 0.96), lineWidth: 1)
        )
    }
}
