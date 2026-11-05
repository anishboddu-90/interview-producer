import Foundation
import AVFoundation

@MainActor enum IntegrationTests {
    static func eventually(seconds: Double = 5,_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for:.milliseconds(20)) }
        return condition()
    }
    static func run(live: Bool = false,audioFolder: URL? = nil,artifacts: URL? = nil,allowCredentialInteraction: Bool = false) async -> Int32 {
        var failures = [String](); var total = 0
        let folder = artifacts ?? FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-integration-\(UUID())")
        var progress = ""
        func check(_ ok: Bool,_ label: String) {
            total += 1; if !ok { failures.append(label) }
            let line = "\(ok ? "PASS" : "FAIL") integration: \(label)"
            print(line); fflush(stdout); progress += line+"\n"
            try? progress.write(to:folder.appendingPathComponent("CHECKS.txt"),atomically:true,encoding:.utf8)
        }
        let suite = "org.interviewproducer.integration.\(UUID())"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite); if artifacts == nil { try? FileManager.default.removeItem(at:folder) } }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            if live && !allowCredentialInteraction {
                // A headless diagnostic must not wait indefinitely on a Keychain approval dialog.
                let account = APIConfiguration.enabled("text") ? APIConfiguration.load("text").keyName("text") : (ProducerInference.useGroq ? "groq" : "chatgpt-session")
                guard await cloudCredentialsAvailable(account:account) else {
                    let detail = "Cloud rehearsal blocked: macOS Keychain has not authorized this build to read the existing credentials without interaction. No provider request was made. Open the updated app and reconnect in Connection, then rerun the cloud diagnostic. Credentials were not modified."
                    try detail.write(to:folder.appendingPathComponent("REHEARSAL-BLOCKED.txt"),atomically:true,encoding:.utf8)
                    print(detail); fflush(stdout); return 2
                }
            }
            preferences.set(false,forKey:"producer.autoNotes")
            let tape = try RehearsalTape.load(folder:audioFolder)
            let device = RehearsalCapture(root:folder)
            let box = RehearsalControllerBox(); let model = RehearsalModel(box:box)
            let chunks = RehearsalChunks()
            let injected: (@Sendable (AudioChunk) async throws -> String)?
            if live { injected = nil } else { injected = { chunk in tape.text(for:chunk) } }
            var d = InterviewDependencies(root:folder,audio:device,preferences:preferences,inference:{ system,input in
                if live { await model.observe(input); return try await ProducerInference.complete(instructions:system,input:input) }
                return try await model.complete(system,input)
            },transcriber:injected)
            d.transcriptionReady = live ? { TranscriptionProvider.ready } : { true }
            d.microphonePermission = { true }; d.debounce = 0.02; d.analysisInterval = 0.05; d.drainTimeout = live ? 90 : 1
            d.onChunk = { chunks.append($0) }
            var profile = LifelineFixtures.profile; profile.source = "SYNTHETIC rehearsal source"
            try d.questions.addProfile(profile)
            let export = folder.appendingPathComponent("synthetic-conversations.json"); try MemoryFixtures.export().write(to:export)
            let preview = try ChatGPTExportReader.open(export)
            let selected = preview.conversations.first { $0.originalID == "synthetic-noise-research" }!
            let original = try ChatGPTExportReader.raw(selected)
            _ = try await d.memory.store.importSelected(preview,ids:[selected.id])
            let conversation = try await d.memory.store.conversations()[0]
            try await d.memory.store.annotate(conversation:conversation.id,node:"u1",annotation:.init(kind:MemoryKind.observation.rawValue,note:"Synthetic test priority; preserve its correction.",sourceURL:"",threadStatus:"",pinned:true,excluded:false))
            let researchFile = folder.appendingPathComponent("Synthetic-publication.md")
            try "SYNTHETIC coverage fixture. Earlier coverage describes house origins and continued booking, not a novel 2026 discovery. No real article is being quoted here.".write(to:researchFile,atomically:true,encoding:.utf8)
            try d.research.add(researchFile,kind:"Synthetic coverage — unverified",sourceURL:"https://example.test/coverage")
            let controller = InterviewController(dependencies:d); box.controller = controller
            check(controller.plannedSource == profile.source,"selected profile and source load without touching the personal bank")
            await controller.generateBrief()
            check(controller.stories.activeBrief?.content.questions.count == 10 && controller.stories.activeBrief?.content.essential_indices.count == 3,"pre-interview brief runs through the real controller and existing inference interface")
            await controller.start(consent:false)
            check(!controller.isRecording && device.startCalls == 0,"consent refusal cannot start capture")
            controller.message = ""
            await controller.start(consent:true)
            check(controller.isRecording && !controller.isStarting && device.isCapturing,"Start Interview completes with a NONEMPTY source (crash regression)")
            check(controller.record?.title.contains(profile.source) == true && controller.record?.questionProfileID == profile.id,"session title, source and profile publish atomically")
            guard controller.isRecording, let id = controller.record?.id else { throw ProducerError.message("The controller did not start; cannot continue the rehearsal.") }
            check(controller.record?.rehearsal == true,"isolated test recordings are explicitly marked synthetic")
            controller.toggleMute()
            let split = Int(tape.turns[2].start*16000)
            try await tape.play(into:device,frames:0..<split)
            let firstCount = chunks.count
            let firstDrained = await eventually(seconds:live ? 90 : 5) { controller.record?.lines.count == firstCount }
            check(firstDrained && firstCount >= 2,"both voiced audio channels traverse PCM segmentation, async feed and transcription")
            check(Set(controller.record?.lines.map(\.speaker) ?? []) == Set(AudioSource.allCases),"speaker roles survive the full audio-to-transcript path")
            check(controller.record?.lines == controller.record?.lines.sorted(by:{$0.start < $1.start}),"transcript remains in timestamp order despite separate channels")
            check(!controller.liveEditorialBusy,"muting keeps automatic analysis idle while transcription and local recording continue")
            controller.toggleMute(); await controller.waitForAnalysis()
            let observed = await model.snapshot()
            check(observed.1 && observed.2,"controller live request automatically retrieves verbatim listening observations AND their correction")
            if !live {
                check(d.questions.selected?.questions.first(where:{$0.id == "music"})?.status == .answered,"a substantive unsolicited answer updates the bank with original receipts in the integrated path")
            } else {
                check(!controller.editorStatus.contains("unavailable"),"real selected editorial model completes against the Groq transcript and local archive")
            }
            let earlierFollowup = controller.activeSuggestion?.id
            controller.nextQuestion(); await controller.lifelineTask?.value
            let preservesEarlierFollowup = earlierFollowup != nil && controller.activeSuggestion?.id == earlierFollowup && controller.activeLifeline == nil && controller.lifelineStatus.contains("follow-up")
            check(controller.activeLifeline != nil || controller.lifelineStatus.contains("unresolved") || preservesEarlierFollowup,"manual Lifeline uses current shared context or conservatively retains an unresolved thread/follow-up")
            if let card = controller.activeLifeline {
                check(profile.questions.contains(where:{$0.id == card.question.id && $0.text == card.question.text}),"Lifeline displays an exact bank question, never generated replacement wording")
            }
            if !live {
                // Exercise automatic gating inside the controller, only in this temporary profile.
                controller.lifelineAction("dismissed"); controller.lifelineExcluded = []
                try d.questions.updateProfile(profile.id) { $0.settings.automatic = true }
                controller.retryAnalysis(); await controller.waitForAnalysis()
                controller.lullState = .init()
                let end = controller.record?.lines.last?.end ?? 0
                controller.elapsed = max(0,end-1); device.micLevel = 0.03; device.audioLevel = 0; controller.tickLifeline()
                controller.elapsed = end; device.micLevel = 0; device.audioLevel = 0.03; controller.tickLifeline()
                controller.elapsed = end+9; device.audioLevel = 0; controller.tickLifeline()
                check(controller.activeLifeline?.mode == "automatic","completed-answer review, two channels and silence jointly activate an optional Lifeline")
                controller.lifelineAction("dismissed"); let count = controller.record?.lifelines?.count
                controller.elapsed = end+120; controller.tickLifeline()
                check(controller.record?.lifelines?.count == count && controller.activeLifeline == nil,"one pause cannot repeatedly alert after dismissal/cooldown")
                try d.questions.updateProfile(profile.id) { $0.settings.automatic = false }
                controller.lifelineExcluded = []; controller.retryAnalysis(); await controller.waitForAnalysis()
                controller.nextQuestion(); await controller.lifelineTask?.value
            }
            let hadLifeline = controller.activeLifeline != nil
            controller.toggleMute()
            await model.setMode(.followup)
            try await tape.play(into:device,frames:split..<tape.me.count)
            let expected = chunks.count
            let complete = await eventually(seconds:live ? 120 : 5) { controller.record?.lines.count == expected }
            check(complete && expected > firstCount,"remaining interview flows through the same capture, transcription, persistence and UI state")
            controller.toggleMute(); await controller.waitForAnalysis()
            check(controller.activeSuggestion != nil,"a consequential missed turning point produces a grounded investigative alert")
            check(controller.activeLifeline == nil,"investigative follow-up preempts a prepared question instead of showing competing cards")
            if !live { check(hadLifeline,"preemption test had an actual prepared card to replace") }
            let alertID = controller.activeSuggestion?.id
            controller.nextQuestion()
            check(controller.activeSuggestion?.id == alertID && controller.activeLifeline == nil,"manual Next Question cannot overwrite an existing follow-up")
            let countBeforeRetry = controller.record?.suggestions.count ?? 0
            controller.retryAnalysis(); await controller.waitForAnalysis()
            check(countBeforeRetry > 0 && controller.record?.suggestions.count == countBeforeRetry,"repeated analysis deduplicates the already offered follow-up")
            controller.action("saved")
            check(controller.record?.suggestions.first(where:{$0.id == alertID})?.status == "saved","follow-up action persists on the selected alert in the same interview history")
            preferences.set(true,forKey:"producer.autoNotes")
            await controller.stop()
            check(!controller.isRecording && !controller.isStopping && !device.isCapturing && device.onAudioBuffer == nil,"Stop closes capture/callbacks before finishing cloud work")
            check(!controller.liveEditorialBusy && !controller.lifelineBusy,"stop clears pending analysis/Lifeline state instead of leaving later actions stuck")
            check(controller.record?.status == "stopped" && controller.record?.storyReport != nil,"automatic post-stop report executes on the same complete interview")
            check(controller.record?.notes.contains("## G. Pitch readiness") == true,"seven-part editorial report is saved with the transcript")
            guard let saved = controller.record else { throw ProducerError.message("Saved interview missing") }
            for path in [saved.micAudioPath,saved.systemAudioPath].compactMap({$0}) {
                let file = try AVAudioFile(forReading:URL(fileURLWithPath:path))
                check(file.length > 16000,"saved \(path.contains("mic-") ? "microphone" : "interviewee") CAF is finalized and readable")
            }
            check(controller.archive.contains(where:{$0.id == id && $0.lines == saved.lines}),"saved archive reloads the full transcript, suggestions and report")
            for format in ["md","txt","json"] {
                let data = try InterviewStore.export(saved,format:format)
                try data.write(to:folder.appendingPathComponent("Synthetic-interview.\(format)"))
                check(!data.isEmpty,"\(format.uppercased()) export works after all features ran together")
            }
            check(try await d.memory.store.originalConversation(conversation.id) == original,"live retrieval/reports leave original imported conversation bytes unchanged")
            await d.memory.search("Project Aurora",includeExcluded:false)
            check(!d.memory.hits.isEmpty,"manual memory inspection still works after automatic retrieval and reporting")
            check((saved.storyReport?.content.directions.isEmpty ?? true) || !d.stories.ledger.directions.flatMap(\.updates).isEmpty,"post-report proposed directions update investigation state when supplied")
            let restored = InterviewController(dependencies:d); box.controller = restored
            restored.openRecord(saved)
            check(restored.record?.storyReport != nil && restored.questions.selected?.id == profile.id,"new controller restores the archive, report and question profile after a simulated app restart")
            preferences.set(false,forKey:"producer.autoNotes")
            await restored.start(consent:true)
            check(restored.isRecording && restored.record?.id != id,"a second Start creates a fresh session rather than reusing crashed/stale state")
            restored.nextQuestion()
            check(restored.activeLifeline != nil,"Next Question remains usable at the start of a subsequent interview")
            restored.lifelineAction("asked")
            check(restored.questions.selected?.questions.contains(where:{$0.status == .asked && $0.manualStatus}) == true,"manual Asked status is retained through the full controller path")
            await restored.stop()
            restored.flushQuestionsBeforeClose()
            check(LifelineLibrary(url:folder.appendingPathComponent("questions.json")).selected?.questions.contains(where:{$0.status == .asked}) == true,"bank progress survives actual disk reload after stop/close flush")
            restored.openRecord(saved)
            var other = StoryFixtures.opposing(); other.title = "SYNTHETIC second-source interview"
            let importURL = folder.appendingPathComponent("second-source.json"); try JSONEncoder().encode(other).write(to:importURL)
            try restored.importInterview(importURL)
            check(restored.record?.sourceName == other.sourceName && restored.lifelineProfile == nil,"imported second-source identity is preserved and does not inherit the first bank")
            check(d.stories.crossEvidence(query:"Cedar Route pulsing delay",currentID:other.id).contains(where:{$0.conversationID == id.uuidString}),"cross-interview lookup returns separately attributed earlier accounts")
            try restored.deleteCurrent()
            check(!d.repository.list().contains(where:{$0.id == other.id}) && FileManager.default.fileExists(atPath:export.path),"deleting a temporary interview removes that record, not the original conversation export")
            if !live { await regressionCases(in:folder,preferences:preferences,check:check) }
            let report = "# Automatic integration rehearsal\n\nMode: \(live ? "real Groq + existing selected model; generated speech only" : "synthetic PCM + injected ASR/model responses")\n\n\(total-failures.count)/\(total) checks passed.\n\n"+(failures.isEmpty ? "No detected integration failures.\n" : failures.map { "- \($0)" }.joined(separator:"\n"))+"\n\nNo personal reporting bank or archive was used. Provider selection and credential settings were not changed; normal session refresh may occur. Native Zoom capture and physical global shortcut need separate checks.\n"
            try report.write(to:folder.appendingPathComponent("REHEARSAL-RESULTS.md"),atomically:true,encoding:.utf8)
        } catch {
            check(false,"unexpected failure: \(error.localizedDescription)")
            try? ("# Rehearsal failed\n\n"+progress).write(to:folder.appendingPathComponent("REHEARSAL-RESULTS.md"),atomically:true,encoding:.utf8)
        }
        print("Integration rehearsal: \(total-failures.count)/\(total) passed (\(live ? "actual cloud services, synthetic WAV" : "isolated deterministic controller/pipeline")).")
        fflush(stdout); return failures.isEmpty ? 0 : 1
    }
    private static func cloudCredentialsAvailable(account: String) async -> Bool {
        // Some legacy Keychain services still block despite a noninteractive LAContext.
        // Keep that synchronous OS call off the UI executor and bound the diagnostic wait.
        let (stream,continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy:.bufferingNewest(1))
        Task.detached {
            let accessible = ProducerSecrets.read(account,allowInteraction:false) != nil && ProducerSecrets.read("groq",allowInteraction:false) != nil
            continuation.yield(accessible); continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for:.seconds(3)); try Task.checkCancellation() } catch { return }
            continuation.yield(false); continuation.finish()
        }
        for await result in stream { deadline.cancel(); return result }
        deadline.cancel(); return false
    }
    private static func regressionCases(in root: URL,preferences: UserDefaults,check: (Bool,String) -> Void) async {
        do {
            let statusAudio = RehearsalCapture(root:root.appendingPathComponent("Status-regression"))
            let statusBox = RehearsalControllerBox(); let statusModel = RehearsalModel(box:statusBox)
            var statusDependencies = InterviewDependencies(root:root.appendingPathComponent("Status-regression"),audio:statusAudio,preferences:preferences,inference:{ try await statusModel.complete($0,$1) },transcriber:{ _ in "Synthetic status check" })
            statusDependencies.transcriptionReady = { true }; statusDependencies.microphonePermission = { true }
            let statusController = InterviewController(dependencies:statusDependencies); statusController.plannedSource = "Synthetic status regression"
            await statusController.start(consent:true)
            if let statusID = statusController.record?.id {
                let clock = Date(); statusController.elapsed = 25; statusAudio.audioLevel = 0.05
                statusController.refreshCaptureStatus(now:clock); statusAudio.audioLevel = 0
                statusController.refreshCaptureStatus(now:clock.addingTimeInterval(3))
                check(statusController.transcriptionStatus != InterviewController.waitingForZoomSpeech,"a normal short Zoom pause does not replace transcription status with a permission warning")
                statusController.elapsed = 45; statusController.refreshCaptureStatus(now:clock.addingTimeInterval(18))
                check(statusController.transcriptionStatus == InterviewController.waitingForZoomSpeech,"sustained Zoom silence gives conditional guidance after the startup grace period")
                statusController.receive(.init(start:30,end:40,speaker:.them,text:"Synthetic received Zoom speech"),session:statusID)
                statusController.refreshCaptureStatus(now:Date().addingTimeInterval(2))
                check(statusController.transcriptionStatus.contains("Transcribed through"),"a received remote transcript clears the stale silence warning")
                statusController.transcriptionError("Synthetic network gap",session:statusID)
                statusController.refreshCaptureStatus(now:clock.addingTimeInterval(90))
                check(statusController.transcriptionStatus == "Synthetic network gap","silence guidance cannot hide a transcription error")
                statusAudio.audioLevel = 0.06; statusController.transcriptionStatus = InterviewController.waitingForZoomSpeech
                statusController.refreshCaptureStatus(now:clock.addingTimeInterval(91))
                check(statusController.transcriptionStatus.contains("Call audio detected"),"new Zoom audio clears conditional waiting guidance before the ASR reply")
            } else { check(false,"status regression controller starts") }
            await statusController.stop()
            let folder = root.appendingPathComponent("Lifecycle-regressions")
            let audio = RehearsalCapture(root:folder)
            let box = RehearsalControllerBox(); let model = RehearsalModel(box:box)
            var d = InterviewDependencies(root:folder,audio:audio,preferences:preferences,inference:{ try await model.complete($0,$1) },transcriber:{ _ in "Synthetic phrase." })
            d.transcriptionReady = { true }; d.microphonePermission = { true }; d.drainTimeout = 0.04
            let c = InterviewController(dependencies:d); box.controller = c; c.plannedSource = "Nonempty regression source"
            audio.failure = "Injected device failure"; await c.start(consent:true)
            check(!c.isRecording && !c.isStarting && audio.onAudioBuffer == nil && c.record?.status == "start failed","capture-start error is visible and fully cleans up the session")
            audio.failure = nil; audio.silentMic = true; await c.start(consent:true)
            check(!c.isRecording && !audio.isCapturing,"microphone startup failure stops partial system capture instead of leaving it running")
            audio.silentMic = false; let latch = RehearsalLatch(); audio.startLatch = latch
            let start = Task { await c.start(consent:true) }
            let entered = await eventually { c.isStarting && audio.startCalls >= 3 }
            let count = audio.startCalls
            await c.start(consent:true)
            check(entered && audio.startCalls == count,"double-clicking Start cannot start two overlapping capture sessions")
            await c.stop(); await latch.release(); await start.value
            check(!c.isStarting && !c.isRecording && !audio.isCapturing && audio.onAudioBuffer == nil,"Stop during asynchronous startup cancels the late capture and cleans callbacks")
            audio.startLatch = nil; await c.start(consent:true); await c.stop()
            check(c.record?.status == "stopped","successful Start/Stop works after a cancelled/failed start")
            let permissionRoot = root.appendingPathComponent("Permission-regression")
            let deniedDevice = RehearsalCapture(root:permissionRoot)
            var denied = InterviewDependencies(root:permissionRoot,audio:deniedDevice,preferences:preferences)
            denied.transcriptionReady = { true }; denied.microphonePermission = { false }
            let noPermission = InterviewController(dependencies:denied)
            await noPermission.start(consent:true)
            check(!noPermission.isStarting && deniedDevice.startCalls == 0,"denied microphone permission leaves a responsive, nonrecording app")
            let never = RehearsalLatch()
            let pipeline = TranscriptPipeline(onLine:{ _ in },onError:{ _ in },transcriber:{ _ in await never.wait(); return "Late ignored text" })
            let feed = Task { await pipeline.enqueue(.init(speaker:.them,start:0,end:7,samples:[0.1])) }
            try? await Task.sleep(for:.milliseconds(10))
            let started = Date(); let drained = await PipelineDrain.wait(feed:feed,pipeline:pipeline,seconds:0.03)
            check(!drained && Date().timeIntervalSince(started) < 0.5,"Stop drain deadline is bounded even when a transcriber ignores task cancellation")
            await never.release(); await feed.value
            let timeoutFolder = root.appendingPathComponent("Stop-timeout")
            let blockingDevice = RehearsalCapture(root:timeoutFolder); let blocked = RehearsalLatch()
            var timeout = InterviewDependencies(root:timeoutFolder,audio:blockingDevice,preferences:preferences,inference:{ try await model.complete($0,$1) },transcriber:{ _ in await blocked.wait(); return "Late phrase" })
            timeout.transcriptionReady = { true }; timeout.microphonePermission = { true }; timeout.drainTimeout = 0.04
            let stuck = InterviewController(dependencies:timeout); stuck.plannedSource = "Timeout test"
            await stuck.start(consent:true)
            try blockingDevice.emit([Float](repeating:0.04,count:112000),speaker:.them,end:7)
            try blockingDevice.emit([Float](repeating:0,count:24000),speaker:.them,end:8.5)
            try? await Task.sleep(for:.milliseconds(10))
            let stopStart = Date(); await stuck.stop()
            check(Date().timeIntervalSince(stopStart) < 0.7 && !stuck.isStopping && !blockingDevice.isCapturing,"actual controller Stop returns on timeout while preserving audio")
            check(stuck.message.contains("timed out"),"a forced transcription gap is reported explicitly")
            await blocked.release()
            let old = stuck.record?.lines.count; try? await Task.sleep(for:.milliseconds(20))
            check(stuck.record?.lines.count == old,"late transcription after timeout cannot mutate the stopped interview")
            await c.simulate(live:false)
            check(c.record?.status == "simulation completed" && c.activeSuggestion != nil,"the existing offline simulation also exercises safe reset without crashing")
        } catch { check(false,"lifecycle regression error: \(error.localizedDescription)") }
    }
}
