import Foundation

/// Local usage counters: how many times each feature was used, per day. No content — only event
/// names like "islandOpened" — and it never leaves the Mac. Old days are dropped.
public struct UsageLog: Codable, Equatable, Sendable {
    /// "yyyy-MM-dd" → event → count
    public private(set) var days: [String: [String: Int]] = [:]
    public var keepDays = 120

    public init() {}

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func record(_ event: String, at date: Date = Date(), calendar: Calendar = .current) {
        days[Self.dayKey(date, calendar: calendar), default: [:]][event, default: 0] += 1
    }

    /// Totals over the last `days` days including today.
    public func totals(lastDays: Int, now: Date = Date(), calendar: Calendar = .current) -> [String: Int] {
        var out: [String: Int] = [:]
        for back in 0..<max(lastDays, 1) {
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            for (event, n) in days[Self.dayKey(d, calendar: calendar)] ?? [:] { out[event, default: 0] += n }
        }
        return out
    }

    /// Days with any activity within the window — "used on 5 of the last 7 days".
    public func activeDays(lastDays: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        (0..<max(lastDays, 1)).filter { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { return false }
            return !(days[Self.dayKey(d, calendar: calendar)] ?? [:]).isEmpty
        }.count
    }

    public mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: now) else { return }
        let oldest = Self.dayKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    public mutating func reset() { days = [:] }
}
