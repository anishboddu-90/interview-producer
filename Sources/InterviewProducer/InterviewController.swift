import Foundation
import SwiftUI
import AVFoundation

@MainActor @Observable final class InterviewController {
    let dependencies: InterviewDependencies
    let audio: any InterviewCaptureDevice
    let editorial: EditorialService
    let research: ResearchLibrary
    let memory: MemoryLibrary
    let stories: StoryLibrary
    let storyEngine: StoryEngine
    let questions: LifelineLibrary
    let lifelineEngine: LifelineEngine
    let questionShortcut = LifelineShortcut()
    var activeLifeline: SavedLifeline?
    var lifelineStatus = "Next Question uses the selected profile; automatic mode defaults off."
    var lifelineBusy = false
    var lifelineTask: Task<Void,Never>?
    var lifelineGeneration = 0
    var pendingManualLifeline = false
    var lifelineExcluded = Set<String>()
    var lifelineCache: LifelineCache?
    var lullState = LifelineLullState()
    var lifelineTranscriptHealthy = true
    var lifelineRecoveryCount = 0
    var liveEditorialBusy: Bool { analysisRunning || pendingAnalysis }

    var plannedSource = ""
    var plannedBackground = ""
    var record: InterviewRecord?
    private var storyRecords: [InterviewRecord] { archive.filter { $0.id != record?.id } + (record.map { [$0] } ?? []) }
    var archive: [InterviewRecord]
    var testing = false
    var rehearsalStatus = ""
    var rehearsalResultsURL: URL?
    var isStarting = false
    private var startAttempt: UUID?
    var isRecording = false
    var isStopping = false
    var simulating = false
    var alertsMuted = false
    var editorStatus = "Choose and test an editorial provider in Connection."
    var transcriptionStatus = "Not capturing"
    var message = ""
    var activeSuggestion: SavedSuggestion?
    var showClosing = false
    var elapsed: Double = 0
    var processingReport = false
    private var pipeline: TranscriptPipeline?
    private var chunker: PCMChunker?
    private var feedTask: Task<Void,Never>?
    private var feedContinuation: AsyncStream<AudioChunk>.Continuation?
    private var analysisTask: Task<Void,Never>?
    private var timerTask: Task<Void,Never>?
    private var simulationTask: Task<Void,Never>?
    private var sessionID: UUID?
    private var analysisRunning = false
    private var pendingAnalysis = false
    private var lastAnalysis = Date.distantPast
    private var origin = Date()
    private var lastZoomActivity = Date()
    private var lastPresentedTime: Double = 0

    init(dependencies supplied: InterviewDependencies? = nil) {
        let d = supplied ?? InterviewDependencies()
        dependencies = d; audio = d.audio; editorial = d.editorial; research = d.research
        memory = d.memory; stories = d.stories; storyEngine = d.storyEngine
        questions = d.questions; lifelineEngine = d.lifelineEngine; archive = d.repository.list()
        for i in archive.indices where archive[i].status == "recording" && !archive[i].simulation {
            archive[i].status = "interrupted — transcript recovered; verify audio integrity"
            try? dependencies.repository.save(archive[i])
        }
        stories.index(archive)
        plannedSource = questions.selected?.source ?? ""
    }

