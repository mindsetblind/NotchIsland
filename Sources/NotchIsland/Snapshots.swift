import AppKit
import NotchIslandCore
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

    static func fillDeveloperSample(_ tracker: DevTaskTracker) {
        tracker.handle(DevEvent(kind: .start, id: "build", title: "swift build -c release", category: .build))
        tracker.handle(DevEvent(kind: .progress, id: "build", message: "Compiling Views.swift", progress: 0.6))
        tracker.handle(DevEvent(kind: .start, id: "tests", title: "npm test", category: .test))
        tracker.handle(DevEvent(kind: .finish, id: "tests", message: "3 failed, 41 passed", status: .failure, exitCode: 1))
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

        model.claude.fillForSnapshots()
        Snapshots.fillDeveloperSample(model.developer.tracker)
        let now = Date()
        model.clipboard.store.showSample([
            ClipItem(text: "https://github.com/mindsetblind/NotchIsland/pulls", kind: .link, copiedAt: now.addingTimeInterval(-40), sourceApp: "Safari"),
            ClipItem(text: "swift build -c release && ./build.sh --install", kind: .text, copiedAt: now.addingTimeInterval(-300), pinned: true, sourceApp: "Терминал"),
            ClipItem(text: "Очень длинный абзац текста, скопированный из заметок, чтобы проверить перенос строк и обрезку в карточке истории буфера обмена.", kind: .text, copiedAt: now.addingTimeInterval(-3600), sourceApp: "Заметки"),
            ClipItem(text: "#3A7BD5", kind: .text, copiedAt: now.addingTimeInterval(-7200)),
        ])
        let clipboardWasEnabled = AppSettings.shared.clipboardEnabled
        defer { AppSettings.shared.clipboardEnabled = clipboardWasEnabled }
        model.selectTab(.clipboard)
        AppSettings.shared.clipboardEnabled = false
        save("expanded-clipboard-off", model.size(for: .expanded), ExpandedView(model: model))
        AppSettings.shared.clipboardEnabled = true
        save("search-clipboard", CGSize(width: 480, height: 380),
             ClipboardSearchView(history: model.clipboard, store: model.clipboard.store, close: {}))
        if let ask = model.claude.permissions.first {
            save("permission", model.size(for: .permission), PermissionCardView(model: model, claude: model.claude, ask: ask))
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
            peek("pet", .idle, PetEarView(model: model))
            peek("music", .music, CompactMusicView(model: model))
            peek("agent", .agent, AgentCompactView(model: model, claude: model.claude))
            peek("agent done", .agentPeek, AgentPeekView(model: model, peek: AgentPeek(project: "NotchIsland", text: "готово", mood: .happy)))
            peek("agent waits", .agentPeek, AgentPeekView(model: model, peek: AgentPeek(project: "Java practice", text: "ждёт ответа", mood: .attention)))
            peek("charging", .charging, ChargingPeekView(model: model))
            peek("build running", .notice, NoticeView(model: model, notice: Notice(
                symbol: "hammer.fill", title: "swift build", startedAt: Date().addingTimeInterval(-83), spinning: true)))
            peek("build failed", .notice, NoticeView(model: model, notice: Notice(
                symbol: "xmark.octagon.fill", tint: .red, title: "Сборка упала", detail: "2 ошибки")))
            peek("tests passed", .notice, NoticeView(model: model, notice: Notice(
                symbol: "checkmark.circle.fill", tint: .green, title: "Тесты прошли", detail: "0:42")))
            peek("low battery", .notice, NoticeView(model: model, notice: Notice(
                symbol: "battery.25percent", tint: .red, title: "Низкий заряд", detail: "10%")))
            peek("copied", .notice, NoticeView(model: model, notice: Notice(
                symbol: "doc.on.clipboard", tint: .green, title: "Скопировано", detail: "https://github.com/mindsetblind")))
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

/// Debug aid: `NotchIsland --capture-pet <dir>` renders the Core Animation pet in every mood,
/// a few moments apart, into one sheet.
@MainActor
enum PetCapture {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-pet"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let moods: [PetMood] = [.idle, .working, .attention, .happy, .sleeping, .dancing]
        let cell = NSSize(width: 140, height: 110)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: cell.width * CGFloat(moods.count), height: cell.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        let views = moods.map { mood -> PetNSView in
            let v = PetNSView(size: 64)
            v.update(mood: mood, gaze: 0)
            return v
        }
        let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        for (n, v) in views.enumerated() {
            v.frame = NSRect(x: CGFloat(n) * cell.width + 19, y: 14, width: 64 * 1.6, height: 64 * 1.3)
            container.addSubview(v)
        }
        window.contentView = container
        window.orderFrontRegardless()

        var shots: [CGImage] = []
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.27))
            let w = Int(container.bounds.width), h = Int(container.bounds.height)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            container.layer?.presentation()?.render(in: ctx) ?? container.layer?.render(in: ctx)
            if let img = ctx.makeImage() { shots.append(img) }
        }
        window.orderOut(nil)

        let W = Int(window.frame.width), H = Int(window.frame.height)
        let sheet = CGContext(data: nil, width: W, height: H * shots.count + 4 * shots.count, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(NSColor.darkGray.cgColor)
        sheet.fill(CGRect(x: 0, y: 0, width: W, height: H * shots.count + 4 * shots.count))
        for (n, img) in shots.enumerated() {
            sheet.draw(img, in: CGRect(x: 0, y: (shots.count - 1 - n) * (H + 4), width: W, height: H))
        }
        if let out = sheet.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("pet.png"))
        }
        exit(0)
    }
}

