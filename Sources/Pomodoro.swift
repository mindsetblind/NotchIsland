import AppKit
import SwiftUI

enum PomodoroPhase: String {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: return "Фокус"
        case .shortBreak: return "Перерыв"
        case .longBreak: return "Длинный перерыв"
        }
    }

    var color: Color {
        switch self {
        case .focus: return Color(red: 1.0, green: 0.42, blue: 0.33)       // tomato
        case .shortBreak: return Color(red: 0.35, green: 0.85, blue: 0.5)
        case .longBreak: return Color(red: 0.3, green: 0.75, blue: 0.95)
        }
    }

    var symbol: String { self == .focus ? "flame.fill" : "cup.and.saucer.fill" }
}

struct PomodoroPreset: Equatable {
    let focus: Int, short: Int, long: Int     // minutes
    var label: String { "\(focus) / \(short) / \(long) мин" }
    static let all = [PomodoroPreset(focus: 25, short: 5, long: 15),
                      PomodoroPreset(focus: 50, short: 10, long: 20),
                      PomodoroPreset(focus: 15, short: 3, long: 10)]
}

struct PomodoroPeek: Equatable {
    let title: String
    let subtitle: String
    let phase: PomodoroPhase
}

/// Classic pomodoro: focus → short break (every 4th: long break) → focus…
/// Breaks start by themselves; the next focus waits for you.
final class Pomodoro: ObservableObject {
    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var completedToday = 0
    @Published private(set) var preset: PomodoroPreset
    @Published private(set) var peek: PomodoroPeek?

    private var endDate: Date?
    private var pausedRemaining: TimeInterval = 0
    private var focusStreak = 0            // completed focuses since the last long break
    private var ticker: Timer?
    private var peekWork: DispatchWorkItem?

