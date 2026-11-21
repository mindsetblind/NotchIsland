import AppKit
import SwiftUI

/// Small floating window under the notch: "Подключить «iPhone»?" with the 6-digit code to compare.
@MainActor
final class PortalPairingPanel {
    static let shared = PortalPairingPanel()

    final class Model: ObservableObject {
        @Published var device = ""
        @Published var code = ""
        @Published var waitingForPhone = false
        var onAllow: () -> Void = {}
        var onDeny: () -> Void = {}
    }

    private let model = Model()
    private var panel: NSPanel?

    func show(device: String, code: String, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void) {
        model.device = device
        model.code = code
        model.waitingForPhone = false
        model.onAllow = onAllow
        model.onDeny = onDeny
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 340, height: 230)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 48,
                              width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func waitForPhone() { model.waitingForPhone = true }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.becomesKeyOnlyIfNeeded = false
        p.contentView = NSHostingView(rootView: PairingView(model: model))
        return p
    }
}

/// Borderless panels refuse key status by default; this one needs Return / Esc.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct PairingView: View {
    @ObservedObject var model: PortalPairingPanel.Model

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Подключить «\(model.device)»?").font(.system(size: 14))
                Text("Отправлять файлы сможет только телефон с тем же кодом")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            Text(model.code)
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color(red: 0.56, green: 0.83, blue: 1))
                .accessibilityLabel("Код \(model.code)")
            if model.waitingForPhone {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Нажми «Совпадает» на iPhone").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(height: 28)
            } else {
                HStack(spacing: 10) {
                    Button("Отклонить") { model.onDeny() }
                        .keyboardShortcut(.cancelAction)
                    Button("Коды совпадают") { model.onAllow() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 340, height: 230)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
