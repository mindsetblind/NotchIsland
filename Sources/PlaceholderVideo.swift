import AVFoundation
import SwiftUI

/// One shared, muted, looping player for the "artwork is loading" video.
/// Every placeholder on screen renders the same player, and it pauses when none are visible.
final class PlaceholderVideo {
    static let shared = PlaceholderVideo()

    let player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var viewers = 0

    var isAvailable: Bool { player != nil }

    private init() {
        guard let url = Bundle.main.url(forResource: "placeholder", withExtension: "mp4") else {
            player = nil
            return
        }
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
        player = p
    }

    func attach() {
        viewers += 1
        if viewers == 1 { player?.play() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { player?.pause() }
    }
}

struct PlaceholderVideoView: NSViewRepresentable {
    var corner: CGFloat

    func makeNSView(context: Context) -> PlayerHostView { PlayerHostView() }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        view.layer?.cornerRadius = corner
    }

    static func dismantleNSView(_ view: PlayerHostView, coordinator: ()) {
        view.detach()
    }
}

final class PlayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var attached = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        playerLayer.player = PlaceholderVideo.shared.player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !attached {
            attached = true
            PlaceholderVideo.shared.attach()
        } else if window == nil {
            detach()
        }
    }

    func detach() {
        guard attached else { return }
        attached = false
        PlaceholderVideo.shared.detach()
    }
}

/// What to show where a cover would be, until the cover arrives:
/// Resources/placeholder.jpg|png, else the looping placeholder.mp4, else a gradient with a note.
struct ArtworkPlaceholder: View {
    let corner: CGFloat

    private static let picture: NSImage? = ["jpg", "png"].lazy
        .compactMap { Bundle.main.url(forResource: "placeholder", withExtension: $0) }
        .compactMap { NSImage(contentsOf: $0) }
        .first

    var body: some View {
        if let picture = Self.picture {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else if PlaceholderVideo.shared.isAvailable {
            PlaceholderVideoView(corner: corner)
        } else {
            ZStack {
                LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geo in
                    Image(systemName: "music.note")
                        .font(.system(size: geo.size.width * 0.45))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
