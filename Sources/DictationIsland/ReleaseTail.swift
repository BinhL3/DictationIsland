import AVFoundation
import Accelerate
import os

/// How long the mic keeps listening after the key comes up.
///
/// 200 ms always, because a release often lands while the last word is still sounding. When you
/// are still talking at that point, it keeps going until 160 ms of quiet, at most 600 ms after
/// the release (Hex #1101/#1103 measured last words cut off by a fixed tail).
///
/// The stop sound plays at the release and a laptop mic hears it, so audio during the sound
/// (plus 60 ms) counts as neither speech nor quiet. Speech before the release is clean, so a word
/// said through the release still grows the tail.
enum ReleaseTail {
    static let frame = 0.01
    static let base = 20  // frames
    static let cap = 60
    /// Speech frames a run needs (gaps up to `gap` frames bridge), so a key click never counts.
    static let sustain = 10
    static let gap = 4
    /// Quiet after the last speech frame that ends a grown tail.
    static let quietEnd = 16
    static let toneMargin = 0.06

    enum Verdict: Equatable { case wait, grow, stop }

    /// - Parameters:
    ///   - speech: one flag per 10 ms frame of the take, true where it was speech.
    ///   - release: the frame where the key came up.
    ///   - tone: frames after the release the stop sound may cover.
    ///   - grown: whether the tail already grew past `base`.
    static func verdict(speech: [Bool], release: Int, tone: Int, grown: Bool) -> Verdict {
        let n = speech.count
        if n < release + base { return .wait }
        if n >= release + cap { return .stop }
        func clean(_ i: Int) -> Bool { i < release || i >= release + tone }
        guard let last = (0..<n).last(where: { clean($0) && speech[$0] }) else { return .stop }
        // The run that frame ends: speech frames back to the first gap longer than `gap`.
        var count = 0, quiet = 0, i = last
        while i >= 0 {
            if !clean(i) {
                // Under the stop sound: can't tell, so it neither counts nor breaks the run.
            } else if speech[i] {
                count += 1
                quiet = 0
            } else {
                quiet += 1
                if quiet > gap { break }
            }
            i -= 1
        }
        guard count >= sustain else { return .stop }
        let quietAfter = (last + 1..<n).filter(clean).count
        // Before growing, the run must reach the tail's end; once grown, it ends on real quiet.
        return quietAfter <= (grown ? quietEnd - 1 : gap) ? .grow : .stop
    }
}

/// Follows one take's own voice (before computer audio is mixed in): which 10 ms frames are
/// speech, for the release tail, and whether the mic delivered anything but digital silence.
/// Written on the audio thread, read on the main actor.
final class TakeActivity: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var speech: [Bool] = []
    /// Frame levels in whole dB, -120...0, for the noise floor.
    private var histogram = [Int](repeating: 0, count: 121)
    private var pending: [Float] = []
    private var release: Int?
    private var heardSignal = false

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let frameLength = max(1, Int(buffer.format.sampleRate * ReleaseTail.frame))
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        pending.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        var start = 0
        while pending.count - start >= frameLength {
            var peak: Float = 0
            var rms: Float = 0
            pending.withUnsafeBufferPointer {
                vDSP_maxmgv($0.baseAddress! + start, 1, &peak, vDSP_Length(frameLength))
                rms = acRMS($0.baseAddress! + start, frameLength)
            }
            if peak > 0 { heardSignal = true }
            let db = 20 * log10(max(rms, 1e-6))
            histogram[min(120, max(0, Int(db.rounded()) + 120))] += 1
            speech.append(Double(db) > Swift.max(floor() + 12, -58))
            start += frameLength
        }
        pending.removeFirst(start)
    }

    /// The 15th percentile frame level so far. A take is mostly pauses and speech; its quietest
    /// part is the room.
    private func floor() -> Double {
        let total = histogram.reduce(0, +)
        var seen = 0
        for (index, frames) in histogram.enumerated() {
            seen += frames
            if seen * 100 >= total * 15 { return Double(index - 120) }
        }
        return -120
    }

    func markRelease() {
        os_unfair_lock_lock(&lock)
        release = speech.count
        os_unfair_lock_unlock(&lock)
    }

    func verdict(tone: TimeInterval, grown: Bool) -> ReleaseTail.Verdict {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let release else { return .stop }
        let toneFrames = tone > 0 ? Int(((tone + ReleaseTail.toneMargin) / ReleaseTail.frame).rounded(.up)) : 0
        return ReleaseTail.verdict(speech: speech, release: release, tone: toneFrames, grown: grown)
    }

    /// The mic ran but every sample was exactly zero (or nothing arrived): an input that went
    /// dead without an error, as after some calls (Hex #1122).
    var wasDigitalSilence: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return !heardSignal
    }
}
