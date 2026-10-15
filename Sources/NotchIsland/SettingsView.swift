import AppKit
import NotchIslandCore
import SwiftUI

/// Regular titled window hosting the settings (the island itself can't take keyboard input).
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: IslandModel) {
        if window == nil {
            let w = EditableWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Настройки NotchIsland"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 500))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A window whose text fields get ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z without a menu bar (see EditShortcuts).
final class EditableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || EditShortcuts.handle(event)
    }
}

struct SettingsView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Основные", systemImage: "gearshape") }
            PetSettings().tabItem { Label("Pet", systemImage: "pawprint") }
            PeekSettings(calendar: model.calendar).tabItem { Label("Уведомления", systemImage: "bell.badge") }
            MusicSettings(model: model).tabItem { Label("Музыка", systemImage: "music.note") }
            ClipboardSettings(history: model.clipboard).tabItem { Label("Буфер", systemImage: "doc.on.clipboard") }
            ClaudeSettings().tabItem { Label("Claude Code", systemImage: "eyes") }
            DeveloperSettings().tabItem { Label("Разработка", systemImage: "hammer") }
            ToolSettings(model: model).tabItem { Label("Инструменты", systemImage: "wrench.and.screwdriver") }
            UsageSettings().tabItem { Label("Статистика", systemImage: "chart.bar") }
            AboutSettings().tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 500)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.setEnabled(on) }
            }
            UpdateSettings()
            Section("Остров") {
                Picker("Раскрывать", selection: $settings.openMode) {
                    ForEach(AppSettings.OpenMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.openMode == .click
                     ? "При наведении остров слегка приподнимается, раскрывается по клику."
                     : "Остров раскрывается сам, когда задерживаешь на нём курсор.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Строка меню") {
                Toggle("Уступать место длинному меню приложений", isOn: $settings.freeMenuBar)
                    .onChange(of: settings.freeMenuBar) { _, _ in MenuBarWatcher.shared.check() }
                if settings.freeMenuBar {
                    if MenuBarWatcher.shared.hasAccess {
                        Text("Когда меню активного приложения доходит до острова (Xcode, Photoshop…), остров сжимается до выреза и возвращается, когда меню короче.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Без доступа работает по списку известных приложений. С «Универсальным доступом» NotchIsland сам видит, где кончается меню любого приложения (только позиции пунктов меню).")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Разрешить…") { MenuBarWatcher.shared.askForAccess() }
                        }
                    }
                }
            }
            Section("Клавиатура") {
                Toggle("⌥Space открывает и закрывает остров", isOn: $settings.hotKeyEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct PeekSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var calendar: CalendarMonitor

    var body: some View {
        Form {
            Section("Пока остров свёрнут") {
                Toggle("Обложка и эквалайзер, когда играет музыка", isOn: $settings.showCompactMusic)
                Toggle("Таймер помидора", isOn: $settings.showCompactPomodoro)
            }
            Section("Короткие уведомления у выреза") {
                Toggle("Подключение зарядки", isOn: $settings.showChargingPeek)
                Toggle("Bluetooth-устройства (AirPods, клавиатуры…)", isOn: $settings.showBluetoothPeek)
                Toggle("Флешки и внешние диски", isOn: $settings.showDrivePeek)
                ForEach(AlertToggle.all, id: \.kind) { item in
                    Toggle(item.title, isOn: Binding(get: { settings.isActivityEnabled(item.kind) },
                                                     set: { settings.setActivity(item.kind, enabled: $0) }))
                }
            }
            Section {
                Toggle("Завершённые загрузки в папке «Загрузки»", isOn: $settings.downloadsWatchEnabled)
                Toggle("Ближайшие события календаря", isOn: $settings.calendarEnabled)
                if settings.calendarEnabled {
                    Picker("Напоминать за", selection: $settings.calendarLeadMinutes) {
                        ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) мин").tag($0) }
                    }
                    if calendar.access == .denied {
                        HStack {
                            Text("Нет доступа к календарю").foregroundStyle(.secondary)
                            Spacer()
                            Button("Открыть настройки") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("С разрешением macOS")
            } footer: {
                Text("macOS спросит доступ к папке «Загрузки» или к календарю при включении. Данные читаются только на этом Mac. Индикаторы камеры, микрофона и записи экрана остров не дублирует: их надёжно показывает сама macOS в строке меню, а для записи экрана публичного API нет.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(settings.liveActivityOrder.enumerated()), id: \.element) { index, kind in
                    HStack {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(Self.title(kind))
                        Spacer()
                        Button { settings.moveLiveActivity(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0)
                            .accessibilityLabel("Выше")
                        Button { settings.moveLiveActivity(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == settings.liveActivityOrder.count - 1)
                            .accessibilityLabel("Ниже")
                    }
                }
            } header: {
                Text("Что показывать, если идёт несколько дел сразу")
            } footer: {
                Text("Свёрнутый остров показывает верхнее из идущих сейчас. Короткие уведомления появляются поверх на несколько секунд, по очереди, и остров возвращается к нему.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Alert kinds with a plain on/off switch (the older ones above have their own settings keys).
struct AlertToggle {
    let kind: ActivityKind
    let title: String
    static let all = [
        AlertToggle(kind: .battery, title: "Низкий заряд аккумулятора"),
        AlertToggle(kind: .disk, title: "Мало места на диске (меньше 10 и 5 ГБ)"),
        AlertToggle(kind: .color, title: "Пипетка: цвет скопирован"),
        AlertToggle(kind: .clipboard, title: "Буфер: скопировано из истории"),
    ]
}

extension PeekSettings {
    static func title(_ kind: ActivityKind) -> String {
        switch kind {
        case .pomodoro: return "Помидор"
        case .agent: return "Claude Code работает"
        case .developer: return "Задачи разработчика (сборки, тесты)"
        case .music: return "Музыка"
        default: return kind.rawValue
        }
    }
}

private struct ClipboardSettings: View {
    @ObservedObject var history: ClipboardHistory
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Вести историю буфера обмена", isOn: $settings.clipboardEnabled)
                Toggle("Пауза — временно ничего не записывать", isOn: $settings.clipboardPaused)
                    .disabled(!settings.clipboardEnabled)
                Toggle("⌃⌥V открывает поиск по истории", isOn: $settings.clipboardHotKey)
                    .disabled(!settings.clipboardEnabled)
            } footer: {
                Text("Сохраняются только текст и ссылки — не файлы и не картинки. Всё хранится только на этом Mac, никуда не отправляется.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Хранение") {
                Picker("Сколько записей", selection: $settings.clipboardMaxItems) {
                    ForEach([20, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Как долго", selection: $settings.clipboardMaxAgeDays) {
                    Text("1 день").tag(1)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("Без срока").tag(0)
                }
                Toggle("Хранить между перезапусками", isOn: $settings.clipboardPersist)
                LabeledContent("Сейчас в истории", value: "\(history.store.items.count) (закреплено \(history.store.items.filter(\.pinned).count))")
                HStack {
                    Spacer()
                    Button("Очистить, кроме закреплённых") { history.store.clearUnpinned() }
                        .disabled(history.store.items.isEmpty)
                    Button("Удалить всю историю…", role: .destructive) { history.confirmClearAll() }
                        .disabled(history.store.items.isEmpty)
                }
            }
            Section {
                Toggle("Пропускать вероятные пароли и токены", isOn: $settings.clipboardSkipSecrets)
                if history.skippedSecrets > 0 {
                    LabeledContent("Пропущено с момента запуска", value: "\(history.skippedSecrets)")
                }
            } header: {
                Text("Безопасность")
            } footer: {
                Text("Всегда пропускается то, что менеджеры паролей помечают как скрытое (1Password, Bitwarden, KeePassXC и другие), и всё, что скопировано, пока они на переднем плане. Дополнительно эвристика узнаёт частые форматы ключей (GitHub, Slack, AWS, OpenAI…), JWT, «password=…», ссылки с паролем и случайные строки — но не любой секрет. Закреплённые записи не удаляются по сроку. Файл: ~/Library/Application Support/NotchIsland/clipboard-history.json, доступен только твоей учётной записи.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MusicSettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var clientID = ""

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientID, prompt: Text("из developer.spotify.com"))
                    .onSubmit { model.setSpotifyClientID(clientID) }
                HStack {
                    if model.spotifyLoggedIn {
                        Label("Вход выполнен", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Выйти") { model.spotifyLogout() }
                    } else {
                        Text(model.spotifyHasClientID ? "Не выполнен вход" : "Сначала укажи Client ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Войти в Spotify") {
                            model.setSpotifyClientID(clientID)
                            model.spotifyLogin()
                        }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Spotify")
            } footer: {
                Text("Нужен для списка треков плейлиста. Redirect URI в настройках приложения Spotify: \(SpotifyWeb.redirectURI)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Заглушка вместо обложки") {
                HStack(spacing: 14) {
                    Group {
                        if let picture = settings.placeholderPicture {
                            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay(Image(systemName: "music.note").foregroundStyle(.white))
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Выбрать картинку…") { settings.choosePlaceholder() }
                        if settings.hasCustomPlaceholder {
                            Button("Сбросить") { settings.resetPlaceholder() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { clientID = model.spotify.clientID ?? "" }
    }
}

private struct ClaudeSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var installed = ClaudeHooks.isInstalled

    var body: some View {
        Form {
            Section {
                HStack {
                    if installed {
                        Label("Подключено", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Отключить…") { ClaudeHooks.uninstall(); installed = ClaudeHooks.isInstalled }
                    } else {
                        Text("Не подключено").foregroundStyle(.secondary)
                        Spacer()
                        Button("Подключить…") { ClaudeHooks.install(); installed = ClaudeHooks.isInstalled }
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Добавляет хуки в \(ClaudeHooks.settingsURL.path) (с резервной копией). Остров показывает сессии и их действия, «готово» и «ждёт ответа». Если остров не запущен, Claude Code работает как обычно.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Спрашивать разрешения в острове", isOn: $settings.claudePermissionsInIsland)
                Toggle("Звуки (запрос разрешения, готово)", isOn: $settings.claudeSounds)
            } footer: {
                Text("Если выключить разрешения, Claude Code будет спрашивать их в терминале, а остров — только показывать статус.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { installed = ClaudeHooks.isInstalled }
    }
}

private struct DeveloperSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var copied = false

    private var linkCommand: String { "ln -sf '\(DeveloperMonitor.cliPath)' /usr/local/bin/notchisland-cli" }

    var body: some View {
        Form {
            Section {
                Toggle("Developer Mode — показывать сборки, тесты и скрипты", isOn: $settings.developerModeEnabled)
                Toggle("Звук при ошибке", isOn: $settings.developerSounds)
                    .disabled(!settings.developerModeEnabled)
                Picker("Предупредить, если задача идёт дольше", selection: $settings.developerLongTaskMinutes) {
                    Text("5 мин").tag(5)
                    Text("10 мин").tag(10)
                    Text("30 мин").tag(30)
                    Text("Не предупреждать").tag(0)
                }
                .disabled(!settings.developerModeEnabled)
            } footer: {
                Text("Пока идёт задача, свёрнутый остров показывает её с таймером; по завершении — «готово» или ошибку. Серверы показываются только при запуске и остановке.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Команда") {
                    Text(DeveloperMonitor.cliPath).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Text("Чтобы вызывать как `notchisland-cli`, создай ссылку в Терминале:").font(.callout)
                    Spacer()
                    Button(copied ? "Скопировано" : "Скопировать команду") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(linkCommand, forType: .string)
                        copied = true
                    }
                }
                Text("notchisland-cli run --category build -- swift build\nnotchisland-cli start deploy --title \"Деплой\" && … && notchisland-cli finish deploy --exit-code $?")
                    .font(.caption.monospaced()).textSelection(.enabled)
            } header: {
                Text("Как сообщать о задачах")
            } footer: {
                Text("События идут через локальный Unix-сокет, доступный только твоей учётной записи; сетевого сервера нет. Остров только показывает события и никогда ничего не выполняет по ним. Если остров не запущен, команда тихо ничего не делает. Формат событий для своих скриптов — docs/developer-mode.md в репозитории.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolSettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var pomodoro: Pomodoro
    @State private var mediaKeysBlocked = CleaningMode.shared.blocksMediaKeys

    init(model: IslandModel) {
        self.model = model
        pomodoro = model.pomodoro
    }

    var body: some View {
        Form {
            Section("Помидор") {
                Picker("Цикл (фокус / перерыв / длинный)", selection: Binding(
                    get: { pomodoro.preset.focus },
                    set: { focus in
                        if let p = PomodoroPreset.all.first(where: { $0.focus == focus }) { pomodoro.setPreset(p) }
                    })) {
                    ForEach(PomodoroPreset.all, id: \.focus) { Text($0.label).tag($0.focus) }
                }
                LabeledContent("Сегодня завершено", value: "\(pomodoro.completedToday) 🍅")
            }
            Section("Чистка") {
                Picker("Длительность по клику", selection: $settings.cleaningDuration) {
                    ForEach(CleaningMode.durations, id: \.self) { d in
                        Text(d < 60 ? "\(Int(d)) с" : "\(Int(d / 60)) мин").tag(d)
                    }
                }
                HStack {
                    if mediaKeysBlocked {
                        Label("Клавиши яркости и громкости тоже блокируются", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Клавиши яркости и громкости продолжают работать")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Разрешить блокировку…") { CleaningMode.requestMediaKeyBlocking() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Re-check after the user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mediaKeysBlocked = CleaningMode.shared.blocksMediaKeys
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("NotchIsland").font(.title2.weight(.semibold))
            Text("Версия \(version)").foregroundStyle(.secondary)
            Link("github.com/mindsetblind/NotchIsland", destination: URL(string: "https://github.com/mindsetblind/NotchIsland")!)
            Button("Открыть папку с логом") {
                let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
                let log = logs.appendingPathComponent("NotchIsland.log")
                if FileManager.default.fileExists(atPath: log.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                } else {
                    NSWorkspace.shared.open(logs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Looks of the cat as tiles with a live preview (each tile shows its own skin).
struct CatSkinPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CatSkin.all) { skin in
                Button { selection = skin.id } label: {
                    VStack(spacing: 6) {
                        CatSkinPreview(skinID: skin.id)
                            .frame(width: 96, height: 64)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(selection == skin.id ? Color.accentColor : .clear, lineWidth: 2))
                        Text(skin.title).font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Вид кота: \(skin.title)")
                .accessibilityAddTraits(selection == skin.id ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// A still cat in a given skin (the island's own cat follows the setting).
private struct CatSkinPreview: View {
    let skinID: String

    var body: some View {
        Image(nsImage: CatNSView.still(mood: .idle, pointsPerCSSPixel: 1.25, skin: CatSkin.named(skinID)))
    }
}

/// Everything about the cat: its look, its behaviour, and the assistant.
private struct PetSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Кот") {
                CatSkinPicker(selection: $settings.catSkin)
                Toggle("Аксессуары по ситуации", isOn: $settings.petAccessories)
                    .help("Очки во время сборок и работы Claude, колпак во сне, шапки по сезону")
                Toggle("Всегда виден справа от выреза", isOn: $settings.petAlwaysVisible)
                Toggle("Засыпает ночью (с 1 до 6)", isOn: $settings.petSleepsAtNight)
                    .disabled(!settings.petAlwaysVisible)
                Text("Следит за курсором, танцует под музыку, «думает», пока работает Claude Code, зовёт, когда он ждёт ответа, и засыпает, если долго не трогать Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Помощник") {
                Toggle("Вызывать по ⌥⇧Space", isOn: $settings.petHotKeyEnabled)
                Toggle("Голос: удерживай ⌥⇧Space и говори", isOn: $settings.petVoice)
                Toggle("Сам предлагает помощь", isOn: $settings.petSuggestions)
                if settings.petSuggestions {
                    Text("Изредка (не чаще раза в 3 часа) смотрит на Загрузки и Рабочий стол и предлагает в острове разобрать завалы. Ничего не делает без твоего подтверждения.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                PetBrainSettings()
                Text("Pet вылезает из выреза и помогает с файлами: найти, разложить по папкам, переименовать, сжать, убрать в Корзину. А ещё включает музыку в Spotify по просьбе — «включи Radiohead», «что-нибудь для работы»; через @ можно указать плейлист или альбом из медиатеки (нужен вход в Spotify во вкладке «Музыка»). Думает через выбранную модель, сам ничего не меняет — сначала показывает план, а сделанное можно отменить. Работает только в домашней папке, кроме ~/Library и скрытых файлов.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
