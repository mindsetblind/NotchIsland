// Offline renderer for a ~9.5 s teaser: the pet (glowing icosahedron) assembles out of darkness,
// bursts apart and snaps back, then flies into the MacBook notch, which grows into the island.
// SceneKit (offscreen SCNRenderer, HDR + bloom + DOF) → AVAssetWriter H.264.
//
//   ./render.sh            (both cuts: 16:9 and 9:16, with sound)
//   cat Sound.swift PromoRender.swift > /tmp/p.swift && swiftc -O /tmp/p.swift -o /tmp/promo && /tmp/promo [--portrait] out.mp4
//   /tmp/promo --stills dir 0.5,2,3.3,5,6.8,9   (PNG stills for checking)

import AppKit
import AVFoundation
import CoreImage
import CoreText
import SceneKit
import simd

typealias V3 = SIMD3<Float>

let portrait = CommandLine.arguments.contains("--portrait")
let W = portrait ? 1080 : 1920, H = portrait ? 1920 : 1080, FPS = 60
let DUR: Float = 10

// MARK: - Math

func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }
func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
func smooth(_ x: Float) -> Float { let x = clamp01(x); return x * x * (3 - 2 * x) }
func smoother(_ x: Float) -> Float { let x = clamp01(x); return x * x * x * (x * (x * 6 - 15) + 10) }
func easeOut(_ x: Float, _ p: Float = 3) -> Float { 1 - pow(1 - clamp01(x), p) }
func easeIn(_ x: Float, _ p: Float = 3) -> Float { pow(clamp01(x), p) }
func seg(_ t: Float, _ a: Float, _ b: Float) -> Float { clamp01((t - a) / (b - a)) }
/// Spring 0→1 with a little overshoot.
func spring(_ x: Float, damping: Float = 6.5, freq: Float = 11) -> Float {
    let x = max(0, x)
    return 1 - exp(-damping * x) * cos(freq * x)
}
func hash(_ n: Float) -> Float { let s = sin(n * 127.1 + 311.7) * 43758.5453; return s - floor(s) }
func hex(_ h: UInt32) -> V3 { V3(Float((h >> 16) & 0xFF), Float((h >> 8) & 0xFF), Float(h & 0xFF)) / 255 }
func ns(_ c: V3, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(max(0, c.x)), green: CGFloat(max(0, c.y)), blue: CGFloat(max(0, c.z)), alpha: a)
}

/// Piecewise colour ramp.
func ramp(_ t: Float, _ keys: [(Float, V3)]) -> V3 {
    if t <= keys[0].0 { return keys[0].1 }
    for i in 1..<keys.count where t <= keys[i].0 {
        return mix(keys[i - 1].1, keys[i].1, smooth((t - keys[i - 1].0) / (keys[i].0 - keys[i - 1].0)))
    }
    return keys.last!.1
}

/// Catmull-Rom through keyframes (time, value).
func spline(_ t: Float, _ k: [(Float, V3)]) -> V3 {
    if t <= k[0].0 { return k[0].1 }
    if t >= k.last!.0 { return k.last!.1 }
    var i = 0
    while t > k[i + 1].0 { i += 1 }
    let p0 = k[max(0, i - 1)].1, p1 = k[i].1, p2 = k[i + 1].1, p3 = k[min(k.count - 1, i + 2)].1
    let u = smooth((t - k[i].0) / (k[i + 1].0 - k[i].0)) * 0.35 + (t - k[i].0) / (k[i + 1].0 - k[i].0) * 0.65
    let u2 = u * u, u3 = u2 * u
    return 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (-p0 + 3 * p1 - 3 * p2 + p3) * u3)
}

// MARK: - Images

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
func blurred(_ img: CGImage, _ r: Double) -> CGImage {
    let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ciContext.createCGImage(ci, from: ci.extent)!
}

/// White centre fading to black (for additive halos).
let radialImage: CGImage = bitmap(256, 256) { c in
    c.setFillColor(.black); c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.45, alpha: 1), CGColor(gray: 0.12, alpha: 1),
                                CGColor(gray: 0.03, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                       locations: [0, 0.12, 0.35, 0.65, 1])!
    c.drawRadialGradient(g, startCenter: CGPoint(x: 128, y: 128), startRadius: 0, endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
}

