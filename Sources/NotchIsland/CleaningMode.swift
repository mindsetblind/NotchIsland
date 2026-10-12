import AppKit
import ApplicationServices
import SwiftUI

/// "Cleaning mode": black full-screen overlay on every display that swallows keyboard, mouse and
/// trackpad input, so the screen and keyboard can be wiped. Exit: hold Esc for 2 s, or wait for the timer.
///
/// Without any permission: app switching, Force Quit, Dock and menu bar are disabled via presentation
/// options and all key/mouse events land in our window. With Accessibility granted, an event tap also
/// swallows the media keys (brightness, volume…) and trackpad gestures.
final class CleaningMode: ObservableObject {
    static let shared = CleaningMode()
    static let durations: [TimeInterval] = [30, 60, 120]
    static let escHoldSeconds: TimeInterval = 2

    @Published private(set) var isActive = false
    @Published private(set) var endDate = Date()
    @Published private(set) var escPressedAt: Date?
    var onFinish: (() -> Void)?

    private var windows: [NSWindow] = []
    private var savedOptions: NSApplication.PresentationOptions = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var ticker: Timer?
    private var escExit: DispatchWorkItem?

    var blocksMediaKeys: Bool { AXIsProcessTrusted() }

    func start(duration: TimeInterval) {
        guard !isActive else { return }
        isActive = true
        endDate = Date().addingTimeInterval(duration)
        escPressedAt = nil

        NSApp.activate(ignoringOtherApps: true)
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
                                     .disableForceQuit, .disableSessionTermination, .disableHideApplication]

        for screen in NSScreen.screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            if screen == NSScreen.main {
                window.contentView = NSHostingView(rootView: CleaningOverlay(mode: self))
            }
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSCursor.hide()
        installTap()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        guard isActive else { return }
        ticker?.invalidate()
        ticker = nil
        removeTap()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSApp.presentationOptions = savedOptions
        NSCursor.unhide()
        isActive = false
        escExit?.cancel()
        escExit = nil
        escPressedAt = nil
        onFinish?()
    }

    /// Esc handling shared by the window (no permission) and the event tap (Accessibility).
    fileprivate func handleKey(keyCode: Int, down: Bool) {
        guard keyCode == 53 else { return }   // Esc
        if down {
            guard escPressedAt == nil else { return }   // ignore key-repeat
            escPressedAt = Date()
            let exit = DispatchWorkItem { [weak self] in self?.stop() }
            escExit = exit
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.escHoldSeconds, execute: exit)
        } else {
            escExit?.cancel()
            escExit = nil
            escPressedAt = nil
        }
    }

    private func tick() {
        if Date() >= endDate { stop() }
    }

    // MARK: Event tap (only when Accessibility is granted)

    private func installTap() {
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask.max   // everything: keys, media keys (system-defined), mouse, gestures
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let mode = Unmanaged<CleaningMode>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = mode.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown || type == .keyUp {
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                DispatchQueue.main.async { mode.handleKey(keyCode: code, down: type == .keyDown) }
            }
            return nil   // swallow
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Opens the Accessibility pane (with the system prompt) so media keys can be blocked too.
    static func requestMediaKeyBlocking() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Fills smoothly (redrawn every display frame) while Esc is held; drains with an ease when released.
private struct EscHoldRing: View {
    let pressedAt: Date?

    var body: some View {
        TimelineView(.animation(paused: pressedAt == nil)) { ctx in
            let progress = pressedAt.map { min(1, ctx.date.timeIntervalSince($0) / CleaningMode.escHoldSeconds) } ?? 0
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: easeInOut(progress))
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .scaleEffect(pressedAt == nil ? 1 : 1.15)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: pressedAt == nil)
        }
    }

    /// Gentle start and finish, so the fill doesn't look mechanical.
    private func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

/// Swallows every key and mouse event that reaches it (the no-permission path).
private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown: CleaningMode.shared.handleKey(keyCode: Int(event.keyCode), down: true)
        case .keyUp: CleaningMode.shared.handleKey(keyCode: Int(event.keyCode), down: false)
        default: break
        }
        // Nothing is forwarded: no clicks, no shortcuts, no beeps.
    }
}

private struct CleaningOverlay: View {
    @ObservedObject var mode: CleaningMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let remaining = max(0, mode.endDate.timeIntervalSince(ctx.date))
            VStack(spacing: 18) {
                Image(systemName: "bubbles.and.sparkles")
                    .font(.system(size: 44, weight: .light))
                Text("Режим чистки")
                    .font(.system(size: 22, weight: .semibold))
                Text("\(Int(remaining.rounded(.up))) с")
                    .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
                HStack(spacing: 10) {
                    EscHoldRing(pressedAt: mode.escPressedAt)
                        .frame(width: 18, height: 18)
                    Text("Удерживай Esc 2 секунды, чтобы выйти")
                }
                .font(.system(size: 14))
                if !mode.blocksMediaKeys {
                    Text("Клавиши яркости и громкости продолжают работать — чтобы блокировать и их, разреши NotchIsland в «Универсальном доступе»")
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .opacity(0.7)
                }
            }
            // Dim grey on black: readable, but the screen stays dark enough to spot smudges.
            .foregroundStyle(.white.opacity(0.32))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }
}
