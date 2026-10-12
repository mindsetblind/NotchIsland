import Foundation

/// Things the pet may offer on its own. Detection is cheap and local (a shallow folder listing);
/// accepting one only opens the pet with a ready request — the plan still waits for ⏎.
public enum PetSuggestion: String, CaseIterable, Codable, Sendable {
    case tidyDownloads        // lots of old files in Downloads
    case desktopScreenshots   // screenshots piling up on the Desktop
    case oldInstallers        // .dmg / .pkg left in Downloads
}

/// What a folder looks like right now (top level only).
public struct PetFolderStats: Equatable, Sendable {
    public var files: Int = 0
    public var olderThanMonth: Int = 0
    public var screenshots: Int = 0
    public var oldInstallers: Int = 0

    public init(files: Int = 0, olderThanMonth: Int = 0, screenshots: Int = 0, oldInstallers: Int = 0) {
        self.files = files
        self.olderThanMonth = olderThanMonth
        self.screenshots = screenshots
        self.oldInstallers = oldInstallers
    }

    public struct Entry: Sendable {
        public let name: String
        public let modified: Date
        public let isDirectory: Bool
        public init(name: String, modified: Date, isDirectory: Bool) {
            self.name = name
            self.modified = modified
            self.isDirectory = isDirectory
        }
    }

    public init(entries: [Entry], now: Date) {
        for e in entries where !e.name.hasPrefix(".") {
            files += 1
            let age = now.timeIntervalSince(e.modified)
            if age > 30 * 86400 { olderThanMonth += 1 }
            let lower = e.name.lowercased()
            if !e.isDirectory && Self.isScreenshot(lower) { screenshots += 1 }
            if !e.isDirectory && (lower.hasSuffix(".dmg") || lower.hasSuffix(".pkg")) && age > 7 * 86400 { oldInstallers += 1 }
        }
    }

    static func isScreenshot(_ lowercasedName: String) -> Bool {
        ["снимок экрана", "screenshot", "screen shot"].contains { lowercasedName.hasPrefix($0) }
            && [".png", ".jpg", ".heic"].contains { lowercasedName.hasSuffix($0) }
    }
}

/// Decides whether to offer something now. Polite by design: rarely, one thing at a time,
/// and never the same offer again within a week.
public struct PetSuggester: Codable, Equatable, Sendable {
    public static let cooldown: TimeInterval = 3 * 3600
    public static let snooze: TimeInterval = 7 * 86400

    public var lastShown: Date?
    public var shownAt: [PetSuggestion: Date] = [:]

    public init() {}

    /// The offer to make, if any. `downloads` / `desktop`: nil when the folder couldn't be read.
    public func next(now: Date, downloads: PetFolderStats?, desktop: PetFolderStats?) -> PetSuggestion? {
        if let lastShown, now.timeIntervalSince(lastShown) < Self.cooldown { return nil }
        func allowed(_ s: PetSuggestion) -> Bool {
            shownAt[s].map { now.timeIntervalSince($0) >= Self.snooze } ?? true
        }
        // Most specific first: installers are an easy, obvious win.
        if let d = downloads, d.oldInstallers >= 3, allowed(.oldInstallers) { return .oldInstallers }
        if let d = desktop, d.screenshots >= 8, allowed(.desktopScreenshots) { return .desktopScreenshots }
        if let d = downloads, d.olderThanMonth >= 30, allowed(.tidyDownloads) { return .tidyDownloads }
        return nil
    }

    public mutating func markShown(_ s: PetSuggestion, at now: Date) {
        lastShown = now
        shownAt[s] = now
    }
}
