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
                    .frame(width: ears(state).width, height: notch.height)
                    .background(Color.black)
                    .overlay(Rectangle().strokeBorder(.red, lineWidth: 1).frame(width: notch.width))
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                Spacer(minLength: 0)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 8) {
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
