import Foundation

/// Small least-recently-used cache (artwork, thumbnails). Not thread-safe: use from one actor.
public struct LRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []   // least recent first

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public var count: Int { values.count }

    public mutating func value(for key: Key) -> Value? {
        guard let v = values[key] else { return nil }
        touch(key)
        return v
    }

    public mutating func set(_ value: Value, for key: Key) {
        values[key] = value
        touch(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }

    public mutating func remove(_ key: Key) {
        values.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Remembers recent failures (e.g. an artwork URL that timed out) so they aren't retried in a loop.
public struct FailureMemo<Key: Hashable> {
    public let retryAfter: TimeInterval
    private var failedAt: [Key: Date] = [:]

    public init(retryAfter: TimeInterval) { self.retryAfter = retryAfter }

    public func shouldTry(_ key: Key, now: Date) -> Bool {
        guard let t = failedAt[key] else { return true }
        return now.timeIntervalSince(t) >= retryAfter
    }

    public mutating func failed(_ key: Key, now: Date) {
        failedAt[key] = now
        if failedAt.count > 200 { failedAt = failedAt.filter { now.timeIntervalSince($0.value) < retryAfter } }
    }

    public mutating func succeeded(_ key: Key) { failedAt.removeValue(forKey: key) }
}

/// What happened when we asked a player (Spotify / Music) for its state.
public enum PlayerAccess: Equatable, Sendable {
    case ok
    /// The player isn't running — normal, not an error.
    case notRunning
    /// macOS refused Automation access (AppleScript error -1743): the user has to allow it.
    case denied
    /// Anything else (timeout, the app is busy or hung).
    case failed
}

/// Tracks the health of one player integration: whether access is denied, and how long to wait
/// before asking again after failures (exponential backoff, reset by the first success), so a hung
/// or broken player isn't hammered once a second.
public struct MediaHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable { case healthy, denied, unavailable }

    public private(set) var state: State = .healthy
    public private(set) var consecutiveFailures = 0
    public private(set) var nextAttempt: Date = .distantPast

    public var baseDelay: TimeInterval = 2
    public var maxDelay: TimeInterval = 60

    public init() {}

    public func canAttempt(at now: Date) -> Bool { now >= nextAttempt }

    /// Records a result; returns true if the state changed (the UI may need to update).
    @discardableResult
    public mutating func record(_ access: PlayerAccess, at now: Date) -> Bool {
        let old = state
        switch access {
        case .ok, .notRunning:
            state = .healthy
            consecutiveFailures = 0
            nextAttempt = .distantPast
        case .denied:
            // Asking again won't help until the user changes the setting; check rarely.
            state = .denied
            consecutiveFailures += 1
            nextAttempt = now.addingTimeInterval(maxDelay)
        case .failed:
            consecutiveFailures += 1
            // One hiccup isn't worth showing; repeated ones are.
            if consecutiveFailures >= 3 { state = .unavailable }
            let delay = min(maxDelay, baseDelay * pow(2, Double(consecutiveFailures - 1)))
            nextAttempt = now.addingTimeInterval(delay)
        }
        return old != state
    }

    /// The user did something (opened the player, pressed play): try again right away.
    public mutating func retrySoon() { nextAttempt = .distantPast }
}
