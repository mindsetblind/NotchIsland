import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var shadowOn = false

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
        // A blurred shadow re-rendered on every frame of a resize is expensive, so it only
        // fades in once the island has finished opening, and drops instantly when it closes.
        .shadow(color: .black.opacity(shadowOn ? 0.5 : 0), radius: shadowOn ? 16 : 0, y: shadowOn ? 6 : 0)
        .onChange(of: model.isLarge) { _, large in
            if large {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard model.isLarge else { return }
                    withAnimation(.easeOut(duration: 0.2)) { shadowOn = true }
                }
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { shadowOn = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Button("Spotify Client ID…") { SpotifySettings.askClientID(model: model) }
            if model.spotifyLoggedIn {
                Button("Выйти из Spotify") { model.spotifyLogout() }
            }
            Divider()
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
        case .pomodoro:
            PomodoroCompactView(model: model, pomodoro: model.pomodoro)
                .frame(width: model.size(for: .pomodoro).width, height: model.notchSize.height)
                .transition(.islandContent(scale: 0.8))
        case .pomodoroPeek:
            if let peek = model.pomodoro.peek {
                PomodoroPeekView(model: model, peek: peek)
                    .frame(width: model.size(for: .pomodoroPeek).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .color:
            if let hex = model.colorPeek {
                ColorPeekView(model: model, hex: hex)
                    .frame(width: model.size(for: .color).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .device:
            if let event = model.devicePeek {
                DevicePeekView(model: model, event: event)
                    .frame(width: model.size(for: .device).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .drop:
            let s = model.size(for: .drop)
            DropZoneView(model: model)
                .frame(width: s.width, height: s.height, alignment: .top)
                .transition(.islandContent(scale: 0.9))
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
            .blur(radius: (1 - progress) * 5)
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
    static var notchGap: CGFloat { 8 }
    let notchWidth: CGFloat
    let height: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            // Keep a gap to the physical notch so nothing looks glued to (or hidden behind) its edge.
            left.frame(maxWidth: .infinity).padding(.trailing, Self.notchGap)
            Spacer().frame(width: notchWidth)
            right.frame(maxWidth: .infinity).padding(.leading, Self.notchGap)
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
            EqualizerView(isPlaying: model.nowPlaying?.isPlaying ?? false, tint: .white)
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
                TabBar(model: model)
                    .padding(.leading, IslandModel.inset - 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } right: {
                HStack {
                    Spacer()
                    IconButton(systemName: "power", size: 11) { NSApp.terminate(nil) }
                        .help("Выйти")
                }
                .padding(.trailing, IslandModel.inset - 7) // power button has its own 7pt hit padding
            }

            // Every tab shares the player's height, so switching tabs never resizes the island.
            ZStack(alignment: .top) {
                switch model.selectedTab {
                case .music: MediaPanel(model: model).transition(.islandContent(scale: 0.97))
                case .apps: AppsTab(model: model).transition(.islandContent(scale: 0.97))
                case .shelf: ShelfTab(model: model).transition(.islandContent(scale: 0.97))
                case .tools: ToolsTab(model: model).transition(.islandContent(scale: 0.97))
                }
            }
            .frame(height: IslandModel.artworkSize)
            .padding(.horizontal, IslandModel.inset)
            .padding(.top, IslandModel.contentTop)
            .padding(.bottom, IslandModel.contentBottom)

            if model.selectedTab == .music && model.showPlaylist {
                PlaylistPanel(model: model)
                    .frame(height: IslandModel.playlistHeight)
                    .padding(.horizontal, IslandModel.inset - 8)
                    .padding(.bottom, IslandModel.contentBottom)
                    .transition(.islandContent(scale: 0.96))
            }
        }
    }
}

struct TabBar: View {
    @ObservedObject var model: IslandModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases) { tab in
                let selected = model.selectedTab == tab
                Button { model.selectTab(tab) } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.45))
                        .frame(width: 28, height: 22)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.15))
                                    .matchedGeometryEffect(id: "selectedTab", in: ns)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if tab == .shelf && !model.shelf.isEmpty {
                                Circle().fill(.white).frame(width: 5, height: 5).offset(x: -4, y: 3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}

/// Shared empty state for the Apps and Shelf tabs.
private struct EmptyTab: View {
    let symbol: String
    let text: String
    var buttonTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08))
                .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
                .overlay(Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let buttonTitle { PillButton(title: buttonTitle, action: action) }
            }
            Spacer(minLength: 0)
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
                        EqualizerView(isPlaying: np.isPlaying, tint: .white).frame(width: 16, height: 12).padding(.top, 3)
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
                    .overlay(alignment: .leading) {
                        IconButton(systemName: "shuffle", size: 13) { model.toggleShuffle() }
                            .foregroundStyle(np.isShuffling ? Color.white : Color.white.opacity(0.4))
                            .overlay(alignment: .bottom) {
                                if np.isShuffling {
                                    Circle().fill(.white).frame(width: 3, height: 3).offset(y: 1)
                                }
                            }
                            .help(np.isShuffling ? "Перемешивание включено" : "Перемешивание выключено")
                    }
                    .overlay(alignment: .trailing) {
                        IconButton(systemName: "list.bullet", size: 13) { model.togglePlaylist() }
                            .foregroundStyle(model.showPlaylist ? Color.white : Color.white.opacity(0.55))
                            .help("Плейлист")
                    }
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

// MARK: - AirDrop drop zone

struct DropZoneView: View {
    @ObservedObject var model: IslandModel

    private static let airDropIcon: NSImage? = {
        let path = "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"
        return FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }()

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height)
            HStack(spacing: 12) {
                DropTile(title: "Полка", hint: "Положить на полку") {
                    Image(systemName: "tray.and.arrow.down.fill").resizable().scaledToFit().padding(7)
                } onDrop: { model.addToShelf($0) }

                DropTile(title: "AirDrop", hint: "Отправить по AirDrop") {
                    if let icon = Self.airDropIcon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").resizable().scaledToFit().padding(6)
                    }
                } onDrop: { model.airDrop($0) }
            }
            .padding(.horizontal, IslandModel.inset)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }
}

