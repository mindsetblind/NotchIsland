import AppKit
import NotchIslandCore
import SceneKit
import SwiftUI
import simd

// The pet as a small glowing icosahedron (SceneKit). Twenty dark metal faces with thin gaps, glowing
// edges and a light core; colour, glow and motion tell the mood. Everything is driven from one
// per-frame `step` on SceneKit's render thread; inputs come from the main thread under a lock.

/// What the island tells the pet besides its mood.
struct IcosaInput: Equatable {
    var mood: PetMood = .idle
    /// 0…1 lights the faces one by one (pomodoro); nil = no progress.
    var progress: Double? = nil
    /// Claude Code sessions in progress — each one is a small satellite.
    var agents: Int = 0
    /// A build/agent is running (the cat wore glasses): a scanning band over the faces.
    var scan: Bool = false
    var season: PetSeasonHat? = nil
    var reduceMotion: Bool = false
    var motif: IcosaMotif = .none
}

/// A habit the pet shows on top of its mood — used where it stands for a tab of the island.
enum IcosaMotif: Equatable {
    case none
    /// Clipboard: a copy rolls over it from the top every couple of seconds.
    case ripple
    /// Tools: now and then it comes apart and snaps back together, like being built.
    case build
}

private typealias V3 = SIMD3<Float>

private func hex(_ h: UInt32) -> V3 { V3(Float((h >> 16) & 0xFF), Float((h >> 8) & 0xFF), Float(h & 0xFF)) / 255 }
private func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
private func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }
private func ease(_ x: Float) -> Float { x * x * (3 - 2 * x) }
private func pulse(_ x: Float) -> Float { exp(-(x * x) / 0.0035) }
private func noise(_ n: Float) -> Float { let s = sin(n * 127.1 + 311.7) * 43758.5453; return s - floor(s) }
private func nsColor(_ c: V3) -> NSColor {
    NSColor(srgbRed: CGFloat(max(0, c.x)), green: CGFloat(max(0, c.y)), blue: CGFloat(max(0, c.z)), alpha: 1)
}
private func hsl(_ h: Float, _ s: Float, _ l: Float) -> V3 {
    func f(_ n: Float) -> Float {
        let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
        let a = s * min(l, 1 - l)
        return l - a * max(-1, min(k - 3, min(9 - k, 1)))
    }
    return V3(f(0), f(8), f(4))
}
private let white = V3(1, 1, 1)

private enum FX { case glint, scan, att, bounce, beat, chew, trem, wake, listen, think, present, glitch }

/// How a mood looks: colour (nil = slowly cycling hue), spin speed, glow, how far faces stand apart…
private struct Look {
    var color: UInt32?
    var spin: Float
    var glow: Float
    var ex: Float = 0
    var br: Float = 0, brT: Float = 1
    var y: Float = 0, tilt: Float = 0, sc: Float = 1
    var fx: Set<FX> = []
    var alert: Bool { fx.contains(.att) || fx.contains(.trem) }

    static func of(_ mood: PetMood) -> Look {
        switch mood {
        case .idle: return Look(color: 0x8FD3FF, spin: 0.25, glow: 0.55, br: 0.025, brT: 4, fx: [.glint])
        case .working: return Look(color: 0x2EE6FF, spin: 1.1, glow: 0.85, ex: 0.02, fx: [.scan])
        case .attention: return Look(color: 0xFFB23E, spin: 0, glow: 0.7, fx: [.att])
        case .happy: return Look(color: 0x4DFFA6, spin: 0.7, glow: 0.85, ex: 0.01, fx: [.bounce])
        case .sleeping: return Look(color: 0x5B5BFF, spin: 0.05, glow: 0.2, ex: -0.025, br: 0.04, brT: 6, y: -0.08)
        case .dancing: return Look(color: nil, spin: 0.9, glow: 0.85, fx: [.beat])
        case .hungry: return Look(color: 0xB57BFF, spin: 0.3, glow: 0.7, ex: 0.1, br: 0.02, brT: 1.5)
        case .gaping: return Look(color: 0xC68CFF, spin: 0.15, glow: 0.95, ex: 0.3)
        case .munching: return Look(color: 0xC68CFF, spin: 0.3, glow: 0.8, fx: [.chew])
        case .full: return Look(color: 0x9F7BFF, spin: 0.2, glow: 0.6, br: 0.03, brT: 2.5, sc: 1.1)
        case .scared: return Look(color: 0xFF4058, spin: 0.1, glow: 0.75, ex: -0.04, sc: 0.8, fx: [.trem])
        case .sad: return Look(color: 0x6F87A8, spin: 0.08, glow: 0.28, br: 0.02, brT: 5, y: -0.18, tilt: 0.35)
        case .failed: return Look(color: 0x6F87A8, spin: 0.08, glow: 0.28, br: 0.02, brT: 5, y: -0.18, tilt: 0.35, fx: [.glitch])
        case .waking: return Look(color: 0x8FD3FF, spin: 0.2, glow: 0.6, fx: [.wake])
        case .listening: return Look(color: 0xE6F0FF, spin: 0.15, glow: 0.7, ex: 0.02, fx: [.listen])
        case .thinking: return Look(color: 0xA88BFF, spin: 0.04, glow: 0.55, fx: [.think])
        case .presenting: return Look(color: 0x7DFFC4, spin: 0.12, glow: 0.9, fx: [.present])
        }
    }
}

// MARK: - Geometry

