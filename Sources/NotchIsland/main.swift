import AppKit
import Carbon
import NotchIslandCore
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

@MainActor
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
    /// ⌃⌥V: clipboard history search (opt-in, see Settings).
    private var clipboardKey: HotKey?
    private var clipboardKeyObserver: Any?
    /// ⌥⇧Space: the pet climbs out of the notch to help with files.
    private var petKey: HotKey?
    private var petKeyObserver: Any?
    /// Space = play/pause, but only while the island is open on the Music tab.
    private var spaceKey: HotKey?
    private var stateObserver: Any?
    private var enteredAt: Date?
    private var leftAt: Date?
    /// The display the island is on, chosen at layout time (see `ScreenPlacement.pick`).
    private var screen: NSScreen?
    private var screenInfo: ScreenInfo?

    private let canvasSize = CGSize(width: 760, height: 640)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: canvasSize))
        let host = FirstMouseHostingView(rootView: IslandView(model: model))
        host.frame = NSRect(origin: .zero, size: canvasSize)
        panel.contentView = host
        layoutPanel()
        panel.orderFrontRegardless()

        // Displays plugged in/out, resolution or arrangement changed, primary display changed.
        NotificationCenter.default.addObserver(self, selector: #selector(layoutPanel),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // After sleep, a display may come back with another ID/frame, and the window server may have
        // reshuffled windows: lay out again and make sure the panel is ordered in.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(self, selector: #selector(systemDidWake), name: name, object: nil)
        }

        // React to real mouse movement instead of polling: zero work while the mouse is still.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let dragged = event.type == .leftMouseDragged
            MainActor.assumeIsolated {
                if dragged { self?.detectFileDrag() }
                self?.trackMouse()
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragChangeCount = NSPasteboard(name: .drag).changeCount
                // Opened from the keyboard: a click anywhere else closes it.
                if self.model.pinnedOpen, !self.islandRect(padding: 4).contains(NSEvent.mouseLocation) {
                    self.model.setHovering(false)
                }
            }
        }

        // ⌥Space opens/closes the island (can be switched off in Settings).
        hotKeyObserver = AppSettings.shared.$hotKeyEnabled.sink { [weak self] enabled in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotKey = enabled
                    ? HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in
                        MainActor.assumeIsolated { self?.model.toggleFromHotKey() }
                    }
                    : nil
            }
        }
        clipboardKeyObserver = AppSettings.shared.$clipboardHotKey.combineLatest(AppSettings.shared.$clipboardEnabled)
            .sink { [weak self] key, enabled in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wanted = key && enabled
                    guard wanted != (self.clipboardKey != nil) else { return }
                    self.clipboardKey = wanted
                        ? HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
                            MainActor.assumeIsolated { self?.model.toggleClipboardSearch() }
                        }
                        : nil
                }
            }
        PetPanelController.shared.placement = { [weak self] in
            guard let self, let screen = self.screen else { return nil }
            return (screen, self.model.notchSize)
        }
        petKeyObserver = AppSettings.shared.$petHotKeyEnabled.sink { [weak self] enabled in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.petKey = enabled
                    ? HotKey(keyCode: kVK_Space, modifiers: optionKey | shiftKey) { [weak self] in
                        MainActor.assumeIsolated {
                            self?.model.setHovering(false)
                            PetPanelController.shared.toggle()
                        }
                    }
                    : nil
            }
        }
        model.islandScreenRect = { [weak self] in
            guard let info = self?.screenInfo, let model = self?.model else { return nil }
            return ScreenPlacement.islandRect(size: model.notchSize, padding: 0, on: info)
        }
        // Click on the collapsed island → open it. The click is consumed so nothing underneath reacts.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.model.isExpanded, !self.model.fileDragActive,
                      self.islandRect(padding: 8).contains(NSEvent.mouseLocation) else { return false }
                self.model.openFromClick()
                return true
            }
            return consumed ? nil : event
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }
        model.onDragOutEnded = { [weak self] in self?.trackMouse() }
        stateObserver = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateSpaceKey() } }
        }
        model.start()
        LoginItem.applyOnLaunch()
    }

    private var targetScreen: NSScreen? { screen }

    static func info(for screen: NSScreen) -> ScreenInfo {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return ScreenInfo(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame,
                          safeTop: screen.safeAreaInsets.top,
                          auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
                          auxRightWidth: screen.auxiliaryTopRightArea?.width)
    }

    /// Picks the display and moves the panel there. Called on every display change and after wake;
    /// does nothing when nothing changed, so it's cheap to call often. The island's state lives in
    /// the model and is untouched — only the geometry follows the display.
    @objc private func layoutPanel() {
        let screens = NSScreen.screens
        let infos = screens.map(Self.info(for:))
        guard let chosen = ScreenPlacement.pick(infos), let index = infos.firstIndex(of: chosen) else {
            // No displays at all (e.g. mid-reconfiguration while waking): keep the old placement.
            return
        }
        screen = screens[index]
        let notch = ScreenPlacement.notchSize(of: chosen)
        if model.notchSize != notch { model.notchSize = notch }
        let frame = ScreenPlacement.panelFrame(canvas: canvasSize, on: chosen)
        if chosen != screenInfo || panel.frame != frame {
            if let old = screenInfo, old.id != chosen.id { debugLog("island moved to display \(chosen.id)") }
            panel.setFrame(frame, display: true)
        }
        screenInfo = chosen
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func systemDidWake() {
        layoutPanel()
        panel.orderFrontRegardless()
        model.systemDidWake()
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
                MainActor.assumeIsolated {
                    self?.model.setFileDrag(false)
                    self?.trackMouse()
                }
            }
        }
    }

    /// Registered only while it's needed, so everywhere else Space keeps working as usual.
    private func updateSpaceKey() {
        let wanted = model.isExpanded && model.selectedTab == .music && model.nowPlaying != nil
        guard wanted != (spaceKey != nil) else { return }
        spaceKey = wanted
            ? HotKey(keyCode: kVK_Space, modifiers: 0) { [weak self] in MainActor.assumeIsolated { self?.model.perform(.playPause) } }
            : nil
    }

    /// The pet follows the cursor with its eyes when it's near the top of the screen.
    private func updatePetGaze(mouse: NSPoint, screen: NSScreen) {
        guard model.showsPet, !model.isExpanded else { return model.setPetGaze(nil) }
        // The face sits in the middle of the right ear, whose width depends on the current state.
        let half = model.size(for: model.state).width / 2
        let earStart = model.notchSize.width / 2 + EarsLayout<EmptyView, EmptyView>.notchGap
        let faceX = screen.frame.midX + (earStart + half) / 2
        let fromTop = screen.frame.maxY - mouse.y
        guard fromTop < 260 else { return model.setPetGaze(nil) }
        let raw = max(-1, min(1, (mouse.x - faceX) / 220))
        model.setPetGaze((raw * 4).rounded() / 4)   // quarter steps: no re-render on every pixel
    }

    private func islandRect(padding pad: CGFloat) -> CGRect {
        guard let screenInfo else { return .zero }
        return ScreenPlacement.islandRect(size: model.islandSize, padding: pad, on: screenInfo)
    }

    private func trackMouse() {
        guard let screen = targetScreen else { return }
        let mouse = NSEvent.mouseLocation
        updatePetGaze(mouse: mouse, screen: screen)

        if model.fileDragActive {
            // Generous zone around the notch so the drop target opens before you hit it exactly.
            let near = mouse.y > screen.frame.maxY - 170 && abs(mouse.x - screen.frame.midX) < 320
            model.setDropNear(near)
            panel.ignoresMouseEvents = !near
            return
        }
        let inside = islandRect(padding: model.isExpanded ? 4 : 8).contains(mouse)
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
            ? Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackMouse() }
            }
            : nil
    }
}

MainActor.assumeIsolated {
    Snapshots.runIfRequested()
    AnimationCapture.runIfRequested()
    PetCapture.runIfRequested()
    CheckCapture.runIfRequested()
    PetPanelCapture.runIfRequested()
    PetAskBench.runIfRequested()
    SearchCapture.runIfRequested()
    TabsCapture.runIfRequested()
    GazeBenchmark.runIfRequested()
    StatesBenchmark.runIfRequested()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
