import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI

enum IslandState: Equatable {
    case idle        // looks exactly like the hardware notch
    case music       // small live activity: artwork + equalizer
    case charging    // short peek after plugging in power
    case device      // short peek when a Bluetooth device / drive connects or disconnects
    case color       // short peek after picking a color: swatch + copied HEX
    case pomodoro    // timer running: ring + time around the notch
    case pomodoroPeek // phase finished
    case expanded    // hover
    case drop        // files are being dragged near the notch → AirDrop target
}

enum IslandTab: String, CaseIterable, Identifiable {
    case music, apps, shelf, tools
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .apps: return "square.grid.2x2.fill"
        case .shelf: return "tray.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        }
    }
    var title: String {
        switch self {
        case .music: return "Музыка"
        case .apps: return "Приложения"
        case .shelf: return "Полка"
        case .tools: return "Инструменты"
        }
    }
}

final class IslandModel: ObservableObject {
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var hovering = false
    /// Pointer is over the notch but hasn't expanded it yet: the island "swells" a little.
    @Published private(set) var hoverHint = false
    @Published private(set) var chargingPeek = false
    @Published private(set) var devicePeek: DeviceEvent?
    @Published private(set) var colorPeek: String?
    /// Recently picked colors as "#RRGGBB", newest first (persisted).
    @Published private(set) var colorHistory: [String] = UserDefaults.standard.stringArray(forKey: "colorHistory") ?? []
    private var colorSampler: NSColorSampler?
    private var colorPeekWork: DispatchWorkItem?
    /// Files parked on the shelf (persisted between launches).
    @Published private(set) var shelf: [URL] = []
    @Published private(set) var selectedTab: IslandTab =
        IslandTab(rawValue: UserDefaults.standard.string(forKey: "selectedTab") ?? "") ?? .music
    /// Opened with the keyboard shortcut: stays open until the shortcut, a click outside, or a hover-out.
    private(set) var pinnedOpen = false
    /// Quick-launch apps shown under the player (persisted).
    @Published private(set) var apps: [URL] = []
    @Published private(set) var runningBundleIDs: Set<String> = []
    @Published private(set) var frontmostBundleID: String?
    private var appIcons: [URL: NSImage] = [:]
    private var appBundleIDs: [URL: String] = [:]
    /// A file is being dragged *out* of the shelf: keep the island open until the mouse is released.
    private(set) var dragOutActive = false
    var onDragOutEnded: (() -> Void)?
    private let devices = DeviceMonitor()
    private var devicePeekWork: DispatchWorkItem?
    @Published private(set) var fileDragActive = false
    @Published private(set) var dropNear = false
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var battery = Battery.read()

    // Spotify playlist panel
    @Published private(set) var showPlaylist = false
    @Published private(set) var playlist: PlaybackContext?
    @Published private(set) var playlistLoading = false
    @Published private(set) var playlistError: String?
    @Published private(set) var spotifyLoggedIn: Bool
    @Published private(set) var spotifyHasClientID: Bool
    let spotify = SpotifyWeb()

    let media = MediaService()
    let pomodoro = Pomodoro()
    private var pomodoroObserver: Any?
    private var timers: [Timer] = []
    private var peekWork: DispatchWorkItem?
    private var artworkKey: String?
    private var playlistTask: Task<Void, Never>?
    private var skipTask: Task<Void, Never>?
    private var mediaFetchInFlight = false
    private var lastListReloadKey: String?
    /// Track the queue-skipper is currently heading to (shown with a spinner in the list).
    @Published private(set) var skipTargetID: String?