/// Debug aid: `NotchIsland --capture-check <dir>` records the "task done" checkmark animation frame by frame.
@MainActor
enum CheckCapture {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-check"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let size = NSSize(width: 90, height: 90)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let mark: AnyView = args.contains("--attention")
            ? AnyView(AnimatedAttention(size: 64)) : AnyView(AnimatedCheckmark(size: 64))
        let host = NSHostingView(rootView: mark.frame(width: 90, height: 90).background(Color.black))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        var frames: [CGImage] = []
        let start = Date()
        while Date().timeIntervalSince(start) < (args.contains("--attention") ? 1.8 : 1.1) {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30))
            let ctx = CGContext(data: nil, width: 90, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: 90); ctx.scaleBy(x: 1, y: -1)
            (host.layer?.presentation() ?? host.layer)?.render(in: ctx)
            if let img = ctx.makeImage() { frames.append(img) }
        }
        let sheet = CGContext(data: nil, width: 94 * frames.count, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(NSColor.darkGray.cgColor)
        sheet.fill(CGRect(x: 0, y: 0, width: 94 * frames.count, height: 90))
        for (n, f) in frames.enumerated() { sheet.draw(f, in: CGRect(x: n * 94, y: 0, width: 90, height: 90)) }
        if let out = sheet.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(args.contains("--attention") ? "attention.png" : "check.png"))
        }
        exit(0)
    }
}

/// Debug aid: `NotchIsland --capture-search <dir>` opens the real clipboard search panel on sample
/// data (types a query, moves the selection) and saves what its layers render. ImageRenderer can't
/// draw text fields or scroll views, so `--snapshots` alone can't show this window.
@MainActor
enum SearchCapture {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-search"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let history = ClipboardHistory()
        let now = Date()
        var sample: [ClipItem] = []
        for n in 0..<12 {
            let isLink = n % 3 == 0
            let text = isLink ? "https://example.com/page/\(n)" : "Заметка номер \(n): немного текста для проверки поиска"
            let date = now.addingTimeInterval(Double(-n * 400))
            sample.append(ClipItem(text: text, kind: isLink ? .link : .text, copiedAt: date,
                                   pinned: n == 4, sourceApp: n % 2 == 0 ? "Safari" : "Заметки"))
        }
        history.store.showSample(sample)
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        pump(0.3)
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
        ClipboardSearchWindow.shared.show(history: history, below: CGRect(x: 600, y: 900, width: 185, height: 32))
        pump(0.6)
        print("frontmost before: \(frontBefore), after: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        guard let panel = NSApp.windows.first(where: { $0 is ClipboardSearchPanel }), let view = panel.contentView else { exit(1) }

        func save(_ name: String) {
            guard let layer = view.layer else { return }
            let size = view.bounds.size, scale: CGFloat = 2
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            guard let image = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }
        save("search-all")
        print("search panel is key:", panel.isKeyWindow)
        // Type "сафари"-less query and move the selection down twice.
        for ch in "номер 1" {
            let s = String(ch)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: s,
                                        charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                panel.sendEvent(e)
            }
        }
        pump(0.3)
        for _ in 0..<2 {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: "\u{F701}",
                                        charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) {
                panel.sendEvent(e)
            }
        }
        pump(0.3)
        save("search-query")
        exit(0)
    }
}

