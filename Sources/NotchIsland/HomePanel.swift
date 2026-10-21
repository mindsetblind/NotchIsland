import AppKit
import NotchIslandCore
import SwiftUI

// MARK: - Window

/// Floating "Дом" panel under the notch: the flat's floor plan with the lamps on it.
final class HomePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: HomeView.size.width, height: HomeView.size.height),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    /// Clicking anywhere else closes it, like the clipboard search.
    override func resignKey() {
        super.resignKey()
        HomeWindow.shared.close()
    }

    override func cancelOperation(_ sender: Any?) { HomeWindow.shared.close() }
}

@MainActor
final class HomeWindow {
    static let shared = HomeWindow()
    private var panel: HomePanel?

    var isOpen: Bool { panel?.isVisible == true }

    func show(below notch: CGRect?, openSettings: @escaping () -> Void) {
        close()
        let panel = HomePanel()
        let home = SmartHomeController.shared
        panel.contentView = NSHostingView(rootView: HomeView(home: home, close: { [weak self] in self?.close() },
                                                             openSettings: { [weak self] in self?.close(); openSettings() }))
        if let notch {
            panel.setFrameTopLeftPoint(NSPoint(x: (notch.midX - panel.frame.width / 2).rounded(), y: notch.minY - 10))
        } else {
            panel.center()
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        home.startPolling()
    }

    /// While editing the plan, dragging must move rooms, not the window.
    func setMovable(_ movable: Bool) { panel?.isMovableByWindowBackground = movable }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        SmartHomeController.shared.stopPolling()
    }
}

// MARK: - Content

struct HomeView: View {
    static let size = CGSize(width: 600, height: 440)

