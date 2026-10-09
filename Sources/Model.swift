import AppKit
import SwiftUI

enum IslandState: Equatable {
    case idle        // looks exactly like the hardware notch
    case music       // small live activity: artwork + equalizer
    case charging    // short peek after plugging in power
    case expanded    // hover
}

final class IslandModel: ObservableObject {
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var hovering = false
    /// Pointer is over the notch but hasn't expanded it yet: the island "swells" a little.
    @Published private(set) var hoverHint = false
    @Published private(set) var chargingPeek = false
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
    private var timers: [Timer] = []
    private var peekWork: DispatchWorkItem?
    private var artworkKey: String?
    private var playlistTask: Task<Void, Never>?
    private var skipTask: Task<Void, Never>?
    /// Track the queue-skipper is currently heading to (shown with a spinner in the list).
    @Published private(set) var skipTargetID: String?

    init() {
        // An older login without playback-control permission must be redone once.
        spotifyLoggedIn = spotify.isLoggedIn && !spotify.needsReauth
        spotifyHasClientID = spotify.clientID != nil
    }

    /// General state changes (music started, charging peek).
    static let spring = Animation.spring(duration: 0.5, bounce: 0.22)
    /// Expanding: a little livelier, like the iPhone island.
    static let open = Animation.spring(duration: 0.52, bounce: 0.3)
    /// Collapsing: settles without overshoot so it doesn't wobble into the notch.
    static let close = Animation.spring(duration: 0.42, bounce: 0.08)
    static let hint = Animation.spring(duration: 0.3, bounce: 0.35)

    var state: IslandState {
        if hovering { return .expanded }
        if chargingPeek { return .charging }
        if nowPlaying?.isPlaying == true { return .music }
        return .idle
    }

    var isExpanded: Bool { hovering }

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
        case .music:    return CGSize(width: notchSize.width + 2 * 40, height: notchSize.height)
        case .charging: return CGSize(width: notchSize.width + 2 * 70, height: notchSize.height)
        case .expanded: return CGSize(width: max(480, notchSize.width + 290),
                                     height: notchSize.height + Self.contentTop + Self.artworkSize + Self.contentBottom
                                        + (showPlaylist ? Self.playlistHeight + Self.contentBottom : 0))
        }
    }

    var topRadius: CGFloat { state == .expanded ? 14 : 6 }
    var bottomRadius: CGFloat { state == .expanded ? 30 : 12 }

    func start() {
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
            if !value { showPlaylist = false }
        }
    }

    func setHoverHint(_ value: Bool) {
        guard value != hoverHint, !hovering else { return }
        withAnimation(Self.hint) { hoverHint = value }
    }

    // MARK: - Media

    func refreshMedia() {
        let np = media.fetch()
        if np != nowPlaying {
            withAnimation(Self.spring) { nowPlaying = np }
        }
        guard let np else {
            artworkKey = nil
            if artwork != nil { artwork = nil }
            return
        }
        // The track moved somewhere outside the list we show (user picked another playlist) → reload.
        if showPlaylist, !playlistLoading, skipTask == nil, let uri = np.trackURI,
           let list = playlist, !list.tracks.contains(where: { $0.uri == uri }) {
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

    func togglePlaylist() {
        withAnimation(Self.open) { showPlaylist.toggle() }
        if showPlaylist { loadPlaylist(onlyIfStale: true) }
    }

    func loadPlaylist(onlyIfStale: Bool = false) {
        guard spotifyHasClientID, spotifyLoggedIn else { return }
        if onlyIfStale, let list = playlist, let uri = nowPlaying?.trackURI,
           list.tracks.contains(where: { $0.uri == uri }) { return }
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

    func play(_ track: PlaylistTrack) {
        guard let list = playlist else { return }
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
                      let uri = media.currentSpotifyTrackURI(),
                      let current = list.tracks.firstIndex(where: { $0.uri == uri }),
                      current != target else { break }
                let forward = target > current
                // "Previous" first restarts the current track, so rewind it before stepping back.
                if !forward { media.seekToStart(.spotify) }
                media.send(forward ? .next : .previous, to: .spotify)
                steps += 1
                // Wait until Spotify has actually switched (up to ~0.6 s) before deciding the next step.
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if media.currentSpotifyTrackURI() != uri { break }
                }
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