    func persist() { if let record { do { try dependencies.repository.save(record) } catch { message = "Could not save interview: \(error.localizedDescription)" } } }
    func refreshArchive() { archive = dependencies.repository.list(); stories.index(archive) }
    func start(consent: Bool) async {
        do { try InterviewSettings.current.validate() } catch { message = error.localizedDescription; return }
        guard !testing, !isStarting, !isRecording, !isStopping, !simulating, !stories.busy, !processingReport else { return }
        guard consent else { message = "Obtain recording and cloud-processing consent before starting."; return }
        guard dependencies.transcriptionReady() else { message = "Configure the selected transcription provider in Connection first."; return }
        let attempt = UUID(); startAttempt = attempt; isStarting = true
        var createdRecord: UUID?
        defer { isStarting = false; if startAttempt == attempt { startAttempt = nil } }
        guard await dependencies.microphonePermission() else { message = "Microphone access is required to capture both speakers."; return }
        guard startAttempt == attempt, !Task.isCancelled else { return }
        do {
            await reset(simulation:false)
            guard startAttempt == attempt, !Task.isCancelled else { throw CancellationError() }
            guard let id = record?.id else { throw ProducerError.message("The interview session could not be prepared.") }
            createdRecord = id
            record?.consent = dependencies.isRehearsal ? "SYNTHETIC REHEARSAL — prerecorded generated voices; no real participant." : "Journalist confirmed interviewee consent before capture, including selected-provider audio transcription, AI text processing and relevant local research/memory excerpts."
            origin = Date(); lastZoomActivity = origin
            let p = TranscriptPipeline(onLine:{ [weak self] line in await self?.receive(line,session:id) },onError:{ [weak self] error in await self?.transcriptionError(error,session:id) },transcriber:dependencies.transcriber)
            pipeline = p
            let c = PCMChunker(); chunker = c
            let (stream,continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy:.bufferingOldest(12))
            feedContinuation = continuation
            feedTask = Task { for await chunk in stream { await p.enqueue(chunk) } }
            let observeChunk = dependencies.onChunk
            c.onChunk = { [weak self] chunk in
                observeChunk?(chunk)
                if case .dropped = continuation.yield(chunk) {
                    Task { @MainActor in self?.transcriptionError("Transcription backlog full; audio remains recorded locally.",session:id) }
                }
            }
            let start = origin; let capture = audio
            audio.onAudioBuffer = { buffer,source in
                guard let channel = buffer.floatChannelData?.pointee else { return }
                let samples = Array(UnsafeBufferPointer(start:channel,count:Int(buffer.frameLength)))
                c.ingest(samples,speaker:source,at:capture.replayTime ?? Date().timeIntervalSince(start))
            }
            try await audio.startCapture()
            guard startAttempt == attempt, !Task.isCancelled else { throw CancellationError() }
            guard audio.micActive else { throw ProducerError.message("Microphone capture did not start. No interview is running.") }
            isRecording = true
            showPrivatePanel()
            record?.systemAudioPath = audio.systemAudioURL?.path; record?.micAudioPath = audio.micAudioURL?.path
            transcriptionStatus = dependencies.isRehearsal ? "Synthetic audio replay · normal transcription pipeline" : "Waiting for speech · selected transcription provider"
            persist()
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.seconds(1)) } catch { return }
                    guard let self, self.isRecording else { return }
                    self.elapsed = self.audio.replayTime ?? Date().timeIntervalSince(self.origin)
                    self.tickLifeline()
                    if self.elapsed >= 7200 { self.message = "Two-hour safety limit reached."; await self.stop(); return }
                    self.refreshCaptureStatus()
                    if let active = self.activeSuggestion, self.elapsed-active.decision.timestamp > 90 { self.activeSuggestion = nil; self.refreshPrivatePanel() }
                }
            }
        } catch {
            sessionID = nil
            if record?.id == createdRecord { record?.systemAudioPath = audio.systemAudioURL?.path; record?.micAudioPath = audio.micAudioURL?.path }
            await audio.stopCapture(); audio.onAudioBuffer = nil
            chunker = nil; feedContinuation?.finish(); feedContinuation = nil
            feedTask?.cancel(); feedTask = nil; await pipeline?.cancel(); pipeline = nil
            isRecording = false
            if record?.id == createdRecord { record?.status = error is CancellationError ? "start cancelled" : "start failed"; persist() }
            if !(error is CancellationError) { message = error.localizedDescription }
        }
    }
    private func reset(simulation: Bool) async {
        cancelLifeline(); activeLifeline = nil; lifelineCache = nil; lifelineExcluded = []; lullState = .init(); lifelineTranscriptHealthy = true; lifelineRecoveryCount = 0
        analysisTask?.cancel(); simulationTask?.cancel(); timerTask?.cancel()
        await editorial.reset()
        // Build the value before publishing it. Optional-chain mutation followed by a record getter
        // in the RHS traps Swift's exclusivity checker (the reported Start Interview crash).
        var fresh = InterviewRecord()
        fresh.simulation = simulation; fresh.rehearsal = dependencies.isRehearsal
        let source = simulation ? "Synthetic interviewee" : plannedSource.trimmingCharacters(in:.whitespacesAndNewlines)
        fresh.setupContext = InterviewSettings.current.context
        fresh.sourceName = source; fresh.sourceBackground = plannedBackground
        if !simulation, let profile = questions.selected, profile.matchesSource(source) { fresh.questionProfileID = profile.id }
        if !source.isEmpty { fresh.title = "\(InterviewSettings.current.title) — \(source)" }
        if dependencies.isRehearsal { fresh.title = "SYNTHETIC REHEARSAL — \(source)" }
        fresh.research = research.context(for:InterviewSettings.current.topic+" "+InterviewSettings.current.goals+" "+source)
        record = fresh
        sessionID = fresh.id; activeSuggestion = nil; alertsMuted = false; elapsed = 0
        pendingAnalysis = false; analysisRunning = false; lastAnalysis = .distantPast
        hidePrivatePanel()
    }
    static let waitingForZoomSpeech = "Waiting for call audio. If the interviewee is speaking, check the selected call application speaker and macOS audio permission."
    func refreshCaptureStatus(now: Date = Date()) {
        guard !InterviewSettings.current.microphoneOnly else { return }
        if audio.audioLevel >= 0.0001 {
            lastZoomActivity = now
            if transcriptionStatus == Self.waitingForZoomSpeech { transcriptionStatus = "Call audio detected · waiting for transcription" }
        } else if elapsed > 20 && now.timeIntervalSince(lastZoomActivity) > 15 && lifelineTranscriptHealthy {
            transcriptionStatus = Self.waitingForZoomSpeech
        }
    }
    func transcriptionError(_ error: String,session: UUID) { guard session == sessionID else { return }; transcriptionStatus = error; lifelineTranscriptHealthy = false; lifelineRecoveryCount = 0; lifelineCache = nil }
    func receive(_ line: InterviewLine,session: UUID) {
        guard session == sessionID else { return }
        invalidateLifelineForTranscript()
        if line.speaker == .them { lastZoomActivity = Date() }
        record?.lines.append(line)
        record?.lines.sort { $0.start < $1.start }
        elapsed = max(elapsed,line.end)
        transcriptionStatus = "Transcribed through \(line.stamp) · \(line.speaker.label)"
        if !line.text.localizedCaseInsensitiveContains("untranscribed"), !line.text.localizedCaseInsensitiveContains("[unclear]") {
            lifelineRecoveryCount += 1; if lifelineRecoveryCount >= 2 { lifelineTranscriptHealthy = true }
        } else { lifelineTranscriptHealthy = false; lifelineRecoveryCount = 0 }
        if let record, let profileID = record.questionProfileID { do { try questions.markObservedAsked(profileID:profileID,record:record) } catch { lifelineStatus = error.localizedDescription } }
        synchronizeLifelineCard()
        persist(); scheduleAnalysis()
    }
    private func scheduleAnalysis() {
        guard !alertsMuted, !isStopping, !stories.busy, !processingReport else { return }
        if analysisRunning { pendingAnalysis = true; return }
        analysisTask?.cancel()
        let wait = max(dependencies.debounce,dependencies.analysisInterval-Date().timeIntervalSince(lastAnalysis))
        let id = sessionID
        analysisTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(wait)); try Task.checkCancellation() } catch { return }
            guard let self, self.sessionID == id, !self.stories.busy, !self.processingReport, let record = self.record else { return }
            if self.lifelineBusy { self.cancelLifeline(); self.pendingManualLifeline = true }
            self.analysisRunning = true; self.lastAnalysis = Date(); self.editorStatus = "Listening for a reporting gap…"
            let lines = Array(record.lines.suffix(80))
            let latest = lines.last?.end ?? 0
            do {
                let context = self.research.context(for:lines.suffix(10).map(\.text).joined(separator:" "))
                let query = lines.suffix(10).map(\.text).joined(separator:" ")
                var recentRecord = record; recentRecord.lines = Array(record.lines.suffix(3))
                let recentEvidence = Array(StoryEvidence.passages([recentRecord]).suffix(3))
                let previousAccounts = record.simulation ? [] : self.stories.crossEvidence(query:query,currentID:record.id)
                let questionBank = record.simulation ? nil : self.questions.profile(record.questionProfileID).flatMap { $0.matchesSource(record.sourceName ?? "") ? $0 : nil }
                let askedLifelines = (record.lifelines ?? []).filter { ["asked","answered"].contains($0.status) }.map { $0.question.text }
                let result = try await self.editorial.analyze(lines:lines,research:context,known:record.suggestions.map { $0.decision.suggested_question }+askedLifelines,
                    publications:self.research.evidence(for:query),interviewEvidence:recentEvidence,crossInterviewEvidence:previousAccounts,
                    investigations:StoryEngine.context(self.stories.currentDirections(records:self.archive.filter { $0.id != record.id }+[record])),questionBank:questionBank)
                guard !Task.isCancelled, self.sessionID == id else { return }
                if !record.simulation { self.stories.acceptLive(result.story_leads ?? [],evidence:result.suppliedEvidence ?? [],source:StoryEvidence.source(record)) }
                self.record?.threads = result.threads
                self.record?.research = context
                if let review = result.lifeline_review, let questionBank { self.acceptLifelineReview(review,profile:questionBank,record:record,evidence:result.suppliedEvidence ?? []) }
                for title in result.resolved_titles {
                    if let i = self.record?.suggestions.firstIndex(where:{$0.decision.suggested_question == title}) {
                        self.record?.suggestions[i].status = "answered"
                        if self.activeSuggestion?.decision.suggested_question == title { self.activeSuggestion = nil; hidePrivatePanel() }
                    }
                }
                // Drop late decisions once later speech has moved the interview on.
                let newerQuestion = (self.record?.lines ?? []).contains { $0.end > latest && $0.speaker == .me && $0.text.contains("?") }
                if result.decision.should_suggest,
                   EditorialFreshness.mayPresent(anchor:latest,latest:self.record?.lines.last?.end ?? 0,newQuestion:newerQuestion,latency:Date().timeIntervalSince(self.lastAnalysis)), !self.alertsMuted {
                    self.preemptLifelineForFollowup()
                    let saved = SavedSuggestion(decision:result.decision,evidence:result.citedEvidence,suppliedEvidence:result.suppliedEvidence)
                    self.record?.suggestions.append(saved); self.activeSuggestion = saved
                    self.lastPresentedTime = latest
                    showPrivatePanel()
                    self.editorStatus = "Follow-up ready"
                } else { self.editorStatus = "Listening · no new alert" }
                self.persist()
            } catch {
                guard !Task.isCancelled, self.sessionID == id else { return }
                self.editorStatus = "Editorial analysis unavailable: \(error.localizedDescription)"
            }
            self.analysisRunning = false
            self.finishQueuedLifeline()
            if self.pendingAnalysis { self.pendingAnalysis = false; self.scheduleAnalysis() }
        }
    }
    func showPrivatePanel() { if dependencies.showsPanels { ProducerPanel.shared.showControls(controller:self) } }
    func hidePrivatePanel() { if dependencies.showsPanels { ProducerPanel.shared.hide() } }
    func cancelEditorialAnalysis() { analysisTask?.cancel(); analysisTask = nil; analysisRunning = false; pendingAnalysis = false }
    func waitForAnalysis() async { let task = analysisTask; await task?.value }
    func retryAnalysis() { guard !analysisRunning else { return }; scheduleAnalysis() }
    func toggleMute() {
        alertsMuted.toggle()
        if alertsMuted { cancelLifeline(); cancelEditorialAnalysis(); hidePrivatePanel(); editorStatus = "Analysis and alerts muted" }
        else { scheduleAnalysis() }
    }
    func action(_ status: String) {
        guard let active = activeSuggestion else { return }
        if let i = record?.suggestions.firstIndex(where:{$0.id == active.id}) { record?.suggestions[i].status = status }
        activeSuggestion = nil; refreshPrivatePanel(); persist()
    }
    func stop() async {
        guard !isStopping, isStarting || isRecording || simulating || pipeline != nil else { return }
        cancelLifeline(); activeLifeline = nil; lifelineCache = nil
        startAttempt = nil
        isStopping = true; isRecording = false; simulating = false
        timerTask?.cancel(); simulationTask?.cancel(); cancelEditorialAnalysis()
        hidePrivatePanel(); activeSuggestion = nil
        await audio.stopCapture()
        audio.onAudioBuffer = nil
        chunker?.finish(); chunker = nil
        feedContinuation?.finish(); feedContinuation = nil
        let drainingFeed = feedTask
        let drainingPipeline = pipeline
        let drained = await PipelineDrain.wait(feed:drainingFeed,pipeline:drainingPipeline,seconds:dependencies.drainTimeout)
        if !drained { message = "Transcription drain timed out. Audio is saved locally; pending speech remains explicitly untranscribed." }
        feedTask = nil
        self.pipeline = nil
        cancelEditorialAnalysis()
        record?.status = "stopped"; persist(); refreshArchive(); isStopping = false
        transcriptionStatus = "Stopped · audio capture is off"
        editorStatus = "Stopped. Generate editorial notes when ready."
        if dependencies.preferences.bool(forKey:"producer.autoNotes"), record?.simulation == false, !(record?.lines.isEmpty ?? true) {
            await generateReport()
        }
    }
    func generateReport() async {
        guard let record, !isStarting, !isRecording, !isStopping, !simulating, !processingReport, !stories.busy, !record.lines.isEmpty else { return }
        cancelEditorialAnalysis()
        processingReport = true; stories.busy = true; stories.progress = "Checking original transcript, coverage and other source accounts…"
        defer { processingReport = false; stories.busy = false; stories.progress = "" }
        let id = record.id
        do {
            let query = record.lines.suffix(30).map(\.text).joined(separator:" ")
            let context = try await storyEngine.prepare(query:query,records:archive,publications:research.editorialEvidence(for:query),currentID:id)
            let report = try await storyEngine.report(record:record,directions:stories.currentDirections(records:storyRecords),context:context)
            guard self.record?.id == id else { return }
            let updates = try report.content.directions.map { try StoryEvidence.validate($0,evidence:report.evidence,label:"Post-interview — \(StoryEvidence.source(record))") }
            if !record.simulation { try stories.apply(updates,interview:record) }
            self.record?.storyReport = report
            self.record?.notes = report.markdown; persist(); refreshArchive()
            stories.status = "Seven-part editorial report saved with original-source receipts. Verify it against the recording."
        } catch { message = "Editorial report unavailable: \(error.localizedDescription). Transcript and audio remain saved." }
    }
    func generateBrief() async {
        guard !isStarting, !isRecording, !isStopping, !simulating, !processingReport, !stories.busy else { return }
        cancelEditorialAnalysis()
        stories.busy = true; stories.progress = "Preparing a source-specific brief from relevant evidence…"
        defer { stories.busy = false; stories.progress = "" }
        do {
            let query = plannedSource+" "+plannedBackground+" "+InterviewSettings.current.topic+" "+InterviewSettings.current.goals
            let context = try await storyEngine.prepare(query:query,records:archive,publications:research.editorialEvidence(for:query))
            let brief = try await storyEngine.brief(source:plannedSource,background:plannedBackground,directions:stories.currentDirections(records:storyRecords),context:context)
            try stories.saveBrief(brief)
        } catch { message = "Brief unavailable: \(error.localizedDescription)" }
    }
    func reviewInvestigations() async {
        guard let record, !isStarting, !isRecording, !isStopping, !simulating, !processingReport, !stories.busy else { return }
        cancelEditorialAnalysis()
        stories.busy = true; stories.progress = "Comparing this source with ongoing investigations…"
        defer { stories.busy = false; stories.progress = "" }
        do {
            let query = record.lines.suffix(30).map(\.text).joined(separator:" ")
            let context = try await storyEngine.prepare(query:query,records:archive,publications:research.editorialEvidence(for:query),currentID:record.id)
            let updates = try await storyEngine.review(record:record,directions:stories.currentDirections(records:storyRecords),context:context)
            if !record.simulation { try stories.apply(updates,interview:record) }
        } catch { message = "Investigation review unavailable: \(error.localizedDescription)" }
    }
    func importInterview(_ url: URL) throws {
        guard !isStarting, !isRecording, !isStopping, !simulating, !processingReport, !stories.busy else { return }
        let incoming = try StoryInterviewImport.read(url,source:plannedSource,background:plannedBackground)
        guard !archive.contains(where:{$0.id == incoming.id}) else { throw ProducerError.message("An interview with this identifier already exists. Open it in Archive rather than overwriting it.") }
        try dependencies.repository.save(incoming); refreshArchive(); openRecord(incoming)
        stories.status = "Imported attributed transcript. Review or generate its editorial report to update investigations."
    }
    func updateSource(name: String,background: String,included: Bool) {
        guard !isStarting, !isRecording, !isStopping, !processingReport, !stories.busy else { return }
        record?.sourceName = String(name.prefix(200)); record?.sourceBackground = String(background.prefix(4000)); record?.includeInStory = included
        if let id = record?.questionProfileID, questions.profile(id)?.matchesSource(name) != true { record?.questionProfileID = nil; activeLifeline = nil; lifelineCache = nil }
        persist(); refreshArchive()
    }
    func runAutomaticRehearsal(live: Bool = false) async {
        guard !testing, !isStarting, !isRecording, !isStopping, !simulating, !processingReport, !stories.busy else { return }
        testing = true; rehearsalStatus = live ? "Running generated speech through Groq and the current editorial model…" : "Running automatic local interview rehearsal…"; rehearsalResultsURL = nil
        defer { testing = false }
        let root = InterviewStore.directory.deletingLastPathComponent().appendingPathComponent("Diagnostics/Rehearsal-\(UUID())")
        let voices = live ? Bundle.main.resourceURL?.appendingPathComponent("Rehearsal-audio") : nil
        let result = await IntegrationTests.run(live:live,audioFolder:voices,artifacts:root,allowCredentialInteraction:live)
        rehearsalResultsURL = root.appendingPathComponent("REHEARSAL-RESULTS.md")
        rehearsalStatus = live
            ? "Generated-speech cloud rehearsal \(result == 0 ? "passed" : "found failures"). No real microphone was used. Open results for the checks."
            : "Automatic local rehearsal \(result == 0 ? "passed (55 checks)" : "found failures"). No real microphone or cloud services were used."
    }
    func simulate(live: Bool) async {
        guard !isStarting, !isRecording, !isStopping, !simulating, !stories.busy else { return }
        await reset(simulation:true); simulating = true
        record?.consent = "Synthetic demonstration; no audio captured."
        let id = sessionID!
        if !live {
            record?.status = "simulation completed"
            record?.lines = SimulationFixtures.revelation
            let saved = SavedSuggestion(decision:SimulationFixtures.revelationDecision)
            record?.suggestions = [saved]; activeSuggestion = saved; simulating = false
            editorStatus = "Offline fixture replay · no AI inference or audio capture"
            showPrivatePanel(); persist(); refreshArchive(); return
        }
        simulationTask = Task { [weak self] in
            for line in SimulationFixtures.revelation {
                guard !Task.isCancelled, let self, self.sessionID == id else { return }
                self.receive(line,session:id)
                try? await Task.sleep(for:.seconds(self.dependencies.replayDelay))
            }
            self?.simulating = false; self?.record?.status = "simulation completed"; self?.persist()
        }
    }
    func openRecord(_ r: InterviewRecord) { guard !isStarting, !isRecording, !isStopping, !processingReport, !simulating, !stories.busy else { return }; cancelEditorialAnalysis(); cancelLifeline(); activeLifeline = nil; lifelineCache = nil; lifelineExcluded = []; record = r; sessionID = r.id; activeSuggestion = nil; if questions.profile(r.questionProfileID) != nil { try? questions.select(r.questionProfileID) }; hidePrivatePanel() }
    func deleteCurrent() throws {
        guard let record, !isStarting, !isRecording, !isStopping, !processingReport, !stories.busy else { return }
        cancelEditorialAnalysis(); simulationTask?.cancel(); sessionID = nil
        cancelLifeline(); activeLifeline = nil; lifelineCache = nil
        try stories.removeInterview(record.id)
        try dependencies.repository.delete(record); self.record = nil; activeSuggestion = nil; hidePrivatePanel(); refreshArchive()
    }
}
