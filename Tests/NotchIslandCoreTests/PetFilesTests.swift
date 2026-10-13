import Foundation
import Testing
@testable import NotchIslandCore

struct PetPolicyTests {
    let policy = PetPolicy(home: URL(fileURLWithPath: "/Users/me"))

    @Test func staysInsideHome() {
        #expect(policy.resolve("/Users/me/Desktop/a.png")?.path == "/Users/me/Desktop/a.png")
        #expect(policy.resolve("~/Downloads")?.path == "/Users/me/Downloads")
        #expect(policy.resolve("/Users/me") == nil)               // the home folder itself
        #expect(policy.resolve("/Users/other/a") == nil)
        #expect(policy.resolve("/Users/me/../other/a") == nil)
        #expect(policy.resolve("/Users/meme/a") == nil)
        #expect(policy.resolve("Desktop/a") == nil)                // relative
    }

    @Test func libraryAndHiddenAreOffLimits() {
        #expect(policy.resolve("/Users/me/Library/Preferences/x.plist") == nil)
        #expect(policy.resolve("/Users/me/.ssh/id_rsa") == nil)
        #expect(policy.resolve("/Users/me/code/.git/config") == nil)
        #expect(policy.resolve("/Users/me/Documents/Library/x") != nil)   // only the top-level Library
    }
}

struct PetValidatorTests {
    let policy = PetPolicy(home: URL(fileURLWithPath: "/Users/me"))
    let disk: Set<String> = ["/Users/me/Desktop", "/Users/me/Desktop/a.png", "/Users/me/Desktop/b.png"]

    func check(_ actions: [PetAction]) -> [PetIssue] {
        PetValidator.validate(actions, policy: policy, exists: { disk.contains($0) })
    }

    @Test func folderMadeEarlierInThePlanCounts() {
        let issues = check([
            PetAction(.mkdir, "/Users/me/Desktop/Shots"),
            PetAction(.move, "/Users/me/Desktop/a.png", to: "/Users/me/Desktop/Shots/a.png"),
            PetAction(.move, "/Users/me/Desktop/b.png", to: "/Users/me/Desktop/Shots/b.png"),
        ])
        #expect(issues.isEmpty)
    }

    @Test func catchesProblems() {
        let issues = check([
            PetAction(.move, "/Users/me/Desktop/a.png", to: "/Users/me/Nowhere/a.png"),   // no such folder
            PetAction(.move, "/Users/me/Desktop/zzz.png", to: "/Users/me/Desktop/z.png"),  // no such file
            PetAction(.copy, "/Users/me/Desktop/a.png", to: "/Users/me/Desktop/b.png"),    // would overwrite
            PetAction(.trash, "/etc/hosts"),                                               // outside home
            PetAction(.move, "/Users/me/Desktop", to: "/Users/me/Desktop/inner"),          // into itself
        ])
        #expect(issues.map(\.index) == [0, 1, 2, 3, 4])
    }

    @Test func movedFileIsGoneForLaterSteps() {
        let issues = check([
            PetAction(.move, "/Users/me/Desktop/a.png", to: "/Users/me/Desktop/c.png"),
            PetAction(.trash, "/Users/me/Desktop/a.png"),
            PetAction(.trash, "/Users/me/Desktop/c.png"),
        ])
        #expect(issues.map(\.index) == [1])
    }
}

struct PetPlanParsingTests {
    @Test func readsStructuredOutput() throws {
        let json = #"{"type":"result","is_error":false,"result":"","structured_output":{"reply":"Готово","files":[],"actions":[{"kind":"trash","path":"/Users/me/a"}]}}"#
        let plan = try PetPlan.parse(cliOutput: Data(json.utf8))
        #expect(plan.reply == "Готово")
        #expect(plan.actions == [PetAction(.trash, "/Users/me/a")])
    }

