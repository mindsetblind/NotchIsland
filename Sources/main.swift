import AppKit
import SwiftUI

/// Borderless panel that floats above the menu bar and never steals focus.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons react to the very first click even though the panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: IslandPanel!
    private let model = IslandModel()
    private var mouseTimer: Timer?
    private var enteredAt: Date?
    private var leftAt: Date?

    private let canvasSize = CGSize(width: 760, height: 280)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: canvasSize))
        let host = FirstMouseHostingView(rootView: IslandView(model: model))
        host.frame = NSRect(origin: .zero, size: canvasSize)
        panel.contentView = host
        layoutPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(layoutPanel),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.trackMouse()
        }
        model.start()
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    @objc private func layoutPanel() {
        guard let screen = targetScreen else { return }
        model.notchSize = Self.notchSize(of: screen)
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - canvasSize.width / 2,
                              y: f.maxY - canvasSize.height,
                              width: canvasSize.width,
                              height: canvasSize.height), display: true)
    }

    static func notchSize(of screen: NSScreen) -> CGSize {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        // No physical notch (external display): fake a small pill under the menu bar edge.
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGSize(width: 190, height: menuBar)
    }

    private func trackMouse() {
        guard let screen = targetScreen else { return }
        let mouse = NSEvent.mouseLocation
        let size = model.islandSize
        let pad: CGFloat = model.isExpanded ? 4 : 8
        let rect = CGRect(x: screen.frame.midX - size.width / 2 - pad,
                          y: screen.frame.maxY - size.height - pad,
                          width: size.width + pad * 2,
                          height: size.height + pad + 1)
        let inside = rect.contains(mouse)
        panel.ignoresMouseEvents = !inside

        let now = Date()
        if inside {
            leftAt = nil
            if enteredAt == nil { enteredAt = now }
            if !model.isExpanded {
                model.setHoverHint(true)
                if now.timeIntervalSince(enteredAt!) > 0.15 { model.setHovering(true) }
            }
        } else {
            enteredAt = nil
            model.setHoverHint(false)
            if model.isExpanded {
                if leftAt == nil { leftAt = now }
                if now.timeIntervalSince(leftAt!) > 0.25 { model.setHovering(false) }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
