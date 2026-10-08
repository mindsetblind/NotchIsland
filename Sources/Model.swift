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

    let media = MediaService()
    private var timers: [Timer] = []
    private var peekWork: DispatchWorkItem?
    private var artworkKey: String?

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

    func size(for state: IslandState) -> CGSize {
        switch state {
        case .idle:     return notchSize
        case .music:    return CGSize(width: notchSize.width + 2 * 40, height: notchSize.height)
        case .charging: return CGSize(width: notchSize.width + 2 * 70, height: notchSize.height)
        case .expanded: return CGSize(width: max(480, notchSize.width + 290),
                                     height: notchSize.height + Self.contentTop + Self.artworkSize + Self.contentBottom)
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
