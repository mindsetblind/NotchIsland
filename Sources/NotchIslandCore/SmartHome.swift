import Foundation

// Yandex Smart Home (api.iot.yandex.net): parsing the user's devices and building light commands.
// Zigbee / Matter lamps behind a Yandex hub show up here like any other device.

public struct HomeRoom: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum LampColor: Equatable, Sendable {
    case hsv(h: Double, s: Double, v: Double)   // 0…360, 0…100, 0…100
    case rgb(Int)                               // 0xRRGGBB
    case temperature(Int)                       // kelvin

    /// Display color, components 0…1.
    public var rgbComponents: (r: Double, g: Double, b: Double) {
        switch self {
        case let .hsv(h, s, v): return Self.hsvToRGB(h: h, s: s / 100, v: max(v, 60) / 100)
        case let .rgb(value):
            return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        case let .temperature(k): return Self.kelvinToRGB(k)
        }
    }

    static func hsvToRGB(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = v - c
        return (r + m, g + m, b + m)
    }

    /// Tanner Helland's approximation of black-body color, good enough for 1500…9000 K.
    static func kelvinToRGB(_ kelvin: Int) -> (r: Double, g: Double, b: Double) {
        let t = Double(min(max(kelvin, 1000), 40000)) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func clamp(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return (clamp(r), clamp(g), clamp(b))
    }
}

public struct HomeLamp: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var roomID: String?
    public var isOn: Bool?
    public var brightness: Int?            // 1…100
    public var color: LampColor?
    public var canDim: Bool
    /// "hsv" / "rgb" when the lamp takes any color.
    public var colorModel: String?
    public var temperatureRange: ClosedRange<Int>?

    public init(id: String, name: String, roomID: String? = nil, isOn: Bool? = nil, brightness: Int? = nil,
                color: LampColor? = nil, canDim: Bool = false, colorModel: String? = nil,
                temperatureRange: ClosedRange<Int>? = nil) {
        self.id = id; self.name = name; self.roomID = roomID; self.isOn = isOn; self.brightness = brightness
        self.color = color; self.canDim = canDim; self.colorModel = colorModel; self.temperatureRange = temperatureRange
    }
}

/// A scenario from «Дом с Алисой» (e.g. "Мак блютуз": the speaker runs «включи блютуз»).
public struct HomeScenario: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct HomeSnapshot: Equatable, Sendable {
    public var rooms: [HomeRoom]
    public var lamps: [HomeLamp]
    public var scenarios: [HomeScenario]
    public init(rooms: [HomeRoom] = [], lamps: [HomeLamp] = [], scenarios: [HomeScenario] = []) {
        self.rooms = rooms; self.lamps = lamps; self.scenarios = scenarios
    }
}

public enum LampAction: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)
    case hsv(h: Int, s: Int, v: Int)
    case temperature(Int)
}

public enum YandexHomeError: Error, Equatable {
    case badResponse
    case api(String)
}

public enum YandexHome {
    static let onOff = "devices.capabilities.on_off"
    static let range = "devices.capabilities.range"
    static let colorSetting = "devices.capabilities.color_setting"

