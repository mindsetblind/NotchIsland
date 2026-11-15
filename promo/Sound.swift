// Procedural soundtrack for the teaser, timed to the same timeline as the picture.
// Everything is synthesised: drone, trace-on pings, riser, burst, reverse swell, impact,
// display pad, fly-by whoosh, island bloop, dock chime, soft pulse and the title chord.

import Foundation

let SR = 48_000

struct Mix {
    let n: Int
    var l: [Float], r: [Float], sl: [Float], sr: [Float]
    init(seconds: Float) {
        n = Int(seconds * Float(SR))
        l = .init(repeating: 0, count: n); r = l; sl = l; sr = l
    }
    mutating func put(_ i: Int, _ v: Float, pan: Float, send: Float) {
        guard i >= 0, i < n else { return }
        let a = (pan + 1) * .pi / 4
        let gl = cos(a), gr = sin(a)
        l[i] += v * gl; r[i] += v * gr
        sl[i] += v * gl * send; sr[i] += v * gr * send
    }
}

struct RNG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) * 2 - 1 } }

extension Mix {
    /// Sine-ish voice: freq(t) Hz, env(t) amplitude, t local seconds.
    mutating func tone(_ t0: Float, _ dur: Float, freq: (Float) -> Float, env: (Float) -> Float,
                       pan: (Float) -> Float = { _ in 0 }, gain: Float, send: Float = 0.3, harmonics: [Float] = [1]) {
        var ph: Double = 0
        let s0 = Int(t0 * Float(SR)), cnt = Int(dur * Float(SR))
        for k in 0..<cnt {
            let t = Float(k) / Float(SR)
            ph += Double(freq(t)) / Double(SR)
            var v: Float = 0
            for (h, a) in harmonics.enumerated() { v += a * Float(sin(2 * .pi * ph * Double(h + 1))) }
            put(s0 + k, v * env(t) * gain, pan: pan(t), send: send)
        }
    }
    /// Band-limited noise: two one-pole lowpasses, the difference gives a band around `cut`.
    mutating func noise(_ t0: Float, _ dur: Float, cut: (Float) -> Float, env: (Float) -> Float, pan: (Float) -> Float = { _ in 0 },
                        gain: Float, send: Float = 0.3, seed: UInt64 = 1, band: Bool = true) {
        var rng = RNG(s: seed)
        var lp1: Float = 0, lp2: Float = 0
        let s0 = Int(t0 * Float(SR)), cnt = Int(dur * Float(SR))
        for k in 0..<cnt {
            let t = Float(k) / Float(SR)
            let c = min(0.99, 2 * .pi * cut(t) / Float(SR))
            let x = rng.next()
            lp1 += c * (x - lp1)
            lp2 += c * 0.25 * (x - lp2)
            let v = band ? (lp1 - lp2) * 1.6 : lp1
            put(s0 + k, v * env(t) * gain, pan: pan(t), send: send)
        }
    }
    /// Struck bell: inharmonic partials with their own decays.
    mutating func bell(_ t0: Float, _ f: Float, gain: Float, decay: Float = 2.5, pan: Float = 0, send: Float = 0.7) {
        let parts: [(Float, Float, Float)] = [(1, 1, 1), (2.0, 0.45, 1.6), (2.76, 0.25, 2.4), (5.4, 0.12, 4), (8.93, 0.05, 6)]
        for (m, a, dk) in parts {
            tone(t0, decay * 1.6, freq: { _ in f * m }, env: { t in min(1, t / 0.002) * exp(-t * dk / decay * 1.6) * a },
                 pan: { _ in pan }, gain: gain, send: send)
        }
    }
    mutating func kick(_ t0: Float, gain: Float, from: Float = 120, to: Float = 42, len: Float = 0.45) {
        tone(t0, len, freq: { t in to + (from - to) * exp(-t * 28) }, env: { t in min(1, t / 0.003) * exp(-t * 7) }, gain: gain, send: 0.05)
        noise(t0, 0.012, cut: { _ in 6000 }, env: { t in 1 - t / 0.012 }, gain: gain * 0.25, send: 0, seed: UInt64(t0 * 1000))
    }

    /// Small stereo reverb on the send bus (Freeverb-ish: combs into allpasses).
    mutating func reverb(wet: Float) {
        func process(_ x: [Float], offset: Int) -> [Float] {
            let combs = [1557, 1617, 1491, 1422, 1277, 1356].map { Int(Float($0 + offset) * 1.6) }
            var out = [Float](repeating: 0, count: n)
            for d in combs {
                var buf = [Float](repeating: 0, count: d), i = 0, store: Float = 0
                for k in 0..<n {
                    let y = buf[i]
                    store = y * 0.75 + store * 0.25
                    buf[i] = x[k] + store * 0.86
                    i = (i + 1) % d
                    out[k] += y
                }
            }
            for d in [556, 441, 341].map({ Int(Float($0 + offset) * 1.6) }) {
                var buf = [Float](repeating: 0, count: d), i = 0
                for k in 0..<n {
                    let b = buf[i]
                    let y = -out[k] + b
                    buf[i] = out[k] + b * 0.5
                    i = (i + 1) % d
                    out[k] = y
                }
            }
            return out
        }
        let wl = process(sl, offset: 0), wr = process(sr, offset: 23)
        for k in 0..<n { l[k] += wl[k] * wet / 6; r[k] += wr[k] * wet / 6 }
    }
}