/// Dark wallpaper with soft blooms of colour.
let wallpaperImage: CGImage = {
    let w = 2048, h = 1280
    let raw = bitmap(w, h) { c in
        c.setFillColor(ns(hex(0x03040B)).cgColor); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let blobs: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] = [
            (0.18, 0.30, 0.55, 0.45, 0x3B1CFF, 0.95), (0.55, 0.12, 0.70, 0.35, 0x0F5BFF, 0.9),
            (0.85, 0.42, 0.45, 0.55, 0xB02CFF, 0.85), (0.42, 0.62, 0.35, 0.25, 0x12C8FF, 0.55),
            (0.95, 0.05, 0.40, 0.30, 0xFF3FA4, 0.7), (0.05, 0.85, 0.30, 0.30, 0x2A0F7A, 0.8),
        ]
        for (x, y, rw, rh, col, a) in blobs {
            c.setFillColor(ns(hex(col), a).cgColor)
            c.fillEllipse(in: CGRect(x: (x - rw / 2) * CGFloat(w), y: (y - rh / 2) * CGFloat(h), width: rw * CGFloat(w), height: rh * CGFloat(h)))
        }
        // A sweeping ribbon.
        c.setStrokeColor(ns(hex(0x7FE7FF), 0.55).cgColor)
        c.setLineWidth(60)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -100, y: 300))
        p.addCurve(to: CGPoint(x: 2200, y: 520), control1: CGPoint(x: 700, y: 900), control2: CGPoint(x: 1300, y: -100))
        c.addPath(p); c.strokePath()
    }
    let b = blurred(raw, 120)
    // Darken the top so the notch reads, and add grain-free vignette.
    return bitmap(w, h) { c in
        c.draw(b, in: CGRect(x: 0, y: 0, width: w, height: h))
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 0, alpha: 0.75), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: CGFloat(h) * 0.72), options: [])
        let mh: CGFloat = 44
        c.setFillColor(CGColor(gray: 1, alpha: 0.07)); c.fill(CGRect(x: 0, y: CGFloat(h) - mh, width: CGFloat(w), height: mh))
        c.setFillColor(CGColor(gray: 1, alpha: 0.8))
        for (x, gw) in [(-6.6, 0.16), (-6.2, 0.36), (-5.7, 0.3), (-5.25, 0.34), (-4.78, 0.26), (5.2, 0.16), (5.55, 0.2), (5.95, 0.2), (6.4, 0.42)] as [(CGFloat, CGFloat)] {
            let px = (x + 7) / 14 * CGFloat(w), pw = gw / 14 * CGFloat(w)
            c.addPath(CGPath(roundedRect: CGRect(x: px - pw / 2, y: CGFloat(h) - mh / 2 - 5, width: pw, height: 10), cornerWidth: 5, cornerHeight: 5, transform: nil))
            c.fillPath()
        }
    }
}()

/// Seamless horizontal spectrum for the "intelligence" rim.
let spectrumImage: CGImage = bitmap(1024, 4) { c in
    let cols: [UInt32] = [0x22D3EE, 0x3B82F6, 0x8B5CF6, 0xEC4899, 0xFF8A3D, 0x22D3EE]
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: cols.map { ns(hex($0)).cgColor } as CFArray,
                       locations: [0, 0.22, 0.45, 0.65, 0.83, 1])!
    c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 1024, y: 0), options: [])
}

/// Environment for metal reflections: dark room, one long softbox, a coloured kicker.
let envImage: CGImage = blurred(bitmap(1024, 512) { c in
    c.setFillColor(CGColor(gray: 0.015, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
    c.setFillColor(CGColor(gray: 0.9, alpha: 1)); c.fill(CGRect(x: 380, y: 400, width: 260, height: 40))
    c.setFillColor(ns(hex(0x4F7BFF), 0.8).cgColor); c.fill(CGRect(x: 820, y: 230, width: 120, height: 60))
    c.setFillColor(ns(hex(0xC04DFF), 0.6).cgColor); c.fill(CGRect(x: 60, y: 200, width: 140, height: 50))
}, 6)

// MARK: - Materials

func constant(_ color: V3, _ intensity: Float, add: Bool = false) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = ns(color)
    m.diffuse.intensity = CGFloat(intensity)
    if add { m.blendMode = .add; m.writesToDepthBuffer = false }
    return m
}

func halo(size: CGFloat) -> (SCNNode, SCNMaterial) {
    let p = SCNPlane(width: size, height: size)
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = radialImage
    m.multiply.contents = NSColor.white
    m.blendMode = .add
    m.writesToDepthBuffer = false
    m.readsFromDepthBuffer = true
    p.materials = [m]
    let n = SCNNode(geometry: p)
    n.constraints = [SCNBillboardConstraint()]
    n.renderingOrder = 10
    return (n, m)
}

// MARK: - Pet

let phi: Float = (1 + Float(5).squareRoot()) / 2
let icoVerts: [V3] = [
    V3(-1, phi, 0), V3(1, phi, 0), V3(-1, -phi, 0), V3(1, -phi, 0),
    V3(0, -1, phi), V3(0, 1, phi), V3(0, -1, -phi), V3(0, 1, -phi),
    V3(phi, 0, -1), V3(phi, 0, 1), V3(-phi, 0, -1), V3(-phi, 0, 1),
].map { simd_normalize($0) }
let icoFaces: [[Int]] = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
]

func triangle(_ v: [V3]) -> SCNGeometry {
    let n = simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0]))
    return SCNGeometry(sources: [SCNGeometrySource(vertices: v.map { SCNVector3($0) }),
                                 SCNGeometrySource(normals: Array(repeating: SCNVector3(n), count: 3))],
                       elements: [SCNGeometryElement(indices: [UInt16(0), 1, 2], primitiveType: .triangles)])
}

final class Pet {
    struct Face {
        let node: SCNNode, c: V3, n: V3, axis: V3, stagger: Float
        let edges: [(node: SCNNode, cyl: SCNCylinder, a: V3, b: V3)]
        let edgeMat: SCNMaterial
    }
    let root = SCNNode(), spin = SCNNode()
    var faces: [Face] = []
    let faceMat = SCNMaterial()
    let coreMat = constant(.one, 1)
    let core: SCNNode
    let (haloNode, haloMat) = halo(size: 5.5)
    let (coreHalo, coreHaloMat) = halo(size: 1.8)
    let light = SCNLight()

