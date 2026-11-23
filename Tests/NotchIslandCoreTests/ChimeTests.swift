import Foundation
import NotchIslandCore
import XCTest

final class ChimeTests: XCTestCase {
    func testWAVHeaderMatchesSamples() {
        for chime in Chime.allCases {
            let wav = chime.wav()
            let count = chime.samples().count
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(wav.count, 44 + count * 2, "\(chime)")
        }
    }

    func testSoundIsShortAudibleAndNotClipped() {
        for chime in Chime.allCases {
            let s = chime.samples()
            let seconds = Double(s.count) / Double(Chime.sampleRate)
            XCTAssertGreaterThan(seconds, 0.5, "\(chime)")
            XCTAssertLessThan(seconds, 2.5, "\(chime)")
            let peak = s.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, Int(Int16.max) / 3, "\(chime)")
            XCTAssertLessThan(peak, Int(Int16.max) * 6 / 10, "\(chime)")
            // Fades out instead of cutting off with a click.
            let tail = s.suffix(200).map { abs(Int($0)) }.max() ?? 0
            XCTAssertLessThan(tail, 300, "\(chime)")
        }
    }
}
