import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization

/// Quiets whatever is playing while you dictate, so you can hear yourself and the mic doesn't pick
/// up the music.
///
/// Preferred: a DJ-style filter sweep. A Core Audio process tap (macOS 14.2+) captures every other
/// app's output and mutes the originals; the tapped audio is played back through a resonant
/// low-pass whose cutoff sweeps down (the music goes "underwater") and back up on release.
/// Needs the System Audio Recording permission.
///
/// Fallback: fade the output device's volume down and back up.
@MainActor
final class MediaMuffler {
    static let shared = MediaMuffler()

    private var filter: SystemAudioFilter?
    private var volume: VolumeDucker?
    private var releaseWork: DispatchWorkItem?
    private var isEngaged = false

    private init() {
        VolumeDucker.restoreAfterCrash()
    }

    func engage() {
        let settings = AppSettings.shared
        guard settings.muffleMedia, !isEngaged else { return }
        releaseWork?.cancel()
        // Nothing playing, nothing to muffle.
        guard filter != nil || volume != nil || OutputDevice.isPlaying else { return }
        isEngaged = true
        let level = Float(settings.muffleLevel)

        if let filter {  // re-engaged during a release sweep
            filter.engage(level: level)
            return
        }
        if let volume {
            volume.duck(to: level)
            return
        }
        if SystemAudioPermission.status == .authorized, let filter = SystemAudioFilter() {
            self.filter = filter
            filter.engage(level: level)
        } else if let volume = VolumeDucker() {
            self.volume = volume
            volume.duck(to: level)
        }
    }

    func release() {
        guard isEngaged else { return }
        isEngaged = false
        let duration: TimeInterval
        if let filter {
            filter.release()
            duration = SystemAudioFilter.releaseSeconds
        } else if let volume {
            volume.restore()
            duration = VolumeDucker.rampSeconds
        } else {
            return
        }
        // Tear down once the sweep is back to dry, which also unmutes the original apps.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isEngaged else { return }
                self.filter = nil
                self.volume = nil
            }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1, execute: work)
    }
}

// MARK: - Output device

