import Combine
import Foundation

/// Everything the collapsed island can show around the notch.
public enum ActivityKind: String, CaseIterable, Codable, Sendable {
    // Live activities: stay while the thing is going on.
    case pomodoro, agent, developer, music
    // Short alerts.
    case battery, device, color, clipboard, download, calendar, disk
    /// The pet offering help on its own (tidy Downloads…).
    case pet

    /// Default order, highest first. Live activities can be re-ordered by the user (Settings).
    public var defaultPriority: Int {
        switch self {
        case .agent: return 90        // "Claude finished / waits for you" — you asked for it
        case .developer: return 85    // build failed / finished
        case .calendar: return 80
        case .pomodoro: return 70
        case .battery: return 60
        case .device: return 50
        case .disk: return 45
        case .download: return 40
        case .pet: return 35
        case .color, .clipboard: return 30
        case .music: return 10
        }
    }

    /// Kinds that can be ongoing (shown while something lasts), in their default order.
    public static let liveKinds: [ActivityKind] = [.pomodoro, .agent, .developer, .music]
}

public struct ActivityID: Hashable, Sendable, CustomStringConvertible {
    public let kind: ActivityKind
    public let key: String

    public init(_ kind: ActivityKind, _ key: String = "") {
        self.kind = kind
        self.key = key
    }

    public var description: String { key.isEmpty ? kind.rawValue : "\(kind.rawValue):\(key)" }
}

/// One thing the island wants to show. `Payload` carries the view data (defined by the app).
public struct Activity<Payload: Equatable>: Identifiable, Equatable {
    public let id: ActivityID
    public var payload: Payload
    public var priority: Int
    /// When it started (live) or was posted (alert). Ties in priority go to the older one, so a
    /// newcomer of the same rank doesn't make the island flip back and forth.
    public var since: Date
    /// Alerts only: how long it stays once shown.
    public var duration: TimeInterval?
    /// Alerts only: set when it actually appears on screen.
    public var expiresAt: Date?

    public var isAlert: Bool { duration != nil }
}

/// Decides what the collapsed island shows.
///
/// - **Live activities** (music playing, pomodoro running, a build in progress…) last until their
///   source ends them. The one with the highest priority is shown.
/// - **Alerts** (device connected, build failed, focus finished…) are shown one at a time on top of
///   live activities for a fixed time, then the island returns to the live activity underneath.
///   Alerts that arrive meanwhile wait in a short queue ordered by priority; a much more important
///   alert interrupts a less important one (which goes back to the queue). Re-posting an alert with
///   the same ID updates it in place instead of queueing a duplicate.
///
/// All work happens on the main actor; expiry is driven by a single scheduled callback.
@MainActor
public final class ActivityCoordinator<Payload: Equatable>: ObservableObject {
    public typealias Item = Activity<Payload>
    /// Schedules `action` after `delay` seconds; returns a cancel function.
    public typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void

    /// What the compact island shows right now.
    @Published public private(set) var current: Item?
    /// The next live activity below `current` (for a small secondary indicator), if any.
    @Published public private(set) var secondary: Item?

    public private(set) var live: [ActivityID: Item] = [:]
    public private(set) var queue: [Item] = []
    public private(set) var shownAlert: Item?

    /// Kinds the user has switched off are kept but not shown.
    public var isAllowed: (ActivityKind) -> Bool = { _ in true } { didSet { recompute() } }
    /// Overrides `ActivityKind.defaultPriority` for live activities (the user's order). Alerts keep
    /// their built-in ranking.
    public var priorityOverrides: [ActivityKind: Int] = [:] {
        didSet {
            for id in live.keys where !explicitPriority.contains(id) { live[id]?.priority = livePriority(of: id.kind) }
            recompute()
        }
    }
    /// Live activities started with their own priority keep it when the user re-orders kinds.
    private var explicitPriority: Set<ActivityID> = []
    /// Waiting alerts beyond this are dropped (lowest priority, then oldest) — a flood of events can't
    /// keep the island busy for minutes.
    public var maxQueued = 6
    /// An alert stays at least this long before a more important one may replace it (no flicker).
    public var minimumDisplay: TimeInterval = 1.2
    /// A preempting alert must outrank the shown one by at least this much.
    public var preemptMargin = 15

    private let now: () -> Date
    private let scheduler: Scheduler
    private var cancelDeadline: (() -> Void)?

    public init(now: @escaping () -> Date = Date.init, scheduler: Scheduler? = nil) {
        self.now = now
        self.scheduler = scheduler ?? { delay, action in
            let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
            return { work.cancel() }
        }
    }

    public func livePriority(of kind: ActivityKind) -> Int { priorityOverrides[kind] ?? kind.defaultPriority }

    // MARK: Live activities

