import AppKit
import IOKit.ps

// MARK: - Now playing (Spotify / Apple Music via AppleScript)

enum MediaSource: String {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

enum MediaCommand { case playPause, next, previous }

struct NowPlaying: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var artworkURL: String?
    var trackURI: String?      // "spotify:track:…" (Spotify only)
    var isShuffling = false
    var fetchedAt: Date

    var trackKey: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    /// Position extrapolated from the last poll so the progress bar moves smoothly.
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(fetchedAt))
    }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        // Ignore small drift in position so we don't re-render every poll.
        a.trackKey == b.trackKey && a.isPlaying == b.isPlaying && a.isShuffling == b.isShuffling && abs(a.position(at: Date()) - b.position(at: Date())) < 1.5
    }
}

final class MediaService {
    private var compiled: [String: NSAppleScript] = [:]

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            s.compileAndReturnError(nil)
            compiled[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static let spotifyInfo = """
    tell application "Spotify"
        if player state is stopped then return {"stopped"}
        set t to current track
        return {player state as string, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t, id of t, shuffling}
    end tell
    """

    private static let musicInfo = """
    tell application "Music"
        if player state is stopped then return {"stopped"}
        set t to current track
        return {player state as string, name of t, artist of t, album of t, duration of t, player position, "", (database ID of t) as string, shuffle enabled}
    end tell
    """

    func fetch() -> NowPlaying? {
        let candidates = [MediaSource.spotify, .music].filter(\.isRunning).compactMap { info(from: $0) }
        return candidates.first(where: \.isPlaying) ?? candidates.first
    }

    private func info(from source: MediaSource) -> NowPlaying? {
        let script = source == .spotify ? Self.spotifyInfo : Self.musicInfo
        guard let d = run(script), d.numberOfItems >= 7,
              let state = d.atIndex(1)?.stringValue, state != "stopped" else { return nil }
        return NowPlaying(
            source: source,
            title: d.atIndex(2)?.stringValue ?? "",
            artist: d.atIndex(3)?.stringValue ?? "",
            album: d.atIndex(4)?.stringValue ?? "",
            duration: d.atIndex(5)?.doubleValue ?? 0,
            position: d.atIndex(6)?.doubleValue ?? 0,
            isPlaying: state == "playing",
            artworkURL: d.atIndex(7)?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            // Spotify gives "spotify:track:…"; for Music we build "music:<database ID>" so both match playlist rows.
            trackURI: d.numberOfItems >= 8
                ? d.atIndex(8)?.stringValue.flatMap { $0.isEmpty ? nil : (source == .music ? "music:" + $0 : $0) }
                : nil,
            isShuffling: d.numberOfItems >= 9 ? d.atIndex(9)?.booleanValue ?? false : false,
            fetchedAt: Date()
        )
    }

    func send(_ command: MediaCommand, to source: MediaSource) {
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        _ = run("tell application \"\(source.rawValue)\" to \(verb)")
    }

    /// Fast, direct read of Spotify's current track (used while skipping through the queue).
    func currentSpotifyTrack() -> (uri: String?, name: String?) {
        let d = run("tell application \"Spotify\" to {id of current track, name of current track}")
        return (d?.atIndex(1)?.stringValue, d?.atIndex(2)?.stringValue)
    }

    // MARK: Apple Music playlist

    /// Tracks of the playlist Music is playing from. Runs its own script instance, so it's safe off the main thread.
    static func musicContext(limit: Int = 1000) -> PlaybackContext? {
        let source = """
        tell application "Music"
            set p to current playlist
            set total to count of tracks of p
            if total = 0 then return {name of p, {}, {}, {}, {}}
            set b to total
            if b > \(limit) then set b to \(limit)
            return {name of p, name of tracks 1 thru b of p, artist of tracks 1 thru b of p, duration of tracks 1 thru b of p, database ID of tracks 1 thru b of p}
        end tell
        """
        var error: NSDictionary?
        guard let d = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil,
              d.numberOfItems >= 5,
              let names = d.atIndex(2), let artists = d.atIndex(3),
              let durations = d.atIndex(4), let ids = d.atIndex(5) else { return nil }
        let count = names.numberOfItems
        let tracks: [PlaylistTrack] = count == 0 ? [] : (1...count).compactMap { i in
            guard let id = ids.atIndex(i)?.int32Value else { return nil }
            return PlaylistTrack(id: "\(i)-music:\(id)", uri: "music:\(id)", linkedURI: nil,
                                 name: names.atIndex(i)?.stringValue ?? "",
                                 artist: artists.atIndex(i)?.stringValue ?? "",
                                 duration: durations.atIndex(i)?.doubleValue ?? 0,
                                 imageURL: nil)
        }
        return PlaybackContext(uri: "music:current-playlist", title: d.atIndex(1)?.stringValue ?? "Плейлист", tracks: tracks)
    }

    /// Plays a track *from the current playlist*, so playback continues through that playlist.
    func playMusicTrack(uri: String) {
        guard let id = Int(uri.replacingOccurrences(of: "music:", with: "")) else { return }
        _ = run("tell application \"Music\" to play (first track of current playlist whose database ID is \(id))")
    }

    func setShuffle(_ on: Bool, for source: MediaSource) {
        let property = source == .spotify ? "shuffling" : "shuffle enabled"
        _ = run("tell application \"\(source.rawValue)\" to set \(property) to \(on)")
    }

    func seekToStart(_ source: MediaSource) {
        _ = run("tell application \"\(source.rawValue)\" to set player position to 0")
    }

    func loadArtwork(for np: NowPlaying, completion: @escaping (NSImage?) -> Void) {
        switch np.source {
        case .spotify:
            guard let s = np.artworkURL, let url = URL(string: s) else { return completion(nil) }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { completion(image) }
            }.resume()
        case .music:
            let d = run("""
            tell application "Music"
                if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
            end tell
            """)
            completion(d.flatMap { NSImage(data: $0.data) })
        }
    }
}

// MARK: - Battery

struct Battery: Equatable {
    var level = 100
    var isCharging = false
    var onAC = true
    var hasBattery = false

    static func read() -> Battery {
        var b = Battery()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return b }
        for ps in sources {
            guard let d = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            b.hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            b.level = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            b.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            b.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        return b
    }
}
