import AppKit
import NotchIslandCore
import SwiftUI

/// What an activity shows in the collapsed island. Existing activities have their own views;
/// new ones can use `.notice` and get a consistent look without writing a view.
enum IslandActivity: Equatable {
    // Live
    case music
    case pomodoro
    case agent
    // Alerts
    case charging(Battery)
    case device(DeviceEvent)
    case color(String)
    case pomodoroPeek(PomodoroPeek)
    case agentPeek(AgentPeek)
    case notice(Notice)

    var state: IslandState {
        switch self {
        case .music: return .music
        case .pomodoro: return .pomodoro
        case .agent: return .agent
        case .charging: return .charging
        case .device: return .device
        case .color: return .color
        case .pomodoroPeek: return .pomodoroPeek
        case .agentPeek: return .agentPeek
        case .notice: return .notice
        }
    }
}

/// Generic compact content: icon + title on the left ear, detail / elapsed time / progress on the right.
struct Notice: Equatable {
    enum Tint: Equatable {
        case white, green, red, orange, yellow, blue

        var color: Color {
            switch self {
            case .white: return .white
            case .green: return Color(nsColor: .systemGreen)
            case .red: return Color(nsColor: .systemRed)
            case .orange: return Color(nsColor: .systemOrange)
            case .yellow: return Color(nsColor: .systemYellow)
            case .blue: return Color(nsColor: .systemBlue)
            }
        }
    }

    var symbol: String
    var tint: Tint = .white
    var title: String
    var detail: String?
    /// Shows a running clock on the right (live tasks).
    var startedAt: Date?
    var progress: Double?
    /// Shows an activity indicator instead of the symbol.
    var spinning = false
    /// Tab to open when the island is clicked while this is shown.
    var tab: IslandTab?
    /// The pet's offer: a click opens the pet with this request (and its face replaces the symbol).
    var petRequest: String?
}

typealias IslandActivities = ActivityCoordinator<IslandActivity>

extension IslandActivities {
    /// Coordinator whose timed changes (alerts expiring) animate like every other island change.
    static func live() -> IslandActivities {
        IslandActivities(scheduler: { delay, action in
            let work = DispatchWorkItem { MainActor.assumeIsolated { withAnimation(IslandModel.spring) { action() } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
            return { work.cancel() }
        })
    }
}

// MARK: - Generic compact view

struct NoticeView: View {
    @ObservedObject var model: IslandModel
    let notice: Notice

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            HStack(spacing: 7) {
                if notice.spinning {
                    SpinnerView(color: notice.tint.color).frame(width: 14, height: 14)
                } else if notice.petRequest != nil {
                    PetView(mood: .attention, size: 14)
                } else {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(notice.tint.color)
                }
                Text(notice.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            right
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var right: some View {
        if let start = notice.startedAt {
            // Updates once a second only while it's on screen.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(formatElapsed(ctx.date.timeIntervalSince(start))).foregroundStyle(notice.tint.color)
            }
        } else if let progress = notice.progress {
            PomodoroRing(progress: progress, color: notice.tint.color, lineWidth: 2.5).frame(width: 15, height: 15)
        } else if let detail = notice.detail {
            Text(detail).foregroundStyle(notice.tint == .white ? .secondary : notice.tint.color)
        }
    }
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Small rotating arc on Core Animation (a SwiftUI rotation would re-render every frame).
struct SpinnerView: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> SpinnerNSView { SpinnerNSView() }
    func updateNSView(_ view: SpinnerNSView, context: Context) { view.color = NSColor(color).cgColor }
}

final class SpinnerNSView: NSView {
    private let arc = CAShapeLayer()
    var color: CGColor = .white { didSet { arc.strokeColor = color } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.7
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        CATransaction.commit()
        guard arc.animation(forKey: "spin") == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            arc.strokeEnd = 1
            arc.opacity = 0.6
            return
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
}
