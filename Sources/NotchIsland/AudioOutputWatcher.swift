import CoreAudio
import Foundation

/// Is the sound going to Bluetooth headphones (AirPods & co.)? Watches the default output device.
final class AudioOutputWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var headphones = false
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.check()
        }
        check()
    }

    func check() {
        let now = Self.outputIsBluetooth()
        guard now != headphones else { return }
        headphones = now
        onChange?(now)
    }

    static func outputIsBluetooth() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        a.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
