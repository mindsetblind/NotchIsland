import Foundation

/// NotchIsland's own notification sounds, synthesized as bell tones (no audio files in the bundle).
public enum Chime: String, CaseIterable, Sendable {
    /// A quick bright run of four notes up (E major): clearly heard from across the room.
    case ring
    /// Two notes going up a fifth: "done".
    case bell
    /// One short, round note.
    case drop
    /// Three notes of a major chord one after another.
    case chord

    struct Note {
        let frequency: Double
        let delay: Double
    }

    var notes: [Note] {
        switch self {
        case .ring:  [Note(frequency: 1318.5, delay: 0), Note(frequency: 1661.2, delay: 0.065),
                      Note(frequency: 1975.5, delay: 0.13), Note(frequency: 2637.0, delay: 0.195)]             // E6 G#6 B6 E7
        case .bell:  [Note(frequency: 1318.5, delay: 0), Note(frequency: 1975.5, delay: 0.12)]          // E6, B6
        case .drop:  [Note(frequency: 1046.5, delay: 0)]                                                // C6
        case .chord: [Note(frequency: 1046.5, delay: 0), Note(frequency: 1318.5, delay: 0.09),
                      Note(frequency: 1568.0, delay: 0.18)]                                             // C6 E6 G6
        }
    }

    /// How fast a note fades (seconds until it is ~37% as loud).
    var decay: Double {
        switch self {
        case .drop: 0.18
        case .ring: 0.26
        default:    0.32
        }
    }

    /// Overtones: a bell's fundamental, octave and inharmonic shimmer; brighter and louder for `ring`.
    var partials: [(ratio: Double, gain: Double, decay: Double)] {
        self == .ring
            ? [(1, 1, 1), (2, 0.5, 0.7), (3, 0.18, 0.5), (2.76, 0.14, 0.4)]
            : [(1, 1, 1), (2, 0.28, 0.6), (2.76, 0.08, 0.4)]
    }

    /// Peak level as a share of full scale.
    var level: Double { self == .ring ? 0.75 : 0.5 }

    public static let sampleRate = 44_100

    /// Mono 16-bit samples, peaking at `level` (below full scale, so it never clips).
    public func samples() -> [Int16] {
        let rate = Double(Self.sampleRate)
        let length = (notes.map(\.delay).max() ?? 0) + decay * 6
        var mix = [Double](repeating: 0, count: Int(length * rate))
        for note in notes {
            let start = Int(note.delay * rate)
            for i in 0..<(mix.count - start) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.004)
                var v = 0.0
                for p in partials {
                    v += p.gain * exp(-t / (decay * p.decay)) * sin(2 * .pi * note.frequency * p.ratio * t)
                }
                mix[start + i] += attack * v
            }
        }
        let peak = mix.map(abs).max() ?? 1
        let scale = peak > 0 ? level / peak : 0
        return mix.map { Int16(($0 * scale * Double(Int16.max)).rounded()) }
    }

    /// The sound as a WAV file in memory (NSSound(data:) plays it).
    public func wav() -> Data {
        let pcm = samples()
        let dataSize = UInt32(pcm.count * 2)
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1))                                  // PCM, mono
        put(UInt32(Self.sampleRate)); put(UInt32(Self.sampleRate * 2))  // sample rate, byte rate
        put(UInt16(2)); put(UInt16(16))                                 // block align, bits per sample
        d.append(contentsOf: Array("data".utf8)); put(dataSize)
        for s in pcm { put(s) }
        return d
    }
}
