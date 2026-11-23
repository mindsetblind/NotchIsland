import Foundation

/// NotchIsland's own notification sounds, synthesized as soft bell tones (no audio files in the bundle).
public enum Chime: String, CaseIterable, Sendable {
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
        case .bell:  [Note(frequency: 1318.5, delay: 0), Note(frequency: 1975.5, delay: 0.12)]          // E6, B6
        case .drop:  [Note(frequency: 1046.5, delay: 0)]                                                // C6
        case .chord: [Note(frequency: 1046.5, delay: 0), Note(frequency: 1318.5, delay: 0.09),
                      Note(frequency: 1568.0, delay: 0.18)]                                             // C6 E6 G6
        }
    }

    /// How fast a note fades (seconds until it is ~37% as loud).
    var decay: Double { self == .drop ? 0.18 : 0.32 }

    public static let sampleRate = 44_100

    /// Mono 16-bit samples, peak at about half of full scale so it never sounds harsh.
    public func samples() -> [Int16] {
        let rate = Double(Self.sampleRate)
        let length = (notes.map(\.delay).max() ?? 0) + decay * 6
        var mix = [Double](repeating: 0, count: Int(length * rate))
        // A bell: fundamental, a soft octave and a quiet inharmonic partial for shimmer.
        let partials: [(ratio: Double, gain: Double, decay: Double)] = [(1, 1, 1), (2, 0.28, 0.6), (2.76, 0.08, 0.4)]
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
        let scale = peak > 0 ? 0.5 / peak : 0
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