enum OutputDevice {
    static var defaultID: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func uid(_ id: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Some app has audio running on the default output (music, video, a call).
    static var isPlaying: Bool {
        guard let id = defaultID else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

// MARK: - DJ filter (process tap)

/// Taps all other processes' audio (muting the originals) and plays it back, filtered, through
/// an ordinary output-only engine.
///
/// The tap sits alone in its aggregate device. Adding the output device to the aggregate (the
/// usual recipe) also opens that device's microphone, which drops Bluetooth headphones like
/// AirPods into low-quality headset mode and reconfigures audio mid-dictation.
final class SystemAudioFilter {
    static let engageSeconds: Double = 0.6
    static let releaseSeconds: Double = 0.9
    /// Cutoff when fully muffled: low enough to sound underwater, high enough to keep the beat.
    static let minCutoff: Float = 500
    static let maxCutoff: Float = 18_000
    /// A little resonance at the cutoff is what makes the sweep sound like a DJ filter; more than
    /// this whistles.
    static let q: Float = 1.2

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let output = AVAudioEngine()
    private var outputObserver: NSObjectProtocol?
    private let dsp: FilterDSP

    /// nil if the tap, the aggregate device or the output can't be set up.
    init?() {
        // Our own process must be excluded, or the filtered output would be tapped again.
        guard let ownProcess = Self.processObject(pid: getpid()) else { return nil }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mSampleRate > 0,
              let playback = AVAudioFormat(standardFormatWithSampleRate: format.mSampleRate, channels: 2)
        else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let dsp = FilterDSP(
            tapChannels: Int(format.mChannelsPerFrame),
            tapInterleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            sampleRate: Float(format.mSampleRate)
        )
        self.dsp = dsp

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DictationIsland Muffle",
            kAudioAggregateDeviceUIDKey: "dev.voicedictation.muffle.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Playback: a source node pulling from the ring buffer, on whatever the output device is.
        let source = AVAudioSourceNode(format: playback) { _, _, frameCount, buffers in
            dsp.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        output.attach(source)
        output.connect(source, to: output.mainMixerNode, format: playback)
        output.prepare()

        // No queue: the block runs on the tap's real-time IO thread and only copies into the ring.
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            dsp.capture(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }
        guard status == noErr, (try? output.start()) != nil, AudioDeviceStart(aggregateID, procID) == noErr else {
            teardown()
            return nil
        }
        // Switching output devices stops the engine; follow the new device.
        outputObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: output, queue: .main
        ) { [output] _ in
            try? output.start()
        }
    }

    deinit { teardown() }

    func engage(level: Float) {
        dsp.level.store(level.bitPattern, ordering: .relaxed)
        dsp.target.store(Float(1).bitPattern, ordering: .relaxed)
        dsp.rampSeconds.store(Float(Self.engageSeconds).bitPattern, ordering: .relaxed)
    }

    func release() {
        dsp.target.store(Float(0).bitPattern, ordering: .relaxed)
        dsp.rampSeconds.store(Float(Self.releaseSeconds).bitPattern, ordering: .relaxed)
    }

    private func teardown() {
        if let outputObserver { NotificationCenter.default.removeObserver(outputObserver) }
        outputObserver = nil
        // Destroying the tap unmutes the original apps; our copy stops right after.
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        output.stop()
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Realtime part. `capture` runs on the tap's IO thread and `render` on the output's; they share
/// a single-producer/single-consumer ring of stereo frames. No allocation or locks.
final class FilterDSP: @unchecked Sendable {
    let target = Atomic<UInt32>(Float(0).bitPattern)
    let level = Atomic<UInt32>(Float(1).bitPattern)
    let rampSeconds = Atomic<UInt32>(Float(0.6).bitPattern)

    private let tapChannels: Int
    private let tapInterleaved: Bool
    private let sampleRate: Float
    private var amount: Float = 0
    /// Biquad history x1 x2 y1 y2 per output channel (stereo).
    private let history = UnsafeMutablePointer<Float>.allocate(capacity: 8)

    /// Stereo interleaved ring; ~0.7 s at 48 kHz.
    private static let capacity = 32_768
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// Playback starts once this much is buffered and catches up if it drifts past `maxLatency`.
    private let primeFrames: Int
    private let maxLatency: Int
    private var primed = false

    init(tapChannels: Int, tapInterleaved: Bool, sampleRate: Float) {
        self.tapChannels = max(1, tapChannels)
        self.tapInterleaved = tapInterleaved
        self.sampleRate = sampleRate
        primeFrames = Int(sampleRate * 0.02)
        maxLatency = Int(sampleRate * 0.08)
        history.initialize(repeating: 0, count: 8)
        ring.initialize(repeating: 0, count: Self.capacity * 2)
    }

    deinit {
        history.deallocate()
        ring.deallocate()
    }

    /// Copies tapped audio into the ring as stereo (mono is duplicated, extra channels dropped).
    func capture(input: UnsafeMutableAudioBufferListPointer) {
        // The aggregate holds only the tap, so its streams are the tap's.
        guard let first = input.first, first.mData != nil else { return }
        let left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, frames: Int
        if tapInterleaved {
            let channels = max(1, Int(first.mNumberChannels))
            let data = UnsafePointer(first.mData!.assumingMemoryBound(to: Float.self))
            left = data
            right = channels > 1 ? data + 1 : data
            stride = channels
            frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        } else {
            let data = UnsafePointer(first.mData!.assumingMemoryBound(to: Float.self))
            left = data
            right = input.count > 1 && input[1].mData != nil
                ? UnsafePointer(input[1].mData!.assumingMemoryBound(to: Float.self)) : data
            stride = 1
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        }

        let w = written.load(ordering: .relaxed)
        let free = Self.capacity - (w - read.load(ordering: .acquiring))
        let count = min(frames, free)  // full (output stalled): drop the newest
        for i in 0..<count {
            let slot = ((w + i) % Self.capacity) * 2
            ring[slot] = left[i * stride]
            ring[slot + 1] = right[i * stride]
        }
        written.store(w + count, ordering: .releasing)
    }

    /// Fills the output with filtered ring audio; silence when starved.
    func render(frames: Int, into outputs: UnsafeMutableAudioBufferListPointer) {
        var r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        var available = w - r
        if !primed {
            primed = available >= primeFrames
        }
        // Keep latency bounded when the two clocks drift apart.
        if available > maxLatency + frames {
            r = w - maxLatency
            available = maxLatency
        }
        let count = primed ? min(frames, available) : 0
        if count < frames && primed && available == 0 { primed = false }

        // Advance the envelope once per buffer, coefficients follow it.
        let goal = Float(bitPattern: target.load(ordering: .relaxed))
        let step = Float(frames) / sampleRate / max(Float(bitPattern: rampSeconds.load(ordering: .relaxed)), 0.01)
        amount = goal > amount ? min(goal, amount + step) : max(goal, amount - step)
        // Ease in and out so the sweep starts and lands softly.
        let eased = amount * amount * (3 - 2 * amount)
        let gain = 1 + (Float(bitPattern: level.load(ordering: .relaxed)) - 1) * eased
        let cutoff = SystemAudioFilter.maxCutoff * pow(SystemAudioFilter.minCutoff / SystemAudioFilter.maxCutoff, eased)

        // RBJ cookbook low-pass. At amount 0 it's bypassed so playback is untouched.
        let bypass = amount <= 0.0001
        let w0 = 2 * Float.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * SystemAudioFilter.q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 - cosw) / 2 / a0, b1 = (1 - cosw) / a0, b2 = b0
        let a1 = -2 * cosw / a0, a2 = (1 - alpha) / a0

        var outChannel = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(1, Int(buffer.mNumberChannels))
            for sub in 0..<stride {
                let channel = min(outChannel, 1)
                outChannel += 1
                let h = history + channel * 4  // x1 x2 y1 y2
                for i in 0..<frames {
                    let x = i < count ? ring[((r + i) % Self.capacity) * 2 + channel] : 0
                    // Bypassed, the history still tracks the signal so engaging doesn't click.
                    let y = bypass ? x : b0 * x + b1 * h[0] + b2 * h[1] - a1 * h[2] - a2 * h[3]
                    h[1] = h[0]; h[0] = x
                    h[3] = h[2]; h[2] = y
                    data[i * stride + sub] = y * gain
                }
            }
        }
        read.store(r + count, ordering: .releasing)
    }
}

// MARK: - System Audio Recording permission

/// There's no public API to check this permission, so this uses the TCC calls AudioCap and
/// similar apps use. Status is `unknown` until the user is asked.
enum SystemAudioPermission {
    enum Status { case unknown, denied, authorized }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    static var status: Status {
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: Request.self)(service, nil, completion)
    }
}

// MARK: - Volume fallback

/// Fades the default output's volume to a fraction and back. The original volume is persisted
/// first, so a crash mid-dictation can't leave the Mac quiet.
@MainActor
final class VolumeDucker {
    nonisolated static let rampSeconds: TimeInterval = 0.5
    private static let restoreKey = "muffleRestoreVolume"

    private let device: AudioObjectID
    private let original: Float32
    private var timer: Timer?

    init?() {
        guard let device = OutputDevice.defaultID, let volume = Self.volume(of: device), Self.isSettable(device) else {
            return nil
        }
        self.device = device
        original = volume
    }

    func duck(to level: Float) {
        if let uid = OutputDevice.uid(device) {
            UserDefaults.standard.set(["uid": uid, "volume": Double(original)], forKey: Self.restoreKey)
        }
        ramp(to: original * level)
    }

    func restore() {
        ramp(to: original) {
            UserDefaults.standard.removeObject(forKey: Self.restoreKey)
        }
    }

    static func restoreAfterCrash() {
        guard let saved = UserDefaults.standard.dictionary(forKey: restoreKey),
              let uid = saved["uid"] as? String, let volume = saved["volume"] as? Double,
              let device = OutputDevice.defaultID, OutputDevice.uid(device) == uid
        else { return }
        set(Float32(volume), on: device)
        UserDefaults.standard.removeObject(forKey: restoreKey)
    }

    private func ramp(to goal: Float32, completion: (() -> Void)? = nil) {
        timer?.invalidate()
        let start = Self.volume(of: device) ?? goal
        let began = Date()
        let device = device
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            let t = min(1, Float(Date().timeIntervalSince(began) / Self.rampSeconds))
            let eased = t * t * (3 - 2 * t)
            Self.set(start + (goal - start) * eased, on: device)
            if t >= 1 {
                timer.invalidate()
                MainActor.assumeIsolated { self?.timer = nil }
                completion?()
            }
        }
    }

    nonisolated private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        var address = volumeAddress
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    private static func isSettable(_ device: AudioObjectID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    nonisolated private static func set(_ volume: Float32, on device: AudioObjectID) {
        var address = volumeAddress
        var volume = max(0, min(1, volume))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }
}
