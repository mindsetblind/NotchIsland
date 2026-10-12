import AppKit
import SwiftUI

// MARK: - Model

struct ClaudeSession: Identifiable, Equatable {
    enum Status: Equatable { case idle, working, waiting, done }

    let id: String                 // Claude Code session_id
    var cwd: String
    var status: Status = .idle
    var activity: String = ""
    var updatedAt = Date()
    var appPID: pid_t?             // terminal / app hosting the session, for "jump to"

    var project: String { (cwd as NSString).lastPathComponent }
}

struct PermissionAsk: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let project: String
    let toolName: String
    let title: String              // "Запустить команду", "Изменить файл"…
    let detail: String             // the command / file path
    let suggestions: [Any]         // permission_suggestions, echoed back for "Always"
    let connection: Int32          // socket to answer on

    static func == (a: PermissionAsk, b: PermissionAsk) -> Bool { a.id == b.id }
}

struct AgentPeek: Equatable {
    let project: String
    let text: String
    let mood: MascotMood
}

/// Live state of Claude Code sessions, fed by `notchisland-hook` through a Unix socket.
final class ClaudeMonitor: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var permissions: [PermissionAsk] = []
    @Published private(set) var peek: AgentPeek?

    private var server: HookSocketServer?
    private var peekWork: DispatchWorkItem?
    private var sweeper: Timer?

    var isAnyWorking: Bool { sessions.contains { $0.status == .working } }
    var isAnyWaiting: Bool { !permissions.isEmpty || sessions.contains { $0.status == .waiting } }

    /// The face to show for the agents overall.
    var mood: MascotMood {
        if isAnyWaiting { return .attention }
        if isAnyWorking { return .working }
        if sessions.contains(where: { $0.status == .done }) { return .happy }
        return .idle
    }

    /// Snapshot mode only: sample sessions and a pending permission.
    func fillForSnapshots() {
        sessions = [
            ClaudeSession(id: "a", cwd: "/Users/me/myMacUtilities/NotchIsland", status: .working,
                          activity: "Правит Views.swift  +12 −3", updatedAt: Date().addingTimeInterval(-20)),
            ClaudeSession(id: "b", cwd: "/Users/me/UNI/Java practice", status: .waiting,
                          activity: "Ждёт твоего ответа", updatedAt: Date().addingTimeInterval(-95)),
            ClaudeSession(id: "c", cwd: "/Users/me/Fit_app", status: .done,
                          activity: "Готово", updatedAt: Date().addingTimeInterval(-600)),
        ]
        permissions = [PermissionAsk(sessionID: "a", project: "NotchIsland", toolName: "Bash", title: "Запустить команду",
                                     detail: "swift build -c release && ./build.sh --install",
                                     suggestions: [["type": "addRules"]], connection: -1)]
        peek = AgentPeek(project: "NotchIsland", text: "готово", mood: .happy)
    }

    func start() {
        server = HookSocketServer { [weak self] event, fd in
            DispatchQueue.main.async { self?.handle(event, connection: fd) }
        }
        server?.start()
        // Forget sessions nobody has heard from in a while (closed terminals don't always say goodbye).
        sweeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-30 * 60)
            withAnimation(IslandModel.spring) {
                self.sessions.removeAll { $0.updatedAt < cutoff && $0.status != .waiting }
                for i in self.sessions.indices where self.sessions[i].status == .done
                    && self.sessions[i].updatedAt < Date().addingTimeInterval(-5 * 60) {
                    self.sessions[i].status = .idle
                }
            }
        }
    }

    // MARK: Events

    private func handle(_ e: [String: Any], connection fd: Int32) {
        guard let name = e["hook_event_name"] as? String, let sid = e["session_id"] as? String else {
            close(fd); return
        }
        let cwd = e["cwd"] as? String ?? ""
        let pid = Self.hostApp(from: e["ancestor_pids"] as? [Int])
        var s = sessions.first { $0.id == sid } ?? ClaudeSession(id: sid, cwd: cwd)
        s.cwd = cwd.isEmpty ? s.cwd : cwd
        s.appPID = pid ?? s.appPID
        s.updatedAt = Date()

        if name != "PermissionRequest" { close(fd) }
        debugLog("claude: \(name) session=\(sid.prefix(8)) tool=\(e["tool_name"] as? String ?? "-")")

        switch name {
        case "SessionStart":
            s.status = .idle
            s.activity = "Сессия началась"
        case "UserPromptSubmit":
            s.status = .working
            s.activity = "Думает…"
        case "PreToolUse":
            s.status = .working
            s.activity = Self.describe(tool: e["tool_name"] as? String, input: e["tool_input"] as? [String: Any])
        case "PostToolUse":
            if let diff = Self.diffStat(tool: e["tool_name"] as? String, input: e["tool_input"] as? [String: Any]) {
                s.activity = Self.describe(tool: e["tool_name"] as? String, input: e["tool_input"] as? [String: Any]) + "  " + diff
            }
        case "PermissionRequest":
            guard AppSettings.shared.claudePermissionsInIsland else { close(fd); break }   // terminal asks as usual
            s.status = .waiting
            let tool = e["tool_name"] as? String ?? "Инструмент"
            let (title, detail) = Self.permissionText(tool: tool, input: e["tool_input"] as? [String: Any])
            let ask = PermissionAsk(sessionID: sid, project: s.project, toolName: tool, title: title, detail: detail,
                                    suggestions: e["permission_suggestions"] as? [Any] ?? [], connection: fd)
            withAnimation(IslandModel.open) { permissions.append(ask) }
            watchHangup(ask)
            if AppSettings.shared.claudeSounds { NSSound(named: "Tink")?.play() }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        case "Notification":
            let type = e["notification_type"] as? String ?? ""
            if ["idle_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"].contains(type) {
                s.status = .waiting
                s.activity = "Ждёт твоего ответа"
                showPeek(AgentPeek(project: s.project, text: "ждёт ответа", mood: .attention))
            }
        case "Stop":
            s.status = .done
            s.activity = "Готово"
            showPeek(AgentPeek(project: s.project, text: "готово", mood: .happy))
            if AppSettings.shared.claudeSounds { NSSound(named: "Glass")?.play() }
        case "SessionEnd":
            withAnimation(IslandModel.spring) { sessions.removeAll { $0.id == sid } }
            return
        default:
            break
        }
        upsert(s)
    }

    private func upsert(_ s: ClaudeSession) {
        withAnimation(IslandModel.spring) {
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        }
    }

    private func showPeek(_ p: AgentPeek) {
        peekWork?.cancel()
        withAnimation(IslandModel.spring) { peek = p }
        let work = DispatchWorkItem { [weak self] in withAnimation(IslandModel.spring) { self?.peek = nil } }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// Claude Code may give up on the request (Esc in the terminal, timeout): the hook process dies,
    /// its socket hits EOF, and the card must go away by itself.
    private var hangupWatchers: [UUID: DispatchSourceRead] = [:]

    private func watchHangup(_ ask: PermissionAsk) {
        let source = DispatchSource.makeReadSource(fileDescriptor: ask.connection, queue: .main)
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            if recv(ask.connection, &byte, 1, MSG_PEEK) <= 0 { self?.dropPermission(ask) }
        }
        hangupWatchers[ask.id] = source
        source.resume()
    }

    private func dropPermission(_ ask: PermissionAsk) {
        guard permissions.contains(ask) else { return }
        hangupWatchers.removeValue(forKey: ask.id)?.cancel()
        close(ask.connection)
        debugLog("claude: permission request withdrawn by Claude Code")
        withAnimation(IslandModel.close) {
            permissions.removeAll { $0.id == ask.id }
            if let i = sessions.firstIndex(where: { $0.id == ask.sessionID }) {
                sessions[i].status = .working
                sessions[i].activity = "Запрос отменён"
            }
        }
    }

    // MARK: Answers

    enum Answer { case allow, always, deny, terminal }

    func answer(_ ask: PermissionAsk, _ answer: Answer) {
        guard permissions.contains(ask) else { return }
        hangupWatchers.removeValue(forKey: ask.id)?.cancel()
        var decision: [String: Any]?
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .always:
            // Echo Claude Code's own suggestion ("always allow this kind of call") as the permission update.
            decision = ["behavior": "allow"]
            if !ask.suggestions.isEmpty { decision?["updatedPermissions"] = ask.suggestions }
        case .deny:
            decision = ["behavior": "deny", "message": "Отклонено в NotchIsland"]
        case .terminal:
            decision = nil   // close without an answer → Claude Code asks in the terminal as usual
        }
        if let decision,
           var data = try? JSONSerialization.data(withJSONObject: [
               "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
           ]) {
            data.append(0x0A)
            _ = data.withUnsafeBytes { write(ask.connection, $0.baseAddress, data.count) }
        }
        close(ask.connection)

        withAnimation(IslandModel.close) {
            permissions.removeAll { $0.id == ask.id }
            if let i = sessions.firstIndex(where: { $0.id == ask.sessionID }) {
                sessions[i].status = answer == .deny ? .idle : .working
                sessions[i].activity = answer == .deny ? "Действие отклонено" : (answer == .terminal ? "Ответ в терминале" : "Продолжает работу")
                sessions[i].updatedAt = Date()
            }
        }
    }

    func jump(to session: ClaudeSession) {
        guard let pid = session.appPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    // MARK: Text helpers

    /// First ancestor that is a regular GUI app (Terminal, iTerm, VS Code, Claude…).
    private static func hostApp(from pids: [Int]?) -> pid_t? {
        for pid in pids ?? [] {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy == .regular {
                return app.processIdentifier
            }
        }
        return nil
    }

    private static func file(_ input: [String: Any]?) -> String {
        let path = input?["file_path"] as? String ?? input?["path"] as? String ?? input?["notebook_path"] as? String ?? ""
        return (path as NSString).lastPathComponent
    }

    static func describe(tool: String?, input: [String: Any]?) -> String {
        switch tool ?? "" {
        case "Read": return "Читает \(file(input))"
        case "Edit", "MultiEdit": return "Правит \(file(input))"
        case "Write": return "Пишет \(file(input))"
        case "NotebookEdit": return "Правит \(file(input))"
        case "Bash":
            let cmd = (input?["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? input?["command"] as? String ?? ""
            return "Запускает: \(cmd)"
        case "Grep", "Glob": return "Ищет \(input?["pattern"] as? String ?? "")"
        case "WebFetch", "WebSearch": return "Ищет в интернете"
        case "Task", "Agent": return "Запустил помощника"
        case "TodoWrite": return "Обновляет план"
        case let other where other.hasPrefix("mcp__"): return "Вызывает \(other.split(separator: "_").last.map(String.init) ?? other)"
        case let other: return other.isEmpty ? "Работает" : other
        }
    }

    static func permissionText(tool: String, input: [String: Any]?) -> (String, String) {
        switch tool {
        case "Bash": return ("Запустить команду", input?["command"] as? String ?? "")
        case "Edit", "MultiEdit", "NotebookEdit": return ("Изменить файл", input?["file_path"] as? String ?? file(input))
        case "Write": return ("Создать файл", input?["file_path"] as? String ?? file(input))
        case "Read": return ("Прочитать файл", input?["file_path"] as? String ?? file(input))
        case "WebFetch": return ("Открыть страницу", input?["url"] as? String ?? "")
        case "WebSearch": return ("Искать в интернете", input?["query"] as? String ?? "")
        default:
            let compact = input.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ("Использовать \(tool)", String(compact.prefix(200)))
        }
    }

    /// "+12 −3" for edits, from the old/new strings Claude Code sends.
    static func diffStat(tool: String?, input: [String: Any]?) -> String? {
        func lines(_ s: String?) -> Int { s.map { $0.isEmpty ? 0 : $0.components(separatedBy: "\n").count } ?? 0 }
        switch tool ?? "" {
        case "Edit":
            return "+\(lines(input?["new_string"] as? String)) −\(lines(input?["old_string"] as? String))"
        case "MultiEdit":
            let edits = input?["edits"] as? [[String: Any]] ?? []
            let added = edits.reduce(0) { $0 + lines($1["new_string"] as? String) }
            let removed = edits.reduce(0) { $0 + lines($1["old_string"] as? String) }
            return "+\(added) −\(removed)"
        case "Write":
            return "+\(lines(input?["content"] as? String))"
        default:
            return nil
        }
    }
}

// MARK: - Socket server

/// Accepts one JSON line per connection from `notchisland-hook`. Permission requests keep their
/// connection open until answered; everything else is closed right away by the monitor.
final class HookSocketServer {
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchIsland/claude.sock").path
    }

    private let onEvent: ([String: Any], Int32) -> Void
    private let queue = DispatchQueue(label: "notchisland.hooks", attributes: .concurrent)
    private var listenFD: Int32 = -1

    init(onEvent: @escaping ([String: Any], Int32) -> Void) { self.onEvent = onEvent }

    func start() {
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else { return }
        chmod(path, 0o600)   // only this user can talk to the island

        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR { continue } else { return } }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [weak self] in self?.readEvent(fd) }
        }
    }

    private func readEvent(_ fd: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while data.count < 4_000_000 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { close(fd); return }
        onEvent(event, fd)
    }
}
