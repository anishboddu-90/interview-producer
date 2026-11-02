import Foundation
import AVFoundation
import Observation

actor RehearsalLatch {
    private var continuation: CheckedContinuation<Void,Never>?
    private var open = false
    func wait() async { if !open { await withCheckedContinuation { continuation = $0 } } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

@Observable final class RehearsalCapture: InterviewCaptureDevice {
    var onAudioBuffer: ((AVAudioPCMBuffer,AudioSource) -> Void)?
    var isCapturing = false; var micActive = false; var micSignalLost = false
    var micLevel: Float = 0; var audioLevel: Float = 0
    let inputDeviceName = "SYNTHETIC interviewer WAV"
    let outputDeviceName = "SYNTHETIC interviewee WAV"
    var systemAudioURL: URL?; var micAudioURL: URL?; var replayTime: Double? = 0
    var startCalls = 0; var stopCalls = 0
    var failure: String?; var silentMic = false; var startLatch: RehearsalLatch?
    private let root: URL
    private var files: [AudioSource:AVAudioFile] = [:]
    init(root: URL) { self.root = root }
    @MainActor func startCapture() async throws {
        startCalls += 1
        if let startLatch { await startLatch.wait() }
        if let failure { throw ProducerError.message(failure) }
        let folder = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        micAudioURL = folder.appendingPathComponent("mic-\(UUID()).caf"); systemAudioURL = folder.appendingPathComponent("system-\(UUID()).caf")
        files[.me] = try AVAudioFile(forWriting:micAudioURL!,settings:format.settings)
        files[.them] = try AVAudioFile(forWriting:systemAudioURL!,settings:format.settings)
        micActive = !silentMic; isCapturing = true
    }
    @MainActor func stopCapture() async { stopCalls += 1; isCapturing = false; micActive = false; micLevel = 0; audioLevel = 0; files = [:] }
    @MainActor func emit(_ samples: [Float],speaker: AudioSource,end: Double) throws {
        guard isCapturing else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(samples.count)),let channel = buffer.floatChannelData?[0] else { throw ProducerError.message("Could not create rehearsal audio buffer.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from:$0.baseAddress!,count:samples.count) }
        try files[speaker]?.write(from:buffer)
        replayTime = end
        let level = samples.reduce(Float(0)) { $0+abs($1) }/Float(max(1,samples.count))
        if speaker == .me { micLevel = level } else { audioLevel = level }
        onAudioBuffer?(buffer,speaker)
    }
}

struct RehearsalTurn: Codable,Sendable {
    var speaker: AudioSource; var text: String; var start: Double; var end: Double
}
struct RehearsalTape: Sendable {
    var me: [Float]; var them: [Float]; var turns: [RehearsalTurn]
    static let script: [(AudioSource,String)] = [
        (.me,"This is a synthetic software test. What did you hear in Project Aurora and Project Beacon?"),
        (.them,"This is fictional rehearsal testimony. The fictional Cedar Route exchange began in 2018. A Portland organizer swapped bills with us. Compare the fictional Tape Cedar with Tape Elm. Listen for pulsing delay and thinner electronic layers. It is a comparison of two recordings, not a claim about the whole scene."),
        (.me,"Who made an overlooked contribution to those performances?"),
        (.them,"A fictional volunteer called Test Rowan repaired the tape machines. That repair work changed what our group could perform. There was a turning point when we nearly stopped organizing shows altogether."),
        (.me,"Interesting. Let us switch to this week's timetable and the dates of the next shows.")
    ]
    static func load(folder: URL? = nil) throws -> Self {
        var me = [Float](), them = [Float](), turns = [RehearsalTurn]()
        for (i,turn) in script.enumerated() {
            let samples: [Float]
            if let folder {
                let file = try AVAudioFile(forReading:folder.appendingPathComponent("turn-\(i).wav"))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else { throw ProducerError.message("Rehearsal WAV must be mono 16 kHz.") }
                try file.read(into:buffer)
                guard let data = buffer.floatChannelData?[0] else { throw ProducerError.message("Rehearsal WAV did not decode as float samples.") }
                samples = Array(UnsafeBufferPointer(start:data,count:Int(buffer.frameLength)))
            } else { samples = [Float](repeating:0.05+Float(i)*0.001,count:112000) }
            let start = Double(me.count)/16000
            let padded = max(120000,samples.count+128000)
            let waveform = samples+[Float](repeating:0,count:padded-samples.count)
            let silence = [Float](repeating:0,count:waveform.count)
            me += turn.0 == .me ? waveform : silence; them += turn.0 == .them ? waveform : silence
            turns.append(.init(speaker:turn.0,text:turn.1,start:start,end:start+Double(samples.count)/16000))
        }
        return .init(me:me,them:them,turns:turns)
    }
    @MainActor func play(into device: RehearsalCapture,frames: Range<Int>? = nil) async throws {
        let range = frames ?? 0..<me.count
        for offset in stride(from:range.lowerBound,to:range.upperBound,by:1600) {
            let end = min(range.upperBound,offset+1600); let time = Double(end)/16000
            try device.emit(Array(me[offset..<end]),speaker:.me,end:time)
            try device.emit(Array(them[offset..<end]),speaker:.them,end:time)
            if offset%16000 == 0 { await Task.yield() }
        }
    }
    func text(for chunk: AudioChunk) -> String {
        turns.filter { $0.speaker == chunk.speaker && $0.end >= chunk.start && $0.start <= chunk.end }.map(\.text).joined(separator:" ")
    }
}
final class RehearsalChunks: @unchecked Sendable {
    private let lock = NSLock(); private var chunks: [AudioChunk] = []
    func append(_ chunk: AudioChunk) { lock.withLock { chunks.append(chunk) } }
    var count: Int { lock.withLock { chunks.count } }
    var speakers: Set<AudioSource> { lock.withLock { Set(chunks.map(\.speaker)) } }
}
