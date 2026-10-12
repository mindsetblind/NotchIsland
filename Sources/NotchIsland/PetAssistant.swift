import AppKit
import NotchIslandCore

/// What the pet knows about the moment it was called: the Finder folder, the selection, dropped files.
struct PetContext {
    var folder: URL?
    var files: [URL] = []
    /// "@" tag: play from this playlist / album / Liked Songs.
    var music: PetMusicSource?
    /// Its tracks ("Name — Artist"), when the request asks to pick something from it.
    var musicTracks: [String] = []
}

/// Something in your Spotify library the pet can be pointed at with "@".
struct PetMusicSource: Identifiable, Equatable {
    enum Kind { case liked, playlist, album }
    let uri: String
    let name: String
    let kind: Kind
    let subtitle: String
    var id: String { uri }

    var icon: String {
        switch kind {
        case .liked: return "heart.fill"
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        }
    }
}

/// Spotify hooks the island model provides.
struct PetMusicPlayer {
    /// Search Spotify and play the best match; returns "Title — Artist".
    var search: (PetMusic) async throws -> String
    var sources: () async -> [PetMusicSource]
    var tracks: (PetMusicSource) async throws -> [PlaylistTrack]
    /// Play a tag, or one of its tracks inside it.
    var play: (PetMusicSource, PlaylistTrack?) async throws -> String
    /// "включи <name>" without Claude: your library first, then Spotify search. nil = not found.
    var quickPlay: (String, PetMusic.Kind?) async throws -> String?
    /// Pause / resume / next / previous; returns what to show.
    var control: (PetQuickIntent.Media) -> String
}

/// The pet's "brain": turns a request into a plan. Swappable (Foundation Models once it speaks Russian).
protocol PetBrain: AnyObject, Sendable {
    func plan(_ request: String, context: PetContext) async throws -> PetPlan
    func cancel()
    /// Get ready while the user is still typing (optional).
    func prewarm()
    func release()
}

extension PetBrain {
    func prewarm() {}
    func release() {}
}

// MARK: - Claude Code

/// Runs the installed `claude -p` with read-only tools and a JSON schema. Claude only looks around
/// and proposes; NotchIsland checks the plan, shows it, and carries it out after you confirm.
final class ClaudeCodeBrain: PetBrain, @unchecked Sendable {   // state behind `lock`
    enum Failure: LocalizedError {
        case notInstalled, notLoggedIn, timedOut
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Не нашёл Claude Code. Установи его: claude.com/claude-code"
            case .notLoggedIn: return "Claude Code не авторизован"
            case .timedOut: return "Claude Code не ответил за 2 минуты"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    var model: () -> String = { "sonnet" }

    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// A Claude Code process started ahead of time (when the panel opens), waiting on stdin for the
    /// request: starting `claude` takes ~3 s, the answer itself ~1.5 s, so this makes requests ~3× faster.
    private struct Warm {
        let process: Process
        let input: Pipe
        let output: Pipe
        let model: String
    }
    private var spare: Warm?

    /// Starts a spare process unless one is already waiting (for the current model).
    func prewarm() {
        lock.withLock {
            if let spare, spare.process.isRunning, spare.model == model() { return }
            spare?.process.terminate()
            spare = try? spawn()
        }
    }

    /// Lets the spare go (the panel has been closed for a while).
    func release() {
        lock.withLock {
            spare?.process.terminate()
            spare = nil
        }
    }

    private func spawn() throws -> Warm {
        guard let exe = Self.executable else { throw Failure.notInstalled }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let p = Process()
        p.executableURL = exe
        p.currentDirectoryURL = home
        let model = model()
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose",
            "--json-schema", PetPlan.jsonSchema,
            "--model", model,
            "--tools", "Glob,Grep,Read",
            "--system-prompt", Self.systemPrompt(home: home.path),
            // Our own hooks would show the pet's helper run as a Claude Code session in the island.
            "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        return Warm(process: p, input: input, output: output, model: model)
    }

