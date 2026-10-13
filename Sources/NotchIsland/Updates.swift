import AppKit
import Sparkle
import SwiftUI

/// Automatic updates (Sparkle): NotchIsland checks the appcast on GitHub Releases once a day,
/// verifies the EdDSA signature of a new version and installs it. Feed and public key are in Info.plist.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController?

    private init() {
        // Only for the real app bundle (not `swift run` / debug captures).
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = bundled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var available: Bool { controller != nil }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        Section("Обновления") {
            if updates.available {
                Toggle("Проверять обновления автоматически", isOn: Binding(get: { updates.automaticallyChecks },
                                                                          set: { updates.automaticallyChecks = $0 }))
                Toggle("Устанавливать без вопросов", isOn: Binding(get: { updates.automaticallyInstalls },
                                                                   set: { updates.automaticallyInstalls = $0 }))
                    .disabled(!updates.automaticallyChecks)
                HStack {
                    Text("Версия \(updates.version)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Проверить сейчас") { updates.checkNow() }
                }
            } else {
                Text("Обновления работают в собранном приложении (NotchIsland.app).").foregroundStyle(.secondary)
            }
        }
    }
}
