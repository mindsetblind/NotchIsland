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

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat = 0,
                auxLeftWidth: CGFloat? = nil, auxRightWidth: CGFloat? = nil) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTop = safeTop
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
    }

    public var hasNotch: Bool { safeTop > 0 && auxLeftWidth != nil && auxRightWidth != nil }
}

public enum ScreenPlacement {
    /// The display the island belongs on: the built-in display with a notch if there is one, otherwise
    /// the primary display (the first in the list — the one with the menu bar in the Displays settings).
    ///
    /// Deliberately not `NSScreen.main`: that is the screen with the key window and changes whenever
    /// focus moves to another display, which used to make hit-testing disagree with where the panel was.
    public static func pick(_ screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first(where: \.hasNotch) ?? screens.first
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
    public static func islandRect(size: CGSize, padding: CGFloat, on s: ScreenInfo) -> CGRect {
        CGRect(x: s.frame.midX - size.width / 2 - padding,
               y: s.frame.maxY - size.height - padding,
               width: size.width + padding * 2,
               height: size.height + padding + 1)
    }
}