    func plan(_ request: String, context: PetContext) async throws -> PetPlan {
        // Take the spare if it's alive, otherwise start one now.
        let warm: Warm = try lock.withLock {
            let ready = spare.flatMap { $0.process.isRunning && $0.model == model() ? $0 : nil }
            spare = nil
            return try ready ?? spawn()
        }
        lock.withLock { process = warm.process }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": Self.prompt(request, context: context)]]
        let line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)

        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let p = warm.process
                    // Closing stdin after the request: Claude answers it and exits.
                    try? warm.input.fileHandleForWriting.write(contentsOf: line)
                    try? warm.input.fileHandleForWriting.close()
                    let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
                    let data = warm.output.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let timedOut = !watchdog.isCancelled && p.terminationReason == .uncaughtSignal
                    watchdog.cancel()
                    self?.lock.withLock { self?.process = nil }
                    // The answer is the last line, {"type":"result", …}; earlier lines are the conversation.
                    let result = data.split(separator: UInt8(ascii: "\n")).last { $0.contains(Array(#""type":"result""#.utf8)) }
                    if let result { cont.resume(returning: Data(result)) }
                    else if timedOut { cont.resume(throwing: Failure.timedOut) }
                    else { cont.resume(returning: data.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? data) }
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
        try Task.checkCancellation()
        do {
            return try PetPlan.parse(cliOutput: data)
        } catch PetPlan.ParseError.notLoggedIn {
            throw Failure.notLoggedIn
        } catch PetPlan.ParseError.failed(let message) {
            throw NSError(domain: "Pet", code: 1, userInfo: [NSLocalizedDescriptionKey: String(message.prefix(300))])
        }
    }

    func cancel() {
        lock.withLock { process }?.terminate()
    }

    static func systemPrompt(home: String) -> String {
        """
        Ты — pet, маленький помощник, который живёт в вырезе экрана MacBook. Помогаешь с файлами и включаешь музыку в Spotify.
        Домашняя папка пользователя: \(home). Работай только внутри неё; ~/Library и скрытые файлы (начинаются с точки) не трогай.

        Сам ты ничего не меняешь. Изучи файлы инструментами Glob, Grep и Read и верни план — его покажут пользователю, и он подтвердит.
        Правила плана:
        - Все пути абсолютные.
        - move, copy и zip: поле to — полный конечный путь вместе с именем файла. Переименование — это move в той же папке.
        - Если нужна новая папка, сначала mkdir.
        - Удаление — только trash (в Корзину) и только когда пользователь прямо просит удалить или почистить.
        - Ничего не перезаписывай: если имя занято, добавь « 2» перед расширением.
        - Если пользователь ищет файлы — положи их в files (не больше 20, самые подходящие первыми), actions оставь пустым. «Покажи» — reveal, «открой» — open.
        - Не больше 200 действий.
        Музыка: если пользователь просит что-то включить или поставить, заполни music и оставь actions пустым; файлы при этом не изучай.
        - Конкретная песня — type track, query «название исполнитель». Исполнитель — type artist, query — его имя как в Spotify. Альбом — album.
        - Настроение, жанр или занятие («что-нибудь спокойное», «для работы», «рок 80-х») — type playlist, query — 2–4 слова, лучше по-английски (например «chill acoustic», «deep focus», «80s rock»).
        - Имена исполнителей пиши как они пишутся в Spotify (латиницей, если исполнитель зарубежный).
        reply — одно-два коротких дружелюбных предложения по-русски, без markdown: что нашёл или что предлагаешь сделать.
        Если просьба непонятна или не про файлы — честно скажи это в reply и оставь actions пустым.
        """
    }

    static func prompt(_ request: String, context: PetContext) -> String {
        var lines = [request, ""]
        if let folder = context.folder { lines.append("Открытая папка в Finder: \(folder.path)") }
        if !context.files.isEmpty {
            lines.append("Выбранные файлы:")
            lines += context.files.prefix(100).map { "- \($0.path)" }
        }
        if let source = context.music, !context.musicTracks.isEmpty {
            lines.append("Пользователь выбрал в Spotify «\(source.name)». Выбери трек только из этого списка: заполни music с type track, а в query напиши номер трека из списка — только число.")
            lines += context.musicTracks.enumerated().map { "\($0 + 1). \($1)" }
        }
        lines.append("Сегодня: \(Date().formatted(date: .complete, time: .shortened))")
        return lines.joined(separator: "\n")
    }
}

struct PetMusicError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Finder context

enum FinderContext {
    /// Folder and selection of the frontmost Finder window. Only asks Finder when it is frontmost,
    /// so the pet never triggers an Automation prompt out of the blue.
    static func read() async -> PetContext {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return PetContext() }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let source = """
                tell application "Finder"
                    set out to ""
                    try
                        set out to POSIX path of (insertion location as alias)
                    end try
                    repeat with i in (get selection)
                        set out to out & linefeed & POSIX path of (i as alias)
                    end repeat
                    return out
                end tell
                """
                var error: NSDictionary?
                let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
                var lines = text.components(separatedBy: "\n")
                let folder = lines.isEmpty ? "" : lines.removeFirst()
                cont.resume(returning: PetContext(
                    folder: folder.isEmpty ? nil : URL(fileURLWithPath: folder),
                    files: lines.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }))
            }
        }
    }
}

