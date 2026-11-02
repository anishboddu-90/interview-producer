import Foundation

struct AudioChunk: Sendable {
    var id = UUID(); var speaker: AudioSource; var start: Double; var end: Double; var samples: [Float]
}

/// Audio callbacks feed a bounded, independent segmenter; networking never blocks capture.
final class PCMChunker: @unchecked Sendable {
    struct Track { var samples = [Float](); var start: Double = 0; var trailingSilence = 0; var voiced = false }
    private let lock = NSLock()
    private var tracks: [AudioSource:Track] = [:]
    private var enabled = true
    var onChunk: (@Sendable (AudioChunk) -> Void)?
    func ingest(_ samples: [Float], speaker: AudioSource, at time: Double) {
        guard !samples.isEmpty else { return }
        let chunk: AudioChunk? = lock.withLock {
            guard enabled else { return nil }
            var t = tracks[speaker] ?? Track()
            let energy = samples.reduce(0) { $0 + abs($1) }/Float(samples.count)
            let voice = energy > 0.002
            if t.samples.isEmpty { t.start = max(0,time-Double(samples.count)/16000) }
            // Keep only 200 ms of preroll when silent.
            if !t.voiced && !voice {
                t.samples = Array((t.samples + samples).suffix(3200)); t.start = max(0,time-Double(t.samples.count)/16000)
                tracks[speaker] = t; return nil
            }
            t.voiced = t.voiced || voice; t.samples.append(contentsOf:samples)
            t.trailingSilence = voice ? 0 : t.trailingSilence + samples.count
            var result: AudioChunk?
            if t.samples.count >= 192000 || (t.samples.count >= 104000 && t.trailingSilence >= 11200) {
                result = AudioChunk(speaker:speaker,start:t.start,end:t.start+Double(t.samples.count)/16000,samples:t.samples)
                t = Track()
            }
            tracks[speaker] = t; return result
        }
        if let chunk { onChunk?(chunk) }
    }
    func finish() {
        let chunks: [AudioChunk] = lock.withLock {
            enabled = false
            let out = tracks.compactMap { speaker,t -> AudioChunk? in
                guard t.voiced, t.samples.count >= 4000 else { return nil }
                return AudioChunk(speaker:speaker,start:t.start,end:t.start+Double(t.samples.count)/16000,samples:t.samples)
            }
            tracks = [:]; return out
        }
        chunks.forEach { onChunk?($0) }
    }
}

actor TranscriptPipeline {
    private var pending = [AudioChunk]()
    private var processed = Set<UUID>()
    private var busy = false
    private var cancelled = false
    private var onLine: @Sendable (InterviewLine) async -> Void
    private var onError: @Sendable (String) async -> Void
    private let injectedTranscriber: (@Sendable (AudioChunk) async throws -> String)?
    init(onLine: @escaping @Sendable (InterviewLine) async -> Void,onError: @escaping @Sendable (String) async -> Void, transcriber: (@Sendable (AudioChunk) async throws -> String)? = nil) { self.onLine = onLine; self.onError = onError; self.injectedTranscriber = transcriber }
    func enqueue(_ chunk: AudioChunk) async {
        guard !cancelled, !processed.contains(chunk.id), !pending.contains(where:{$0.id == chunk.id}) else { return }
        guard pending.count < 12 else { await onError("Transcription backlog exceeded two minutes. Audio is saved locally; a chunk was skipped."); return }
        pending.append(chunk)
        guard !busy else { return }
        busy = true
        while !pending.isEmpty && !cancelled {
            let item = pending.removeFirst(); processed.insert(item.id)
            if processed.count > 2400 { processed = [item.id] }
            do {
                if let injectedTranscriber {
                    let text = try await injectedTranscriber(item)
                    if !cancelled { await onLine(InterviewLine(start:item.start,end:item.end,speaker:item.speaker,text:text)) }
                    continue
                }
                var text: String?
                for attempt in 0..<2 {
                    do { text = try await TranscriptionProvider.transcribe(item); break }
                    catch {
                        guard attempt == 0, error is URLError else { throw error }
                        try await Task.sleep(for:.seconds(2))
                    }
                }
                if let text = text?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty, !cancelled {
                    await onLine(InterviewLine(start:item.start,end:item.end,speaker:item.speaker,text:text))
                }
            } catch { if !cancelled { await onError("Transcription gap [\(Int(item.start))s, \(item.speaker.label)]: \(error.localizedDescription)") } }
        }
        busy = false
    }
    func drain() async {
        while !cancelled && (busy || !pending.isEmpty) {
            do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
        }
    }
    func cancel() { cancelled = true; pending = [] }
}
