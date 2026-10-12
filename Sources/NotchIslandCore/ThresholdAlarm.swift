import Foundation

/// Fires once when a value drops to or below each threshold, and re-arms a threshold only after the
/// value has risen clearly above it again (`hysteresis`) or `reset()` is called (e.g. the charger was
/// plugged in). Used for low battery and low disk space, so a value hovering around a limit doesn't
/// announce itself over and over.
public struct ThresholdAlarm: Equatable, Sendable {
    /// Highest first, e.g. [20, 10].
    public let thresholds: [Double]
    public let hysteresis: Double
    private var fired: Set<Double> = []

    public init(thresholds: [Double], hysteresis: Double) {
        self.thresholds = thresholds.sorted(by: >)
        self.hysteresis = hysteresis
    }

    /// Feeds a new reading; returns the threshold that was just crossed (the lowest one, if a jump
    /// crossed several), or nil.
    public mutating func update(_ value: Double) -> Double? {
        for t in thresholds where fired.contains(t) && value > t + hysteresis { fired.remove(t) }
        let crossed = thresholds.filter { value <= $0 && !fired.contains($0) }
        guard let lowest = crossed.min() else { return nil }
        // Crossing the lowest implies the higher ones too: don't announce them later.
        for t in thresholds where t >= lowest { fired.insert(t) }
        return lowest
    }

    public mutating func reset() { fired.removeAll() }
}