// MARK: - Assistant state

@MainActor
final class PetAssistant: ObservableObject {
    static let shared = PetAssistant()

    enum Phase: Equatable {
        case input
        case thinking
        case plan(PetPlan, issues: [PetIssue])
        case done(String, canUndo: Bool)
        case playing(String)
        case failed(String)
        case notLoggedIn
    }

    @Published private(set) var phase: Phase = .input
    @Published private(set) var isOpen = false
    @Published var query = ""
    @Published var context = PetContext()
    /// The request the current plan answers (shown above it).
    @Published private(set) var asked = ""

    private let brain: PetBrain
    private let policy = PetPolicy(home: FileManager.default.homeDirectoryForCurrentUser)
    private lazy var executor = PetExecutor(policy: policy) { url, reveal in
        DispatchQueue.main.async {
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        }
    }
    private var task: Task<Void, Never>?
    /// Set by the island model (Spotify search, library, playback).
    var music: PetMusicPlayer?
    /// Your Spotify library for "@" tags (loaded on open, cached by the model).
    @Published private(set) var musicSources: [PetMusicSource] = []
    /// Highlighted row of the "@" suggestions.
    @Published var suggestionIndex = 0
    private var lastUndo: [PetUndo] = []

    let voice = PetVoice()
    private var voiceObserver: Any?