    private static let presetKey = "pomodoroPreset"
    private static let dayKey = "pomodoroDay"
    private static let countKey = "pomodoroCount"

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.presetKey)
        preset = PomodoroPreset.all.first { $0.focus == saved } ?? PomodoroPreset.all[0]
        pausedRemaining = duration(.focus)
        completedToday = UserDefaults.standard.string(forKey: Self.dayKey) == Self.today
            ? UserDefaults.standard.integer(forKey: Self.countKey) : 0
    }

    // MARK: Reading

    func duration(_ phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(preset.focus * 60)
        case .shortBreak: return TimeInterval(preset.short * 60)
        case .longBreak: return TimeInterval(preset.long * 60)
        }
    }

    func remaining(at date: Date) -> TimeInterval {
        guard isRunning, let endDate else { return pausedRemaining }
        return max(0, endDate.timeIntervalSince(date))
    }

    func progress(at date: Date) -> Double {
        let total = duration(phase)
        return total > 0 ? 1 - remaining(at: date) / total : 0
    }

    /// Untouched timer at the start of a focus — nothing to reset.
    var isFresh: Bool { !isRunning && phase == .focus && pausedRemaining == duration(.focus) }

    // MARK: Controls

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        withAnimation(IslandModel.spring) { isRunning = true }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        ticker?.tolerance = 0.2
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining(at: Date())
        stopTicker()
        withAnimation(IslandModel.spring) { isRunning = false }
    }

    func reset() {
        stopTicker()
        focusStreak = 0
        pausedRemaining = duration(.focus)
        withAnimation(IslandModel.spring) {
            isRunning = false
            phase = .focus
        }
    }

    func skip() { advance(completed: false) }

    func setPreset(_ p: PomodoroPreset) {
        preset = p
        UserDefaults.standard.set(p.focus, forKey: Self.presetKey)
        if !isRunning { pausedRemaining = duration(phase) }
        else { endDate = Date().addingTimeInterval(min(remaining(at: Date()), duration(phase))) }
    }

    // MARK: Internals

    private func tick() {
        if remaining(at: Date()) <= 0 { advance(completed: true) }
    }

    private func advance(completed: Bool) {
        stopTicker()
        if phase == .focus {
            if completed { countFocus() }
            let next: PomodoroPhase = focusStreak >= 4 ? .longBreak : .shortBreak
            if next == .longBreak { focusStreak = 0 }
            pausedRemaining = duration(next)
            withAnimation(IslandModel.spring) {
                phase = next
                isRunning = false
            }
            start()   // breaks start by themselves
            if completed {
                announce(PomodoroPeek(title: "Фокус завершён",
                                      subtitle: "перерыв \(Int(duration(next) / 60)) мин",
                                      phase: next))
            }
        } else {
            pausedRemaining = duration(.focus)
            withAnimation(IslandModel.spring) {
                phase = .focus
                isRunning = false
            }
            if completed {
                announce(PomodoroPeek(title: "Перерыв окончен", subtitle: "пора за работу", phase: .focus))
            }
        }
    }

    private func countFocus() {
        focusStreak += 1
        let d = UserDefaults.standard
        if d.string(forKey: Self.dayKey) != Self.today { completedToday = 0 }
        completedToday += 1
        d.set(Self.today, forKey: Self.dayKey)
        d.set(completedToday, forKey: Self.countKey)
    }

    private func announce(_ p: PomodoroPeek) {
        NSSound(named: "Glass")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        peekWork?.cancel()
        withAnimation(IslandModel.spring) { peek = p }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(IslandModel.spring) { self?.peek = nil }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Views

struct PomodoroRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

func formatTimer(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Tile on the Tools tab: ring + time; click starts/pauses, hover shows reset/skip.
struct PomodoroTile: View {
    @ObservedObject var pomodoro: Pomodoro
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let p = pomodoro
            VStack(spacing: 5) {
                ZStack {
                    PomodoroRing(progress: p.progress(at: ctx.date), color: p.phase.color, lineWidth: 4)
                        .animation(.linear(duration: 1), value: p.progress(at: ctx.date))
                    VStack(spacing: 1) {
                        Text(formatTimer(p.remaining(at: ctx.date)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        Image(systemName: p.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 52, height: 52)
                // Drop the tomato count if the phase name is too long to fit next to it.
                ViewThatFits(in: .horizontal) {
                    Text(p.completedToday > 0 ? "\(p.phase.title) · 🍅\(p.completedToday)" : p.phase.title)
                    Text(p.phase.title)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
            }
            .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hover ? 0.14 : 0.08)))
            .overlay(alignment: .topLeading) {
                if hover && !p.isFresh {
                    miniButton("arrow.counterclockwise", help: "Сбросить") { p.reset() }
                }
            }
            .overlay(alignment: .topTrailing) {
                if hover {
                    miniButton("forward.end.fill", help: "Пропустить этап") { p.skip() }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p.toggle() }
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
            .contextMenu {
                ForEach(PomodoroPreset.all, id: \.focus) { preset in
                    Button((preset == p.preset ? "✓ " : "") + preset.label) { p.setPreset(preset) }
                }
                Divider()
                Button("Сбросить") { p.reset() }
                Button("Пропустить этап") { p.skip() }
                Divider()
                Text("Сегодня завершено: \(p.completedToday) 🍅")
            }
            .help(p.isRunning ? "Пауза" : "Старт")
        }
    }

    private func miniButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(2)
    }
}

/// Collapsed island while a timer runs: ring + phase on the left, time (or the music EQ) on the right.
struct PomodoroCompactView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var pomodoro: Pomodoro

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                HStack(spacing: 6) {
                    PomodoroRing(progress: pomodoro.progress(at: ctx.date), color: pomodoro.phase.color, lineWidth: 2.5)
                        .frame(width: 15, height: 15)
                    Image(systemName: pomodoro.phase.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(pomodoro.phase.color)
                }
            } right: {
                Text(formatTimer(pomodoro.remaining(at: ctx.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pomodoro.phase.color)
            }
        }
    }
}

struct PomodoroPeekView: View {
    @ObservedObject var model: IslandModel
    let peek: PomodoroPeek

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            HStack(spacing: 6) {
                Image(systemName: peek.phase.symbol).foregroundStyle(peek.phase.color)
                Text(peek.title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            Text(peek.subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(peek.phase.color)
                .lineLimit(1)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
