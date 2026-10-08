import ServiceManagement

/// "Open at Login" via the modern ServiceManagement API (shows up in System Settings → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NotchIsland: login item change failed: \(error)")
        }
    }
}