    init() {
        faceMat.lightingModel = .physicallyBased
        faceMat.diffuse.contents = ns(hex(0x0E1117))
        faceMat.metalness.contents = 0.85
        faceMat.roughness.contents = 0.28
        faceMat.isDoubleSided = true
        let s = SCNSphere(radius: 0.16); s.segmentCount = 32; s.materials = [coreMat]
        core = SCNNode(geometry: s)
        root.addChildNode(spin)
        spin.addChildNode(core)
        root.addChildNode(haloNode)
        root.addChildNode(coreHalo)
        light.type = .omni
        light.attenuationStartDistance = 0
        light.categoryBitMask = 1
        let ln = SCNNode(); ln.light = light; root.addChildNode(ln)

        for (i, f) in icoFaces.enumerated() {
            let v = f.map { icoVerts[$0] }
            let c = (v[0] + v[1] + v[2]) / 3
            let n = simd_normalize(c)
            let lv = v.map { ($0 - c) * 0.9 }
            let node = SCNNode(geometry: triangle(lv))
            node.geometry!.materials = [faceMat]
            node.simdPosition = c
            let em = constant(.one, 3)
            var edges: [(SCNNode, SCNCylinder, V3, V3)] = []
            for k in 0..<3 {
                let a = lv[k] + n * 0.006, b = lv[(k + 1) % 3] + n * 0.006
                let cyl = SCNCylinder(radius: 0.0095, height: 1)
                cyl.radialSegmentCount = 8
                cyl.materials = [em]
                let en = SCNNode(geometry: cyl)
                node.addChildNode(en)
                edges.append((en, cyl, a, b))
            }
            let st = hash(Float(i) * 1.7)
            let axis = simd_normalize(V3(hash(Float(i) + 3) - 0.5, hash(Float(i) + 9) - 0.5, hash(Float(i) + 17) - 0.5))
            spin.addChildNode(node)
            faces.append(Face(node: node, c: c, n: n, axis: axis, stagger: st, edges: edges, edgeMat: em))
        }
    }

    /// build: global time used for the trace-on; explode 0…1; glow multiplier.
    func update(t: Float, color: V3, explode e: Float, glow: Float, spinAngle: Float, flash: Float, scale: Float) {
        spin.simdOrientation = simd_quatf(angle: spinAngle, axis: simd_normalize(V3(0.25, 1, 0.12)))
            * simd_quatf(angle: 0.35, axis: V3(1, 0, 0))
        let bright = mix(color, .one, 0.15 + 0.6 * flash)
        for f in faces {
            // Trace-on: each face draws its three edges in turn.
            let p = seg(t, 0.35 + f.stagger * 1.35, 0.85 + f.stagger * 1.35)
            for (k, edge) in f.edges.enumerated() {
                let q = clamp01(p * 3 - Float(k))
                let d = edge.b - edge.a, L = simd_length(d)
                edge.node.isHidden = q <= 0.001
                edge.cyl.height = CGFloat(L * q)
                edge.node.simdPosition = edge.a + d * (q / 2)
                edge.node.simdOrientation = simd_quatf(from: V3(0, 1, 0), to: d / L)
            }
            let tip = p > 0 && p < 1 ? 1.8 : 0
            f.edgeMat.diffuse.contents = ns(bright)
            f.edgeMat.diffuse.intensity = CGFloat(glow * 3.2 + Float(tip) + flash * 6)
            f.node.opacity = CGFloat(smooth(p * 1.4))
            let out = e * (0.55 + 0.9 * f.stagger)
            f.node.simdPosition = f.c * (1 + out)
            f.node.simdOrientation = simd_quatf(angle: e * 2.2 * (f.stagger - 0.5), axis: f.axis)
        }
        let ignite = easeOut(seg(t, 0.0, 0.9), 2)
        coreMat.diffuse.contents = ns(mix(color, .one, 0.55))
        coreMat.diffuse.intensity = CGFloat((0.6 + 1.6 * glow) * ignite + flash * 4)
        core.simdScale = V3(repeating: 0.25 + 0.75 * ignite)
        haloMat.multiply.contents = ns(color * ((0.35 * glow + 0.6 * flash) * (scale < 0.5 ? 0.25 : 1)))
        coreHaloMat.multiply.contents = ns(mix(color, .one, 0.4) * ((0.9 * ignite + flash) * (scale < 0.5 ? 0.5 : 1)))
        haloMat.readsFromDepthBuffer = scale > 0.5
        coreHaloMat.readsFromDepthBuffer = scale > 0.5
        light.color = ns(color)
        light.intensity = CGFloat(900 * glow * ignite + 2500 * flash)
        light.attenuationEndDistance = CGFloat(4 * scale)
    }
}

// MARK: - Notch / island