    @ObservedObject var home: SmartHomeController
    let close: () -> Void
    let openSettings: () -> Void
    @State var selected: String?
    @State var editing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            if !home.loggedIn {
                placeholder(symbol: "house", title: "Подключи Умный дом Яндекса",
                            detail: "Вход и ClientID — в Настройках → Дом", button: "Открыть настройки", action: openSettings)
            } else if home.snapshot.lamps.isEmpty {
                if home.loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder(symbol: "lightbulb.slash", title: "Ламп не нашлось",
                                detail: "Здесь появятся лампы из приложения «Дом с Алисой»", button: "Обновить") { home.refresh() }
                }
            } else if editing {
                PlanEditor(home: home)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Тяни комнату — переместить, уголок — размер, лампу — на её место. Клетка — 1 м.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                IsoPlanView(home: home, selected: $selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
            }
            if let error = home.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: home.snapshot.lamps.map(\.id)) { _, ids in
            if let s = selected, !ids.contains(s) { selected = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "house.fill").foregroundStyle(.secondary)
            Text("Дом").font(.system(size: 15, weight: .semibold))
            let on = home.snapshot.lamps.filter { $0.isOn == true }.count
            if home.loggedIn && !home.snapshot.lamps.isEmpty {
                Text(on == 0 ? "всё выключено" : "горит \(on) из \(home.snapshot.lamps.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if home.loading { ProgressView().controlSize(.mini) }
            if editing {
                Menu {
                    ForEach(PlanEditor.extraNames, id: \.self) { name in
                        Button(name) { home.editLayout { $0.addExtra(name: name, after: home.plan) } }
                    }
                } label: {
                    Label("Комната", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11, weight: .medium))
                .help("Добавить комнату без ламп: коридор, ванную…")
                if !home.layout.isEmpty {
                    pill("Сбросить") { home.resetLayout() }
                        .help("Вернуть автоматическую раскладку")
                }
                pill("Готово") { setEditing(false) }
            } else if home.loggedIn && !home.snapshot.lamps.isEmpty {
                HomeSpeakerButton()
                IconButton(systemName: "pencil.and.ruler", size: 11) { setEditing(true) }
                    .foregroundStyle(.secondary)
                    .help("Изменить план: размеры комнат и места ламп")
            }
            if on > 0 && !editing {
                pill("Выключить всё") { home.allOff() }
            }
            IconButton(systemName: "xmark", size: 10) { close() }
                .foregroundStyle(.secondary)
                .help("Закрыть (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.1)))
    }

    private func setEditing(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { editing = on }
        selected = nil
        HomeWindow.shared.setMovable(!on)
    }

    @ViewBuilder private var controls: some View {
        if let id = selected, let lamp = home.snapshot.lamps.first(where: { $0.id == id }) {
            LampControls(home: home, lamp: lamp)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.04))
        } else {
            Text("Клик по лампе — вкл/выкл · по названию комнаты — вся комната · правый клик — яркость и цвет")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private func placeholder(symbol: String, title: String, detail: String, button: String,
                             action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(button, action: action).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Isometric plan

/// Rooms as flat slabs with two low back walls, lamps as glowing dots casting light on the floor.
struct IsoPlanView: View {
    @ObservedObject var home: SmartHomeController
    @Binding var selected: String?

    private static let wallHeight = 0.55
    private static let lampHeight = 0.35

    var body: some View {
        GeometryReader { geo in
            let plan = home.plan
            let iso = Iso(plan: plan, in: geo.size, wall: Self.wallHeight)
            let lamps = Dictionary(uniqueKeysWithValues: home.snapshot.lamps.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // Back to front so nearer walls overlap farther floors.
                    for room in plan.rooms.sorted(by: { $0.x + $0.y < $1.x + $1.y }) {
                        drawRoom(room, plan: plan, lamps: lamps, iso: iso, in: &ctx)
                    }
                }
                ForEach(plan.rooms, id: \.id) { room in
                    let p = iso.point(room.x + room.width, room.y + room.depth)
                    Button { home.toggleRoom(room.id) } label: {
                        Text(room.name)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .position(x: p.x, y: p.y + 10)
                    .help("Включить или выключить всю комнату")
                }
                ForEach(plan.lamps, id: \.id) { spot in
                    if let lamp = lamps[spot.id] {
                        LampDot(lamp: lamp, selected: selected == lamp.id,
                                unreachable: home.unreachable.contains(lamp.id),
                                toggle: { home.toggle(lamp.id); selected = lamp.id },
                                select: { selected = selected == lamp.id ? nil : lamp.id })
                            .position(iso.point(spot.x, spot.y, z: Self.lampHeight))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func drawRoom(_ room: HomePlan.Room, plan: HomePlan, lamps: [String: HomeLamp], iso: Iso,
                          in ctx: inout GraphicsContext) {
        let x0 = room.x, y0 = room.y, x1 = room.x + room.width, y1 = room.y + room.depth
        let floor = iso.polygon([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)])
        ctx.fill(floor, with: .color(.white.opacity(0.07)))

        // Light pools: only from lamps that are on, tinted by their color, sized by brightness.
        var lit = ctx
        lit.clip(to: floor)
        lit.blendMode = .plusLighter
        for spot in plan.lamps where spot.x > x0 && spot.x < x1 && spot.y > y0 && spot.y < y1 {
            guard let lamp = lamps[spot.id], lamp.isOn == true else { continue }
            let c = Color(lamp: lamp)
            let level = Double(lamp.brightness ?? 100) / 100
            let r = iso.unit * (0.9 + 1.6 * level)
            let center = iso.point(spot.x, spot.y)
            let rect = CGRect(x: center.x - r, y: center.y - r / 2, width: r * 2, height: r)
            lit.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [c.opacity(0.25 + 0.4 * level), c.opacity(0)]),
                center: center, startRadius: 0, endRadius: r))
        }

        // Two back walls: along the far edges.
        let h = Self.wallHeight
        let back = iso.polygon([(x0, y0, 0), (x1, y0, 0), (x1, y0, h), (x0, y0, h)])
        let side = iso.polygon([(x0, y0, 0), (x0, y1, 0), (x0, y1, h), (x0, y0, h)])
        ctx.fill(back, with: .color(.white.opacity(0.10)))
        ctx.fill(side, with: .color(.white.opacity(0.05)))
        ctx.stroke(floor, with: .color(.white.opacity(0.22)), lineWidth: 1)
        ctx.stroke(back, with: .color(.white.opacity(0.16)), lineWidth: 1)
        ctx.stroke(side, with: .color(.white.opacity(0.16)), lineWidth: 1)
    }
}

/// Isometric projection of plan coordinates, scaled to fit the view.
private struct Iso {
    let unit: CGFloat
    let origin: CGPoint
    private static let cos30 = cos(Double.pi / 6), sin30 = 0.5

    init(plan: HomePlan, in size: CGSize, wall: Double) {
        // Bounding box of the plan's corners in unit space.
        let corners = [(plan.minX, plan.minY), (plan.width, plan.minY), (plan.width, plan.depth), (plan.minX, plan.depth)]
        let xs = corners.map { ($0.0 - $0.1) * Self.cos30 }
        let ys = corners.map { ($0.0 + $0.1) * Self.sin30 }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = (ys.min() ?? 0) - wall, maxY = (ys.max() ?? 1) + 0.4   // room for labels below
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        unit = min(size.width / w, size.height / h, 70)
        origin = CGPoint(x: (size.width - w * unit) / 2 - minX * unit, y: (size.height - h * unit) / 2 - minY * unit)
    }

    func point(_ x: Double, _ y: Double, z: Double = 0) -> CGPoint {
        CGPoint(x: origin.x + (x - y) * Self.cos30 * unit, y: origin.y + ((x + y) * Self.sin30 - z) * unit)
    }

    func polygon(_ pts: [(Double, Double, Double)]) -> Path {
        var p = Path()
        p.addLines(pts.map { point($0.0, $0.1, z: $0.2) })
        p.closeSubpath()
        return p
    }
}

private struct LampDot: View {
    let lamp: HomeLamp
    let selected: Bool
    let unreachable: Bool
    let toggle: () -> Void
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        let on = lamp.isOn == true
        let c = Color(lamp: lamp)
        ZStack {
            if on {
                Circle().fill(c.opacity(0.35)).frame(width: 34, height: 34).blur(radius: 8)
            }
            Circle()
                .fill(on ? c : Color.white.opacity(0.12))
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0.3), lineWidth: selected ? 2 : 1))
                .frame(width: 16, height: 16)
            if unreachable {
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.orange)
            }
        }
        .frame(width: 36, height: 36)
        .scaleEffect(hover ? 1.15 : 1)
        .contentShape(Circle())
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.4)) { hover = h } }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button(on ? "Выключить" : "Включить", action: toggle)
            Button("Яркость и цвет…", action: select)
        }
        .help("\(lamp.name) — \(on ? "горит" : "выключена")\(lamp.brightness.map { on ? ", \($0) %" : "" } ?? "")")
        .accessibilityLabel(lamp.name)
        .accessibilityValue(on ? "горит" : "выключена")
        .accessibilityAddTraits(.isButton)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