/// One dashed drop target that lights up while files hover over it.
private struct DropTile<Icon: View>: View {
    let title: String
    let hint: String
    @ViewBuilder var icon: Icon
    let onDrop: ([NSItemProvider]) -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(targeted ? 0.12 : 0.04))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(targeted ? 0.85 : 0.28), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            HStack(spacing: 12) {
                icon
                    .frame(width: 42, height: 42)
                    .scaleEffect(targeted ? 1.12 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(targeted ? "Отпусти" : hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, 12)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted.animation(.spring(duration: 0.3, bounce: 0.35))) { providers in
            onDrop(providers)
            return true
        }
        .onChange(of: targeted) { _, on in
            if on { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        }
    }
}

// MARK: - App launcher

struct AppsTab: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.apps.isEmpty {
            EmptyTab(symbol: "square.grid.2x2", text: "Добавь приложения, в которых часто работаешь",
                     buttonTitle: "Добавить") { model.addApps() }
        } else {
            HScroll {
                HStack(spacing: 4) {
                    ForEach(model.apps, id: \.self) { url in
                        AppIcon(model: model, url: url)
                            .transition(.scale(0.5).combined(with: .opacity))
                    }
                    Button { model.addApps() } label: {
                        // Same structure as AppIcon (46pt icon, label, 4pt dot slot) so the labels line up.
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                                .frame(width: 40, height: 40)
                                .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary))
                                .frame(width: 46, height: 46)
                            Text("Добавить").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            Color.clear.frame(width: 4, height: 4)
                        }
                        .frame(width: 66)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct AppIcon: View {
    @ObservedObject var model: IslandModel
    let url: URL
    @State private var hover = false

    var body: some View {
        let id = model.bundleID(for: url)
        let running = id.map { model.runningBundleIDs.contains($0) } ?? false
        let front = id != nil && id == model.frontmostBundleID

        VStack(spacing: 4) {
            Image(nsImage: model.icon(for: url))
                .resizable()
                .frame(width: 46, height: 46)
                .scaleEffect(hover ? 1.12 : 1, anchor: .bottom)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: 62)
            Circle()
                .fill(.white.opacity(front ? 0.95 : 0.45))
                .frame(width: 4, height: 4)
                .opacity(running ? 1 : 0)
        }
        .frame(width: 66)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.4)) { hover = h } }
        .onTapGesture { model.launch(url) }
        .contextMenu {
            Button("Открыть") { model.launch(url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Левее") { model.moveApp(url, by: -1) }
            Button("Правее") { model.moveApp(url, by: 1) }
            Divider()
            Button("Убрать из панели") { model.removeApp(url) }
        }
    }
}

