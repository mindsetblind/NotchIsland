import AppKit

/// What a browser is playing (YouTube in Dia, Chrome, Safari, Arc…), read from the system
/// "Now Playing" through NowPlayingBridge.dylib hosted in /usr/bin/perl — macOS answers only
/// Apple-signed processes, and this way no browser needs Automation access or JavaScript flags.
///
/// `@unchecked Sendable`: mutable state is guarded by `lock`.
final class BrowserMedia: @unchecked Sendable {
    /// Browsers whose media counts as "YouTube". Other apps (Spotify, Music, Podcasts…) are left out.
    static let browsers: [String: String] = [
        "company.thebrowser.dia": "Dia",
        "company.thebrowser.Browser": "Arc",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome",
        "com.brave.Browser": "Brave",
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari",
        "com.microsoft.edgemac": "Edge",
        "org.mozilla.firefox": "Firefox",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "ru.yandex.desktop.yandex-browser": "Яндекс Браузер",
        "com.kagi.kagimacOS": "Orion",
    ]

    struct State {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var isPlaying: Bool
        var browser: String
        var bundleID: String
        var artworkID: String?
        var receivedAt: Date
    }

    /// Called on the main thread after what's playing changed.
    var onChange: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var state: State?
    private var artwork: (id: String, image: NSImage)?
    private var process: Process?
    private var buffer = Data()
    private var restarts = 0
    private var stopped = true

    private static let perl = "/usr/bin/perl"
    private static let loader = #"use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); my $s = DynaLoader::dl_find_symbol($l, $ARGV[1]) or die "no $ARGV[1]"; DynaLoader::dl_install_xsub("main::f", $s); f();"#

    private static var bridgePath: String? {
        Bundle.main.path(forResource: "NowPlayingBridge", ofType: "dylib")
    }

    /// Now playing in a browser, with the position brought up to now; nil if nothing.
    var nowPlaying: NowPlaying? {
        lock.lock(); defer { lock.unlock() }
        guard let s = state else { return nil }
        let now = Date()
        let position = s.isPlaying ? s.elapsed + now.timeIntervalSince(s.receivedAt) : s.elapsed
        return NowPlaying(source: .youtube, title: s.title,
                          artist: s.artist.isEmpty ? s.browser : s.artist,
                          album: s.album, duration: s.duration,
                          position: s.duration > 0 ? min(position, s.duration) : position,
                          isPlaying: s.isPlaying, artworkURL: s.artworkID, trackURI: nil, fetchedAt: now)
    }

    func artwork(for id: String?) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        guard let id, let artwork, artwork.id == id else { return nil }
        return artwork.image
    }

    func start() {
        lock.lock(); stopped = false; lock.unlock()
        launch()
    }

    func stop() {
        lock.lock()
        stopped = true
        let p = process
        process = nil
        lock.unlock()
        p?.terminate()
    }

    private func launch() {
        guard let bridge = Self.bridgePath else {
            debugLog("browser media: NowPlayingBridge.dylib is not in the app bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.perl)
        p.arguments = ["-e", Self.loader, bridge, "np_stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.received(data)
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            let restart = !self.stopped && self.process === proc
            self.restarts += 1
            let delay = min(60.0, pow(2.0, Double(min(self.restarts, 6))))
            if restart { self.process = nil; self.state = nil; self.buffer = Data() }
            self.lock.unlock()
            guard restart else { return }
            debugLog("browser media: helper exited (\(proc.terminationStatus)), restarting in \(Int(delay)) s")
            self.notify()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
        }
        do {
            try p.run()
            lock.lock(); process = p; lock.unlock()
        } catch {
            debugLog("browser media: can't start helper: \(error.localizedDescription)")
        }
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        var new: State?
        let clients = Set(d["clients"] as? [String] ?? [])
        if d["none"] == nil, let title = d["title"] as? String,
           let bundleID = d["bundleID"] as? String, let browser = Self.browsers[bundleID] {
            new = State(title: title,
                        artist: d["artist"] as? String ?? "",
                        album: d["album"] as? String ?? "",
                        duration: d["duration"] as? Double ?? 0,
                        elapsed: d["elapsed"] as? Double ?? 0,
                        isPlaying: (d["rate"] as? Double ?? 0) > 0,
                        browser: browser,
                        bundleID: bundleID,
                        artworkID: d["artworkID"] as? String,
                        receivedAt: Date())
        }
        let image = (d["artwork"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        lock.lock()
        let old = state
        // The system shows another app now (Spotify started): the video is still in its tab, just
        // not reported any more. Keep it while the browser still has media, so you can switch back.
        if new == nil, let old, d["bundleID"] as? String != old.bundleID, clients.contains(old.bundleID) {
            new = old
        }
        state = new
        restarts = 0
        if let image, let id = d["artworkID"] as? String { artwork = (id, image) }
        lock.unlock()
        let changed = old?.title != new?.title || old?.isPlaying != new?.isPlaying
            || old?.artworkID != new?.artworkID || abs(Self.position(of: old) - Self.position(of: new)) > 2
            || (old == nil) != (new == nil)
        if changed { notify() }
    }

    /// Position now (playing state moves on from when it was received): a seek shows as a jump.
    private static func position(of s: State?) -> Double {
        guard let s else { return 0 }
        return s.isPlaying ? s.elapsed + Date().timeIntervalSince(s.receivedAt) : s.elapsed
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    /// MediaRemote commands: 1 pause, 2 toggle play/pause, 4 next, 5 previous.
    func send(_ command: MediaCommand) {
        let code: Int
        switch command {
        case .playPause: code = 2
        case .next: code = 4
        case .previous: code = 5
        }
        send(code: code)
    }

    /// Pauses the video (another player started). Remembered as paused right away: the system may
    /// already be showing that other player, so no update about the video would come.
    func pause() {
        lock.lock()
        let playing = state?.isPlaying == true
        if playing, var s = state {
            s.elapsed = Self.position(of: s)
            s.isPlaying = false
            s.receivedAt = Date()
            state = s
        }
        lock.unlock()
        if playing { send(code: 1) }
    }

    private func send(code: Int) {
        guard let bridge = Self.bridgePath else { return }
        lock.lock(); let app = state?.bundleID; lock.unlock()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.perl)
        p.arguments = ["-e", Self.loader, bridge, "np_send"]
        var env = ["NP_COMMAND": String(code)]
        if let app { env["NP_APP"] = app }   // to that browser only, never to Spotify
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { debugLog("browser media: can't send command: \(error.localizedDescription)") }
    }
}
