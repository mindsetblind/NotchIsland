import CoreGraphics

/// What we need to know about a display to decide where the island lives.
public struct ScreenInfo: Equatable, Sendable {
    public var id: UInt32                 // CGDirectDisplayID
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// Height of the camera housing (safeAreaInsets.top); 0 on displays without a notch.
    public var safeTop: CGFloat
    /// Widths of the menu bar areas left/right of the notch (auxiliaryTopLeft/RightArea).
    public var auxLeftWidth: CGFloat?
    public var auxRightWidth: CGFloat?
    /// The MacBook's own panel (CGDisplayIsBuiltin), notch or not.
    public var isBuiltIn: Bool

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat = 0,
                auxLeftWidth: CGFloat? = nil, auxRightWidth: CGFloat? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTop = safeTop
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
    }

    public var hasNotch: Bool { safeTop > 0 && auxLeftWidth != nil && auxRightWidth != nil }
}

/// Which display the island lives on (Settings → Основные → Остров).
public enum IslandScreenChoice: String, CaseIterable, Sendable {
    /// An external monitor when one is connected (the primary one if it's external), else the MacBook.
    case external
    /// The primary display — the one with the menu bar in the Displays settings.
    case primary
    /// The built-in display with the notch (falls back to the primary one with the lid closed).
    case notch
    /// Whichever display the mouse pointer is on.
    case mouse
}

public enum ScreenPlacement {
    /// The display the island belongs on for `choice`. `screens` is in `NSScreen.screens` order, so the
    /// first one is the primary display.
    ///
    /// Deliberately not `NSScreen.main`: that is the screen with the key window and changes whenever
    /// focus moves to another display, which used to make hit-testing disagree with where the panel was.
    public static func pick(_ screens: [ScreenInfo], choice: IslandScreenChoice = .notch,
                            mouse: CGPoint? = nil) -> ScreenInfo? {
        guard let primary = screens.first else { return nil }
        switch choice {
        case .external:
            if !primary.isBuiltIn { return primary }
            return screens.first(where: { !$0.isBuiltIn }) ?? primary
        case .primary:
            return primary
        case .notch:
            return screens.first(where: \.hasNotch) ?? primary
        case .mouse:
            guard let mouse else { return primary }
            return screens.first(where: { contains($0.frame, mouse) }) ?? primary
        }
    }

    /// Like `CGRect.contains`, but the top edge counts too: the pointer pinned against the top of a
    /// display reports y == frame.maxY.
    public static func contains(_ frame: CGRect, _ p: CGPoint) -> Bool {
        p.x >= frame.minX && p.x < frame.maxX && p.y >= frame.minY && p.y <= frame.maxY
    }

    /// Size of the physical notch, or of the pill drawn under the menu bar on displays without one.
    public static func notchSize(of s: ScreenInfo) -> CGSize {
        if s.hasNotch, let l = s.auxLeftWidth, let r = s.auxRightWidth {
            return CGSize(width: max(0, s.frame.width - l - r), height: s.safeTop)
        }
        // No notch (external display, or the lid is closed): a small pill as tall as the menu bar.
        // With an auto-hiding menu bar visibleFrame reaches the top, so fall back to the usual 24pt.
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        return CGSize(width: 190, height: max(24, min(menuBar, 44)))
    }

    /// Frame of the (transparent) panel: centered at the top of the screen.
    public static func panelFrame(canvas: CGSize, on s: ScreenInfo) -> CGRect {
        CGRect(x: (s.frame.midX - canvas.width / 2).rounded(),
               y: s.frame.maxY - canvas.height,
               width: canvas.width, height: canvas.height)
    }

    /// Hit area of an island of `size` (in screen coordinates), grown by `padding`.
    public static func islandRect(size: CGSize, padding: CGFloat, on s: ScreenInfo, shift: CGFloat = 0) -> CGRect {
        CGRect(x: s.frame.midX + shift - size.width / 2 - padding,
               y: s.frame.maxY - size.height - padding,
               width: size.width + padding * 2,
               height: size.height + padding + 1)
    }
}
