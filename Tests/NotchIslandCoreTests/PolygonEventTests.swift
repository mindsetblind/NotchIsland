import Testing
@testable import NotchIslandCore

struct PolygonEventTests {
    @Test func parsesDone() throws {
        let e = try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "done", "title": "Сдать лабу"])
        #expect(e == .done(title: "Сдать лабу", allThree: false))
        let all = try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "done", "title": "Код", "all_three": true])
        #expect(all == .done(title: "Код", allThree: true))
    }

    @Test func parsesSoon() throws {
        let e = try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "soon", "title": "Зал", "minutes": 10])
        #expect(e == .soon(title: "Зал", minutes: 10))
    }

    @Test func rejectsBadInput() {
        #expect(throws: PolygonEventError.wrongVersion) {
            try PolygonEventParser.parse(["v": 2, "type": "polygon", "event": "done", "title": "x"])
        }
        #expect(throws: PolygonEventError.badField("title")) {
            try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "done", "title": "   "])
        }
        #expect(throws: PolygonEventError.badField("minutes")) {
            try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "soon", "title": "Зал", "minutes": -5])
        }
        #expect(throws: PolygonEventError.unknownEvent("open")) {
            try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "open", "title": "x"])
        }
    }

    @Test func stripsControlCharacters() throws {
        let e = try PolygonEventParser.parse(["v": 1, "type": "polygon", "event": "done", "title": "a\u{1B}[31m\nb"])
        #expect(e == .done(title: "a [31m b", allThree: false))
    }

    @Test func recognisesType() {
        #expect(PolygonEventParser.isPolygonEvent(["type": "polygon"]))
        #expect(!PolygonEventParser.isPolygonEvent(["type": "task"]))
    }
}
