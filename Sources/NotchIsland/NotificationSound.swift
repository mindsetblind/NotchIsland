import AppKit
import NotchIslandCore

/// A sound the island plays for agent events: one of NotchIsland's own chimes, a macOS system sound, or none.
/// Stored in settings as its `id`: "chime.bell", "system.Glass", "none".
struct NotificationSound: Identifiable, Hashable {
    let id: String
    let title: String

    static let none = NotificationSound(id: "none", title: "Без звука")

    static let chimes: [NotificationSound] = Chime.allCases.map {
        NotificationSound(id: "chime.\($0.rawValue)", title: Self.title($0))
    }

    /// System sounds from /System/Library/Sounds, by name.
    static let system: [NotificationSound] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted()
            .map { NotificationSound(id: "system.\($0)", title: $0) }
    }()

    static func named(_ id: String) -> NotificationSound {
        ([none] + chimes + system).first { $0.id == id } ?? none
    }

    private static func title(_ chime: Chime) -> String {
        switch chime {
        case .ring:  "Перезвон"
        case .bell:  "Колокольчик"
        case .drop:  "Капля"
        case .chord: "Аккорд"
        }
    }

    // MARK: Playing

    private static var cache: [String: NSSound] = [:]
    private static var playing: NSSound?

    func play() {
        guard let sound = Self.sound(id) else { return }
        Self.playing?.stop()
        Self.playing = sound
        sound.play()
    }

    private static func sound(_ id: String) -> NSSound? {
        if let s = cache[id] { return s }
        var s: NSSound?
        if id.hasPrefix("chime."), let chime = Chime(rawValue: String(id.dropFirst(6))) {
            s = NSSound(data: chime.wav())
        } else if id.hasPrefix("system.") {
            s = NSSound(named: String(id.dropFirst(7)))
        }
        cache[id] = s
        return s
    }
}
