import AppKit
import QuickLookThumbnailing
import SwiftUI

/// What plays at the right edge of the screen while a file flies in.
enum PortalEffect: String, CaseIterable, Identifiable {
    /// The pet's icosahedron as a gate: faces light up with progress, shards fly in, it bursts on arrival.
    case pet
    /// Bands of light bulging out of the edge, colours flowing through them.
    case rainbow
    /// A half-open ring with sparks spiralling into it.
    case vortex
    /// Rings rolling out of the edge like waves.
    case ripple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pet: return "Пет"
        case .rainbow: return "Радуга"
        case .vortex: return "Портал"
        case .ripple: return "Волны"
        }
    }

    static var current: PortalEffect { PortalEffect(rawValue: AppSettings.shared.portalEffect) ?? .pet }
}

@MainActor
final class PortalEffectState: ObservableObject {
    enum Phase { case hidden, receiving, arrived, failed }

    @Published var phase = Phase.hidden
    @Published var progress: Double = 0
    @Published var effect = PortalEffect.pet
    @Published var thumbnail: NSImage?
    var startedAt = Date()
    var phaseAt = Date()
}

/// Shows the edge panel for incoming transfers. Several transfers at once share one effect and its
/// progress is their average; the arrival plays when the last one lands.
@MainActor
final class PortalEffectController {
    static let shared = PortalEffectController()

    let state = PortalEffectState()
    private var panel: NSPanel?
    private var transfers: [String: Double] = [:]
    private var hideWork: DispatchWorkItem?
    private var previewTimer: Timer?

    func begin(id: String, name: String) {
        transfers[id] = 0
        hideWork?.cancel()
        if state.phase != .receiving {
            state.effect = .current
            state.thumbnail = nil
            state.progress = 0
            state.startedAt = Date()
            state.phase = .receiving
            show()
            haptic(.alignment)
        }
        recalc()
    }

    func update(id: String, fraction: Double) {
        guard transfers[id] != nil else { return }
        transfers[id] = min(max(fraction, 0), 1)
        recalc()
    }

    func finish(id: String, file: URL?) {
        transfers.removeValue(forKey: id)
        guard transfers.isEmpty else { return recalc() }
        if state.phase == .hidden || state.phase == .failed {
            // A file so small its start and end came together: still give it its moment.
            state.effect = .current
            state.startedAt = Date().addingTimeInterval(-0.45)
            show()
        }
        state.progress = 1
        state.phase = .arrived
        state.phaseAt = Date()
        haptic(.levelChange)
        if let file {
            FileThumbnails.load(file, side: 240) { [weak self] image in
                guard self?.state.phase == .arrived else { return }
                self?.state.thumbnail = image
            }
        }
        scheduleHide(after: 2.3)
    }

    func fail(id: String) {
        transfers.removeValue(forKey: id)
        guard transfers.isEmpty else { return recalc() }
        guard state.phase == .receiving else { return }
        state.phase = .failed
        state.phaseAt = Date()
        haptic(.generic)
        scheduleHide(after: 0.9)
    }

    /// Settings → «Показать»: a pretend two-second transfer.
    func preview() {
        previewTimer?.invalidate()
        let id = "preview"
        begin(id: id, name: "")
        let start = Date()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let p = Date().timeIntervalSince(start) / 2
                if p >= 1 {
                    timer.invalidate()
                    self?.finish(id: id, file: Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
                } else {
                    self?.update(id: id, fraction: p)
                }
            }
        }
    }

    private func recalc() {
        guard !transfers.isEmpty else { return }
        state.progress = transfers.values.reduce(0, +) / Double(transfers.count)
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transfers.isEmpty else { return }
                self.state.phase = .hidden
                self.state.thumbnail = nil
                self.panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show() {
        let screen = PetPanelController.shared.placement()?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let width: CGFloat = 340
        let height = min(680, screen.frame.height * 0.8)
        let frame = NSRect(x: screen.frame.maxX - width, y: screen.frame.midY - height / 2, width: width, height: height)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.ignoresMouseEvents = true
            p.contentView = NSHostingView(rootView: PortalEffectView(state: state))
            panel = p
        }
        panel?.setFrame(frame, display: false)
        panel?.orderFrontRegardless()
    }
}

