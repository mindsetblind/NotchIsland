import AppKit
import IOKit.ps
import NotchIslandCore

// MARK: - Now playing (Spotify / Apple Music via AppleScript)

enum MediaSource: String, CaseIterable {
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

/// All AppleScript traffic goes through one serial background queue: a Spotify query takes ~100–200 ms,
/// and doing that on the main thread froze animations once a second.
/// `@unchecked Sendable`: all mutable state (the compiled-script cache) is only touched on `queue`.
final class MediaService: @unchecked Sendable {
    private var compiled: [String: NSAppleScript] = [:]
    private let queue = DispatchQueue(label: "notchisland.applescript", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()

    init() { queue.setSpecific(key: queueKey, value: true) }

    /// Runs on the AppleScript queue (directly if already there).
    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? work() : queue.sync(execute: work)
    }

    /// Fire-and-forget command; ordering with later queries is preserved by the serial queue.
    private func runAsync(_ source: String) {
        queue.async { _ = self.run(source) }
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        onQueue { execute(source).result }
    }

    /// AppleScript error numbers we tell apart: the user denied Automation access; the app isn't running.
    static let errNotPermitted = -1743
    static let errNotRunning = -600

    private func execute(_ source: String) -> (result: NSAppleEventDescriptor?, error: Int?) {
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return (nil, -1) }
            s.compileAndReturnError(nil)
            compiled[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard let error else { return (result, nil) }
        return (nil, error[NSAppleScript.errorNumber] as? Int ?? -1)
    }

    // A hung player must not block the queue: Apple Events wait 2 minutes by default.
    private static let spotifyInfo = """
    with timeout of 3 seconds
    tell application "Spotify"
        if player state is stopped then return {"stopped"}
        set t to current track
        return {player state as string, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t, id of t, shuffling}
    end tell
    end timeout
    """

    private static let musicInfo = """
    with timeout of 3 seconds
    tell application "Music"
        if player state is stopped then return {"stopped"}
        set t to current track
        return {player state as string, name of t, artist of t, album of t, duration of t, player position, "", (database ID of t) as string, shuffle enabled}
    end tell
    end timeout
    """

    /// Result of one poll: what's playing, and how each player answered.
    struct Poll {
        var nowPlaying: NowPlaying?
        var access: [MediaSource: PlayerAccess] = [:]
    }

    /// Polls the players in the background and delivers the result on the main thread.
    /// `skip`: players to leave alone this time (backing off after errors).
    func fetchAsync(skipping skip: Set<MediaSource> = [], _ completion: @escaping @Sendable (Poll) -> Void) {
        queue.async {
            let result = self.fetch(skipping: skip)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func fetch(skipping skip: Set<MediaSource> = []) -> Poll {
        var poll = Poll()
        var candidates: [NowPlaying] = []
        for source in [MediaSource.spotify, .music] where !skip.contains(source) {
            guard source.isRunning else {
                poll.access[source] = .notRunning
                continue
            }
            let (np, access) = info(from: source)
            poll.access[source] = access
            if let np { candidates.append(np) }
        }
        poll.nowPlaying = candidates.first(where: \.isPlaying) ?? candidates.first
        return poll
    }

    private func info(from source: MediaSource) -> (NowPlaying?, PlayerAccess) {
        let script = source == .spotify ? Self.spotifyInfo : Self.musicInfo
        let (result, error) = onQueue { execute(script) }
        if let error {
            switch error {
            case Self.errNotPermitted: return (nil, .denied)
            case Self.errNotRunning: return (nil, .notRunning)
            default: return (nil, .failed)
            }
        }
        guard let d = result, d.numberOfItems >= 1, let state = d.atIndex(1)?.stringValue else { return (nil, .failed) }
        guard state != "stopped", d.numberOfItems >= 7 else { return (nil, .ok) }
        return (NowPlaying(
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
        ), .ok)
    }

    func send(_ command: MediaCommand, to source: MediaSource) {
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        runAsync("tell application \"\(source.rawValue)\" to \(verb)")
    }

    /// Fast, direct read of Spotify's current track (used while skipping through the queue).
    func currentSpotifyTrack() -> (uri: String?, name: String?) {
        let d = run("tell application \"Spotify\" to {id of current track, name of current track}")
        return (d?.atIndex(1)?.stringValue, d?.atIndex(2)?.stringValue)
    }

    // MARK: Apple Music playlist

    /// Tracks of the playlist Music is playing from (call off the main thread; runs on the AppleScript queue).
    func musicContext(limit: Int = 1000) -> PlaybackContext? {
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
        guard let d = run(source), d.numberOfItems >= 5,
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
        runAsync("tell application \"Music\" to play (first track of current playlist whose database ID is \(id))")
    }

    /// Starts Spotify hidden (no window, no focus change) if it isn't running. False if it isn't installed.
    func launchSpotifyHidden() async -> Bool {
        if MediaSource.spotify.isRunning { return true }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MediaSource.spotify.bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
        for _ in 0..<40 where !MediaSource.spotify.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))   // until it's ready for commands and shows up as a device
        return MediaSource.spotify.isRunning
    }

