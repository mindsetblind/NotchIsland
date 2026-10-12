import SwiftUI

enum MascotMood: Equatable {
    case idle        // calm, blinks now and then
    case working     // eyes dart left and right
    case attention   // wide eyes, small hop — needs you
    case happy       // ^ ^ eyes, a little jump
    case sleeping    // closed eyes, slow breathing
    case dancing     // music is playing: the eyes bounce like equalizer bars
}

/// Minimal face: two pill eyes, no mouth (style "A"). `size` is the face height in points.
/// Animations are short SwiftUI loops that only run while the face is on screen.
struct MascotFace: View {
    let mood: MascotMood
    var size: CGFloat = 18
    /// -1…1: where the cursor is (left/right of the face). Overrides the idle glances while set.
    var gaze: CGFloat? = nil

    @State private var blink = false
    @State private var look: CGFloat = 0        // -1…1, horizontal glance
    @State private var hop: CGFloat = 0         // vertical bounce
    @State private var breathe = false
    @State private var tilt: Double = 0         // degrees
    @State private var bars: [CGFloat] = [1, 1] // per-eye height while dancing (equalizer)

    private var eyeW: CGFloat { size * 0.30 }
    private var eyeH: CGFloat { size * 0.68 }
    private var gap: CGFloat { size * 0.36 }

    var body: some View {
        HStack(spacing: gap) {
            eye(0)
            eye(1)
        }
        .offset(x: (gaze ?? look) * size * 0.16, y: hop)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: gaze)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .scaleEffect(y: mood == .sleeping && breathe ? 0.92 : 1, anchor: .bottom)
        .frame(width: size * 1.6, height: size)
        .task(id: mood) { await animate() }
    }

    @ViewBuilder private func eye(_ index: Int) -> some View {
        switch mood {
        case .happy:
            HappyArc()
                .stroke(.white, style: StrokeStyle(lineWidth: eyeW * 0.75, lineCap: .round))
                .frame(width: eyeW * 1.5, height: eyeH * 0.42)
        case .sleeping:
            Capsule().fill(.white).frame(width: eyeW * 1.3, height: eyeW * 0.45)
        default:
            Capsule()
                .fill(.white)
                .frame(width: mood == .attention ? eyeW * 1.15 : eyeW,
                       height: (mood == .attention ? eyeH * 1.18 : eyeH) * (blink ? 0.12 : 1)
                           * (mood == .dancing ? bars[index] : 1))
        }
    }

    // MARK: Animation loops (cancelled automatically when the mood changes or the view disappears)

    private func animate() async {
        withAnimation(.easeOut(duration: 0.2)) { look = 0; hop = 0; blink = false; tilt = 0; bars = [1, 1] }
        switch mood {
        case .dancing:
            // Eyes bounce like equalizer bars, each to its own beat.
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.18)) {
                    bars = [CGFloat.random(in: 0.45...1.08), CGFloat.random(in: 0.45...1.08)]
                }
                await sleep(0.18)
            }
        case .idle:
            while !Task.isCancelled {
                await sleep(Double.random(in: 2.2...4.5))
                await blinkOnce()
                if Bool.random() {   // occasional quick glance
                    withAnimation(.easeInOut(duration: 0.25)) { look = Bool.random() ? 1 : -1 }
                    await sleep(0.9)
                    withAnimation(.easeInOut(duration: 0.25)) { look = 0 }
                }
            }
        case .working:
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.45)) { look = 1 }
                await sleep(0.75)
                withAnimation(.easeInOut(duration: 0.45)) { look = -1 }
                await sleep(0.75)
                if Int.random(in: 0..<3) == 0 { await blinkOnce() }
            }
        case .attention:
            while !Task.isCancelled {
                withAnimation(.spring(duration: 0.25, bounce: 0.6)) { hop = -size * 0.12 }
                await sleep(0.18)
                withAnimation(.spring(duration: 0.35, bounce: 0.5)) { hop = 0 }
                await sleep(1.3)
            }
        case .happy:
            withAnimation(.spring(duration: 0.3, bounce: 0.6)) { hop = -size * 0.18 }
            await sleep(0.22)
            withAnimation(.spring(duration: 0.45, bounce: 0.55)) { hop = 0 }
        case .sleeping:
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.6)) { breathe.toggle() }
                await sleep(1.6)
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeIn(duration: 0.07)) { blink = true }
        await sleep(0.11)
        withAnimation(.easeOut(duration: 0.1)) { blink = false }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// "^" shape for closed happy eyes.
struct HappyArc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        return p
    }
}