// MARK: - Drawing

struct PortalEffectView: View {
    @ObservedObject var state: PortalEffectState

    var body: some View {
        if state.phase == .hidden {
            Color.clear
        } else {
            // Redraws every frame only while the panel is up.
            TimelineView(.animation) { ctx in
                let frame = PortalFrame(state: state, now: ctx.date)
                ZStack {
                    Canvas { gc, size in frame.draw(in: &gc, size: size) }
                        .colorMultiply(state.phase == .failed && state.effect != .pet ? Color(red: 1, green: 0.45, blue: 0.45) : .white)
                    GeometryReader { geo in
                        if let image = state.thumbnail { frame.arrivalCard(image, size: geo.size) }
                    }
                }
            }
        }
    }
}

/// One frame of the effect: everything derives from time since the start and since the last phase change.
struct PortalFrame {
    let effect: PortalEffect
    let progress: Double
    let t: Double
    /// 0…1: fades in at the start, out after arrival or failure.
    let intensity: Double
    /// Bump on arrival (1 = none).
    let boost: Double
    let sinceArrival: Double?
    /// Seconds since the transfer failed.
    var sinceFailure: Double? = nil
    let calm: Bool

    @MainActor init(state: PortalEffectState, now: Date) {
        effect = state.effect
        progress = state.progress
        calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let raw = now.timeIntervalSince(state.startedAt)
        t = calm ? raw * 0.3 : raw
        let appear = smoothstep(0, 0.45, raw)
        let since = now.timeIntervalSince(state.phaseAt)
        switch state.phase {
        case .arrived:
            sinceArrival = since
            intensity = appear * (1 - smoothstep(1.4, 2.2, since))
            boost = calm ? 1 : 1 + 0.45 * sin(min(since / 0.6, 1) * .pi)
        case .failed:
            sinceArrival = nil
            sinceFailure = since
            intensity = appear * (1 - smoothstep(0, 0.8, since))
            boost = 1
        default:
            sinceArrival = nil
            intensity = appear
            boost = 1
        }
    }

    func draw(in gc: inout GraphicsContext, size: CGSize) {
        guard intensity > 0.001 else { return }
        gc.blendMode = .plusLighter
        switch effect {
        case .pet: petGate(&gc, size)
        case .rainbow: rainbow(&gc, size)
        case .vortex: vortex(&gc, size)
        case .ripple: ripple(&gc, size)
        }
    }

    // MARK: Pet gate

    /// Same palette as the pet (IcosaPet): ice blue at rest, cyan while working, mint on arrival, red glitch on failure.
    private static let ice = (0.56, 0.83, 1.0)
    private static let cyan = (0.18, 0.90, 1.0)
    private static let mint = (0.30, 1.0, 0.65)
    private static let alarm = (1.0, 0.25, 0.35)