// MARK: - Shelf

struct ShelfTab: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.shelf.isEmpty {
            EmptyTab(symbol: "tray", text: "Перетащи файлы к вырезу и брось их на «Полку»")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Self.filesLabel(model.shelf.count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    IconButton(systemName: "paperplane", size: 10) { model.airDrop(urls: model.shelf) }
                        .foregroundStyle(.secondary)
                        .help("Отправить всё по AirDrop")
                    IconButton(systemName: "trash", size: 10) { model.clearShelf() }
                        .foregroundStyle(.secondary)
                        .help("Очистить полку")
                }
                HScroll {
                    HStack(spacing: 6) {
                        ForEach(model.shelf, id: \.self) { url in
                            ShelfItem(model: model, url: url)
                                .transition(.scale(0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private static func filesLabel(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word = mod10 == 1 && mod100 != 11 ? "файл"
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "файла" : "файлов"
        return "\(n) \(word)"
    }
}

struct ShelfItem: View {
    @ObservedObject var model: IslandModel
    let url: URL
    @State private var hover: Bool

    init(model: IslandModel, url: URL, hover: Bool = false) {
        self.model = model
        self.url = url
        _hover = State(initialValue: hover)
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: model.icon(for: url))
                .resizable()
                .frame(width: 38, height: 38)
                .overlay(alignment: .topTrailing) {
                    if hover {
                        Button { model.removeFromShelf(url) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(white: 0.35))
                                .background(Circle().fill(.black).padding(1))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 7, y: -5)
                        .transition(.scale(0.5).combined(with: .opacity))
                        .help("Убрать с полки")
                    }
                }
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .padding(.top, 7)          // room for the close button above the icon
        .padding(.bottom, 4)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag {
            model.beginDragOut()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Открыть") { NSWorkspace.shared.open(url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Отправить по AirDrop") { model.airDrop(urls: [url]) }
            Divider()
            Button("Убрать с полки") { model.removeFromShelf(url) }
        }
        .help(url.path)
    }
}

// MARK: - Tools

struct ToolsTab: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 12) {
            ToolTile(symbol: "eyedropper.halffull", title: "Пипетка") { model.pickColor() }
                .help("Выбрать цвет на экране и скопировать HEX")
            PomodoroTile(pomodoro: model.pomodoro)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Последние цвета").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if !model.colorHistory.isEmpty {
                        IconButton(systemName: "trash", size: 10) { model.clearColors() }
                            .foregroundStyle(.secondary)
                            .help("Очистить историю цветов")
                    }
                }
                if model.colorHistory.isEmpty {
                    Text("Выбери цвет пипеткой — HEX сразу окажется в буфере обмена")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    HScroll {
                        HStack(spacing: 6) {
                            ForEach(model.colorHistory, id: \.self) { hex in
                                ColorSwatch(model: model, hex: hex)
                                    .transition(.scale(0.5).combined(with: .opacity))
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
    }
}

/// Square tool button, same size as the player artwork so tabs line up.
private struct ToolTile: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hover ? 0.14 : 0.08)))
            .scaleEffect(hover ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.4)) { hover = h } }
    }
}

