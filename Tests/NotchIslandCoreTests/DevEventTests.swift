import Foundation
import Testing
@testable import NotchIslandCore

struct DevEventParserTests {
    func parse(_ json: String) throws -> DevEvent { try DevEventParser.parse(Data(json.utf8)) }

    @Test func parsesAFullStartEvent() throws {
        let e = try parse(#"{"v":1,"type":"task","event":"start","id":"web-build","title":"npm run build","category":"build","source":"npm"}"#)
        #expect(e.kind == .start)
        #expect(e.id == "web-build")
        #expect(e.title == "npm run build")
        #expect(e.category == .build)
        #expect(e.source == "npm")
    }

    @Test func finishTakesStatusOrExitCode() throws {
        #expect(try parse(#"{"v":1,"type":"task","event":"finish","id":"a","status":"failure"}"#).status == .failure)
        #expect(try parse(#"{"v":1,"type":"task","event":"finish","id":"a","exit_code":0}"#).status == .success)
        #expect(try parse(#"{"v":1,"type":"task","event":"finish","id":"a","exit_code":2}"#).status == .failure)
        #expect(throws: DevEventError.missingStatus) { try parse(#"{"v":1,"type":"task","event":"finish","id":"a"}"#) }
    }

    @Test func clampsProgressAndToleratesUnknownCategories() throws {
        let e = try parse(#"{"v":1,"type":"task","event":"progress","id":"a","progress":7,"category":"quantum"}"#)
        #expect(e.progress == 1)
        #expect(e.category == .other)
    }

    @Test(arguments: [
        ("not json", DevEventError.notJSON),
        (#"[1,2]"#, .notJSON),
        (#"{"type":"task","event":"start","id":"a"}"#, .wrongVersion),
        (#"{"v":2,"type":"task","event":"start","id":"a"}"#, .wrongVersion),
        (#"{"v":true,"type":"task","event":"start","id":"a"}"#, .wrongVersion),
        (#"{"v":1,"type":"exec","event":"start","id":"a"}"#, .notATaskEvent),
        (#"{"v":1,"type":"task","event":"rm -rf","id":"a"}"#, .unknownEvent("rm -rf")),
        (#"{"v":1,"type":"task","event":"start","id":""}"#, .badID),
        (#"{"v":1,"type":"task","event":"start","id":"../../etc/passwd; ls"}"#, .badID),
        (#"{"v":1,"type":"task","event":"start","id":"тест"}"#, .badID),
        (#"{"v":1,"type":"task","event":"start","id":"a","title":42}"#, .badField("title")),
        (#"{"v":1,"type":"task","event":"progress","id":"a","progress":"half"}"#, .badField("progress")),
        (#"{"v":1,"type":"task","event":"finish","id":"a","status":"maybe"}"#, .badField("status")),
    ])
    func rejectsMalformedEvents(_ json: String, _ error: DevEventError) {
        #expect(throws: error) { try parse(json) }
    }

    @Test func rejectsOversizedMessages() {
        let big = #"{"v":1,"type":"task","event":"start","id":"a","title":""# + String(repeating: "x", count: 9000) + #""}"#
        #expect(throws: DevEventError.tooLarge) { try parse(big) }
    }

    @Test func sanitisesText() throws {
        let e = try parse(#"{"v":1,"type":"task","event":"message","id":"a","message":"line1\n\u001b[31mred\u001b[0m\tend"}"#)
        #expect(e.message == "line1 [31mred [0m end")
        let long = try parse(#"{"v":1,"type":"task","event":"start","id":"a","title":""# + String(repeating: "я", count: 200) + #""}"#)
        #expect(long.title?.count == DevEventParser.maxTitleLength)
        #expect(long.title?.hasSuffix("…") == true)
        let blank = try parse(#"{"v":1,"type":"task","event":"start","id":"a","title":"  \n "}"#)
        #expect(blank.title == nil)
    }

    @Test func recognisesDevEventsAmongHookEvents() {
        #expect(DevEventParser.isDevEvent(["v": 1, "type": "task"]))
        #expect(!DevEventParser.isDevEvent(["hook_event_name": "Stop", "session_id": "x"]))
    }
}

@MainActor
struct DevTaskTrackerTests {
    final class Clock { var now = Date(timeIntervalSince1970: 3_000_000) }
    let clock = Clock()
    let tracker: DevTaskTracker

    init() {
        let clock = self.clock
        tracker = DevTaskTracker(now: { clock.now })
    }

    func ev(_ kind: DevEvent.Kind, _ id: String = "build", title: String? = nil, status: DevEvent.Status? = nil,
            progress: Double? = nil, message: String? = nil) -> DevEvent {
        DevEvent(kind: kind, id: id, title: title, category: .build, message: message, progress: progress,
                 status: status, exitCode: nil, source: nil)
    }

    @Test func startProgressFinishLifecycle() {
        guard case .started(let t) = tracker.handle(ev(.start, title: "swift build")) else { Issue.record("not started"); return }
        #expect(t.isRunning)
        clock.now += 30
        guard case .updated(let p) = tracker.handle(ev(.progress, progress: 0.5)) else { Issue.record("not updated"); return }
        #expect(p.progress == 0.5)
        clock.now += 12
        guard case .finished(let f) = tracker.handle(ev(.finish, status: .failure, message: "2 errors")) else {
            Issue.record("not finished"); return
        }
        #expect(f.state == .failure)
        #expect(f.duration(at: clock.now + 100) == 42)
        #expect(f.message == "2 errors")
        #expect(tracker.running.isEmpty)
    }

    @Test func duplicateEventsAreDropped() {
        tracker.handle(ev(.start))
        clock.now += 0.2
        #expect(tracker.handle(ev(.start)) == .ignored("duplicate"))
        clock.now += 2
        #expect(tracker.handle(ev(.start)) != .ignored("duplicate"))
    }

    @Test func secondFinishIsIgnored() {
        tracker.handle(ev(.start))
        tracker.handle(ev(.finish, status: .success))
        clock.now += 2
        #expect(tracker.handle(ev(.finish, status: .failure)) == .ignored("already finished"))
        #expect(tracker.tasks.first?.state == .success)
    }

    @Test func restartingAFinishedTaskResetsTheClock() {
        tracker.handle(ev(.start))
        clock.now += 10
        tracker.handle(ev(.finish, status: .success))
        clock.now += 10
        guard case .started(let t) = tracker.handle(ev(.start)) else { Issue.record("not restarted"); return }
        #expect(t.startedAt == clock.now)
        #expect(t.finishedAt == nil)
    }

    @Test func eventsForUnknownTasksStillShowUp() {
        guard case .finished(let t) = tracker.handle(ev(.finish, "deploy", status: .success)) else {
            Issue.record("unknown finish not recorded"); return
        }
        #expect(t.title == "deploy")
        guard case .started = tracker.handle(ev(.progress, "late", progress: 0.3)) else { Issue.record(); return }
    }

    @Test func floodIsRateLimited() {
        var accepted = 0
        for i in 0..<200 {
            if case .ignored = tracker.handle(ev(.message, "t\(i % 5)", message: "\(i)")) {} else { accepted += 1 }
        }
        #expect(accepted == 20)   // the burst; time didn't move
        clock.now += 1
        #expect(tracker.handle(ev(.message, "t0", message: "after")) != .ignored("rate limit"))
    }

    @Test func listIsCappedDroppingOldFinishedFirst() {
        tracker.maxTasks = 3
        tracker.burst = 1000
        tracker.handle(ev(.start, "running"))
        for i in 0..<5 {
            clock.now += 1
            tracker.handle(ev(.start, "t\(i)"))
            tracker.handle(ev(.finish, "t\(i)", status: .success))
        }
        #expect(tracker.tasks.map(\.id) == ["running", "t4", "t3"])
    }

    @Test func longRunningIsAnnouncedOnce() {
        tracker.longRunningAfter = 60
        tracker.handle(ev(.start))
        clock.now += 30
        #expect(tracker.tick().isEmpty)
        clock.now += 31
        let changes = tracker.tick()
        #expect(changes.count == 1)
        if case .takingLong(let t)? = changes.first { #expect(t.id == "build") } else { Issue.record("no warning") }
        clock.now += 600
        #expect(tracker.tick().isEmpty)
    }

    @Test func abandonedAndOldTasksAreCleanedUp() {
        tracker.abandonedAfter = 100
        tracker.keepFinishedFor = 50
        tracker.longRunningAfter = nil
        tracker.handle(ev(.start, "ghost"))
        clock.now += 101
        _ = tracker.tick()
        #expect(tracker.tasks.first?.state == .cancelled)
        clock.now += 51
        _ = tracker.tick()
        #expect(tracker.tasks.isEmpty)
    }
}