func islandPath(w: CGFloat, h: CGFloat, r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let r = min(r, h, w / 2)
    p.move(to: NSPoint(x: -w / 2, y: 0))
    p.line(to: NSPoint(x: -w / 2, y: -h + r))
    p.appendArc(withCenter: NSPoint(x: -w / 2 + r, y: -h + r), radius: r, startAngle: 180, endAngle: 270)
    p.line(to: NSPoint(x: w / 2 - r, y: -h))
    p.appendArc(withCenter: NSPoint(x: w / 2 - r, y: -h + r), radius: r, startAngle: 270, endAngle: 360)
    p.line(to: NSPoint(x: w / 2, y: 0))
    p.close()
    p.flatness = 0.002
    return p
}

func glowMask(w: CGFloat, h: CGFloat, r: CGFloat, pad: CGFloat) -> CGImage {
    let ppu: CGFloat = 120
    let pw = Int((w + 2 * pad) * ppu), ph = Int((h + pad) * ppu)
    let img = bitmap(pw, ph) { c in
        c.setFillColor(.black); c.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        c.setFillColor(.white)
        let rect = CGRect(x: pad * ppu, y: pad * ppu, width: w * ppu, height: (h + 1) * ppu)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: r * ppu, cornerHeight: r * ppu, transform: nil)); c.fillPath()
        // Hollow it so light only escapes around the rim.
        c.setFillColor(CGColor(gray: 0.25, alpha: 1))
        let inner = rect.insetBy(dx: 0.08 * ppu, dy: 0.08 * ppu)
        c.addPath(CGPath(roundedRect: inner, cornerWidth: max(0, r - 0.08) * ppu, cornerHeight: max(0, r - 0.08) * ppu, transform: nil)); c.fillPath()
    }
    return blurred(img, Double(0.16 * ppu))
}

// MARK: - Scene

let scene = SCNScene()
scene.background.contents = NSColor.black
scene.lightingEnvironment.contents = envImage
scene.lightingEnvironment.intensity = 1.2

let camNode = SCNNode()
let cam = SCNCamera()
cam.zNear = 0.05
cam.zFar = 100
cam.wantsHDR = true
cam.bloomIntensity = 1.4
cam.bloomThreshold = 0.75
cam.bloomBlurRadius = 18
cam.bloomIterationCount = 3
cam.bloomIterationSpread = 1.2
cam.wantsExposureAdaptation = false
cam.exposureOffset = 0
cam.vignettingPower = 1.2
cam.vignettingIntensity = 0.9
cam.colorFringeStrength = 0.6
cam.colorFringeIntensity = 0.8
cam.saturation = 1.08
cam.contrast = 0.12
cam.wantsDepthOfField = true
cam.fStop = 2.2
cam.focalBlurSampleCount = 24
camNode.camera = cam
if portrait { cam.projectionDirection = .horizontal }
scene.rootNode.addChildNode(camNode)

let key = SCNLight(); key.type = .directional; key.intensity = 700; key.color = NSColor(white: 0.95, alpha: 1)
let keyNode = SCNNode(); keyNode.light = key; keyNode.simdPosition = V3(-3, 4, 5); keyNode.simdLook(at: .zero)
scene.rootNode.addChildNode(keyNode)
let rim = SCNLight(); rim.type = .directional; rim.intensity = 900
let rimNode = SCNNode(); rimNode.light = rim; rimNode.simdPosition = V3(2, 1, -4); rimNode.simdLook(at: .zero)
scene.rootNode.addChildNode(rimNode)

let pet = Pet()
scene.rootNode.addChildNode(pet.root)

// Dust that turns into bokeh.
var dust: [(node: SCNNode, p: V3, s: Float)] = []
let dustMat = constant(hex(0xBFD8FF), 2.2)
for i in 0..<240 {
    let fi = Float(i)
    let p = V3((hash(fi) - 0.5) * 14, (hash(fi + 0.3) - 0.5) * 7, (hash(fi + 0.7) - 0.5) * 12 - 1)
    let s = SCNSphere(radius: CGFloat(0.006 + 0.012 * hash(fi + 0.9))); s.segmentCount = 6; s.materials = [dustMat]
    let n = SCNNode(geometry: s); scene.rootNode.addChildNode(n)
    dust.append((n, p, hash(fi + 1.3)))
}

// The MacBook display.
let screenZ: Float = -4.5
let screenW: Float = 14, screenH: Float = 8.75
let screenCenterY: Float = -3.2
let topY = screenCenterY + screenH / 2
let display = SCNPlane(width: CGFloat(screenW), height: CGFloat(screenH))
let displayMat = SCNMaterial()
displayMat.lightingModel = .constant
displayMat.diffuse.contents = wallpaperImage
display.materials = [displayMat]
let displayNode = SCNNode(geometry: display)
displayNode.simdPosition = V3(0, screenCenterY, screenZ)
scene.rootNode.addChildNode(displayNode)

