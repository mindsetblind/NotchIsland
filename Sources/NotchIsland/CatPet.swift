import AppKit
import NotchIslandCore
import QuartzCore

// The pet as a neon cat — design and animations from Figma Make ("Animated Mascot Designs"), mirrored in
// the Figma file "Pet — NotchIsland". Built in CSS pixels (head 44×28) and scaled to the island; the
// CSS @keyframes are sampled into Core Animation, so the render server plays them with no per-frame work.

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor { NSColor(hex: hex, alpha: alpha).cgColor }

enum CatStyle {
    static func pupil(_ mood: PetMood) -> UInt32 {
        switch mood {
        case .idle: return 0x27EFFF
        case .working: return 0xC4FF5C
        case .attention: return 0xFF4FD8
        case .happy: return 0x6DFFBC
        case .sleeping: return 0x27EFFF
        case .dancing: return 0xFF52D9
        }
    }
}

final class CatNSView: NSView {
    /// Points per CSS pixel.
    private let k: CGFloat
    private let stage = CALayer()        // CSS coordinates (y down), scaled to the view
    private let body = CALayer()         // head + everything on it; bobs, tilts, squashes
    private let ears = [CAGradientLayer(), CAGradientLayer()]
    private let eyesGroup = CALayer()    // follows the cursor
    private let eyes = [CALayer(), CALayer()]
    private let pupilMoves = [CALayer(), CALayer()]
    private let pupils = [CALayer(), CALayer()]
    private let muzzle = CALayer()
    private let whiskers = [CALayer(), CALayer()]
    private let paws = [CALayer(), CALayer()]
    private let glitchA = CALayer(), glitchB = CALayer()
    private var mood: PetMood?
    private var gaze: CGFloat = .nan
    private var laidOutSize: CGSize = .zero