    /// GET /v1.0/user/info → rooms and lights (devices of type devices.types.light*).
    public static func parseUserInfo(_ data: Data) throws -> HomeSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YandexHomeError.badResponse }
        if json["status"] as? String == "error" { throw YandexHomeError.api(json["message"] as? String ?? "ошибка API") }
        let rooms = (json["rooms"] as? [[String: Any]] ?? []).compactMap { r -> HomeRoom? in
            guard let id = r["id"] as? String else { return nil }
            return HomeRoom(id: id, name: r["name"] as? String ?? "Комната")
        }
        let lamps = (json["devices"] as? [[String: Any]] ?? []).compactMap { d -> HomeLamp? in
            guard let id = d["id"] as? String, (d["type"] as? String ?? "").hasPrefix("devices.types.light") else { return nil }
            var lamp = HomeLamp(id: id, name: d["name"] as? String ?? "Лампа", roomID: d["room"] as? String)
            for cap in d["capabilities"] as? [[String: Any]] ?? [] {
                let params = cap["parameters"] as? [String: Any] ?? [:]
                let state = cap["state"] as? [String: Any]
                switch cap["type"] as? String {
                case onOff:
                    lamp.isOn = state?["value"] as? Bool
                case range where params["instance"] as? String == "brightness":
                    lamp.canDim = true
                    lamp.brightness = (state?["value"] as? NSNumber)?.intValue
                case colorSetting:
                    lamp.colorModel = params["color_model"] as? String
                    if let t = params["temperature_k"] as? [String: Any],
                       let lo = (t["min"] as? NSNumber)?.intValue, let hi = (t["max"] as? NSNumber)?.intValue, lo <= hi {
                        lamp.temperatureRange = lo...hi
                    }
                    lamp.color = state.flatMap(parseColor)
                default: break
                }
            }
            return lamp
        }
        // Inactive scenarios can't be run.
        let scenarios = (json["scenarios"] as? [[String: Any]] ?? []).compactMap { sc -> HomeScenario? in
            guard let id = sc["id"] as? String, sc["is_active"] as? Bool ?? true else { return nil }
            return HomeScenario(id: id, name: sc["name"] as? String ?? "Сценарий")
        }
        return HomeSnapshot(rooms: rooms, lamps: lamps, scenarios: scenarios)
    }

    static func parseColor(_ state: [String: Any]) -> LampColor? {
        switch state["instance"] as? String {
        case "hsv":
            guard let v = state["value"] as? [String: Any], let h = (v["h"] as? NSNumber)?.doubleValue,
                  let s = (v["s"] as? NSNumber)?.doubleValue, let b = (v["v"] as? NSNumber)?.doubleValue else { return nil }
            return .hsv(h: h, s: s, v: b)
        case "rgb": return (state["value"] as? NSNumber).map { .rgb($0.intValue) }
        case "temperature_k": return (state["value"] as? NSNumber).map { .temperature($0.intValue) }
        default: return nil
        }
    }

    /// Body of POST /v1.0/devices/actions.
    public static func actionsBody(_ commands: [(lampID: String, action: LampAction)]) -> Data {
        var order: [String] = []
        var byLamp: [String: [[String: Any]]] = [:]
        for (id, action) in commands {
            if byLamp[id] == nil { order.append(id) }
            byLamp[id, default: []].append(capability(action))
        }
        let devices = order.map { ["id": $0, "actions": byLamp[$0] ?? []] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: ["devices": devices], options: [.sortedKeys])) ?? Data()
    }

    static func capability(_ action: LampAction) -> [String: Any] {
        switch action {
        case .power(let on):
            return ["type": onOff, "state": ["instance": "on", "value": on]]
        case .brightness(let b):
            return ["type": range, "state": ["instance": "brightness", "value": min(max(b, 1), 100)]]
        case let .hsv(h, s, v):
            return ["type": colorSetting, "state": ["instance": "hsv", "value": ["h": h, "s": s, "v": v]]]
        case .temperature(let k):
            return ["type": colorSetting, "state": ["instance": "temperature_k", "value": k]]
        }
    }

    /// Lamps whose command the hub reported as failed (action_result.status == "ERROR").
    public static func failedLamps(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["devices"] as? [[String: Any]] ?? []).compactMap { d in
            let caps = d["capabilities"] as? [[String: Any]] ?? []
            let failed = caps.contains { cap in
                let result = (cap["state"] as? [String: Any])?["action_result"] as? [String: Any]
                return result?["status"] as? String == "ERROR"
            }
            return failed ? d["id"] as? String : nil
        }
    }

    /// The snapshot with a command already applied, so the plan reacts before the hub answers.
    public static func applying(_ action: LampAction, to lampID: String, in snapshot: HomeSnapshot) -> HomeSnapshot {
        var s = snapshot
        guard let i = s.lamps.firstIndex(where: { $0.id == lampID }) else { return s }
        switch action {
        case .power(let on): s.lamps[i].isOn = on
        case .brightness(let b): s.lamps[i].brightness = min(max(b, 1), 100)
        case let .hsv(h, sat, v): s.lamps[i].color = .hsv(h: Double(h), s: Double(sat), v: Double(v))
        case .temperature(let k): s.lamps[i].color = .temperature(k)
        }
        return s
    }
}

// MARK: - Floor plan

/// A simple floor plan in grid units: rooms as rectangles on the floor, lamps as points inside them.
public struct HomePlan: Equatable, Sendable {
    public struct Room: Equatable, Sendable {
        public let id: String          // room ID, "" for lamps without a room, "extra-…" for rooms without lamps
        public let name: String
        public let x: Double, y: Double, width: Double, depth: Double
        public var isExtra: Bool { id.hasPrefix(HomeLayout.extraPrefix) }

