import Foundation
import Testing
@testable import NotchIslandCore

struct LRUCacheTests {
    @Test func evictsTheLeastRecentlyUsed() {
        var c = LRUCache<String, Int>(capacity: 2)
        c.set(1, for: "a")
        c.set(2, for: "b")
        _ = c.value(for: "a")          // "b" is now the oldest
        c.set(3, for: "c")
        let r1 = c.value(for: "b")
        #expect(r1 == nil)
        let r2 = c.value(for: "a")
        #expect(r2 == 1)
        let r3 = c.value(for: "c")
        #expect(r3 == 3)
        #expect(c.count == 2)
    }

    @Test func overwritingDoesNotGrow() {
        var c = LRUCache<String, Int>(capacity: 2)
        c.set(1, for: "a")
        c.set(2, for: "a")
        #expect(c.count == 1)
        let r4 = c.value(for: "a")
        #expect(r4 == 2)
        c.remove("a")
        let r5 = c.value(for: "a")
        #expect(r5 == nil)
    }
}

struct FailureMemoTests {
    @Test func failedKeysWaitBeforeRetrying() {
        var m = FailureMemo<String>(retryAfter: 600)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(m.shouldTry("cover", now: t0))
        m.failed("cover", now: t0)
        #expect(!m.shouldTry("cover", now: t0.addingTimeInterval(599)))
        #expect(m.shouldTry("cover", now: t0.addingTimeInterval(600)))
        m.succeeded("cover")
        #expect(m.shouldTry("cover", now: t0))
    }
}

/// A fake player integration: replays a scripted sequence of results, like the AppleScript layer would.
struct MediaHealthTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    @Test func automationDenialIsReportedAndRecovers() {
        var h = MediaHealth()
        let r6 = h.record(.denied, at: t0)
        #expect(r6)
        #expect(h.state == .denied)
        #expect(!h.canAttempt(at: t0.addingTimeInterval(30)))
        #expect(h.canAttempt(at: t0.addingTimeInterval(60)))
        // The user allowed access in System Settings.
        let r7 = h.record(.ok, at: t0.addingTimeInterval(60))
        #expect(r7)
        #expect(h.state == .healthy)
        #expect(h.canAttempt(at: t0.addingTimeInterval(60)))
    }

    @Test func singleHiccupIsNotAnError() {
        var h = MediaHealth()
        let r8 = h.record(.failed, at: t0)
        #expect(!r8)
        #expect(h.state == .healthy)
        #expect(!h.canAttempt(at: t0.addingTimeInterval(1)))
        #expect(h.canAttempt(at: t0.addingTimeInterval(2)))
    }

    @Test func repeatedFailuresBackOffExponentiallyUpToTheCap() {
        var h = MediaHealth()
        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            h.record(.failed, at: now)
            delays.append(h.nextAttempt.timeIntervalSince(now))
            now = h.nextAttempt
        }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60])
        #expect(h.state == .unavailable)
        h.record(.ok, at: now)
        #expect(h.state == .healthy)
        #expect(h.consecutiveFailures == 0)
    }

    @Test func playerNotRunningIsHealthy() {
        var h = MediaHealth()
        h.record(.failed, at: t0)
        h.record(.notRunning, at: t0)
        #expect(h.state == .healthy)
        #expect(h.canAttempt(at: t0))
    }

    @Test func userActionCutsTheWaitShort() {
        var h = MediaHealth()
        h.record(.denied, at: t0)
        h.retrySoon()
        #expect(h.canAttempt(at: t0))
    }
}
