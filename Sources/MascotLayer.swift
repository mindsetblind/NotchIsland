import AppKit
import QuartzCore
import SwiftUI

/// The always-visible mascot, animated by Core Animation: the system render server runs the loops,
/// so the app does no per-frame work (the SwiftUI face cost ~14% CPU while an agent was working).
/// Snapshot mode falls back to the SwiftUI `MascotFace`, which ImageRenderer can draw.
struct MascotView: View {
    let mood: MascotMood
    var size: CGFloat = 17
    var gaze: CGFloat? = nil

    var body: some View {
        if Snapshots.active {
            MascotFace(mood: mood, size: size, gaze: gaze)
        } else {
            MascotLayerView(mood: mood, size: size, gaze: gaze)
                .frame(width: size * 1.6, height: size * 1.3)
        }
    }
}

private struct MascotLayerView: NSViewRepresentable {
    let mood: MascotMood
    let size: CGFloat
    let gaze: CGFloat?

    func makeNSView(context: Context) -> MascotNSView { MascotNSView(size: size) }

    func updateNSView(_ view: MascotNSView, context: Context) {
        view.update(mood: mood, gaze: gaze ?? 0)
    }
}

final class MascotNSView: NSView {
    private let size: CGFloat
    // root ← gaze offset; look ← idle/working glances; body ← hop / tilt / breathing
    private let gazeLayer = CALayer()
    private let lookLayer = CALayer()
    private let bodyLayer = CALayer()
    private let eyes = [CALayer(), CALayer()]
    private let arcs = [CAShapeLayer(), CAShapeLayer()]
    private var mood: MascotMood?
    private var gaze: CGFloat = .nan
    private var laidOutSize: CGSize = .zero

    private var eyeW: CGFloat { size * 0.30 }
    private var eyeH: CGFloat { size * 0.68 }
    private var gap: CGFloat { size * 0.36 }

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(gazeLayer)
        gazeLayer.addSublayer(lookLayer)
        lookLayer.addSublayer(bodyLayer)
        for eye in eyes {
            eye.backgroundColor = NSColor.white.cgColor
            bodyLayer.addSublayer(eye)
        }
        for arc in arcs {
            arc.strokeColor = NSColor.white.cgColor
            arc.fillColor = nil
            arc.lineCap = .round
            arc.lineWidth = eyeW * 0.75
            bodyLayer.addSublayer(arc)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Layout passes happen for many reasons; only a real size change needs a rebuild
        // (otherwise every pass would restart the animations — a visible hiccup).
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [gazeLayer, lookLayer] { l.frame = bounds }
        // Tilt and breathing pivot on the bottom of the face.
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        bodyLayer.bounds = bounds
        bodyLayer.position = CGPoint(x: bounds.midX, y: 0)
        CATransaction.commit()
        if let mood { configure(mood) }
    }

    func update(mood: MascotMood, gaze: CGFloat) {
        if gaze != self.gaze {
            self.gaze = gaze
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            gazeLayer.transform = CATransform3DMakeTranslation(gaze * size * 0.16, 0, 0)
            CATransaction.commit()
        }
        guard mood != self.mood else { return }
        self.mood = mood
        configure(mood)
    }

    // MARK: Moods

    private func configure(_ mood: MascotMood) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [lookLayer, bodyLayer] + eyes { l.removeAllAnimations() }

        let happy = mood == .happy
        for eye in eyes { eye.isHidden = happy }
        for arc in arcs { arc.isHidden = !happy }

