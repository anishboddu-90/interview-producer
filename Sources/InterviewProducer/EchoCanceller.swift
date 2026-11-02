import Foundation
import CSpeexDSP

/// Acoustic echo canceller (SpeexDSP MDF).
///
/// When the call plays through the Mac's speakers, the mic picks it up and the
/// other person's voice would be transcribed a second time as "Me". Parrot already
/// captures that exact speaker output as the system-audio stream (via
/// ScreenCaptureKit), so we use it as the AEC *reference* and subtract it from the
/// mic — the same near-end + far-end approach Zoom/Meet use, just with the
/// reference we capture instead of one we play.
///
/// Everything works on 16 kHz mono, 10 ms frames (160 samples), matching the rest
/// of the pipeline. Fail-safe: if the canceller can't initialise, `process` returns
/// the mic audio untouched — the mic is never silenced.
final class EchoCanceller {
    private var echoState: OpaquePointer?
    private var preprocess: OpaquePointer?

    private let frameSize = 160          // 10 ms @ 16 kHz
    private let filterTail: Int          // 2048 = ~128 ms echo tail
    private let sampleRate: Int32 = 16000

    /// Far-end reference (system audio) waiting to be paired with mic frames, and
    /// the mic accumulator. Int16 is what SpeexDSP operates on.
    private var reference: [Int16] = []
    /// Index of the first unconsumed sample in `reference`. Advancing this instead
    /// of `removeFirst`-ing every 10 ms frame keeps reads O(1) amortized; the
    /// consumed prefix is reclaimed in bulk by `compactReferenceIfNeeded`.
    private var referenceHead = 0
    private var micAccum: [Int16] = []
    private let lock = NSLock()
    private let maxReference = 16000 * 5  // cap the reference ring at 5 s

    var isActive: Bool { echoState != nil }

    /// Mic frames let through uncancelled because no reference came for
    /// `maxHold` (system audio stopped, or a gap). Diagnostic, read with
    /// `referenceBacklog` for the once-a-minute alignment log (#98).
    private(set) var starvedFrames = 0

    /// Unconsumed far-end reference samples waiting to be paired with mic frames.
    /// Diagnostic only: a backlog that keeps growing means the mic stopped
    /// consuming (dead tap) while system audio kept arriving.
    var referenceBacklog: Int {
        lock.lock(); defer { lock.unlock() }
        return reference.count - referenceHead
    }

    /// How much echo came out while they talked, since the last read. Fed and
    /// read on the mic thread only (`process` and the minute log), so no lock.
    private var stats = EchoStats()

    /// The minute's echo numbers, then start a new minute. nil: too little of
    /// them talking to judge.
    func takeStats() -> EchoStats.Summary? {
        defer { stats = EchoStats() }
        return stats.summary()
    }

    /// Debug (#98, `PARROT_AEC_DUMP`): each batch's raw mic frames and the
    /// exact reference frames they were paired with (zeros when starved),
    /// so `--aec-replay` can feed Speex what it saw live. Mic thread.
    var onPairs: ((_ mic: [Int16], _ ref: [Int16]) -> Void)?

    /// #98: live, each mic frame met the oldest reference waiting, and on 3
    /// of 5 speaker runs that left the echo reaching the mic just before its
    /// reference, which a causal filter can't model (3-4 dB instead of 18).
    /// Replays of those runs cancel 13-19 dB with the reference 10-30 ms
    /// fresher, and every run fails 10 ms staler. So the first pairing skips
    /// `lead` of reference, and the mic waits for the reference it needs
    /// instead of pairing with silence (each of those made the reference a
    /// frame staler for good). The mic comes out ~20 ms later.
    private let lead: Int
    /// No reference for this long (system audio stopped, a gap): stop
    /// waiting, let all the held mic through uncancelled, start over.
    private let maxHold = 1600  // 100 ms
    // Under `lock`:
    private var leadApplied = false
    /// Reference waiting at the very first mic buffer: the startup state a
    /// mic restart goes back to.
    private var startBacklog: Int?
    private var resyncPending = false

