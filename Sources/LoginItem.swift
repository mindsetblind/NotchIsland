import ServiceManagement

/// "Open at Login" via the modern ServiceManagement API (shows up in System Settings → Login Items).
enum LoginItem {
    private static let choiceKey = "loginItemUserChoice"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Called from the context-menu toggle; remembers that the user decided explicitly.
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: choiceKey)
        apply(enabled)
    }

    /// On launch: start at login by default, unless the user turned it off.
    /// Re-registering also repairs a registration made by an older build with a different signature.
    static func applyOnLaunch() {
        let wanted = UserDefaults.standard.object(forKey: choiceKey) as? Bool ?? true
        if wanted && SMAppService.mainApp.status != .enabled { apply(true) }
        debugLog("login item: wanted=\(wanted) status=\(describe(SMAppService.mainApp.status))")
    }

    private static func apply(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            debugLog("login item change failed: \(error)")
        }
    }

    private static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
