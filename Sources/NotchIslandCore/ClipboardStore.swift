import Combine
import Foundation

public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, link }

    public let id: UUID
    public var text: String
    public var kind: Kind
    /// Last time this text was copied (items are ordered by it).
    public var copiedAt: Date
    public var pinned: Bool
    /// Name of the app it was copied from, if known (shown as a hint only).
    public var sourceApp: String?

    public init(id: UUID = UUID(), text: String, kind: Kind, copiedAt: Date, pinned: Bool = false, sourceApp: String? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.copiedAt = copiedAt
        self.pinned = pinned
        self.sourceApp = sourceApp
    }

    /// One line for compact rows.
    public var preview: String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

public struct ClipboardPolicy: Equatable, Sendable {
    /// Unpinned items kept at most (oldest go first).
    public var maxItems: Int
    /// Unpinned items older than this are forgotten. nil = no age limit.
    public var maxAge: TimeInterval?
    public var maxPinned: Int
    /// Longer text isn't stored at all (big pastes are rarely worth keeping and bloat the file).
    public var maxLength: Int
    public var skipLikelySecrets: Bool

    public init(maxItems: Int = 50, maxAge: TimeInterval? = 7 * 86_400, maxPinned: Int = 30,
                maxLength: Int = 20_000, skipLikelySecrets: Bool = true) {
        self.maxItems = maxItems
        self.maxAge = maxAge
        self.maxPinned = maxPinned
        self.maxLength = maxLength
        self.skipLikelySecrets = skipLikelySecrets
    }
}

/// Clipboard history: text and links only, stored locally in one JSON file readable only by the user.
@MainActor
public final class ClipboardStore: ObservableObject {
    public enum AddResult: Equatable {
        case added, bumped, skippedEmpty, skippedTooLong, skippedSecret
    }

    /// Pinned first, then most recently copied.
    @Published public private(set) var items: [ClipItem] = []
    public var policy: ClipboardPolicy { didSet { prune() } }

    /// Where the history is kept; nil = memory only. Switching to nil deletes the file right away.
    public var fileURL: URL? {
        didSet {
            guard oldValue != fileURL else { return }
            if let oldValue { try? FileManager.default.removeItem(at: oldValue) }
            save()
        }
    }
    private let now: () -> Date
    /// Sample data for screenshots: shown, never written.
    private var readOnly = false

    /// `fileURL == nil` keeps the history in memory only (tests, or "don't keep between launches").
    public init(fileURL: URL?, policy: ClipboardPolicy = ClipboardPolicy(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.policy = policy
        self.now = now
        load()
        prune()
    }

    // MARK: Changes

    @discardableResult
    public func add(_ raw: String, sourceApp: String? = nil) -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skippedEmpty }
        guard raw.count <= policy.maxLength else { return .skippedTooLong }
        if policy.skipLikelySecrets && SecretDetector.isLikelySecret(raw) { return .skippedSecret }

        // Copying the same text again moves it to the top instead of adding a duplicate.
        if let i = items.firstIndex(where: { $0.text == raw }) {
            items[i].copiedAt = now()
            if let sourceApp { items[i].sourceApp = sourceApp }
            sortAndSave()
            return .bumped
        }
        items.append(ClipItem(text: raw, kind: Self.kind(of: trimmed), copiedAt: now(), sourceApp: sourceApp))
        prune()
        return .added
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if pinned && items.filter(\.pinned).count >= policy.maxPinned { return }
        items[i].pinned = pinned
        sortAndSave()
    }

    /// Marks an item as just used (copied back from the history).
    public func touch(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].copiedAt = now()
        sortAndSave()
    }

    /// Removes everything except pinned items.
    public func clearUnpinned() {
        items.removeAll { !$0.pinned }
        save()
    }

    /// Removes everything, pinned included, and deletes the file right away.
    public func clearAll() {
        items.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Applies the age and count limits (called on every add and when the policy changes; also call
    /// it periodically so old items expire even if nothing new is copied).
    public func prune() {
        let t = now()
        if let maxAge = policy.maxAge {
            items.removeAll { !$0.pinned && t.timeIntervalSince($0.copiedAt) > maxAge }
        }
        items.removeAll { !$0.pinned && $0.text.count > policy.maxLength }
        sortItems()
        var unpinnedSeen = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= policy.maxItems
        }
        save()
    }

    // MARK: Search

    /// Case- and diacritic-insensitive; every word of the query must appear.
    public func search(_ query: String) -> [ClipItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            words.allSatisfy { item.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: Classification

    public static func kind(of text: String) -> ClipItem.Kind {
        guard !text.contains(where: \.isWhitespace), text.count < 2048 else { return .text }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme), url.host != nil || scheme == "mailto" {
            return .link
        }
        if text.lowercased().hasPrefix("www."), text.contains(".") { return .link }
        return .text
    }

    // MARK: Persistence

    private struct FileFormat: Codable {
        var version = 1
        var items: [ClipItem]
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            items = try JSONDecoder.clipboard.decode(FileFormat.self, from: data).items
        } catch {
            // Never silently destroy history: keep the unreadable file next to the new one.
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            items = []
        }
    }

    private func sortItems() {
        items.sort { $0.pinned != $1.pinned ? $0.pinned : $0.copiedAt > $1.copiedAt }
    }

    private func sortAndSave() {
        sortItems()
        save()
    }

    /// Replaces the items for UI snapshots without touching the history file.
    public func showSample(_ sample: [ClipItem]) {
        readOnly = true
        items = sample
    }

    private func save() {
        guard !readOnly, let fileURL else { return }
        if items.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder.clipboard.encode(FileFormat(items: items)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Created with owner-only permissions from the start, then replaced atomically.
        let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        let fm = FileManager.default
        let moved = fm.fileExists(atPath: fileURL.path)
            ? (try? fm.replaceItemAt(fileURL, withItemAt: tmp)) != nil
            : (try? fm.moveItem(at: tmp, to: fileURL)) != nil
        if !moved { try? fm.removeItem(at: tmp) }
    }
}

private extension JSONEncoder {
    static let clipboard: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

private extension JSONDecoder {
    static let clipboard: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
