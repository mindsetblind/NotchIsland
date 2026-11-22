import Foundation
import Testing
@testable import NotchIslandCore

struct HookSettingsFileTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func missingOrBlankFileMeansNoSettings() throws {
        #expect(try HookSettingsFile.parse(nil).isEmpty)
        #expect(try HookSettingsFile.parse(data("")).isEmpty)
        #expect(try HookSettingsFile.parse(data("  \n\t")).isEmpty)
    }

    @Test func keepsEverythingInAValidFile() throws {
        let s = try HookSettingsFile.parse(data(#"{"model":"opus","hooks":{"Stop":[]},"env":{"A":"1"}}"#))
        #expect(s["model"] as? String == "opus")
        #expect(s["hooks"] is [String: Any])
        #expect((s["env"] as? [String: String])?["A"] == "1")
    }

    /// The bug: a file that doesn't parse (cut short, a missing quote after a hand edit) used to read
    /// as {} and get overwritten with only NotchIsland's hooks.
    @Test func refusesInvalidJSONInsteadOfStartingOver() {
        #expect(throws: HookSettingsFile.ReadError.self) {
            try HookSettingsFile.parse(data(#"{"model":"opus", "env": {"A": 1}"#))
        }
        #expect(throws: HookSettingsFile.ReadError.self) {
            try HookSettingsFile.parse(data(#"{"model": "#))
        }
    }

    @Test func refusesJSONThatIsNotAnObject() {
        #expect(throws: HookSettingsFile.ReadError.notAnObject) { try HookSettingsFile.parse(data("[1, 2]")) }
        #expect(throws: HookSettingsFile.ReadError.notAnObject) { try HookSettingsFile.parse(data(#""text""#)) }
    }

    @Test func readsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try HookSettingsFile.read(at: dir.appendingPathComponent("absent.json")).isEmpty)

        let good = dir.appendingPathComponent("settings.json")
        try data(#"{"model":"opus"}"#).write(to: good)
        #expect(try HookSettingsFile.read(at: good)["model"] as? String == "opus")

        let broken = dir.appendingPathComponent("broken.json")
        try data(#"{"model":"opus" "env"}"#).write(to: broken)
        #expect(throws: HookSettingsFile.ReadError.self) { try HookSettingsFile.read(at: broken) }

        // A folder where the file should be: exists, but can't be read.
        let folder = dir.appendingPathComponent("folder.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: HookSettingsFile.ReadError.self) { try HookSettingsFile.read(at: folder) }
    }
}