/// Debug aid: `NotchIsland --capture-tabs <dir>` hosts the expanded island in a real window and saves
/// what its layers render for every tab — unlike `--snapshots`, this includes scroll views.
@MainActor
enum TabsCapture {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-tabs"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let savedTab = UserDefaults.standard.string(forKey: "selectedTab")
        defer { UserDefaults.standard.set(savedTab, forKey: "selectedTab") }

        let model = IslandModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.claude.fillForSnapshots()
        Snapshots.fillDeveloperSample(model.developer.tracker)
        let size = model.size(for: .expanded)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ExpandedView(model: model)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.black).foregroundStyle(.white).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        for tab in IslandTab.allCases {
            model.selectTab(tab)
            pump(0.8)
            guard let layer = host.layer else { continue }
            let scale: CGFloat = 2
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            if host.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            if let image = ctx.makeImage(),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("tab-\(tab.rawValue).png"))
            }
        }
        exit(0)
    }
}

/// Debug aid: `NotchIsland --bench-gaze` hosts the real island in a window and drives the pet's
/// gaze the way cursor movement near the top of the screen does (~60 changes/s for 6 s), then prints
/// the CPU time the process spent. Used to measure per-update cost of the island view.
@MainActor
enum GazeBenchmark {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--bench-gaze") else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = IslandModel()
        model.notchSize = CGSize(width: 185, height: 32)
        let size = NSSize(width: 760, height: 200)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: IslandView(model: model))
        window.orderFrontRegardless()
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func cpu() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        pump(1.5)
        let c0 = cpu(), t0 = Date()
        var i = 0
        while Date().timeIntervalSince(t0) < 6 {
            model.setPetGaze((CGFloat(sin(Double(i) * 0.15)) * 4).rounded() / 4)
            i += 1
            pump(1.0 / 60)
        }
        let used = cpu() - c0, wall = Date().timeIntervalSince(t0)
        print(String(format: "gaze updates: %d, CPU %.2f s over %.1f s = %.1f%%", i, used, wall, used / wall * 100))
        exit(0)
    }
}

