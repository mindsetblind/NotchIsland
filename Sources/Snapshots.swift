import AppKit
import SwiftUI

/// Debug aid: `NotchIsland --snapshots <dir>` renders every island state to PNG files and quits.
/// Used to check layouts (overlaps, clipping, truncation) without clicking through the UI.
@MainActor
enum Snapshots {
    nonisolated(unsafe) static var active = false

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        active = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedTab = UserDefaults.standard.string(forKey: "selectedTab")
        render(to: dir)
        UserDefaults.standard.set(savedTab, forKey: "selectedTab")
        exit(0)
    }

    private static func render(to dir: URL) {
        let model = IslandModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.refreshMediaNow()
        let notch = model.notchSize
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        model.fillForSnapshots(
            shelf: ["README.md", "Package.swift", "build.sh", "Sources/SpotifyWeb.swift", "Info.plist",
                    "очень длинное название файла для проверки.pdf"].map { project.appendingPathComponent($0) },
            apps: ["/System/Applications/Calendar.app", "/System/Applications/Notes.app", "/Applications/Safari.app",
                   "/System/Applications/Music.app", "/System/Applications/System Settings.app",
                   "/System/Applications/Utilities/Terminal.app"].map { URL(fileURLWithPath: $0) },
            colors: ["#3A7BD5", "#FF6B54", "#2ECC71", "#F1C40F", "#9B59B6", "#FFFFFF"])

        func save<V: View>(_ name: String, _ size: CGSize, _ view: V) {
            let content = view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.black)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .padding(8)
                .background(Color(white: 0.5))   // grey margin makes the island's edges visible
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }

        for tab in IslandTab.allCases {
            model.selectTab(tab)
            save("expanded-\(tab.rawValue)", model.size(for: .expanded), ExpandedView(model: model))
        }
        save("drop", model.size(for: .drop), DropZoneView(model: model))

        let ears = { (state: IslandState) in CGSize(width: model.size(for: state).width, height: notch.height) }

        // All the small "around the notch" states on one sheet; the red box is the physical notch.
        func peek<V: View>(_ title: String, _ state: IslandState, _ view: V) -> some View {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 10)).foregroundStyle(.black).frame(width: 110, alignment: .trailing)
                view
                    .frame(width: ears(state).width, height: model.size(for: state).height)
                    .background(Color.black)
                    .overlay(Rectangle().strokeBorder(.red, lineWidth: 1).frame(width: notch.width))
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                Spacer(minLength: 0)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 8) {
            peek("music", .music, CompactMusicView(model: model))
            peek("charging", .charging, ChargingPeekView(model: model))
            peek("color", .color, ColorPeekView(model: model, hex: "#3A7BD5"))
            peek("pomodoro done", .pomodoroPeek, PomodoroPeekView(model: model, peek:
                PomodoroPeek(title: "Фокус завершён", subtitle: "перерыв 15 мин", phase: .longBreak)))
            peek("break done", .pomodoroPeek, PomodoroPeekView(model: model, peek:
                PomodoroPeek(title: "Перерыв окончен", subtitle: "пора за работу", phase: .focus)))
            peek("pomodoro", .pomodoro, PomodoroCompactView(model: model, pomodoro: model.pomodoro))
            peek("airpods", .device, DevicePeekView(model: model, event:
                DeviceEvent(name: "AirPods Pro — Иван", symbol: "airpodspro", connected: true, battery: 85, detail: "L 85% · R 90%")))
            peek("keyboard", .device, DevicePeekView(model: model, event:
                DeviceEvent(name: "Magic Keyboard с Touch ID", symbol: "keyboard", connected: true)))
            peek("disconnected", .device, DevicePeekView(model: model, event:
                DeviceEvent(name: "AirPods Pro — Иван", symbol: "airpodspro", connected: false)))
            peek("drive", .device, DevicePeekView(model: model, event:
                DeviceEvent(name: "Transcend 64GB", symbol: "externaldrive.fill", connected: true, detail: "свободно 12,3 ГБ")))
        }
        .padding(10)
        .frame(width: 860, alignment: .leading)
        .background(Color(white: 0.85))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("peeks.png"))
        }
        save("peek-charging", ears(.charging), ChargingPeekView(model: model))
        save("peek-color", ears(.color), ColorPeekView(model: model, hex: "#3A7BD5"))
        save("peek-pomodoro", ears(.pomodoroPeek), PomodoroPeekView(model: model, peek:
            PomodoroPeek(title: "Фокус завершён", subtitle: "перерыв 15 мин", phase: .longBreak)))
        save("peek-pomodoro-2", ears(.pomodoroPeek), PomodoroPeekView(model: model, peek:
            PomodoroPeek(title: "Перерыв окончен", subtitle: "пора за работу", phase: .focus)))
        save("compact-pomodoro", ears(.pomodoro), PomodoroCompactView(model: model, pomodoro: model.pomodoro))
        let devices = [
            DeviceEvent(name: "AirPods Pro — Иван", symbol: "airpodspro", connected: true, battery: 85, detail: "L 85% · R 90%"),
            DeviceEvent(name: "Magic Keyboard с Touch ID", symbol: "keyboard", connected: true),
            DeviceEvent(name: "AirPods Pro — Иван", symbol: "airpodspro", connected: false),
            DeviceEvent(name: "Transcend 64GB", symbol: "externaldrive.fill", connected: true, detail: "свободно 12,3 ГБ"),
        ]
        for (n, e) in devices.enumerated() {
            save("peek-device-\(n)", ears(.device), DevicePeekView(model: model, event: e))
        }
        if let url = model.shelf.first {
            save("shelf-item-hover", CGSize(width: 90, height: 90), ShelfItem(model: model, url: url, hover: true))
        }
    }
}

/// Debug aid: `NotchIsland --capture-collapse <dir>` opens the island in a small window on a grey
/// background, expands it, collapses it, and saves every rendered frame of the collapse as a contact sheet.
@MainActor
enum AnimationCapture {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-collapse"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let model = IslandModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.refreshMediaNow()
        let size = NSSize(width: 640, height: 260)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.55, alpha: 1)
        let host = NSHostingView(rootView: IslandView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()

        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func grab() -> CGImage? {
            guard let layer = host.layer else { return nil }
            let scale = 1.0
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if layer.isGeometryFlipped == false && !host.isFlipped {
                // AppKit layers are bottom-up already.
            } else {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
            }
            (layer.presentation() ?? layer).render(in: ctx)
            return ctx.makeImage()
        }

        pump(0.8)
        model.setHovering(true)
        pump(1.2)
        var frames: [(Double, CGImage)] = []
        let start = Date()
        model.setHovering(false)
        while Date().timeIntervalSince(start) < 0.75 {
            if let img = grab() { frames.append((Date().timeIntervalSince(start), img)) }
            pump(1.0 / 60)
        }
        window.orderOut(nil)

        // Contact sheet, 6 per row, top 120 px of each frame.
        let cols = 6, fw = Int(size.width), fh = Int(size.height), label = 16
        let rows = (frames.count + cols - 1) / cols
        let W = cols * (fw + 4), H = rows * (fh + label + 4)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (n, (t, img)) in frames.enumerated() {
            let x = (n % cols) * (fw + 4), y = H - (n / cols + 1) * (fh + label + 4)
            ctx.draw(img, in: CGRect(x: x, y: y, width: fw, height: fh))
            NSString(string: String(format: "%.0f ms", t * 1000)).draw(at: NSPoint(x: x + 2, y: y + fh + 1),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        if let out = ctx.makeImage(),
           let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("collapse.png"))
        }
        print("\(frames.count) frames")
        exit(0)
    }
}
