import Foundation

/// Events from Polygon (the planner app, iPhone + Mac) over the same local socket as Developer Mode.
/// One JSON object per line:
///
///     {"v":1,"type":"polygon","event":"done","title":"Сдать лабу","all_three":false}
///     {"v":1,"type":"polygon","event":"soon","title":"Зал","minutes":10}
///
/// `done` — a task got done in Polygon: the pet by the notch is glad (dances when all three main tasks
/// of the day are done). `soon` — an event from Polygon's weekly schedule starts in a few minutes.
/// Like every socket event, these are only displayed: nothing is run, opened or written.
public enum PolygonEvent: Equatable, Sendable {
    case done(title: String, allThree: Bool)
    case soon(title: String, minutes: Int)
}

public enum PolygonEventError: Error, Equatable, CustomStringConvertible {
    case wrongVersion, notPolygon, unknownEvent(String), badField(String)

    public var description: String {
        switch self {
        case .wrongVersion: return "unsupported protocol version (expected \"v\": 1)"
        case .notPolygon: return "expected \"type\": \"polygon\""
        case .unknownEvent(let e): return "unknown event \"\(e)\" (done, soon)"
        case .badField(let f): return "invalid \"\(f)\""
        }
    }
}

public enum PolygonEventParser {
    public static func isPolygonEvent(_ object: [String: Any]) -> Bool { object["type"] as? String == "polygon" }

    public static func parse(_ object: [String: Any]) throws -> PolygonEvent {
        guard (object["v"] as? NSNumber)?.intValue == 1 else { throw PolygonEventError.wrongVersion }
        guard isPolygonEvent(object) else { throw PolygonEventError.notPolygon }
        guard let title = (object["title"] as? String).flatMap({ DevEventParser.clean($0, max: 80) }) else {
            throw PolygonEventError.badField("title")
        }
        switch object["event"] as? String {
        case "done":
            return .done(title: title, allThree: object["all_three"] as? Bool ?? false)
        case "soon":
            guard let minutes = (object["minutes"] as? NSNumber)?.intValue, (0...24 * 60).contains(minutes) else {
                throw PolygonEventError.badField("minutes")
            }
            return .soon(title: title, minutes: minutes)
        case let other:
            throw PolygonEventError.unknownEvent(other ?? "")
        }
    }
}
