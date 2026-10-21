import Foundation
import Testing
@testable import NotchIslandCore

struct SmartHomeTests {
    static let userInfo = """
    {"status":"ok","request_id":"r",
     "rooms":[{"id":"kitchen","name":"Кухня","household_id":"h","devices":["l1"]},
              {"id":"bed","name":"Спальня","household_id":"h","devices":["l2","l3"]},
              {"id":"empty","name":"Балкон","household_id":"h","devices":[]}],
     "devices":[
      {"id":"l1","name":"Люстра","type":"devices.types.light","room":"kitchen","capabilities":[
        {"type":"devices.capabilities.on_off","state":{"instance":"on","value":true}},
        {"type":"devices.capabilities.range","parameters":{"instance":"brightness","unit":"unit.percent"},
         "state":{"instance":"brightness","value":40}},
        {"type":"devices.capabilities.color_setting","parameters":{"color_model":"hsv","temperature_k":{"min":2700,"max":6500}},
         "state":{"instance":"temperature_k","value":4500}}]},
      {"id":"l2","name":"Ночник","type":"devices.types.light.lamp","room":"bed","capabilities":[
        {"type":"devices.capabilities.on_off","state":{"instance":"on","value":false}},
        {"type":"devices.capabilities.color_setting","parameters":{"color_model":"hsv"},
         "state":{"instance":"hsv","value":{"h":120,"s":100,"v":80}}}]},
      {"id":"l3","name":"Торшер","type":"devices.types.light","room":"bed","capabilities":[
        {"type":"devices.capabilities.on_off","state":null}]},
      {"id":"l4","name":"Лента","type":"devices.types.light.strip","room":null,"capabilities":[]},
      {"id":"s1","name":"Розетка","type":"devices.types.socket","room":"kitchen","capabilities":[
        {"type":"devices.capabilities.on_off","state":{"instance":"on","value":true}}]}],
     "households":[{"id":"h","name":"Дом"}]}
    """

    @Test func parsesLightsWithTheirState() throws {
        let s = try YandexHome.parseUserInfo(Data(Self.userInfo.utf8))
        #expect(s.rooms.map(\.name) == ["Кухня", "Спальня", "Балкон"])
        #expect(s.lamps.map(\.id) == ["l1", "l2", "l3", "l4"])   // the socket isn't a light
        let l1 = s.lamps[0]
        #expect(l1.isOn == true && l1.brightness == 40 && l1.canDim)
        #expect(l1.color == .temperature(4500) && l1.temperatureRange == 2700...6500 && l1.colorModel == "hsv")
        #expect(s.lamps[1].color == .hsv(h: 120, s: 100, v: 80) && s.lamps[1].isOn == false && !s.lamps[1].canDim)
        #expect(s.lamps[2].isOn == nil)    // never reported
        #expect(s.lamps[3].roomID == nil)
    }