        public init(id: String, name: String, x: Double, y: Double, width: Double, depth: Double) {
            self.id = id; self.name = name; self.x = x; self.y = y; self.width = width; self.depth = depth
        }
    }
    public struct Lamp: Equatable, Sendable {
        public let id: String
        public let x: Double, y: Double
    }
    public let rooms: [Room]
    public let lamps: [Lamp]
    public let width: Double
    public let depth: Double

    public static let noRoomID = ""

    /// Top-left of the occupied area (rooms may be moved away from the origin in the editor).
    public var minX: Double { min(rooms.map(\.x).min() ?? 0, lamps.map(\.x).min() ?? 0) }
    public var minY: Double { min(rooms.map(\.y).min() ?? 0, lamps.map(\.y).min() ?? 0) }

    /// Rooms with lamps laid out in rows (largest first), lamps spread evenly inside each room.
    public static func automatic(_ snapshot: HomeSnapshot, rowWidth: Double = 10) -> HomePlan {
        var groups: [(id: String, name: String, lamps: [HomeLamp])] = snapshot.rooms.compactMap { room in
            let lamps = snapshot.lamps.filter { $0.roomID == room.id }
            return lamps.isEmpty ? nil : (room.id, room.name, lamps)
        }
        let known = Set(snapshot.rooms.map(\.id))
        let homeless = snapshot.lamps.filter { $0.roomID.map { !known.contains($0) } ?? true }
        if !homeless.isEmpty { groups.append((noRoomID, "Без комнаты", homeless)) }
        groups.sort { $0.lamps.count > $1.lamps.count }

        var rooms: [Room] = [], lamps: [Lamp] = []
        var x = 0.0, y = 0.0, rowDepth = 0.0, maxWidth = 0.0
        for g in groups {
            let n = Double(g.lamps.count)
            let width = min(max(3, 2 + n * 1.5), rowWidth)
            let depth = n > 3 ? 4.0 : 3.0
            if x > 0 && x + width > rowWidth { x = 0; y += rowDepth; rowDepth = 0 }
            rooms.append(Room(id: g.id, name: g.name, x: x, y: y, width: width, depth: depth))
            // One row of lamps for up to 3, two rows above that.
            let perRow = n > 3 ? Int((n / 2).rounded(.up)) : g.lamps.count
            for (i, lamp) in g.lamps.enumerated() {
                let row = i / perRow, col = i % perRow
                let inRow = row == 0 ? min(perRow, g.lamps.count) : g.lamps.count - perRow
                let rows = g.lamps.count > perRow ? 2.0 : 1.0
                lamps.append(Lamp(id: lamp.id,
                                  x: x + width * Double(col + 1) / Double(inRow + 1),
                                  y: y + depth * Double(row + 1) / (rows + 1)))
            }
            x += width
            rowDepth = max(rowDepth, depth)
            maxWidth = max(maxWidth, x)
        }
        return HomePlan(rooms: rooms, lamps: lamps, width: maxWidth, depth: y + rowDepth)
    }
}

// MARK: - The user's own layout

