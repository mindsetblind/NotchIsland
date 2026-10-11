import AppKit
import SwiftUI

/// Regular titled window hosting the settings (the island itself can't take keyboard input).
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: IslandModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Настройки NotchIsland"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 440))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Основные", systemImage: "gearshape") }
            PeekSettings().tabItem { Label("Уведомления", systemImage: "bell.badge") }
            MusicSettings(model: model).tabItem { Label("Музыка", systemImage: "music.note") }
            ToolSettings(model: model).tabItem { Label("Инструменты", systemImage: "wrench.and.screwdriver") }
            AboutSettings().tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
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
            Section("Клавиатура") {
                Toggle("⌥Space открывает и закрывает остров", isOn: $settings.hotKeyEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PeekSettings: View {
    @ObservedObject private var settings = AppSettings.shared

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