    /// `pointsPerCSSPixel`: 17 pt pet → ~0.57 (head ≈ 16 pt tall, 25 pt wide).
    init(pointsPerCSSPixel: CGFloat) {
        k = pointsPerCSSPixel
        super.init(frame: .zero)
        wantsLayer = true
        build()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func motionPreferenceChanged() { if let mood { configure(mood) } }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Centre what you see at rest — ears (7 px above the head) and head — not just the head.
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY - 3.5 * k)   // view is y-up: lower it
        CATransaction.commit()
        if let mood { configure(mood) }
    }

    func update(mood: PetMood, gaze: CGFloat) {
        if gaze != self.gaze {
            self.gaze = gaze
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
            eyesGroup.transform = CATransform3DMakeTranslation(gaze * 2.5, 0, 0)
            CATransaction.commit()
        }
        guard mood != self.mood else { return }
        self.mood = mood
        configure(mood)
    }

    // MARK: Building (CSS pixels, y down)

    private func place(_ layer: CALayer, in parent: CALayer, _ rect: CGRect, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        layer.anchorPoint = anchor
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
        parent.addSublayer(layer)
    }

    private func rect(_ parent: CALayer, _ r: CGRect, _ color: CGColor, radius: CGFloat = 0) -> CALayer {
        let l = CALayer()
        l.backgroundColor = color
        l.cornerRadius = radius
        place(l, in: parent, r)
        return l
    }

    /// Hard-stop diagonal gradient (CSS `linear-gradient(135deg, …)`); `mirrored` for the right ear.
    private func gradient(_ stops: [(UInt32, CGFloat, CGFloat)], mirrored: Bool = false) -> CAGradientLayer {
        let g = CAGradientLayer()
        var colors: [CGColor] = [], locations: [NSNumber] = []
        for (i, s) in stops.enumerated() {
            let end = i + 1 < stops.count ? stops[i + 1].2 : 1
            colors += [cg(s.0, s.1), cg(s.0, s.1)]
            locations += [NSNumber(value: Double(s.2)), NSNumber(value: Double(end) - 0.0001)]
        }
        g.colors = colors
        g.locations = locations
        g.startPoint = mirrored ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 0)
        g.endPoint = mirrored ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 1)
        return g
    }

    private func path(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }

    private func build() {
        guard let root = layer else { return }
        stage.isGeometryFlipped = true
        stage.bounds = CGRect(x: 0, y: 0, width: 44, height: 28)
        stage.transform = CATransform3DMakeScale(k, k, 1)
        root.addSublayer(stage)
        place(body, in: stage, CGRect(x: 0, y: 0, width: 44, height: 28))

        // Ears behind the head: stepped "pixel" silhouettes with a cyan band, pivoting at the bottom.
        let earPts: [(CGFloat, CGFloat)] = [(0, 10), (0, 5), (3, 5), (3, 0), (6, 0), (6, 2.5), (9, 2.5), (9, 7.5), (12, 7.5), (12, 10)]
        for (i, ear) in ears.enumerated() {
            let mirrored = i == 1
            let pts = mirrored ? earPts.map { (12 - $0.0, $0.1) } : earPts
            let g = gradient([(0x20272B, 1, 0), (0x35DFF2, 1, 0.44), (0x080A0D, 1, 0.52)], mirrored: mirrored)
            ear.colors = g.colors; ear.locations = g.locations; ear.startPoint = g.startPoint; ear.endPoint = g.endPoint
            let mask = CAShapeLayer(); mask.path = path(pts); mask.frame = CGRect(x: 0, y: 0, width: 12, height: 10)
            ear.mask = mask
            place(ear, in: body, CGRect(x: mirrored ? 29 : 3, y: -7, width: 12, height: 10), anchor: CGPoint(x: 0.5, y: 1))
            // Neon fringe of the CSS drop-shadow filter: a cyan edge on the left, magenta on the right.
            // (A layer shadow would be clipped by the mask, so it's an outline layer inside the ear.)
            ear.mask = nil
            let fill = CAShapeLayer(); fill.path = path(pts); fill.frame = ear.bounds
            let outline = CAShapeLayer()
            outline.path = path(pts)
            outline.frame = ear.bounds
            outline.fillColor = nil
            outline.strokeColor = cg(mirrored ? 0xFF8BE6 : 0x94F5FF, 0.6)
            outline.lineWidth = 1
            let paint = CAGradientLayer()
            paint.colors = ear.colors; paint.locations = ear.locations; paint.startPoint = ear.startPoint; paint.endPoint = ear.endPoint
            paint.frame = ear.bounds
            paint.mask = fill
            ear.colors = nil
            ear.addSublayer(paint)
            ear.addSublayer(outline)
        }

        // Offset "shadows" of the CSS filter + box-shadow, behind the head.
        let headRect = CGRect(x: 0, y: 0, width: 44, height: 28)
        for (dx, dy, color, alpha) in [(3.0, 3.0, 0x000000, 0.3), (0, 2, 0x164A55, 1), (-1, 0, 0x3CEDFF, 0.24), (1, 0, 0xFF41D6, 0.18)]
            as [(CGFloat, CGFloat, UInt32, CGFloat)] {
            let s = rect(body, headRect.offsetBy(dx: dx, dy: dy), cg(color, alpha), radius: 9)
            if color == 0x164A55 {   // soft cyan glow around the whole head
                s.shadowColor = cg(0x41E5FF); s.shadowOpacity = 0.18; s.shadowRadius = 4; s.shadowOffset = .zero
            }
        }

        // Head: dark glass, cyan rim, magenta scan stripe, inner highlight and shade, glitch slices.
        let head = gradient([(0x252D32, 1, 0), (0x111619, 1, 0.18), (0x176574, 1, 0.70), (0x08090D, 1, 0.78)])
        head.cornerRadius = 9
        head.masksToBounds = true
        head.borderWidth = 1
        head.borderColor = cg(0x94F5FF, 0.95)
        place(head, in: body, headRect)
        _ = rect(head, CGRect(x: 29.9, y: 0, width: 1.8, height: 28), cg(0xFF3AD2, 0.24))
        _ = rect(head, CGRect(x: 1, y: 0, width: 2, height: 28), cg(0x80F0FF, 0.2))
        _ = rect(head, CGRect(x: 41, y: 0, width: 3, height: 28), cg(0x000000, 0.55))
        _ = rect(head, CGRect(x: 0, y: 25, width: 41, height: 3), cg(0x000000, 0.55))
        place(glitchA, in: head, CGRect(x: -8.8, y: 7, width: 30.8, height: 2))
        glitchA.backgroundColor = cg(0x35F1FF)
        _ = rect(glitchA, CGRect(x: 8, y: 8, width: 30.8, height: 2), cg(0xFF3BD4))
        place(glitchB, in: head, CGRect(x: 29.2, y: 20, width: 18.5, height: 3))
        glitchB.backgroundColor = cg(0xFF3BD4)
        for g in [glitchA, glitchB] { g.opacity = 0 }

        // Eyes: clipped boxes with glowing pill pupils.
        place(eyesGroup, in: body, headRect)
        for (i, eye) in eyes.enumerated() {
            eye.masksToBounds = true
            place(eye, in: eyesGroup, CGRect(x: i == 0 ? 7 : 27, y: 8, width: 10, height: 12))
            place(pupilMoves[i], in: eye, CGRect(x: 0, y: 0, width: 10, height: 12))
            let p = pupils[i]
            p.cornerRadius = 3.5
            p.shadowOffset = .zero
            p.shadowRadius = 2.5
            p.shadowOpacity = 0.9
            place(p, in: pupilMoves[i], CGRect(x: 1.5, y: 1, width: 7, height: 10))
        }

        // Muzzle: stepped pink nose and a tiny "w" mouth.
        place(muzzle, in: body, CGRect(x: 18, y: 16, width: 8, height: 6))
        let nose = CAShapeLayer()
        nose.path = path([(0, 0), (4, 0), (4, 2), (3, 2), (3, 3), (1, 3), (1, 2), (0, 2)])
        nose.fillColor = cg(0xFF45D5)
        place(nose, in: muzzle, CGRect(x: 2, y: 0, width: 4, height: 3))
        for (x, deg) in [(1.0, 24.0), (3, -24)] as [(CGFloat, CGFloat)] {
            let m = rect(muzzle, CGRect(x: x, y: 4, width: 4, height: 1), cg(0x8A8795))
            m.transform = CATransform3DMakeRotation(deg * .pi / 180, 0, 0, 1)
        }

        // Whiskers (the right set is mirrored), pivoting where they meet the face.
        for (i, w) in whiskers.enumerated() {
            place(w, in: body, CGRect(x: i == 0 ? -2 : 37, y: 16, width: 9, height: 7))
            w.opacity = 0.65
            for (y, deg) in [(1.0, 10.0), (5, -10)] as [(CGFloat, CGFloat)] {
                let line = CALayer()
                line.backgroundColor = cg(0x7AEAF5)
                line.cornerRadius = 0.5
                let anchor = CGPoint(x: i == 0 ? 1 : 0, y: 0.5)
                place(line, in: w, CGRect(x: i == 0 ? 0 : 1, y: y, width: 8, height: 1), anchor: anchor)
                line.transform = CATransform3DMakeRotation((i == 0 ? deg : -deg) * .pi / 180, 0, 0, 1)
            }
        }

        // Paws (hidden unless the mood uses them), pivoting at the top.
        for (i, paw) in paws.enumerated() {
            place(paw, in: body, CGRect(x: i == 0 ? 5 : 29, y: 23, width: 10, height: 11), anchor: CGPoint(x: 0.5, y: 0))
            _ = rect(paw, CGRect(x: 2, y: 2, width: 10, height: 11), cg(0xFF39D3, 0.28), radius: 5)
            let pad = gradient([(0x263136, 1, 0), (0x176C79, 1, 0.58), (0x08090D, 1, 0.72)])
            pad.cornerRadius = 5
            pad.masksToBounds = true
            pad.borderWidth = 1
            pad.borderColor = cg(0x59E5F6, 0.45)
            place(pad, in: paw, CGRect(x: 0, y: 0, width: 10, height: 11))
            let bean = rect(paw, CGRect(x: 1, y: 6, width: 6, height: 4), cg(0x10191C), radius: 2)
            bean.borderWidth = 1
            bean.borderColor = cg(0x4DEAFF)
            for x in [3.0, 5.0] as [CGFloat] { _ = rect(paw, CGRect(x: x, y: 7, width: 1, height: 2), cg(0xFF58D8)) }
            paw.opacity = 0
        }
    }

    // MARK: Still image (snapshots)

    /// The cat's resting pose for a mood, as an image (for ImageRenderer-based snapshots).
    static func still(mood: PetMood, pointsPerCSSPixel k: CGFloat) -> NSImage {
        let size = NSSize(width: (48 * k).rounded(.up) + 4, height: (44 * k).rounded(.up) + 4)
        let view = CatNSView(pointsPerCSSPixel: k)
        view.frame = NSRect(origin: .zero, size: size)
        view.layout()
        view.update(mood: mood, gaze: 0)
        let scale: CGFloat = 2
        guard let layer = view.layer, let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cgImage = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: Moods

    private var allLayers: [CALayer] {
        [stage, body, glitchA, glitchB, muzzle] + ears + eyes + pupilMoves + pupils + whiskers + paws
    }

    private func configure(_ mood: PetMood) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers { l.removeAllAnimations() }
        // Resting values; the mood's animations play on top of them.
        for l in [body, muzzle] + eyes + pupilMoves + pupils + whiskers + paws { l.transform = CATransform3DIdentity }
        for e in ears { e.transform = CATransform3DIdentity }
        let color = cg(CatStyle.pupil(mood))
        for p in pupils {
            p.backgroundColor = color
            p.shadowColor = color
            p.opacity = mood == .sleeping ? 0 : 1
        }
        for w in whiskers { w.opacity = 0.65 }
        for p in paws { p.opacity = 0 }
        if mood == .sleeping {
            for p in paws { p.opacity = 1; p.transform = CATransform3DMakeTranslation(0, 3, 0) }
        }
        CATransaction.commit()

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Reduce motion: the pose and colours still show the mood, the eyes blink, nothing moves around.
        if reduce {
            if mood != .sleeping { for e in eyes { animate(e, CatMotion.blink) } }
            if mood == .sleeping { applyStatic(CatMotion.sleepPose) }
            return
        }
        // Always: the occasional signal flicker and glitch slices.
        animate(stage, CatMotion.flicker, scalar: "opacity", property: "op", fallback: 1)
        animate(glitchA, CatMotion.glitchA, scalar: "opacity", property: "op", fallback: 0)
        animate(glitchA, CatMotion.glitchA, key: "slide")
        animate(glitchB, CatMotion.glitchB, scalar: "opacity", property: "op", fallback: 0)
        animate(glitchB, CatMotion.glitchB, key: "slide")

        for spec in CatMotion.specs(for: mood) {
            let targets: [CALayer]
            switch spec.part {
            case .body: targets = [body]
            case .earLeft: targets = [ears[0]]
            case .earRight: targets = [ears[1]]
            case .eyes: targets = eyes
            case .pupils: targets = pupilMoves
            case .muzzle: targets = [muzzle]
            case .whiskers: targets = whiskers
            case .pawLeft: targets = [paws[0]]
            case .pawRight: targets = [paws[1]]
            }
            for t in targets {
                if spec.frames.properties.contains(where: { $0 != "op" }) {
                    animate(t, spec.frames, perspective: spec.part == .body, mirrored: spec.part == .earRight)
                }
                if spec.frames.properties.contains("op") {
                    animate(t, spec.frames, scalar: "opacity", property: "op", fallback: Double(t.opacity))
                }
            }
        }
        // Dancing to music: the pupils also bounce like equalizer bars, each to its own beat.
        if mood == .dancing {
            let beats: [([Double], Double)] = [([0.45, 1.0, 0.6, 1.08, 0.5, 0.85, 0.45], 1.3),
                                               ([0.95, 0.5, 1.08, 0.62, 1.0, 0.42, 0.95], 1.1)]
            for (p, beat) in zip(pupils, beats) {
                let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
                a.values = beat.0
                a.keyTimes = (0..<beat.0.count).map { NSNumber(value: Double($0) / Double(beat.0.count - 1)) }
                a.duration = beat.1
                a.repeatCount = .infinity
                a.calculationMode = .cubic
                p.add(a, forKey: "eq")
            }
        }
    }

    private func applyStatic(_ frames: CSSKeyframes) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.transform = Self.transform(frames, at: 0, perspective: false, mirrored: false)
        CATransaction.commit()
    }

    /// Transform track: tx, ty, rot, sx, sy (and rx, ry for the body's 3D tilt).
    private func animate(_ layer: CALayer, _ frames: CSSKeyframes, key: String = "motion",
                         perspective: Bool = false, mirrored: Bool = false) {
        let n = max(2, Int((frames.duration * 30).rounded()) + 1)
        let values = (0..<n).map { i -> NSValue in
            NSValue(caTransform3D: Self.transform(frames, at: Double(i) / Double(n - 1), perspective: perspective, mirrored: mirrored))
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = values
        a.duration = frames.duration
        a.repeatCount = .infinity
        a.calculationMode = isStepped(frames) ? .discrete : .linear
        layer.add(a, forKey: key)
    }

    private func animate(_ layer: CALayer, _ frames: CSSKeyframes, scalar keyPath: String, property: String, fallback: Double) {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = frames.samples(property, default: fallback)
        a.duration = frames.duration
        a.repeatCount = .infinity
        a.calculationMode = isStepped(frames) ? .discrete : .linear
        layer.add(a, forKey: keyPath)
    }

    private func isStepped(_ f: CSSKeyframes) -> Bool {
        if case .steps = f.timing { return true }
        return false
    }

    static func transform(_ f: CSSKeyframes, at t: Double, perspective: Bool, mirrored: Bool) -> CATransform3D {
        func v(_ p: String, _ d: Double) -> CGFloat { CGFloat(f.value(p, at: t, default: d)) }
        var m = CATransform3DIdentity
        if perspective { m.m34 = -1 / 180 }
        m = CATransform3DTranslate(m, v("tx", 0), v("ty", 0), 0)
        let rx = v("rx", 0), ry = v("ry", 0)
        if rx != 0 { m = CATransform3DRotate(m, rx * .pi / 180, 1, 0, 0) }
        if ry != 0 { m = CATransform3DRotate(m, ry * .pi / 180, 0, 1, 0) }
        let rot = v("rot", 0) * (mirrored ? -1 : 1)
        if rot != 0 { m = CATransform3DRotate(m, rot * .pi / 180, 0, 0, 1) }
        let s = v("s", 1)
        m = CATransform3DScale(m, v("sx", 1) * s, v("sy", 1) * s, 1)
        return m
    }
}

