import AppKit
import NotchIslandCore
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
    @Published var claudePermissionsInIsland: Bool { didSet { save(claudePermissionsInIsland, "claudePermissionsInIsland") } }
    @Published var claudeSounds: Bool { didSet { save(claudeSounds, "claudeSounds") } }
    @Published var petAlwaysVisible: Bool { didSet { save(petAlwaysVisible, "mascotAlwaysVisible") } }
    @Published var petSleepsAtNight: Bool { didSet { save(petSleepsAtNight, "mascotSleepsAtNight") } }
    /// ⌥⇧Space calls the pet out of the notch to help with files.
    @Published var petHotKeyEnabled: Bool { didSet { save(petHotKeyEnabled, "petHotKeyEnabled") } }
    /// Where the pet thinks: Groq (fast, free key), Ollama (on this Mac) or Claude Code.
    @Published var petProvider: PetProvider { didSet { save(petProvider.rawValue, "petProvider") } }
    /// Groq model id; empty = the best available automatically.
    @Published var petGroqModel: String { didSet { save(petGroqModel, "petGroqModel") } }
    @Published var petOllamaModel: String { didSet { save(petOllamaModel, "petOllamaModel") } }
    /// Claude model the pet thinks with: "sonnet" (smarter) or "haiku" (faster).
    @Published var petModel: String { didSet { save(petModel, "petModel") } }
    /// The pet now and then offers help on its own (tidy Downloads, screenshots…).
    @Published var petSuggestions: Bool { didSet { save(petSuggestions, "petSuggestions") } }
    /// The cat dresses for the occasion (headphones, glasses, nightcap, seasonal hats).
    @Published var petAccessories: Bool { didSet { save(petAccessories, "petAccessories") } }
    /// The cat's look (CatSkin id).
    @Published var catSkin: String {
        didSet {
            save(catSkin, "catSkin")
            NotificationCenter.default.post(name: CatSkin.changed, object: nil)
        }
    }
    /// Shrink the island to the notch while the active app's menus reach it.
    @Published var freeMenuBar: Bool { didSet { save(freeMenuBar, "freeMenuBar") } }
    /// Hold ⌥⇧Space to talk to the pet.
    @Published var petVoice: Bool { didSet { save(petVoice, "petVoice") } }
    /// Alert/activity kinds switched off by the user (empty = everything on; new kinds start enabled).
    @Published var disabledActivities: Set<ActivityKind> {
        didSet { save(disabledActivities.map(\.rawValue).sorted(), "disabledActivities") }
    }
    /// User's order of live activities (first = shown when several are going on).
    @Published var liveActivityOrder: [ActivityKind] {
        didSet { save(liveActivityOrder.map(\.rawValue), "liveActivityOrder") }
    }
    // Clipboard history (off until the user turns it on).
    @Published var clipboardEnabled: Bool { didSet { save(clipboardEnabled, "clipboardEnabled") } }
    @Published var clipboardPaused: Bool { didSet { save(clipboardPaused, "clipboardPaused") } }
    @Published var clipboardMaxItems: Int { didSet { save(clipboardMaxItems, "clipboardMaxItems") } }
    /// Days unpinned items are kept.
    @Published var clipboardMaxAgeDays: Int { didSet { save(clipboardMaxAgeDays, "clipboardMaxAgeDays") } }
    @Published var clipboardSkipSecrets: Bool { didSet { save(clipboardSkipSecrets, "clipboardSkipSecrets") } }
    @Published var clipboardPersist: Bool { didSet { save(clipboardPersist, "clipboardPersist") } }
    @Published var clipboardHotKey: Bool { didSet { save(clipboardHotKey, "clipboardHotKey") } }
    // Developer Mode (off until the user turns it on).
    @Published var developerModeEnabled: Bool { didSet { save(developerModeEnabled, "developerModeEnabled") } }
    @Published var developerSounds: Bool { didSet { save(developerSounds, "developerSounds") } }
    /// Warn once when a task runs longer than this (0 = never).
    @Published var developerLongTaskMinutes: Int { didSet { save(developerLongTaskMinutes, "developerLongTaskMinutes") } }
    // Optional system activities that need a permission (off until turned on).
    @Published var downloadsWatchEnabled: Bool { didSet { save(downloadsWatchEnabled, "downloadsWatchEnabled") } }
    @Published var calendarEnabled: Bool { didSet { save(calendarEnabled, "calendarEnabled") } }
    @Published var calendarLeadMinutes: Int { didSet { save(calendarLeadMinutes, "calendarLeadMinutes") } }
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
        claudePermissionsInIsland = bool("claudePermissionsInIsland", true)
        claudeSounds = bool("claudeSounds", true)
        petAlwaysVisible = bool("mascotAlwaysVisible", true)
        petSleepsAtNight = bool("mascotSleepsAtNight", true)
        petHotKeyEnabled = bool("petHotKeyEnabled", true)
        petModel = d.string(forKey: "petModel") ?? "sonnet"
        petProvider = PetProvider(rawValue: d.string(forKey: "petProvider") ?? "") ?? .groq
        petGroqModel = d.string(forKey: "petGroqModel") ?? ""
        petOllamaModel = d.string(forKey: "petOllamaModel") ?? "qwen2.5:7b"
        petSuggestions = bool("petSuggestions", true)
        petVoice = bool("petVoice", true)
        freeMenuBar = bool("freeMenuBar", true)
        catSkin = d.string(forKey: "catSkin") ?? "neon"
        petAccessories = bool("petAccessories", true)
        clipboardEnabled = bool("clipboardEnabled", false)
        clipboardPaused = bool("clipboardPaused", false)
        clipboardMaxItems = d.object(forKey: "clipboardMaxItems") as? Int ?? 50
        clipboardMaxAgeDays = d.object(forKey: "clipboardMaxAgeDays") as? Int ?? 7
        clipboardSkipSecrets = bool("clipboardSkipSecrets", true)
        clipboardPersist = bool("clipboardPersist", true)
        clipboardHotKey = bool("clipboardHotKey", false)
        developerModeEnabled = bool("developerModeEnabled", false)
        developerSounds = bool("developerSounds", true)
        developerLongTaskMinutes = d.object(forKey: "developerLongTaskMinutes") as? Int ?? 10
        downloadsWatchEnabled = bool("downloadsWatchEnabled", false)
        calendarEnabled = bool("calendarEnabled", false)
        calendarLeadMinutes = d.object(forKey: "calendarLeadMinutes") as? Int ?? 5
        disabledActivities = Set((d.stringArray(forKey: "disabledActivities") ?? []).compactMap(ActivityKind.init(rawValue:)))
        liveActivityOrder = Self.normalizedOrder(d.stringArray(forKey: "liveActivityOrder")?.compactMap(ActivityKind.init(rawValue:)))
        placeholderPicture = Self.loadPlaceholder()
    }

    // MARK: Activities

    func isActivityEnabled(_ kind: ActivityKind) -> Bool { !disabledActivities.contains(kind) }

    func setActivity(_ kind: ActivityKind, enabled: Bool) {
        if enabled { disabledActivities.remove(kind) } else { disabledActivities.insert(kind) }
    }

    /// Saved order with unknown kinds dropped and new ones appended in their default place.
    static func normalizedOrder(_ saved: [ActivityKind]?) -> [ActivityKind] {
        var order = (saved ?? []).filter { ActivityKind.liveKinds.contains($0) }
        order = order.enumerated().filter { order.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        for kind in ActivityKind.liveKinds where !order.contains(kind) { order.append(kind) }
        return order
    }

    func moveLiveActivity(_ kind: ActivityKind, by offset: Int) {
        guard let i = liveActivityOrder.firstIndex(of: kind) else { return }
        let j = min(max(i + offset, 0), liveActivityOrder.count - 1)
        guard i != j else { return }
        liveActivityOrder.swapAt(i, j)
    }

    /// Live priorities from the user's order (same band as the defaults, highest first).
    var livePriorityOverrides: [ActivityKind: Int] {
        let order = liveActivityOrder
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, 75 - $0 * 5) })
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: Placeholder picture

    static var supportDir: URL {
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
