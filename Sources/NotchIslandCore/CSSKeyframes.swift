import Foundation

// A tiny CSS @keyframes evaluator. The pet's animations were designed as CSS in Figma Make; evaluating
// them the way a browser does (per-segment timing functions, steps(), cubic-bezier overshoot) lets the
// island sample them into Core Animation keyframes and look exactly like the design.

public enum CSSTiming: Equatable, Sendable {
    case linear
    case easeInOut
    case cubicBezier(Double, Double, Double, Double)
    /// steps(n) = steps(n, jump-end): holds each value, jumps at the end of each step.
    case steps(Int)

    /// Progress within one keyframe segment (0…1) → eased progress (may overshoot for cubic-bezier).
    public func apply(_ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        switch self {
        case .linear: return p
        case .easeInOut: return Self.bezier(0.42, 0, 0.58, 1, p)
        case .cubicBezier(let x1, let y1, let x2, let y2): return Self.bezier(x1, y1, x2, y2, p)
        case .steps(let n): return n > 0 ? (p >= 1 ? 1 : floor(p * Double(n)) / Double(n)) : p
        }
    }

    /// y on a cubic Bézier from (0,0) to (1,1) at the point whose x equals `x` (Newton + bisection).
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        func coord(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        func slope(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
        var t = x
        for _ in 0..<8 {
            let err = coord(x1, x2, t) - x
            if abs(err) < 1e-7 { return coord(y1, y2, t) }
            let d = slope(x1, x2, t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let v = coord(x1, x2, t)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return coord(y1, y2, t)
    }
}

/// One @keyframes block: stops at 0…1 with property values. A property missing from a stop is
/// interpolated between the nearest stops that have it (as in CSS), with its default at 0% / 100%.
public struct CSSKeyframes: Sendable {
    public var stops: [(at: Double, values: [String: Double])]
    public var timing: CSSTiming
    public var duration: Double

    public init(duration: Double, timing: CSSTiming, _ stops: [(Double, [String: Double])]) {
        self.duration = duration
        self.timing = timing
        self.stops = stops.map { (at: $0.0, values: $0.1) }.sorted { $0.at < $1.at }
    }

    /// Several percentages sharing one set of values: `0%, 34%, 100% { … }`.
    public init(duration: Double, timing: CSSTiming, groups: [([Double], [String: Double])]) {
        self.init(duration: duration, timing: timing, groups.flatMap { g in g.0.map { ($0, g.1) } })
    }

    public var properties: Set<String> { Set(stops.flatMap { $0.values.keys }) }

    /// Value of `property` at progress `t` (0…1 of the loop).
    public func value(_ property: String, at t: Double, default fallback: Double) -> Double {
        let keyed = stops.compactMap { s in s.values[property].map { (s.at, $0) } }
        var points = keyed
        if points.first.map({ $0.0 > 0 }) ?? true { points.insert((0, fallback), at: 0) }
        if points.last.map({ $0.0 < 1 }) ?? true { points.append((1, fallback)) }
        let t = min(max(t, 0), 1)
        guard let i = points.lastIndex(where: { $0.0 <= t }) else { return points[0].1 }
        if i == points.count - 1 { return points[i].1 }
        let (a, va) = points[i], (b, vb) = points[i + 1]
        let p = b > a ? (t - a) / (b - a) : 1
        return va + (vb - va) * timing.apply(p)
    }

    /// Evenly spaced samples over one loop (inclusive of both ends), for Core Animation keyframes.
    public func samples(_ property: String, default fallback: Double, perSecond: Double = 30) -> [Double] {
        let n = max(2, Int((duration * perSecond).rounded()) + 1)
        return (0..<n).map { value(property, at: Double($0) / Double(n - 1), default: fallback) }
    }
}
