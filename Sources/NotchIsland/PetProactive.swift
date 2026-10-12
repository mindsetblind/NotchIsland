import AppKit
import NotchIslandCore

/// The pet offering help on its own: now and then it looks at Downloads and the Desktop (top level
/// only) and, if something piles up, shows a short offer in the island. A click opens the pet with
/// a ready request; nothing happens until you confirm the plan.
@MainActor
final class PetProactive {
    static let shared = PetProactive()

    private weak var model: IslandModel?
    private var timer: Timer?
    private var suggester: PetSuggester
    private static let storeKey = "petSuggester"

    private init() {
        suggester = UserDefaults.standard.data(forKey: Self.storeKey)
            .flatMap { try? JSONDecoder().decode(PetSuggester.self, from: $0) } ?? PetSuggester()
    }

    func start(model: IslandModel) {
        self.model = model
        // First look a few minutes after launch, then twice an hour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 120
    }

    /// Only when you're at the Mac and the island has nothing else to say.
    private var canInterrupt: Bool {
        guard let model, AppSettings.shared.petSuggestions, AppSettings.shared.isActivityEnabled(.pet) else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle < 60 && !model.isExpanded && model.currentActivity == nil && !PetAssistant.shared.isOpen
    }

    func check() {
        guard canInterrupt else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task.detached(priority: .utility) {
            let now = Date()
            let downloads = Self.stats(home.appendingPathComponent("Downloads"), now: now)
            let desktop = Self.stats(home.appendingPathComponent("Desktop"), now: now)
            await MainActor.run { self.offer(downloads: downloads, desktop: desktop, now: now) }
        }
    }

    private func offer(downloads: PetFolderStats?, desktop: PetFolderStats?, now: Date) {
        guard canInterrupt, let model,
              let suggestion = suggester.next(now: now, downloads: downloads, desktop: desktop) else { return }
        let (title, detail, request) = Self.text(suggestion, downloads: downloads, desktop: desktop)
        model.post(.pet, suggestion.rawValue, .notice(Notice(symbol: "sparkles", title: title, detail: detail,
                                                             petRequest: request)), duration: 10)
        suggester.markShown(suggestion, at: now)
        if let data = try? JSONEncoder().encode(suggester) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        debugLog("pet: offered \(suggestion.rawValue)")
    }

    nonisolated static func stats(_ folder: URL, now: Date) -> PetFolderStats? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        return PetFolderStats(entries: urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return .init(name: url.lastPathComponent, modified: v?.contentModificationDate ?? now, isDirectory: v?.isDirectory ?? false)
        }, now: now)
    }

    static func text(_ s: PetSuggestion, downloads: PetFolderStats?, desktop: PetFolderStats?) -> (String, String, String) {
        switch s {
        case .oldInstallers:
            let n = downloads?.oldInstallers ?? 0
            return ("Убрать установщики?", "\(n) в Загрузках",
                    "убери в Корзину установщики .dmg и .pkg из Загрузок, которые старше недели")
        case .desktopScreenshots:
            let n = desktop?.screenshots ?? 0
            return ("Сложить скриншоты?", "\(n) на столе",
                    "сложи скриншоты с рабочего стола в папку «Скриншоты» на рабочем столе")
        case .tidyDownloads:
            let n = downloads?.olderThanMonth ?? 0
            return ("Разобрать Загрузки?", "\(n) старых",
                    "разложи файлы в Загрузках, которые старше месяца, по папкам по типу")
        }
    }
}