        // Eye geometry for the mood.
        var w = eyeW, h = eyeH
        switch mood {
        case .attention: w *= 1.15; h *= 1.18
        case .sleeping: w = eyeW * 1.3; h = eyeW * 0.45
        default: break
        }
        let cx = bounds.midX, cy = bounds.midY
        let spacing = gap + w
        for (i, eye) in eyes.enumerated() {
            eye.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            eye.cornerRadius = min(w, h) / 2
            eye.position = CGPoint(x: cx + (i == 0 ? -spacing / 2 : spacing / 2), y: cy)
        }
        for (i, arc) in arcs.enumerated() {
            let aw = eyeW * 1.5, ah = eyeH * 0.42
            let arcSpacing = gap + aw   // same layout as the SwiftUI face: `gap` between the arcs' frames
            let x = cx + (i == 0 ? -arcSpacing / 2 : arcSpacing / 2) - aw / 2
            let y = cy - ah / 2
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: y))
            p.addQuadCurve(to: CGPoint(x: x + aw, y: y), control: CGPoint(x: x + aw / 2, y: y + ah * 2))
            arc.path = p
        }
        CATransaction.commit()

        let look = size * 0.16, hop = size * 0.12
        switch mood {
        case .idle:
            addBlink(period: 3.7)
            // An occasional glance left or right.
            lookLayer.add(loop("transform.translation.x", values: [0, 0, look, look, 0, 0, -look, -look, 0],
                               times: [0, 0.3, 0.33, 0.45, 0.48, 0.75, 0.78, 0.9, 0.93], duration: 9), forKey: "look")
        case .working:
            let dart = CABasicAnimation(keyPath: "transform.translation.x")
            dart.fromValue = -look
            dart.toValue = look
            dart.duration = 0.75
            dart.autoreverses = true
            dart.repeatCount = .infinity
            dart.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            lookLayer.add(dart, forKey: "look")
            addBlink(period: 2.6)
        case .attention:
            bodyLayer.add(loop("transform.translation.y", values: [0, hop, 0, 0],
                               times: [0, 0.12, 0.3, 1], duration: 1.5), forKey: "hop")
        case .happy:
            let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
            jump.values = [0, size * 0.18, 0]
            jump.keyTimes = [0, 0.35, 1]
            jump.duration = 0.6
            jump.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            bodyLayer.add(jump, forKey: "hop")
        case .sleeping:
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 1
            breathe.toValue = 0.9
            breathe.duration = 1.6
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bodyLayer.add(breathe, forKey: "breathe")
        case .dancing:
            // Music is playing: the two pill eyes become equalizer bars, each with its own rhythm
            // (same feel as the old EQ), plus a tiny bob of the whole face.
            let rhythms: [([CGFloat], Double)] = [([0.45, 1.0, 0.6, 1.08, 0.5, 0.85, 0.45], 1.3),
                                                  ([0.95, 0.5, 1.08, 0.62, 1.0, 0.42, 0.95], 1.1)]
            // Animate the height (not a y-scale) so the ends stay perfectly round, like EQ capsules.
            for (eye, r) in zip(eyes, rhythms) {
                eye.add(loop("bounds.size.height", values: r.0.map { $0 * h }, times: [0, 0.17, 0.33, 0.5, 0.67, 0.83, 1],
                             duration: r.1), forKey: "eq")
            }
            bodyLayer.add(loop("transform.translation.y", values: [0, size * 0.04, 0], times: [0, 0.5, 1], duration: 0.56),
                          forKey: "bob")
        }
    }

    private func addBlink(period: Double) {
        let blink = loop("transform.scale.y", values: [1, 1, 0.12, 1, 1],
                         times: [0, 0.55, 0.57, 0.6, 1], duration: period)
        for eye in eyes { eye.add(blink, forKey: "blink") }
    }

    private func loop(_ keyPath: String, values: [CGFloat], times: [Double], duration: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.duration = duration
        a.repeatCount = .infinity
        a.calculationMode = .cubic
        return a
    }
}

/// "Thinking" dots for the collapsed island, also on Core Animation.
struct ThinkingDotsCA: View {
    var body: some View {
        if Snapshots.active {
            ThinkingDots()
        } else {
            ThinkingDotsLayer().frame(width: 18, height: 6)
        }
    }
}

private struct ThinkingDotsLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        for i in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.cgColor
            dot.frame = CGRect(x: CGFloat(i) * 7, y: 1, width: 4, height: 4)
            dot.cornerRadius = 2
            dot.opacity = 0.3
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1, 0.3, 0.3]
            pulse.keyTimes = [0, 0.17, 0.33, 1]
            pulse.duration = 0.96
            pulse.repeatCount = .infinity
            pulse.timeOffset = Double(2 - i) * 0.32   // each dot lights up in turn
            dot.add(pulse, forKey: "pulse")
            view.layer?.addSublayer(dot)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
