import Foundation

/// Runs at most one refresh at a time. A caller that arrives while a refresh is running waits for it
/// and gets the same result instead of starting a second one.
///
/// Made for OAuth refresh tokens that rotate (Spotify PKCE): two parallel refreshes would both send
/// the same refresh token, the second one would be rejected — and that used to log the user out.
@MainActor
public final class SharedRefresh<Value: Sendable> {
    private var running: Task<Value, Error>?

    public init() {}

    /// True while a refresh started by `run` hasn't finished.
    public var isRunning: Bool { running != nil }

    public func run(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let running { return try await running.value }
        // Both this function and the task run on the main actor, so `running` is set before the
        // task's body can start — and cleared by the task itself when it's done.
        let task = Task { @MainActor in
            defer { self.running = nil }
            return try await work()
        }
        running = task
        return try await task.value
    }
}
