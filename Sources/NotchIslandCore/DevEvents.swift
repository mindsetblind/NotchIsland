import Foundation

/// Developer Mode event, protocol version 1.
///
/// One JSON object per line, sent to NotchIsland's Unix socket
/// (`~/Library/Application Support/NotchIsland/claude.sock`, owner-only). Example:
///
///     {"v":1,"type":"task","event":"start","id":"web-build","title":"npm run build","category":"build"}
///     {"v":1,"type":"task","event":"progress","id":"web-build","progress":0.4,"message":"bundling"}
///     {"v":1,"type":"task","event":"finish","id":"web-build","status":"failure","message":"2 errors","exit_code":1}
///     {"v":1,"type":"task","event":"start","id":"api","title":"API :8080","category":"server"}
///
/// The island only *displays* these events: it never runs commands, opens URLs or touches files
/// because of them. See `docs/developer-mode.md`.
public struct DevEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case start, progress, finish, message }
    public enum Status: String, Sendable { case success, failure, cancelled }
    public enum Category: String, Sendable, CaseIterable { case build, test, script, server, deploy, other }

    public var kind: Kind
    public var id: String
    public var title: String?
    public var category: Category
    public var message: String?
    /// 0…1
    public var progress: Double?
    public var status: Status?
    public var exitCode: Int?
    /// Free-form name of the sender ("xcodebuild", "npm", "my-script").
    public var source: String?

    public init(kind: Kind, id: String, title: String? = nil, category: Category = .other, message: String? = nil,
                progress: Double? = nil, status: Status? = nil, exitCode: Int? = nil, source: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.category = category
        self.message = message
        self.progress = progress
        self.status = status
        self.exitCode = exitCode
        self.source = source
    }
}

public enum DevEventError: Error, Equatable, CustomStringConvertible {
    case tooLarge, notJSON, wrongVersion, notATaskEvent, unknownEvent(String), badID, missingStatus
    case badField(String)

    public var description: String {
        switch self {
        case .tooLarge: return "message is larger than \(DevEventParser.maxMessageBytes) bytes"
        case .notJSON: return "not a JSON object"
        case .wrongVersion: return "unsupported protocol version (expected \"v\": 1)"
        case .notATaskEvent: return "expected \"type\": \"task\""
        case .unknownEvent(let e): return "unknown event \"\(e)\" (start, progress, finish, message)"
        case .badID: return "\"id\" must be 1–64 characters: letters, digits, . _ : / -"
        case .missingStatus: return "\"finish\" needs \"status\": success, failure or cancelled"
        case .badField(let f): return "invalid \"\(f)\""
        }
    }
}

public enum DevEventParser {
    public static let maxMessageBytes = 8 * 1024
    public static let maxTitleLength = 80
    public static let maxTextLength = 300
    public static let maxIDLength = 64

    /// True if this JSON object is meant for Developer Mode (rather than a Claude Code hook event).
    public static func isDevEvent(_ object: [String: Any]) -> Bool {
        object["type"] as? String == "task" && object["v"] != nil
    }

    public static func parse(_ data: Data) throws -> DevEvent {
        guard data.count <= maxMessageBytes else { throw DevEventError.tooLarge }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DevEventError.notJSON
        }
        return try parse(object)
    }

    public static func parse(_ o: [String: Any]) throws -> DevEvent {
        guard let v = o["v"] as? NSNumber, !isBoolean(v), v.intValue == 1 else { throw DevEventError.wrongVersion }
        guard o["type"] as? String == "task" else { throw DevEventError.notATaskEvent }
        guard let rawKind = o["event"] as? String else { throw DevEventError.unknownEvent("") }
        guard let kind = DevEvent.Kind(rawValue: rawKind) else { throw DevEventError.unknownEvent(String(rawKind.prefix(20))) }
        guard let id = o["id"] as? String, isValidID(id) else { throw DevEventError.badID }

        var e = DevEvent(kind: kind, id: id, title: nil, category: .other, message: nil,
                         progress: nil, status: nil, exitCode: nil, source: nil)
        if let v = o["title"] {
            guard let s = v as? String else { throw DevEventError.badField("title") }
            e.title = clean(s, max: maxTitleLength)
        }
        if let v = o["message"] {
            guard let s = v as? String else { throw DevEventError.badField("message") }
            e.message = clean(s, max: maxTextLength)
        }
        if let v = o["source"] {
            guard let s = v as? String else { throw DevEventError.badField("source") }
            e.source = clean(s, max: 40)
        }
        if let v = o["category"] {
            // Unknown categories degrade to "other" so newer senders keep working.
            guard let s = v as? String else { throw DevEventError.badField("category") }
            e.category = DevEvent.Category(rawValue: s) ?? .other
        }
        if let v = o["progress"] {
            guard let n = v as? NSNumber, !isBoolean(n), n.doubleValue.isFinite else { throw DevEventError.badField("progress") }
            e.progress = min(1, max(0, n.doubleValue))
        }
        if let v = o["exit_code"] {
            guard let n = v as? NSNumber, !isBoolean(n) else { throw DevEventError.badField("exit_code") }
            e.exitCode = Int(clamping: n.int64Value)
        }
        if let v = o["status"] {
            guard let s = v as? String, let status = DevEvent.Status(rawValue: s) else { throw DevEventError.badField("status") }
            e.status = status
        }
        if kind == .finish && e.status == nil {
            // An exit code is enough to know how it ended.
            guard let code = e.exitCode else { throw DevEventError.missingStatus }
            e.status = code == 0 ? .success : .failure
        }
        return e
    }

    /// JSON true/false also arrive as NSNumber (and `is Bool` matches 0 and 1 too).
    private static func isBoolean(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func isValidID(_ id: String) -> Bool {
        guard (1...maxIDLength).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:/-".unicodeScalars.contains($0) }
            && id.allSatisfy(\.isASCII)
    }

    /// Single line, no control characters (no terminal escapes, no fake newlines), trimmed, capped.
    static func clean(_ s: String, max: Int) -> String? {
        let scalars = s.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format
                ? " " : Character(scalar)
        }
        var out = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if out.count > max { out = String(out.prefix(max - 1)) + "…" }
        return out.isEmpty ? nil : out
    }
}