    init(brain: PetBrain? = nil) {
        let claude = ClaudeCodeBrain()
        claude.model = { AppSettings.shared.petModel }
        self.brain = brain ?? claude
        voice.onText = { [weak self] text in self?.query = text }
        voiceObserver = voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: Voice

    var isListening: Bool { voice.isListening }

    func startListening() {
        guard !voice.isListening else { return }
        if case .thinking = phase { cancelThinking() }
        if phase != .input { reset() }
        query = ""
        Task {
            do { try await voice.start() } catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// Key released / mic button: what was said becomes the request.
    func stopListening(submit: Bool = true) {
        guard voice.isListening else { return }
        Task {
            let text = await voice.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            query = text
            if submit && !text.isEmpty { self.submit() }
        }
    }

    func cancelListening() {
        voice.cancel()
        query = ""
    }

    // MARK: Opening

    var onOpenChange: ((Bool) -> Void)?

    private var releaseWork: DispatchWorkItem?

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        onOpenChange?(open)
        releaseWork?.cancel()
        guard open else {
            if voice.isListening { voice.cancel() }
            // Keep the warm Claude for a quick second call; let it go after two quiet minutes.
            let work = DispatchWorkItem { [brain] in brain.release() }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [brain] in brain.prewarm() }
        // Each call starts clean: only work still in progress (thinking, or a plan waiting for ⏎)
        // survives. Old answers and errors are gone, and the context is what Finder shows *now*.
        switch phase {
        case .thinking: break
        case .plan where planIsRunnable: break
        default: reset()
        }
        context = PetContext()
        Task {
            let finder = await FinderContext.read()
            if isOpen { context.folder = finder.folder; context.files = finder.files }
        }
        Task {
            if let sources = await music?.sources() { musicSources = sources }
        }
    }

    /// Back to an empty field (✕ in the panel, esc on an answer).
    func reset() {
        if case .thinking = phase { cancelThinking() }
        phase = .input
        query = ""
        asked = ""
    }

    func addFiles(_ urls: [URL]) {
        let new = urls.filter { !context.files.contains($0) }
        context.files += new
    }

    func removeFile(_ url: URL) { context.files.removeAll { $0 == url } }
    func clearFolder() { context.folder = nil }

    // MARK: Asking

    // MARK: "@" tags

    /// Text after an "@" being typed at the end of the field (nil when not mentioning anything).
    var mention: String? {
        guard let at = query.range(of: "@", options: .backwards) else { return nil }
        if at.lowerBound != query.startIndex && query[query.index(before: at.lowerBound)] != " " { return nil }
        return String(query[at.upperBound...])
    }

    var suggestions: [PetMusicSource] {
        guard let m = mention?.trimmingCharacters(in: .whitespaces).lowercased() else { return [] }
        let hits = m.isEmpty ? musicSources : musicSources.filter {
            $0.name.lowercased().contains(m) || $0.subtitle.lowercased().contains(m)
        }
        return hits
    }

    /// Quick picks under the field: the whole library, scrolled sideways.
    var quickSources: [PetMusicSource] { musicSources }

    func moveSuggestion(_ delta: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        suggestionIndex = (suggestionIndex + delta + n) % n
    }

    func pick(_ source: PetMusicSource) {
        context.music = source
        if let at = query.range(of: "@", options: .backwards) { query.removeSubrange(at.lowerBound...) }
        query = query.trimmingCharacters(in: .whitespaces)
        suggestionIndex = 0
    }

    func clearMusic() { context.music = nil }

    /// ⏎: pick the highlighted "@" suggestion, else a new request, else "do it" for a ready plan.
    func submit() {
        let list = suggestions
        if !list.isEmpty {
            pick(list[min(suggestionIndex, list.count - 1)])
            return
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let source = context.music { return playTag(source) }
            if case .plan = phase { execute() }
            return
        }
        ask(text)
    }

    /// Just a tag, no words: play it right away, no Claude needed.
    private func playTag(_ source: PetMusicSource) {
        task?.cancel()
        asked = "@" + source.name
        phase = .thinking
        task = Task {
            do {
                guard let music else { return }
                showPlaying(try await music.play(source, nil))
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func showPlaying(_ text: String, closeAfter seconds: Double = 2.5) {
        phase = .playing(text)
        // The pet goes back into the notch shortly — the island shows the track.
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if case .playing = phase, isOpen { PetPanelController.shared.close() }
        }
    }

    func ask(_ text: String) {
        task?.cancel()
        asked = context.music.map { "@\($0.name) \(text)" } ?? text
        query = ""
        phase = .thinking
        var context = context
        task = Task { [brain, policy] in
            do {
                // Simple requests never reach Claude.
                if context.music == nil, let intent = PetQuickIntent.parse(text), try await self.runQuick(intent) {
                    return
                }
                defer { if self.isOpen { DispatchQueue.global(qos: .utility).async { brain.prewarm() } } }
                // "@Tag + words": let Claude pick from that playlist's own tracks.
                var tracks: [PlaylistTrack] = []
                if let source = context.music, let music = self.music {
                    tracks = Array(((try? await music.tracks(source)) ?? []).prefix(300))
                    if tracks.isEmpty {
                        // Spotify won't show what's inside (e.g. someone else's playlist): play it whole.
                        return self.showPlaying(try await music.play(source, nil))
                    }
                    context.musicTracks = tracks.map { $0.artist.isEmpty ? $0.name : "\($0.name) — \($0.artist)" }
                }
                let plan = try await brain.plan(text, context: context)
                guard !Task.isCancelled else { return }
                // Music starts right away: nothing to confirm, nothing to undo.
                if let request = plan.music, let music = self.music {
                    let playing: String
                    if let source = context.music {
                        let n = Int(request.query.filter(\.isNumber)) ?? 0
                        let pick = tracks.indices.contains(n - 1) ? tracks[n - 1]
                            : tracks.first { request.query.localizedCaseInsensitiveContains($0.name) }
                        playing = try await music.play(source, pick)
                    } else {
                        playing = try await music.search(request)
                    }
                    guard !Task.isCancelled else { return }
                    if plan.actions.isEmpty && plan.files.isEmpty { return self.showPlaying(playing) }
                }
                let issues = PetValidator.validate(plan.actions, policy: policy)
                self.phase = .plan(plan, issues: issues)
            } catch ClaudeCodeBrain.Failure.notLoggedIn {
                self.phase = .notLoggedIn
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Handles an instant request. False = couldn't (nothing found…), ask Claude instead.
    private func runQuick(_ intent: PetQuickIntent) async throws -> Bool {
        switch intent {
        case .media(let command):
            guard let music else { return false }
            showPlaying(music.control(command), closeAfter: 1)
            return true
        case .play(let name, let type):
            guard let music, let playing = try await music.quickPlay(name, type) else { return false }
            guard !Task.isCancelled else { return true }
            showPlaying(playing)
            return true
        case .find(let name):
            let files = await Self.spotlight(name, policy: policy)
            guard !files.isEmpty, !Task.isCancelled else { return false }
            let reply = files.count == 1 ? "Нашёл:" : "Нашёл \(files.count) \(PetPanelView.files(files.count)):"
            phase = .plan(PetPlan(reply: reply, files: files), issues: [])
            return true
        }
    }

    /// Spotlight lookup by file name inside the home folder (never Library or hidden files), newest first.
    static func spotlight(_ name: String, policy: PetPolicy) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-onlyin", policy.home.path, "-name", name]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return cont.resume(returning: []) }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                    .filter { policy.resolve($0) != nil }
                let dated = paths.prefix(200).map { path -> (String, Date) in
                    let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    return (path, date)
                }
                cont.resume(returning: dated.sorted { $0.1 > $1.1 }.prefix(20).map(\.0))
            }
        }
    }

    func cancelThinking() {
        task?.cancel()
        brain.cancel()
        phase = .input
        query = asked
    }

    // MARK: Doing

    var planIsRunnable: Bool {
        guard case .plan(let plan, let issues) = phase else { return false }
        return issues.isEmpty && plan.actions.contains(where: \.modifies)
    }

    func execute() {
        guard case .plan(let plan, let issues) = phase, issues.isEmpty, !plan.actions.isEmpty else { return }
        let result = executor.run(plan.actions)
        lastUndo = result.undo
        let changed = plan.actions.prefix(result.completed).filter(\.modifies).count
        if let error = result.error {
            phase = .failed("Сделал \(changed) из \(plan.actions.filter(\.modifies).count), дальше ошибка: \(error)")
        } else if changed == 0 {
            setOpen(false)   // just open/reveal: get out of the way
            phase = .input
        } else {
            phase = .done(Self.summary(changed), canUndo: !lastUndo.isEmpty)
            NSSound(named: "Glass")?.play()
        }
    }

    func undo() {
        guard !lastUndo.isEmpty else { return }
        let failed = executor.undo(lastUndo)
        lastUndo = []
        phase = .done(failed == 0 ? "Вернул всё как было" : "Вернул почти всё: \(failed) не получилось", canUndo: false)
    }

    func dismissPlan() {
        phase = .input
        query = asked
    }

    static func summary(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word = mod10 == 1 && mod100 != 11 ? "действие"
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "действия" : "действий"
        return "Готово: \(n) \(word)"
    }

    /// Debug captures only.
    func debugShow(_ phase: Phase, asked: String = "", context: PetContext = PetContext(),
                   sources: [PetMusicSource] = [], query: String = "") {
        self.phase = phase
        self.musicSources = sources
        self.query = query
        self.asked = asked
        self.context = context
    }

    // MARK: Pet face

    /// The face in the panel.
    var mood: PetMood {
        if voice.isListening { return .attention }
        switch phase {
        case .input: return .idle
        case .thinking: return .working
        case .plan: return planIsRunnable ? .attention : .idle
        case .done: return .happy
        case .playing: return .dancing
        case .failed, .notLoggedIn: return .idle
        }
    }

    /// While the panel is hidden, the pet right of the notch carries on the story.
    var earMood: PetMood? {
        guard !isOpen else { return nil }
        switch phase {
        case .thinking: return .working
        case .plan: return planIsRunnable ? .attention : nil
        default: return nil
        }
    }
}
