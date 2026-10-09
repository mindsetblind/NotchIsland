import AppKit
import IOBluetooth
import IOKit

struct DeviceEvent: Equatable {
    let name: String
    let symbol: String          // SF Symbol
    let connected: Bool
    var battery: Int? = nil     // %, when the device reports it
    var detail: String? = nil   // e.g. "L 80% · R 75%" or free space on a drive
}

/// Watches Bluetooth devices and external drives coming and going.
final class DeviceMonitor: NSObject {
    var onEvent: ((DeviceEvent) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var announcedVolumes: Set<URL> = []
    private let startedAt = Date()

    func start() {
        // Also fires once for every device that is already connected — those get no peek (see below),
        // but we still need their disconnect notifications.
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(bluetoothConnected(_:device:)))
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeMounted(_:)), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeUnmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    // MARK: Bluetooth

    @objc private func bluetoothConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? UUID().uuidString
        disconnectNotes[key]?.unregister()
        disconnectNotes[key] = device.register(forDisconnectNotification: self,
                                               selector: #selector(bluetoothDisconnected(_:device:)))
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        // Battery levels show up a moment after the link is established.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.onEvent?(Self.event(for: device, connected: true))
        }
    }

    @objc private func bluetoothDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotes[device.addressString ?? ""] = nil
        onEvent?(Self.event(for: device, connected: false))
    }

    private static func event(for device: IOBluetoothDevice, connected: Bool) -> DeviceEvent {
        var e = DeviceEvent(name: device.name ?? "Устройство", symbol: symbol(for: device), connected: connected)
        if connected { (e.battery, e.detail) = battery(for: device) }
        return e
    }

    private static func symbol(for d: IOBluetoothDevice) -> String {
        let name = (d.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") || name.contains("клавиатура") { return "keyboard" }
        if name.contains("mouse") || name.contains("мышь") { return "magicmouse" }
        if name.contains("controller") || name.contains("dualsense") || name.contains("dualshock") { return "gamecontroller" }
        switch d.deviceClassMajor {
        case 0x02: return "iphone"                          // phone
        case 0x04: return "headphones"                      // audio / video
        case 0x05:                                          // peripheral
            let minor = d.deviceClassMinor
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "magicmouse" }
            return "gamecontroller"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Best effort: AirPods expose per-bud levels via (undocumented) IOBluetoothDevice properties;
    /// Apple keyboards/mice/trackpads report theirs in the IORegistry.
    private static func battery(for d: IOBluetoothDevice) -> (Int?, String?) {
        func level(_ key: String) -> Int? {
            guard d.responds(to: Selector(key)), let n = d.value(forKey: key) as? NSNumber, n.intValue > 0 else { return nil }
            return n.intValue
        }
        let left = level("batteryPercentLeft"), right = level("batteryPercentRight")
        let caseLevel = level("batteryPercentCase")
        if left != nil || right != nil {
            var parts: [String] = []
            if let left { parts.append("L \(left)%") }
            if let right { parts.append("R \(right)%") }
            if let caseLevel { parts.append("футляр \(caseLevel)%") }
            return ([left, right].compactMap { $0 }.min(), parts.joined(separator: " · "))
        }
        if let single = level("batteryPercentSingle") { return (single, nil) }
        return (hidBattery(named: d.name), nil)
    }

    private static func hidBattery(named name: String?) -> Int? {
        guard let name else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if product == name,
               let pct = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                return pct
            }
        }
        return nil
    }

    // MARK: External drives

    @objc private func volumeMounted(_ n: Notification) {
        guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let v = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                                        .volumeIsLocalKey, .volumeLocalizedNameKey,
                                                        .volumeAvailableCapacityKey]),
              v.volumeIsLocal == true,
              v.volumeIsInternal == false || v.volumeIsEjectable == true || v.volumeIsRemovable == true
        else { return }
        announcedVolumes.insert(url)
        let free = v.volumeAvailableCapacity.map {
            "свободно " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        onEvent?(DeviceEvent(name: v.volumeLocalizedName ?? url.lastPathComponent,
                             symbol: "externaldrive.fill", connected: true, detail: free))
    }

    @objc private func volumeUnmounted(_ n: Notification) {
        guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              announcedVolumes.remove(url) != nil else { return }
        let name = n.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? url.lastPathComponent
        onEvent?(DeviceEvent(name: name, symbol: "externaldrive", connected: false))
    }
}
