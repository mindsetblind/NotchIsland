import AppKit
import Combine
import NotchIslandCore
import SwiftUI

/// Developer Mode: long-running tasks (builds, tests, scripts, local servers) reported by
/// `notchisland-cli` or any script over the local socket. Optional and off by default.
///
/// While something runs, the collapsed island shows it with a timer; when it finishes the island
/// says how it ended. Local servers only announce start/stop — they run for hours and would
/// otherwise occupy the island permanently.
@MainActor
final class DeveloperMonitor: ObservableObject {
    let tracker = DevTaskTracker()
    private let settings: AppSettings
    private weak var model: IslandModel?
    private var ticker: Timer?
    private var observers: [AnyCancellable] = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func attach(to model: IslandModel) {
        self.model = model
        tracker.longRunningAfter = settings.developerLongTaskMinutes > 0 ? TimeInterval(settings.developerLongTaskMinutes * 60) : nil
        observers = [
            tracker.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncLive() } }
            },
            settings.$developerModeEnabled.removeDuplicates().sink { [weak self] on in
                DispatchQueue.main.async { MainActor.assumeIsolated { if !on { self?.disable() } } }
            },
            settings.$developerLongTaskMinutes.sink { [weak self] minutes in
                self?.tracker.longRunningAfter = minutes > 0 ? TimeInterval(minutes * 60) : nil
            },
        ]
    }

    var isEnabled: Bool { settings.developerModeEnabled }

    /// Handles one socket message; the answer goes back to the sender so scripts can report mistakes.
    func receive(_ data: Data, connection fd: Int32) {
        defer { close(fd) }
        guard isEnabled else {
            HookSocketServer.reply(fd, ["ok": false, "error": "Developer Mode is off (NotchIsland → Настройки → Разработка)"])
            return
        }
        let event: DevEvent
        do {
            event = try DevEventParser.parse(data)
        } catch let error as DevEventError {
            HookSocketServer.reply(fd, ["ok": false, "error": error.description])
            return
        } catch {
            HookSocketServer.reply(fd, ["ok": false, "error": "invalid event"])
            return
        }
        let change = tracker.handle(event)
        if case .ignored(let why) = change {
            HookSocketServer.reply(fd, ["ok": false, "error": "ignored: \(why)"])
            return
        }
        HookSocketServer.reply(fd, ["ok": true])
        announce(change)
        updateTicker()
    }

    // MARK: Island

    private func announce(_ change: DevTaskTracker.Change) {
        guard let model else { return }
        switch change {
        case .started(let t) where t.category == .server:
            model.post(.developer, t.id, .notice(Notice(symbol: "server.rack", tint: .green, title: t.title,
                                                       detail: "запущен", tab: .agents)), duration: 3)
        case .finished(let t) where t.category == .server:
            model.post(.developer, t.id, .notice(Notice(symbol: "server.rack", tint: t.state == .failure ? .red : .white,
                                                       title: t.title, detail: t.state == .failure ? "упал" : "остановлен",
                                                       tab: .agents)), duration: 3.5)
            if t.state == .failure { playFailureSound() }
        case .finished(let t):
            let duration = formatElapsed(t.duration(at: Date()))
            let notice: Notice
            switch t.state {
            case .success:
                notice = Notice(symbol: "checkmark.circle.fill", tint: .green, title: t.title, detail: duration, tab: .agents)
            case .failure:
                notice = Notice(symbol: "xmark.octagon.fill", tint: .red, title: t.title,
                                detail: t.message ?? t.exitCode.map { "код \($0)" } ?? "ошибка", tab: .agents)
                playFailureSound()
            case .cancelled, .running:
                notice = Notice(symbol: "stop.circle", tint: .white, title: t.title, detail: "отменено", tab: .agents)
            }
            model.post(.developer, t.id, .notice(notice), duration: t.state == .failure ? 5 : 3.5)
            // The cat shares the moment once the alert has gone: a cheer or a sulk.
            if t.state == .success { model.react(.happy, for: 2.5, after: 3.5) }
            if t.state == .failure { model.react(.sad, for: 3, after: 5) }
        case .takingLong(let t):
            model.post(.developer, t.id, .notice(Notice(symbol: "hourglass", tint: .orange, title: t.title,
                                                       detail: "уже " + formatElapsed(t.duration(at: Date())), tab: .agents)),
                       duration: 4)
        default:
            break
        }
    }

    /// The compact island shows running tasks (servers excluded) as one live activity.
    private func syncLive() {
        guard let model else { return }
        let running = tracker.running.filter { $0.category != .server }
        guard isEnabled, let first = running.first else {
            model.setLive(.developer, "tasks", nil)
            return
        }
        let title = running.count == 1 ? first.title : "\(first.title) +\(running.count - 1)"
        let symbol: String
        switch first.category {
        case .build: symbol = "hammer.fill"
        case .test: symbol = "checklist"
        case .deploy: symbol = "icloud.and.arrow.up"
        default: symbol = "terminal.fill"
        }
        model.setLive(.developer, "tasks", .notice(Notice(symbol: symbol, title: title, startedAt: first.startedAt,
                                                          spinning: true, tab: .agents)))
    }

    private func updateTicker() {
        let needed = !tracker.running.isEmpty
        if needed, ticker == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 5
            ticker = t
        } else if !needed {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        for change in tracker.tick() { announce(change) }
        updateTicker()
    }

    private func disable() {
        tracker.clearFinished()
        for t in tracker.running { tracker.remove(t.id) }
        model?.setLive(.developer, "tasks", nil)
        model?.activities.dismissAll(.developer)
        updateTicker()
    }

    private func playFailureSound() {
        guard settings.developerSounds else { return }
        NSSound(named: "Basso")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Path of the bundled command-line helper.
    static var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notchisland-cli").path }
}

// MARK: - Rows in the Agents tab

struct DevTaskRow: View {
    @ObservedObject var tracker: DevTaskTracker
    let task: DevTask
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if task.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(formatElapsed(task.duration(at: ctx.date)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(formatElapsed(task.duration(at: Date())))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Скопировать сообщение") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString([task.title, task.message].compactMap { $0 }.joined(separator: " — "), forType: .string)
            }
            Button("Убрать из списка") { tracker.remove(task.id) }
            Button("Убрать завершённые") { tracker.clearFinished() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(stateText)")
    }

    private var stateText: String {
        switch task.state {
        case .running: return "выполняется"
        case .success: return "готово"
        case .failure: return "ошибка"
        case .cancelled: return "отменено"
        }
    }

    private var subtitle: String {
        var parts = [stateText]
        if let p = task.progress, task.isRunning { parts.append("\(Int(p * 100))%") }
        if let m = task.message { parts.append(m) }
        if let code = task.exitCode, task.state == .failure, task.message == nil { parts.append("код \(code)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var icon: some View {
        switch task.state {
        case .running:
            if let p = task.progress {
                PomodoroRing(progress: p, color: .white, lineWidth: 2).frame(width: 13, height: 13)
            } else {
                SpinnerView(color: .white).frame(width: 13, height: 13)
            }
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Notice.Tint.green.color)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(Notice.Tint.red.color)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