private let phi: Float = (1 + Float(5).squareRoot()) / 2
private let icoVerts: [V3] = [
    V3(-1, phi, 0), V3(1, phi, 0), V3(-1, -phi, 0), V3(1, -phi, 0),
    V3(0, -1, phi), V3(0, 1, phi), V3(0, -1, -phi), V3(0, 1, -phi),
    V3(phi, 0, -1), V3(phi, 0, 1), V3(-phi, 0, -1), V3(-phi, 0, 1),
].map { simd_normalize($0) }
private let icoFaces: [[Int]] = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
]
/// The vertex that faces you when the pet pays attention.
private let frontVertex = icoVerts[5]

private func triangle(_ v: [V3]) -> SCNGeometry {
    let n = simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0]))
    let pos = SCNGeometrySource(vertices: v.map { SCNVector3($0) })
    let nor = SCNGeometrySource(normals: Array(repeating: SCNVector3(n), count: 3))
    let el = SCNGeometryElement(indices: [UInt16(0), 1, 2], primitiveType: .triangles)
    return SCNGeometry(sources: [pos, nor], elements: [el])
}

private func solidIcosahedron(radius: Float) -> SCNGeometry {
    var pos: [SCNVector3] = [], nor: [SCNVector3] = []
    for f in icoFaces {
        let v = f.map { icoVerts[$0] * radius }
        let n = simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0]))
        pos += v.map { SCNVector3($0) }
        nor += Array(repeating: SCNVector3(n), count: 3)
    }
    let el = SCNGeometryElement(indices: (0..<UInt16(pos.count)).map { $0 }, primitiveType: .triangles)
    return SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)], elements: [el])
}

private func wireIcosahedron(radius: Float) -> SCNGeometry {
    var edges = Set<[Int]>()
    for f in icoFaces { for k in 0..<3 { edges.insert([f[k], f[(k + 1) % 3]].sorted()) } }
    let pos = SCNGeometrySource(vertices: icoVerts.map { SCNVector3($0 * radius) })
    let el = SCNGeometryElement(indices: edges.flatMap { $0.map(UInt16.init) }, primitiveType: .line)
    return SCNGeometry(sources: [pos], elements: [el])
}

private func additive(_ m: SCNMaterial) -> SCNMaterial {
    m.lightingModel = .constant
    m.blendMode = .add
    m.writesToDepthBuffer = false
    return m
}

/// Soft halo around an edge: brightest where the tube faces you, fading to its sides.
private let glowShader = """
#pragma body
float k = pow(abs(dot(_surface.normal, _surface.view)), 3.0);
_output.color = float4(_surface.diffuse.rgb * k, 1.0);
"""

/// Open tubes along the given segments, as one mesh (radial normals for the glow falloff).
private func tubes(_ segs: [(V3, V3)], radius r: Float, sides: Int = 6) -> (SCNGeometrySource, SCNGeometrySource, SCNGeometryElement) {
    var pos: [SCNVector3] = [], nor: [SCNVector3] = [], idx: [UInt16] = []
    for (a, b) in segs {
        let d = simd_normalize(b - a)
        let u = simd_normalize(simd_cross(d, abs(d.y) < 0.9 ? V3(0, 1, 0) : V3(1, 0, 0)))
        let w = simd_cross(d, u)
        let base = UInt16(pos.count)
        for i in 0..<sides {
            let ang = Float(i) / Float(sides) * 2 * .pi
            let nn = u * cos(ang) + w * sin(ang)
            pos += [SCNVector3(a + nn * r), SCNVector3(b + nn * r)]
            nor += [SCNVector3(nn), SCNVector3(nn)]
        }
        for i in 0..<sides {
            let i0 = base + UInt16(i * 2), i1 = base + UInt16(((i + 1) % sides) * 2)
            idx += [i0, i1, i0 + 1, i1, i1 + 1, i0 + 1]
        }
    }
    return (SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor), SCNGeometryElement(indices: idx, primitiveType: .triangles))
}

/// One face: a dark triangle, its glowing edges and their halo — one node, one geometry with three parts.
private final class Face {
    let node = SCNNode()
    let mat: SCNMaterial
    let lineMat: SCNMaterial
    let glowMat: SCNMaterial
    let lv: [V3]
    let cen: V3, n: V3, idx: Int, stagger: Float
    var rank = 0
    var netPos = V3.zero
    var qNet = simd_quatf(angle: 0, axis: V3(0, 1, 0))
    var lift: Float = 0, flash: Float = 0
    var glitchOff = V3.zero
    // Last values handed to SceneKit (skip the update when nothing visible changed).
    var shown = SIMD4<Float>(-1, -1, -1, -1), shownLine = V3(-1, -1, -1), shownGlow = V3(-1, -1, -1)

    init(index: Int, verts v: [V3]) {
        idx = index
        stagger = noise(Float(index))
        let c = (v[0] + v[1] + v[2]) / 3
        cen = c
        n = simd_normalize(c)
        lv = v.map { $0 - c }
        mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(srgbRed: 0x11 / 255, green: 0x14 / 255, blue: 0x19 / 255, alpha: 1)
        mat.metalness.contents = 0.7
        mat.roughness.contents = 0.32
        mat.isDoubleSided = true
        lineMat = additive(SCNMaterial())
        glowMat = additive(SCNMaterial())
        glowMat.shaderModifiers = [.fragment: glowShader]
        node.simdPosition = cen
        node.simdScale = V3(repeating: 0.93)
        build(radius: 0.011)
    }