    @Test func fallsBackToJSONInResultText() throws {
        let json = #"{"is_error":false,"result":"Вот план:\n```json\n{\"reply\":\"ок\",\"actions\":[]}\n```"}"#
        let plan = try PetPlan.parse(cliOutput: Data(json.utf8))
        #expect(plan.reply == "ок")
        #expect(plan.files.isEmpty)
    }

    @Test func readsMusicRequest() throws {
        let json = #"{"is_error":false,"structured_output":{"reply":"Включаю","files":[],"actions":[],"music":{"query":"Radiohead","type":"artist"}}}"#
        let plan = try PetPlan.parse(cliOutput: Data(json.utf8))
        #expect(plan.music == PetMusic(query: "Radiohead", type: .artist))
        // Unknown type still plays something; an empty query means no music at all.
        let odd = #"{"structured_output":{"reply":"","files":[],"actions":[],"music":{"query":"lofi","type":"mix"}}}"#
        #expect(try PetPlan.parse(cliOutput: Data(odd.utf8)).music == PetMusic(query: "lofi", type: .track))
        let empty = #"{"structured_output":{"reply":"","files":[],"actions":[],"music":{"query":" ","type":"track"}}}"#
        #expect(try PetPlan.parse(cliOutput: Data(empty.utf8)).music == nil)
    }

    @Test func schemaIsValidJSON() throws {
        #expect(try JSONSerialization.jsonObject(with: Data(PetPlan.jsonSchema.utf8)) is [String: Any])
    }

    @Test func recognisesMissingLogin() {
        let json = #"{"is_error":true,"result":"Failed to authenticate: OAuth session expired"}"#
        #expect(throws: PetPlan.ParseError.notLoggedIn) { try PetPlan.parse(cliOutput: Data(json.utf8)) }
    }
}

struct PetExecutorTests {
    @Test func runsAndUndoes() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pet-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let desk = home.appendingPathComponent("Desktop").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: desk + "/a.txt"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: desk + "/b.txt"))

        let exec = PetExecutor(policy: PetPolicy(home: home))
        let run = exec.run([
            PetAction(.mkdir, desk + "/Notes"),
            PetAction(.move, desk + "/a.txt", to: desk + "/Notes/a.txt"),
            PetAction(.copy, desk + "/b.txt", to: desk + "/Notes/b.txt"),
        ])
        #expect(run.error == nil)
        #expect(run.completed == 3)
        #expect(fm.fileExists(atPath: desk + "/Notes/a.txt"))
        #expect(!fm.fileExists(atPath: desk + "/a.txt"))

        // The folder isn't empty until the copy and the moved file are gone — undo goes newest first.
        let failed = exec.undo(run.undo)
        #expect(failed == 0)
        #expect(fm.fileExists(atPath: desk + "/a.txt"))
        #expect(fm.fileExists(atPath: desk + "/b.txt"))
        #expect(!fm.fileExists(atPath: desk + "/Notes"))
    }

    @Test func stopsAtFirstFailure() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pet-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let docs = home.appendingPathComponent("Docs").path

        let run = PetExecutor(policy: PetPolicy(home: home)).run([
            PetAction(.mkdir, docs + "/A"),
            PetAction(.move, docs + "/missing.txt", to: docs + "/A/missing.txt"),
            PetAction(.mkdir, docs + "/B"),
        ])
        #expect(run.completed == 1)
        #expect(run.error != nil)
        #expect(run.undo.count == 1)
        #expect(!fm.fileExists(atPath: docs + "/B"))
    }
}

struct PetPlanSchemaTests {
    @Test func musicMayBeNull() throws {
        // Models often send "music": null when there's nothing to play; the schema must allow it.
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(PetPlan.jsonSchema.utf8)) as? [String: Any])
        let music = try #require((schema["properties"] as? [String: Any])?["music"] as? [String: Any])
        #expect((music["type"] as? [String])?.contains("null") == true)
        let plan = try JSONDecoder().decode(PetPlan.self, from: Data(#"{"reply":"ок","files":[],"actions":[],"music":null}"#.utf8))
        #expect(plan.music == nil)
    }
}
