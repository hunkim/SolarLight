import AppKit
import SwiftUI

@MainActor
final class SpotlightPanelController: NSObject, NSWindowDelegate {
    private let viewModel = ChatViewModel()
    private lazy var panel: NSPanel = makePanel()

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.prepareForPresentation()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !viewModel.isShowingSettings else { return }
        hide()
    }

    private func makePanel() -> NSPanel {
        let rootView = SpotlightPanelView(viewModel: viewModel) { [weak self] in
            self?.hide()
        }

        let panel = SpotlightPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: rootView)
        return panel
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }

        let frame = screen.visibleFrame
        let width = min(720, frame.width - 40)
        let height: CGFloat = 360
        let x = frame.midX - width / 2
        let y = frame.maxY - height - 110

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

private final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
