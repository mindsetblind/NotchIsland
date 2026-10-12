import AppKit

/// Adds/removes NotchIsland's entries in ~/.claude/settings.json — only when the user clicks the
/// button in Settings, after showing exactly what will change and making a backup.
enum ClaudeHooks {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The helper inside the installed app bundle.
    static var hookCommand: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notchisland-hook").path
        return "'\(path)'"
    }

    private static let marker = "notchisland-hook"

    /// Event → (needs a tool matcher, timeout in seconds). PermissionRequest waits for your click.
    private static let events: [(String, Bool, Int)] = [
        ("SessionStart", false, 10),
        ("UserPromptSubmit", false, 10),
        ("PreToolUse", true, 10),
        ("PostToolUse", true, 10),
        ("PermissionRequest", true, 3600),
        ("Notification", false, 10),
        ("Stop", false, 10),
        ("SessionEnd", false, 10),
    ]

    static var isInstalled: Bool {
        guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
        }
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return json
    }

    /// Settings with our hook entries removed (everything else untouched).
    private static func withoutOurs(_ settings: [String: Any]) -> [String: Any] {
        var s = settings
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        for (event, value) in hooks {
            var groups = value as? [[String: Any]] ?? []
            groups = groups.compactMap { group in
                var g = group
                let handlers = (g["hooks"] as? [[String: Any]] ?? []).filter { ($0["command"] as? String)?.contains(marker) != true }
                if handlers.isEmpty { return nil }
                g["hooks"] = handlers
                return g
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        return s
    }

    private static func withOurs(_ settings: [String: Any]) -> [String: Any] {
        var s = withoutOurs(settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        for (event, matcher, timeout) in events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": hookCommand, "timeout": timeout]]]
            if matcher { group["matcher"] = "*" }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        s["hooks"] = hooks
        return s
    }

    // MARK: UI flows

    static func install() {
        let preview = events.map { "  \($0.0)" + ($0.1 ? " (все инструменты)" : "") }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Подключить Claude Code к острову?"
        alert.informativeText = """
        В \(settingsURL.path) будут добавлены хуки — Claude Code станет сообщать острову о своих действиях и спрашивать разрешения через него:

        \(preview)

        Команда: \(hookCommand)

        Перед записью будет сделана резервная копия. Остальные настройки не меняются (JSON будет переформатирован). Если остров не запущен, Claude Code работает как обычно.
        """
        alert.addButton(withTitle: "Подключить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write(withOurs(readSettings()))
    }

    static func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Отключить Claude Code от острова?"
        alert.informativeText = "Хуки NotchIsland будут удалены из \(settingsURL.path). Перед записью будет сделана резервная копия."
        alert.addButton(withTitle: "Отключить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write(withoutOurs(readSettings()))
    }

    private static func write(_ settings: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.notchisland-backup-\(stamp)")
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return
        }
        do {
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