// MARK: - Controls for the selected lamp

private struct LampControls: View {
    @ObservedObject var home: SmartHomeController
    let lamp: HomeLamp

    private static let hues: [Int] = [0, 30, 55, 120, 190, 230, 280, 320]

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { lamp.isOn == true }, set: { home.apply([(lamp.id, .power($0))]) })) {
                Text(lamp.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 150, alignment: .leading)

            if lamp.canDim {
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(lamp.brightness ?? 100) },
                                          set: { home.set(.brightness(Int($0.rounded())), for: lamp.id) }), in: 1...100)
                        .controlSize(.mini)
                        .frame(width: 110)
                }
                .help("Яркость \(lamp.brightness ?? 100) %")
            }
            if let range = lamp.temperatureRange {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.sun").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(temperature ?? (range.lowerBound + range.upperBound) / 2) },
                                          set: { home.set(.temperature(Int($0.rounded())), for: lamp.id) }),
                           in: Double(range.lowerBound)...Double(range.upperBound))
                        .controlSize(.mini)
                        .frame(width: 90)
                }
                .help("Теплее ← → холоднее")
            }
            if lamp.colorModel != nil {
                HStack(spacing: 4) {
                    ForEach(Self.hues, id: \.self) { h in
                        Circle()
                            .fill(Color(hue: Double(h) / 360, saturation: 0.85, brightness: 1))
                            .frame(width: 13, height: 13)
                            .onTapGesture { home.apply([(lamp.id, .hsv(h: h, s: 100, v: lamp.brightness ?? 100))]) }
                            .accessibilityLabel("Цвет \(h)°")
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var temperature: Int? {
        if case .temperature(let k) = lamp.color { return k }
        return nil
    }
}

extension Color {
    init(lamp: HomeLamp) {
        let c = (lamp.color ?? .temperature(3400)).rgbComponents
        self.init(red: c.r, green: c.g, blue: c.b)
    }
}

/// Snapshots: the panel with a lamp's controls open.
struct HomeViewSelected: View {
    let home: SmartHomeController
    var body: some View { HomeView(home: home, close: {}, openSettings: {}, selected: "1") }
}

// MARK: - Plan editor (top-down, metres)

struct PlanEditor: View {
    @ObservedObject var home: SmartHomeController
    /// Live positions while dragging; committed to the layout when the drag ends.
    @State private var roomPreview: [String: HomeLayout.Rect] = [:]
    @State private var lampPreview: [String: HomeLayout.Point] = [:]

    static let extraNames = ["Коридор", "Прихожая", "Ванная", "Туалет", "Балкон", "Кладовка", "Гардероб", "Комната"]

    var body: some View {
        GeometryReader { geo in
            let plan = home.plan
            // Some free metres around the flat to drag things into.
            let spanX = max(plan.width + 2, 10), spanY = max(plan.depth + 2, 6)
            let m = min(geo.size.width / spanX, geo.size.height / spanY)
            let names = Dictionary(uniqueKeysWithValues: home.snapshot.lamps.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for i in 0...Int(spanX) {
                        let x = CGFloat(i) * m
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(.white.opacity(i % 5 == 0 ? 0.12 : 0.05)), lineWidth: 1)
                    }
                    for j in 0...Int(spanY) {
                        let y = CGFloat(j) * m
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(.white.opacity(j % 5 == 0 ? 0.12 : 0.05)), lineWidth: 1)
                    }
                }
                ForEach(plan.rooms, id: \.id) { room in
                    roomView(room, m: m)
                }
                ForEach(plan.lamps, id: \.id) { spot in
                    let p = lampPreview[spot.id] ?? HomeLayout.Point(x: spot.x, y: spot.y)
                    let lamp = names[spot.id]
                    Circle()
                        .fill(lamp.map { $0.isOn == true ? Color(lamp: $0) : .white.opacity(0.35) } ?? .gray)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .overlay(alignment: .top) {
                            Text(lamp?.name ?? "").font(.system(size: 9)).foregroundStyle(.secondary)
                                .fixedSize().offset(y: 26)
                        }
                        .position(x: p.x * m, y: p.y * m)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                lampPreview[spot.id] = HomeLayout.Point(
                                    x: max(0, HomeLayout.snap(spot.x + g.translation.width / m, step: 0.25)),
                                    y: max(0, HomeLayout.snap(spot.y + g.translation.height / m, step: 0.25)))
                            }
                            .onEnded { _ in
                                if let p = lampPreview.removeValue(forKey: spot.id) { home.editLayout { $0.setLamp(p, for: spot.id) } }
                            })
                        .help(lamp?.name ?? "")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func roomView(_ room: HomePlan.Room, m: CGFloat) -> some View {
        let r = roomPreview[room.id] ?? HomeLayout.Rect(x: room.x, y: room.y, width: room.width, depth: room.depth)
        let base = HomeLayout.Rect(x: room.x, y: room.y, width: room.width, depth: room.depth)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white.opacity(room.isExtra ? 0.05 : 0.09))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.45), lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(room.name).font(.system(size: 10.5, weight: .medium))
                    Text("\(Self.metres(r.width)) × \(Self.metres(r.depth)) м").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                // Resize handle.
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.18)))
                    .contentShape(Rectangle())
                    .padding(2)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            var n = base
                            n.width = max(HomeLayout.minSize, HomeLayout.snap(base.width + g.translation.width / m))
                            n.depth = max(HomeLayout.minSize, HomeLayout.snap(base.depth + g.translation.height / m))
                            roomPreview[room.id] = n
                        }
                        .onEnded { _ in commit(room.id) })
                    .help("Потяни, чтобы изменить размер")
            }
            .frame(width: r.width * m, height: r.depth * m)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    var n = base
                    n.x = max(0, HomeLayout.snap(base.x + g.translation.width / m))
                    n.y = max(0, HomeLayout.snap(base.y + g.translation.height / m))
                    roomPreview[room.id] = n
                }
                .onEnded { _ in commit(room.id) })
            .contextMenu {
                if room.isExtra {
                    Menu("Переименовать") {
                        ForEach(Self.extraNames, id: \.self) { name in
                            Button(name) { home.editLayout { $0.renameExtra(room.id, to: name) } }
                        }
                    }
                    Button("Удалить комнату") { home.editLayout { $0.removeExtra(room.id) } }
                } else {
                    Text("Название комнаты — из «Дома с Алисой»")
                }
            }
            .position(x: (r.x + r.width / 2) * m, y: (r.y + r.depth / 2) * m)
    }

    private func commit(_ roomID: String) {
        guard let r = roomPreview.removeValue(forKey: roomID) else { return }
        home.editLayout { $0.setRect(r, for: roomID) }
    }

    static func metres(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }
}

/// Snapshots: the plan editor.
struct HomeViewEditing: View {
    let home: SmartHomeController
    var body: some View { HomeView(home: home, close: {}, openSettings: {}, editing: true) }
}

/// Same as the island's speaker button; the panel has no island model, so it calls SpeakerLink directly.
private struct HomeSpeakerButton: View {
    @ObservedObject private var link = SpeakerLink.shared

    var body: some View {
        if link.isAvailable {
            let active = link.isActive
            if link.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                IconButton(systemName: active ? "hifispeaker.fill" : "hifispeaker", size: 11) { link.toggle() }
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .help(active ? "Вернуть звук на Mac" : "Звук на Станцию по Bluetooth")
            }
        }
    }
}
