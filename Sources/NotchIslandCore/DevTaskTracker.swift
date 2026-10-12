import Combine
import Foundation

public struct DevTask: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, success, failure, cancelled }

    public let id: String
    public var title: String
    public var category: DevEvent.Category
    public var state: State
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var message: String?
    public var progress: Double?
    public var exitCode: Int?
    public var source: String?
    /// "Taking long" was already announced for this run.
    public var warnedLong = false

    public var isRunning: Bool { state == .running }

    public func duration(at now: Date) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Keeps the list of developer tasks from incoming events and says what changed, so the app can
/// show the right alert. Pure logic: time and limits are injectable for tests.
@MainActor
public final class DevTaskTracker: ObservableObject {
    public enum Change: Equatable {
        case started(DevTask)
        case updated(DevTask)
        case finished(DevTask)
        case takingLong(DevTask)
        case ignored(String)
    }

    /// Running tasks first (oldest first), then finished ones (newest first).
    @Published public private(set) var tasks: [DevTask] = []

    /// At most this many tasks are remembered; the oldest finished ones go first.
    public var maxTasks = 20
    /// A running task is announced as "taking long" once after this. nil = never.
    public var longRunningAfter: TimeInterval? = 10 * 60
    /// A running task nobody has heard from in this long is considered abandoned (sender crashed).
    public var abandonedAfter: TimeInterval = 6 * 3600
    /// Finished tasks are forgotten after this.
    public var keepFinishedFor: TimeInterval = 3600

    // Flood protection: a token bucket (burst `burst`, refilled at `ratePerSecond`).
    public var burst = 20.0
    public var ratePerSecond = 5.0
    private var tokens = 20.0
    private var lastRefill: Date
    /// The exact same event repeated within this window is dropped.
    public var duplicateWindow: TimeInterval = 1
    private var lastEvent: (event: DevEvent, at: Date)?

    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
        lastRefill = now()
    }

    public var running: [DevTask] { tasks.filter(\.isRunning) }

    // MARK: Events

    @discardableResult
    public func handle(_ e: DevEvent) -> Change {
        let t = now()
        refill(t)
        guard tokens >= 1 else { return .ignored("rate limit") }
        if let last = lastEvent, last.event == e, t.timeIntervalSince(last.at) < duplicateWindow {
            return .ignored("duplicate")
        }
        tokens -= 1
        lastEvent = (e, t)

        let index = tasks.firstIndex { $0.id == e.id }
        var task = index.map { tasks[$0] } ?? DevTask(
            id: e.id, title: e.title ?? e.id, category: e.category, state: .running,
            startedAt: t, updatedAt: t, finishedAt: nil, message: nil, progress: nil, exitCode: nil, source: e.source)
        let wasRunning = index != nil && task.isRunning
        task.updatedAt = t
        if let title = e.title { task.title = title }
        if e.category != .other || index == nil { task.category = e.category }
        if let source = e.source { task.source = source }
        if let message = e.message { task.message = message }

        let change: Change
        switch e.kind {
        case .start:
            if !wasRunning {
                // New run (or a re-run of a finished task with the same ID): the clock starts again.
                task.state = .running
                task.startedAt = t
                task.finishedAt = nil
                task.progress = nil
                task.exitCode = nil
                task.warnedLong = false
                task.message = e.message
            }
            if let p = e.progress { task.progress = p }
            change = wasRunning ? .updated(task) : .started(task)
        case .progress, .message:
            if let p = e.progress { task.progress = p }
            change = wasRunning || index != nil ? .updated(task) : .started(task)
        case .finish:
            if !task.isRunning && index != nil && task.finishedAt != nil {
                return .ignored("already finished")
            }
            task.state = Self.state(for: e.status ?? .success)
            task.finishedAt = t
            task.exitCode = e.exitCode
            if task.state == .success { task.progress = 1 }
            change = .finished(task)
        }
        store(task, at: index)
        return change
    }

    /// Call periodically (e.g. every 30 s while tasks run): "taking long" warnings, cleanup.
    public func tick() -> [Change] {
        let t = now()
        var changes: [Change] = []
        for i in tasks.indices where tasks[i].isRunning {
            if t.timeIntervalSince(tasks[i].updatedAt) > abandonedAfter {
                tasks[i].state = .cancelled
                tasks[i].finishedAt = t
                tasks[i].message = "нет вестей — задача, видимо, прервана"
                continue
            }
            if let limit = longRunningAfter, !tasks[i].warnedLong, tasks[i].duration(at: t) > limit {
                tasks[i].warnedLong = true
                changes.append(.takingLong(tasks[i]))
            }
        }
        tasks.removeAll { !$0.isRunning && t.timeIntervalSince($0.finishedAt ?? t) > keepFinishedFor }
        sortAndTrim()
        return changes
    }

    public func remove(_ id: String) {
        tasks.removeAll { $0.id == id }
    }

    public func clearFinished() {
        tasks.removeAll { !$0.isRunning }
    }

    // MARK: Internals

    private static func state(for status: DevEvent.Status) -> DevTask.State {
        switch status {
        case .success: return .success
        case .failure: return .failure
        case .cancelled: return .cancelled
        }
    }

    private func store(_ task: DevTask, at index: Int?) {
        if let index { tasks[index] = task } else { tasks.append(task) }
        sortAndTrim()
    }

    private func sortAndTrim() {
        tasks.sort { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.isRunning ? a.startedAt < b.startedAt : (a.finishedAt ?? a.updatedAt) > (b.finishedAt ?? b.updatedAt)
        }
        while tasks.count > maxTasks {
            // Drop the oldest finished task; if everything is running, the oldest running one.
            if let i = tasks.lastIndex(where: { !$0.isRunning }) { tasks.remove(at: i) } else { tasks.removeFirst() }
        }
    }

    private func refill(_ t: Date) {
        tokens = min(burst, tokens + t.timeIntervalSince(lastRefill) * ratePerSecond)
        lastRefill = t
    }
}
