import Testing
@testable import NotchIslandCore

@MainActor
struct SharedRefreshTests {
    /// The Spotify bug: two requests with an expired token used to start two refreshes.
    @Test func parallelCallersShareOneRefresh() async throws {
        let shared = SharedRefresh<String>()
        var calls = 0
        let work: @MainActor () async throws -> String = {
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return "token-\(calls)"
        }
        async let a = shared.run(work)
        async let b = shared.run(work)
        async let c = shared.run(work)
        let results = try await [a, b, c]
        #expect(calls == 1)
        #expect(results == ["token-1", "token-1", "token-1"])
        #expect(!shared.isRunning)
    }

    @Test func laterCallStartsAFreshRefresh() async throws {
        let shared = SharedRefresh<Int>()
        var calls = 0
        let work: @MainActor () async throws -> Int = { calls += 1; return calls }
        #expect(try await shared.run(work) == 1)
        #expect(try await shared.run(work) == 2)
    }

    struct Boom: Error, Equatable {}

    @Test func errorReachesEveryWaiterAndDoesNotStick() async throws {
        let shared = SharedRefresh<Int>()
        var calls = 0
        let failing: @MainActor () async throws -> Int = {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            throw Boom()
        }
        async let a: Int? = try? shared.run(failing)
        async let b: Int? = try? shared.run(failing)
        let (ra, rb) = await (a, b)
        #expect(ra == nil && rb == nil)
        #expect(calls == 1)
        // After a failure the next call tries again.
        #expect(try await shared.run { 7 } == 7)
    }
}
