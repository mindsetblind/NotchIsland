import AppKit
import ApplicationServices

/// Watches the active app's menu bar: when its menus run under the island's ears (Xcode, Photoshop,
/// IDEs…), the island gives the menu bar back and shrinks to the notch until you switch to an app
/// with a shorter menu. Reads only the positions of the menu titles (Accessibility permission);
/// without it, a short list of apps known for long menus is used instead.
@MainActor
final class MenuBarWatcher {
    static let shared = MenuBarWatcher()

    /// Apps whose menus reach the notch on a 14" MacBook — used only without Accessibility access.
    static let knownLongMenus: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.FinalCut", "com.apple.logic10", "com.apple.motionapp",
        "com.adobe.Photoshop", "com.adobe.illustrator", "com.adobe.AfterEffects", "com.adobe.PremierePro",
        "com.figma.Desktop", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.goland", "com.jetbrains.WebStorm", "com.google.android.studio",
        "com.image-line.flstudio", "com.blackmagic-design.DaVinciResolve", "org.blenderfoundation.blender",
        "com.parallels.desktop.console", "com.wondershare.filmoramacos",
    ]

    /// Island geometry, from the app delegate: screen midX and notch width (AX and Cocoa share x).
    var geometry: () -> (midX: CGFloat, notchWidth: CGFloat)? = { nil }
    /// Free room in the menu bar left and right of the notch (points; .infinity = nothing there).
    struct Room: Equatable {
        var left: CGFloat = .infinity
        var right: CGFloat = .infinity
        static let none = Room(left: 0, right: 0)
    }
    var onChange: ((Room) -> Void)?

    private(set) var room = Room()
    private var timer: Timer?
    private var observer: Any?

    var hasAccess: Bool { AXIsProcessTrusted() }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Menus are rebuilt a moment after activation.
            MainActor.assumeIsolated {
                self?.check()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.check() }
            }
        }
        // Menus can also change inside an app (another window, a plug-in): a cheap look every few seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 1
        check()
    }

    func askForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func check() {
        guard AppSettings.shared.freeMenuBar, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return set(Room()) }
        if hasAccess, let geometry = geometry() {
            set(Self.room(pid: app.processIdentifier, midX: geometry.midX, notchWidth: geometry.notchWidth) ?? Room())
        } else {
            set(Self.knownLongMenus.contains(app.bundleIdentifier ?? "") ? .none : Room())
        }
    }

    private func set(_ value: Room) {
        guard value != room else { return }
        room = value
        func f(_ v: CGFloat) -> String { v.isInfinite ? "∞" : "\(Int(v))" }
        debugLog("menu bar: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") room left \(f(value.left)) right \(f(value.right))\(hasAccess ? "" : " (no AX, list)")")
        onChange?(value)
    }

    /// Distance from each edge of the notch to the nearest menu title of the app.
    static func room(pid: pid_t, midX: CGFloat, notchWidth: CGFloat) -> Room? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let bar = menuBar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        let notchLeft = midX - notchWidth / 2, notchRight = midX + notchWidth / 2
        var room = Room()
        for item in items {
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            guard s.width > 0 else { continue }
            let right = p.x + s.width
            if right <= notchLeft { room.left = min(room.left, notchLeft - right) }
            else if p.x >= notchRight { room.right = min(room.right, p.x - notchRight) }
            else { return .none }   // a title under the notch itself
        }
        return room
    }
}
