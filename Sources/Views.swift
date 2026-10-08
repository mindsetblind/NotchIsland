import AppKit
import SwiftUI

// MARK: - Shape

/// Notch silhouette: concave flares at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let size = model.islandSize
        let tr = model.topRadius

        // Only the black silhouette animates its size. Each content view is laid out once at its
        // final size and revealed by the mask, so text never re-flows mid-animation.
        ZStack(alignment: .top) {
            Color.black
            content
        }
        .frame(width: size.width + tr * 2, height: size.height, alignment: .top)
        .clipShape(NotchShape(topRadius: tr, bottomRadius: model.bottomRadius))
        .shadow(color: .black.opacity(model.isExpanded ? 0.5 : 0), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Toggle("Запускать при входе", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.setEnabled($0) }
            ))
            Divider()
            Button("Выйти из NotchIsland") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .music:
            CompactMusicView(model: model)
                .frame(width: model.size(for: .music).width, height: model.notchSize.height)
                .transition(.islandContent(scale: 0.8))
        case .charging:
            ChargingPeekView(model: model)
                .frame(width: model.size(for: .charging).width, height: model.notchSize.height)
                .transition(.islandContent(scale: 0.8))
        case .expanded:
            let s = model.size(for: .expanded)
            ExpandedView(model: model)
                .frame(width: s.width, height: s.height, alignment: .top)
                .transition(.islandContent(scale: 0.9))
        }
    }
}

// MARK: - Content transition

/// Fade + un-blur + slight grow from the top. Driven by a single progress value so SwiftUI
/// interpolates all three effects together.
struct IslandContentEffect: ViewModifier {
    let progress: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(scale + (1 - scale) * progress, anchor: .top)
    }
}

extension AnyTransition {
    static func islandContent(scale: CGFloat) -> AnyTransition {
        let fx = AnyTransition.modifier(active: IslandContentEffect(progress: 0, scale: scale),
                                        identity: IslandContentEffect(progress: 1, scale: scale))
        return .asymmetric(
            // Appear slightly after the shape starts growing, so content "lands" in it.
            insertion: fx.animation(.spring(duration: 0.45, bounce: 0.1).delay(0.07)),
            // Disappear quickly, before the shape shrinks over it.
            removal: fx.animation(.easeOut(duration: 0.14))
        )
    }
}

// MARK: - Compact states

/// Content laid out on the two "ears" left and right of the physical notch.
struct EarsLayout<Left: View, Right: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            Spacer().frame(width: notchWidth)
            right.frame(maxWidth: .infinity)
        }
        .frame(height: height)
    }
}

struct CompactMusicView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            ArtworkView(image: model.artwork, size: 20, corner: 5)
        } right: {
            EqualizerView(isPlaying: model.nowPlaying?.isPlaying ?? false, tint: .green)
                .frame(width: 18, height: 14)
        }
    }
}

struct ChargingPeekView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text("Зарядка").font(.system(size: 12, weight: .medium))
            }
        } right: {
            HStack(spacing: 6) {
                Text("\(model.battery.level)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.green)
                BatteryGlyph(battery: model.battery)
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                HStack {
                    Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, IslandModel.inset)
            } right: {
                HStack(spacing: 10) {
                    Spacer()
                    if model.battery.hasBattery {
                        HStack(spacing: 5) {
                            Text("\(model.battery.level)%")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            BatteryGlyph(battery: model.battery)
                        }
                    }
                    IconButton(systemName: "power", size: 11) { NSApp.terminate(nil) }
                        .help("Выйти")
                }
                .padding(.trailing, IslandModel.inset - 7) // power button has its own 7pt hit padding
            }

            MediaPanel(model: model)
                .frame(height: IslandModel.artworkSize)
                .padding(.horizontal, IslandModel.inset)
                .padding(.top, IslandModel.contentTop)
                .padding(.bottom, IslandModel.contentBottom)
        }
    }
}

struct MediaPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let np = model.nowPlaying {
            HStack(spacing: 14) {
                ArtworkView(image: model.artwork, size: IslandModel.artworkSize, corner: 14)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 3)

                // Title pinned to the artwork's top, controls to its bottom, progress evenly between.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(np.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(np.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        EqualizerView(isPlaying: np.isPlaying, tint: .green).frame(width: 16, height: 12).padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                    ProgressRow(np: np)
                    Spacer(minLength: 0)
                    HStack(spacing: 22) {
                        IconButton(systemName: "backward.fill", size: 16) { model.perform(.previous) }
                        IconButton(systemName: np.isPlaying ? "pause.fill" : "play.fill", size: 22) { model.perform(.playPause) }
                            .contentTransition(.symbolEffect(.replace))
                        IconButton(systemName: "forward.fill", size: 16) { model.perform(.next) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, -5) // optical: icon buttons carry 5pt of hit padding below the glyph
                }
            }
        } else {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08))
                    .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
                    .overlay(Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.secondary))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ничего не играет").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 8) {
                        PillButton(title: "Музыка") { open("com.apple.Music") }
                        PillButton(title: "Spotify") { open("com.spotify.client") }
                    }
                }
                Spacer()
            }
        }
    }

    private func open(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

struct ProgressRow: View {
    let np: NowPlaying

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !np.isPlaying)) { ctx in
            let pos = np.position(at: ctx.date)
            let fraction = np.duration > 0 ? pos / np.duration : 0
            HStack(spacing: 8) {
                Text(format(pos))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
                Text("-" + format(max(0, np.duration - pos)))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func format(_ t: Double) -> String {
        let s = Int(t.isFinite ? t : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Small components

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct EqualizerView: View {
    let isPlaying: Bool
    let tint: Color
    private let phases: [Double] = [0, 1.7, 0.9, 2.6]

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: geo.size.width * 0.12) {
                    ForEach(phases.indices, id: \.self) { i in
                        // Two overlapping waves per bar look organic instead of mechanically bouncing.
                        let w = 0.5 + 0.3 * sin(t * (3.1 + Double(i) * 0.7) + phases[i])
                                    + 0.2 * sin(t * (7.3 - Double(i) * 0.9) + phases[i] * 2)
                        let v = isPlaying ? 0.25 + 0.75 * w : 0.2
                        Capsule().fill(tint).frame(height: geo.size.height * v)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

struct BatteryGlyph: View {
    let battery: Battery

    var body: some View {
        let color: Color = battery.onAC ? .green : (battery.level <= 20 ? .red : .white)
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.5), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5).fill(color)
                    .frame(width: max(2, 18 * CGFloat(battery.level) / 100))
                    .padding(2)
                if battery.isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black).frame(maxWidth: .infinity)
                }
            }
            .frame(width: 24, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.5)).frame(width: 1.5, height: 4)
        }
    }
}

struct IconButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 10)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
                .scaleEffect(hover ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.4)) { hover = h } }
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(hover ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
