import Foundation

// The pet's file assistant: the model only *proposes* a plan; everything here checks and runs it.
// Nothing is ever deleted for good (trash only), nothing outside the home folder is touched,
// and every step that ran can be undone.

public struct PetAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case mkdir     // path = new folder
        case move      // path → to (full destination path, also used for renaming)
        case copy      // path → to
        case trash     // path goes to the Trash
        case zip       // path → to (.zip archive)
        case open      // open with the default app
        case reveal    // show in Finder
    }

    public var kind: Kind
    public var path: String
    public var to: String?

    public init(_ kind: Kind, _ path: String, to: String? = nil) {
        self.kind = kind
        self.path = path
        self.to = to
    }

    /// Changes something on disk (as opposed to open/reveal).
    public var modifies: Bool { kind != .open && kind != .reveal }
}

/// "Play something": a Spotify search the app runs and starts right away (nothing to confirm).
public struct PetMusic: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case track, artist, album, playlist }
    public var query: String
    public var type: Kind

    public init(query: String, type: Kind) {
        self.query = query
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        type = (try? c.decode(Kind.self, forKey: .type)) ?? .track
    }
}

public struct PetPlan: Codable, Equatable, Sendable {
    /// One or two short sentences for the user.
    public var reply: String
    /// Files the user was looking for (search results).
    public var files: [String]
    public var actions: [PetAction]
    public var music: PetMusic?

    public init(reply: String, files: [String] = [], actions: [PetAction] = [], music: PetMusic? = nil) {
        self.reply = reply
        self.files = files
        self.actions = actions
        self.music = music
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        actions = try c.decodeIfPresent([PetAction].self, forKey: .actions) ?? []
        music = try? c.decodeIfPresent(PetMusic.self, forKey: .music)
        if music?.query.trimmingCharacters(in: .whitespaces).isEmpty == true { music = nil }
    }

    /// JSON schema handed to the model so its answer always has this shape.
    public static let jsonSchema = """
    {"type":"object","properties":{\
    "reply":{"type":"string"},\
    "files":{"type":"array","items":{"type":"string"}},\
    "actions":{"type":"array","items":{"type":"object","properties":{\
    "kind":{"type":"string","enum":["mkdir","move","copy","trash","zip","open","reveal"]},\
    "path":{"type":"string"},"to":{"type":"string"}},"required":["kind","path"]}},\
    "music":{"type":["object","null"],"properties":{"query":{"type":"string"},\
    "type":{"type":"string","enum":["track","artist","album","playlist"]}},"required":["query","type"]}},\
    "required":["reply","files","actions"]}
    """

    public enum ParseError: Error, Equatable {
        case notLoggedIn
        case failed(String)
    }

    /// Reads `claude -p --output-format json` output: the plan is in `structured_output`,
    /// or (older versions) a JSON object somewhere in `result`.
    public static func parse(cliOutput data: Data) throws -> PetPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw classify(text.isEmpty ? "Claude Code ничего не ответил" : text)
        }
        let result = root["result"] as? String ?? ""
        if root["is_error"] as? Bool == true { throw classify(result) }
        if let structured = root["structured_output"], !(structured is NSNull),
           let json = try? JSONSerialization.data(withJSONObject: structured),
           let plan = try? JSONDecoder().decode(PetPlan.self, from: json) {
            return plan
        }
        if let start = result.firstIndex(of: "{"), let end = result.lastIndex(of: "}"),
           let plan = try? JSONDecoder().decode(PetPlan.self, from: Data(result[start...end].utf8)) {
            return plan
        }
        if !result.isEmpty { return PetPlan(reply: result) }
        throw ParseError.failed("Не получилось разобрать ответ Claude Code")
    }

    static func classify(_ message: String) -> ParseError {
        let m = message.lowercased()
        if m.contains("authenticate") || m.contains("not logged in") || m.contains("/login") || m.contains("oauth") {
            return .notLoggedIn
        }
        return .failed(message)
    }
}

/// Where the pet may work: inside the home folder, never in Library or hidden folders.
public struct PetPolicy: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Absolute path inside the home folder (`~` expanded), or nil when it's off limits.
    public func resolve(_ raw: String) -> URL? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~") { path = home.path + path.dropFirst() }
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parts = url.pathComponents, base = home.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        let inside = parts.dropFirst(base.count)
        if inside.first == "Library" { return nil }
        if inside.contains(where: { $0.hasPrefix(".") }) { return nil }
        return url
    }
}

public struct PetIssue: Equatable, Sendable {
    public let index: Int
    public let message: String

    public init(index: Int, message: String) {
        self.index = index
        self.message = message
    }
}

