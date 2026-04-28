import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: SpotlightPanelController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

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

        DispatchQueue.main.async {
            controller.show()
        }
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "SolarLight")

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