let bezel = SCNBox(width: CGFloat(screenW + 0.45), height: CGFloat(screenH + 0.45), length: 0.18, chamferRadius: 0.32)
let bezelMat = SCNMaterial()
bezelMat.lightingModel = .physicallyBased
bezelMat.diffuse.contents = ns(hex(0x050507)); bezelMat.metalness.contents = 0.3; bezelMat.roughness.contents = 0.35
bezel.materials = [bezelMat]
let bezelNode = SCNNode(geometry: bezel)
bezelNode.simdPosition = V3(0, screenCenterY, screenZ - 0.095)
scene.rootNode.addChildNode(bezelNode)
// Aluminium lid behind.
let lid = SCNBox(width: CGFloat(screenW + 0.6), height: CGFloat(screenH + 0.6), length: 0.12, chamferRadius: 0.4)
let lidMat = SCNMaterial(); lidMat.lightingModel = .physicallyBased
lidMat.diffuse.contents = ns(hex(0x8A8E96)); lidMat.metalness.contents = 1; lidMat.roughness.contents = 0.3
lid.materials = [lidMat]
let lidNode = SCNNode(geometry: lid); lidNode.simdPosition = V3(0, screenCenterY, screenZ - 0.25)
scene.rootNode.addChildNode(lidNode)

// Island + rim + glow.
let islandMat = SCNMaterial()
islandMat.lightingModel = .constant
islandMat.diffuse.contents = NSColor.black; islandMat.metalness.contents = 0.0; islandMat.roughness.contents = 0.2
let islandNode = SCNNode(); islandNode.categoryBitMask = 2; bezelNode.categoryBitMask = 2; islandNode.simdPosition = V3(0, topY, screenZ + 0.04)
scene.rootNode.addChildNode(islandNode)
let rimMat = constant(.one, 2.2)
rimMat.diffuse.contents = spectrumImage
rimMat.diffuse.wrapS = .repeat
let rimShapeNode = SCNNode(); rimShapeNode.simdPosition = V3(0, topY, screenZ + 0.02)
scene.rootNode.addChildNode(rimShapeNode)
let glowPlane = SCNPlane(width: 1, height: 1)
let glowMat = SCNMaterial()
glowMat.lightingModel = .constant
glowMat.diffuse.contents = spectrumImage
glowMat.diffuse.wrapS = .repeat
glowMat.blendMode = .add
glowMat.writesToDepthBuffer = false
glowPlane.materials = [glowMat]
let glowNode = SCNNode(geometry: glowPlane)
scene.rootNode.addChildNode(glowNode)

// Island contents: greeting + level bars.
let label = SCNText(string: "Hi, I’m pet", extrusionDepth: 0)
label.font = NSFont.systemFont(ofSize: 1, weight: .semibold)
label.flatness = 0.005
let labelMat = constant(V3(repeating: 0.95), 1.1)
label.materials = [labelMat]
let labelNode = SCNNode(geometry: label)
scene.rootNode.addChildNode(labelNode)
var bars: [(SCNNode, SCNCapsule)] = []
let barMat = constant(hex(0x4DFFA6), 2.4)
for _ in 0..<5 {
    let c = SCNCapsule(capRadius: 0.028, height: 0.1); c.materials = [barMat]
    let n = SCNNode(geometry: c); scene.rootNode.addChildNode(n); bars.append((n, c))
}
// Docking ripple.
let ring = SCNTorus(ringRadius: 0.3, pipeRadius: 0.006)
let ringMat = constant(hex(0x4DFFA6), 3, add: true)
ring.materials = [ringMat]
let ringNode = SCNNode(geometry: ring)
ringNode.simdOrientation = simd_quatf(angle: .pi / 2, axis: V3(1, 0, 0))
scene.rootNode.addChildNode(ringNode)

// MARK: - Timeline

let notchW: Float = 1.85, notchH: Float = 0.34, notchR: Float = 0.11
let islW: Float = 3.7, islH: Float = 0.66, islR: Float = 0.33
let slot = V3(-islW / 2 + islH / 2 + 0.06, topY - islH / 2, screenZ + 0.25)
let slotScale: Float = 0.21

let C_CYAN = hex(0x2EE6FF), C_VIOLET = hex(0xA35BFF), C_PINK = hex(0xFF4FC3), C_BLUE = hex(0x6FB7FF), C_GREEN = hex(0x4DFFA6)

func petColor(_ t: Float) -> V3 {
    ramp(t, [(0, C_CYAN), (2.6, C_CYAN), (3.15, C_VIOLET), (3.6, C_PINK), (4.4, C_BLUE), (5.6, C_BLUE), (6.3, C_GREEN)])
}

func explodeAmount(_ t: Float) -> Float {
    if t < 2.55 { return 0 }
    if t < 3.45 { return 0.7 * easeOut(seg(t, 2.55, 3.05), 4) + 0.08 * seg(t, 3.05, 3.45) }
    return 0.78 * (1 - easeIn(seg(t, 3.45, 3.72), 3))
}

func flashAmount(_ t: Float) -> Float {
    let snap = exp(-pow((t - 3.74) / 0.07, 2)) + 0.4 * exp(-max(0, t - 3.74) * 6) * (t > 3.74 ? 1 : 0)
    let dock = 0.6 * exp(-pow((t - 6.32) / 0.08, 2))
    return snap + dock
}

