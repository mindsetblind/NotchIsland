import Foundation
import Testing
@testable import NotchIslandCore

/// Manual clock + scheduler: time only moves when the test says so.
@MainActor
final class FakeTime {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var pending: [(at: Date, id: Int, action: @MainActor () -> Void)] = []
    private var nextID = 0

    var scheduler: ActivityCoordinator<String>.Scheduler {
        { [unowned self] delay, action in
            let id = self.nextID
            self.nextID += 1
            self.pending.append((self.now.addingTimeInterval(delay), id, action))
            return { [weak self] in self?.pending.removeAll { $0.id == id } }
        }
    }

    var scheduledCount: Int { pending.count }

    /// Moves the clock and fires whatever came due, in order.
    func advance(_ seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = pending.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            pending.removeAll { $0.id == next.id }
            now = next.at
            next.action()
        }
        now = target
    }
}

@MainActor
struct ActivityCoordinatorTests {
    let time = FakeTime()
    let c: ActivityCoordinator<String>

    init() {
        let time = self.time
        c = ActivityCoordinator<String>(now: { time.now }, scheduler: time.scheduler)
    }

    @Test func idleWhenNothingIsGoingOn() {
        #expect(c.current == nil)
        #expect(c.secondary == nil)
    }

    @Test func highestPriorityLiveActivityWins() {
        c.setLive(ActivityID(.music), "music")
        #expect(c.current?.payload == "music")
        c.setLive(ActivityID(.pomodoro), "pomodoro")
        #expect(c.current?.payload == "pomodoro")
        #expect(c.secondary?.payload == "music")
        c.endLive(ActivityID(.pomodoro))
        #expect(c.current?.payload == "music")
        #expect(c.secondary == nil)
    }

    @Test func userPriorityOrderIsRespected() {
        c.setLive(ActivityID(.music), "music")
        c.setLive(ActivityID(.pomodoro), "pomodoro")
        c.priorityOverrides = [.music: 100]
        #expect(c.current?.payload == "music")
    }

    @Test func equalPriorityKeepsTheOlderOneStable() {
        c.setLive(ActivityID(.developer, "a"), "a")
        time.advance(1)
        c.setLive(ActivityID(.developer, "b"), "b")
        #expect(c.current?.payload == "a")
        // Updating "a" must not reset its start and let "b" jump ahead.
        c.setLive(ActivityID(.developer, "a"), "a2")
        #expect(c.current?.payload == "a2")
    }

    @Test func disallowedKindsAreHiddenButKept() {
        c.setLive(ActivityID(.music), "music")
        c.isAllowed = { $0 != .music }
        #expect(c.current == nil)
        c.isAllowed = { _ in true }
        #expect(c.current?.payload == "music")
    }

    @Test func alertShowsOverLiveAndExpiresBackToIt() {
        c.setLive(ActivityID(.music), "music")
        c.post(ActivityID(.device, "airpods"), "airpods", duration: 3)
        #expect(c.current?.payload == "airpods")
        #expect(c.secondary?.payload == "music")
        time.advance(2.9)
        #expect(c.current?.payload == "airpods")
        time.advance(0.2)
        #expect(c.current?.payload == "music")
        #expect(time.scheduledCount == 0)
    }

    @Test func alertsQueueByPriorityThenArrival() {
        c.post(ActivityID(.color), "color", duration: 2)
        c.post(ActivityID(.device, "1"), "device1", duration: 2)
        c.post(ActivityID(.disk), "disk", duration: 2)
        c.post(ActivityID(.device, "2"), "device2", duration: 2)
        #expect(c.current?.payload == "color")
        #expect(c.queue.map(\.payload) == ["device1", "device2", "disk"])
        time.advance(2)
        #expect(c.current?.payload == "device1")
        time.advance(2)
        #expect(c.current?.payload == "device2")
        time.advance(2)
        #expect(c.current?.payload == "disk")
        time.advance(2)
        #expect(c.current == nil)
    }

