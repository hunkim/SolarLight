import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: SpotlightPanelController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = SpotlightPanelController()
        panelController = controller

        hotKeyManager = HotKeyManager(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey)) { [weak controller] in
            Task { @MainActor in
                controller?.toggle()
            }
        }
        hotKeyManager?.register()

        installMenuBarItem()

        if OnboardingWindowController.hasCompleted {
            DispatchQueue.main.async {
                controller.show()
            }
        } else {
            presentOnboarding()
        }
    }

    private func presentOnboarding() {
        // Promote to a regular app while the welcome window is visible so it
        // takes focus and shows in the Dock; revert to accessory afterwards.
        NSApp.setActivationPolicy(.regular)

        let controller = OnboardingWindowController { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.accessory)
            self.onboardingController = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.panelController?.show()
            }
        }
        onboardingController = controller
        controller.show()
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open SolarLight", action: #selector(openPanel), keyEquivalent: "l")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func openPanel() {
        panelController?.show()
    }
}