    init() {
        // An older login without playback-control permission must be redone once.
        spotifyLoggedIn = spotify.isLoggedIn && !spotify.needsReauth
        spotifyHasClientID = spotify.clientID != nil
        // Island state depends on the timer, so re-render whenever it changes.
        pomodoroObserver = pomodoro.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// General state changes (music started, charging peek).
    static let spring = Animation.spring(duration: 0.5, bounce: 0.22)
    /// Expanding: a little livelier, like the iPhone island.
    static let open = Animation.spring(duration: 0.52, bounce: 0.3)
    /// Collapsing: settles without overshoot so it doesn't wobble into the notch.
    static let close = Animation.spring(duration: 0.42, bounce: 0.08)
    static let hint = Animation.spring(duration: 0.3, bounce: 0.35)

    var state: IslandState {
        if fileDragActive && dropNear { return .drop }
        if hovering { return .expanded }
        if chargingPeek { return .charging }
        if pomodoro.peek != nil { return .pomodoroPeek }
        if colorPeek != nil { return .color }
        if devicePeek != nil { return .device }
        if pomodoro.isRunning { return .pomodoro }
        if nowPlaying?.isPlaying == true { return .music }
        return .idle
    }

    var isExpanded: Bool { hovering }
    var isLarge: Bool { state == .expanded || state == .drop }

    var islandSize: CGSize {
        var s = size(for: state)
        if hoverHint && state != .expanded {
            s.width += 14
            s.height += 4
        }
        return s
    }

    // Expanded layout metrics, shared with the views so the height always fits the content exactly.
    static let inset: CGFloat = 22          // left/right padding of everything inside
    static let artworkSize: CGFloat = 92
    static let contentTop: CGFloat = 10     // below the header row (its text already sits mid-row)
    static let contentBottom: CGFloat = 20
    static let playlistHeight: CGFloat = 230

    func size(for state: IslandState) -> CGSize {
        switch state {
        case .idle:     return notchSize
        case .music:    return CGSize(width: notchSize.width + 2 * 52, height: notchSize.height + 6)
        case .charging: return CGSize(width: notchSize.width + 2 * 92, height: notchSize.height)
        case .device:   return CGSize(width: notchSize.width + 2 * 150, height: notchSize.height)
        case .color:    return CGSize(width: notchSize.width + 2 * 140, height: notchSize.height)
        case .pomodoro: return CGSize(width: notchSize.width + 2 * 58, height: notchSize.height)
        case .pomodoroPeek: return CGSize(width: notchSize.width + 2 * 160, height: notchSize.height)
        case .drop:     return CGSize(width: max(540, notchSize.width + 350), height: notchSize.height + 112)
        case .expanded: return CGSize(width: max(480, notchSize.width + 290),
                                     height: notchSize.height + Self.contentTop + Self.artworkSize + Self.contentBottom
                                        + (selectedTab == .music && showPlaylist ? Self.playlistHeight + Self.contentBottom : 0))
        }
    }

    var topRadius: CGFloat { isLarge ? 14 : 6 }
    var bottomRadius: CGFloat { isLarge ? 30 : 12 }

    func start() {
        loadShelf()
        loadApps()
        devices.onEvent = { [weak self] event in self?.showDevicePeek(event) }
        devices.start()
        refreshMedia()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshMedia()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        })
    }

    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        if value {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(value ? Self.open : Self.close) {
            hovering = value
            hoverHint = false
            if !value { showPlaylist = false; pinnedOpen = false }
        }
    }

    func selectTab(_ tab: IslandTab) {
        guard tab != selectedTab else { return }
        withAnimation(Self.spring) {
            selectedTab = tab
            if tab != .music { showPlaylist = false }
        }
        UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
    }

    /// Keyboard shortcut: open (and keep open) or close the island.
    func toggleFromHotKey() {
        if hovering {
            setHovering(false)
        } else {
            setHovering(true)
            pinnedOpen = true
        }
    }

    /// Once the pointer has been over the island, normal hover rules take over again.
    func unpin() { pinnedOpen = false }

    func setHoverHint(_ value: Bool) {
        guard value != hoverHint, !hovering else { return }
        withAnimation(Self.hint) { hoverHint = value }
    }

    // MARK: - Media

    func refreshMedia() {
        guard !mediaFetchInFlight else { return }
        mediaFetchInFlight = true
        media.fetchAsync { [weak self] np in
            self?.mediaFetchInFlight = false
            self?.apply(np)
        }
    }

    /// Snapshot mode needs the result right away.
    func refreshMediaNow() { apply(media.fetch()) }

    private func apply(_ np: NowPlaying?) {
        if np != nowPlaying {
            withAnimation(Self.spring) { nowPlaying = np }
        }
        guard let np else {
            artworkKey = nil
            if artwork != nil { artwork = nil }
            return
        }
        // The track moved somewhere outside the list we show (user picked another playlist) → reload.
        // Reload only once per track change — a track we can't match must not cause a reload loop.
        if showPlaylist, !playlistLoading, skipTask == nil, let list = playlist,
           np.trackKey != lastListReloadKey,
           Self.index(of: np.trackURI, name: np.title, in: list.tracks) == nil {
            lastListReloadKey = np.trackKey
            loadPlaylist()
        }
        if np.trackKey != artworkKey {
            artworkKey = np.trackKey
            let key = np.trackKey
            media.loadArtwork(for: np) { [weak self] image in
                guard let self, self.artworkKey == key else { return }
                withAnimation(.easeInOut(duration: 0.25)) { self.artwork = image }
            }
        }
    }

    func perform(_ command: MediaCommand) {
        guard let source = nowPlaying?.source else { return }
        media.send(command, to: source)
        // Ask again shortly so the UI reflects the new state without waiting a full second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refreshMedia() }
    }

    // MARK: - Spotify playlist

    /// Finds the playing track in a list: by ID, by the ID Spotify relinked it from, then by title.
    static func index(of uri: String?, name: String?, in tracks: [PlaylistTrack]) -> Int? {
        if let uri, let i = tracks.firstIndex(where: { $0.uri == uri || $0.linkedURI == uri }) { return i }
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        return tracks.firstIndex { $0.name.lowercased() == name }
    }

    func togglePlaylist() {
        withAnimation(Self.open) { showPlaylist.toggle() }
        if showPlaylist { loadPlaylist(onlyIfStale: true) }
    }

    func loadPlaylist(onlyIfStale: Bool = false) {
        if onlyIfStale, let list = playlist, let np = nowPlaying,
           Self.index(of: np.trackURI, name: np.title, in: list.tracks) != nil { return }
        if nowPlaying?.source == .music {
            loadMusicPlaylist()
            return
        }
        guard spotifyHasClientID, spotifyLoggedIn else { return }
        playlistTask?.cancel()
        playlistLoading = true
        playlistError = nil
        playlistTask = Task { @MainActor in
            do {
                let ctx = try await spotify.currentContext()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { playlist = ctx }
            } catch SpotifyError.notLoggedIn {
                spotifyLoggedIn = false
            } catch {
                if !Task.isCancelled { playlistError = error.localizedDescription }
            }
            playlistLoading = false
        }
    }

    /// Apple Music: AppleScript exposes the current playlist directly — no login, no API limits.
    private func loadMusicPlaylist() {
        playlistTask?.cancel()
        playlistLoading = true
        playlistError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = self.media.musicContext()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.playlistLoading = false
                if let ctx {
                    withAnimation(.easeInOut(duration: 0.2)) { self.playlist = ctx }
                } else {
                    self.playlistError = "«Музыка» не отдала текущий плейлист — так бывает с радио и подборками, не добавленными в медиатеку"
                }
            }
        }
    }

    func play(_ track: PlaylistTrack) {
        guard let list = playlist else { return }
        if track.uri.hasPrefix("music:") {
            media.playMusicTrack(uri: track.uri)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshMedia() }
            return
        }
        if list.uri == nil {
            skipInQueue(to: track, in: list)
            return
        }
        Task { @MainActor in
            do {
                try await spotify.play(trackURI: track.uri, contextURI: list.uri)
                try? await Task.sleep(for: .milliseconds(350))
                refreshMedia()
                try? await Task.sleep(for: .seconds(1))
                debugLog("after play: \(await spotify.playerSummary())")
            } catch SpotifyError.notLoggedIn {
                spotifyLoggedIn = false
            } catch {
                playlistError = error.localizedDescription
            }
        }
    }

    /// Queue view (context Spotify won't let us read or start remotely): reach the chosen track by
    /// pressing next/previous — exactly what Spotify would play anyway.
    /// The loop re-checks the real current track after every step, so a new click simply changes
    /// the target mid-way (you can change your mind, or click the playing track to stop).
    private func skipInQueue(to track: PlaylistTrack, in list: PlaybackContext) {
        guard list.tracks.contains(where: { $0.id == track.id }) else { return }
        skipTargetID = track.id
        guard skipTask == nil else { return }   // running loop picks up the new target

        skipTask = Task { @MainActor in
            var steps = 0
            while let targetID = skipTargetID, steps < 100 {
                guard let list = playlist,
                      let target = list.tracks.firstIndex(where: { $0.id == targetID }),
                      case let now = media.currentSpotifyTrack(),
                      let current = Self.index(of: now.uri, name: now.name, in: list.tracks),
                      current != target else { break }
                let forward = target > current
                // "Previous" first restarts the current track, so rewind it before stepping back.
                if !forward { media.seekToStart(.spotify) }
                media.send(forward ? .next : .previous, to: .spotify)
                steps += 1
                // Wait until Spotify has actually switched (up to ~0.6 s) before deciding the next step.
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if media.currentSpotifyTrack().uri != now.uri { break }
                }
            }
            if steps == 0 {
                let now = media.currentSpotifyTrack()
                debugLog("queue skip: current \(now.uri ?? "-") «\(now.name ?? "")» not found in list")
            }
            debugLog("queue skip done after \(steps) step(s)")
            skipTargetID = nil
            skipTask = nil
            refreshMedia()
            try? await Task.sleep(for: .milliseconds(500))
            loadPlaylist()   // the queue shifted; refetch it
        }
    }

    func spotifyLogin() {
        spotify.login { [weak self] error in
            guard let self else { return }
            self.spotifyLoggedIn = self.spotify.isLoggedIn && !self.spotify.needsReauth
            self.playlistError = error?.localizedDescription
            if error == nil { self.loadPlaylist() }
        }
    }

    func spotifyLogout() {
        spotify.logout()
        spotifyLoggedIn = false
        playlist = nil
    }

    func setSpotifyClientID(_ id: String?) {
        spotify.clientID = id
        spotifyHasClientID = spotify.clientID != nil
    }

    // MARK: - Drag & drop → AirDrop

    func setFileDrag(_ active: Bool) {
        guard active != fileDragActive else { return }
        withAnimation(active ? Self.open : Self.close) {
            fileDragActive = active
            if !active { dropNear = false }
        }
    }

    func setDropNear(_ near: Bool) {
        guard near != dropNear else { return }
        if near { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        withAnimation(near ? Self.open : Self.close) {
            dropNear = near
            if near { hovering = false; hoverHint = false }
        }
    }

    /// Collects the dropped file URLs and hands them to the system AirDrop sheet.
    func airDrop(_ providers: [NSItemProvider]) {
        Self.loadFileURLs(providers) { [weak self] urls in
            self?.setFileDrag(false)
            self?.airDrop(urls: urls)
        }
    }

    func airDrop(urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    private static func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, url.isFileURL { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: - Shelf

    private static let shelfKey = "shelfPaths"

    func addToShelf(_ providers: [NSItemProvider]) {
        Self.loadFileURLs(providers) { [weak self] urls in
            guard let self else { return }
            self.setFileDrag(false)
            let new = urls.filter { !self.shelf.contains($0) }
            withAnimation(Self.spring) { self.shelf.append(contentsOf: new) }
            if !new.isEmpty { self.selectTab(.shelf) }
            self.saveShelf()
        }
    }

    func removeFromShelf(_ url: URL) {
        withAnimation(Self.spring) { shelf.removeAll { $0 == url } }
        saveShelf()
    }

    func clearShelf() {
        withAnimation(Self.spring) { shelf.removeAll() }
        saveShelf()
    }

    /// Snapshot mode only: fill lists with sample data without touching what's saved.
    func fillForSnapshots(shelf: [URL], apps: [URL], colors: [String]) {
        self.shelf = shelf
        self.apps = apps
        self.colorHistory = colors
    }

    private func loadShelf() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.shelfKey) ?? []
        // Files that were moved or deleted since are dropped silently.
        shelf = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: Self.shelfKey)
    }

    func beginDragOut() {
        guard !dragOutActive else { return }
        dragOutActive = true
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self?.dragOutActive = false
            self?.onDragOutEnded?()
        }
    }

    // MARK: - App launcher

    private static let appsKey = "launcherApps"

    func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Добавить"
        panel.message = "Выбери приложения для быстрого запуска из острова"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { !apps.contains($0) }
        withAnimation(Self.spring) { apps.append(contentsOf: new) }
        saveApps()
    }

    func removeApp(_ url: URL) {
        withAnimation(Self.spring) { apps.removeAll { $0 == url } }
        saveApps()
    }

    func moveApp(_ url: URL, by offset: Int) {
        guard let i = apps.firstIndex(of: url) else { return }
        let j = min(max(i + offset, 0), apps.count - 1)
        guard i != j else { return }
        withAnimation(Self.spring) { apps.swapAt(i, j) }
        saveApps()
    }

    func launch(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    func icon(for url: URL) -> NSImage {
        if let cached = appIcons[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[url] = icon
        return icon
    }

    func bundleID(for url: URL) -> String? {
        if let cached = appBundleIDs[url] { return cached }
        let id = Bundle(url: url)?.bundleIdentifier
        appBundleIDs[url] = id
        return id
    }

    private func loadApps() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.appsKey) ?? []
        apps = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunningApps() }
        }
        refreshRunningApps()
    }

    private func refreshRunningApps() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if running != runningBundleIDs { runningBundleIDs = running }
        if front != frontmostBundleID { frontmostBundleID = front }
    }

    private func saveApps() {
        UserDefaults.standard.set(apps.map(\.path), forKey: Self.appsKey)
    }

    // MARK: - Devices

    private func showDevicePeek(_ event: DeviceEvent) {
        devicePeekWork?.cancel()
        if event.connected { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        withAnimation(Self.spring) { devicePeek = event }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Self.spring) { self?.devicePeek = nil }
        }
        devicePeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - Color picker

    func pickColor() {
        setHovering(false)   // get out of the way of the loupe
        let sampler = NSColorSampler()
        colorSampler = sampler
        NSApp.activate(ignoringOtherApps: true)
        sampler.show { [weak self] color in
            guard let self else { return }
            self.colorSampler = nil
            guard let rgb = color?.usingColorSpace(.sRGB) else { return }   // nil → cancelled with Esc
            let hex = String(format: "#%02X%02X%02X",
                             Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()),
                             Int((rgb.blueComponent * 255).rounded()))
            self.copyColor(hex)
            withAnimation(Self.spring) {
                self.colorHistory.removeAll { $0 == hex }
                self.colorHistory.insert(hex, at: 0)
                self.colorHistory = Array(self.colorHistory.prefix(12))
            }
            UserDefaults.standard.set(self.colorHistory, forKey: "colorHistory")
            self.showColorPeek(hex)
        }
    }

    func copyColor(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func removeColor(_ hex: String) {
        withAnimation(Self.spring) { colorHistory.removeAll { $0 == hex } }
        UserDefaults.standard.set(colorHistory, forKey: "colorHistory")
    }

    func clearColors() {
        withAnimation(Self.spring) { colorHistory.removeAll() }
        UserDefaults.standard.set(colorHistory, forKey: "colorHistory")
    }

    private func showColorPeek(_ hex: String) {
        colorPeekWork?.cancel()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(Self.spring) { colorPeek = hex }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Self.spring) { self?.colorPeek = nil }
        }
        colorPeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        guard var np = nowPlaying else { return }
        np.isShuffling.toggle()
        media.setShuffle(np.isShuffling, for: np.source)
        withAnimation(.easeOut(duration: 0.15)) { nowPlaying = np }   // instant feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.refreshMedia()
            // Shuffling reorders what plays next, so a shown queue is now stale.
            if self.showPlaylist, self.playlist?.uri == nil { self.loadPlaylist() }
        }
    }

    // MARK: - Battery

    private func refreshBattery() {
        let new = Battery.read()
        let pluggedIn = new.onAC && !battery.onAC
        if new != battery { battery = new }
        if pluggedIn && new.hasBattery { showChargingPeek() }
    }

    private func showChargingPeek() {
        peekWork?.cancel()
        withAnimation(Self.spring) { chargingPeek = true }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Self.spring) { self?.chargingPeek = false }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