    /// Starts or updates a live activity. Updating keeps its original start time.
    public func setLive(_ id: ActivityID, _ payload: Payload, priority: Int? = nil) {
        let p = priority ?? livePriority(of: id.kind)
        if priority != nil { explicitPriority.insert(id) } else { explicitPriority.remove(id) }
        if var existing = live[id] {
            guard existing.payload != payload || existing.priority != p else { return }
            existing.payload = payload
            existing.priority = p
            live[id] = existing
        } else {
            live[id] = Item(id: id, payload: payload, priority: p, since: now(), duration: nil, expiresAt: nil)
        }
        recompute()
    }

    public func endLive(_ id: ActivityID) {
        explicitPriority.remove(id)
        guard live.removeValue(forKey: id) != nil else { return }
        recompute()
    }

    /// Convenience for sources that are simply on/off.
    public func setLive(_ id: ActivityID, _ payload: Payload, active: Bool) {
        if active { setLive(id, payload) } else { endLive(id) }
    }

    // MARK: Alerts

    public func post(_ id: ActivityID, _ payload: Payload, duration: TimeInterval, priority: Int? = nil) {
        let p = priority ?? id.kind.defaultPriority
        let t = now()

        // Same alert already on screen: refresh its content and timer, no re-entry animation.
        if var shown = shownAlert, shown.id == id {
            shown.payload = payload
            shown.priority = p
            shown.duration = duration
            shown.expiresAt = t.addingTimeInterval(duration)
            shownAlert = shown
            recompute()
            return
        }
        let item = Item(id: id, payload: payload, priority: p, since: t, duration: duration, expiresAt: nil)
        // Already waiting: update it where it is.
        if let i = queue.firstIndex(where: { $0.id == id }) {
            queue[i].payload = payload
            queue[i].priority = p
            queue[i].duration = duration
            sortQueue()
            recompute()
            return
        }
        guard isAllowed(id.kind) else { return }

        if let shown = shownAlert {
            let shownFor = t.timeIntervalSince(shown.since)
            if p >= shown.priority + preemptMargin && shownFor >= minimumDisplay {
                // Interrupt: the current alert goes back to the queue with the time it had left.
                var back = shown
                back.duration = max(1.5, (shown.expiresAt ?? t).timeIntervalSince(t))
                back.expiresAt = nil
                queue.append(back)
                show(item)
            } else {
                queue.append(item)
            }
            sortQueue()
            trimQueue()
        } else {
            show(item)
        }
        recompute()
    }

    /// Removes an alert (shown or waiting), e.g. when the user clicked it away or it became moot.
    public func dismiss(_ id: ActivityID) {
        queue.removeAll { $0.id == id }
        if shownAlert?.id == id {
            shownAlert = nil
            showNext()
        }
        recompute()
    }

    /// Removes every alert of a kind (e.g. the feature was switched off).
    public func dismissAll(_ kind: ActivityKind) {
        queue.removeAll { $0.id.kind == kind }
        if shownAlert?.id.kind == kind {
            shownAlert = nil
            showNext()
        }
        recompute()
    }

    /// Expires what is due. Called by the scheduled deadline; tests call it after moving the clock.
    public func advance() {
        let t = now()
        if let shown = shownAlert, let end = shown.expiresAt, end <= t {
            shownAlert = nil
            showNext()
        }
        recompute()
    }

    /// Re-evaluates permissions/priorities (call after settings change).
    public func refresh() {
        // An alert of a kind that was just switched off disappears right away.
        queue.removeAll { !isAllowed($0.id.kind) }
        if let shown = shownAlert, !isAllowed(shown.id.kind) {
            shownAlert = nil
            showNext()
        }
        recompute()
    }

    // MARK: Internals

    private func show(_ item: Item) {
        var a = item
        let t = now()
        a.since = t
        a.expiresAt = t.addingTimeInterval(a.duration ?? 0)
        shownAlert = a
    }

    private func showNext() {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if isAllowed(next.id.kind) {
                show(next)
                return
            }
        }
    }

    private func sortQueue() {
        // Stable: higher priority first, then in arrival order.
        queue = queue.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)
    }

    private func trimQueue() {
        if queue.count > maxQueued { queue.removeLast(queue.count - maxQueued) }
    }

    /// Visible live activities, most important first.
    public var rankedLive: [Item] {
        live.values
            .filter { isAllowed($0.id.kind) }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority
                      : $0.since != $1.since ? $0.since < $1.since : $0.id.description < $1.id.description }
    }

    private func recompute() {
        let ranked = rankedLive
        let newCurrent = shownAlert ?? ranked.first
        let newSecondary = ranked.first { $0.id != newCurrent?.id }
        if newCurrent != current { current = newCurrent }
        if newSecondary != secondary { secondary = newSecondary }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        cancelDeadline?()
        cancelDeadline = nil
        guard let end = shownAlert?.expiresAt else { return }
        cancelDeadline = scheduler(max(0, end.timeIntervalSince(now()))) { [weak self] in self?.advance() }
    }
}