    func build(radius r: Float) {
        let edges = (0..<3).map { (lv[$0], lv[($0 + 1) % 3]) }
        let nrm = simd_normalize(simd_cross(lv[1] - lv[0], lv[2] - lv[0]))
        let line = tubes(edges, radius: r)
        let glow = tubes(edges, radius: r * 4.5, sides: 8)
        // Triangle vertices go after the tube vertices so every part shares one vertex buffer.
        var pos: [SCNVector3] = [], nor: [SCNVector3] = []
        func extract(_ s: SCNGeometrySource) -> [SCNVector3] {
            s.data.withUnsafeBytes { raw in
                (0..<s.vectorCount).map { i in
                    let o = i * s.dataStride + s.dataOffset
                    return SCNVector3(raw.load(fromByteOffset: o, as: Float.self), raw.load(fromByteOffset: o + 4, as: Float.self),
                                      raw.load(fromByteOffset: o + 8, as: Float.self))
                }
            }
        }
        func indices(_ e: SCNGeometryElement, offset: Int) -> [UInt16] {
            e.data.withUnsafeBytes { raw in (0..<(e.primitiveCount * 3)).map { raw.load(fromByteOffset: $0 * 2, as: UInt16.self) + UInt16(offset) } }
        }
        let triStart = 0
        pos += lv.map { SCNVector3($0) }; nor += Array(repeating: SCNVector3(nrm), count: 3)
        let lineStart = pos.count
        pos += extract(line.0); nor += extract(line.1)
        let glowStart = pos.count
        pos += extract(glow.0); nor += extract(glow.1)
        let tri = SCNGeometryElement(indices: [UInt16(triStart), 1, 2], primitiveType: .triangles)
        let lineEl = SCNGeometryElement(indices: indices(line.2, offset: lineStart), primitiveType: .triangles)
        let glowEl = SCNGeometryElement(indices: indices(glow.2, offset: glowStart), primitiveType: .triangles)
        let parts = [(tri, mat), (lineEl, lineMat), (glowEl, glowMat)]
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)], elements: parts.map(\.0))
        geo.materials = parts.map(\.1)
        node.geometry = geo
    }
}

private struct Satellite {
    let node: SCNNode
    let mat: SCNMaterial
    let lineMat: SCNMaterial
    let phase: Float, speed: Float
    let q: simd_quatf
    let born: Float
    var died: Float?
}

private struct Spark { let a: Float, r: Float, y: Float, s: Float; let node: SCNNode; let mat: SCNMaterial }

// MARK: - Scene