public enum PetValidator {
    /// Checks every step against the policy and against what the disk will look like by then
    /// (earlier steps of the same plan count: "make folder, then move into it" is fine).
    public static func validate(_ actions: [PetAction], policy: PetPolicy,
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [PetIssue] {
        var issues: [PetIssue] = []
        var created = Set<String>(), removed = Set<String>()
        func present(_ p: String) -> Bool {
            if removed.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }
            return created.contains(p) || exists(p)
        }
        func parentPresent(_ p: String) -> Bool {
            present((p as NSString).deletingLastPathComponent)
        }

        for (i, a) in actions.enumerated() {
            func fail(_ m: String) { issues.append(PetIssue(index: i, message: m)) }
            guard let src = policy.resolve(a.path)?.path else { fail("путь вне домашней папки"); continue }
            switch a.kind {
            case .mkdir:
                if present(src) { fail("папка уже есть"); continue }
                created.insert(src)
            case .trash:
                guard present(src) else { fail("файла нет"); continue }
                removed.insert(src)
            case .open, .reveal:
                if !present(src) { fail("файла нет") }
            case .move, .copy, .zip:
                guard let raw = a.to, let dst = policy.resolve(raw)?.path else { fail("куда — непонятно"); continue }
                guard present(src) else { fail("файла нет"); continue }
                if src == dst { fail("файл уже здесь"); continue }
                if dst.hasPrefix(src + "/") { fail("нельзя положить папку саму в себя"); continue }
                if present(dst) { fail("там уже есть файл с таким именем"); continue }
                if !parentPresent(dst) { fail("нет папки назначения"); continue }
                created.insert(dst)
                if a.kind == .move { removed.insert(src); created.remove(src) }
                removed.remove(dst)
            }
        }
        return issues
    }
}

/// One step that ran, and how to take it back.
public enum PetUndo: Equatable, Sendable {
    case removeCreated(URL)          // folder made / copy / archive → to the Trash (folder: only if empty)
    case moveBack(from: URL, to: URL)
    case restoreFromTrash(trashed: URL, original: URL)
}

public struct PetRunResult: Sendable {
    public var completed: Int
    public var undo: [PetUndo]
    public var error: String?
}

public final class PetExecutor {
    public let policy: PetPolicy
    private let fm: FileManager
    /// open/reveal need AppKit; the app passes NSWorkspace here.
    private let present: (URL, _ reveal: Bool) -> Void

    public init(policy: PetPolicy, fileManager: FileManager = .default,
                present: @escaping (URL, Bool) -> Void = { _, _ in }) {
        self.policy = policy
        self.fm = fileManager
        self.present = present
    }

    /// Runs the steps in order and stops at the first failure; whatever ran stays undoable.
    public func run(_ actions: [PetAction]) -> PetRunResult {
        var result = PetRunResult(completed: 0, undo: [], error: nil)
        for a in actions {
            do {
                if let step = try perform(a) { result.undo.append(step) }
                result.completed += 1
            } catch {
                result.error = "\(a.kind.rawValue) \((a.path as NSString).lastPathComponent): \(error.localizedDescription)"
                break
            }
        }
        return result
    }

    private func perform(_ a: PetAction) throws -> PetUndo? {
        guard let src = policy.resolve(a.path) else { throw PetError("путь вне домашней папки") }
        func dst() throws -> URL {
            guard let raw = a.to, let url = policy.resolve(raw) else { throw PetError("куда — непонятно") }
            guard !fm.fileExists(atPath: url.path) else { throw PetError("там уже есть файл с таким именем") }
            return url
        }
        switch a.kind {
        case .mkdir:
            try fm.createDirectory(at: src, withIntermediateDirectories: false)
            return .removeCreated(src)
        case .move:
            let to = try dst()
            try fm.moveItem(at: src, to: to)
            return .moveBack(from: to, to: src)
        case .copy:
            let to = try dst()
            try fm.copyItem(at: src, to: to)
            return .removeCreated(to)
        case .zip:
            let to = try dst()
            try Self.zip(src, to: to)
            return .removeCreated(to)
        case .trash:
            var trashed: NSURL?
            try fm.trashItem(at: src, resultingItemURL: &trashed)
            return (trashed as URL?).map { .restoreFromTrash(trashed: $0, original: src) }
        case .open, .reveal:
            guard fm.fileExists(atPath: src.path) else { throw PetError("файла нет") }
            present(src, a.kind == .reveal)
            return nil
        }
    }

    /// Takes steps back newest first. Returns how many could not be undone.
    @discardableResult
    public func undo(_ steps: [PetUndo]) -> Int {
        var failed = 0
        for step in steps.reversed() {
            do {
                switch step {
                case .removeCreated(let url):
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue, let items = try? fm.contentsOfDirectory(atPath: url.path),
                       !items.filter({ $0 != ".DS_Store" }).isEmpty {
                        failed += 1   // something new landed in it — leave it alone
                        continue
                    }
                    try fm.trashItem(at: url, resultingItemURL: nil)
                case .moveBack(let from, let to):
                    guard !fm.fileExists(atPath: to.path) else { failed += 1; continue }
                    try fm.moveItem(at: from, to: to)
                case .restoreFromTrash(let trashed, let original):
                    guard !fm.fileExists(atPath: original.path) else { failed += 1; continue }
                    try fm.moveItem(at: trashed, to: original)
                }
            } catch {
                failed += 1
            }
        }
        return failed
    }

    static func zip(_ src: URL, to dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dst.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PetError("не получилось сжать") }
    }
}

struct PetError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