    private static let icosa: (v: [SIMD3<Double>], f: [(Int, Int, Int)]) = {
        let g = (1 + 5.0.squareRoot()) / 2
        let raw: [SIMD3<Double>] = [
            [-1, g, 0], [1, g, 0], [-1, -g, 0], [1, -g, 0], [0, -1, g], [0, 1, g],
            [0, -1, -g], [0, 1, -g], [g, 0, -1], [g, 0, 1], [-g, 0, -1], [-g, 0, 1]]
        let n = (1 + g * g).squareRoot()
        let faces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
                     (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
                     (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        return (raw.map { $0 / n }, faces)
    }()

    private func petGate(_ gc: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, cy = size.height / 2
        let failed = sinceFailure != nil
        let arrive = sinceArrival.map { smoothstep(0, 0.7, $0) } ?? 0
        // Colour: ice → cyan as data flows → mint flash on arrival → red when it fails.
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ k: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k)
        }
        var rgb = mix(Self.ice, Self.cyan, smoothstep(0.02, 0.3, progress))
        if let s = sinceArrival { rgb = mix(rgb, Self.mint, 1 - smoothstep(0.5, 1.4, s)) }
        if failed { rgb = Self.alarm }
        func col(_ a: Double) -> Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2).opacity(max(0, min(1, a)) * intensity) }

        // Glitch on failure: the whole gate jumps sideways in quantised steps.
        var jx: CGFloat = 0
        if let f = sinceFailure, !calm {
            let q = floor(f / 0.05)
            jx = CGFloat(fract(sin(q * 91.7) * 4375.5) - 0.5) * 16 * CGFloat(1 - smoothstep(0.2, 0.7, f))
        }
        let r = 150 * smoothstep(0, 0.55, t) * (1 + 0.025 * sin(t * 2.2)) * boost * (failed ? 0.92 : 1)
        let center = CGPoint(x: w - 8 + jx, y: cy)
        let spin = t * (0.35 + 0.5 * progress)
        let (cA, sA) = (cos(spin), sin(spin)), (cB, sB) = (cos(0.5 + t * 0.21), sin(0.5 + t * 0.21))
        func rot(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let x = p.x * cA + p.z * sA, z = -p.x * sA + p.z * cA
            return SIMD3(x, p.y * cB - z * sB, p.y * sB + z * cB)
        }
        func proj(_ p: SIMD3<Double>) -> CGPoint {
            let k = 3.2 / (3.2 - p.z)
            return CGPoint(x: center.x + CGFloat(p.x * k) * r, y: center.y - CGFloat(p.y * k) * r)
        }

        // Soft core.
        let core = r * 0.55
        gc.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: 2 * core, height: 2 * core)),
                with: .radialGradient(Gradient(colors: [col(0.28 + 0.25 * progress), .clear]),
                                      center: center, startRadius: 0, endRadius: core))

        // Faces: burst outward on arrival; light up one by one with progress.
        let verts = Self.icosa.v.map(rot)
        let lit = (sinceArrival != nil ? 20 : progress * 20)
        struct Tri { var p: [CGPoint]; var z: Double; var front: Bool; var glow: Double }
        var tris: [Tri] = []
        for (i, f) in Self.icosa.f.enumerated() {
            var a = verts[f.0], b = verts[f.1], c = verts[f.2]
            let n = (a + b + c) / 3
            let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            if arrive > 0 {
                // Each face flies off along its normal and shrinks to a shard.
                let push = n / len * (0.55 + 0.15 * Double(i % 3)) * arrive
                let keep = 1 - 0.75 * arrive
                a = n + push + (a - n) * keep; b = n + push + (b - n) * keep; c = n + push + (c - n) * keep
            }
            let glow = min(max(lit - Double(i), 0), 1)
            tris.append(Tri(p: [proj(a), proj(b), proj(c)], z: n.z, front: n.z > -0.05, glow: glow))
        }
        let fadeOut = 1 - arrive
        let ordered = tris.sorted(by: { $0.z < $1.z }).map { tri -> (Path, Tri, Double) in
            var path = Path(); path.addLines(tri.p); path.closeSubpath()
            return (path, tri, (tri.front ? 0.85 : 0.22) * (0.35 + 0.65 * (tri.z + 1) / 2) * fadeOut)
        }
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            for (path, _, a) in ordered {
                layer.stroke(path, with: .color(col(a * 0.6)), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
            }
        }
        for (path, tri, a) in ordered {
            if tri.glow > 0 {
                gc.fill(path, with: .color(col((0.10 + 0.22 * tri.glow) * (0.35 + 0.65 * (tri.z + 1) / 2) * fadeOut)))
            }
            gc.stroke(path, with: .color(col(a)), style: StrokeStyle(lineWidth: tri.front ? 1.3 : 0.8, lineJoin: .round))
        }
        if arrive < 1 {
            for v in verts where v.z > -0.2 {
                let p = proj(v), d = 1.6 + 1.2 * (v.z + 1) / 2
                gc.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)),
                        with: .color(Color.white.opacity(0.85 * (1 - arrive) * intensity)))
            }
        }

        // Shards: small triangles drifting in from the screen toward the gate while receiving.
        guard !calm, sinceArrival == nil, !failed else { return }
        let count = 18 + Int(26 * progress)
        for k in 0..<count {
            let s = seed(k), life = 1.3 + s.1
            let ph = fract(t / life + s.0)
            let start = CGPoint(x: w - 140 - CGFloat(s.1) * 180, y: cy + CGFloat(s.2 - 0.5) * 520)
            let e = ph * ph
            let p = CGPoint(x: start.x + (center.x - start.x) * CGFloat(e), y: start.y + (center.y - start.y) * CGFloat(e))
            let sz = CGFloat(2.5 + 3 * s.2) * CGFloat(1 - 0.6 * ph)
            let ang = s.0 * 6.28 + t * (1.5 + 2 * s.1)
            var shard = Path()
            for j in 0..<3 {
                let a2 = ang + Double(j) * 2.094
                let q = CGPoint(x: p.x + CGFloat(cos(a2)) * sz, y: p.y + CGFloat(sin(a2)) * sz)
                if j == 0 { shard.move(to: q) } else { shard.addLine(to: q) }
            }
            shard.closeSubpath()
            gc.stroke(shard, with: .color(col(sin(ph * .pi) * 0.9)), lineWidth: 0.9)
        }
    }

    // MARK: Rainbow

    private func rainbow(_ gc: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, cy = size.height / 2
        let length = size.height * (0.3 + 0.6 * progress) * smoothstep(0, 0.6, t)
        let bands = 7
        func band(_ i: Int) -> Path {
            let spread = CGFloat(i) * 7
            let bulge = (26 + CGFloat(i) * 9) * CGFloat(boost)
            var p = Path()
            p.move(to: CGPoint(x: w + 4, y: cy - length / 2 - spread))
            p.addQuadCurve(to: CGPoint(x: w + 4, y: cy + length / 2 + spread), control: CGPoint(x: w - bulge * 2, y: cy))
            return p
        }
        func color(_ i: Int, _ alpha: Double) -> Color {
            Color(hue: fract(Double(i) / Double(bands) + t * 0.12), saturation: 0.8, brightness: 1).opacity(alpha * intensity)
        }
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 10))
            for i in 0..<bands { layer.stroke(band(i), with: .color(color(i, 0.75)), lineWidth: 9) }
        }
        for i in 0..<bands { gc.stroke(band(i), with: .color(color(i, 0.9)), lineWidth: 1.6) }
        guard !calm else { return }
        // Specks of light drifting out of the bands.
        for k in 0..<46 {
            let s = seed(k), life = 1.4 + s.2
            let ph = fract(t / life + s.0)
            let x = w - CGFloat(ph) * (50 + 170 * CGFloat(s.1))
            let y = cy + CGFloat(s.2 - 0.5) * length * 1.1
            let r = 1.2 + 2 * CGFloat(1 - ph)
            let c = Color(hue: fract(s.0 + t * 0.1), saturation: 0.6, brightness: 1)
            gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                    with: .color(c.opacity((1 - ph) * intensity)))
        }
    }

    // MARK: Vortex

    private func vortex(_ gc: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, cy = size.height / 2
        let grow = smoothstep(0, 0.5, t) * (0.8 + 0.2 * progress) * boost
        let rx = 110 * grow, ry = 200 * grow
        let center = CGPoint(x: w, y: cy)
        let oval = Path(ellipseIn: CGRect(x: w - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
        gc.fill(oval, with: .radialGradient(Gradient(colors: [
            Color(red: 0.55, green: 0.3, blue: 1).opacity(0.75 * intensity),
            Color(red: 0.15, green: 0.1, blue: 0.6).opacity(0.35 * intensity), .clear]),
            center: center, startRadius: 0, endRadius: ry))
        let ring = GraphicsContext.Shading.conicGradient(
            Gradient(colors: [.cyan, Color(red: 0.6, green: 0.3, blue: 1), Color(red: 1, green: 0.35, blue: 0.8), .cyan]),
            center: center, angle: .radians(t * 2.2))
        gc.drawLayer { layer in
            layer.opacity = intensity
            layer.addFilter(.blur(radius: 12))
            layer.stroke(oval, with: ring, lineWidth: 14)
        }
        var sharp = gc
        sharp.opacity = intensity
        sharp.stroke(oval, with: ring, lineWidth: 2.5)
        if !calm {
            // Sparks spiralling in.
            for k in 0..<130 {
                let s = seed(k), life = 1.6 + s.1
                let ph = fract(t / life + s.0)
                let r = 1.3 - ph
                let angle = s.0 * 2 * .pi + t * (1.2 + s.2) + ph * 3.2
                let x = w + CGFloat(cos(angle) * r) * rx, y = cy + CGFloat(sin(angle) * r) * ry
                guard x < w - 1 else { continue }
                let size = 1 + 2.2 * CGFloat(1 - ph)
                let c = s.2 > 0.5 ? Color.cyan : Color(red: 1, green: 0.5, blue: 0.9)
                gc.fill(Path(ellipseIn: CGRect(x: x - size, y: y - size, width: 2 * size, height: 2 * size)),
                        with: .color(c.opacity(sin(ph * .pi) * intensity)))
            }
        }
        progressArc(&gc, center: center, rx: rx * 1.14, ry: ry * 1.08)
    }

    // MARK: Ripple

    private func ripple(_ gc: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, cy = size.height / 2
        let center = CGPoint(x: w, y: cy)
        let reach = 250 * smoothstep(0, 0.5, t) * boost
        let speed = 0.5 + 0.6 * progress
        func ring(_ k: Int) -> (Path, Double) {
            let ph = fract(t * speed + Double(k) / 5)
            let r = 24 + CGFloat(ph) * reach
            return (Path(ellipseIn: CGRect(x: w - r * 0.8, y: cy - r, width: 1.6 * r, height: 2 * r)), ph)
        }
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 8))
            for k in 0..<5 {
                let (p, ph) = ring(k)
                layer.stroke(p, with: .color(Color(hue: 0.48 + 0.14 * ph, saturation: 0.95, brightness: 1)
                    .opacity((1 - ph) * intensity)), lineWidth: 10 * CGFloat(1 - ph) + 2)
            }
        }
        for k in 0..<5 {
            let (p, ph) = ring(k)
            gc.stroke(p, with: .color(.white.opacity(0.7 * (1 - ph) * intensity)), lineWidth: 1.2)
        }
        let pulse = 46 + 10 * CGFloat(sin(t * 3))
        gc.fill(Path(ellipseIn: CGRect(x: w - pulse, y: cy - pulse * 1.4, width: 2 * pulse, height: 2.8 * pulse)),
                with: .radialGradient(Gradient(colors: [Color(red: 0.2, green: 0.9, blue: 1).opacity(0.9 * intensity), .clear]),
                                      center: center, startRadius: 0, endRadius: pulse * 1.4))
        progressArc(&gc, center: center, rx: 58, ry: 80)
    }

    /// Bright line around the visible half from the top down, as far as the transfer has got.
    private func progressArc(_ gc: inout GraphicsContext, center: CGPoint, rx: CGFloat, ry: CGFloat) {
        guard progress > 0.005, sinceArrival == nil else { return }
        var path = Path()
        let steps = 48
        for i in 0...steps {
            let theta = .pi / 2 + .pi * progress * Double(i) / Double(steps)
            let p = CGPoint(x: center.x + CGFloat(cos(theta)) * rx, y: center.y - CGFloat(sin(theta)) * ry)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        gc.stroke(path, with: .color(.white.opacity(0.9 * intensity)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    // MARK: Arrival

    /// The received file's thumbnail slides out of the edge and settles beside it.
    func arrivalCard(_ image: NSImage, size: CGSize) -> some View {
        let since = sinceArrival ?? 0
        let move = easeOutBack(min(since / 0.55, 1))
        let fade = 1 - smoothstep(1.4, 2.1, since)
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let side: CGFloat = 132
        let card = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        let x = size.width + 90 - CGFloat(move) * 250
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(effect == .pet ? Color(red: 0.56, green: 0.83, blue: 1).opacity(0.55) : .white.opacity(0.8),
                        lineWidth: effect == .pet ? 1 : 1.5))
            .shadow(color: effect == .pet ? Color(red: 0.3, green: 0.8, blue: 1).opacity(0.35) : .black.opacity(0.35),
                    radius: 14, y: effect == .pet ? 0 : 6)
            .scaleEffect(0.55 + 0.45 * move)
            .rotationEffect(.degrees(-10 * (1 - move)))
            .opacity(fade)
            .position(x: x, y: size.height / 2)
    }

    // MARK: Helpers

    /// Three stable pseudo-random numbers in 0…1 for particle `k`.
    private func seed(_ k: Int) -> (Double, Double, Double) {
        func h(_ n: Double) -> Double { fract(sin(n) * 43758.5453) }
        let n = Double(k)
        return (h(n * 12.9898 + 1), h(n * 78.233 + 2), h(n * 39.425 + 3))
    }
}

private func fract(_ x: Double) -> Double { x - floor(x) }

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

private func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.4, c3 = c1 + 1
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
}

// MARK: - Thumbnails

enum FileThumbnails {
    /// QuickLook thumbnail (photo, video frame, PDF page…), or the file's icon.
    @MainActor static func load(_ url: URL, side: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(image ?? NSWorkspace.shared.icon(forFile: url.path)) }
            }
        }
    }
}