    @Test func queuedAlertGetsItsFullTimeOnceShown() {
        c.post(ActivityID(.device, "1"), "first", duration: 3)
        time.advance(1)
        c.post(ActivityID(.device, "2"), "second", duration: 3)
        time.advance(2)       // first expires at t=3
        #expect(c.current?.payload == "second")
        time.advance(2.9)
        #expect(c.current?.payload == "second")
        time.advance(0.2)
        #expect(c.current == nil)
    }

    @Test func repostingTheSameAlertUpdatesInPlace() {
        c.post(ActivityID(.battery, "charging"), "50%", duration: 3)
        time.advance(2)
        c.post(ActivityID(.battery, "charging"), "51%", duration: 3)
        #expect(c.current?.payload == "51%")
        #expect(c.queue.isEmpty)
        time.advance(2)       // timer restarted by the re-post
        #expect(c.current?.payload == "51%")
        time.advance(1.1)
        #expect(c.current == nil)
    }

    @Test func duplicateWaitingAlertIsNotQueuedTwice() {
        c.post(ActivityID(.device, "a"), "a", duration: 3)
        c.post(ActivityID(.device, "b"), "b on", duration: 3)
        c.post(ActivityID(.device, "b"), "b off", duration: 3)
        #expect(c.queue.map(\.payload) == ["b off"])
    }

    @Test func muchMoreImportantAlertPreemptsAfterMinimumDisplay() {
        c.post(ActivityID(.color), "color", duration: 3)
        // Too early: waits instead of flickering.
        c.post(ActivityID(.agent, "done"), "agent", duration: 3)
        #expect(c.current?.payload == "color")
        c.dismiss(ActivityID(.agent, "done"))

        time.advance(1.5)
        c.post(ActivityID(.agent, "done"), "agent", duration: 3)
        #expect(c.current?.payload == "agent")
        // The interrupted alert returns with the time it had left.
        #expect(c.queue.first?.payload == "color")
        time.advance(3)
        #expect(c.current?.payload == "color")
        time.advance(1.5)
        #expect(c.current == nil)
    }

    @Test func similarPriorityDoesNotPreempt() {
        c.post(ActivityID(.device), "device", duration: 3)
        time.advance(2)
        c.post(ActivityID(.battery), "battery", duration: 3)   // 60 vs 50: below the margin
        #expect(c.current?.payload == "device")
        time.advance(1)
        #expect(c.current?.payload == "battery")
    }

    @Test func floodOfAlertsIsCapped() {
        c.maxQueued = 3
        for i in 0..<50 { c.post(ActivityID(.clipboard, "\(i)"), "\(i)", duration: 2) }
        #expect(c.queue.count == 3)
        #expect(c.current?.payload == "0")
    }

    @Test func dismissShowsTheNextAlert() {
        c.post(ActivityID(.device, "a"), "a", duration: 5)
        c.post(ActivityID(.device, "b"), "b", duration: 5)
        c.dismiss(ActivityID(.device, "a"))
        #expect(c.current?.payload == "b")
    }

    @Test func switchingAKindOffDropsItsAlerts() {
        c.setLive(ActivityID(.music), "music")
        c.post(ActivityID(.device, "a"), "a", duration: 5)
        c.post(ActivityID(.device, "b"), "b", duration: 5)
        c.isAllowed = { $0 != .device }
        c.refresh()
        #expect(c.current?.payload == "music")
        #expect(c.queue.isEmpty)
        c.post(ActivityID(.device, "c"), "c", duration: 5)
        #expect(c.current?.payload == "music")
    }

    @Test func endingUnknownLiveActivityIsHarmless() {
        c.endLive(ActivityID(.pomodoro))
        c.dismiss(ActivityID(.device))
        c.advance()
        #expect(c.current == nil)
    }

    @Test func rapidLiveToggleSettlesOnFinalState() {
        for i in 0..<20 {
            c.setLive(ActivityID(.music), "music", active: i % 2 == 0)
        }
        #expect(c.current == nil)   // last call (i = 19) ended it
        c.setLive(ActivityID(.music), "music", active: true)
        #expect(c.current?.payload == "music")
    }
}
