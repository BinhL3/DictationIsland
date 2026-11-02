import CoreAudio
import Foundation
import IOKit

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channelCount: Int
    /// Hidden from the system device list (e.g. by Logitech's leftover "Blue Voice" driver
    /// extension), but still openable by UID.
    var isHidden = false
}

/// Core Audio device enumeration. AVAudioEngine always opens the system default input unless
/// its input unit is pointed at a specific device, which is what `AudioCapture` does with these.
enum AudioDevices {
    /// Visible inputs plus hidden USB mics found through the kernel audio driver.
    static func inputs() -> [AudioInputDevice] {
        let visible = visibleInputs()
        let known = Set(visible.map(\.uid))
        let hidden: [AudioInputDevice] = kernelEngineUIDs().compactMap { uid in
            guard !known.contains(uid), let id = translate(uid: uid) else { return nil }
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: string(id, kAudioObjectPropertyName) ?? "USB Microphone",
                channelCount: channels,
                isHidden: true
            )
        }
        return visible + hidden
    }

    /// UIDs of every USB/kernel audio engine. Hidden devices aren't in `kAudioHardwarePropertyDevices`,
    /// but Core Audio still resolves them by UID.
    private static func kernelEngineUIDs() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAudioEngine"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var uids: [String] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "IOAudioEngineGlobalUniqueID" as CFString, kCFAllocatorDefault, 0)
            if let uid = property?.takeRetainedValue() as? String { uids.append(uid) }
        }
        return uids
    }

    private static func translate(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &id
            )
        }
        return status == noErr && id != 0 ? id : nil
    }

    private static func visibleInputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                name: string(id, kAudioObjectPropertyName) ?? "Unknown",
                channelCount: channels
            )
        }
    }

    static func defaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return visibleInputs().first { $0.id == id }
    }

    static func device(uid: String) -> AudioInputDevice? {
        inputs().first { $0.uid == uid }
    }

    /// The input to open for a take. A chosen mic wins while it's connected. Otherwise this
    /// follows the system default (as `AudioCapture` does for a missing mic), except that a Bluetooth headset (AirPods) is passed over for the built-in mic:
    /// opening a headset's mic drops it into low-quality call audio, which hurts both the
    /// recording and the music being muffled. With the lid closed the built-in mic can't hear
    /// you, so the headset is used after all. nil means "system default".
    static func preferredInputUID(selected: String?, avoidBluetooth: Bool) -> String? {
        if let selected, device(uid: selected) != nil { return selected }
        guard avoidBluetooth, let current = defaultInput(), isBluetooth(current.id), !isLidClosed(),
              let builtIn = visibleInputs().first(where: { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn })
        else { return selected }
        return builtIn.uid
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(id)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr ? transport : 0
    }

    /// A MacBook lid is shut (clamshell mode with an external display).
    private static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
