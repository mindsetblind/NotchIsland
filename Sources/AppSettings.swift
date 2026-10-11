import AppKit
import SwiftUI

/// User preferences (persisted in UserDefaults) shared by the island and the Settings window.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum OpenMode: String, CaseIterable, Identifiable {
        case click, hover
        var id: String { rawValue }
        var title: String { self == .click ? "По клику" : "При наведении" }
    }

    @Published var openMode: OpenMode { didSet { save(openMode.rawValue, "openMode") } }
    @Published var hotKeyEnabled: Bool { didSet { save(hotKeyEnabled, "hotKeyEnabled") } }
    @Published var showCompactMusic: Bool { didSet { save(showCompactMusic, "showCompactMusic") } }
    @Published var showCompactPomodoro: Bool { didSet { save(showCompactPomodoro, "showCompactPomodoro") } }
    @Published var showChargingPeek: Bool { didSet { save(showChargingPeek, "showChargingPeek") } }
    @Published var showBluetoothPeek: Bool { didSet { save(showBluetoothPeek, "showBluetoothPeek") } }
    @Published var showDrivePeek: Bool { didSet { save(showDrivePeek, "showDrivePeek") } }
    @Published var cleaningDuration: TimeInterval { didSet { save(cleaningDuration, "cleaningDuration") } }
    /// Picture shown instead of a cover that hasn't loaded (user's choice, else the bundled one).
    @Published private(set) var placeholderPicture: NSImage?

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        openMode = OpenMode(rawValue: d.string(forKey: "openMode") ?? "") ?? .click
        hotKeyEnabled = bool("hotKeyEnabled", true)
        showCompactMusic = bool("showCompactMusic", true)
        showCompactPomodoro = bool("showCompactPomodoro", true)
        showChargingPeek = bool("showChargingPeek", true)
        showBluetoothPeek = bool("showBluetoothPeek", true)
        showDrivePeek = bool("showDrivePeek", true)
        cleaningDuration = d.object(forKey: "cleaningDuration") as? Double ?? 120
        placeholderPicture = Self.loadPlaceholder()
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: Placeholder picture

    private static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var customPlaceholderURL: URL { supportDir.appendingPathComponent("placeholder-picture") }

    var hasCustomPlaceholder: Bool { FileManager.default.fileExists(atPath: Self.customPlaceholderURL.path) }

    private static func loadPlaceholder() -> NSImage? {
        if let custom = NSImage(contentsOf: customPlaceholderURL) { return custom }
        return ["jpg", "png"].lazy
            .compactMap { Bundle.main.url(forResource: "placeholder", withExtension: $0) }
            .compactMap { NSImage(contentsOf: $0) }
            .first
    }

    func choosePlaceholder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Выбрать"
        panel.message = "Картинка, которая показывается, пока обложка не загрузилась"
        guard panel.runModal() == .OK, let url = panel.url, NSImage(contentsOf: url) != nil else { return }
        try? FileManager.default.removeItem(at: Self.customPlaceholderURL)
        try? FileManager.default.copyItem(at: url, to: Self.customPlaceholderURL)
        placeholderPicture = Self.loadPlaceholder()
    }

    func resetPlaceholder() {
        try? FileManager.default.removeItem(at: Self.customPlaceholderURL)
        placeholderPicture = Self.loadPlaceholder()
    }
}
