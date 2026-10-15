import AVFoundation
import Accelerate

/// Lock-protected bar levels written on the audio thread and read by the waveform's render loop.
/// Kept outside Observation on purpose: Alcove drives its `NSWaveformView`s from a shared
/// `WaveformAnimationClock` instead of invalidating SwiftUI on every audio buffer.
final class LevelMeter: @unchecked Sendable {
    let bandCount: Int
    private var levels: [Float]
    private let lock = NSLock()

    init(bandCount: Int) {
        self.bandCount = bandCount
        self.levels = Array(repeating: 0, count: bandCount)
    }

    func write(_ newLevels: [Float]) {
        lock.lock()
        levels = newLevels
        lock.unlock()
    }

    func read() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    func reset() {
        write(Array(repeating: 0, count: bandCount))
    }
}

/// Splits mic audio into log-spaced voice bands, like Alcove's `AudioFrequencyBand(startFrequency:endFrequency:)`
/// spectrum sessions, but fed from the microphone instead of a process tap.
final class SpectrumAnalyzer {
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private let bands: [(start: Float, end: Float)]

    init(bandCount: Int, fftSize: Int = 1024, minFrequency: Float = 90, maxFrequency: Float = 5_000) {
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let ratio = pow(maxFrequency / minFrequency, 1 / Float(bandCount))
        self.bands = (0..<bandCount).map { i in
            (minFrequency * pow(ratio, Float(i)), minFrequency * pow(ratio, Float(i + 1)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Returns one 0...1 level per band. Overall height follows loudness (dBFS), the per-bar
    /// shape follows the spectrum, so silence stays flat regardless of FFT scaling.
    func levels(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> [Float] {
        let n = min(count, fftSize)
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        let db = 20 * log10(max(rms, 1e-7))
        let loudness = max(0, min(1, (db + 55) / 40))

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let binWidth = Float(sampleRate) / Float(fftSize)
        let energies: [Float] = bands.map { band in
            let lo = max(1, Int(band.start / binWidth))
            let hi = min(half - 1, max(lo + 1, Int(band.end / binWidth)))
            var sum: Float = 0
            vDSP_sve(Array(magnitudes[lo..<hi]), 1, &sum, vDSP_Length(hi - lo))
            return sum / Float(hi - lo)
        }
        let peak = max(energies.max() ?? 0, 1e-12)
        return energies.map { loudness * (0.35 + 0.65 * sqrt($0 / peak)) }
    }
}

/// Owns the microphone. Every buffer is downmixed to mono, then fanned out to the level meter
/// and the transcriber, so stereo USB mics (Blue Yeti: 2 channels) behave like any other input.
///
/// Building the engine graph takes ~170 ms (more on first use); starting a built one ~60 ms.
/// So the graph is built ahead of time with `prepare` and kept across sessions: a prepared,
/// stopped engine doesn't open the mic (no menu bar indicator), and pressing the key only has
/// to start it. Reusing one engine also avoids the spurious configuration-change notifications
/// that releasing an engine sends to the next one.
final class AudioCapture {
    /// A built, prepared engine for one input and channel choice.
    private struct Graph {
        let engine: AVAudioEngine
        let deviceUID: String?
        let channel: InputChannel
        let deviceID: AudioDeviceID?
        let hardware: AVAudioFormat
    }

    private var graph: Graph?
    private let handler = BufferHandler()
    private let analyzer: SpectrumAnalyzer
    private let meter: LevelMeter

    init(meter: LevelMeter) {
        self.meter = meter
        self.analyzer = SpectrumAnalyzer(bandCount: meter.bandCount)
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Builds the engine for this input now so a later `start` is quick. No-op without mic
    /// permission, while running, or if it's already built for these settings.
    func prepare(deviceUID: String?, channel: InputChannel) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              !(graph?.engine.isRunning ?? false) else { return }
        _ = try? reusableGraph(deviceUID: deviceUID, channel: channel)
    }

    /// - Parameters:
    ///   - deviceUID: Core Audio UID of the input to open; nil uses the system default.
    ///   - channel: which input channel(s) to keep.
    func start(deviceUID: String?, channel: InputChannel, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stopObserving()
        rebuilds = 0
        handler.set(onBuffer)
        do {
            try reusableGraph(deviceUID: deviceUID, channel: channel).engine.start()
        } catch {
            // The prepared engine went stale in a way the checks missed; build a fresh one.
            graph = nil
            try buildGraph(deviceUID: deviceUID, channel: channel).engine.start()
        }
        observeConfiguration(deviceUID: deviceUID, channel: channel)
    }

    func stop() {
        stopObserving()
        handler.set(nil)
        graph?.engine.stop()
        meter.reset()
    }

    private var configurationObserver: NSObjectProtocol?
    /// Rebuilds after real configuration changes this session; capped so a device that keeps
    /// stopping can't turn into a loop.
    private var rebuilds = 0
    private static let maxRebuilds = 3

    /// A change to the system's audio setup (a Bluetooth headset switching profile, a device
    /// appearing) can stop the engine; rebuild it so the session keeps hearing you. The
    /// notification also fires spuriously while the engine keeps running, so only act if it
    /// really stopped. Rebuilding on a spurious one loops: each rebuild releases an engine, which
    /// posts another (the menu bar mic icon flickers).
    private func observeConfiguration(deviceUID: String?, channel: InputChannel) {
        guard let engine = graph?.engine else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, let graph = self.graph, !graph.engine.isRunning,
                  self.rebuilds < Self.maxRebuilds else { return }
            self.rebuilds += 1
            self.stopObserving()
            self.graph = nil
            guard (try? self.buildGraph(deviceUID: deviceUID, channel: channel).engine.start()) != nil else { return }
            self.observeConfiguration(deviceUID: deviceUID, channel: channel)
        }
    }

    private func stopObserving() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    /// The prepared graph if it still matches the settings and the hardware, else a new one.
    private func reusableGraph(deviceUID: String?, channel: InputChannel) throws -> Graph {
        if let graph, graph.deviceUID == deviceUID, graph.channel == channel,
           graph.deviceID == Self.deviceID(uid: deviceUID) {
            let current = graph.engine.inputNode.inputFormat(forBus: 0)
            if current.sampleRate == graph.hardware.sampleRate, current.channelCount == graph.hardware.channelCount {
                return graph
            }
        }
        graph = nil
        return try buildGraph(deviceUID: deviceUID, channel: channel)
    }

    /// The device a graph for `uid` opens: that device if present, else the system default input.
    private static func deviceID(uid: String?) -> AudioDeviceID? {
        if let uid, let device = AudioDevices.device(uid: uid) { return device.id }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    private func buildGraph(deviceUID: String?, channel: InputChannel) throws -> Graph {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let device = AudioDevices.device(uid: deviceUID) {
            try select(device: device.id, on: input)
        }

        // After switching devices the input bus keeps the *previous* device's format (e.g. 1 ch
        // from the built-in mic instead of the Yeti's 2). Connecting it with the hardware format
        // fixes that. Never touch `mainMixerNode`: it drags in the output device.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
              let busFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { throw AudioCaptureError.noInput }
        // Silent node the input is connected to, so the input bus adopts the device's real format.
        let sink = AVAudioMixerNode()
        engine.attach(sink)
        engine.connect(input, to: sink, format: busFormat)
        sink.outputVolume = 0

        let format = input.outputFormat(forBus: 0)
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw AudioCaptureError.noInput
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [analyzer, meter, handler] buffer, _ in
            guard let onBuffer = handler.get(),
                  let monoBuffer = Self.downmix(buffer, to: mono, channel: channel) else { return }
            onBuffer(monoBuffer)
            let levels = analyzer.levels(
                samples: monoBuffer.floatChannelData![0],
                count: Int(monoBuffer.frameLength),
                sampleRate: mono.sampleRate
            )
            meter.write(levels)
        }
        engine.prepare()
        let graph = Graph(
            engine: engine, deviceUID: deviceUID, channel: channel,
            deviceID: Self.deviceID(uid: deviceUID), hardware: hardware
        )
        self.graph = graph
        return graph
    }

    private func select(device: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw AudioCaptureError.noInput }
        var id = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioCaptureError.deviceUnavailable(status) }
    }

    private static func downmix(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, channel: InputChannel) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        output.frameLength = buffer.frameLength
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let destination = output.floatChannelData![0]

        switch channel {
        case .left:
            destination.update(from: source[0], count: Int(frames))
        case .right:
            destination.update(from: source[min(1, channels - 1)], count: Int(frames))
        case .mix:
            destination.update(from: source[0], count: Int(frames))
            guard channels > 1 else { break }
            for index in 1..<channels {
                vDSP_vadd(destination, 1, source[index], 1, destination, 1, frames)
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(destination, 1, &scale, destination, 1, frames)
        }
        return output
    }
}

/// The current session's buffer consumer, swapped from the main thread and read on the tap's.
private final class BufferHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func set(_ onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.onBuffer = onBuffer
        lock.unlock()
    }

    func get() -> ((AVAudioPCMBuffer) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return onBuffer
    }
}

enum AudioCaptureError: LocalizedError {
    case noInput
    case deviceUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input available"
        case .deviceUnavailable: return "Selected microphone is unavailable"
        }
    }
}

/// Holds mic buffers until the transcriber is ready, then flushes them in order and forwards
/// live. Written from the audio thread, opened from the main actor.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var sink: Transcriber?
    /// ~20 s at 1024-frame buffers; plenty for model start-up.
    private let maxPending = 1000

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let sink {
            sink.append(buffer)
        } else if pending.count < maxPending {
            pending.append(buffer)
        }
    }

    func open(into sink: Transcriber) {
        lock.lock()
        defer { lock.unlock() }
        pending.forEach(sink.append)
        pending = []
        self.sink = sink
    }
}