/// Camera: orbit around the pet first, then a spline out to the display.
func camera(_ t: Float) -> (pos: V3, target: V3, fov: Float, focus: V3) {
    let u = smoother(seg(t, 0, 4.3))
    let a = mix(-1.25, 0.75, u)
    let d = mix(5.6, 4.3, smoother(seg(t, 0, 2.5))) + 1.1 * smooth(seg(t, 2.5, 3.2)) - 0.9 * smooth(seg(t, 3.4, 3.9))
    let h = mix(0.55, -0.55, u) + 0.12 * sin(t * 1.3)
    let orbit = V3(d * sin(a), h, d * cos(a))
    let orbitTarget = V3(0, 0.05, 0)

    let pkeys: [(Float, V3)] = [
        (3.9, orbit), (5.2, V3(4.6, 1.0, 6.2)), (6.35, V3(0.4, 0.3, 0.1)), (7.8, V3(0.05, 0.35, -0.5)), (9.5, V3(0, -1.6, 5.2)),
    ]
    let lkeys: [(Float, V3)] = [
        (3.9, orbit), (5.2, V3(5.2, 1.4, 6.6)), (6.35, V3(0.5, 0.9, -1.4)), (7.8, V3(-0.2, 0.98, -1.7)), (9.5, V3(0, -0.2, 6.2)),
    ]
    let ptkeys: [(Float, V3)] = [
        (3.9, orbitTarget), (5.2, V3(-0.3, -0.9, -2.6)), (6.35, V3(-0.25, topY - 1.05, screenZ)), (7.8, V3(-0.1, topY - 1.0, screenZ)),
        (9.5, V3(0, -2.6, screenZ)),
    ]
    let ltkeys: [(Float, V3)] = [
        (3.9, orbitTarget), (5.2, V3(-0.2, -0.7, -2.6)), (6.35, V3(-0.7, topY - 0.34, screenZ)), (7.8, V3(-0.35, topY - 0.34, screenZ)),
        (9.5, V3(0, topY - 2.6, screenZ)),
    ]
    let keys = portrait ? pkeys : lkeys, tkeys = portrait ? ptkeys : ltkeys
    let b = smooth(seg(t, 3.75, 4.6))
    let pos = mix(orbit, spline(max(t, 3.9), keys), b)
    let target = mix(orbitTarget, spline(max(t, 3.9), tkeys), b)
    let fov = portrait
        ? mix(36, 50, smooth(seg(t, 4.2, 5.2))) + 12 * smooth(seg(t, 5.4, 6.5)) - 4 * smooth(seg(t, 6.5, 7.8)) + 4 * smooth(seg(t, 7.9, 9.3))
        : mix(30, 38, smooth(seg(t, 4.2, 5.2))) - 6 * smooth(seg(t, 5.4, 6.5)) + 14 * smooth(seg(t, 7.9, 9.3))
    let focus = t < 5.9 ? pet.root.simdWorldPosition : mix(pet.root.simdWorldPosition, V3(0, topY - 0.35, screenZ), smooth(seg(t, 7.8, 8.6)))
    return (pos, target, fov, focus)
}

func petTransform(_ t: Float) -> (pos: V3, scale: Float) {
    let f = smoother(seg(t, 5.0, 6.32))
    // Arc: up and over, landing in the island's left slot.
    let p0 = V3(0, 0, 0), p2 = slot, p1 = V3(1.6, 2.2, -1.6)
    let a = mix(p0, p1, f), b = mix(p1, p2, f)
    var pos = mix(a, b, f)
    let hover = 0.06 * sin(t * 2.2) * (1 - f)
    pos.y += hover
    // Breath once docked.
    let s = mix(1, slotScale, easeIn(f, 1.6)) * (1 + 0.04 * sin(t * 3) * smooth(seg(t, 6.5, 7)))
    return (pos, s)
}

