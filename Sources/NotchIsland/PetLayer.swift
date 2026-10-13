import AppKit
import QuartzCore
import SwiftUI

/// The always-visible pet — a neon cat (see CatPet.swift), animated by Core Animation: the system
/// render server runs the loops, so the app does no per-frame work. `size` is the old face height
/// in points; the cat's head ends up about that tall.
struct PetView: View {
    let mood: PetMood
    var size: CGFloat = 17
    var gaze: CGFloat? = nil

    var body: some View {
        CatView(mood: mood, pointsPerCSSPixel: size / 30, gaze: gaze)
            .frame(width: size * 1.6, height: size * 1.3)
    }
}

struct CatView: View {
    let mood: PetMood
    let pointsPerCSSPixel: CGFloat
    var gaze: CGFloat? = nil

    var body: some View {
        if Snapshots.active {
            Image(nsImage: CatNSView.still(mood: mood, pointsPerCSSPixel: pointsPerCSSPixel))
        } else {
            CatLayerView(mood: mood, k: pointsPerCSSPixel, gaze: gaze)
        }
    }
}

private struct CatLayerView: NSViewRepresentable {
    let mood: PetMood
    let k: CGFloat
    let gaze: CGFloat?

    func makeNSView(context: Context) -> CatNSView { CatNSView(pointsPerCSSPixel: k) }

    func updateNSView(_ view: CatNSView, context: Context) {
        view.update(mood: mood, gaze: gaze ?? 0)
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
