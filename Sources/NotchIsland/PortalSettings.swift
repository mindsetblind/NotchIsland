import AppKit
import SwiftUI

/// Settings → Portal: receiving files from an iPhone.
struct PortalSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var portal: PortalService
    @State private var showToken = false

    var body: some View {
        Form {
            Section {
                Toggle("Принимать файлы с iPhone", isOn: $settings.portalEnabled)
                HStack {
                    Picker("Эффект у края экрана", selection: $settings.portalEffect) {
                        ForEach(PortalEffect.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Button("Показать") { PortalEffectController.shared.preview() }
                }
                HStack {
                    Text("Сохранять в")
                    Spacer()
                    Text(PortalService.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Выбрать…") { chooseFolder() }
                    if !settings.portalFolder.isEmpty {
                        Button("Сбросить") { settings.portalFolder = "" }
                    }
                }
            } header: {
                Text("Portal")
            } footer: {
                Text("Смахни фото вправо в приложении PortalCompanion на iPhone — оно прилетит на этот Mac, а у правого края экрана сыграет эффект. Mac виден для iPhone как «\(portal.macName)». При первом включении macOS спросит доступ к локальной сети.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if portal.connected.isEmpty && portal.trusted.isEmpty {
                    Text(settings.portalEnabled ? "Пока никого. Открой PortalCompanion на iPhone рядом." : "Portal выключен")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices, id: \.self) { name in
                    HStack {
                        Circle().fill(portal.connected.contains(name) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(name)
                        Text(portal.connected.contains(name) ? "подключено" : "разрешено")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if portal.trusted.contains(name) {
                            Button("Забыть") { portal.forget(name) }.buttonStyle(.borderless)
                        }
                    }
                }
                if let error = portal.lastError {
                    Text("Последняя ошибка: \(error)").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Устройства")
            } footer: {
                Text("Новое устройство отправляет файлы только после твоего «Разрешить». «Забыть» — спросит снова.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Принимать из «Быстрых команд» (HTTP)", isOn: $settings.portalHTTPEnabled)
                if settings.portalHTTPEnabled {
                    HStack {
                        Text("Порт")
                        Spacer()
                        TextField("", value: $settings.portalHTTPPort, format: .number.grouping(.never))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                    }
                    if !portal.httpStatus.isEmpty {
                        Text(portal.httpStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(portal.uploadURLs, id: \.self) { url in
                        HStack {
                            Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Скопировать")
                        }
                    }
                    HStack {
                        Text("Токен")
                        Spacer()
                        Text(showToken ? AppSettings.portalToken : String(repeating: "•", count: 16))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                        Button { copy(AppSettings.portalToken) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Скопировать токен")
                        Button("Новый") { settings.regeneratePortalToken() }
                            .help("Старые команды перестанут работать, пока не вставишь новый токен")
                    }
                }
            } header: {
                Text("Без приложения: «Быстрые команды»")
            } footer: {
                Text("Команда «Отправить в NotchIsland» в меню «Поделиться» на iPhone делает POST на адрес выше с заголовком Authorization: Bearer <токен>. Пошаговая инструкция — docs/portal.md. iPhone и Mac должны быть в одной сети Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var devices: [String] {
        portal.connected + portal.trusted.filter { !portal.connected.contains($0) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранять файлы, прилетевшие с iPhone"
        panel.directoryURL = PortalService.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.portalFolder = url.path
    }
}
