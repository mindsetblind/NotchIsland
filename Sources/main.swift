import AppKit
import Carbon
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
    /// One-shot re-check while a hover delay is pending (expand after 0.15 s, collapse after 0.25 s).
    private var recheckTimer: Timer?
    /// Drag pasteboard generation at the last mouse-down: a change during dragging means a real drag session.
    private var dragChangeCount = 0
    private var dragWatch: Timer?
    private var hotKey: HotKey?
    private var hotKeyObserver: Any?
    /// Space = play/pause, but only while the island is open on the Music tab.
    private var spaceKey: HotKey?
    private var stateObserver: Any?
    private var enteredAt: Date?
    private var leftAt: Date?

    private let canvasSize = CGSize(width: 760, height: 640)

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

        // React to real mouse movement instead of polling: zero work while the mouse is still.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            if event.type == .leftMouseDragged { self?.detectFileDrag() }
            self?.trackMouse()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.dragChangeCount = NSPasteboard(name: .drag).changeCount
            // Opened from the keyboard: a click anywhere else closes it.
            if self.model.pinnedOpen, !self.islandRect(padding: 4).contains(NSEvent.mouseLocation) {
                self.model.setHovering(false)
            }
        }

        // ⌥Space opens/closes the island (can be switched off in Settings).
        hotKeyObserver = AppSettings.shared.$hotKeyEnabled.sink { [weak self] enabled in
            guard let self else { return }
            self.hotKey = enabled
                ? HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.model.toggleFromHotKey() }
                : nil
        }
        // Click on the collapsed island → open it. The click is consumed so nothing underneath reacts.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, !self.model.isExpanded, !self.model.fileDragActive,
                  self.islandRect(padding: 8).contains(NSEvent.mouseLocation) else { return event }
            self.model.setHovering(true)
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] event in
            self?.trackMouse()
            return event
        }
        model.onDragOutEnded = { [weak self] in self?.trackMouse() }
        stateObserver = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateSpaceKey() }
        }
        model.start()
        LoginItem.applyOnLaunch()
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

    // MARK: File drag → AirDrop

    /// Another app (Finder, Desktop…) started dragging files: let the island act as a drop target.
    private func detectFileDrag() {
        guard !model.fileDragActive else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount,
              pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        model.setFileDrag(true)
        // Drag sessions swallow mouse-up in some cases, so watch the button state until it's released.
        dragWatch?.invalidate()
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            // Leave a moment for the drop itself to be delivered before tearing the drop zone down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.model.setFileDrag(false)
                self?.trackMouse()
            }
        }
    }

    /// Registered only while it's needed, so everywhere else Space keeps working as usual.
    private func updateSpaceKey() {
        let wanted = model.isExpanded && model.selectedTab == .music && model.nowPlaying != nil
        guard wanted != (spaceKey != nil) else { return }
        spaceKey = wanted
            ? HotKey(keyCode: kVK_Space, modifiers: 0) { [weak self] in self?.model.perform(.playPause) }
            : nil
    }

    /// The mascot follows the cursor with its eyes when it's near the top of the screen.
    private func updateMascotGaze(mouse: NSPoint, screen: NSScreen) {
        guard model.showsMascot, !model.isExpanded else { return model.setMascotGaze(nil) }
        // The face sits in the middle of the right ear, whose width depends on the current state.
        let half = model.size(for: model.state).width / 2
        let earStart = model.notchSize.width / 2 + EarsLayout<EmptyView, EmptyView>.notchGap
        let faceX = screen.frame.midX + (earStart + half) / 2
        let fromTop = screen.frame.maxY - mouse.y
        guard fromTop < 260 else { return model.setMascotGaze(nil) }
        let raw = max(-1, min(1, (mouse.x - faceX) / 220))
        model.setMascotGaze((raw * 4).rounded() / 4)   // quarter steps: no re-render on every pixel
    }

    private func islandRect(padding pad: CGFloat) -> CGRect {
        guard let screen = targetScreen else { return .zero }
        let size = model.islandSize
        return CGRect(x: screen.frame.midX - size.width / 2 - pad,
                      y: screen.frame.maxY - size.height - pad,
                      width: size.width + pad * 2,
                      height: size.height + pad + 1)
    }

    private func trackMouse() {
        guard let screen = targetScreen else { return }
        let mouse = NSEvent.mouseLocation
        updateMascotGaze(mouse: mouse, screen: screen)

        if model.fileDragActive {
            // Generous zone around the notch so the drop target opens before you hit it exactly.
            let near = mouse.y > screen.frame.maxY - 170 && abs(mouse.x - screen.frame.midX) < 320
            model.setDropNear(near)
            panel.ignoresMouseEvents = !near
            return
        }
        let size = model.islandSize
        let pad: CGFloat = model.isExpanded ? 4 : 8
        let rect = CGRect(x: screen.frame.midX - size.width / 2 - pad,
                          y: screen.frame.maxY - size.height - pad,
                          width: size.width + pad * 2,
                          height: size.height + pad + 1)
        let inside = rect.contains(mouse)
        panel.ignoresMouseEvents = !inside

        let now = Date()
        let opensOnHover = AppSettings.shared.openMode == .hover
        if inside {
            leftAt = nil
            model.unpin()
            if !model.isExpanded {
                // "Click" mode: hover only lifts the island (a click opens it, see the mouse-down monitor).
                // "Hover" mode: it opens after resting on it briefly.
                model.setHoverHint(true)
                if enteredAt == nil { enteredAt = now }
                if opensOnHover, now.timeIntervalSince(enteredAt!) > 0.15 { model.setHovering(true) }
            }
        } else {
            enteredAt = nil
            model.setHoverHint(false)
            if model.isExpanded && !model.dragOutActive && !model.pinnedOpen {
                if leftAt == nil { leftAt = now }
                if now.timeIntervalSince(leftAt!) > 0.25 { model.setHovering(false) }
            }
        }

        // The mouse may stop moving while a delay is still running — check again shortly.
        let pending = (inside && !model.isExpanded && opensOnHover) || (!inside && model.isExpanded && !model.pinnedOpen)
        recheckTimer?.invalidate()
        recheckTimer = pending
            ? Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in self?.trackMouse() }
            : nil
    }
}

MainActor.assumeIsolated {
    Snapshots.runIfRequested()
    AnimationCapture.runIfRequested()
    MascotCapture.runIfRequested()
    CheckCapture.runIfRequested()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
