import AppKit
import NotchIslandCore
import SwiftUI

/// What we count. Only that something happened — never which file, track, app or text.
enum UsageEvent: String, CaseIterable {
    // Island
    case islandOpenedClick, islandOpenedHover, islandOpenedHotKey
    case tabMusic, tabApps, tabShelf, tabClipboard, tabAgents, tabTools
    // Music
    case musicControl, playlistOpened, trackChosen
    // Files
    case shelfAdded, airDrop, appLaunched
    // Tools
    case pomodoroStarted, colorPicked, cleaningStarted, homeOpened, lampToggled, speakerConnected
    // Clipboard
    case clipboardCopied, clipboardSearchOpened
    // Pet
    case petPanelOpened, petVoice, petQuick, petModel, petPlanRun, petUndo, petMusic, petTag
    case petOfferShown, petOfferAccepted, catPetted, catSkinChanged
    // Agents
    case agentPermissionAnswered
    // App
    case settingsOpened

    enum Group: String, CaseIterable { case island = "Остров", music = "Музыка", files = "Файлы и приложения",
                                       tools = "Инструменты", clipboard = "Буфер", pet = "Pet", agents = "Агенты", app = "Приложение" }

    var group: Group {
        switch self {
        case .islandOpenedClick, .islandOpenedHover, .islandOpenedHotKey, .tabMusic, .tabApps, .tabShelf,
             .tabClipboard, .tabAgents, .tabTools: return .island
        case .musicControl, .playlistOpened, .trackChosen: return .music
        case .shelfAdded, .airDrop, .appLaunched: return .files
        case .pomodoroStarted, .colorPicked, .cleaningStarted, .homeOpened, .lampToggled, .speakerConnected: return .tools
        case .clipboardCopied, .clipboardSearchOpened: return .clipboard
        case .petPanelOpened, .petVoice, .petQuick, .petModel, .petPlanRun, .petUndo, .petMusic, .petTag,
             .petOfferShown, .petOfferAccepted, .catPetted, .catSkinChanged: return .pet
        case .agentPermissionAnswered: return .agents
        case .settingsOpened: return .app
        }
    }

    var title: String {
        switch self {
        case .islandOpenedClick: return "Открыл остров кликом"
        case .islandOpenedHover: return "Открыл остров наведением"
        case .islandOpenedHotKey: return "Открыл остров по ⌥Space"
        case .tabMusic: return "Вкладка «Музыка»"
        case .tabApps: return "Вкладка «Приложения»"
        case .tabShelf: return "Вкладка «Полка»"
        case .tabClipboard: return "Вкладка «Буфер»"
        case .tabAgents: return "Вкладка «Агенты»"
        case .tabTools: return "Вкладка «Инструменты»"
        case .musicControl: return "Пауза / следующий / предыдущий"
        case .playlistOpened: return "Открыл плейлист"
        case .trackChosen: return "Выбрал трек в плейлисте"
        case .shelfAdded: return "Положил файл на полку"
        case .airDrop: return "AirDrop через остров"
        case .appLaunched: return "Запустил приложение из острова"
        case .pomodoroStarted: return "Запустил помидор"
        case .colorPicked: return "Пипетка"
        case .cleaningStarted: return "Режим чистки"
        case .homeOpened: return "Открыл «Дом»"
        case .lampToggled: return "Управлял лампой"
        case .speakerConnected: return "Звук на Станцию"
        case .clipboardCopied: return "Скопировал из истории буфера"
        case .clipboardSearchOpened: return "Поиск по буферу (⌃⌥V)"
        case .petPanelOpened: return "Позвал pet (⌥⇧Space)"
        case .petVoice: return "Говорил с pet голосом"
        case .petQuick: return "Быстрая команда pet (без модели)"
        case .petModel: return "Вопрос модели"
        case .petPlanRun: return "Выполнил план с файлами"
        case .petUndo: return "Отменил план"
        case .petMusic: return "Включил музыку через pet"
        case .petTag: return "@-тег плейлиста"
        case .petOfferShown: return "Pet предложил помощь"
        case .petOfferAccepted: return "Принял предложение pet"
        case .catPetted: return "Погладил кота"
        case .catSkinChanged: return "Сменил вид кота"
        case .agentPermissionAnswered: return "Ответил Claude из острова"
        case .settingsOpened: return "Открыл настройки"
        }
    }
}

/// Usage counters on this Mac (Application Support/NotchIsland/usage.json). Off with one switch.
@MainActor
final class Usage: ObservableObject {
    static let shared = Usage()
    @Published private(set) var log = UsageLog()
    private var saveWork: DispatchWorkItem?

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(UsageLog.self, from: data) {
            log = saved
        }
        log.prune()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Usage.shared.save() }
        }
    }

    static func track(_ event: UsageEvent) {
        guard AppSettings.shared.usageStats else { return }
        shared.log.record(event.rawValue)
        shared.scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func save() {
        if let data = try? JSONEncoder().encode(log) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    func reset() {
        log.reset()
        save()
    }

    /// Plain-text report to paste somewhere.
    func report(lastDays: Int) -> String {
        let totals = log.totals(lastDays: lastDays)
        var lines = ["NotchIsland — использование за \(lastDays) дн. (активных дней: \(log.activeDays(lastDays: lastDays)))"]
        for group in UsageEvent.Group.allCases {
            let events = UsageEvent.allCases.filter { $0.group == group }
            lines.append("\n\(group.rawValue)")
            for e in events.sorted(by: { (totals[$0.rawValue] ?? 0) > (totals[$1.rawValue] ?? 0) }) {
                lines.append("  \(totals[e.rawValue] ?? 0)\t\(e.title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct UsageSettings: View {
    @ObservedObject private var usage = Usage.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var window = 7
    @State private var copied = false

    var body: some View {
        let totals = usage.log.totals(lastDays: window)
        let used = UsageEvent.allCases.filter { (totals[$0.rawValue] ?? 0) > 0 }
            .sorted { (totals[$0.rawValue] ?? 0) > (totals[$1.rawValue] ?? 0) }
        let unused = UsageEvent.allCases.filter { (totals[$0.rawValue] ?? 0) == 0 }
        let top = max(1, used.first.map { totals[$0.rawValue] ?? 0 } ?? 1)

        Form {
            Section {
                Toggle("Считать, чем я пользуюсь", isOn: $settings.usageStats)
                Text("Только счётчики по дням — без названий файлов, треков и текста. Хранится на этом Mac и никуда не отправляется.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Период", selection: $window) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                }
                .pickerStyle(.segmented)
                Text("Активных дней: \(usage.log.activeDays(lastDays: window)) из \(window)").foregroundStyle(.secondary)
            }
            Section("Пользуюсь") {
                if used.isEmpty {
                    Text("Пока пусто — статистика появится по мере работы").foregroundStyle(.secondary)
                }
                ForEach(used, id: \.self) { e in
                    let n = totals[e.rawValue] ?? 0
                    HStack(spacing: 10) {
                        Text(e.title).lineLimit(1)
                        Spacer(minLength: 8)
                        GeometryReader { geo in
                            Capsule().fill(Color.accentColor.opacity(0.7))
                                .frame(width: max(3, geo.size.width * CGFloat(n) / CGFloat(top)))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(width: 120, height: 6)
                        Text("\(n)").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
            }
            Section("Ни разу за \(window) дн.") {
                Text(unused.map(\.title).joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(copied ? "Скопировано ✓" : "Скопировать отчёт") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(usage.report(lastDays: window), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    Spacer()
                    Button("Сбросить", role: .destructive) { usage.reset() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