func update(_ t: Float) {
    let col = petColor(t)
    let e = explodeAmount(t)
    let fl = flashAmount(t)
    let spinA = 0.35 * t + 2.2 * smoother(seg(t, 2.55, 3.8)) + 1.2 * smooth(seg(t, 5, 6.4))
    let tr = petTransform(t)
    pet.root.simdPosition = tr.pos
    pet.root.simdScale = V3(repeating: tr.scale)
    let glow: Float = 0.55 + 0.35 * seg(t, 2.4, 3.0) - 0.2 * seg(t, 4, 5) + 0.35 * seg(t, 6.1, 6.5)
    pet.update(t: t, color: col, explode: e, glow: glow, spinAngle: spinA, flash: fl, scale: tr.scale)

    // Dust drifts up and fades in.
    let df = smooth(seg(t, 0.3, 2.0)) * (1 - 0.6 * smooth(seg(t, 8.6, 9.4)))
    dustMat.diffuse.intensity = CGFloat(2.2 * df)
    let cpos = camera(t).pos
    for d in dust {
        var p = d.p
        p.y += t * (0.05 + 0.08 * d.s) + 0.4 * e * d.s
        p.x += 0.1 * sin(t * 0.6 + d.s * 9)
        d.node.isHidden = simd_distance(p, cpos) < (t > 5.2 ? 3.2 : 1.6) || (t > 5.2 && p.z > screenZ && p.z < screenZ + 2.5)
        d.node.simdPosition = p
    }

    // Display wakes up after the snap.
    let on = smooth(seg(t, 3.75, 4.9)) * (1 - 0.55 * smooth(seg(t, 8.0, 9.0)))
    displayMat.diffuse.intensity = CGFloat(on)

    // Notch → island.
    let g = spring(seg(t, 5.75, 7.4) * 1.65, damping: 5.5, freq: 9)
    let w = mix(notchW, islW, g), h = mix(notchH, islH, g), r = mix(notchR, islR, smooth(seg(t, 5.75, 6.3)))
    let shape = SCNShape(path: islandPath(w: CGFloat(w), h: CGFloat(h), r: CGFloat(r)), extrusionDepth: 0.06)
    shape.chamferRadius = 0.01
    shape.materials = [islandMat]
    islandNode.geometry = shape
    let rg: Float = 0.022
    let rimShape = SCNShape(path: islandPath(w: CGFloat(w + 2 * rg), h: CGFloat(h + rg), r: CGFloat(r + rg)), extrusionDepth: 0.01)
    rimShape.materials = [rimMat]
    rimShapeNode.geometry = rimShape
    let rimOn = smooth(seg(t, 5.7, 6.1)) * (1 - 0.45 * smooth(seg(t, 7.0, 7.8)))
    rimShapeNode.isHidden = rimOn < 0.01
    rimMat.diffuse.intensity = CGFloat(3.2 * rimOn)
    let flow = SCNMatrix4MakeTranslation(CGFloat(t * 0.45), 0, 0)
    rimMat.diffuse.contentsTransform = SCNMatrix4Scale(flow, 0.6, 1, 1)

    let pad: Float = 0.55
    glowPlane.width = CGFloat(w + 2 * pad); glowPlane.height = CGFloat(h + pad)
    glowNode.simdPosition = V3(0, topY - (h + pad) / 2, screenZ + 0.01)
    glowMat.multiply.contents = glowMask(w: CGFloat(w), h: CGFloat(h), r: CGFloat(r), pad: CGFloat(pad))
    glowMat.diffuse.contentsTransform = SCNMatrix4MakeTranslation(CGFloat(t * 0.45), 0, 0)
    glowMat.diffuse.intensity = CGFloat(2.4 * rimOn + 0.3 * on)

    // Content inside the island.
    let ci = smooth(seg(t, 6.35, 6.9))
    let (lmin, lmax) = label.boundingBox
    let ls: Float = 0.2
    labelNode.simdScale = V3(repeating: ls)
    let lh = Float(lmax.y - lmin.y) * ls
    labelNode.simdPosition = V3(-islW / 2 + islH + 0.12, topY - islH / 2 - lh / 2 - Float(lmin.y) * ls + 0.01 + 0.06 * (1 - ci), screenZ + 0.08)
    labelNode.opacity = CGFloat(ci * smooth(seg(t, 0, 7.4) * 2 - 1 + 1) )
    labelMat.diffuse.intensity = CGFloat(0.8 * ci)
    for (i, (n, c)) in bars.enumerated() {
        let fi = Float(i)
        let lvl = 0.35 + 0.65 * abs(sin(t * (5.5 + fi * 1.3) + fi * 1.7)) * (0.6 + 0.4 * sin(t * 2.1 + fi))
        c.height = CGFloat(max(0.057, 0.3 * lvl * ci))
        n.simdPosition = V3(islW / 2 - islH / 2 - 0.3 + fi * 0.085, topY - islH / 2, screenZ + 0.08)
        n.opacity = CGFloat(ci)
    }
    barMat.diffuse.contents = ns(mix(C_GREEN, hex(0x7DF9FF), 0.5 + 0.5 * sin(t * 2)))

    let rp = seg(t, 6.3, 7.1)
    ringNode.isHidden = rp <= 0 || rp >= 1
    ringNode.simdPosition = slot
    ringNode.simdScale = V3(repeating: 0.45 + 0.9 * easeOut(rp, 3))
    ringMat.diffuse.intensity = CGFloat(3 * (1 - rp) * (1 - rp))
    ringNode.simdOrientation = simd_quatf(angle: .pi / 2, axis: V3(1, 0, 0))

    // Camera.
    let c = camera(t)
    camNode.simdPosition = c.pos
    camNode.simdLook(at: c.target, up: V3(0, 1, 0), localFront: V3(0, 0, -1))
    // Gentle dutch tilt during the orbit.
    camNode.simdOrientation = camNode.simdOrientation * simd_quatf(angle: 0.06 * sin(t * 0.9) * (1 - smooth(seg(t, 5.5, 6.5))), axis: V3(0, 0, 1))
    cam.fieldOfView = CGFloat(c.fov)
    cam.focusDistance = CGFloat(simd_distance(c.pos, c.focus))
    cam.fStop = CGFloat(t < 5 ? 0.45 : mix(0.45, 2.5, smooth(seg(t, 5, 6.3))) + 6 * smooth(seg(t, 8, 9)))
    cam.bloomIntensity = CGFloat(1.3 + 1.5 * flashAmount(t))
    cam.exposureOffset = CGFloat(-0.15 + 0.3 * flashAmount(t))
}

// MARK: - Title overlay (2D)