/// Debug aid: `NotchIsland --bench-states` shows each collapsed state in the real island for 4 s and
/// prints the CPU the process spent on it (render + animations), to find expensive states.
@MainActor
enum StatesBenchmark {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--bench-states") else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = IslandModel()
        model.notchSize = CGSize(width: 185, height: 32)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 760, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: IslandView(model: model))
        window.orderFrontRegardless()
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func cpu() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        func measure(_ name: String, _ setUp: () -> Void) {
            setUp()
            let c0 = cpu()
            pump(4)
            print(String(format: "%-28@ %5.1f%%", name as NSString, (cpu() - c0) / 4 * 100))
        }
        pump(1.5)
        if CommandLine.arguments.contains("--churn") {
            window.setContentSize(NSSize(width: 760, height: 640))
            model.refreshMediaNow()
            pump(1)
            print("churning, pid \(getpid())")
            let c0 = cpu()
            for i in 0..<14 {
                if i % 2 == 0 {
                    model.post(.agent, "c", .agentPeek(AgentPeek(project: "NotchIsland", text: "готово", mood: .happy)), duration: 30)
                } else {
                    model.activities.dismissAll(.agent)
                }
                pump(1)
            }
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            print(String(format: "churn avg %.1f%%  (process total user %.2f s, sys %.2f s, involuntary ctx switches %ld, voluntary %ld)",
                         (cpu() - c0) / 14 * 100,
                         Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6,
                         Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6, u.ru_nivcsw, u.ru_nvcsw))
            exit(0)
        }
        if CommandLine.arguments.contains("--real") {
            window.setContentSize(NSSize(width: 760, height: 640))
            model.refreshMediaNow()
            pump(1)
            measure("music playing (compact)") {}
            measure("claude starts working") {
                model.claude.handleHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "bench", "cwd": "/tmp/bench"], connection: -1)
            }
            measure("claude working") {}
            do {
                model.claude.handleHookEvent(["hook_event_name": "Stop", "session_id": "bench", "cwd": "/tmp/bench"], connection: -1)
                var line = "Stop, CPU per 0.25 s:"
                for _ in 0..<20 {
                    let c0 = cpu()
                    pump(0.25)
                    line += String(format: " %.0f", (cpu() - c0) / 0.25 * 100)
                }
                print(line + " (%)")
            }
            measure("after готово") {}
            measure("after готово (2)") {}
            exit(0)
        }
        if CommandLine.arguments.contains("--tail") {
            measure("device peek") {
                model.post(.device, "d", .device(DeviceEvent(name: "AirPods", symbol: "airpods", connected: true)), duration: 30)
            }
            model.activities.dismissAll(.device)
            print("idling for sampling, pid \(getpid())")
            for _ in 0..<5 { measure("  idle after device") {} }
            exit(0)
        }
        measure("idle (pet)") {}
        measure("sound Glass") { NSSound(named: "Glass")?.play() }
        measure("idle after sound") {}
        measure("pet happy (cheer)") { model.cheer() }
        measure("idle after cheer") {}
        measure("agent done (checkmark)") {
            model.post(.agent, "a", .agentPeek(AgentPeek(project: "NotchIsland", text: "готово", mood: .happy)), duration: 30)
        }
        model.activities.dismissAll(.agent)
        measure("  idle after checkmark") {}
        measure("agent waits (attention)") {
            model.post(.agent, "b", .agentPeek(AgentPeek(project: "NotchIsland", text: "ждёт ответа", mood: .attention)), duration: 30)
        }
        model.activities.dismissAll(.agent)
        measure("  idle after attention") {}
        measure("device peek") {
            model.post(.device, "d", .device(DeviceEvent(name: "AirPods", symbol: "airpods", connected: true, battery: 80)), duration: 30)
        }
        model.activities.dismissAll(.device)
        measure("  idle after device") {}
        measure("notice with timer+spinner") {
            model.post(.developer, "x", .notice(Notice(symbol: "hammer.fill", title: "swift build", startedAt: Date(), spinning: true)), duration: 30)
        }
        model.activities.dismissAll(.developer)
        measure("  idle after notice") {}
        measure("pomodoro running") { model.pomodoro.start() }
        model.pomodoro.reset()
        measure("back to idle") {}
        exit(0)
    }
}