    /// `filterTail` and `lead` are for `--aec-replay`, whose dumps already
    /// hold the live pairing; the app always uses 2048 and 320 (20 ms).
    init(filterTail: Int = 2048, lead: Int = 320) {
        self.filterTail = filterTail
        self.lead = lead
        echoState = speex_echo_state_init(Int32(frameSize), Int32(filterTail))
        var rate = sampleRate
        if let echoState {
            _ = speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        }
        preprocess = speex_preprocess_state_init(Int32(frameSize), sampleRate)
        if let preprocess, let echoState {
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE,
                                     UnsafeMutableRawPointer(echoState))
        }
    }

    deinit {
        if let echoState { speex_echo_state_destroy(echoState) }
        if let preprocess { speex_preprocess_state_destroy(preprocess) }
    }

    /// Feed far-end reference samples (the system audio). Called from the SCK
    /// callback, concurrently with `process`.
    func pushReference(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let ints = samples.map(Self.toInt16)
        lock.lock()
        reference.append(contentsOf: ints)
        // Cap the *unconsumed* reference at maxReference by dropping the oldest.
        let unconsumed = reference.count - referenceHead
        if unconsumed > maxReference {
            referenceHead += unconsumed - maxReference
        }
        compactReferenceIfNeeded()
        lock.unlock()
    }

    /// Cancel echo from a mic buffer. Returns cleaned samples for whatever whole
    /// 10 ms frames completed (possibly empty if fewer than 160 samples have
    /// accumulated). On any failure, returns the input unchanged.
    func process(mic samples: [Float]) -> [Float] {
        guard let echoState, let preprocess else { return samples }

        let micInts = samples.map(Self.toInt16)

        // Pair each mic frame with a reference frame under the lock, then run the
        // (heavier) DSP outside it so pushReference isn't blocked.
        // ponytail: FIFO pairing with a fixed 20 ms head start, no timestamps;
        // measured on one MacBook Pro. Upgrade path: estimate the echo delay
        // per call (`--aec-replay` shows the window) or PTS + AVAudioTime.
        var pairs: [([Int16], [Int16])] = []
        lock.lock()
        // Mic still waiting from before a restart's gap goes through
        // uncancelled: its reference is long gone. (A part frame stays and
        // joins the new audio: that pairing starts under 10 ms off.)
        var preGap = 0
        if resyncPending, let startBacklog {
            // Back to the startup state: drop what piled up while the mic was down.
            preGap = micAccum.count / frameSize * frameSize
            referenceHead += max(0, reference.count - referenceHead - startBacklog)
            leadApplied = false
            resyncPending = false
        }
        micAccum.append(contentsOf: micInts)
        if startBacklog == nil { startBacklog = reference.count - referenceHead }
        var micIndex = 0
        var outage = false
        while micAccum.count - micIndex >= frameSize {
            if micIndex >= preGap, !leadApplied, reference.count - referenceHead >= lead + frameSize {
                referenceHead += lead
                leadApplied = true
            }
            var refFrame = [Int16](repeating: 0, count: frameSize)
            if micIndex < preGap {
                // through as is
            } else if !outage, leadApplied, reference.count - referenceHead >= frameSize {
                refFrame = Array(reference[referenceHead ..< referenceHead + frameSize])
                referenceHead += frameSize
            } else if outage || micAccum.count - micIndex > maxHold {
                // All of it, not just the excess: mic held back while the
                // reference was missing would leave every later pairing stale.
                outage = true
                leadApplied = false
                starvedFrames += 1
            } else {
                break  // its reference is on the way
            }
            pairs.append((Array(micAccum[micIndex ..< micIndex + frameSize]), refFrame))
            micIndex += frameSize
        }
        // At most `maxHold` of mic stays waiting, so this shift is cheap.
        if micIndex > 0 { micAccum.removeFirst(micIndex) }
        compactReferenceIfNeeded()
        lock.unlock()

        guard !pairs.isEmpty else { return [] }
        onPairs?(pairs.flatMap(\.0), pairs.flatMap(\.1))

        var out: [Float] = []
        out.reserveCapacity(pairs.count * frameSize)
        for (micFrame, refFrame) in pairs {
            var outFrame = [Int16](repeating: 0, count: frameSize)
            micFrame.withUnsafeBufferPointer { mic in
                refFrame.withUnsafeBufferPointer { ref in
                    speex_echo_cancellation(echoState, mic.baseAddress, ref.baseAddress, &outFrame)
                }
            }
            let filtered = outFrame
            _ = speex_preprocess_run(preprocess, &outFrame)
            stats.add(mic: micFrame, ref: refFrame, filtered: filtered, out: outFrame)
            out.append(contentsOf: outFrame.map(Self.toFloat))
        }
        return out
    }

    /// The mic engine restarted (AirPods, an input change): the reference
    /// that piles up while it's down would leave every pairing seconds stale
    /// for the rest of the call. The next mic buffer starts over instead.
    func micRestarted() {
        lock.lock()
        resyncPending = true
        lock.unlock()
    }

    /// Reclaim the consumed reference prefix once it's at least half the buffer,
    /// so per-frame reads stay O(1) amortized instead of O(n) `removeFirst`.
    private func compactReferenceIfNeeded() {
        if referenceHead > 0, referenceHead * 2 >= reference.count {
            reference.removeFirst(referenceHead)
            referenceHead = 0
        }
    }

    private static func toInt16(_ f: Float) -> Int16 {
        Int16(max(-1, min(1, f)) * 32767)
    }
    private static func toFloat(_ i: Int16) -> Float {
        Float(i) / 32767
    }
}