/// Where the user put rooms and lamps in the editor, in metres. Anything not saved here
/// (a new room or lamp from Yandex) falls back to the automatic layout.
public struct HomeLayout: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double, y: Double, width: Double, depth: Double
        public init(x: Double, y: Double, width: Double, depth: Double) {
            self.x = x; self.y = y; self.width = width; self.depth = depth
        }
    }
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public struct ExtraRoom: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var rect: Rect
        public init(id: String, name: String, rect: Rect) { self.id = id; self.name = name; self.rect = rect }
    }

    public static let extraPrefix = "extra-"
    public static let minSize = 1.0

    public var rooms: [String: Rect] = [:]
    public var lamps: [String: Point] = [:]
    public var extras: [ExtraRoom] = []

    public init(rooms: [String: Rect] = [:], lamps: [String: Point] = [:], extras: [ExtraRoom] = []) {
        self.rooms = rooms; self.lamps = lamps; self.extras = extras
    }

    public var isEmpty: Bool { rooms.isEmpty && lamps.isEmpty && extras.isEmpty }

    /// Moves or resizes any room (one from Yandex or an extra one). Never below 1 m or off the grid's origin.
    public mutating func setRect(_ rect: Rect, for roomID: String) {
        let r = Rect(x: max(0, rect.x), y: max(0, rect.y),
                     width: max(Self.minSize, rect.width), depth: max(Self.minSize, rect.depth))
        if let i = extras.firstIndex(where: { $0.id == roomID }) { extras[i].rect = r } else { rooms[roomID] = r }
    }

    public mutating func setLamp(_ point: Point, for lampID: String) {
        lamps[lampID] = Point(x: max(0, point.x), y: max(0, point.y))
    }

    /// A room without lamps (corridor, bathroom…) to the right of everything else.
    @discardableResult
    public mutating func addExtra(name: String, after plan: HomePlan) -> String {
        let id = Self.extraPrefix + UUID().uuidString
        extras.append(ExtraRoom(id: id, name: name, rect: Rect(x: plan.width, y: 0, width: 2, depth: 2)))
        return id
    }

    public mutating func renameExtra(_ id: String, to name: String) {
        if let i = extras.firstIndex(where: { $0.id == id }) { extras[i].name = name }
    }

    public mutating func removeExtra(_ id: String) { extras.removeAll { $0.id == id } }

    public static func snap(_ v: Double, step: Double = 0.5) -> Double { (v / step).rounded() * step }
}

extension HomePlan {
    /// The automatic plan with the user's layout on top. A lamp that wasn't placed by hand keeps its
    /// relative spot inside its room, so it follows the room when the room is moved or resized.
    public static func make(_ snapshot: HomeSnapshot, layout: HomeLayout) -> HomePlan {
        let auto = automatic(snapshot)
        guard !layout.isEmpty else { return auto }
        var rooms: [Room] = auto.rooms.map { r in
            guard let c = layout.rooms[r.id] else { return r }
            return Room(id: r.id, name: r.name, x: c.x, y: c.y, width: c.width, depth: c.depth)
        }
        rooms += layout.extras.map { Room(id: $0.id, name: $0.name, x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, depth: $0.rect.depth) }

        let autoRooms = Dictionary(uniqueKeysWithValues: auto.rooms.map { ($0.id, $0) })
        let placed = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        let known = Set(snapshot.rooms.map(\.id))
        let lamps: [Lamp] = auto.lamps.map { spot in
            if let p = layout.lamps[spot.id] { return Lamp(id: spot.id, x: p.x, y: p.y) }
            let roomID = snapshot.lamps.first { $0.id == spot.id }?.roomID.flatMap { known.contains($0) ? $0 : nil } ?? noRoomID
            guard let from = autoRooms[roomID], let to = placed[roomID] else { return spot }
            return Lamp(id: spot.id, x: to.x + (spot.x - from.x) / from.width * to.width,
                        y: to.y + (spot.y - from.y) / from.depth * to.depth)
        }
        let width = max(rooms.map { $0.x + $0.width }.max() ?? 0, lamps.map(\.x).max() ?? 0)
        let depth = max(rooms.map { $0.y + $0.depth }.max() ?? 0, lamps.map(\.y).max() ?? 0)
        return HomePlan(rooms: rooms, lamps: lamps, width: width, depth: depth)
    }
}


// MARK: - Speaker over Bluetooth

public enum SpeakerMatch {
    /// The scenario that turns the speaker's Bluetooth on: the saved one, else one whose name says
    /// "блютуз" / "bluetooth".
    public static func scenario(in scenarios: [HomeScenario], savedID: String?) -> HomeScenario? {
        if let savedID, let s = scenarios.first(where: { $0.id == savedID }) { return s }
        return scenarios.first { s in
            let n = s.name.lowercased()
            return ["блютуз", "bluetooth", "блютус"].contains { n.contains($0) }
        }
    }

    /// A paired Bluetooth device that looks like a Yandex speaker.
    public static func isYandexSpeaker(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["станци", "yandex", "station", "алиса", "alice"].contains { n.contains($0) }
    }

    /// CoreAudio names a Bluetooth output after the device, sometimes with a suffix.
    public static func audioName(_ audio: String, matches bluetooth: String) -> Bool {
        let a = audio.lowercased().trimmingCharacters(in: .whitespaces)
        let b = bluetooth.lowercased().trimmingCharacters(in: .whitespaces)
        return !b.isEmpty && (a == b || a.hasPrefix(b) || b.hasPrefix(a) && a.count >= 4)
    }
}
