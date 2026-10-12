import Testing
@testable import NotchIslandCore

struct ThresholdAlarmTests {
    @Test func firesOncePerThresholdWhileDraining() {
        var a = ThresholdAlarm(thresholds: [20, 10], hysteresis: 3)
        let readings: [Double] = [50, 30, 21, 20, 19, 18, 11, 10, 9, 5]
        let fired = readings.compactMap { a.update($0) }
        #expect(fired == [20, 10])
    }

    @Test func jumpingPastSeveralThresholdsAnnouncesOnlyTheLowest() {
        var a = ThresholdAlarm(thresholds: [20, 10], hysteresis: 3)
        #expect(a.update(8) == 10)
        #expect(a.update(15) == nil)   // 20 is considered announced too
    }

    @Test func hoveringAroundTheLimitDoesNotRepeat() {
        var a = ThresholdAlarm(thresholds: [10], hysteresis: 2)
        #expect(a.update(10) == 10)
        #expect(a.update(11) == nil)
        #expect(a.update(10) == nil)
        #expect(a.update(12.5) == nil) // rose clearly above → re-armed
        #expect(a.update(9.9) == 10)
    }

    @Test func resetRearmsEverything() {
        var a = ThresholdAlarm(thresholds: [20, 10], hysteresis: 3)
        _ = a.update(9)
        a.reset()
        #expect(a.update(19) == 20)
    }
}
