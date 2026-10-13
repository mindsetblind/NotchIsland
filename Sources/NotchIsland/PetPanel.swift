import AppKit
import NotchIslandCore
import SwiftUI
import UniformTypeIdentifiers

// ⌥⇧Space: the pet climbs out of the notch with a text field. Like the clipboard search it's a
// non-activating panel — it takes the keyboard without pulling NotchIsland to the front.

final class PetPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above the island panel, so it grows straight out of the notch over it.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    /// Clicking anywhere else puts the pet back, like Spotlight.
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Visual state of the panel (separate from the assistant, which lives on while it's hidden).
@MainActor
final class PetPanelState: ObservableObject {
    @Published var shown = false
    var notch = CGSize(width: 190, height: 32)
}

@MainActor
final class PetPanelController {
    static let shared = PetPanelController()

    static let contentWidth: CGFloat = 520
    static let topRadius: CGFloat = 10
    /// Room around the silhouette for its shadow.
    static let margin: CGFloat = 24

    private var panel: PetPanel?
    private let state = PetPanelState()
    private let assistant = PetAssistant.shared
    private var hideWork: DispatchWorkItem?
    /// Screen and notch of the island, from the app delegate.
    var placement: () -> (screen: NSScreen, notch: CGSize)? = { nil }

    var isOpen: Bool { assistant.isOpen }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let (screen, notch) = placement() else { return }
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.notch = notch
        assistant.setOpen(true)
        resize(height: panel.frame.height, on: screen)
        panel.makeKeyAndOrderFront(nil)
        // Next runloop: let SwiftUI lay out the collapsed silhouette first, then grow.
        DispatchQueue.main.async { [state] in
            withAnimation(IslandModel.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78)) {
                state.shown = true
            }
        }
    }

    func close() {
        guard assistant.isOpen else { return }
        assistant.setOpen(false)
        withAnimation(IslandModel.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.9)) {
            state.shown = false
        }
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    private func makePanel() -> PetPanel {
        let panel = PetPanel()
        let view = PetPanelView(assistant: assistant, state: state, close: { [weak self] in self?.close() },
                                heightChanged: { [weak self] h in
                                    guard let self, let screen = self.placement()?.screen else { return }
                                    self.resize(height: h + Self.margin, on: screen)
                                })
        panel.contentView = NSHostingView(rootView: view)
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            // The first time, macOS asks for the microphone: its dialog takes focus — stay open.
            if self.assistant.voice.askingPermission { return }
            self.close()
        }
        panel.onEscape = { [weak self] in self?.escape() }
        return panel
    }

    func escape() {
        if assistant.isListening { return assistant.cancelListening() }
        // Like Spotlight: esc first clears what's there, then closes.
        switch assistant.phase {
        case .thinking: assistant.cancelThinking()
        case _ where !assistant.query.isEmpty: assistant.query = ""
        case .input: close()
        default: assistant.reset()
        }
    }

    /// Top edge flush with the top of the screen, centred on the notch.
    private func resize(height: CGFloat, on screen: NSScreen) {
        guard let panel else { return }
        let width = Self.contentWidth + Self.topRadius * 2 + Self.margin * 2
        let frame = NSRect(x: (screen.frame.midX - width / 2).rounded(), y: screen.frame.maxY - height,
                           width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

// MARK: - View

struct PetPanelView: View {
    @ObservedObject var assistant: PetAssistant
    @ObservedObject var state: PetPanelState
    @ObservedObject private var settings = AppSettings.shared
    let close: () -> Void
    let heightChanged: (CGFloat) -> Void

    @FocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 120
    @State private var dropTargeted = false

    private let t = PetPanelController.topRadius

    var body: some View {
        let w = PetPanelController.contentWidth + t * 2
        let shown = state.shown
        // Same trick as the island: the content is laid out once at its final size and the black
        // silhouette grows over it from the size of the notch.
        content
            .frame(width: w, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                contentHeight = h
                heightChanged(h)
            }
            .opacity(shown ? 1 : 0)
            .animation(shown ? .easeOut(duration: 0.2).delay(0.08) : .easeOut(duration: 0.08), value: shown)
            .frame(width: shown ? w : state.notch.width + t * 2,
                   height: shown ? contentHeight : state.notch.height, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: t, bottomRadius: shown ? 26 : 10))
            .shadow(color: .black.opacity(shown ? 0.45 : 0), radius: 14, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                load(providers)
                return true
            }
            .onChange(of: state.shown) { _, on in if on { focused = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: max(state.notch.height - 6, 0))   // the menu bar strip
            header
            if hasChips { chips }
            if !assistant.suggestions.isEmpty {
                suggestionList
            } else {
                phaseView(assistant.phase)
                if showsQuickPicks { quickPicks }
            }
            footer
        }
        .padding(.horizontal, t + 16)
        .padding(.bottom, 14)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(.horizontal, t + 6).padding(.top, state.notch.height).padding(.bottom, 6)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            PetView(mood: assistant.mood, size: 20)
            TextField("", text: $assistant.query,
                      prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { assistant.submit() }
                .onKeyPress(.escape) { PetPanelController.shared.escape(); return .handled }
                .onKeyPress(.downArrow) { suggest { assistant.moveSuggestion(1) } }
                .onKeyPress(.upArrow) { suggest { assistant.moveSuggestion(-1) } }
                .onKeyPress(.tab) { suggest { assistant.submit() } }
                .onChange(of: assistant.query) { _, _ in assistant.suggestionIndex = 0 }
                .disabled(assistant.phase == .thinking)
                .accessibilityLabel("Запрос для pet")
            if settings.petVoice && assistant.phase != .thinking {
                micButton
            }
            if assistant.phase != .input && assistant.phase != .thinking && !assistant.isListening {
                Button { assistant.reset() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.35))
                .help("Очистить")
                .accessibilityLabel("Очистить")
            }
        }
        .frame(height: 30)
    }

    /// Click to talk (same as holding ⌥⇧Space); while listening it shows the voice level.
    private var micButton: some View {
        Button {
            assistant.isListening ? assistant.stopListening() : assistant.startListening()
        } label: {
            Group {
                if assistant.isListening {
                    Image(systemName: "waveform", variableValue: assistant.voice.level)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "mic.fill").foregroundStyle(.white.opacity(0.35))
                }
            }
            .font(.system(size: 14, weight: .medium))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(assistant.isListening ? "Закончить и отправить" : "Сказать голосом (или держи ⌥⇧Space)")
        .accessibilityLabel(assistant.isListening ? "Закончить и отправить" : "Сказать голосом")
    }

    /// Arrow keys and Tab belong to the "@" list while it's showing.
    private func suggest(_ action: () -> Void) -> KeyPress.Result {
        guard !assistant.suggestions.isEmpty else { return .ignored }
        action()
        return .handled
    }

    private var placeholder: String {
        if assistant.isListening { return "Слушаю…" }
        if assistant.context.music != nil && assistant.phase == .input {
            return "⏎ — включить, или скажи, что выбрать"
        }
        switch assistant.phase {
        case .thinking: return "Думаю…"
        case .plan: return assistant.planIsRunnable ? "⏎ — выполнить, или уточни запрос" : "Спроси что-нибудь ещё"
        default: return "Что сделать? Файлы или музыка"
        }
    }

    // MARK: Context chips

    private var hasChips: Bool {
        assistant.context.folder != nil || !assistant.context.files.isEmpty || assistant.context.music != nil
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let source = assistant.context.music {
                chip(icon: source.icon, source.name, tint: .green) { assistant.clearMusic() }
            }
            if let folder = assistant.context.folder {
                chip(icon: "folder.fill", Self.display(folder)) { assistant.clearFolder() }
            }
            let files = assistant.context.files
            if files.count == 1 {
                chip(icon: "doc.fill", files[0].lastPathComponent) { assistant.removeFile(files[0]) }
            } else if files.count > 1 {
                chip(icon: "doc.on.doc.fill", "\(files.count) \(Self.files(files.count))") {
                    files.forEach(assistant.removeFile)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(icon: String, _ title: String, tint: Color = .white.opacity(0.6),
                      remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9.5)).foregroundStyle(tint)
            Text(title.count > 30 ? title.prefix(16) + "…" + title.suffix(12) : title)
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityLabel("Убрать \(title)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(tint == .green ? Color.green.opacity(0.22) : .white.opacity(0.1)))
        .fixedSize()
    }

    // MARK: Spotify tags

    private var showsQuickPicks: Bool {
        assistant.phase == .input && assistant.query.isEmpty && assistant.context.music == nil
            && !assistant.quickSources.isEmpty
    }

    /// One tap attaches a source: Liked Songs and your first playlists.
    private var quickPicks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                    .padding(.trailing, 2)
                ForEach(assistant.quickSources) { source in
                    Button { assistant.pick(source) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: source.icon).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.55))
                            Text(source.name.count > 26 ? source.name.prefix(24) + "…" : source.name)
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(source.subtitle)
                }
            }
            .padding(.vertical, 1)   // room for the outlines
            .padding(.trailing, 24)
        }
        // Long rows fade out at the right edge instead of being cut.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }

    /// "@…" typed: matching playlists, albums and Liked Songs (six rows visible, the rest scrolls).
    private var suggestionList: some View {
        let list = assistant.suggestions
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, source in
                        HStack(spacing: 8) {
                            Image(systemName: source.icon).font(.system(size: 11))
                                .foregroundStyle(source.kind == .liked ? .green : .white.opacity(0.6)).frame(width: 18)
                            Text(source.name).font(.system(size: 12.5)).lineLimit(1)
                            Text(source.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 25)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(i == assistant.suggestionIndex ? 0.13 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { assistant.pick(source) }
                        .id(source.id)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: CGFloat(min(list.count, 6)) * 26)
            .onChange(of: assistant.suggestionIndex) { _, i in
                guard list.indices.contains(i) else { return }
                proxy.scrollTo(list[i].id)
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private func phaseView(_ phase: PetAssistant.Phase) -> some View {
        switch phase {
        case .input:
            EmptyView()
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("«\(assistant.asked)»").lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 12))
        case .plan(let plan, let issues):
            planView(plan, issues: issues)
        case .done(let text, _):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
        case .playing(let text):
            HStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
        case .failed(let message):
            Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 12.5))
        case .notLoggedIn:
            VStack(alignment: .leading, spacing: 8) {
                Text("Pet думает с помощью Claude Code, а он ещё не авторизован. Один раз выполни в Терминале:")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("claude auth login").font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
                    Button("Скопировать") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude auth login", forType: .string)
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private func planView(_ plan: PetPlan, issues: [PetIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !plan.reply.isEmpty {
                Text(plan.reply).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.files.isEmpty || !plan.actions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(plan.files.enumerated()), id: \.offset) { _, path in fileRow(path) }
                        ForEach(Array(plan.actions.enumerated()), id: \.offset) { i, action in
                            actionRow(action, issue: issues.first { $0.index == i })
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: min(CGFloat(plan.files.count + plan.actions.count) * 26, 260))
            }
        }
    }

    private func fileRow(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        return HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
            Text(url.lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
            Text(Self.short(url.deletingLastPathComponent().path)).font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .frame(height: 25)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url); close() }
        .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        .contextMenu {
            Button("Открыть") { NSWorkspace.shared.open(url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help("Клик — показать в Finder, двойной — открыть")
    }

    private func actionRow(_ a: PetAction, issue: PetIssue?) -> some View {
        let (icon, text) = Self.describe(a)
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 18)
                .foregroundStyle(a.kind == .trash ? .red.opacity(0.85) : .white.opacity(0.6))
            Text(text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let issue {
                Text(issue.message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .frame(height: 25)
        .padding(.horizontal, 6)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch assistant.phase {
            case .thinking:
                hint("esc — отменить")
            case _ where assistant.isListening:
                hint("Отпусти ⌥⇧Space — и я сделаю · esc — отменить")
                Spacer()
            case .input where !assistant.suggestions.isEmpty:
                hint("↑↓ — выбрать · ⏎ или tab — прикрепить")
                Spacer()
            case .input:
                hint(assistant.musicSources.isEmpty ? "⏎ — спросить · перетащи файлы сюда · esc — закрыть"
                                                    : "⏎ — спросить · @ — плейлисты Spotify · esc — закрыть")
                Spacer()
                hint(settings.petProvider == .claude ? "Claude Code · \(settings.petModel.capitalized)" : settings.petProvider.short)
            case .plan(let plan, let issues):
                if !issues.isEmpty {
                    hint("Часть шагов не выйдет — уточни запрос")
                } else if plan.actions.contains(where: \.modifies) {
                    hint("Можно будет отменить")
                } else {
                    hint("esc — очистить")
                }
                Spacer()
                if issues.isEmpty && !plan.actions.isEmpty {
                    Button("Отмена") { assistant.dismissPlan() }.buttonStyle(PetButtonStyle(primary: false))
                    Button(plan.actions.contains(where: \.modifies) ? "Выполнить" : "Показать") { assistant.execute() }
                        .buttonStyle(PetButtonStyle(primary: true))
                }
            case .done(_, let canUndo):
                if canUndo {
                    Button("Отменить") { assistant.undo() }
                        .buttonStyle(PetButtonStyle(primary: false))
                        .keyboardShortcut("z", modifiers: .command)
                }
                Spacer()
            default:
                hint("esc — очистить")
                Spacer()
            }
        }
        .frame(minHeight: 22)
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
    }

    // MARK: Helpers

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { assistant.addFiles([url]) }
            }
        }
    }

    static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Finder's name for a folder: "Рабочий стол", not "Desktop".
    static func display(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path) }

    static func files(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "файл" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "файла" }
        return "файлов"
    }

    /// Icon and one-line description: "a.png → Скриншоты/", "старое.txt → новое.txt"…
    static func describe(_ a: PetAction) -> (String, String) {
        let src = URL(fileURLWithPath: a.path)
        let name = src.lastPathComponent
        let dst = a.to.map(URL.init(fileURLWithPath:))
        switch a.kind {
        case .mkdir: return ("folder.badge.plus", "Новая папка «\(name)» в «\(display(src.deletingLastPathComponent()))»")
        case .trash: return ("trash", "\(name) → Корзина")
        case .open: return ("arrow.up.forward.app", "Открыть \(name)")
        case .reveal: return ("magnifyingglass", "Показать \(name) в Finder")
        case .zip: return ("doc.zipper", "Сжать \(name) → \(dst?.lastPathComponent ?? "?")")
        case .copy, .move:
            guard let dst else { return ("arrow.right", name) }
            let sameFolder = dst.deletingLastPathComponent() == src.deletingLastPathComponent()
            if a.kind == .move && sameFolder { return ("pencil", "\(name) → \(dst.lastPathComponent)") }
            let folder = display(dst.deletingLastPathComponent()) + "/"
            let target = dst.lastPathComponent == name ? folder : folder + dst.lastPathComponent
            return (a.kind == .copy ? "doc.on.doc" : "arrow.right", "\(name) → \(target)")
        }
    }
}

struct PetButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? .black : .white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(primary ? .white : .white.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
