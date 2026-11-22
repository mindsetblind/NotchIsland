import Foundation

/// Reads an agent's hook settings file (`~/.claude/settings.json`, `~/.codex/hooks.json`) before
/// NotchIsland adds or removes its hooks. The point is to tell "there is no file yet" (start from an
/// empty object) from "there is a file we can't understand" (stop — writing would wipe the user's settings).
public enum HookSettingsFile {
    public enum ReadError: Error, Equatable, CustomStringConvertible {
        /// The file exists but couldn't be read (permissions, it's a folder…).
        case unreadable(String)
        /// The file isn't valid JSON — e.g. a trailing comma after a hand edit.
        case invalidJSON(String)
        /// Valid JSON, but not an object at the top level.
        case notAnObject

        public var description: String {
            switch self {
            case .unreadable(let why): return "Файл не читается: \(why)"
            case .invalidJSON(let why): return "Файл не разбирается как JSON: \(why)"
            case .notAnObject: return "В файле JSON, но не объект { … }"
            }
        }
    }

    /// Settings from the file's contents; `nil` (no file) and an empty or blank file mean "no settings yet".
    public static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw ReadError.invalidJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                                        ?? error.localizedDescription)
        }
        guard let object = json as? [String: Any] else { throw ReadError.notAnObject }
        return object
    }

    /// Reads and parses the file at `url`; a missing file is fine, anything else unreadable throws.
    public static func read(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadError.unreadable(error.localizedDescription)
        }
        return try parse(data)
    }
}
