import AppKit
import Carbon.HIToolbox

/// ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z / ⇧⌘Z in our text fields. NotchIsland has no menu bar (it's an accessory
/// app), and these shortcuts normally reach text fields through the Edit menu — so the panels with a
/// text field forward them to the first responder themselves. Matched by physical key, so they also
/// work on the Russian layout (⌘Ф = ⌘A).
enum EditShortcuts {
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector?
        switch (Int(event.keyCode), flags) {
        case (kVK_ANSI_A, .command): action = #selector(NSText.selectAll(_:))
        case (kVK_ANSI_C, .command): action = #selector(NSText.copy(_:))
        case (kVK_ANSI_V, .command): action = #selector(NSText.paste(_:))
        case (kVK_ANSI_X, .command): action = #selector(NSText.cut(_:))
        case (kVK_ANSI_Z, .command): action = Selector(("undo:"))
        case (kVK_ANSI_Z, [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}