/// #98: the alignment log proved the canceller was in step, never that it
/// removed anything. This measures that, per 10 ms frame while they talk,
/// in dB. Pure, so `--profile-test` checks it.
struct EchoStats {
    struct Summary {
        /// Frames of them talking behind the numbers.
        var frames: Int
        /// Raw mic vs what reaches the file and the transcriber.
        var removed: Float
        /// Raw mic vs the linear filter alone, before Speex's suppressor:
        /// says which stage is failing.
        var filterAlone: Float
        /// Raw mic vs their audio: how loud the speakers reach the mic.
        var hears: Float
    }

    private var removed: [Float] = []
    private var filterAlone: [Float] = []
    private var hears: [Float] = []

    /// Only while they talk: with them silent there's no echo to remove.
    mutating func add(mic: [Int16], ref: [Int16], filtered: [Int16], out: [Int16]) {
        let meanAbs = ref.reduce(0) { $0 + abs(Float($1)) } / Float(ref.count) / 32767
        guard meanAbs > EchoGate.talkingFloor else { return }
        let m = Self.power(mic)
        removed.append(Self.dB(m, Self.power(out)))
        filterAlone.append(Self.dB(m, Self.power(filtered)))
        hears.append(Self.dB(m, Self.power(ref)))
    }

    /// Medians, not means: when I talk over them, the raw mic is my voice,
    /// which the canceller rightly keeps, so those frames read as "removed
    /// nothing". The median ignores them while they talk alone half the time.
    func summary() -> Summary? {
        // 1 s of them talking: less, and one "Yeah" of theirs fills the line.
        guard removed.count >= 100 else { return nil }
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        return Summary(frames: removed.count, removed: median(removed),
                       filterAlone: median(filterAlone), hears: median(hears))
    }

    private static func power(_ frame: [Int16]) -> Double {
        frame.reduce(0) { $0 + Double($1) * Double($1) } / Double(frame.count)
    }

    /// One step of Int16 (power 1) as the floor, so silence reads as a big
    /// number instead of infinity: up to ~90 dB on a loud frame.
    private static func dB(_ a: Double, _ b: Double) -> Float {
        Float(10 * log10((a + 1) / (b + 1)))
    }
}