func drawTitle(_ ctx: CGContext, _ t: Float) {
    let a = smooth(seg(t, 8.85, 9.45))
    guard a > 0 else { return }
    let cx = CGFloat(W) / 2, cy = CGFloat(H) / 2 - 10
    let track = CGFloat(40 * (1 - easeOut(seg(t, 8.75, 9.9), 3)))
    func line(_ s: String, size: CGFloat, weight: NSFont.Weight, kern: CGFloat) -> CTLine {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .kern: kern])
        return CTLineCreateWithAttributedString(attr)
    }
    let title = line("NotchIsland", size: portrait ? 118 : 128, weight: .bold, kern: -2 + track)
    let tb = CTLineGetBoundsWithOptions(title, .useOpticalBounds)
    let rise = CGFloat(30 * (1 - easeOut(seg(t, 8.85, 9.7), 3)))
    ctx.saveGState()
    ctx.setAlpha(CGFloat(a))
    // Soft dark backing so the type pops off the wallpaper.
    let back = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(back, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: 700, options: [])
    // Gradient title.
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: cx - tb.width / 2 - tb.minX, y: cy - rise)
    ctx.setTextDrawingMode(.clip)
    CTLineDraw(title, ctx)
    let sweep = CGFloat(t - 8) * 300
    let cols: [UInt32] = [0x7DF9FF, 0x6FB7FF, 0xB58CFF, 0xFF7AD9, 0x7DF9FF]
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: cols.map { ns(hex($0)).cgColor } as CFArray,
                       locations: [0, 0.3, 0.55, 0.8, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: cx - tb.width / 2 - 200 + sweep, y: 0), end: CGPoint(x: cx + tb.width / 2 + sweep, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    // Subtitle.
    let sa = smooth(seg(t, 9.15, 9.65))
    let sub = line("meet  pet.", size: 44, weight: .medium, kern: 1 + track * 0.3)
    let sbb = CTLineGetBoundsWithOptions(sub, .useOpticalBounds)
    ctx.setAlpha(CGFloat(a * sa))
    ctx.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
    ctx.textPosition = CGPoint(x: cx - sbb.width / 2 - sbb.minX, y: cy - 90 - rise * 0.6)
    ctx.setTextDrawingMode(.fill)
    let subAttr = NSAttributedString(string: "meet  pet.", attributes: [
        .font: NSFont.systemFont(ofSize: 44, weight: .medium), .kern: 1 + track * 0.3,
        .foregroundColor: NSColor(white: 1, alpha: 0.78),
    ])
    CTLineDraw(CTLineCreateWithAttributedString(subAttr), ctx)
    _ = sub
    ctx.restoreGState()
}

func fadeToBlack(_ ctx: CGContext, _ t: Float) {
    let k = max(1 - smooth(seg(t, 0, 0.25)), smooth(seg(t, DUR - 0.25, DUR)))
    guard k > 0 else { return }
    ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(k)))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
}

// MARK: - Render

let device = MTLCreateSystemDefaultDevice()!
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = camNode

func frame(_ t: Float) -> CGImage {
    update(t)
    let img = renderer.snapshot(atTime: TimeInterval(t), with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
    var r = CGRect(x: 0, y: 0, width: W, height: H)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    return bitmap(W, H) { c in
        c.interpolationQuality = .high
        c.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        drawTitle(c, t)
        fadeToBlack(c, t)
    }
}

let args = CommandLine.arguments.filter { $0 != "--portrait" }
if args.count >= 4, args[1] == "--stills" {
    let dir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for s in args[3].split(separator: ",") {
        let t = Float(s)!
        let img = frame(t)
        let rep = NSBitmapImageRep(cgImage: img)
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(String(format: "t%05.2f.png", t)))
        print("still", t)
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "pet-notch-teaser.mp4")
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 28_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
])
audioIn.expectsMediaDataInRealTime = false
writer.add(audioIn)
print("synthesising audio…")
let pcm = soundtrack(duration: DUR, petStagger: pet.faces.map(\.stagger))
var asbd = AudioStreamBasicDescription(mSampleRate: Float64(SR), mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                       mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
var audioFmt: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                               formatDescriptionOut: &audioFmt)
var audioPos = 0  // frames written
var audioDone = false
func pushAudio(upTo seconds: Float, block wait: Bool = false) {
    let totalFrames = pcm.count / 2
    let limit = min(totalFrames, Int(seconds * Float(SR)))
    while audioPos < limit {
        let frames = min(4800, totalFrames - audioPos)
        if !audioIn.isReadyForMoreMediaData { if wait { usleep(1000); continue } else { return } }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        pcm.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + audioPos * 4, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: audioFmt!, sampleCount: frames,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(audioPos), timescale: CMTimeScale(SR)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        audioIn.append(sb!)
        audioPos += frames
    }
    // Finish the audio track as soon as it is all in, or the writer keeps waiting for more and stalls the video.
    if audioPos >= totalFrames && !audioDone { audioIn.markAsFinished(); audioDone = true }
}
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let total = Int(DUR * Float(FPS))
for i in 0..<total {
    let t = Float(i) / Float(FPS)
    let img = frame(t)
    while !input.isReadyForMoreMediaData { pushAudio(upTo: t + 1.0); usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    CVPixelBufferUnlockBaseAddress(buf, [])
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
    if i % 60 == 0 { print("frame \(i)/\(total)") }
    pushAudio(upTo: t + 0.5)
}
pushAudio(upTo: DUR + 1, block: true)
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print("done:", writer.status == .completed ? out.path : "failed \(String(describing: writer.error))")
