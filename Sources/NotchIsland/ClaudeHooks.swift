import AppKit

/// Coding agents the island can follow through their hooks. Both use the same hook format
/// (Claude Code's `settings.json` → `hooks`, Codex's `~/.codex/hooks.json` → `hooks`).
enum CodingAgent: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The value `notchisland-hook --source …` puts into the event's `agent` field.
    init(eventValue: String?) { self = eventValue == "codex" ? .codex : .claude }
}

/// Adds/removes NotchIsland's entries in the agent's hook file — only when the user clicks the
/// button in Settings, after showing exactly what will change and making a backup.
enum AgentHooks {
    static func settingsURL(_ agent: CodingAgent) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    /// The helper inside the installed app bundle.
    static func hookCommand(_ agent: CodingAgent) -> String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notchisland-hook").path
        return agent == .codex ? "'\(path)' --source codex" : "'\(path)'"
    }

    private static let marker = "notchisland-hook"

    /// Event → (needs a tool matcher, timeout in seconds). PermissionRequest waits for your click.
    private static func events(_ agent: CodingAgent) -> [(String, Bool, Int)] {
        switch agent {
        case .claude:
            return [
                ("SessionStart", false, 10),
                ("UserPromptSubmit", false, 10),
                ("PreToolUse", true, 10),
                ("PostToolUse", true, 10),
                ("PermissionRequest", true, 3600),
                ("Notification", false, 10),
                ("Stop", false, 10),
                ("SessionEnd", false, 10),
            ]
        case .codex:
            // Codex has no Notification event; its matchers are regexes, so "no matcher" = every tool.
            return [
                ("SessionStart", false, 10),
                ("UserPromptSubmit", false, 10),
                ("PreToolUse", false, 10),
                ("PostToolUse", false, 10),
                ("PermissionRequest", false, 3600),
                ("Stop", false, 10),
                ("SessionEnd", false, 10),
            ]
        }
    }

    static var anyInstalled: Bool { CodingAgent.allCases.contains { isInstalled($0) } }

    static func isInstalled(_ agent: CodingAgent) -> Bool {
        guard let hooks = readSettings(agent)["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
        }
    }

    private static func readSettings(_ agent: CodingAgent) -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL(agent)),
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

    private static func withOurs(_ settings: [String: Any], _ agent: CodingAgent) -> [String: Any] {
        var s = withoutOurs(settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        for (event, matcher, timeout) in events(agent) {
            var group: [String: Any] = ["hooks": [["type": "command", "command": hookCommand(agent), "timeout": timeout]]]
            if matcher { group["matcher"] = "*" }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        s["hooks"] = hooks
        return s
    }

    // MARK: UI flows

    static func install(_ agent: CodingAgent) {
        let preview = events(agent).map { "  \($0.0)" }.joined(separator: "\n")
        let url = settingsURL(agent)
        let alert = NSAlert()
        alert.messageText = "Подключить \(agent.name) к острову?"
        var text = """
        В \(url.path) будут добавлены хуки — \(agent.name) станет сообщать острову о своих действиях и спрашивать разрешения через него:

        \(preview)

        Команда: \(hookCommand(agent))

        Перед записью будет сделана резервная копия. Остальные настройки не меняются (JSON будет переформатирован). Если остров не запущен, \(agent.name) работает как обычно.
        """
        if agent == .codex {
            text += "\n\nCodex попросит один раз доверить новые хуки — согласись в нём, иначе он их не запустит."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Подключить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write(withOurs(readSettings(agent), agent), to: url)
    }

    static func uninstall(_ agent: CodingAgent) {
        let url = settingsURL(agent)
        let alert = NSAlert()
        alert.messageText = "Отключить \(agent.name) от острова?"
        alert.informativeText = "Хуки NotchIsland будут удалены из \(url.path). Перед записью будет сделана резервная копия."
        alert.addButton(withTitle: "Отключить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write(withoutOurs(readSettings(agent)), to: url)
    }

    private static func write(_ settings: [String: Any], to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).notchisland-backup-\(stamp)")
            try? fm.copyItem(at: url, to: backup)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
