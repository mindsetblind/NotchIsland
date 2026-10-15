import Foundation
import Testing
@testable import NotchIslandCore

struct UsageLogTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

    @Test func countsPerWindow() {
        var log = UsageLog()
        log.record("islandOpened", at: now, calendar: cal)
        log.record("islandOpened", at: now, calendar: cal)
        log.record("islandOpened", at: now.addingTimeInterval(-3 * 86400), calendar: cal)
        log.record("petAsked", at: now.addingTimeInterval(-10 * 86400), calendar: cal)
        #expect(log.totals(lastDays: 1, now: now, calendar: cal) == ["islandOpened": 2])
        #expect(log.totals(lastDays: 7, now: now, calendar: cal) == ["islandOpened": 3])
        #expect(log.totals(lastDays: 30, now: now, calendar: cal)["petAsked"] == 1)
        #expect(log.activeDays(lastDays: 7, now: now, calendar: cal) == 2)
    }

    @Test func dropsOldDays() throws {
        var log = UsageLog()
        log.keepDays = 30
        log.record("old", at: now.addingTimeInterval(-40 * 86400), calendar: cal)
        log.record("new", at: now, calendar: cal)
        log.prune(now: now, calendar: cal)
        #expect(log.totals(lastDays: 365, now: now, calendar: cal) == ["new": 1])
        let back = try JSONDecoder().decode(UsageLog.self, from: JSONEncoder().encode(log))
        #expect(back == log)
    }
}