// MARK: - Motion (the CSS @keyframes from Figma Make, one per part and mood)

enum CatMotion {
    enum Part { case body, earLeft, earRight, eyes, pupils, muzzle, whiskers, pawLeft, pawRight }
    struct Spec { let part: Part; let frames: CSSKeyframes }

    typealias K = CSSKeyframes

    static let blink = K(duration: 3.8, timing: .steps(2), groups: [([0, 0.34, 0.43, 0.76, 0.84, 1], ["sy": 1]), ([0.38, 0.80], ["sy": 0.12])])
    static let flicker = K(duration: 5.6, timing: .steps(1), groups: [([0, 0.89, 0.91, 0.94, 1], ["op": 1]), ([0.90], ["op": 0.68]), ([0.92], ["op": 0.9])])
    static let glitchA = K(duration: 4.8, timing: .steps(1), groups: [
        ([0, 0.84, 0.88, 1], ["op": 0, "tx": 0]), ([0.85], ["op": 0.9, "tx": 10]), ([0.86], ["op": 0.45, "tx": -4]), ([0.87], ["op": 1, "tx": 5])])
    static let glitchB = K(duration: 4.8, timing: .steps(1), groups: [
        ([0, 0.90, 0.94, 1], ["op": 0, "tx": 0]), ([0.91], ["op": 1, "tx": -10]), ([0.92], ["op": 0.55, "tx": 4]), ([0.93], ["op": 0.9, "tx": -3])])
    static let sleepPose = K(duration: 3.4, timing: .steps(6), [(0, ["ty": 3, "sx": 1.08, "sy": 0.86, "rot": -2])])