final class IcosaPetScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Units of scene height that fill the view.
    static let visibleHeight: Float = 2.7

    private let root = SCNNode()
    private let spinNode = SCNNode()
    private let core: SCNNode
    private let coreMat = SCNMaterial()
    private let inner: SCNNode
    private let innerMat = SCNMaterial()
    private let rim = SCNLight()
    private var faces: [Face] = []
    private var sats: [Satellite] = []
    private var sparks: [Spark] = []
    private var sparkSeason: PetSeasonHat?

    private let lock = NSLock()
    private var shared = IcosaInput()
    private var sharedRipples: [Int] = []
    private var sharedEntrance = false
    /// The pet may now and then unfold into a flat net and fold back when it has been idle a long time.
    var allowsEasterEgg = false

    // Animated state.
    private var start: Double?
    private var last: Float = 0
    private var col = hex(0x8FD3FF)
    private var glow: Float = 0.55, ex: Float = 0, spin: Float = 0.25, yOff: Float = 0, scl: Float = 1, tilt: Float = 0
    private var att: Float = 0, think: Float = 0
    private var rot: Float = 0
    private var mood: PetMood?
    private var moodSince: Float = 0
    private var glitchT0: Float = -99, glitchIDs: [Int] = [], glitchNext: Float = 0
    private var unfoldT0: Float = -99, idleSince: Float = 0, lastUnfold: Float = -1000
    private var appearT0: Float = -99
    private var ripples: [(n: V3, t0: Float)] = []
    private var progPrev: Float = 0, progDone: Float = -99
    private var motifRipple: Float = -99
    private var shake = V3.zero
    private var lineRadius: Float = 0.011
    private var nightFactor: Float = 0, nightChecked: Float = -99

    var input: IcosaInput {
        get { lock.lock(); defer { lock.unlock() }; return shared }
        set { lock.lock(); shared = newValue; lock.unlock() }
    }

    func ripple(face: Int) { lock.lock(); sharedRipples.append(face); lock.unlock() }
    func playEntrance() { lock.lock(); sharedEntrance = true; lock.unlock() }

    override init() {
        let coreGeo = SCNSphere(radius: 0.42)
        coreGeo.segmentCount = 24
        coreMat.lightingModel = .constant
        coreGeo.materials = [coreMat]
        core = SCNNode(geometry: coreGeo)
        let wire = wireIcosahedron(radius: 0.4)
        wire.materials = [additive(innerMat)]
        inner = SCNNode(geometry: wire)
        super.init()

        scene.background.contents = NSColor.clear
        let cam = SCNCamera()
        cam.fieldOfView = 30
        cam.zNear = 0.1
        cam.zFar = 50
        cameraNode.camera = cam
        cameraNode.simdPosition = V3(0, 0, Self.visibleHeight / 2 / tan(15 * .pi / 180))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 150
        scene.rootNode.addChildNode(SCNNode().with { $0.light = ambient })
        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = V3(-2, 3, 4)
        keyNode.simdLook(at: .zero)
        scene.rootNode.addChildNode(keyNode)
        rim.type = .omni
        rim.attenuationStartDistance = 0
        rim.attenuationEndDistance = 8
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.simdPosition = V3(1.5, -1, -2.5)
        scene.rootNode.addChildNode(rimNode)

        scene.rootNode.addChildNode(root)
        root.addChildNode(spinNode)
        root.addChildNode(inner)
        spinNode.addChildNode(core)
        for (i, f) in icoFaces.enumerated() {
            let face = Face(index: i, verts: f.map { icoVerts[$0] })
            spinNode.addChildNode(face.node)
            faces.append(face)
        }
        // Progress lights the faces from the top down, going round.
        let ang: (V3) -> Float = { atan2($0.z, $0.x) }
        faces.sorted { a, b in a.cen.y != b.cen.y ? a.cen.y > b.cen.y : ang(a.cen) < ang(b.cen) }
            .enumerated().forEach { $1.rank = $0 }
        buildNet()
    }

    /// Where each face lies in the flat net: a strip of ten triangles with five above and five below.
    private func buildNet() {
        let L = simd_distance(icoVerts[0], icoVerts[11]), h = L * Float(3).squareRoot() / 2, c = 2.75 * L
        var mid: [[V3]] = [], top: [[V3]] = [], bot: [[V3]] = []
        for k in 0..<10 {
            let x = Float(k) * L / 2 - c
            if k % 2 == 0 {
                mid.append([V3(x, -h / 2, 0), V3(x + L, -h / 2, 0), V3(x + L / 2, h / 2, 0)])
                bot.append([V3(x, -h / 2, 0), V3(x + L / 2, -1.5 * h, 0), V3(x + L, -h / 2, 0)])
            } else {
                mid.append([V3(x, h / 2, 0), V3(x + L / 2, -h / 2, 0), V3(x + L, h / 2, 0)])
                top.append([V3(x, h / 2, 0), V3(x + L, h / 2, 0), V3(x + L / 2, 1.5 * h, 0)])
            }
        }
        let ang: (Face) -> Float = { atan2($0.cen.z, $0.cen.x) }
        let byY = faces.sorted { $0.cen.y > $1.cen.y }
        let groups: [([Face], [[V3]])] = [
            (byY[0..<5].sorted { ang($0) < ang($1) }, top),
            (byY[5..<15].sorted { ang($0) < ang($1) }, mid),
            (byY[15...].sorted { ang($0) < ang($1) }, bot),
        ]
        func basis(_ a: V3, _ b: V3, _ c: V3) -> simd_float3x3 {
            let e1 = simd_normalize(b - a)
            let n = simd_normalize(simd_cross(b - a, c - a))
            return simd_float3x3(columns: (e1, simd_cross(n, e1), n))
        }
        for (fs, slots) in groups {
            for (i, f) in fs.enumerated() {
                let tri = slots[i]
                let tc = (tri[0] + tri[1] + tri[2]) / 3
                let src = icoFaces[f.idx].map { icoVerts[$0] - f.cen }
                let R = basis(tri[0] - tc, tri[1] - tc, tri[2] - tc) * basis(src[0], src[1], src[2]).transpose
                f.netPos = tc
                f.qNet = simd_quatf(R)
            }
        }
    }

    /// Edges stay about half a point thick whatever the size of the view.
    func setPointsPerUnit(_ ppu: CGFloat) {
        let r = Float(max(0.011, 0.3 / max(ppu, 1)))
        guard abs(r - lineRadius) > 0.0005 else { return }
        lineRadius = r
        for f in faces { f.build(radius: r) }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) { step(time: time) }

    // MARK: Step

    func step(time: TimeInterval) {
        if start == nil { start = time }
        let t = Float(time - start!)
        let dt = min(0.05, max(0, t - last))
        last = t
        lock.lock()
        let inp = shared
        let newRipples = sharedRipples
        sharedRipples.removeAll()
        let entrance = sharedEntrance
        sharedEntrance = false
        lock.unlock()

        if inp.mood != mood {
            mood = inp.mood
            moodSince = t
            if inp.mood == .failed {
                glitchT0 = t
                glitchIDs = (0..<4).map { _ in Int.random(in: 0..<20) }
            }
            if inp.mood != .idle { idleSince = t }
        }
        if entrance { appearT0 = t }
        for i in newRipples where faces.indices.contains(i) { ripples.append((faces[i].n, t)) }
        if inp.motif == .ripple, t - motifRipple > 2.2 {
            motifRipple = t
            ripples.append((V3(0, 1, 0), t))
        }
        ripples.removeAll { t - $0.t0 > 1.4 }

        let M = Look.of(inp.mood), age = t - moodSince
        let L = 1 - pow(0.02, dt)
        let calm: Float = M.alert ? 0 : 1
        let rm = inp.reduceMotion

        // Colour: the mood's own, warmer and dimmer at night, icier in winter.
        var tc = M.color.map(hex) ?? hsl((t * 0.12).truncatingRemainder(dividingBy: 1), 0.85, 0.62)
        if M.fx.contains(.wake) { let k = min(1, age / 2.2); tc = mix(hex(0x5B5BFF), hex(0x8FD3FF), k * k) }
        if t - nightChecked > 30 {
            nightChecked = t
            let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let hr = Float(comps.hour ?? 12) + Float(comps.minute ?? 0) / 60
            nightFactor = hr < 5 ? 1 : hr < 8 ? 1 - (hr - 5) / 3 : hr < 19 ? 0 : hr < 22 ? (hr - 19) / 3 : 1
        }
        let nf = nightFactor
        tc = mix(tc, hex(0xFFB07A), 0.28 * nf * calm)
        if inp.season == .beanie || inp.season == .santa { tc = mix(tc, hex(0xDDF3FF), 0.15 * calm) }

        col = mix(col, tc, min(1, L * 1.2))
        glow += (M.glow - glow) * L
        spin += ((rm ? M.spin * 0.3 : M.spin) - spin) * L
        yOff += (M.y - yOff) * L
        tilt += (M.tilt - tilt) * L
        att += ((M.fx.contains(.att) ? 1 : 0) - att) * L * 0.9
        think += ((M.fx.contains(.think) ? 1 : 0) - think) * L

        var exT = M.ex, sc = M.sc, g = glow * (1 - 0.35 * nf * calm), yo: Float = 0
        if M.br > 0 { sc *= 1 + sin(t * 2 * .pi / M.brT) * M.br }
        var bounceP: Float = -1
        if M.fx.contains(.bounce), !rm { bounceP = (t * 1.3).truncatingRemainder(dividingBy: 1); yo += abs(sin(bounceP * .pi)) * 0.16 }
        var beatK: Float = 0
        if M.fx.contains(.beat) { let p = (t * 2).truncatingRemainder(dividingBy: 1); beatK = exp(-p * 6); sc *= 1 + beatK * 0.06; g *= 0.8 + beatK * 0.4 }
        if M.fx.contains(.chew) { let p = (t * 3).truncatingRemainder(dividingBy: 1); exT = max(0, (p < 0.5 ? p : 1 - p) * 0.36 - 0.02) * (rm ? 0.4 : 1) }
        if M.fx.contains(.wake) {
            let k = min(1, age / 2.2)
            sc *= 0.85 + 0.15 * k + (age < 1.2 ? sin(age * .pi / 1.2) * 0.08 : 0)
            g *= 0.4 + 0.6 * k
        }
        var attP: Float = -1
        if M.fx.contains(.att) { attP = age.truncatingRemainder(dividingBy: 1.8); let k = pulse(attP - 0.05) + pulse(attP - 0.3) * 0.8; g += k * 0.5; sc *= 1 + k * 0.035 }
        var amp: Float = 0
        if M.fx.contains(.listen) {
            amp = abs(sin(t * 13.1) * sin(t * 3.7) + 0.5 * sin(t * 23.3)) * 0.75 * (0.55 + 0.45 * sin(t * 1.3))
            g *= 0.85 + amp * 0.4
        }
        let pres: Float = M.fx.contains(.present) ? ease(clamp01(age / 0.6)) : 0
        if inp.motif == .build, !rm {
            // Apart for a moment every 3 s, then a snap back with a little flash.
            let p = t.truncatingRemainder(dividingBy: 3) / 3
            exT += p < 0.35 ? sin(p / 0.35 * .pi) * 0.22 : 0
            if p > 0.33 && p < 0.42 { g += (1 - abs(p - 0.375) / 0.045) * 0.4 }
        }
        let prog = Float(inp.progress ?? 0)
        if prog >= 1 && progPrev < 1 { progDone = t }
        progPrev = prog

        // Easter egg: long idle → unfold into the flat net and fold back.
        if allowsEasterEgg, inp.mood == .idle, !rm, t - idleSince > 180, t - lastUnfold > 420 { unfoldT0 = t; lastUnfold = t }
        let ua = t - unfoldT0
        let uK: Float = ua < 0 ? 0 : ua < 2.2 ? ease(ua / 2.2) : ua < 3.8 ? 1 : ua < 6 ? 1 - ease((ua - 3.8) / 2.2) : 0

        let ga = t - glitchT0
        let gOn = ga >= 0 && ga < 0.6
        if gOn && t > glitchNext {
            glitchNext = t + 0.06
            for i in glitchIDs { faces[i].glitchOff = V3(.random(in: -0.125...0.125), .random(in: -0.1...0.1), .random(in: -0.05...0.05)) }
        }
        let va = t - appearT0
        let appearing = va >= 0 && va < 1.5

        ex += (exT - ex) * min(1, L * (M.fx.contains(.chew) ? 6 : 1.6))
        scl += (sc - scl) * min(1, L * (M.fx.contains(.beat) ? 6 : 2))

        // Orientation: a slow tumble, turned to you for attention.
        rot += spin * dt * (1 - att) * (1 - uK)
        let qE = simd_quatf(angle: 0.35 + sin(t * 0.4) * 0.12, axis: V3(1, 0, 0)) * simd_quatf(angle: rot, axis: V3(0, 1, 0))
        let wobble = simd_quatf(angle: sin(t * 0.9) * 0.05, axis: V3(1, 0, 0)) * simd_quatf(angle: sin(t * 0.7) * 0.08, axis: V3(0, 1, 0))
        let qA = wobble * simd_quatf(from: frontVertex, to: V3(0, 0, 1))
        let identity = simd_quatf(angle: 0, axis: V3(0, 1, 0))
        var q = simd_slerp(qE, qA, att)
        q = simd_slerp(q, identity, uK)
        spinNode.simdOrientation = q

        if M.fx.contains(.trem) && !rm {
            shake = V3(.random(in: -0.016...0.016), .random(in: -0.016...0.016), 0)
        } else { shake *= 0.8 }
        let gx: Float = gOn ? Float(Int.random(in: -1...1)) * 0.03 : 0
        root.simdPosition = V3(shake.x + gx, yOff + yo + shake.y + (rm ? 0 : sin(t * 1.1) * 0.03 * (1 - uK)), 0)
        root.simdOrientation = simd_quatf(angle: tilt * 0.4 * (1 - uK), axis: V3(0, 0, 1))
        root.simdScale = V3(repeating: scl * (1 - 0.42 * uK))

        // Faces.
        let gl = floor(t / 2.6)
        let red = hex(0xFF3040)
        for f in faces {
            let wn = q.act(f.n)
            var lift: Float = 0, flash: Float = 0
            if M.fx.contains(.glint) {
                for j in [gl, gl - 1] where Int(noise(j) * 20) == f.idx || Int(noise(j + 0.5) * 20) == f.idx {
                    let a = t - j * 2.6
                    if a >= 0 && a < 1.4 { let e = sin(a / 1.4 * .pi); lift += e * 0.045; flash += e * 0.6 }
                }
            }
            if M.fx.contains(.scan) || inp.scan { let w = pow(max(0, sin(wn.y * 3 - t * 5)), 2); lift += w * 0.025; flash += w * 0.7 }
            if M.fx.contains(.att) {
                let d = acos(max(-1, min(1, wn.z))) / .pi
                let k = pulse(attP - 0.05 - d * 0.28) + pulse(attP - 0.3 - d * 0.28) * 0.8
                lift += k * 0.08; flash += k * 1.6
            }
            if bounceP >= 0 { let d = (wn.y + 1) / 2; let k = pulse(bounceP - 0.02 - d * 0.18); lift += k * 0.05; flash += k * 0.8 }
            if M.fx.contains(.beat) { lift += beatK * 0.06 * (0.5 + 0.5 * noise(Float(f.idx))); flash += beatK * 0.5 }
            if M.fx.contains(.listen) { let h2 = noise(Float(f.idx) * 3.1 + floor(t * 14)); lift += amp * 0.055 * h2; flash += amp * 0.7 * h2 }
            if M.fx.contains(.think) {
                let a = atan2(wn.x, wn.z)
                flash += pow(max(0, cos(a - t * 3)), 8) * 0.5 * max(0, 1 - abs(wn.y) * 1.4)
            }
            if pres > 0 { let k = max(0, f.n.y); lift += k * 0.14 * pres; flash += k * 0.55 * pres }
            for r in ripples {
                let a = t - r.t0
                let d = acos(max(-1, min(1, simd_dot(f.n, r.n))))
                let k = exp(-pow(a * 2.6 - d, 2) / 0.05) * (1 - a / 1.4)
                lift += k * 0.07; flash += k * 1.3
            }
            var litK: Float = 1
            if prog > 0 { litK = clamp01(prog * 20 - Float(f.rank)); flash += litK * 0.55 }
            if t - progDone < 1.2 { let d = (1 - f.cen.y) / 2; let k = pulse(t - progDone - 0.05 - d * 0.35); lift += k * 0.07; flash += k * 2 }
            if rm { lift *= 0.3 }
            f.lift += (lift - f.lift) * min(1, dt * 18)
            f.flash += (flash - f.flash) * min(1, dt * 18)

            var vS: Float = 1, vOff: Float = 0
            if appearing { let e = clamp01((va - f.stagger * 0.5) / 0.75); let o = 1 - pow(1 - e, 3); vS = o; vOff = (1 - o) * 2.6 }
            let isGlitch = gOn && glitchIDs.contains(f.idx)
            var pos = f.cen + f.n * (ex + f.lift + vOff)
            if isGlitch { pos += f.glitchOff }
            if uK > 0 {
                pos = mix(pos, f.netPos, uK)
                f.node.simdOrientation = simd_slerp(identity, f.qNet, uK)
            } else {
                f.node.simdOrientation = identity
            }
            f.node.simdPosition = pos
            f.node.simdScale = V3(repeating: 0.93 * max(0.0001, vS))

            let fc = isGlitch ? red : col
            let fl = f.flash + (isGlitch ? 1.5 : 0)
            let em = SIMD4<Float>(fc, (0.035 + fl * 0.32) * max(g, 0.35))
            if simd_reduce_max(simd_abs(em - f.shown)) > 0.004 {
                f.shown = em
                f.mat.emission.contents = nsColor(fc)
                f.mat.emission.intensity = CGFloat(em.w)
            }
            let lineOp = (0.35 + g * 0.55) * (prog > 0 ? 0.4 + 0.6 * litK : 1)
            let lc = mix(fc, white, min(0.6, fl * 0.4)) * lineOp
            if simd_reduce_max(simd_abs(lc - f.shownLine)) > 0.004 { f.shownLine = lc; f.lineMat.diffuse.contents = nsColor(lc) }
            let gc = fc * (0.18 + g * 0.42) * (1 + fl * 0.8) * (prog > 0 ? 0.35 + 0.65 * litK : 1)
            if simd_reduce_max(simd_abs(gc - f.shownGlow)) > 0.004 { f.shownGlow = gc; f.glowMat.diffuse.contents = nsColor(gc) }
        }

        // Core and the spinning wire inside it while thinking.
        var coreS = (0.72 + g * 0.3 + ex * 0.8) * (1 - 0.45 * think) * (1 - uK)
        if appearing { coreS *= clamp01((va - 0.5) / 0.6) }
        core.simdScale = V3(repeating: max(0.0001, coreS))
        let cc: V3 = inp.season == .witch ? hex(0xFF7A1A) : inp.season == .santa ? mix(col, hex(0xFFD27A), 0.6) : col
        coreMat.diffuse.contents = nsColor(mix(cc, white, 0.3))
        innerMat.diffuse.contents = nsColor(mix(col, white, 0.4) * think * 0.9)
        inner.simdOrientation = simd_quatf(angle: t * 3.1 * think, axis: V3(0, 1, 0)) * simd_quatf(angle: t * 2.2 * think, axis: V3(1, 0, 0))
        inner.isHidden = think < 0.01
        rim.color = nsColor(col)
        rim.intensity = CGFloat((1 + g * 2.4) * 450)

        updateSatellites(count: inp.agents, t: t)
        updateSparks(season: inp.season, t: t)
    }

    private func updateSatellites(count: Int, t: Float) {
        let alive = sats.filter { $0.died == nil }.count
        if count > alive {
            for _ in alive..<min(count, 5) {
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                mat.diffuse.contents = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)
                mat.metalness.contents = 0.7
                mat.roughness.contents = 0.3
                let body = solidIcosahedron(radius: 0.15)
                body.materials = [mat]
                let node = SCNNode(geometry: body)
                let lineMat = additive(SCNMaterial())
                let wire = wireIcosahedron(radius: 0.17)
                wire.materials = [lineMat]
                node.addChildNode(SCNNode(geometry: wire))
                root.addChildNode(node)
                sats.append(Satellite(node: node, mat: mat, lineMat: lineMat, phase: .random(in: 0..<(2 * .pi)), speed: .random(in: 0.55...1),
                                      q: simd_quatf(angle: .random(in: 0.25...0.6), axis: V3(1, 0, 0)) * simd_quatf(angle: .random(in: -0.4...0.4), axis: V3(0, 0, 1)),
                                      born: t))
            }
        } else if count < alive {
            var drop = alive - count
            for i in sats.indices.reversed() where drop > 0 && sats[i].died == nil { sats[i].died = t; drop -= 1 }
        }
        sats.removeAll { s in
            if let d = s.died, t - d > 0.6 { s.node.removeFromParentNode(); return true }
            return false
        }
        for s in sats {
            var size = ease(clamp01((t - s.born) / 0.45)), r: Float = 1.3, fl: Float = 0
            if let d = s.died { let k = t - d; r *= 1 + k * 3; size *= 1 - k / 0.6; fl = 1 }
            let a = s.phase + s.speed * t
            s.node.simdPosition = s.q.act(V3(cos(a) * r, 0, sin(a) * r))
            s.node.simdEulerAngles = V3(t * 1.3, t * 0.9, 0)
            s.node.simdScale = V3(repeating: max(0.0001, size))
            s.mat.emission.contents = nsColor(col)
            s.mat.emission.intensity = CGFloat(0.25 + fl * 0.8)
            s.lineMat.diffuse.contents = nsColor(mix(col, white, fl * 0.7 + 0.15))
        }
    }

    /// Seasonal particles instead of hats: snow in winter, embers at Halloween, golden sparks for the holidays.
    private func updateSparks(season: PetSeasonHat?, t: Float) {
        if season != sparkSeason {
            sparkSeason = season
            sparks.forEach { $0.node.removeFromParentNode() }
            sparks = []
            if season != nil {
                for i in 0..<30 {
                    let fi = Float(i)
                    let mat = additive(SCNMaterial())
                    let dot = SCNSphere(radius: 0.045)
                    dot.segmentCount = 6
                    dot.materials = [mat]
                    let node = SCNNode(geometry: dot)
                    root.addChildNode(node)
                    sparks.append(Spark(a: noise(fi + 1) * 2 * .pi, r: 1.25 + noise(fi + 7) * 0.4, y: noise(fi + 13) * 2 - 1, s: noise(fi + 19), node: node, mat: mat))
                }
            }
        }
        guard let season else { return }
        for (i, p) in sparks.enumerated() {
            var pos = V3.zero, c = white
            switch season {
            case .beanie:
                let a = p.a + t * 0.15
                let yy = ((p.y + 1 - t * 0.12 * (0.5 + p.s)).truncatingRemainder(dividingBy: 2) + 2).truncatingRemainder(dividingBy: 2) - 1
                pos = V3(cos(a) * p.r, yy * 1.1, sin(a) * p.r)
                c = V3(0.85, 0.92, 1) * (0.5 + 0.5 * p.s)
            case .witch:
                let life = (t * 0.35 * (0.6 + p.s) + p.s).truncatingRemainder(dividingBy: 1)
                let rr = 0.5 + p.r * 0.5
                pos = V3(cos(p.a) * rr, -1.1 + life * 2.2, sin(p.a) * rr)
                let k = (1 - life) * (0.6 + 0.4 * sin(t * 9 + Float(i)))
                c = V3(1, 0.45, 0.08) * k
            case .santa:
                let a = p.a + t * 0.08
                pos = V3(cos(a) * p.r, p.y * 1.05, sin(a) * p.r)
                let k = pow(max(0, sin(t * (2 + p.s * 3) + p.a * 5)), 8)
                c = V3(1, 0.82, 0.45) * k
            }
            p.node.simdPosition = pos
            p.mat.diffuse.contents = nsColor(c)
        }
    }

    /// Index of the face a scene node belongs to.
    func faceIndex(of node: SCNNode) -> Int? {
        var n: SCNNode? = node
        while let cur = n {
            if let i = faces.firstIndex(where: { $0.node === cur }) { return i }
            n = cur.parent
        }
        return nil
    }
}

