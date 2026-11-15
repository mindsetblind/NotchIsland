import AppKit
import Combine
import SwiftUI

// The pet as a desktop widget: a small card that lives on the wallpaper (above the desktop icons,
// under every app window). Same live pet as by the notch, plus the time and what it's up to.
// Drag it anywhere; right-click for the menu. Settings → Пет → «Виджет на рабочем столе».

final class DeskWidgetPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Just above the desktop icons: part of the desktop, never over an app.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The whole card is one handle: drag moves the window, double-click pokes the pet, right-click
/// opens the menu. (The SceneKit view inside would otherwise swallow the mouse.)
private final class DeskWidgetHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
}

@MainActor
final class DeskWidgetState: ObservableObject {
    /// False while other windows cover the widget: nothing to render then.
    @Published var visible = true
}

@MainActor
final class DeskWidgetController: NSObject, NSWindowDelegate {
    static let shared = DeskWidgetController()

    static let size = CGSize(width: 176, height: 196)
    private static let margin: CGFloat = 28
    private static let originKey = "deskWidgetOrigin"

    private var panel: DeskWidgetPanel?
    private weak var model: IslandModel?
    private let state = DeskWidgetState()
    private var settingObserver: AnyCancellable?
    /// Programmatic moves (placing, pulling back on screen) aren't the user's choice of a spot.
    private var placing = false

    func start(model: IslandModel) {
        self.model = model
        settingObserver = AppSettings.shared.$deskWidget.sink { [weak self] on in
            MainActor.assumeIsolated { on ? self?.show() : self?.hide() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func show() {
        guard let model else { return }
        if panel == nil {
            let panel = DeskWidgetPanel(size: Self.size)
            let host = DeskWidgetHostingView(rootView: DeskWidgetView(model: model, state: state))
            host.frame = NSRect(origin: .zero, size: Self.size)
            host.onDoubleClick = { [weak model] in model?.cheer() }
            host.makeMenu = { [weak self] in self?.menu() ?? NSMenu() }
            panel.contentView = host
            panel.delegate = self
            self.panel = panel
        }
        place()
        panel?.orderFrontRegardless()
        state.visible = true
    }

    private func hide() {
        panel?.orderOut(nil)
        state.visible = false
    }

    // MARK: Position

    /// The saved spot if it's still on a display, else the bottom right corner of the main one.
    private func place(reset: Bool = false) {
        guard let panel else { return }
        var origin = Self.defaultOrigin()
        if !reset, let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            if Self.isOnScreen(NSRect(origin: p, size: Self.size)) { origin = p }
        }
        placing = true
        panel.setFrameOrigin(origin)
        placing = false
    }

    private static func defaultOrigin() -> NSPoint {
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        return NSPoint(x: area.maxX - size.width - margin, y: area.minY + margin)
    }

    /// Enough of the card is on some display to grab it.
    private static func isOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let part = screen.visibleFrame.intersection(rect)
            return part.width >= 60 && part.height >= 60
        }
    }

    @objc private func screensChanged() {
        guard let panel, panel.isVisible else { return }
        // A display went away under the widget: come back to a visible spot (the saved one stays
        // for when the display returns).
        if !Self.isOnScreen(panel.frame) { place() }
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing, let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let panel else { return }
        let visible = panel.isVisible && panel.occlusionState.contains(.visible)
        if state.visible != visible { state.visible = visible }
    }

    // MARK: Menu

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Вернуть в угол", #selector(resetPosition)),
                                ("Настройки…", #selector(openSettings)),
                                ("Скрыть виджет", #selector(turnOff))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        place(reset: true)
    }

    @objc private func openSettings() { model?.openSettings() }
    @objc private func turnOff() { AppSettings.shared.deskWidget = false }
}

// MARK: - View

struct DeskWidgetView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var state: DeskWidgetState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                // Covered by other windows → no SceneKit view, no frames rendered.
                if state.visible {
                    PetView(mood: model.petMood, size: 62, accessories: model.petAccessories,
                            extras: PetExtras(agents: model.petAgents))
                } else {
                    Color.clear
                }
            }
            .frame(width: 100, height: 82)
            .padding(.top, 18)

            Spacer(minLength: 0)

            // Every second only while a pomodoro counts down; otherwise the clock needs a minute's precision.
            TimelineView(.periodic(from: .now, by: model.pomodoro.isRunning ? 1 : 15)) { ctx in
                VStack(spacing: 3) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.95))
                    Text(Self.status(model, at: ctx.date))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: model.petMood)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .frame(width: DeskWidgetController.size.width, height: DeskWidgetController.size.height)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.black.opacity(0.8))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
        )
    }

    /// One short line about what the pet is doing right now.
    static func status(_ model: IslandModel, at date: Date) -> String {
        switch model.petMood {
        case .listening: return "Слушает"
        case .thinking: return "Думает"
        case .presenting: return "Есть план"
        case .hungry, .gaping: return "Ждёт файл"
        case .munching: return "Ням"
        case .attention: return "Claude ждёт ответа"
        case .working:
            let n = model.petAgents
            return n > 1 ? "Claude работает · \(n)" : "Claude работает"
        case .happy: return "Доволен"
        case .dancing:
            guard let track = model.nowPlaying, !track.title.isEmpty else { return "Слушает музыку" }
            return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        case .full: return pomodoro(model, at: date) ?? "Файлы на полке"
        case .sleeping: return "Спит"
        case .scared: return "Батарея садится"
        case .sad, .failed: return "Грустит"
        case .waking: return "Просыпается"
        case .idle: return pomodoro(model, at: date) ?? "На связи"
        }
    }

    private static func pomodoro(_ model: IslandModel, at date: Date) -> String? {
        let p = model.pomodoro
        guard p.isRunning else { return nil }
        return "\(p.phase.title) · \(formatTimer(p.remaining(at: date)))"
    }
}
