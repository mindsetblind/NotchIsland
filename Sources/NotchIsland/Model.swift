import AppKit
import Combine
import NotchIslandCore
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
    case permission  // Claude Code asks for permission: card with Allow / Deny
    case agent       // an agent is working / waiting: mascot face around the notch
    case agentPeek   // "готово" / "ждёт ответа"
    case notice      // any other activity, generic look (developer tasks, low battery, disk space…)
}

enum IslandTab: String, CaseIterable, Identifiable {
    case music, apps, shelf, clipboard, agents, tools
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .apps: return "square.grid.2x2.fill"
        case .shelf: return "tray.fill"
        case .clipboard: return "doc.on.clipboard"
        case .agents: return "eyes"
        case .tools: return "wrench.and.screwdriver.fill"
        }
    }
    var title: String {
        switch self {
        case .music: return "Музыка"
        case .apps: return "Приложения"
        case .shelf: return "Полка"
        case .clipboard: return "Буфер"
        case .agents: return "Агенты и задачи"
        case .tools: return "Инструменты"
        }
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var hovering = false
    /// Pointer is over the notch but hasn't expanded it yet: the island "swells" a little.
    @Published private(set) var hoverHint = false
    /// Decides what the collapsed island shows (live activities + timed alerts).
    let activities = IslandActivities.live()
    private var activityObservers: [AnyCancellable] = []
    /// Recently picked colors as "#RRGGBB", newest first (persisted).
    @Published private(set) var colorHistory: [String] = UserDefaults.standard.stringArray(forKey: "colorHistory") ?? []
    private var colorSampler: NSColorSampler?
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
    @Published private(set) var fileDragActive = false
    @Published private(set) var dropNear = false
    @Published private(set) var nowPlaying: NowPlaying? {
        didSet {
            guard (oldValue?.isPlaying == true) != (nowPlaying?.isPlaying == true) else { return }
            activities.setLive(ActivityID(.music), .music, active: nowPlaying?.isPlaying == true)
        }
    }
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
    let claude = ClaudeMonitor()
    let clipboard = ClipboardHistory()
    let developer = DeveloperMonitor()
    private var eventServer: HookSocketServer?
    /// Screen rectangle of the collapsed island (set by the app delegate), to place popovers under it.
    var islandScreenRect: (() -> CGRect?)?
    private var claudeObserver: Any?
    private var pomodoroObserver: Any?
    private var settingsObserver: Any?
    let settings = AppSettings.shared
    private var timers: [Timer] = []
    private var artworkKey: String?
    /// Last ~30 covers (≈ a few MB at most): going back to a track shows its cover instantly.
    private var artworkCache = LRUCache<String, NSImage>(capacity: 30)
    private var artworkFailures = FailureMemo<String>(retryAfter: 10 * 60)
    private var playlistTask: Task<Void, Never>?
    private var skipTask: Task<Void, Never>?
    private var mediaFetchInFlight = false
    private var lastCommandAt = Date.distantPast
    private var expectedPlaying: (value: Bool, until: Date)?
    private var lastListReloadKey: String?
    /// Track the queue-skipper is currently heading to (shown with a spinner in the list).
    @Published private(set) var skipTargetID: String?

    init() {
        // An older login without playback-control permission must be redone once.
        spotifyLoggedIn = spotify.isLoggedIn && !spotify.needsReauth
        spotifyHasClientID = spotify.clientID != nil
        // Island state depends on the timer, so re-render whenever it changes.
        pomodoroObserver = pomodoro.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        // Claude Code sends an event for every tool call; the island itself only cares whether agents
        // work, wait or are done (and about permission cards). Re-render only when that changes —
        // the Agents tab observes the monitor directly for the details.
        claudeObserver = claude.$sessions.combineLatest(claude.$permissions)
            .map { sessions, permissions in
                ClaudeSignature(working: sessions.contains { $0.status == .working },
                                waiting: !permissions.isEmpty || sessions.contains { $0.status == .waiting },
                                done: sessions.contains { $0.status == .done },
                                permissions: permissions.map(\.id))
            }
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // Toggling what's shown around the notch must re-evaluate the island state right away.
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                withAnimation(Self.spring) {
                    self.applyActivitySettings()
                    self.objectWillChange.send()
                }
            }
        }
        setUpActivities()
    }

    private struct ClaudeSignature: Equatable {
        var working: Bool, waiting: Bool, done: Bool
        var permissions: [UUID]
    }

    // MARK: - Activities

    private func setUpActivities() {
        applyActivitySettings()
        activityObservers = [
            activities.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            pomodoro.$isRunning.removeDuplicates().sink { [weak self] running in
                self?.activities.setLive(ActivityID(.pomodoro), .pomodoro, active: running)
            },
            claude.$sessions.combineLatest(claude.$permissions).sink { [weak self] sessions, permissions in
                let busy = !permissions.isEmpty || sessions.contains { $0.status == .working || $0.status == .waiting }
                self?.activities.setLive(ActivityID(.agent), .agent, active: busy)
            },
        ]
        pomodoro.onAnnounce = { [weak self] peek in
            self?.post(.pomodoro, "phase", .pomodoroPeek(peek), duration: 4)
        }
        claude.onPeek = { [weak self] peek in
            self?.post(.agent, peek.project, .agentPeek(peek), duration: 3.5)
        }
        clipboard.onCopiedBack = { [weak self] item in
            guard let self, !self.isExpanded else { return }
            self.post(.clipboard, "", .notice(Notice(symbol: "doc.on.clipboard", tint: .green, title: "Скопировано",
                                                       detail: item.preview, tab: .clipboard)), duration: 1.8)
        }
    }

    /// What the user switched off in Settings, and their order of live activities.
    private func applyActivitySettings() {
        let s = settings
        activities.isAllowed = { kind in
            switch kind {
            case .music: return s.showCompactMusic
            case .pomodoro: return s.showCompactPomodoro
            // Charging and devices have their own switches, checked where the alert is posted;
            // "low battery" is checked there too, so turning it off doesn't silence charging.
            case .battery, .device: return true
            default: return s.isActivityEnabled(kind)
            }
        }
        activities.priorityOverrides = s.livePriorityOverrides
        activities.refresh()
    }

    /// Posts a timed alert with the island's usual animation.
    func post(_ kind: ActivityKind, _ key: String = "", _ payload: IslandActivity, duration: TimeInterval) {
        withAnimation(Self.spring) { activities.post(ActivityID(kind, key), payload, duration: duration) }
    }

    /// Starts/updates (payload) or ends (nil) a live activity.
    func setLive(_ kind: ActivityKind, _ key: String = "", _ payload: IslandActivity?) {
        withAnimation(Self.spring) {
            if let payload { activities.setLive(ActivityID(kind, key), payload) } else { activities.endLive(ActivityID(kind, key)) }
        }
    }

    var currentActivity: IslandActivity? { activities.current?.payload }

    /// System setting "Reduce motion": springs and bounces become short cross-fades.
    nonisolated static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private nonisolated static let gentle = Animation.easeInOut(duration: 0.2)

    /// General state changes (music started, charging peek).
    nonisolated static var spring: Animation { reduceMotion ? gentle : .spring(duration: 0.5, bounce: 0.22) }
    /// Expanding: a little livelier, like the iPhone island.
    nonisolated static var open: Animation { reduceMotion ? gentle : .spring(duration: 0.52, bounce: 0.3) }
    /// Collapsing: critically damped — decelerates smoothly into the notch, no overshoot.
    nonisolated static var close: Animation { reduceMotion ? gentle : .spring(duration: 0.45, bounce: 0) }
    /// Hover "lift", like an app icon under the cursor in the app switcher.
    nonisolated static var hint: Animation { reduceMotion ? gentle : .spring(duration: 0.35, bounce: 0.45) }

    var state: IslandState {
        // Interactive states first: they need the user's hands.
        if fileDragActive && dropNear { return .drop }
        if !claude.permissions.isEmpty { return .permission }
        if hovering { return .expanded }
        return currentActivity?.state ?? .idle
    }

    var isExpanded: Bool { hovering }
    var isLarge: Bool { state == .expanded || state == .drop || state == .permission }

    var islandSize: CGSize {
        var s = size(for: state)
        if hoverHint && state != .expanded {
            s.width += 22   // sideways only: growing downward would cover full-screen windows
        }
        return s
    }

    // Expanded layout metrics, shared with the views so the height always fits the content exactly.
    static let inset: CGFloat = 22          // left/right padding of everything inside
    static let artworkSize: CGFloat = 92
    static let contentTop: CGFloat = 10     // below the header row (its text already sits mid-row)
    static let contentBottom: CGFloat = 20
    static let playlistHeight: CGFloat = 230

    /// Width of each "ear" when only the mascot is shown (it sits in the right one).
    static let mascotEar: CGFloat = 40

    func size(for state: IslandState) -> CGSize {
        switch state {
        case .idle:     return showsMascot ? CGSize(width: notchSize.width + 2 * Self.mascotEar, height: notchSize.height)
                                           : notchSize
        // Collapsed states never go below the menu bar (= notch height), so they can't cover
        // the top of full-screen windows.
        case .music:    return CGSize(width: notchSize.width + 2 * 52, height: notchSize.height)
        case .charging: return CGSize(width: notchSize.width + 2 * 92, height: notchSize.height)
        case .device:   return CGSize(width: notchSize.width + 2 * 150, height: notchSize.height)
        case .color:    return CGSize(width: notchSize.width + 2 * 140, height: notchSize.height)
        case .pomodoro: return CGSize(width: notchSize.width + 2 * (showsMascot ? 84 : 58), height: notchSize.height)
        case .pomodoroPeek: return CGSize(width: notchSize.width + 2 * 160, height: notchSize.height)
        case .drop:     return CGSize(width: max(540, notchSize.width + 350), height: notchSize.height + 112)
        case .permission: return CGSize(width: max(480, notchSize.width + 290), height: notchSize.height + 118)
        case .agent:    return CGSize(width: notchSize.width + 2 * 52, height: notchSize.height)
        case .agentPeek: return CGSize(width: notchSize.width + 2 * 140, height: notchSize.height)
        case .notice:   return CGSize(width: notchSize.width + 2 * 150, height: notchSize.height)
        case .expanded: return CGSize(width: max(520, notchSize.width + 330),
                                     height: notchSize.height + Self.contentTop + Self.artworkSize + Self.contentBottom
                                        + (selectedTab == .music && showPlaylist ? Self.playlistHeight + Self.contentBottom : 0))
        }
    }

    // MARK: - Mascot (always visible right of the notch)

    /// Set from the mouse tracker: -1…1 = cursor left/right of the face; nil = too far to care.
    @Published private(set) var mascotGaze: CGFloat?
    private var happyUntil = Date.distantPast
    private var lastMascotMood: MascotMood?

    var showsMascot: Bool { settings.mascotAlwaysVisible }

    var mascotMood: MascotMood {
        if claude.isAnyWaiting { return .attention }
        if claude.isAnyWorking { return .working }
        // Only a short burst of joy: a finished Claude session stays "done" for minutes, and a face
        // frozen in ^ ^ for that long stops blinking, dancing and sleeping.
        if Date() < happyUntil { return .happy }
        if isSleepy { return .sleeping }
        if nowPlaying?.isPlaying == true { return .dancing }
        return .idle
    }

    /// Nobody has touched the Mac for 5 minutes, or it's the middle of the night.
    private var isSleepy: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 5 * 60 { return true }
        guard settings.mascotSleepsAtNight else { return false }
        // At night it dozes off sooner — but not while you're actually using the Mac.
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 1 && hour < 6 && idle > 60
    }

    func setMascotGaze(_ gaze: CGFloat?) {
        // Any mouse movement wakes a sleeping mascot right away (not on the next periodic check).
        if lastMascotMood == .sleeping { checkMascotMood() }
        guard gaze != mascotGaze else { return }
        mascotGaze = gaze
    }

    /// A short happy hop: file shelved, color copied, AirDrop sent…
    func cheer() {
        happyUntil = Date().addingTimeInterval(2.5)
        objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.objectWillChange.send() }
    }

    /// Moods that change with time (sleep) don't trigger a re-render by themselves — check now and then.
    private func checkMascotMood() {
        let mood = mascotMood
        guard mood != lastMascotMood else { return }
        lastMascotMood = mood
        objectWillChange.send()
    }

    var topRadius: CGFloat { isLarge ? 14 : 6 }
    var bottomRadius: CGFloat { isLarge ? 30 : 12 }

    func start() {
        claude.start()
        developer.attach(to: self)
        startEventServer()
        loadShelf()
        loadApps()
        devices.onEvent = { [weak self] event in self?.showDevicePeek(event) }
        devices.start()
        refreshMedia()
        startMediaObservers()
        // Power source changes are pushed by IOKit — no polling.
        power.onChange = { [weak self] in self?.refreshBattery() }
        power.start()
        startSystemActivities()
        let mood = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMascotMood() }
        }
        mood.tolerance = 1
        timers.append(mood)
    }

    // MARK: - Local events (Claude Code hooks + Developer Mode)

    private func startEventServer() {
        eventServer = HookSocketServer { [weak self] data, event, fd in
            let isDev = DevEventParser.isDevEvent(event)
            // JSON objects aren't Sendable; they are only read on the main actor from here on.
            nonisolated(unsafe) let event = event
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { Darwin.close(fd); return }
                    if isDev { self.developer.receive(data, connection: fd) } else { self.claude.handleHookEvent(event, connection: fd) }
                }
            }
        }
        eventServer?.start()
    }

    // MARK: - Media observation

    private let power = PowerSourceMonitor()
    private var lowBattery = LowBatteryWatcher()
    private let disk = DiskSpaceMonitor()
    private let downloads = DownloadsWatcher()
    let calendar = CalendarMonitor()
    private var systemObservers: [AnyCancellable] = []
    private var lastMediaPoll = Date.distantPast
    private var mediaNotifyWork: DispatchWorkItem?

    /// Both players announce every play/pause/track change with a distributed notification, so the
    /// island learns about changes right away. Polling remains only as a safety net and to correct
    /// the extrapolated position: every second while the player is on screen, rarely otherwise.
    private func startMediaObservers() {
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaDidNotify() }
            }
        }
        let poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMediaIfDue() }
        }
        poll.tolerance = 0.3
        timers.append(poll)
    }

    /// Coalesces bursts (Spotify sends several notifications per track change).
    private func mediaDidNotify() {
        mediaNotifyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshMedia() } }
        mediaNotifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private var mediaPollInterval: TimeInterval {
        let playing = nowPlaying?.isPlaying == true
        if isExpanded && selectedTab == .music { return playing ? 1 : 3 }
        if playing { return 10 }
        // Player running but paused, or nothing at all: a launch/quit/play arrives as a notification.
        return 30
    }

    private func pollMediaIfDue() {
        guard Date().timeIntervalSince(lastMediaPoll) >= mediaPollInterval else { return }
        refreshMedia()
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

    /// Click on the collapsed island. While an alert is shown, open the tab it belongs to
    /// (like tapping a live activity on iPhone); otherwise keep the tab the user left.
    func openFromClick() {
        if let alert = activities.shownAlert, let tab = Self.tab(for: alert.payload) { selectTab(tab) }
        setHovering(true)
    }

    private static func tab(for activity: IslandActivity) -> IslandTab? {
        switch activity {
        case .pomodoroPeek: return .tools
        case .agentPeek: return .agents
        case .color: return .tools
        case .notice(let n): return n.tab
        default: return nil
        }
    }

    /// After sleep: state polled from the outside world may be stale.
    func systemDidWake() {
        refreshMedia()
        refreshBattery()
        checkMascotMood()
        disk.check()
        calendar.reschedule()
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

    /// Health of each player integration (Automation denied, hung player → back off).
    private var mediaHealth: [MediaSource: MediaHealth] = [:]
    /// Shown in the player when a player can't be asked (instead of a silent "nothing playing").
    @Published private(set) var mediaProblem: MediaProblem?

    enum MediaProblem: Equatable {
        case denied(MediaSource)
        case unavailable(MediaSource)
    }

    func refreshMedia() {
        guard !mediaFetchInFlight else { return }
        mediaFetchInFlight = true
        lastMediaPoll = Date()
        let startedAt = Date()
        let now = Date()
        let skip = Set(MediaSource.allCases.filter { !(mediaHealth[$0]?.canAttempt(at: now) ?? true) })
        media.fetchAsync(skipping: skip) { [weak self] poll in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mediaFetchInFlight = false
                // A poll that started before the last command reports the old state — drop it, or the
                // play/pause icon would briefly flip back. Poll again instead.
                if startedAt < self.lastCommandAt {
                    self.refreshMedia()
                    return
                }
                self.recordHealth(poll.access)
                var np = poll.nowPlaying
                // The current track's player was skipped this time (backing off): keep what we know.
                if np == nil, let current = self.nowPlaying, skip.contains(current.source) { np = current }
                self.apply(np)
            }
        }
    }

    /// Snapshot mode needs the result right away.
    func refreshMediaNow() { apply(media.fetch().nowPlaying) }

    private func recordHealth(_ access: [MediaSource: PlayerAccess]) {
        let now = Date()
        for (source, result) in access {
            var h = mediaHealth[source] ?? MediaHealth()
            if h.record(result, at: now) { debugLog("media: \(source.rawValue) is now \(h.state)") }
            mediaHealth[source] = h
        }
        let problem: MediaProblem? = MediaSource.allCases.lazy.compactMap { source -> MediaProblem? in
            switch self.mediaHealth[source]?.state {
            case .denied: return .denied(source)
            case .unavailable: return .unavailable(source)
            default: return nil
            }
        }.first
        if problem != mediaProblem { mediaProblem = problem }
    }

    /// Opens Privacy & Security → Automation, where access to Spotify/Music is granted.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        // Check again as soon as the user comes back.
        for s in MediaSource.allCases { mediaHealth[s]?.retrySoon() }
    }

    private func apply(_ polled: NowPlaying?) {
        var np = polled
        // Spotify keeps reporting "playing" for ~300 ms after a pause command. Within a short window
        // after ⏯ we trust the state we just set; if the player still disagrees afterwards, it wins.
        if let expected = expectedPlaying, var p = np, p.trackKey == nowPlaying?.trackKey {
            if p.isPlaying == expected.value {
                expectedPlaying = nil                       // confirmed
            } else if Date() < expected.until {
                p.isPlaying = expected.value                // late report — keep our state
                p.position = nowPlaying?.position(at: Date()) ?? p.position
                p.fetchedAt = Date()
                np = p
            } else {
                expectedPlaying = nil                       // the command really didn't take
            }
        }
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
            // Recently seen covers come from memory: no request, no placeholder flash.
            if let cached = artworkCache.value(for: key) {
                withAnimation(.easeInOut(duration: 0.2)) { artwork = cached }
                return
            }
            // A cover that failed recently (e.g. the CDN is unreachable) isn't retried on every poll.
            guard artworkFailures.shouldTry(key, now: Date()) else {
                if artwork != nil { artwork = nil }
                return
            }
            if artwork != nil { withAnimation(.easeInOut(duration: 0.2)) { artwork = nil } }   // placeholder while loading
            media.loadArtwork(for: np) { [weak self] image in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let image { self.artworkCache.set(image, for: key) } else { self.artworkFailures.failed(key, now: Date()) }
                    guard self.artworkKey == key else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { self.artwork = image }
                }
            }
        }
    }

    func perform(_ command: MediaCommand) {
        guard var np = nowPlaying else { return }
        lastCommandAt = Date()
        media.send(command, to: np.source)
        if command == .playPause {
            // Flip the icon right away; the next poll confirms it.
            np.position = np.position(at: Date())
            np.fetchedAt = Date()
            np.isPlaying.toggle()
            expectedPlaying = (np.isPlaying, Date().addingTimeInterval(1.0))
            withAnimation(.easeOut(duration: 0.15)) { nowPlaying = np }
        }
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
        let media = self.media
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ctx = media.musicContext()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
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
        cheer()
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
            if !new.isEmpty { self.selectTab(.shelf); self.cheer() }
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
            MainActor.assumeIsolated {
                self?.dragOutActive = false
                self?.onDragOutEnded?()
            }
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
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.refreshRunningApps()
                    // A player launched or quit: update the island now rather than on the next slow poll.
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    if let id = app?.bundleIdentifier, [MediaSource.spotify.bundleID, MediaSource.music.bundleID].contains(id),
                       note.name != NSWorkspace.didActivateApplicationNotification {
                        self?.mediaDidNotify()
                    }
                }
            }
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
        let isDrive = event.symbol.hasPrefix("externaldrive")
        guard isDrive ? settings.showDrivePeek : settings.showBluetoothPeek else { return }
        if event.connected { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        // Keyed by name: a quick disconnect → reconnect updates one alert instead of queueing two.
        post(.device, event.name, .device(event), duration: 3.5)
    }

    // MARK: - Settings

    func openSettings() {
        setHovering(false)
        SettingsWindow.shared.show(model: self)
    }

    // MARK: - Clipboard history

    func openClipboardSearch() {
        setHovering(false)
        ClipboardSearchWindow.shared.show(history: clipboard, below: islandScreenRect?())
    }

    func toggleClipboardSearch() {
        if ClipboardSearchWindow.shared.isOpen { ClipboardSearchWindow.shared.close() } else { openClipboardSearch() }
    }

    // MARK: - Cleaning mode

    func startCleaning(duration: TimeInterval? = nil) {
        setHovering(false)
        CleaningMode.shared.start(duration: duration ?? settings.cleaningDuration)
    }

    // MARK: - Color picker

    func pickColor() {
        setHovering(false)   // get out of the way of the loupe
        let sampler = NSColorSampler()
        colorSampler = sampler
        NSApp.activate(ignoringOtherApps: true)
        sampler.show { [weak self] color in
            MainActor.assumeIsolated { self?.colorPicked(color) }
        }
    }

    private func colorPicked(_ color: NSColor?) {
        colorSampler = nil
        guard let rgb = color?.usingColorSpace(.sRGB) else { return }   // nil → cancelled with Esc
        let hex = String(format: "#%02X%02X%02X",
                         Int((rgb.redComponent * 255).rounded()),
                         Int((rgb.greenComponent * 255).rounded()),
                         Int((rgb.blueComponent * 255).rounded()))
        copyColor(hex)
        cheer()
        withAnimation(Self.spring) {
            colorHistory.removeAll { $0 == hex }
            colorHistory.insert(hex, at: 0)
            colorHistory = Array(colorHistory.prefix(12))
        }
        UserDefaults.standard.set(colorHistory, forKey: "colorHistory")
        showColorPeek(hex)
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
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        post(.color, "", .color(hex), duration: 2.5)
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        guard var np = nowPlaying else { return }
        lastCommandAt = Date()
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
        if pluggedIn && new.hasBattery && settings.showChargingPeek { showChargingPeek() }
        if let level = lowBattery.update(new), settings.isActivityEnabled(.battery) {
            post(.battery, "low", .notice(Notice(symbol: level <= 10 ? "battery.0percent" : "battery.25percent", tint: .red,
                                                 title: "Низкий заряд", detail: "\(level)%")), duration: 5)
        }
    }

    // MARK: - System activities

    private func startSystemActivities() {
        disk.onLow = { [weak self] bytes in
            let free = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            self?.post(.disk, "", .notice(Notice(symbol: "internaldrive.fill", tint: .orange, title: "Мало места на диске",
                                                 detail: "свободно \(free)")), duration: 5)
        }
        disk.start()
        downloads.onFinished = { [weak self] url in
            self?.post(.download, url.lastPathComponent, .notice(Notice(symbol: "arrow.down.circle.fill", tint: .blue,
                                                                        title: url.lastPathComponent, detail: "загружено")),
                       duration: 3.5)
        }
        calendar.onAlert = { [weak self] event, startingNow in
            let time = event.startDate.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
            self?.post(.calendar, event.calendarItemIdentifier, .notice(Notice(
                symbol: "calendar", tint: .blue, title: event.title ?? "Событие",
                detail: startingNow ? "начинается" : "в \(time)")), duration: startingNow ? 6 : 5)
        }
        systemObservers = [
            settings.$downloadsWatchEnabled.removeDuplicates().sink { [weak self] on in
                MainActor.assumeIsolated { on ? self?.downloads.start() : self?.downloads.stop() }
            },
            settings.$calendarEnabled.removeDuplicates().sink { [weak self] on in
                MainActor.assumeIsolated { self?.calendar.setEnabled(on) }
            },
            settings.$calendarLeadMinutes.removeDuplicates().sink { [weak self] minutes in
                MainActor.assumeIsolated {
                    self?.calendar.leadMinutes = minutes
                    self?.calendar.reschedule()
                }
            },
        ]
    }

    private func showChargingPeek() {
        post(.battery, "charging", .charging(battery), duration: 3)
    }
}