    /// Starts a Spotify URI (track, album, artist or playlist) through AppleScript — works without
    /// Premium, but Spotify opens that page and jumps to the front (the caller hides it again).
    /// `context`: play `uri` (a track) inside this playlist/album/Liked Songs, so it continues from there.
    func playSpotifyScript(uri: String, context: String? = nil) async -> Bool {
        let pattern = #"^spotify:[a-z]+(:[A-Za-z0-9._-]+)+$"#
        guard uri.range(of: pattern, options: .regularExpression) != nil,
              context.map({ $0.range(of: pattern, options: .regularExpression) != nil }) ?? true,
              await launchSpotifyHidden() else { return false }
        return await withCheckedContinuation { cont in
            let inContext = context.map { " in context \"\($0)\"" } ?? ""
            queue.async { cont.resume(returning: self.execute("tell application \"Spotify\" to play track \"\(uri)\"\(inContext)").error == nil) }
        }
    }

    func setShuffle(_ on: Bool, for source: MediaSource) {
        let property = source == .spotify ? "shuffling" : "shuffle enabled"
        runAsync("tell application \"\(source.rawValue)\" to set \(property) to \(on)")
    }

    func seekToStart(_ source: MediaSource) {
        runAsync("tell application \"\(source.rawValue)\" to set player position to 0")
    }

    /// Covers are small; a short timeout keeps an unreachable CDN from holding requests for a minute.
    private static let artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.urlCache = nil              // cached in memory by the model, never on disk
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func loadArtwork(for np: NowPlaying, completion: @escaping @Sendable (NSImage?) -> Void) {
        switch np.source {
        case .spotify:
            guard let s = np.artworkURL, let url = URL(string: s), url.scheme == "https" else { return completion(nil) }
            Self.artworkSession.dataTask(with: url) { data, response, error in
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                let image = ok ? data.flatMap(NSImage.init(data:)) : nil
                if image == nil { debugLog("artwork: \(error.map { "\($0.localizedDescription)" } ?? "bad response")") }
                DispatchQueue.main.async { completion(image) }
            }.resume()
        case .music:
            queue.async {
                let d = self.run("""
                tell application "Music"
                    if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
                end tell
                """)
                let image = d.flatMap { NSImage(data: $0.data) }
                DispatchQueue.main.async { completion(image) }
            }
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

/// Calls `onChange` whenever a power source changes (plugged in, unplugged, level changed).
/// IOKit pushes these, so nothing polls while the Mac sits idle.
final class PowerSourceMonitor {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else {
            debugLog("power: IOPSNotificationCreateRunLoopSource failed")
            return
        }
        source = loop
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
