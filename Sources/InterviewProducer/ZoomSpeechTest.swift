import Foundation
import AVFoundation

/// Diagnostic only: native Zoom capture, isolated archive and real cloud inference.
/// Microphone buffers are never handed to transcription. Both generated actors
/// arrive through one remote Zoom endpoint, so both correctly use `.them`.
final class ZoomOnlyTestCapture: InterviewCaptureDevice {
    let native = AudioCaptureManager()
    let root: URL
    var onAudioBuffer: ((AVAudioPCMBuffer,AudioSource) -> Void)?
    var isCapturing: Bool { native.isCapturing }
    var micActive: Bool { native.micActive }
    var micSignalLost: Bool { native.micSignalLost }
    var micLevel: Float { native.micLevel }
    var audioLevel: Float { native.audioLevel }
    var inputDeviceName: String { native.inputDeviceName }
    var outputDeviceName: String { native.outputDeviceName }
    var systemAudioURL: URL? { root.appendingPathComponent("Audio/Zoom-received.caf") }
    var micAudioURL: URL? { nil }
    var replayTime: Double? { nil }
    init(root: URL) { self.root = root }
    @MainActor func startCapture() async throws {
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Audio"),withIntermediateDirectories:true)
        native.onAudioBuffer = { [weak self] buffer,source in
            guard source == .them else { return }
            self?.onAudioBuffer?(buffer,source)
        }
        try await native.startCapture()
    }
    @MainActor func stopCapture() async {
        await native.stopCapture(); native.onAudioBuffer = nil
        if let source = native.systemAudioURL, let destination = systemAudioURL,
           FileManager.default.fileExists(atPath:source.path) {
            do { try FileManager.default.copyItem(at:source,to:destination); try FileManager.default.removeItem(at:source) }
            catch { print("Zoom diagnostic audio finalization: \(error.localizedDescription)") }
        }
        // Delete only this capture's newly created ambient microphone diagnostic.
        if let url = native.micAudioURL { try? FileManager.default.removeItem(at:url) }
    }
}

actor ZoomInferenceLog {
    let root: URL; var calls = 0; var inputs: [String] = []
    init(root: URL) { self.root = root }
    func infer(_ system: String,_ input: String) async throws -> String {
        calls += 1; let n = calls; inputs.append(input)
        try input.write(to:root.appendingPathComponent("Model-input-\(n).txt"),atomically:true,encoding:.utf8)
        let result = try await ProducerInference.complete(instructions:system,input:input)
        try result.write(to:root.appendingPathComponent("Model-output-\(n).json"),atomically:true,encoding:.utf8)
        return result
    }
}

