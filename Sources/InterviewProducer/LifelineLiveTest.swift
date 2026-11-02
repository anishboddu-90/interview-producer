import Foundation
import Darwin

@MainActor enum LifelineLiveTest {
    static func run() async -> Int32 {
        var total = 0; var failures = [String]()
        func check(_ yes: Bool,_ label: String) { total += 1; if !yes { failures.append(label) }; print("\(yes ? "PASS" : "FAIL") live Lifeline: \(label)"); fflush(stdout) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-lifeline-live-\(UUID())")
        do {
            guard !ProducerInference.model.isEmpty else { throw ProducerError.message("Select an eligible model in the existing Connection page first.") }
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let memory = ConversationMemory(url:folder.appendingPathComponent("memory.sqlite"))
            try await memory.saveDossier("SYNTHETIC TEST. Keep musical change provisional. No predetermined protagonist or national significance.")
            let engine = LifelineEngine(memory:memory)
            var profile = LifelineFixtures.profile
            let current = LifelineFixtures.record()
            let firstStart = Date()
            let (choice,_) = try await engine.choose(profile:profile,record:current)
            check(choice.next_question_id == "music" && !choice.pending_followup,"manual choice selects concrete recordings rather than first bank entry")
            check(!choice.answers.contains(where:{$0.question_id == "music"}),"unexplained listening claim is not mistaken for a substantive answer")
            print("  Fresh cloud review: \(String(format:"%.1f",Date().timeIntervalSince(firstStart)))s. Current cached reviews and preparation/local choices need no new inference."); fflush(stdout)
            let answerRecord = LifelineFixtures.record(LifelineFixtures.substantive)
            let (answerReview,evidence) = try await engine.choose(profile:profile,record:answerRecord)
            let library = LifelineLibrary(url:folder.appendingPathComponent("questions.json")); try library.addProfile(profile)
            let changed = try library.applyAnswers(answerReview.answers,profileID:profile.id,expectedRevision:0,record:answerRecord,evidence:evidence)
            check(changed > 0 && library.selected?.questions.first(where:{$0.id == "music"})?.status == .answered,"real model recognizes an unsolicited substantive answer with validated exact transcript receipts")
            check(answerReview.next_question_id != "music","already substantively answered question is not selected again")
            let negative = LifelineFixtures.record("I have heard those recording titles, but I have not listened closely enough to compare their electronic textures or say what you should listen for.")
            let (mention,_) = try await engine.choose(profile:profile,record:negative)
            check(!mention.answers.contains(where:{$0.question_id == "music"}),"long topic mention explicitly denying an answer does not complete the question")
            let thinking = LifelineFixtures.record("Let me think about that for a moment... I need a little time to remember what happened.")
            let (pause,_) = try await engine.choose(profile:profile,record:thinking)
            check(pause.thinking_pause || !pause.answer_complete,"real model keeps a thinking pause quiet for automatic consideration")
            profile.questions[1].status = .skipped
            let (skipped,_) = try await engine.choose(profile:profile,record:current)
            check(skipped.next_question_id != "music","real model respects a skipped prepared question")
            let service = EditorialService(archive:memory)
            var revelation = LifelineFixtures.record("There was a point when we nearly stopped organizing shows altogether, but I haven't told you what happened.")
            revelation.lines.append(.init(start:22,end:28,speaker:.me,text:"Interesting. Let's talk about this week's timetable instead."))
            let result = try await service.analyze(lines:revelation.lines,research:EditorialProfile.coverageContext,known:[],interviewEvidence:StoryEvidence.passages([revelation]),questionBank:LifelineFixtures.profile)
            check(result.decision.should_suggest,"important investigative follow-up still surfaces with a question bank loaded")
            check(result.lifeline_review == nil || result.lifeline_review?.pending_followup == true || result.lifeline_review?.next_question_id == nil,"live review does not compete with the investigative alert")
            print("Only temporary synthetic profiles/interviews were used; no personal archive, live audio or real question statuses changed.")
        } catch { check(false,"request or validation failed: \(error.localizedDescription)") }
        print("Live Lifeline checks: \(total-failures.count)/\(total) passed. Model judgments remain fallible."); fflush(stdout)
        return failures.isEmpty ? 0 : 1
    }
}