    @Test func apiErrorIsReported() {
        #expect(throws: YandexHomeError.api("bad token")) {
            try YandexHome.parseUserInfo(Data(#"{"status":"error","message":"bad token"}"#.utf8))
        }
    }

    @Test func actionsAreGroupedPerLamp() throws {
        let body = YandexHome.actionsBody([("a", .power(true)), ("b", .power(false)), ("a", .brightness(150))])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let devices = try #require(json["devices"] as? [[String: Any]])
        #expect(devices.map { $0["id"] as? String } == ["a", "b"])
        let a = try #require(devices[0]["actions"] as? [[String: Any]])
        #expect(a.map { $0["type"] as? String } == ["devices.capabilities.on_off", "devices.capabilities.range"])
        let brightness = try #require(a[1]["state"] as? [String: Any])
        #expect(brightness["instance"] as? String == "brightness" && brightness["value"] as? Int == 100)   // clamped
    }

    @Test func colorActionsUseTheRightInstance() throws {
        let body = YandexHome.actionsBody([("a", .hsv(h: 30, s: 100, v: 50)), ("b", .temperature(2700))])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""instance":"hsv""#) && text.contains(#""h":30"#))
        #expect(text.contains(#""instance":"temperature_k""#) && text.contains(#""value":2700"#))
    }

    @Test func failedLampsComeFromActionResults() {
        let answer = """
        {"status":"ok","devices":[
          {"id":"a","capabilities":[{"type":"devices.capabilities.on_off","state":{"instance":"on","action_result":{"status":"DONE"}}}]},
          {"id":"b","capabilities":[{"type":"devices.capabilities.on_off","state":{"instance":"on","action_result":{"status":"ERROR","error_code":"DEVICE_UNREACHABLE"}}}]}]}
        """
        #expect(YandexHome.failedLamps(Data(answer.utf8)) == ["b"])
    }

    @Test func applyingUpdatesOnlyThatLamp() throws {
        let s = try YandexHome.parseUserInfo(Data(Self.userInfo.utf8))
        let off = YandexHome.applying(.power(false), to: "l1", in: s)
        #expect(off.lamps[0].isOn == false && off.lamps[1] == s.lamps[1])
        #expect(YandexHome.applying(.brightness(0), to: "l1", in: s).lamps[0].brightness == 1)
        #expect(YandexHome.applying(.power(true), to: "nope", in: s) == s)
    }

    @Test func automaticPlanKeepsLampsInsideTheirRooms() throws {
        let s = try YandexHome.parseUserInfo(Data(Self.userInfo.utf8))
        let plan = HomePlan.automatic(s)
        // Empty rooms are skipped, lamps without a room get their own.
        #expect(Set(plan.rooms.map(\.name)) == ["Кухня", "Спальня", "Без комнаты"])
        #expect(plan.rooms.first?.name == "Спальня")   // most lamps first
        #expect(plan.lamps.count == 4)
        for spot in plan.lamps {
            let lamp = try #require(s.lamps.first { $0.id == spot.id })
            let room = try #require(plan.rooms.first { $0.id == (lamp.roomID ?? HomePlan.noRoomID) })
            #expect(spot.x > room.x && spot.x < room.x + room.width && spot.y > room.y && spot.y < room.y + room.depth)
        }
        // Rooms don't overlap.
        for (i, a) in plan.rooms.enumerated() {
            for b in plan.rooms.dropFirst(i + 1) {
                #expect(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.depth <= b.y || b.y + b.depth <= a.y)
            }
        }
    }

    @Test func manyLampsWrapIntoTwoRows() {
        let lamps = (1...6).map { HomeLamp(id: "\($0)", name: "\($0)", roomID: "r") }
        let plan = HomePlan.automatic(HomeSnapshot(rooms: [HomeRoom(id: "r", name: "Зал")], lamps: lamps))
        #expect(Set(plan.lamps.map(\.y)).count == 2)
        #expect(Set(plan.lamps.map { "\($0.x),\($0.y)" }).count == 6)   // no two in the same spot
    }

    @Test func colorsTurnIntoSensibleRGB() {
        let warm = LampColor.temperature(2700).rgbComponents
        #expect(warm.r == 1 && warm.b < 0.7)
        let cold = LampColor.temperature(6500).rgbComponents
        #expect(cold.b > 0.9)
        let green = LampColor.hsv(h: 120, s: 100, v: 100).rgbComponents
        #expect(green.g == 1 && green.r < 0.01 && green.b < 0.01)
        let red = LampColor.rgb(0xFF0000).rgbComponents
        #expect(red.r == 1 && red.g == 0)
    }
}

struct HomeLayoutTests {
    static func sample() throws -> HomeSnapshot { try YandexHome.parseUserInfo(Data(SmartHomeTests.userInfo.utf8)) }

    @Test func emptyLayoutIsTheAutomaticPlan() throws {
        let s = try Self.sample()
        #expect(HomePlan.make(s, layout: HomeLayout()) == HomePlan.automatic(s))
    }

    @Test func movedRoomTakesItsUnplacedLampsAlong() throws {
        let s = try Self.sample()
        let auto = HomePlan.automatic(s)
        let kitchen = try #require(auto.rooms.first { $0.id == "kitchen" })
        let spot = try #require(auto.lamps.first { $0.id == "l1" })
        var layout = HomeLayout()
        layout.setRect(.init(x: 20, y: 10, width: kitchen.width * 2, depth: kitchen.depth), for: "kitchen")
        let plan = HomePlan.make(s, layout: layout)
        let moved = try #require(plan.lamps.first { $0.id == "l1" })
        #expect(moved.x == 20 + (spot.x - kitchen.x) * 2)
        #expect(moved.y == 10 + (spot.y - kitchen.y))
        #expect(plan.width == 20 + kitchen.width * 2 && plan.depth >= 10 + kitchen.depth)
    }