@MainActor enum ZoomSpeechTest {
    static func run(root: URL,seconds: Double) async -> Int32 {
        var checks = ""; var failures = 0
        func check(_ ok: Bool,_ label: String) {
            let line = "\(ok ? "PASS" : "FAIL"): \(label)"; print(line); fflush(stdout)
            checks += line+"\n"; if !ok { failures += 1 }
            try? checks.write(to:root.appendingPathComponent("CHECKS.txt"),atomically:true,encoding:.utf8)
        }
        let suite = "org.interviewproducer.zoomtest.\(UUID())"
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { check(false,"existing microphone permission required; no settings changed"); return 2 }
            prefs.set(false,forKey:"producer.autoNotes")
            let capture = ZoomOnlyTestCapture(root:root); let log = ZoomInferenceLog(root:root)
            var d = InterviewDependencies(root:root,audio:capture,preferences:prefs,inference:{ try await log.infer($0,$1) })
            d.microphonePermission = { true }; d.showsPanels = false; d.analysisInterval = 10; d.debounce = 2; d.drainTimeout = 60
            var profile = LifelineFixtures.profile
            profile.source = "SYNTHETIC two-voice Zoom participant"
            profile.settings.automatic = false
            try d.questions.addProfile(profile)
            let export = root.appendingPathComponent("synthetic-memory.json")
            let fixture = String(decoding:try MemoryFixtures.export(),as:UTF8.self).replacingOccurrences(of:"Project Aurora",with:"Tape Cedar").replacingOccurrences(of:"Project Beacon",with:"Tape Elm")
            try Data(fixture.utf8).write(to:export)
            let preview = try ChatGPTExportReader.open(export)
            let selected = preview.conversations.first { $0.originalID == "synthetic-noise-research" }!
            _ = try await d.memory.store.importSelected(preview,ids:[selected.id])
            let conversation = try await d.memory.store.conversations()[0]
            try await d.memory.store.annotate(conversation:conversation.id,node:"u1",annotation:.init(kind:MemoryKind.observation.rawValue,note:"Synthetic listening observation; preserve its correction",sourceURL:"",threadStatus:"",pinned:true,excluded:false))
            let controller = InterviewController(dependencies:d)
            await controller.start(consent:true)
            check(controller.isRecording && capture.isCapturing,"real controller starts native capture with nonempty source")
            guard controller.isRecording else { print(controller.message); return 2 }
            print("ZOOM TEST CAPTURE READY: native Zoom output only is transcribed; ambient microphone is discarded. Duration \(seconds)s."); fflush(stdout)
            for tick in 0..<Int(seconds) {
                try await Task.sleep(for:.seconds(1))
                if tick%10 == 9 {
                    print("Zoom elapsed=\(tick+1)s transcriptLines=\(controller.record?.lines.count ?? 0) status=\(controller.transcriptionStatus)"); fflush(stdout)
                    if let record = controller.record { try InterviewStore.export(record,format:"md").write(to:root.appendingPathComponent("Live-progress.md")) }
                }
            }
            await controller.waitForAnalysis()
            if controller.activeSuggestion != nil { controller.action("saved") }
            controller.nextQuestion(); await controller.lifelineTask?.value
            check(!controller.lifelineBusy && (controller.activeLifeline != nil || controller.activeSuggestion != nil || controller.lifelineStatus != "Next Question uses the selected profile; automatic mode defaults off."),"Lifeline request completes during native capture")
            let liveInputs = await log.inputs
            check(liveInputs.contains { $0.contains("sustained abrasive") && $0.contains("not a regular beat") },"live editorial context automatically retrieves original listening observation AND user correction")
            controller.retryAnalysis(); await controller.waitForAnalysis()
            let followups = (controller.record?.suggestions ?? []).map { $0.decision.suggested_question.lowercased() }
            check(Set(followups).count == followups.count,"repeated analysis does not save an identical follow-up question")
            await controller.stop()
            check(!capture.isCapturing && !controller.isRecording && !controller.isStopping,"Stop closes native capture and drains pending transcription")
            guard var record = controller.record else { throw ProducerError.message("Missing Zoom test record") }
            let text = record.transcript.lowercased()
            check(!record.lines.isEmpty && record.lines.allSatisfy { $0.speaker == .them },"actual Zoom output is transcribed; no ambient microphone enters cloud pipeline")
            check(text.contains("interviewer speaking") && text.contains("interviewee speaking"),"both distinct synthesized actors are recalled from received Zoom audio")
            check(text.contains("pulsing delay") && text.contains("thinner electronic"),"specific listening comparison survives Zoom and ASR")
            check((text.contains("eighteen") || text.contains("2018")) && (text.contains("sixteen") || text.contains("2016")) && text.contains("correct"),"original date and explicit correction both survive")
            check(text.contains("portland") && text.contains("swapped bills"),"source relationship survives Zoom and ASR")
            check(text.contains("stopped organizing") && text.contains("disagreement"),"unresolved turning point survives Zoom and ASR")
            check(record.lines == record.lines.sorted { $0.start < $1.start },"transcript timestamps stay ordered")
            if let url = capture.systemAudioURL {
                let audio = try AVAudioFile(forReading:url)
                check(Double(audio.length)/audio.fileFormat.sampleRate >= seconds-5,"received Zoom CAF is finalized and covers the capture interval")
            }
            await controller.generateReport()
            check(controller.record?.storyReport != nil,"existing authorized editorial model generates seven-part report from Zoom transcript")
            record = controller.record ?? record
            for format in ["json","md","txt"] { try InterviewStore.export(record,format:format).write(to:root.appendingPathComponent("Zoom-synthetic-interview.\(format)")) }
            check(d.repository.list().contains { $0.id == record.id && $0.lines == record.lines },"saved native Zoom interview reloads with exact transcript")
            check(d.questions.selected?.settings.automatic == false,"isolated profile stays manual; personal profile is untouched")
            print("Zoom speech test finished with \(failures) failures. Both generated voices use the remote channel; local-vs-remote human attribution is not established by this diagnostic."); fflush(stdout)
            return failures == 0 ? 0 : 1
        } catch { check(false,error.localizedDescription); return 2 }
    }
}
