import AVFoundation
import CoreAudio
import os

/// Hears what the Mac is playing (a video, a call, a voice memo) so a dictation can include it.
/// A Core Audio process tap over every other app, left *unmuted* so you keep hearing it, in a
/// private aggregate device. The realtime IO thread only copies a mono mix into a small ring; the
/// mic path pulls from the ring and adds it to each mic buffer, so the transcriber hears one
/// stream: you and the computer together. Needs System Audio Recording.
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    let sampleRate: Double

    /// Mono frames from the tap, newest last; about a second, oldest dropped when full.
    private var ring = [Float](repeating: 0, count: 96_000)
    private var readIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()
    /// Fractional read position when resampling to the mic's rate.
    private var phase: Double = 0

    init?() {
        guard let own = Self.processObject(pid: getpid()) else { return nil }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mSampleRate > 0
        else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        sampleRate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DictationIsland Computer Audio",
            kAudioAggregateDeviceUIDKey: "dev.voicedictation.computer.\(UUID().uuidString)",
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
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, _, _, _ in
            self?.capture(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), channels: channels, interleaved: interleaved)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            teardown()
            return nil
        }
    }

    deinit { teardown() }

    /// Realtime IO thread: downmix to mono and append to the ring.
    private func capture(_ buffers: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool) {
        guard let first = buffers.first, let data = first.mData else { return }
        let frames: Int
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if interleaved {
            let samples = data.assumingMemoryBound(to: Float.self)
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                push(sum / Float(max(1, channels)))
            }
        } else {
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let planes = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            for frame in 0..<frames {
                var sum: Float = 0
                for plane in planes { sum += plane[frame] }
                push(sum / Float(max(1, planes.count)))
            }
        }
    }

    private func push(_ sample: Float) {
        let capacity = ring.count
        ring[(readIndex + count) % capacity] = sample
        if count < capacity { count += 1 } else { readIndex = (readIndex + 1) % capacity }
    }

    /// Mic thread: adds the computer's audio to a mono mic buffer, resampled to its rate.
    func mix(into buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        let step = sampleRate / buffer.format.sampleRate
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let capacity = ring.count
        for i in 0..<frames {
            let whole = Int(phase)
            guard whole + 1 < count else { break }  // ran dry: the rest of this buffer is mic only
            let a = ring[(readIndex + whole) % capacity], b = ring[(readIndex + whole + 1) % capacity]
            let t = Float(phase - Double(whole))
            samples[i] = max(-1, min(1, samples[i] + a + (b - a) * t))
            phase += step
        }
        // Drop what was consumed.
        let consumed = min(Int(phase), count)
        readIndex = (readIndex + consumed) % capacity
        count -= consumed
        phase -= Double(consumed)
        // Don't let the computer's audio fall behind the mic: keep at most ~0.2 s queued.
        let maxQueued = Int(sampleRate * 0.2)
        if count > maxQueued {
            readIndex = (readIndex + count - maxQueued) % capacity
            count = maxQueued
        }
    }

    private func teardown() {
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

/// The current take's computer-audio source, swapped from the main thread, read on the mic's.
final class ComputerAudioSlot: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var capture: SystemAudioCapture?

    var isOn: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return capture != nil
    }

    func set(_ capture: SystemAudioCapture?) {
        os_unfair_lock_lock(&lock)
        let old = self.capture
        self.capture = capture
        os_unfair_lock_unlock(&lock)
        _ = old  // torn down outside the lock
    }

    func mix(into buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&lock)
        let capture = self.capture
        os_unfair_lock_unlock(&lock)
        capture?.mix(into: buffer)
    }
}
