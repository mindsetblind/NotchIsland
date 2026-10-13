import Testing
@testable import NotchIslandCore

struct CSSKeyframesTests {
    @Test func timingFunctions() {
        #expect(CSSTiming.linear.apply(0.3) == 0.3)
        #expect(abs(CSSTiming.easeInOut.apply(0.5) - 0.5) < 1e-6)
        #expect(CSSTiming.easeInOut.apply(0.1) < 0.1)                 // slow start
        #expect(CSSTiming.steps(4).apply(0.24) == 0)
        #expect(CSSTiming.steps(4).apply(0.26) == 0.25)
        #expect(CSSTiming.steps(4).apply(1) == 1)
        // The "done" bounce overshoots past the target.
        let bounce = CSSTiming.cubicBezier(0.34, 1.56, 0.64, 1)
        #expect((0...20).map { bounce.apply(Double($0) / 20) }.max()! > 1.05)
    }

    @Test func interpolatesLikeCSS() {
        // @keyframes ear-left { 0%, 65%, 100% { rotate 0 } 72% { -14 } 79% { 5 } }, linear here
        let ear = CSSKeyframes(duration: 3.2, timing: .linear, groups: [
            ([0, 0.65, 1], ["rot": 0]), ([0.72], ["rot": -14]), ([0.79], ["rot": 5]),
        ])
        #expect(ear.value("rot", at: 0.3, default: 0) == 0)
        #expect(ear.value("rot", at: 0.72, default: 0) == -14)
        #expect(abs(ear.value("rot", at: 0.755, default: 0) - (-4.5)) < 1e-9)
    }

    @Test func missingPropertiesUseNeighboursAndDefaults() {
        // wave-paw: opacity everywhere, rotation only in the middle.
        let k = CSSKeyframes(duration: 2, timing: .linear, [(0.5, ["rot": 40, "op": 1]), (1, ["op": 0])])
        #expect(k.value("rot", at: 0.25, default: 0) == 20)   // from the implicit 0 at 0%
        #expect(k.value("op", at: 0.75, default: 0) == 0.5)
        #expect(k.samples("rot", default: 0, perSecond: 2).count == 5)
    }

    @Test func stepsHoldValues() {
        let k = CSSKeyframes(duration: 1, timing: .steps(2), [(0, ["x": 0]), (1, ["x": 10])])
        #expect(k.value("x", at: 0.4, default: 0) == 0)
        #expect(k.value("x", at: 0.6, default: 0) == 5)
    }
}