    @Test func placedLampStaysWhereItWasPut() throws {
        var layout = HomeLayout()
        layout.setLamp(.init(x: 1.25, y: -3), for: "l2")
        let lamp = try #require(HomePlan.make(try Self.sample(), layout: layout).lamps.first { $0.id == "l2" })
        #expect(lamp.x == 1.25 && lamp.y == 0)   // clamped to the grid
    }

    @Test func roomsNeverShrinkBelowAMetre() {
        var layout = HomeLayout()
        layout.setRect(.init(x: -2, y: 1, width: 0.2, depth: 0), for: "r")
        #expect(layout.rooms["r"] == .init(x: 0, y: 1, width: 1, depth: 1))
    }

    @Test func extraRoomsCanBeAddedRenamedMovedAndRemoved() throws {
        let s = try Self.sample()
        var layout = HomeLayout()
        let id = layout.addExtra(name: "Коридор", after: HomePlan.automatic(s))
        #expect(id.hasPrefix(HomeLayout.extraPrefix))
        layout.renameExtra(id, to: "Ванная")
        layout.setRect(.init(x: 0, y: 7, width: 2, depth: 1.5), for: id)
        #expect(layout.rooms[id] == nil)   // stays an extra, not a Yandex room
        let room = try #require(HomePlan.make(s, layout: layout).rooms.first { $0.id == id })
        #expect(room.name == "Ванная" && room.isExtra && room.y == 7 && room.depth == 1.5)
        layout.removeExtra(id)
        #expect(layout.isEmpty)
    }

    @Test func layoutSurvivesSaving() throws {
        var layout = HomeLayout()
        layout.setRect(.init(x: 1, y: 2, width: 3, depth: 4), for: "kitchen")
        layout.setLamp(.init(x: 2, y: 3), for: "l1")
        layout.addExtra(name: "Балкон", after: HomePlan.automatic(try Self.sample()))
        let back = try JSONDecoder().decode(HomeLayout.self, from: try JSONEncoder().encode(layout))
        #expect(back == layout)
    }

    @Test func snapsToHalfMetres() {
        #expect(HomeLayout.snap(2.26) == 2.5 && HomeLayout.snap(2.24) == 2 && HomeLayout.snap(0.6, step: 0.25) == 0.5)
    }
}

struct SpeakerMatchTests {
    @Test func scenariosAreParsedSkippingInactive() throws {
        let json = #"{"status":"ok","rooms":[],"devices":[],"scenarios":[{"id":"a","name":"Мак блютуз","is_active":true},{"id":"b","name":"Старый","is_active":false}]}"#
        let s = try YandexHome.parseUserInfo(Data(json.utf8))
        #expect(s.scenarios == [HomeScenario(id: "a", name: "Мак блютуз")])
    }

    @Test func bluetoothScenarioIsFoundByName() {
        let list = [HomeScenario(id: "1", name: "Кино"), HomeScenario(id: "2", name: "Mac Bluetooth")]
        #expect(SpeakerMatch.scenario(in: list, savedID: nil)?.id == "2")
        #expect(SpeakerMatch.scenario(in: list, savedID: "1")?.id == "1")
        #expect(SpeakerMatch.scenario(in: list, savedID: "gone")?.id == "2")
        #expect(SpeakerMatch.scenario(in: [HomeScenario(id: "1", name: "Кино")], savedID: nil) == nil)
    }

    @Test func recognisesYandexSpeakers() {
        #expect(SpeakerMatch.isYandexSpeaker("Яндекс Станция Миди"))
        #expect(SpeakerMatch.isYandexSpeaker("Yandex Station Midi 1A2B"))
        #expect(!SpeakerMatch.isYandexSpeaker("AirPods Pro"))
    }

    @Test func audioDeviceNameMatching() {
        #expect(SpeakerMatch.audioName("Yandex Station Midi", matches: "Yandex Station Midi"))
        #expect(SpeakerMatch.audioName("Yandex Station Midi (2)", matches: "Yandex Station Midi"))
        #expect(!SpeakerMatch.audioName("MacBook Pro Speakers", matches: "Yandex Station Midi"))
        #expect(!SpeakerMatch.audioName("Yan", matches: "Yandex Station Midi"))
    }
}