func soundtrack(duration: Float, petStagger: [Float]) -> [Int16] {
    var m = Mix(seconds: duration)
    func sm(_ x: Float) -> Float { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }

    // 1. Drone: low A + E, slow swell, a lift when the display wakes, out at the end.
    let droneEnv: (Float) -> Float = { t in
        let g = (0.25 + 0.75 * sm(t / 2.2)) * (1 + 0.5 * sm((t - 3.8) / 1.2)) * (1 - 0.55 * sm((t - 2.5) / 0.15) * (1 - sm((t - 3.6) / 0.2)))
        return g * (1 - sm((t - duration + 0.6) / 0.6))
    }
    m.tone(0, duration, freq: { _ in 55 }, env: droneEnv, pan: { _ in -0.2 }, gain: 0.16, send: 0.1, harmonics: [1, 0.3, 0.1])
    m.tone(0, duration, freq: { t in 82.41 * (1 + 0.002 * sin(t * 0.7)) }, env: droneEnv, pan: { _ in 0.2 }, gain: 0.1, send: 0.2, harmonics: [1, 0.2])
    m.noise(0, duration, cut: { t in 300 + 500 * sm(t / 4) }, env: droneEnv, gain: 0.05, send: 0.4, seed: 7, band: false)

    // 2. Trace-on: a glassy ping for every face as its edges draw.
    let pent: [Float] = [1760, 1975.5, 2217.5, 2637, 2960, 3520, 3951]
    for (i, st) in petStagger.enumerated() {
        let t0 = 0.35 + st * 1.35
        let f = pent[Int(st * 997) % pent.count]
        let pan = Float(i % 2 == 0 ? -1 : 1) * (0.3 + 0.6 * st)
        m.tone(t0, 0.9, freq: { _ in f }, env: { t in min(1, t / 0.002) * exp(-t * 7) }, pan: { _ in pan }, gain: 0.045, send: 0.7, harmonics: [1, 0, 0.15])
        m.noise(t0, 0.02, cut: { _ in 9000 }, env: { t in 1 - t / 0.02 }, pan: { _ in pan }, gain: 0.05, send: 0.2, seed: UInt64(i + 11))
    }
    // Core ignition: soft sub swell + air.
    m.tone(0.05, 1.6, freq: { t in 40 + 15 * t }, env: { t in sm(t / 0.6) * exp(-t * 1.5) }, gain: 0.3, send: 0.1)

    // 3. Riser into the burst.
    m.noise(1.75, 0.8, cut: { t in 300 + 9000 * pow(t / 0.8, 2) }, env: { t in pow(t / 0.8, 2.5) }, gain: 0.35, send: 0.3, seed: 21)
    m.tone(1.75, 0.8, freq: { t in 220 * pow(4, t / 0.8) }, env: { t in pow(t / 0.8, 3) }, gain: 0.05, send: 0.5, harmonics: [1, 0.3])

    // 4. Burst at 2.55: thump + wide whoosh outwards + sparkle.
    m.kick(2.55, gain: 0.7, from: 110, to: 34, len: 0.9)
    m.noise(2.55, 1.0, cut: { t in 9000 * exp(-t * 3.5) + 300 }, env: { t in min(1, t / 0.004) * exp(-t * 3.2) }, pan: { t in -0.7 * min(1, t * 3) },
            gain: 0.45, send: 0.5, seed: 31)
    m.noise(2.55, 1.0, cut: { t in 9000 * exp(-t * 3.5) + 300 }, env: { t in min(1, t / 0.004) * exp(-t * 3.2) }, pan: { t in 0.7 * min(1, t * 3) },
            gain: 0.45, send: 0.5, seed: 32)
    for k in 0..<8 {
        let fk = Float(k)
        m.bell(2.6 + fk * 0.07, 2200 + 400 * fk.truncatingRemainder(dividingBy: 3), gain: 0.02, decay: 0.8, pan: k % 2 == 0 ? -0.6 : 0.6, send: 0.8)
    }

    // 5. Reverse swell sucking the faces back in.
    m.noise(3.1, 0.64, cut: { t in 400 + 10000 * pow(t / 0.64, 3) }, env: { t in pow(t / 0.64, 4) }, gain: 0.55, send: 0.2, seed: 41)
    m.tone(3.1, 0.64, freq: { t in 110 * pow(2, 2 * t / 0.64) }, env: { t in pow(t / 0.64, 4) }, gain: 0.08, send: 0.2, harmonics: [1, 0.5, 0.25])

    // 6. Snap: click, deep boom, metallic ring with a long tail.
    m.noise(3.74, 0.02, cut: { _ in 12000 }, env: { t in 1 - t / 0.02 }, gain: 0.6, send: 0.3, seed: 51, band: false)
    m.kick(3.74, gain: 1.0, from: 160, to: 36, len: 1.4)
    m.bell(3.74, 523.25, gain: 0.12, decay: 3.2, pan: -0.15, send: 0.9)
    m.bell(3.745, 784, gain: 0.07, decay: 2.8, pan: 0.2, send: 0.9)

    // 7. Display wakes: A major 9 pad swelling in.
    let pad: [Float] = [220, 277.18, 329.63, 415.3, 493.88]
    for (i, f) in pad.enumerated() {
        let pan = Float(i) / 2 - 1
        m.tone(3.8, duration - 3.8, freq: { t in f * (1 + 0.003 * sin(t * (3 + Float(i)))) },
               env: { t in sm(t / 1.0) * (0.7 + 0.3 * sm((t - 5.0) / 0.6)) * (1 - 0.4 * sm((t - 2.0) / 1.0)) * (1 - sm((t - (duration - 3.8) + 0.5) / 0.5)) },
               pan: { _ in pan * 0.7 }, gain: 0.035, send: 0.8, harmonics: [1, 0.25, 0.08])
    }

    // 8. Fly-by whoosh into the notch (doppler-ish pitch drop).
    m.noise(5.0, 1.4, cut: { t in 700 + 3500 * sin(.pi * min(1, t / 1.3)) }, env: { t in sin(.pi * min(1, t / 1.35)) * (0.3 + 0.7 * t / 1.4) },
            pan: { t in 0.6 - 1.2 * t / 1.4 }, gain: 0.45, send: 0.35, seed: 61)
    m.tone(5.0, 1.35, freq: { t in 900 - 500 * t / 1.35 }, env: { t in sin(.pi * t / 1.35) }, pan: { t in 0.5 - t / 1.35 }, gain: 0.03, send: 0.5)

    // 9. Island opens: a springy bloop.
    m.tone(5.75, 0.6, freq: { t in 260 + 260 * (1 - exp(-t * 9) * cos(t * 30)) }, env: { t in min(1, t / 0.01) * exp(-t * 6) }, gain: 0.18, send: 0.4,
           harmonics: [1, 0.3])

    // 10. Dock chime.
    m.kick(6.32, gain: 0.45, from: 90, to: 45, len: 0.5)
    m.bell(6.32, 1318.5, gain: 0.11, decay: 2.4, pan: -0.25, send: 0.75)
    m.bell(6.40, 1975.5, gain: 0.08, decay: 2.2, pan: 0.25, send: 0.75)
    m.bell(6.48, 2637, gain: 0.05, decay: 2.0, pan: 0, send: 0.8)

    // 11. Soft pulse while the island "plays" (120 bpm), with ticks.
    var beat: Float = 6.82
    while beat < 8.7 {
        m.kick(beat, gain: 0.22, from: 95, to: 48, len: 0.35)
        m.noise(beat + 0.25, 0.05, cut: { _ in 9000 }, env: { t in exp(-t * 60) }, pan: { _ in 0.3 }, gain: 0.09, send: 0.2, seed: UInt64(beat * 100))
        beat += 0.5
    }

    // 12. Title: reverse air into a bright chord and a sparkle.
    m.noise(8.35, 0.5, cut: { t in 500 + 8000 * pow(t / 0.5, 2) }, env: { t in pow(t / 0.5, 3) }, gain: 0.3, send: 0.3, seed: 71)
    m.kick(8.85, gain: 0.55, from: 120, to: 38, len: 1.0)
    for (i, f) in ([440, 554.37, 659.25, 830.61, 987.77, 1318.5] as [Float]).enumerated() {
        m.tone(8.85, duration - 8.85, freq: { _ in f }, env: { t in min(1, t / 0.02) * exp(-t * 0.9) },
               pan: { _ in Float(i) / 2.5 - 1 }, gain: 0.05, send: 0.85, harmonics: [1, 0.2])
    }
    for k in 0..<6 { m.bell(8.9 + Float(k) * 0.06, [2637, 3520, 2960, 3951, 4434, 5274][k], gain: 0.018, decay: 1.2, pan: k % 2 == 0 ? -0.5 : 0.5) }

    m.reverb(wet: 0.9)

    // Master: soft clip, normalise, fade the very end.
    var peak: Float = 0
    for k in 0..<m.n { m.l[k] = tanh(m.l[k] * 1.2); m.r[k] = tanh(m.r[k] * 1.2); peak = max(peak, abs(m.l[k]), abs(m.r[k])) }
    let g = 0.89 / max(peak, 1e-4)
    var out = [Int16](repeating: 0, count: m.n * 2)
    for k in 0..<m.n {
        let t = Float(k) / Float(SR)
        let f = min(1, t / 0.05) * min(1, max(0, (duration - t) / 0.25))
        out[2 * k] = Int16(max(-1, min(1, m.l[k] * g * f)) * 32767)
        out[2 * k + 1] = Int16(max(-1, min(1, m.r[k] * g * f)) * 32767)
    }
    return out
}
