import Foundation

/// Which seasonal hat the pet wears on a given day (nil = none).
public enum PetSeasonHat: String, Sendable {
    case witch, santa, beanie

    public static func on(month: Int, day: Int) -> PetSeasonHat? {
        switch (month, day) {
        case (10, 25...), (11, 1): return .witch            // Halloween week
        case (12, 20...), (1, ...10): return .santa          // the holidays
        case (12, _), (1, _), (2, _): return .beanie         // the rest of winter
        default: return nil
        }
    }

    public static func on(_ date: Date, calendar: Calendar = .current) -> PetSeasonHat? {
        let c = calendar.dateComponents([.month, .day], from: date)
        return on(month: c.month ?? 0, day: c.day ?? 0)
    }
}
