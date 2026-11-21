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
        // Black is the *background*, not a sibling layer: in a ZStack SwiftUI may draw an outgoing
        // view below its siblings during the removal transition, so the old content was hidden
        // behind the black fill and seemed to vanish in a single frame.
        ZStack(alignment: .top) {
            content
        }
        .frame(width: size.width + tr * 2, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: tr, bottomRadius: model.bottomRadius))
        // A blurred shadow re-rendered on every frame of a resize is expensive, so it only
        // fades in once the island has finished opening, and fades out fast when it closes.
        .shadow(color: .black.opacity(shadowOn ? 0.5 : 0), radius: shadowOn ? 16 : 0, y: shadowOn ? 6 : 0)
        .offset(x: model.islandShift)
        .onChange(of: model.isLarge) { _, large in
            if large {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard model.isLarge else { return }
                    withAnimation(.easeOut(duration: 0.2)) { shadowOn = true }
                }
            } else {
                // Fade it out quickly. (Removing it inside a no-animation transaction also killed the
                // collapse animation that runs in the same update — the island snapped shut in one frame.)
                withAnimation(.easeOut(duration: 0.15)) { shadowOn = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Button("Настройки…") { model.openSettings() }
            if Updates.shared.available {
                Button("Проверить обновления…") { model.setHovering(false); Updates.shared.checkNow() }
            }
            Divider()
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
            if model.showsPet {
                PetEarView(model: model)
                    .frame(width: model.size(for: .idle).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            } else {
                Color.clear
            }
        case .music:
            CompactMusicView(model: model)
                .frame(width: model.size(for: .music).width, height: model.size(for: .music).height)
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
            if case .pomodoroPeek(let peek) = model.currentActivity {
                PomodoroPeekView(model: model, peek: peek)
                    .frame(width: model.size(for: .pomodoroPeek).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .color:
            if case .color(let hex) = model.currentActivity {
                ColorPeekView(model: model, hex: hex)
                    .frame(width: model.size(for: .color).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .device:
            if case .device(let event) = model.currentActivity {
                DevicePeekView(model: model, event: event)
                    .frame(width: model.size(for: .device).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .permission:
            if let ask = model.claude.permissions.first {
                let s = model.size(for: .permission)
                PermissionCardView(model: model, claude: model.claude, ask: ask)
                    .frame(width: s.width, height: s.height, alignment: .top)
                    .transition(.islandContent(scale: 0.92))
            }
        case .agent:
            AgentCompactView(model: model, claude: model.claude)
                .frame(width: model.size(for: .agent).width, height: model.notchSize.height)
                .transition(.islandContent(scale: 0.8))
        case .agentPeek:
            if case .agentPeek(let peek) = model.currentActivity {
                AgentPeekView(model: model, peek: peek)
                    .frame(width: model.size(for: .agentPeek).width, height: model.notchSize.height)
                    .transition(.islandContent(scale: 0.8))
            }
        case .notice:
            if case .notice(let notice) = model.currentActivity {
                NoticeView(model: model, notice: notice)
                    .frame(width: model.size(for: .notice).width, height: model.notchSize.height)
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
    /// `delay`: compact states wait a bit longer so they appear as the shape settles into the notch.
    static func islandContent(scale: CGFloat, delay: Double? = nil) -> AnyTransition {
        // Reduce motion: a plain cross-fade, no blur or zoom.
        if IslandModel.reduceMotion { return .opacity.animation(.easeInOut(duration: 0.2)) }
        let fx = AnyTransition.modifier(active: IslandContentEffect(progress: 0, scale: scale),
                                        identity: IslandContentEffect(progress: 1, scale: scale))
        return .asymmetric(
            // Appear slightly after the shape starts growing, so content "lands" in it.
            insertion: fx.animation(.spring(duration: 0.45, bounce: 0.1).delay(delay ?? (scale <= 0.8 ? 0.12 : 0.07))),
            // Fade fast at first (ease-out), so the content is mostly gone before the shrinking shape
            // starts to crop it; it also shrinks toward the notch.
            removal: fx.animation(.easeOut(duration: 0.15))
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
        // A bit larger than the notch (wider ears, slightly taller) so the cover is readable at a glance.
        EarsLayout(notchWidth: model.notchSize.width, height: model.size(for: .music).height) {
            ArtworkView(image: model.artwork, size: 26, corner: 7)
        } right: {
            if model.showsPet {
                // The pet's eyes bounce like equalizer bars while music plays.
                PetView(mood: model.petMood, size: 17, gaze: model.petGaze, accessories: model.petAccessories,
                        extras: PetExtras(agents: model.petAgents))
            } else {
                EqualizerView(isPlaying: model.nowPlaying?.isPlaying ?? false, tint: .white)
                    .frame(width: 22, height: 17)
            }
        }
    }
}

/// Collapsed island with nothing else going on: just the pet, right of the notch.
struct PetEarView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        // Only the right ear (the island is shifted right by half an ear, see `islandShift`); the cat
        // is centred in it — its whiskers already keep clear of the notch edge.
        HStack(spacing: 0) {
            Spacer().frame(width: model.notchSize.width)
            PetView(mood: model.petMood, size: 17, gaze: model.petGaze, accessories: model.petAccessories,
                    extras: PetExtras(agents: model.petAgents, entrance: PetEntrance.once(), easterEgg: true))
                .frame(maxWidth: .infinity)
        }
        .frame(height: model.notchSize.height)
    }
}

struct ChargingPeekView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            Text("зарядка").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        } right: {
            HStack(spacing: 6) {
                Text("\(model.battery.level)%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.green)
                BatteryGlyph(battery: model.battery)
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    /// The tab whose dot is under the pointer: its name shows in the header.
    @State private var hoveredTab: IslandTab?

    var body: some View {
        VStack(spacing: 0) {
            // Quiet header: the pet acting out the tab (or the dash you point at), settings and quit.
            EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                TabPet(model: model, claude: model.claude, tab: hoveredTab ?? model.selectedTab)
                    .padding(.leading, IslandModel.inset - 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } right: {
                HStack(spacing: 0) {
                    Spacer()
                    IconButton(systemName: "gearshape", size: 10) { model.openSettings() }
                        .foregroundStyle(.white.opacity(0.45))
                        .help("Настройки")
                        .accessibilityLabel("Настройки")
                    IconButton(systemName: "power", size: 10) { NSApp.terminate(nil) }
                        .foregroundStyle(.white.opacity(0.45))
                        .help("Выйти")
                        .accessibilityLabel("Выйти из NotchIsland")
                }
                .padding(.trailing, IslandModel.inset - 7) // power button has its own 7pt hit padding
            }

            // Every tab shares the player's height, so switching tabs never resizes the island.
            ZStack(alignment: .top) {
                switch model.selectedTab {
                case .music: MediaPanel(model: model).transition(.islandContent(scale: 0.97))
                case .apps: AppsTab(model: model).transition(.islandContent(scale: 0.97))
                case .shelf: ShelfTab(model: model).transition(.islandContent(scale: 0.97))
                case .clipboard: ClipboardTab(model: model, history: model.clipboard, store: model.clipboard.store)
                    .transition(.islandContent(scale: 0.97))
                case .agents: AgentsTab(model: model, claude: model.claude, tracker: model.developer.tracker)
                    .transition(.islandContent(scale: 0.97))
                case .tools: ToolsTab(model: model).transition(.islandContent(scale: 0.97))
                }
            }
            .frame(height: IslandModel.artworkSize)
            .padding(.horizontal, IslandModel.inset)
            .padding(.top, IslandModel.contentTop)
            .padding(.bottom, IslandModel.contentBottom)
            .overlay(alignment: .bottom) {
                TabBar(model: model, hovered: $hoveredTab).padding(.bottom, 4)
            }

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

/// The pet in the header, doing what the tab is about: dancing to music, apps orbiting it, hungry for
/// files (or full of them), copies rolling over it, thinking with the agents, being built for tools.
struct TabPet: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var claude: ClaudeMonitor
    let tab: IslandTab

    var body: some View {
        PetView(mood: mood, size: 15, extras: PetExtras(agents: tab == .apps ? 3 : 0, motif: motif))
            .accessibilityLabel(tab.title)
    }

    private var mood: PetMood {
        switch tab {
        case .music: return model.nowPlaying?.isPlaying == true ? .dancing : .idle
        case .apps, .clipboard, .tools: return .idle
        case .shelf: return model.shelf.isEmpty ? .hungry : .full
        case .agents: return claude.isAnyWaiting ? .attention : claude.isAnyWorking ? .thinking : .idle
        }
    }

    private var motif: IcosaMotif {
        switch tab {
        case .clipboard: return .ripple
        case .tools: return .build
        default: return .none
        }
    }
}

/// Tabs as a row of short dashes under the content: the current one is long and white.
/// Pointing at a dash shows the tab's name in the header.
struct TabBar: View {
    @ObservedObject var model: IslandModel
    @Binding var hovered: IslandTab?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.visibleTabs) { tab in
                let selected = model.selectedTab == tab
                let lit = selected || hovered == tab
                // A file waits on the shelf: its dash stays a little brighter.
                let waiting = tab == .shelf && !model.shelf.isEmpty
                Button { model.selectTab(tab) } label: {
                    Capsule()
                        .fill(.white.opacity(selected ? 1 : lit ? 0.7 : waiting ? 0.55 : 0.25))
                        .frame(width: selected ? 14 : 5, height: 2)
                        .frame(width: 22, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in hovered = h ? tab : (hovered == tab ? nil : hovered) }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: model.selectedTab)
        .animation(.easeOut(duration: 0.12), value: hovered)
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
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.3))
                .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
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
            HStack(spacing: 16) {
                ArtworkView(image: model.artwork, size: IslandModel.artworkSize, corner: 10)

                // Title with the artist small beneath, a hairline with the position, then the controls.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(np.title).font(.system(size: 14)).lineLimit(1)
                            Text(np.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let other = model.mediaSources.first(where: { $0 != np.source }) {
                            SourceSwitchButton(target: other) { model.switchMediaSource() }
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 0)
                    ProgressRow(np: np) { model.seek(to: $0) }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        MacMediaButton(systemName: "backward.fill", size: 15) { model.perform(.previous) }
                            .accessibilityLabel("Предыдущий трек")
                        MacMediaButton(systemName: np.isPlaying ? "pause.fill" : "play.fill", size: 21) { model.perform(.playPause) }
                            .accessibilityLabel(np.isPlaying ? "Пауза" : "Воспроизвести")
                        MacMediaButton(systemName: "forward.fill", size: 15) { model.perform(.next) }
                            .accessibilityLabel("Следующий трек")
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if np.source == .youtube {
                            // A video: no shuffle — just say where it plays.
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.leading, 6)
                                .help("Видео в браузере")
                        } else {
                            MacMediaButton(systemName: "shuffle", size: 11, isOn: np.isShuffling, secondary: true) { model.toggleShuffle() }
                                .help(np.isShuffling ? "Перемешивание включено" : "Перемешивание выключено")
                                .accessibilityLabel(np.isShuffling ? "Перемешивание включено" : "Перемешивание выключено")
                        }
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) {
                            SpeakerButton(model: model, size: 11, macStyle: true)
                            if np.source != .youtube {
                                MacMediaButton(systemName: "list.bullet", size: 11, isOn: model.showPlaylist, secondary: true) { model.togglePlaylist() }
                                    .help("Плейлист")
                                    .accessibilityLabel("Плейлист")
                            }
                        }
                    }
                    .padding(.bottom, -4) // optical: buttons carry hit padding below the glyph
                }
            }
        } else {
            HStack(spacing: 14) {
                Image(systemName: "music.note").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.3))
                    .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
                VStack(alignment: .leading, spacing: 10) {
                    switch model.mediaProblem {
                    case .denied(let source)?:
                        Text("Нет доступа к \(source == .spotify ? "Spotify" : "«Музыке»")")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Разреши NotchIsland управлять приложением: Конфиденциальность → Автоматизация.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        PillButton(title: "Открыть настройки") { model.openAutomationSettings() }
                    case .unavailable(let source)?:
                        Text("\(source == .spotify ? "Spotify" : "«Музыка»") не отвечает")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Остров попробует снова через минуту.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    case nil:
                        Text("Ничего не играет").font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                        HStack(spacing: 8) {
                            PillButton(title: "Музыка") { open("com.apple.Music") }
                            PillButton(title: "Spotify") { open("com.spotify.client") }
                        }
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
    var onSeek: (Double) -> Void = { _ in }

    /// 0…1 while the bar is being dragged; the bar follows the finger, the player jumps on release.
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        // ~12 updates/s is smooth for a bar that moves a couple of points per second, at a third of the cost.
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !np.isPlaying || dragFraction != nil)) { ctx in
            let live = np.position(at: ctx.date)
            let pos = dragFraction.map { $0 * np.duration } ?? live
            let fraction = np.duration > 0 ? min(1, max(0, pos / np.duration)) : 0
            let active = hovering || dragFraction != nil
            HStack(spacing: 10) {
                Text(format(pos))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: active ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard np.duration > 0, geo.size.width > 0 else { return }
                                dragFraction = min(1, max(0, v.location.x / geo.size.width))
                            }
                            .onEnded { v in
                                guard np.duration > 0, geo.size.width > 0 else { dragFraction = nil; return }
                                let f = min(1, max(0, v.location.x / geo.size.width))
                                onSeek(f * np.duration)
                                dragFraction = nil
                            }
                    )
                    .onHover { hovering = $0 }
                }
                .frame(height: 12)
                .animation(.easeOut(duration: 0.12), value: active)
                Text("-" + format(max(0, np.duration - pos)))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(active ? 0.75 : 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Позиция в треке")
            .accessibilityValue("\(format(pos)) из \(format(np.duration))")
            .accessibilityAdjustableAction { direction in
                let step = 10.0
                onSeek(live + (direction == .increment ? step : -step))
            }
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
                DropTile(title: "Полка", hint: "Покорми пета файлом") { targeted in
                    // Mouth open while you carry the file; wide open when it's right above.
                    PetView(mood: targeted ? .gaping : .hungry, size: 26)
                } onDrop: { model.addToShelf($0) }

                DropTile(title: "AirDrop", hint: "Отправить по AirDrop") { _ in
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
    @ViewBuilder var icon: (_ targeted: Bool) -> Icon
    let onDrop: ([NSItemProvider]) -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(targeted ? 0.06 : 0))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(targeted ? 0.7 : 0.18), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
            HStack(spacing: 12) {
                icon(targeted)
                    .frame(width: 42, height: 42)
                    .scaleEffect(targeted ? 1.12 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15))
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
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
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
                .foregroundStyle(.white.opacity(0.6))
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
        HStack(spacing: 4) {
            ToolTile(symbol: "eyedropper", title: "Пипетка") { model.pickColor() }
            PomodoroTile(pomodoro: model.pomodoro)
            ToolTile(symbol: "house", title: "Дом") { model.openHome() }
                .help("План квартиры и лампы Умного дома Яндекса")
            ToolTile(symbol: "sparkles", title: "Чистка") { model.startCleaning() }
                .help("Чёрный экран, клавиатура и трекпад отключены. Выход — удерживать Esc 2 с")
                .contextMenu {
                    ForEach(CleaningMode.durations, id: \.self) { d in
                        Button(d < 60 ? "Чистка на \(Int(d)) с" : "Чистка на \(Int(d / 60)) мин") {
                            model.startCleaning(duration: d)
                        }
                    }
                    Divider()
                    if CleaningMode.shared.blocksMediaKeys {
                        Text("Клавиши яркости и громкости тоже блокируются")
                    } else {
                        Button("Блокировать и клавиши яркости/громкости…") { CleaningMode.requestMediaKeyBlocking() }
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("цвета").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1).fixedSize()
                    Spacer()
                    if !model.colorHistory.isEmpty {
                        IconButton(systemName: "trash", size: 10) { model.clearColors() }
                            .foregroundStyle(.secondary)
                            .help("Очистить историю цветов")
                    }
                }
                if model.colorHistory.isEmpty {
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
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(hover ? 0.9 : 0.45))
            }
            .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hover ? 0.05 : 0)))
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
                    .frame(width: 9, height: 9)
                Text("скопировано").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            Text(hex)
                .font(.system(size: 12, design: .monospaced))
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
            Text(event.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(event.connected ? 0.75 : 0.4))
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            Group {
                if !event.connected {
                    Text("отключено").foregroundStyle(.white.opacity(0.4))
                } else if let battery = event.battery {
                    HStack(spacing: 5) {
                        Text("\(battery)%").foregroundStyle(battery <= 20 ? .red : .green)
                        BatteryGlyph(battery: Battery(level: battery, isCharging: false, onAC: false, hasBattery: true))
                    }
                    .help(event.detail ?? "")
                } else if let detail = event.detail {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("подключено").foregroundStyle(.green)
                }
            }
            .font(.system(size: 12).monospacedDigit())
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

@MainActor
enum SpotifySettings {
    static func askClientID(model: IslandModel) {
        model.setHovering(false)   // the open island would float over the dialog
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
        // Reduce motion: still bars of different heights instead of bouncing ones.
        if playing && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (i, bar) in bars.enumerated() {
                bar.removeAllAnimations()
                bar.transform = CATransform3DMakeScale(1, [0.6, 1, 0.75, 0.9][i % 4], 1)
            }
            return
        }
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

/// Media control in the style of macOS Control Center's Now Playing: filled glyphs, a soft rounded
/// highlight on hover, dimming on press; toggles get a filled circle when on.
/// "⇄ YouTube": shows the other player that has something loaded (Spotify and a video at once).
struct SourceSwitchButton: View {
    let target: MediaSource
    let action: () -> Void
    @State private var hover = false

    private var title: String {
        switch target {
        case .spotify: return "Spotify"
        case .music: return "Музыка"
        case .youtube: return "Видео"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .bold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hover ? 0.95 : 0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(hover ? 0.18 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Показать \(title)")
        .accessibilityLabel("Переключить на \(title)")
    }
}

struct MacMediaButton: View {
    let systemName: String
    let size: CGFloat
    var isOn = false
    var secondary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: secondary ? .semibold : .regular))
                .frame(width: size + 16, height: size + 12)
        }
        .buttonStyle(MacMediaButtonStyle(isOn: isOn, secondary: secondary))
    }
}

struct MacMediaButtonStyle: ButtonStyle {
    var isOn = false
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, isOn: isOn, secondary: secondary)
    }

    private struct Face: View {
        let configuration: Configuration
        let isOn: Bool
        let secondary: Bool
        @State private var hover = false

        var body: some View {
            configuration.label
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.white.opacity(secondary ? 0.6 : 0.95))
                .background {
                    if isOn {
                        Circle().fill(.white.opacity(0.9)).padding(3)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(configuration.isPressed ? 0.18 : hover ? 0.1 : 0))
                    }
                }
                .opacity(configuration.isPressed ? 0.65 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(hover ? 0.08 : 0)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Sends the Mac's sound to the Yandex speaker and back (shown once a speaker is paired).
struct SpeakerButton: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var link = SpeakerLink.shared
    var size: CGFloat = 13
    var macStyle = false

    var body: some View {
        if link.isAvailable {
            let active = link.isActive
            Group {
                if link.isBusy {
                    ProgressView().controlSize(.mini).frame(width: size + 6, height: size + 6)
                } else if macStyle {
                    MacMediaButton(systemName: "hifispeaker.fill", size: size, isOn: active, secondary: true) { model.toggleSpeaker() }
                } else {
                    IconButton(systemName: active ? "hifispeaker.fill" : "hifispeaker", size: size) { model.toggleSpeaker() }
                        .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
                }
            }
            .help(help(active: active))
            .accessibilityLabel(active ? "Вернуть звук на Mac" : "Звук на Станцию")
        }
    }

    private func help(active: Bool) -> String {
        switch link.phase {
        case .working(let text): return text
        case .failed(let text) where !active: return text
        default: return active ? "Звук играет на Станции — нажми, чтобы вернуть на Mac" : "Включить Bluetooth на Станции и играть звук через неё"
        }
    }
}
