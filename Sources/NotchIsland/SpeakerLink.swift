import AppKit
import CoreAudio
import IOBluetooth
import NotchIslandCore

// One button: the Yandex speaker turns its Bluetooth on (a «Дом с Алисой» scenario), the Mac connects
// to it and makes it the sound output. Pressing again gives the sound back to where it was.

// MARK: - Sound output (CoreAudio)

enum AudioOutput {
    struct Device { let id: AudioDeviceID; let uid: String; let name: String }

    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static var current: Device? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return all().first { $0.id == id }
    }

    @discardableResult
    static func select(_ device: Device) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

// MARK: - The button's logic

@MainActor
final class SpeakerLink: ObservableObject {
    static let shared = SpeakerLink()

    enum Phase: Equatable {
        case idle
        case working(String)
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { announce() } }
    }
    /// Shows progress and the result at the notch (set by the island model).
    var onNotice: ((Notice) -> Void)?
    /// Paired Bluetooth devices, for the picker in Settings → Дом.
    @Published private(set) var paired: [(address: String, name: String)] = []

    private static let addressKey = "speakerAddress"
    private static let scenarioKey = "speakerScenario"
    /// Where the sound went before the speaker took over.
    private var previousOutputUID: String?
    private var task: Task<Void, Never>?

    var savedAddress: String? {
        get { UserDefaults.standard.string(forKey: Self.addressKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.addressKey); objectWillChange.send() }
    }
    var savedScenarioID: String? {
        get { UserDefaults.standard.string(forKey: Self.scenarioKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.scenarioKey); objectWillChange.send() }
    }

    private init() { reloadPaired() }

    func reloadPaired() {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        paired = devices.compactMap { d in d.addressString.map { ($0, d.name ?? $0) } }
    }

    /// The saved speaker, else the first paired device that looks like a Yandex Station.
    var device: IOBluetoothDevice? {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        if let savedAddress, let d = devices.first(where: { $0.addressString == savedAddress }) { return d }
        return devices.first { SpeakerMatch.isYandexSpeaker($0.name ?? "") }
    }

    var isAvailable: Bool { device != nil }

    var isBusy: Bool { if case .working = phase { return true } else { return false } }

    /// The speaker is connected and playing the Mac's sound.
    var isActive: Bool {
        guard let d = device, d.isConnected(), let out = AudioOutput.current else { return false }
        return SpeakerMatch.audioName(out.name, matches: d.name ?? "")
    }

    func toggle() {
        guard !isBusy else { return }
        if isActive { disconnect() } else { connect() }
    }

    func connect() {
        guard let device else {
            phase = .failed("Сначала сопряги Станцию с Mac: Настройки → Bluetooth")
            return
        }
        let name = device.name ?? "Станция"
        if let out = AudioOutput.current, !SpeakerMatch.audioName(out.name, matches: name) { previousOutputUID = out.uid }
        task?.cancel()
        task = Task {
            debugLog("speaker: start, linked=\(device.isConnected()), services: \(Self.services(device))")
            if !device.isConnected() {
                phase = .working("Включаю Bluetooth на Станции…")
                await turnOnSpeakerBluetooth()
                phase = .working("Подключаюсь к Станции…")
                guard await connectWithRetries(device) else {
                    phase = .failed("Станция не ответила. Скажи «Алиса, включи блютуз» и нажми ещё раз")
                    return
                }
            }
            phase = .working("Переключаю звук…")
            guard let output = await audioProfile(device, name: name) else {
                phase = .failed("Станция подключилась, но не появилась среди устройств вывода звука")
                return
            }
            AudioOutput.select(output)
            phase = .connected
            Usage.track(.speakerConnected)
        }
    }

    func disconnect() {
        task?.cancel()
        let device = self.device
        if let uid = previousOutputUID, let back = AudioOutput.all().first(where: { $0.uid == uid }) {
            AudioOutput.select(back)
        } else if let builtIn = AudioOutput.all().first(where: { $0.uid.contains("BuiltIn") }) {
            AudioOutput.select(builtIn)
        }
        previousOutputUID = nil
        phase = .idle
        onNotice?(Notice(symbol: "hifispeaker", title: "Звук → \(AudioOutput.current?.name ?? "Mac")"))
        guard let device else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = device.closeConnection() }
    }

    private func announce() {
        switch phase {
        case .idle: break
        case .working(let text): onNotice?(Notice(symbol: "hifispeaker.fill", title: "Станция", detail: text, spinning: true))
        case .connected: onNotice?(Notice(symbol: "hifispeaker.fill", tint: .green, title: "Звук → Станция"))
        case .failed(let text): onNotice?(Notice(symbol: "hifispeaker.fill", tint: .orange, title: "Станция", detail: text))
        }
    }

    /// Runs the «включи блютуз» scenario. Without a Yandex login or scenario we just try to connect:
    /// the speaker may already be in Bluetooth mode.
    private func turnOnSpeakerBluetooth() async {
        let home = SmartHomeController.shared
        guard home.loggedIn else { return }
        var scenarios = home.snapshot.scenarios
        if scenarios.isEmpty, let fresh = try? await home.yandex.snapshot() { scenarios = fresh.scenarios }
        guard let scenario = SpeakerMatch.scenario(in: scenarios, savedID: savedScenarioID) else {
            debugLog("speaker: no bluetooth scenario among \(scenarios.map(\.name))")
            return
        }
        do {
            try await home.yandex.runScenario(scenario.id)
            // The speaker takes a moment to say "Bluetooth включён" and start listening.
            try? await Task.sleep(for: .seconds(3))
        } catch {
            debugLog("speaker: scenario failed: \(error.localizedDescription)")
        }
    }

    /// Pages the speaker with the asynchronous API: IOBluetooth reports back on the main run loop,
    /// so nothing blocks and a missed page fails after ~8 s instead of hanging.
    private func connectWithRetries(_ device: IOBluetoothDevice) async -> Bool {
        for attempt in 0..<6 {
            if Task.isCancelled { return false }
            if device.isConnected() { return true }
            let result = await BluetoothPager.open(device, timeout: 8)
            debugLog("speaker: connect attempt \(attempt + 1) → \(String(format: "0x%08X", result))")
            if result == kIOReturnSuccess || device.isConnected() { return true }
            try? await Task.sleep(for: .seconds(1.5))
        }
        return device.isConnected()
    }

    /// A bare link (ACL) doesn't make the speaker a sound output: macOS only brings up the audio
    /// profile once it knows the speaker's services. Ask for them (SDP), then reconnect if needed.
    private func audioProfile(_ device: IOBluetoothDevice, name: String) async -> AudioOutput.Device? {
        if let out = await waitForAudio(named: name, seconds: 4) { return out }
        debugLog("speaker: linked, no audio yet; services: \(Self.services(device))")
        let sdp = await BluetoothPager.queryServices(device, timeout: 10)
        debugLog("speaker: sdp → \(String(format: "0x%08X", sdp)); services: \(Self.services(device))")
        if let out = await waitForAudio(named: name, seconds: 4) { return out }
        // Reconnect now that the services are known.
        _ = device.closeConnection()
        try? await Task.sleep(for: .seconds(1.5))
        let again = await BluetoothPager.open(device, timeout: 8)
        debugLog("speaker: reconnect → \(String(format: "0x%08X", again)); audio: \(AudioOutput.all().map(\.name))")
        return await waitForAudio(named: name, seconds: 8)
    }

    private static func services(_ device: IOBluetoothDevice) -> [String] {
        (device.services as? [IOBluetoothSDPServiceRecord] ?? []).compactMap { $0.getServiceName() }
    }

    private func waitForAudio(named name: String, seconds: Double = 10) async -> AudioOutput.Device? {
        for _ in 0..<Int(seconds * 2) {
            if let d = AudioOutput.all().first(where: { SpeakerMatch.audioName($0.name, matches: name) }) { return d }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}

/// One asynchronous connection attempt to a paired device.
private final class BluetoothPager: NSObject, IOBluetoothDeviceAsyncCallbacks {
    private var continuation: CheckedContinuation<IOReturn, Never>?
    private var timeoutWork: DispatchWorkItem?

    @MainActor
    static func open(_ device: IOBluetoothDevice, timeout: TimeInterval) async -> IOReturn {
        let pager = BluetoothPager()
        return await withCheckedContinuation { cont in
            pager.continuation = cont
            // Page timeout is in 0.625 ms slots.
            let slots = BluetoothHCIPageTimeout(min(timeout / 0.000625, Double(UInt16.max)))
            let started = device.openConnection(pager, withPageTimeout: slots, authenticationRequired: false)
            guard started == kIOReturnSuccess else { return pager.finish(started) }
            let work = DispatchWorkItem { pager.finish(kIOReturnTimeout) }
            pager.timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 2, execute: work)
        }
    }

    @MainActor
    static func queryServices(_ device: IOBluetoothDevice, timeout: TimeInterval) async -> IOReturn {
        let pager = BluetoothPager()
        pager.waitsForSDP = true
        return await withCheckedContinuation { cont in
            pager.continuation = cont
            let started = device.performSDPQuery(pager)
            guard started == kIOReturnSuccess else { return pager.finish(started) }
            let work = DispatchWorkItem { pager.finish(kIOReturnTimeout) }
            pager.timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    private var waitsForSDP = false

    private func finish(_ status: IOReturn) {
        timeoutWork?.cancel()
        continuation?.resume(returning: status)
        continuation = nil
    }

    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) { if !waitsForSDP { finish(status) } }
    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { if waitsForSDP { finish(status) } }
}