private extension SCNNode {
    func with(_ f: (SCNNode) -> Void) -> SCNNode { f(self); return self }
}


// MARK: - View

final class IcosaNSView: SCNView {
    let pet = IcosaPetScene()
    private var lastRipple = Date.distantPast

    init(fps: Int) {
        super.init(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        scene = pet.scene
        pointOfView = pet.cameraNode
        delegate = pet
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = fps
        rendersContinuously = true
        isPlaying = false
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks go to whatever is around the pet (the island, the panel), never to the 3D view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPlaying = window != nil
    }

    override func layout() {
        super.layout()
        pet.setPointsPerUnit(bounds.height / CGFloat(IcosaPetScene.visibleHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { touch(event) }
    override func mouseMoved(with event: NSEvent) { touch(event) }

    /// The cursor brushing the pet sends a ripple across its faces from the touched spot.
    private func touch(_ event: NSEvent) {
        guard Date().timeIntervalSince(lastRipple) > 0.7 else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first,
              let face = pet.faceIndex(of: hit.node) else { return }
        lastRipple = Date()
        pet.ripple(face: face)
    }

    /// A still image for snapshot mode (ImageRenderer can't draw live views).
    static func still(mood: PetMood, size: NSSize) -> NSImage {
        let pet = IcosaPetScene()
        var input = IcosaInput()
        input.mood = mood
        pet.input = input
        pet.setPointsPerUnit(size.height / CGFloat(IcosaPetScene.visibleHeight))
        for i in 0...90 { pet.step(time: Double(i) / 30) }
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = pet.scene
        renderer.pointOfView = pet.cameraNode
        let img = renderer.snapshot(atTime: 3, with: CGSize(width: size.width * 2, height: size.height * 2), antialiasingMode: .multisampling4X)
        img.size = size
        return img
    }
}

struct IcosaPetView: NSViewRepresentable {
    var input: IcosaInput
    /// Faces fly in and assemble when the pet first shows up.
    var entrance = false
    var easterEgg = false
    var fps = 30

    func makeNSView(context: Context) -> IcosaNSView {
        let v = IcosaNSView(fps: fps)
        v.pet.allowsEasterEgg = easterEgg
        if entrance { v.pet.playEntrance() }
        return v
    }

    func updateNSView(_ view: IcosaNSView, context: Context) {
        var i = input
        i.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if view.pet.input != i { view.pet.input = i }
        // Calm moods move slowly: fewer frames, less work.
        let fast: Set<PetMood> = [.attention, .happy, .dancing, .munching, .scared, .failed, .waking, .listening, .presenting]
        let target = i.reduceMotion ? 15 : i.mood == .sleeping ? 12 : fast.contains(i.mood) ? fps : min(fps, 20)
        if view.preferredFramesPerSecond != target { view.preferredFramesPerSecond = target }
    }
}

/// The pet by the notch assembles itself once per launch, not every time the island redraws.
enum PetEntrance {
    private static var done = false
    static func once() -> Bool {
        defer { done = true }
        return !done
    }
}

// MARK: - Debug capture

extension IcosaPetScene {
    /// `NotchIsland --capture-icosa <dir> [px]`: a sheet of every mood (columns) over time (rows),
    /// rendered offscreen — for checking the look without the island.
    static func captureSheetIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-icosa"), i + 1 < args.count else { return }
        let px = i + 2 < args.count ? Int(args[i + 2]) ?? 120 : 120
        let moods: [PetMood] = [.idle, .working, .attention, .happy, .sleeping, .dancing, .hungry, .gaping, .munching,
                                .full, .scared, .sad, .failed, .waking, .listening, .thinking, .presenting]
        let times: [Double] = [0.4, 1.0, 1.7, 2.6]
        let W = px * 8 / 5, H = px
        let ctx = CGContext(data: nil, width: W * moods.count, height: H * times.count, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W * moods.count, height: H * times.count))
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        for (c, mood) in moods.enumerated() {
            let pet = IcosaPetScene()
            var input = IcosaInput()
            input.mood = .idle
            pet.input = input
            pet.setPointsPerUnit(CGFloat(H) / CGFloat(visibleHeight))
            var t = 0.0
            for _ in 0..<60 { pet.step(time: t); t += 1 / 30 }   // settle in idle, then switch
            input.mood = mood
            if args.contains("--agents") { input.agents = 3 }
            if args.contains("--build") { input.motif = .build }
            if args.contains("--ripple") { input.motif = .ripple }
            if let s = args.firstIndex(of: "--season"), s + 1 < args.count { input.season = PetSeasonHat(rawValue: args[s + 1]) }
            pet.input = input
            let t0 = t
            renderer.scene = pet.scene
            renderer.pointOfView = pet.cameraNode
            for (r, dt) in times.enumerated() {
                while t < t0 + dt { pet.step(time: t); t += 1 / 30 }
                let img = renderer.snapshot(atTime: t, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
                if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ctx.draw(cg, in: CGRect(x: c * W, y: (times.count - 1 - r) * H, width: W, height: H))
                }
            }
        }
        let url = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("icosa.png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        exit(0)
    }
}