    static func specs(for mood: PetMood) -> [Spec] {
        switch mood {
        case .idle:
            let ear = K(duration: 3.2, timing: .steps(4), groups: [([0, 0.65, 1], ["rot": 0]), ([0.72], ["rot": -14]), ([0.79], ["rot": 5])])
            return [
                // Make's idle sways and turns the head (up to −2° / −8°) and, being stepped, holds those
                // poses — at island size that read as "standing crooked". At rest the cat stands straight
                // and only breathes up and down; the tilts stay in the active moods.
                Spec(part: .body, frames: K(duration: 3.2, timing: .easeInOut, [
                    (0, ["ty": 0]), (0.28, ["ty": -1]), (0.58, ["ty": 0]), (0.76, ["ty": -1.5]), (1, ["ty": 0])])),
                Spec(part: .eyes, frames: blink),
                Spec(part: .pupils, frames: K(duration: 3.8, timing: .steps(3), groups: [([0, 0.16, 0.86, 1], ["tx": 0]), ([0.28, 0.50], ["tx": 2]), ([0.62, 0.76], ["tx": -2])])),
                Spec(part: .muzzle, frames: K(duration: 3.8, timing: .steps(2), groups: [([0, 0.48, 0.58, 1], ["sy": 1]), ([0.53], ["sy": 0.75])])),
                Spec(part: .whiskers, frames: K(duration: 3.8, timing: .steps(2), groups: [([0, 0.45, 0.60, 1], ["ty": 0]), ([0.50], ["ty": -1]), ([0.55], ["ty": 1])])),
                Spec(part: .earLeft, frames: ear), Spec(part: .earRight, frames: ear),
            ]
        case .working:
            return [
                Spec(part: .body, frames: K(duration: 1.8, timing: .easeInOut, groups: [([0, 1], ["ty": 1, "ry": -13, "rot": -5]), ([0.5], ["ty": -4, "ry": 13, "rot": 6])])),
                Spec(part: .pupils, frames: K(duration: 2.2, timing: .steps(3), groups: [
                    ([0, 0.20, 1], ["tx": 0, "ty": 0, "rot": 0]), ([0.32, 0.48], ["tx": 2, "ty": 1, "rot": 8]), ([0.62, 0.78], ["tx": -2, "ty": -1, "rot": -8])])),
                Spec(part: .earLeft, frames: K(duration: 1.8, timing: .easeInOut, groups: [([0, 1], ["rot": -9]), ([0.5], ["rot": 10])])),
                Spec(part: .earRight, frames: K(duration: 1.8, timing: .easeInOut, groups: [([0, 1], ["rot": 8]), ([0.5], ["rot": -12])])),
                Spec(part: .pawLeft, frames: K(duration: 1.8, timing: .easeInOut, groups: [([0, 1], ["op": 0.8, "ty": 3, "rot": -8]), ([0.5], ["op": 1, "tx": 5, "ty": -8, "rot": -28])])),
            ]
        case .attention:
            let ear = K(duration: 1.35, timing: .easeInOut, groups: [([0, 1], ["rot": 0, "ty": 0]), ([0.45, 0.70], ["rot": -17, "ty": -2])])
            return [
                Spec(part: .body, frames: K(duration: 1.35, timing: .cubicBezier(0.3, 0.8, 0.3, 1), groups: [
                    ([0, 1], ["ty": 1]), ([0.45], ["sx": 1.15, "sy": 0.88, "ty": -3, "rx": -12]), ([0.70], ["sx": 0.96, "sy": 1.08, "ty": -2, "rx": 8])])),
                Spec(part: .eyes, frames: K(duration: 1.35, timing: .easeInOut, groups: [([0, 1], ["sx": 1, "sy": 1]), ([0.45, 0.70], ["sx": 1.08, "sy": 1.16])])),
                Spec(part: .pupils, frames: K(duration: 1.35, timing: .easeInOut, groups: [([0, 1], ["ty": 0, "sy": 1]), ([0.45, 0.70], ["ty": -1, "sy": 1.14])])),
                Spec(part: .whiskers, frames: K(duration: 1.35, timing: .easeInOut, groups: [([0, 1], ["op": 0.55]), ([0.45, 0.70], ["op": 1])])),
                Spec(part: .earLeft, frames: ear), Spec(part: .earRight, frames: ear),
                Spec(part: .pawLeft, frames: K(duration: 1.35, timing: .easeInOut, groups: [
                    ([0, 0.15, 1], ["op": 0, "ty": -2, "rot": 0]), ([0.32, 0.56], ["op": 1, "ty": 4, "rot": 7]), ([0.72, 0.88], ["op": 0.65, "ty": 2, "rot": -4])])),
                Spec(part: .pawRight, frames: K(duration: 1.35, timing: .easeInOut, groups: [
                    ([0, 0.15, 1], ["op": 0, "ty": -2, "rot": 0]), ([0.32, 0.56], ["op": 0.65, "ty": 2, "rot": 4]), ([0.72, 0.88], ["op": 1, "ty": 4, "rot": -7])])),
            ]
        case .happy:
            let ear = K(duration: 2, timing: .easeInOut, groups: [([0, 0.25, 1], ["rot": 0]), ([0.45, 0.68], ["rot": -20])])
            func wave(_ side: Double) -> K {
                K(duration: 2, timing: .easeInOut, groups: [
                    ([0, 0.24, 0.82, 1], ["op": 0, "tx": 0, "ty": -2, "rot": 0]), ([0.38], ["op": 1, "tx": -2 * side, "ty": 4, "rot": 18 * side]),
                    ([0.52], ["op": 1, "tx": -4 * side, "ty": 0, "rot": 40 * side]), ([0.68], ["op": 1, "tx": -2 * side, "ty": 4, "rot": 14 * side])])
            }
            return [
                Spec(part: .body, frames: K(duration: 2, timing: .cubicBezier(0.34, 1.56, 0.64, 1), groups: [
                    ([0, 0.25, 1], ["ty": 1]), ([0.45], ["ty": -7, "sx": 0.94, "sy": 1.08, "rx": -10, "ry": -8, "rot": -3]),
                    ([0.62], ["ty": 0, "sx": 1.1, "sy": 0.9, "rx": 8, "ry": 7, "rot": 2])])),
                Spec(part: .eyes, frames: K(duration: 2, timing: .easeInOut, groups: [([0, 0.28, 0.82, 1], ["ty": 0, "sx": 1, "sy": 1]), ([0.42, 0.68], ["ty": 3, "sx": 1.08, "sy": 0.38])])),
                Spec(part: .pupils, frames: K(duration: 2, timing: .easeInOut, groups: [([0, 0.28, 0.82, 1], ["ty": 0, "sy": 1]), ([0.42, 0.68], ["ty": 1, "sy": 0.2])])),
                Spec(part: .muzzle, frames: K(duration: 2, timing: .easeInOut, groups: [([0, 0.28, 0.82, 1], ["ty": 0, "s": 1]), ([0.42, 0.68], ["ty": 1, "s": 1.12])])),
                Spec(part: .whiskers, frames: K(duration: 2, timing: .easeInOut, groups: [([0, 0.28, 0.82, 1], ["op": 0.65, "ty": 0]), ([0.42, 0.68], ["op": 1, "ty": 1])])),
                Spec(part: .earLeft, frames: ear), Spec(part: .earRight, frames: ear),
                Spec(part: .pawLeft, frames: wave(1)), Spec(part: .pawRight, frames: wave(-1)),
            ]
        case .sleeping:
            let ear = K(duration: 3.4, timing: .easeInOut, groups: [([0, 1], ["rot": -20, "ty": 2]), ([0.5], ["rot": -15, "ty": 1])])
            return [
                Spec(part: .body, frames: K(duration: 3.4, timing: .steps(6), groups: [([0, 1], ["ty": 3, "sx": 1.08, "sy": 0.86, "rot": -2]), ([0.5], ["ty": 2, "sx": 1.12, "sy": 0.9, "rot": 2])])),
                Spec(part: .eyes, frames: K(duration: 3.4, timing: .easeInOut, groups: [([0, 1], ["ty": 4, "sx": 1.05, "sy": 0.14]), ([0.5], ["ty": 3, "sx": 1.05, "sy": 0.18])])),
                Spec(part: .whiskers, frames: K(duration: 3.4, timing: .easeInOut, groups: [([0, 1], ["op": 0.35, "ty": 1]), ([0.5], ["op": 0.55, "ty": 2])])),
                Spec(part: .earLeft, frames: ear), Spec(part: .earRight, frames: ear),
            ]
        case .dancing:
            return [
                Spec(part: .body, frames: K(duration: 0.9, timing: .steps(6), [
                    (0, ["tx": -2, "ry": -12, "rot": -8]), (0.25, ["ty": -7, "rx": -8, "rot": 0]), (0.5, ["tx": 2, "ry": 12, "rot": 8]),
                    (0.75, ["ty": -7, "rx": 8, "rot": 0]), (1, ["tx": -2, "ry": -12, "rot": -8])])),
                Spec(part: .pupils, frames: K(duration: 0.9, timing: .steps(2), groups: [([0, 1], ["tx": -1]), ([0.5], ["tx": 1])])),
                Spec(part: .earLeft, frames: K(duration: 0.9, timing: .steps(3), groups: [([0, 1], ["rot": -18]), ([0.5], ["rot": 12])])),
                Spec(part: .earRight, frames: K(duration: 0.9, timing: .steps(3), groups: [([0, 1], ["rot": 12]), ([0.5], ["rot": -18])])),
                Spec(part: .pawLeft, frames: K(duration: 0.9, timing: .steps(3), groups: [([0, 1], ["op": 1, "ty": 3, "rot": -8]), ([0.5], ["op": 1, "ty": -3, "rot": 10])])),
                Spec(part: .pawRight, frames: K(duration: 0.9, timing: .steps(3), groups: [([0, 1], ["op": 1, "ty": -3, "rot": -10]), ([0.5], ["op": 1, "ty": 3, "rot": 8])])),
            ]
        }
    }
}
