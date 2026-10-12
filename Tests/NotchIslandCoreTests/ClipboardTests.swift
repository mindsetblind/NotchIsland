import Foundation
import Testing
@testable import NotchIslandCore

struct SecretDetectorTests {
    @Test(arguments: [
        "ghp_aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5",
        "xoxb-1234567890-abcdefghijkl",
        "sk-ant-api03-AbCdEf1234567890_abcdefXYZ",
        "sk_live_51HabcdefGHIJKLmnop",
        "AKIAIOSFODNN7EXAMPLE",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "password = hunter2hunter2",
        "export API_KEY=abcd1234efgh5678",
        "postgres://admin:s3cr3tP4ss@db.example.com:5432/app",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
        "x7#Kq9!vB2m$Lp4zR8wT",      // generated password
        "Tr0ub4dor&3xK9#mQ2vL",
    ])
    func flagsLikelySecrets(_ text: String) {
        #expect(SecretDetector.isLikelySecret(text), "\(text)")
    }

    @Test(arguments: [
        "Привет, как дела?",
        "https://github.com/mindsetblind/NotchIsland/pull/12?tab=files",
        "/Users/me/Projects/NotchIsland/Sources/Model.swift",
        "550e8400-e29b-41d4-a716-446655440000",
        "96d2e5b7c1a04f3e9b2d8c6a5f4e3d2c1b0a9f8e",
        "activityCoordinatorDidChange",
        "swift build -c release",
        "ivan@example.com",
        "The password field must be at least 8 characters long.",
        "let x = 42",
        "ScreenshotFinal2024.png",
    ])
    func keepsOrdinaryText(_ text: String) {
        #expect(!SecretDetector.isLikelySecret(text), "\(text) → \(String(describing: SecretDetector.reason(text)))")
    }
}

@MainActor
struct ClipboardStoreTests {
    final class Clock { var now = Date(timeIntervalSince1970: 2_000_000) }

    func makeStore(_ policy: ClipboardPolicy = ClipboardPolicy(), file: URL? = nil, clock: Clock = Clock()) -> ClipboardStore {
        ClipboardStore(fileURL: file, policy: policy, now: { clock.now })
    }

    @Test func addsNewestFirstAndDetectsLinks() {
        let c = Clock()
        let s = makeStore(clock: c)
        #expect(s.add("hello") == .added)
        c.now += 1
        #expect(s.add("https://apple.com") == .added)
        #expect(s.items.map(\.text) == ["https://apple.com", "hello"])
        #expect(s.items.first?.kind == .link)
        #expect(s.items.last?.kind == .text)
    }

    @Test func copyingAgainMovesToTopWithoutDuplicates() {
        let c = Clock()
        let s = makeStore(clock: c)
        s.add("a"); c.now += 1
        s.add("b"); c.now += 1
        #expect(s.add("a") == .bumped)
        #expect(s.items.map(\.text) == ["a", "b"])
    }

    @Test func skipsEmptyHugeAndSecretText() {
        let s = makeStore(ClipboardPolicy(maxLength: 10))
        #expect(s.add("   \n") == .skippedEmpty)
        #expect(s.add(String(repeating: "x", count: 11)) == .skippedTooLong)
        #expect(s.add("ghp_aB3dE5fG7hI9jK1lM3nO5pQ7") == .skippedTooLong)
        let open = makeStore()
        #expect(open.add("ghp_aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5") == .skippedSecret)
        #expect(open.items.isEmpty)
    }

    @Test func secretFilterCanBeSwitchedOff() {
        let s = makeStore(ClipboardPolicy(skipLikelySecrets: false))
        #expect(s.add("ghp_aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5") == .added)
    }

    @Test func countLimitDropsOldestUnpinned() {
        let c = Clock()
        let s = makeStore(ClipboardPolicy(maxItems: 3), clock: c)
        for i in 0..<3 { s.add("item \(i)"); c.now += 1 }
        s.setPinned(s.items.last!.id, true)        // "item 0" survives
        for i in 3..<6 { s.add("item \(i)"); c.now += 1 }
        #expect(s.items.map(\.text) == ["item 0", "item 5", "item 4", "item 3"])
    }

    @Test func oldItemsExpireButPinnedStay() {
        let c = Clock()
        let s = makeStore(ClipboardPolicy(maxAge: 60), clock: c)
        s.add("keep"); s.add("forget")
        s.setPinned(s.items.first { $0.text == "keep" }!.id, true)
        c.now += 61
        s.prune()
        #expect(s.items.map(\.text) == ["keep"])
    }

    @Test func pinnedComeFirstAndPinLimitHolds() {
        let c = Clock()
        let s = makeStore(ClipboardPolicy(maxPinned: 1), clock: c)
        s.add("a"); c.now += 1
        s.add("b"); c.now += 1
        let a = s.items.first { $0.text == "a" }!.id
        let b = s.items.first { $0.text == "b" }!.id
        s.setPinned(a, true)
        #expect(s.items.first?.text == "a")
        s.setPinned(b, true)                       // over the limit: ignored
        #expect(s.items.filter(\.pinned).count == 1)
    }

    @Test func removeAndClear() {
        let s = makeStore()
        s.add("a"); s.add("b"); s.add("c")
        s.remove(s.items.first { $0.text == "b" }!.id)
        #expect(Set(s.items.map(\.text)) == ["a", "c"])
        s.setPinned(s.items.first!.id, true)
        s.clearUnpinned()
        #expect(s.items.count == 1)
        s.clearAll()
        #expect(s.items.isEmpty)
    }

    @Test func searchMatchesAllWordsIgnoringCaseAndAccents() {
        let s = makeStore()
        s.add("Café au lait recipe")
        s.add("Swift concurrency notes")
        s.add("https://example.com/cafe")
        #expect(s.search("cafe").count == 2)
        #expect(s.search("SWIFT notes").map(\.text) == ["Swift concurrency notes"])
        #expect(s.search("swift recipe").isEmpty)
        #expect(s.search("  ").count == 3)
    }

    @Test func persistsWithOwnerOnlyPermissionsAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        let s = makeStore(file: file)
        s.add("persist me")
        s.setPinned(s.items[0].id, true)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        let reloaded = makeStore(file: file)
        #expect(reloaded.items.map(\.text) == ["persist me"])
        #expect(reloaded.items.first?.pinned == true)

        reloaded.clearAll()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableFileIsSetAsideNotDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        try Data("not json".utf8).write(to: file)
        let s = makeStore(file: file)
        #expect(s.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.unreadable.json").path))
    }
}
