import Foundation

@MainActor extension InterviewController {
    var lifelineProfile: QuestionProfile? {
        if let record {
            guard !record.simulation, let profile = questions.profile(record.questionProfileID), profile.matchesSource(record.sourceName ?? "") else { return nil }
            return profile
        }
        return questions.selected
    }
    static func lifelineAnchor(_ record: InterviewRecord) -> String {
        MemoryIdentity.digest("\(record.lines.count)|"+record.lines.suffix(2).map { "\($0.id)|\($0.start)|\($0.end)|\($0.text)" }.joined(separator:"\n"))
    }
    func configureQuestionShortcut() {
        let settings = questions.state
        questionShortcut.register(key:settings.shortcutKey,modifiers:settings.shortcutModifiers,enabled:settings.shortcutEnabled) { [weak self] in self?.nextQuestion() }
    }
    func selectQuestionProfile(_ id: String?) {
        guard !isStarting, !isRecording, !isStopping, !simulating, !lifelineBusy else { return }
        do {
            try questions.select(id); activeLifeline = nil; lifelineCache = nil; lifelineExcluded = []
            if let profile = questions.selected {
                if !profile.source.isEmpty { plannedSource = profile.source }
                if let record, profile.matchesSource(record.sourceName ?? "") { self.record?.questionProfileID = profile.id; persist() }
            } else if record != nil { record?.questionProfileID = nil; persist() }
        } catch { message = error.localizedDescription }
    }
    func cancelLifeline() {
        lifelineGeneration += 1; lifelineTask?.cancel(); lifelineTask = nil; lifelineBusy = false; pendingManualLifeline = false
    }
    func invalidateLifelineForTranscript() {
        lifelineCache = nil
        if lifelineBusy {
            cancelLifeline(); pendingManualLifeline = true
            lifelineStatus = "Conversation continued; waiting for the current follow-up analysis before choosing."
        }
        if activeLifeline?.mode == "automatic" { activeLifeline = nil; refreshPrivatePanel() }
    }
    func preemptLifelineForFollowup() {
        cancelLifeline(); activeLifeline = nil
        lifelineStatus = "Investigative follow-up has priority. Next Question remains available after you handle it."
    }
    func refreshPrivatePanel() {
        if isRecording || activeLifeline != nil || activeSuggestion != nil { showPrivatePanel() }
        else { hidePrivatePanel() }
    }
    func synchronizeLifelineCard() {
        lifelineCache = nil
        guard let card = activeLifeline else { return }
        let current = questions.profile(card.profileID)?.questions.first { $0.id == card.question.id }
        let automaticOff = card.mode == "automatic" && questions.profile(card.profileID)?.settings.automatic != true
        if current?.eligible != true || current?.fingerprint != card.question.fingerprint || automaticOff || lifelineProfile?.id != card.profileID {
            setLifelineHistory(card.id,status:current?.status.rawValue ?? "removed")
            activeLifeline = nil; refreshPrivatePanel()
        }
    }
    func setQuestionStatus(profile: String,id: String,status: QuestionStatus) {
        do { try questions.setStatus(profile,id:id,status:status); synchronizeLifelineCard() }
        catch { lifelineStatus = error.localizedDescription }
    }
    func finishQueuedLifeline() {
        guard pendingManualLifeline else { return }
        pendingManualLifeline = false
        if activeSuggestion == nil { nextQuestion() }
    }
    func acceptLifelineReview(_ review: LifelineReview,profile: QuestionProfile,record captured: InterviewRecord,evidence: [ResearchEvidence]) {
        guard record?.id == captured.id, record?.questionProfileID == profile.id else { return }
        do {
            try LifelineEngine.validate(review,profile:profile,record:captured,evidence:evidence)
            try questions.applyAnswers(review.answers,profileID:profile.id,expectedRevision:profile.revision,record:captured,evidence:evidence)
            guard let updated = questions.profile(profile.id) else { return }
            lifelineCache = .init(review:review,evidence:evidence,profileID:profile.id,revision:updated.revision,recordID:captured.id,anchor:Self.lifelineAnchor(captured))
            if let active = activeLifeline, questions.profile(active.profileID)?.questions.first(where:{$0.id == active.question.id})?.status == .answered {
                setLifelineHistory(active.id,status:"answered"); activeLifeline = nil; refreshPrivatePanel()
            }
        } catch { lifelineStatus = "Follow-ups continue; question review was withheld: \(error.localizedDescription)" }
    }
    func nextQuestion(another: Bool = false) {
        guard !isStopping else { lifelineStatus = "Wait for capture to finish stopping."; return }
        guard activeSuggestion == nil else { lifelineStatus = "Handle the displayed investigative follow-up first."; refreshPrivatePanel(); return }
        guard !processingReport, !stories.busy else { lifelineStatus = "An editorial job is running; try Next Question when it finishes."; return }
        guard let profile = lifelineProfile else { lifelineStatus = "Select a question profile for this source in Question Lifeline."; return }
        if another, let active = activeLifeline {
            lifelineExcluded.insert(active.question.id); setLifelineHistory(active.id,status:"another requested"); activeLifeline = nil
        }
        if activeLifeline != nil, !another { refreshPrivatePanel(); return }
        guard !lifelineBusy else { return }
        if liveEditorialBusy { pendingManualLifeline = true; lifelineStatus = "Checking the current investigative follow-up first…"; return }
        let contextRecord: InterviewRecord
        if let record { contextRecord = record }
        else { var preview = InterviewRecord(); preview.sourceName = profile.source; preview.status = "question preparation"; contextRecord = preview }
        if let cache = lifelineCache, cache.profileID == profile.id, cache.revision == profile.revision,
           cache.recordID == contextRecord.id, cache.anchor == Self.lifelineAnchor(contextRecord), !another,
           Date().timeIntervalSince(cache.date) < 60 {
            showLifeline(cache.review,evidence:cache.evidence,profile:profile,record:contextRecord,mode:"manual")
            return
        }
        // Before any speech, selection is deterministic preparation, not a claim that an answer was checked by AI.
        if contextRecord.lines.isEmpty {
            showLocalLifeline(profile:profile,record:contextRecord,reason:"Prepared-question selection before interview context is available.")
            return
        }
        lifelineBusy = true; lifelineStatus = "Choosing a relevant unanswered question…"; lifelineGeneration += 1
        let generation = lifelineGeneration; let excluded = lifelineExcluded
        let query = contextRecord.lines.suffix(10).map(\.text).joined(separator:" ")
        let publications = research.evidence(for:query)
        let previous = contextRecord.simulation ? [] : stories.crossEvidence(query:query,currentID:contextRecord.id)
        lifelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (review,evidence) = try await self.lifelineEngine.choose(profile:profile,record:contextRecord,excluding:excluded,publications:publications,previousAccounts:previous)
                try Task.checkCancellation()
                guard self.lifelineGeneration == generation, self.record?.id == contextRecord.id, self.activeSuggestion == nil else { return }
                try self.questions.applyAnswers(review.answers,profileID:profile.id,expectedRevision:profile.revision,record:contextRecord,evidence:evidence)
                guard let updated = self.questions.profile(profile.id) else { return }
                self.lifelineCache = .init(review:review,evidence:evidence,profileID:updated.id,revision:updated.revision,recordID:contextRecord.id,anchor:Self.lifelineAnchor(contextRecord))
                self.showLifeline(review,evidence:evidence,profile:updated,record:contextRecord,mode:"manual")
            } catch {
                guard !Task.isCancelled, self.lifelineGeneration == generation else { return }
                self.lifelineStatus = "AI context check unavailable: \(error.localizedDescription)"
                // Manual help survives network/auth failures. This never marks an answer and never powers automatic mode.
                if self.activeSuggestion == nil, let current = self.questions.profile(profile.id), current.revision == profile.revision {
                    self.showLocalLifeline(profile:current,record:contextRecord,reason:"Local ranking only; AI/history check unavailable. Verify that this has not already been answered.")
                }
            }
            if self.lifelineGeneration == generation { self.lifelineBusy = false; self.lifelineTask = nil }
        }
    }
    func showLocalLifeline(profile: QuestionProfile,record: InterviewRecord,reason: String) {
        guard let question = LifelineRanking.candidates(profile,lines:record.lines,excluding:lifelineExcluded).first else {
            lifelineStatus = lifelineExcluded.isEmpty ? "All questions are asked, answered or skipped. Edit a status or choose another profile." : "No more questions in this pass. Use All Questions or reset the pass to revisit deferred questions."
            activeLifeline = nil; refreshPrivatePanel(); return
        }
        presentLifeline(question,bridge:LifelineRanking.localBridge(question,lines:record.lines),reason:reason,evidence:[],profile:profile,record:record,mode:"manual · local")
    }
    func showLifeline(_ review: LifelineReview,evidence: [ResearchEvidence],profile: QuestionProfile,record: InterviewRecord,mode: String) {
        guard activeSuggestion == nil else { return }
        guard !review.pending_followup else { lifelineStatus = "A substantive follow-up is still unresolved; stay with that thread before changing topics."; return }
        guard let id = review.next_question_id, let question = LifelineRanking.candidates(profile,lines:record.lines,excluding:lifelineExcluded,evidence:evidence).first(where:{$0.id == id}) else {
            lifelineStatus = "No suitable remaining question was identified. Inspect All Questions or change an overridden status."; activeLifeline = nil; refreshPrivatePanel(); return
        }
        let cited = (try? ResearchEvidence.validatedReferences(review.source_refs,candidates:evidence)) ?? []
        presentLifeline(question,bridge:review.bridge,reason:review.reason,evidence:cited,profile:profile,record:record,mode:mode)
    }
    func presentLifeline(_ question: LifelineQuestion,bridge: String,reason: String,evidence: [ResearchEvidence],profile: QuestionProfile,record context: InterviewRecord,mode: String) {
        do {
            guard activeSuggestion == nil else { return }
            try questions.updateQuestion(profile.id,id:question.id) { q in q.status = .suggested; q.lastSuggested = Date() }
            let card = SavedLifeline(profileID:profile.id,question:question,bridge:bridge,reason:reason,mode:mode,evidence:evidence,transcriptAnchor:context.lines.last?.id.uuidString)
            activeLifeline = card
            if record?.id == context.id { if record?.lifelines == nil { record?.lifelines = [] }; record?.lifelines?.append(card); persist() }
            lifelineStatus = "Next question ready · \(mode). Original bank wording preserved."
            showPrivatePanel()
        } catch { lifelineStatus = "Question could not be saved: \(error.localizedDescription)" }
    }
    func setLifelineHistory(_ id: UUID,status: String) {
        if let i = record?.lifelines?.firstIndex(where:{$0.id == id}) { record?.lifelines?[i].status = status; persist() }
    }
    func lifelineAction(_ action: String) {
        guard let card = activeLifeline else { return }
        do {
            switch action {
            case "asked": try questions.setStatus(card.profileID,id:card.question.id,status:.asked)
            case "skip": try questions.setStatus(card.profileID,id:card.question.id,status:.skipped)
            case "save":
                try questions.updateQuestion(card.profileID,id:card.question.id) { q in q.savedForLater = true; q.status = .available }
                lifelineExcluded.insert(card.question.id)
            default: lifelineExcluded.insert(card.question.id)
            }
            setLifelineHistory(card.id,status:action); activeLifeline = nil; lifelineCache = nil; refreshPrivatePanel()
        } catch { lifelineStatus = error.localizedDescription }
    }
    func tickLifeline() {
        let now = elapsed
        lullState.observe(at:now,mic:audio.micLevel,system:audio.audioLevel)
        guard let record, let profile = lifelineProfile else { return }
        let cache = lifelineCache
        let matches = cache.map { $0.profileID == profile.id && $0.revision == profile.revision && $0.recordID == record.id &&
            $0.anchor == Self.lifelineAnchor(record) && Date().timeIntervalSince($0.date) < 60 && $0.review.anchor_ref != nil } ?? false
        let healthy = audio.isCapturing && audio.micActive && !audio.micSignalLost && lifelineTranscriptHealthy
        guard lullState.mayOffer(at:now,settings:profile.settings,recording:isRecording,healthy:healthy,
              busy:liveEditorialBusy || lifelineBusy || alertsMuted || processingReport || stories.busy,
              visible:activeSuggestion != nil || activeLifeline != nil,
              unresolved:record.threads.contains(where:{$0.status == "open"}),lastLine:record.lines.last,review:cache?.review,reviewMatches:matches),let cache else { return }
        lullState.attempted(at:now)
        showLifeline(cache.review,evidence:cache.evidence,profile:profile,record:record,mode:"automatic")
    }
    func flushQuestionsBeforeClose() {
        do { if !questions.state.profiles.isEmpty { try questions.flush() }; persist() }
        catch { lifelineStatus = "Question save failed: \(error.localizedDescription)" }
    }
}
