import Foundation
import NotchIslandCore

/// Polygon (the planner, iPhone + Mac) tells the island about the day: a done task makes the pet glad
/// (it dances when all three main tasks are done), an event from Polygon's weekly schedule gets a
/// gentle heads-up a few minutes before. Off with the «Polygon» switch in Settings → alerts.
extension IslandModel {
    func receivePolygon(_ object: [String: Any], connection fd: Int32) {
        defer { Darwin.close(fd) }
        let event: PolygonEvent
        do {
            event = try PolygonEventParser.parse(object)
        } catch let error as PolygonEventError {
            HookSocketServer.reply(fd, ["ok": false, "error": error.description])
            return
        } catch {
            HookSocketServer.reply(fd, ["ok": false, "error": "invalid event"])
            return
        }
        HookSocketServer.reply(fd, ["ok": true])
        guard settings.isActivityEnabled(.polygon) else { return }

        switch event {
        case let .done(title, allThree):
            react(allThree ? .dancing : .happy, for: allThree ? 4 : 2.5)
            post(.polygon, "done", .notice(Notice(symbol: allThree ? "sparkles" : "checkmark.circle.fill", tint: .green,
                                                  title: allThree ? "Все три главных сделаны" : "Готово",
                                                  detail: allThree ? nil : title)),
                 duration: allThree ? 3.5 : 2.5)
        case let .soon(title, minutes):
            react(.attention, for: 2)
            post(.polygon, "soon:" + title, .notice(Notice(symbol: "calendar", tint: .yellow, title: title,
                                                           detail: minutes <= 0 ? "сейчас" : "через \(minutes) мин")),
                 duration: 5)
        }
    }
}