private struct ColorSwatch: View {
    @ObservedObject var model: IslandModel
    let hex: String
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(Color(hex: hex))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .overlay {
                    if copied {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: hex).isLight ? .black : .white)
                    }
                }
                .frame(width: 34, height: 34)
                .scaleEffect(hover ? 1.1 : 1)
            Text(hex)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 58)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.4)) { hover = h } }
        .onTapGesture { copy(hex) }
        .contextMenu {
            Button("Копировать HEX  \(hex)") { copy(hex) }
            Button("Копировать rgb(…)") { copy(Color.cssRGB(hex)) }
            Button("Копировать Color(red:…)") { copy(Color.swiftUI(hex)) }
            Divider()
            Button("Удалить") { model.removeColor(hex) }
        }
        .help("Клик — скопировать \(hex)")
    }

    private func copy(_ text: String) {
        model.copyColor(text)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

struct ColorPeekView: View {
    @ObservedObject var model: IslandModel
    let hex: String

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            HStack(spacing: 7) {
                Circle().fill(Color(hex: hex))
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .frame(width: 16, height: 16)
                Text("Скопировано").font(.system(size: 12, weight: .medium))
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            Text(hex)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

extension Color {
    /// "#RRGGBB" → Color (sRGB).
    init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    private static func components(_ hex: String) -> (Int, Int, Int) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    static func cssRGB(_ hex: String) -> String {
        let (r, g, b) = components(hex)
        return "rgb(\(r), \(g), \(b))"
    }

    static func swiftUI(_ hex: String) -> String {
        let (r, g, b) = components(hex)
        let f = { (x: Int) in String(format: "%.3f", Double(x) / 255) }
        return "Color(red: \(f(r)), green: \(f(g)), blue: \(f(b)))"
    }

    /// Perceived brightness, to pick a readable checkmark color on top of the swatch.
    var isLight: Bool {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

// MARK: - Device peek

struct DevicePeekView: View {
    @ObservedObject var model: IslandModel
    let event: DeviceEvent

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            HStack(spacing: 7) {
                Image(systemName: event.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(event.connected ? .white : .secondary)
                Text(event.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(event.connected ? .primary : .secondary)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            Group {
                if !event.connected {
                    Text("Отключено").foregroundStyle(.secondary)
                } else if let battery = event.battery {
                    HStack(spacing: 5) {
                        Text("\(battery)%").foregroundStyle(battery <= 20 ? .red : .green)
                        BatteryGlyph(battery: Battery(level: battery, isCharging: false, onAC: false, hasBattery: true))
                    }
                    .help(event.detail ?? "")
                } else if let detail = event.detail {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Label("Подключено", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Spotify playlist

struct PlaylistPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.playlist?.title ?? "Плейлист")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let n = model.playlist?.tracks.count, n > 0 {
                    Text("\(n)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if model.playlistLoading {
                    ProgressView().controlSize(.mini)
                } else if model.spotifyLoggedIn || !isSpotify {
                    IconButton(systemName: "arrow.clockwise", size: 10) { model.loadPlaylist() }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)

            content
        }
        .padding(.top, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
    }

    /// Spotify needs a Client ID and login; Apple Music works straight through AppleScript.
    private var isSpotify: Bool { model.nowPlaying?.source != .music }

    @ViewBuilder private var content: some View {
        if isSpotify && !model.spotifyHasClientID {
            Placeholder(text: "Укажи Spotify Client ID: правый клик по острову → «Spotify Client ID…»") {
                PillButton(title: "Указать") { SpotifySettings.askClientID(model: model) }
            }
        } else if isSpotify && !model.spotifyLoggedIn {
            Placeholder(text: "Войди в Spotify, чтобы видеть треки плейлиста") {
                PillButton(title: "Войти в Spotify") { model.spotifyLogin() }
            }
        } else if let error = model.playlistError {
            Placeholder(text: error) {
                PillButton(title: "Повторить") { model.loadPlaylist() }
            }
        } else if let list = model.playlist {
            TrackList(model: model, tracks: list.tracks)
        } else {
            Spacer()
        }
    }
}

private struct Placeholder<Action: View>: View {
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackList: View {
    @ObservedObject var model: IslandModel
    let tracks: [PlaylistTrack]

    private var currentID: String? {
        guard let np = model.nowPlaying,
              let i = IslandModel.index(of: np.trackURI, name: np.title, in: tracks) else { return nil }
        return tracks[i].id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(tracks) { track in
                        TrackRow(track: track,
                                 isCurrent: track.id == currentID,
                                 isPending: track.id == model.skipTargetID && track.id != currentID,
                                 isPlaying: model.nowPlaying?.isPlaying ?? false) { model.play(track) }
                            .id(track.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            .onAppear { if let id = currentID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.1)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct TrackRow: View {
    let track: PlaylistTrack
    let isCurrent: Bool
    let isPending: Bool
    let isPlaying: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AsyncImage(url: track.imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ArtworkPlaceholder(corner: 6)
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    EqualizerView(isPlaying: isPlaying, tint: .white).frame(width: 14, height: 11)
                } else if isPending {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(Self.format(track.duration))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(isCurrent ? 0.12 : (isPending ? 0.09 : (hover ? 0.07 : 0)))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private static func format(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum SpotifySettings {
    static func askClientID(model: IslandModel) {
        let alert = NSAlert()
        alert.messageText = "Spotify Client ID"
        alert.informativeText = "Создай приложение на developer.spotify.com/dashboard с Redirect URI \(SpotifyWeb.redirectURI) и вставь сюда его Client ID."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = model.spotify.clientID ?? ""
        field.placeholderString = "Client ID"
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.setSpotifyClientID(field.stringValue)
        }
    }
}

// MARK: - Small components

/// Horizontal scroll row. In snapshot mode it renders as a plain row, because ImageRenderer
/// can't draw scroll view contents.
struct HScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if Snapshots.active {
            HStack(spacing: 0) { content }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholder(corner: corner)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Bouncing bars animated by Core Animation: the system render server drives them,
/// so the app does no per-frame work at all while music plays.
struct EqualizerView: NSViewRepresentable {
    let isPlaying: Bool
    let tint: Color

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(color: NSColor(tint).cgColor, playing: isPlaying)
    }
}

final class EqualizerNSView: NSView {
    private var bars: [CALayer] = []
    private var playing: Bool?
    // Each bar gets its own rhythm so the motion looks organic rather than in lockstep.
    private static let rhythms: [(values: [CGFloat], duration: Double)] = [
        ([0.35, 0.9, 0.5, 1.0, 0.4, 0.75, 0.35], 1.3),
        ([0.8, 0.4, 1.0, 0.55, 0.9, 0.3, 0.8], 1.1),
        ([0.5, 1.0, 0.35, 0.8, 0.45, 0.95, 0.5], 1.45),
        ([0.9, 0.45, 0.7, 0.3, 1.0, 0.6, 0.9], 1.2),
    ]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in Self.rhythms.indices {
            let bar = CALayer()
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let n = CGFloat(bars.count)
        let gap = bounds.width * 0.12
        let w = (bounds.width - gap * (n - 1)) / n
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }

    func update(color: CGColor, playing: Bool) {
        bars.forEach { $0.backgroundColor = color }
        guard playing != self.playing else { return }
        self.playing = playing
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if playing {
                let r = Self.rhythms[i]
                let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
                anim.values = r.values
                anim.duration = r.duration
                anim.calculationMode = .cubic
                anim.repeatCount = .infinity
                bar.add(anim, forKey: "bounce")
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.2, 1)
            }
        }
        if playing { bars.forEach { $0.transform = CATransform3DIdentity } }
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