/// Small thumbnail for the island (loads once per file).
struct FileThumbnailView: View {
    let url: URL
    var side: CGFloat = 20
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: url) { FileThumbnails.load(url, side: side * 2) { image = $0 } }
    }
}

// MARK: - Offline capture (checks the look without a real transfer)

extension PortalFrame {
    init(effect: PortalEffect, progress: Double, t: Double, sinceArrival: Double?) {
        self.effect = effect
        self.progress = progress
        self.t = t
        self.calm = false
        self.sinceArrival = sinceArrival
        let appear = smoothstep(0, 0.45, t)
        if let since = sinceArrival {
            intensity = appear * (1 - smoothstep(1.4, 2.2, since))
            boost = 1 + 0.45 * sin(min(since / 0.6, 1) * .pi)
        } else {
            intensity = appear
            boost = 1
        }
    }
}

/// `NotchIsland --capture-portal <dir>`: one PNG per effect with frames at 0.3 s, 40 %, 90 % and arrival.
enum PortalCapture {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-portal"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let thumb = NSWorkspace.shared.icon(forFile: "/System/Applications/Photos.app")
        let steps: [(Double, Double, Double?)] = [(0.3, 0.05, nil), (1.2, 0.4, nil), (2.4, 0.9, nil), (3, 1, 0.35), (3.6, 1, 1.0)]
        for effect in PortalEffect.allCases {
            let sheet = HStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                    let frame = PortalFrame(effect: effect, progress: s.1, t: s.0, sinceArrival: s.2)
                    ZStack {
                        Canvas { gc, size in frame.draw(in: &gc, size: size) }
                        if s.2 != nil { GeometryReader { geo in frame.arrivalCard(thumb, size: geo.size) } }
                    }
                    .frame(width: 340, height: 600)
                    .background(Color(white: 0.16))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.15)))
                }
            }
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("portal-\(effect.rawValue).png"))
        }
        exit(0)
    }
}
