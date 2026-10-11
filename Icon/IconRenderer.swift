// Renders the app icon: `swiftc Icon/IconRenderer.swift -o /tmp/icon && /tmp/icon Icon/icon-1024.png`
import AppKit
import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    func path(in r: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
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

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824×824 body centered on a 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.27, blue: 0.98), Color(red: 0.16, green: 0.45, blue: 1.0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .init(x: 0.3, y: 0.15),
                                             startRadius: 0, endRadius: 600))
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

            // The island, hanging from the top edge of the "screen".
            ZStack(alignment: .top) {
                NotchShape(topRadius: 30, bottomRadius: 110)
                    .fill(Color.black)
                    .frame(width: 540, height: 380)
                HStack(spacing: 34) {
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.33), Color(red: 1, green: 0.75, blue: 0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 168, height: 168)
                        .overlay(Image(systemName: "music.note").font(.system(size: 86, weight: .semibold)).foregroundStyle(.white))
                    HStack(alignment: .center, spacing: 18) {
                        ForEach([0.5, 1.0, 0.68, 0.88, 0.42], id: \.self) { h in
                            Capsule().fill(Color.white).frame(width: 24, height: 140 * h)
                        }
                    }
                    .frame(height: 140)
                }
                .padding(.top, 128)
            }
            .frame(width: 824, height: 824, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        }
        .frame(width: 1024, height: 1024)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    renderer.isOpaque = false
    // Go through CGImage to keep the transparent corners.
    guard let cg = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: out)
}