/// Debug aid: `NotchIsland --capture-pet-panel <dir>` renders the pet's file assistant panel in each
/// state (sample plans, no Claude call) and saves one PNG per state.
@MainActor
enum PetPanelCapture {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-pet-panel"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let desk = home + "/Desktop"
        let assistant = PetAssistant.shared
        let state = PetPanelState()
        state.notch = CGSize(width: 185, height: 32)
        state.shown = true
        let context = PetContext(folder: URL(fileURLWithPath: desk),
                                 files: [URL(fileURLWithPath: desk + "/Снимок экрана 1.png")])
        let tidy = PetPlan(reply: "Нашёл 3 скриншота на рабочем столе — сложу их в новую папку «Скриншоты».", actions: [
            PetAction(.mkdir, desk + "/Скриншоты"),
            PetAction(.move, desk + "/Снимок экрана 1.png", to: desk + "/Скриншоты/Снимок экрана 1.png"),
            PetAction(.move, desk + "/Снимок экрана 2.png", to: desk + "/Скриншоты/Снимок экрана 2.png"),
            PetAction(.move, desk + "/черновик.txt", to: desk + "/план отпуска.txt"),
            PetAction(.trash, desk + "/старый архив.zip"),
        ])
        let found = PetPlan(reply: "Вот что похоже на договор аренды:", files: [
            home + "/Documents/Договор аренды 2026.pdf", home + "/Downloads/dogovor_arendy_scan.pdf",
        ])
        let states: [(String, PetAssistant.Phase, String)] = [
            ("input", .input, ""),
            ("thinking", .thinking, "разложи скриншоты с рабочего стола"),
            ("plan", .plan(tidy, issues: []), "разложи скриншоты"),
            ("plan-issues", .plan(tidy, issues: [PetIssue(index: 4, message: "файла нет")]), "разложи скриншоты"),
            ("found", .plan(found, issues: []), "где договор аренды"),
            ("done", .done("Готово: 5 действий", canUndo: true), ""),
            ("playing", .playing("Weird Fishes/Arpeggi — Radiohead"), ""),
            ("login", .notLoggedIn, ""),
        ]
        let size = NSSize(width: PetPanelController.contentWidth + 20 + 48, height: 420)
        let sources = [
            PetMusicSource(uri: "spotify:user:me:collection", name: "Любимые треки", kind: .liked, subtitle: "Медиатека"),
            PetMusicSource(uri: "spotify:playlist:1", name: "Для бега", kind: .playlist, subtitle: "Плейлист · ivan"),
            PetMusicSource(uri: "spotify:playlist:2", name: "Deep Focus", kind: .playlist, subtitle: "Плейлист · Spotify"),
            PetMusicSource(uri: "spotify:playlist:3", name: "Дорога", kind: .playlist, subtitle: "Плейлист · ivan"),
            PetMusicSource(uri: "spotify:album:4", name: "In Rainbows", kind: .album, subtitle: "Альбом · Radiohead"),
        ]
        var tagged = PetContext()
        tagged.music = sources[1]
        let extra: [(String, PetAssistant.Phase, String)] = [("quick", .input, ""), ("mention", .input, "@д"), ("tagged", .input, "")]
        for (name, phase, asked) in states + extra {
            assistant.debugShow(phase, asked: asked, context: name == "input" ? context : name == "tagged" ? tagged : PetContext(),
                                sources: name == "quick" || name == "mention" || name == "tagged" ? sources : [],
                                query: name == "mention" ? "что-нибудь бодрое @д" : "")
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 40, y: 40), size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = NSColor(white: 0.55, alpha: 1)
            let host = NSHostingView(rootView: PetPanelView(assistant: assistant, state: state, close: {}, heightChanged: { _ in }))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("pet-\(name).png"))
            window.orderOut(nil)
        }
        exit(0)
    }
}

/// Debug aid: `NotchIsland --pet-ask "<request>"` runs the pet's Claude brain cold and pre-warmed
/// and prints both timings and the plan (no files are touched, nothing is played).
@MainActor
enum PetAskBench {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--pet-ask"), i + 1 < args.count else { return }
        let request = args[i + 1]
        if let quick = PetQuickIntent.parse(request) { print("quick path: \(quick)") }
        let brain = ClaudeCodeBrain()
        Task {
            var t = Date()
            let cold = try? await brain.plan(request, context: PetContext())
            print(String(format: "cold: %.2f s → %@", Date().timeIntervalSince(t), String(describing: cold)))
            brain.prewarm()
            try? await Task.sleep(for: .seconds(4))
            t = Date()
            let warm = try? await brain.plan(request, context: PetContext())
            print(String(format: "warm: %.2f s → %@", Date().timeIntervalSince(t), String(describing: warm)))
            exit(0)
        }
        RunLoop.main.run()
    }
}
