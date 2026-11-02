import Foundation

@MainActor enum LifelineTests {
    static func run() async -> Int32 {
        var total = 0; var failures = [String]()
        func check(_ yes: Bool,_ name: String) { total += 1; if !yes { failures.append(name); print("FAIL lifeline: \(name)") } }
        func rejects(_ name: String,_ action: () throws -> Void) { do { try action(); check(false,name) } catch { check(true,name) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-lifeline-tests-\(UUID())")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let file = folder.appendingPathComponent("profiles.json")
            let library = LifelineLibrary(url:file)
            check(library.state.profiles.isEmpty && library.selected == nil,"fresh app has no app-wide Alex question default")
            var p = LifelineFixtures.profile
            check(!p.settings.automatic,"automatic mode defaults OFF for every new profile")
            try library.addProfile(p)
            check(LifelineRanking.candidates(p,lines:LifelineFixtures.record().lines).first?.id == "music","manual local ranking selects relevant unanswered question instead of first list entry")
            var nearEnd = p; nearEnd.settings.remainingMinutes = 3; nearEnd.questions[1].priority = 1
            check(LifelineRanking.candidates(nearEnd,lines:[]).prefix(2).contains(where:{$0.essential}),"remaining time gives essential questions priority")
            var priorAnswer = StoryEvidence.passage(LifelineFixtures.record().lines[0],record:LifelineFixtures.record())
            priorAnswer.origin = "publication"; priorAnswer.excerpt = p.questions[1].text; priorAnswer.threadStatus = "answered"
            check(LifelineRanking.candidates(p,lines:[],evidence:[priorAnswer]).contains(where:{$0.id == "music"}),"prior publication/conversation answer does not block independent questioning of a new source")
            let changedTopic = LifelineFixtures.record("We spent that entire section discussing touring exchanges and Portland organizers.")
            check(!LifelineRanking.localBridge(p.questions[1],lines:changedTopic.lines).isEmpty,"topic switch gets a neutral conversational transition")
            var asked = LifelineFixtures.record(); asked.lines = [.init(start:1,end:2,speaker:.me,text:p.questions[1].text)]
            check(!LifelineRanking.candidates(p,lines:asked.lines).contains(where:{$0.id == "music"}),"a near-identical question already asked is excluded without requiring exact model wording")
            try library.markObservedAsked(profileID:p.id,record:asked)
            check(library.profile(p.id)?.questions[1].status == .asked && library.profile(p.id)?.questions[1].statusHistory.first?.evidence.first?.evidence.role.hasPrefix("Journalist") == true,"asked detection retains the exact attributed interviewer receipt")
            try library.setStatus(p.id,id:"music",status:.available,manual:false)
            try library.setStatus(p.id,id:"people",status:.skipped)
            check(!LifelineRanking.candidates(library.profile(p.id)!,lines:[]).contains(where:{$0.id == "people"}),"skipped questions are not repeatedly suggested")
            try library.updateQuestion(p.id,id:"networks") { q in q.notes = "Ask an organizer outside the same circle."; q.transition = "Turning to touring connections,"; q.researchContext = "Seek a concrete exchange, not national hype."; q.savedForLater = true }
            let reopened = LifelineLibrary(url:file)
            check(reopened.selected?.id == p.id && reopened.selected?.questions[3].status == .skipped,"selected bank and manual statuses survive a new process-style load")
            check(reopened.selected?.questions[2].notes == "Ask an organizer outside the same circle." && reopened.selected?.questions[2].savedForLater == true,"notes, transitions, context and save-for-later flags persist")
            p = library.profile(p.id)!
            let jsonURL = folder.appendingPathComponent("bank.json"), mdURL = folder.appendingPathComponent("bank.md")
            try QuestionBankIO.export(p,format:"json").write(to:jsonURL)
            try QuestionBankIO.export(p,format:"md").write(to:mdURL)
            check(try QuestionBankIO.read(jsonURL) == p,"JSON import/export preserves all required fields, IDs, exact wording, status and order")
            check(try QuestionBankIO.read(mdURL) == p,"Markdown export's complete metadata block roundtrips all original fields")
            let markdown = "# Prepared interview\n## Music\n1. Which exact recordings should I compare?\n   ID: supplied-q1\n   Priority: 5\n   Status: asked\n   Essential: true\n   Transition: Before moving on,\n   Research context: Test the audible claim.\n   Notes: Keep the caveat.\n2. What did the organizer contribute?\n"
            let parsed = try QuestionBankIO.markdown(markdown,name:"unused")
            check(parsed.questions[0].id == "supplied-q1" && parsed.questions[0].category == "Music" && parsed.questions[0].priority == 5 && parsed.questions[0].status == .asked && parsed.questions[0].essential,"numbered Markdown preserves category, priority, status and essential metadata")
            check(parsed.questions[0].transition == "Before moving on," && parsed.questions[0].researchContext == "Test the audible claim." && parsed.questions[0].notes == "Keep the caveat.","Markdown optional fields are preserved rather than concatenated into question text")
            rejects("duplicate question IDs fail without overwriting fields") { var invalid = p; invalid.questions.append(invalid.questions[0]); try QuestionBankIO.validate(invalid) }
            rejects("duplicate profile import cannot erase saved progress") { try library.importBank(jsonURL) }
            let draftLib = LifelineLibrary(url:folder.appendingPathComponent("drafts.json")); try draftLib.addProfile(p)
            try draftLib.updateQuestion(p.id,id:"music") { $0.text = "" }
            check(LifelineLibrary(url:folder.appendingPathComponent("drafts.json")).selected?.questions[1].text == "","cleared question draft autosaves through app closure rather than reverting text")
            check(!LifelineRanking.candidates(draftLib.selected!,lines:[]).contains(where:{$0.id == "music"}),"incomplete question drafts are never suggested")
            let originalOrder = p.questions.map(\.id)
            try library.move(p.id,id:"networks",delta:-1)
            check(library.profile(p.id)?.questions.map(\.id) != originalOrder,"question reordering is saved")
            try library.duplicateQuestion(p.id,id:"networks")
            check(library.profile(p.id)?.questions.count == 5 && Set(library.profile(p.id)!.questions.map(\.id)).count == 5,"duplicate question gets a new ID and keeps original wording")
            try library.duplicateProfile(p.id)
            check(library.selected?.id != p.id && library.selected?.questions.allSatisfy({$0.status == .available}) == true && library.selected?.settings.automatic == false,"duplicate for a new interview resets its own progress and keeps automatic off")
            check(library.profile(p.id)?.questions.first(where:{$0.id == "people"})?.status == .skipped,"duplicating a bank never changes the original profile's statuses")
            check(!p.matchesSource("Another interviewee") && p.matchesSource("Synthetic Source Alder"),"source-specific bank cannot silently attach to unrelated interviewees")

            let answerRecord = LifelineFixtures.record(LifelineFixtures.substantive)
            let answerEvidence = StoryEvidence.passages([answerRecord])
            let answer = LifelineAnswerUpdate(question_id:"music",confidence:0.99,explanation:"The source provides two recordings, listening locations, audible differences and a scope caveat.",citations:[.init(ref:answerEvidence[0].id,quote:LifelineFixtures.substantive)])
            let answerLib = LifelineLibrary(url:folder.appendingPathComponent("answers.json")); try answerLib.addProfile(LifelineFixtures.profile)
            let changed = try answerLib.applyAnswers([answer],profileID:p.id,expectedRevision:0,record:answerRecord,evidence:answerEvidence)
            check(changed == 1 && answerLib.selected?.questions[1].status == .answered,"substantive answer is recognized without the exact question ever being asked")
            let receipt = answerLib.selected!.questions[1].statusHistory[0]
            check(receipt.evidence[0].quote == LifelineFixtures.substantive && receipt.evidence[0].evidence.reference.contains("[00:10]"),"automatic answer status retains exact quote, source identity and timestamp")
            check(!LifelineRanking.candidates(answerLib.selected!,lines:[]).contains(where:{$0.id == "music"}),"substantively answered question is not repeated")
            try answerLib.setStatus(p.id,id:"music",status:.available)
            let manualRevision = answerLib.selected!.revision
            _ = try answerLib.applyAnswers([answer],profileID:p.id,expectedRevision:manualRevision,record:answerRecord,evidence:answerEvidence)
            check(answerLib.selected?.questions[1].status == .available && answerLib.selected?.questions[1].manualStatus == true,"manual override wins over a later AI status update")
            rejects("in-flight stale review cannot overwrite a more recent bank edit") { _ = try answerLib.applyAnswers([answer],profileID:p.id,expectedRevision:0,record:answerRecord,evidence:answerEvidence) }
            try answerLib.setStatus(p.id,id:"music",status:.available,manual:false)
            let briefRecord = LifelineFixtures.record("I own those recordings.")
            let briefEvidence = StoryEvidence.passages([briefRecord])
            var briefUpdate = answer; briefUpdate.citations = [.init(ref:briefEvidence[0].id,quote:briefEvidence[0].excerpt)]
            _ = try answerLib.applyAnswers([briefUpdate],profileID:p.id,expectedRevision:answerLib.selected!.revision,record:briefRecord,evidence:briefEvidence)
            check(answerLib.selected?.questions[1].status == .available,"mere topic or recording mention does not mark question answered")
            var publication = answerEvidence[0]; publication.id = "PUB-test"; publication.origin = "publication"; publication.role = "supplied research"
            var publishedUpdate = answer; publishedUpdate.citations = [.init(ref:publication.id,quote:publication.excerpt)]
            _ = try answerLib.applyAnswers([publishedUpdate],profileID:p.id,expectedRevision:answerLib.selected!.revision,record:answerRecord,evidence:[publication])
            check(answerLib.selected?.questions[1].status == .available,"previously published coverage does not become this source's live answer")
            var assistant = publication; assistant.id = "MEM-assistant"; assistant.origin = "conversation"; assistant.role = "assistant"
            publishedUpdate.citations = [.init(ref:assistant.id,quote:assistant.excerpt)]
            _ = try answerLib.applyAnswers([publishedUpdate],profileID:p.id,expectedRevision:answerLib.selected!.revision,record:answerRecord,evidence:[assistant])
            check(answerLib.selected?.questions[1].status == .available,"assistant speculation cannot substantively answer a question on the interviewee's behalf")
            try answerLib.updateQuestion(p.id,id:"music") { $0.status = .answered }
            try answerLib.updateQuestion(p.id,id:"music") { $0.text = "What different musical question remains to be investigated?" }
            check(answerLib.selected?.questions[1].status == .available,"editing the question invalidates its automatic answered status while retaining history")

            var lull = LifelineLullState(); var settings = LifelineSettings(); settings.automatic = true
            lull.observe(at:1,mic:0.02,system:0); lull.observe(at:10,mic:0,system:0.04)
            let finalLine = InterviewLine(start:9,end:10,speaker:.them,text:"That is everything I can add about those particular recordings.")
            let review = LifelineFixtures.review(answerRecord)
            func gate(_ at: Double = 19,_ health: Bool = true,_ busy: Bool = false,_ visible: Bool = false,_ open: Bool = false,_ line: InterviewLine? = finalLine,_ r: LifelineReview? = review,_ matches: Bool = true) -> Bool {
                lull.mayOffer(at:at,settings:settings,recording:true,healthy:health,busy:busy,visible:visible,unresolved:open,lastLine:line,review:r,reviewMatches:matches)
            }
            check(gate(),"auto consideration requires both channels, healthy transcript, completed answer, silence and confidence")
            settings.automatic = false; check(!gate(),"manual availability does not enable automatic mode"); settings.automatic = true
            var thinking = review; thinking.thinking_pause = true
            check(!gate(19,true,false,false,false,finalLine,thinking),"interviewee thinking pause remains quiet")
            var thinkingLine = finalLine; thinkingLine.text = "Let me think about that for a moment..."
            check(!gate(19,true,false,false,false,thinkingLine),"hesitation transcript blocks a false silence alert")
            check(!gate(19,true,false,false,false,finalLine,nil),"silence alone without a completed-answer review cannot trigger")
            check(!gate(19,false),"transcription interruption disables automatic Lifeline")
            check(!gate(19,true,false,true),"visible investigative follow-up or Lifeline prevents an automatic card")
            check(!gate(19,true,true),"editorial analysis in progress takes priority")
            check(!gate(19,true,false,false,true),"unresolved substantive thread prevents a topic switch")
            var interviewer = finalLine; interviewer.speaker = .me; interviewer.text = "Could you explain that?"
            check(!gate(19,true,false,false,false,interviewer),"interviewer already starting a follow-up is not interrupted")
            var stale = finalLine; stale.end = 2
            check(!gate(19,true,false,false,false,stale),"untranscribed recent speech cannot be mistaken for a completed silence")
            check(!gate(19,true,false,false,false,finalLine,review,false),"stale transcript/model anchor blocks automatic suggestions")
            lull.attempted(at:19)
            check(!gate(120),"one pause cannot generate repeated suggestions even after the cooldown expires")
            lull.observe(at:121,mic:0,system:0.02); var later = finalLine; later.end = 121
            check(!gate(126,true,false,false,false,later),"configured silence duration is enforced after a new turn")
            check(gate(130,true,false,false,false,later),"new completed turn can qualify after cooldown and fresh silence")
            lull.attempted(at:130); lull.observe(at:135,mic:0,system:0.02); later.end = 135
            check(!gate(144,true,false,false,false,later),"automatic mode respects its cooldown across consecutive turns")
            var exhausted = p; for i in exhausted.questions.indices { exhausted.questions[i].status = .answered }
            check(LifelineRanking.candidates(exhausted,lines:[]).isEmpty,"exhausted question bank is handled without inventing a question")

            let memory = ConversationMemory(url:folder.appendingPathComponent("memory.sqlite"))
            let liveRecord = LifelineFixtures.record()
            let response = LifelineFixtures.review(liveRecord)
            let probe = StoryPromptProbe(try StoryFixtures.json(response))
            let engine = LifelineEngine(memory:memory,inference:{ system,input in await probe.complete(system,input) })
            let (choice,provided) = try await engine.choose(profile:LifelineFixtures.profile,record:liveRecord)
            check(choice.next_question_id == "music" && provided.contains(where:{$0.origin == "dossier"}),"manual service uses current transcript, local dossier/retrieval and eligible bank through existing inference")
            let prompt = await probe.snapshot()[0]
            check(prompt.0.contains("not independently verified") && prompt.0.contains("new perspective") && prompt.0.contains("original wording unchanged"),"ranking instructions preserve memory uncertainty, independent verification and question wording")
            var invalid = response; invalid.next_question_id = "invented-id"
            rejects("model cannot invent a new question ID") { try LifelineEngine.validate(invalid,profile:LifelineFixtures.profile,record:liveRecord,evidence:provided) }
            var skippedProfile = LifelineFixtures.profile; skippedProfile.questions[1].status = .skipped
            rejects("model cannot select a skipped question") { try LifelineEngine.validate(response,profile:skippedProfile,record:liveRecord,evidence:provided) }
            invalid = response; invalid.anchor_ref = "INT-obsolete"
            rejects("model cannot certify an outdated transcript anchor") { try LifelineEngine.validate(invalid,profile:LifelineFixtures.profile,record:liveRecord,evidence:provided) }
            let quiet = EditorialEnvelope(decision:.init(should_suggest:false,confidence:0,priority:"medium",suggested_question:"",reason:"",evidence_excerpt:"",related_topic:"",timestamp:0),threads:[],resolved_titles:[],source_refs:[],lifeline_review:response)
            let envelopeProbe = StoryPromptProbe(try StoryFixtures.json(quiet))
            let editorial = EditorialService(archive:memory,inference:{ system,input in await envelopeProbe.complete(system,input) })
            let integrated = try await editorial.analyze(lines:liveRecord.lines,research:"",known:[],interviewEvidence:StoryEvidence.passages([liveRecord]),questionBank:LifelineFixtures.profile)
            let integratedCalls = await envelopeProbe.snapshot().count
            check(integrated.lifeline_review?.next_question_id == "music" && integratedCalls == 1,"live bank review piggybacks on the existing call instead of adding inference per sentence")
            var raw = try JSONSerialization.jsonObject(with:Data(try StoryFixtures.json(quiet).utf8)) as! [String:Any]; raw["lifeline_review"] = ["invalid":"payload"]
            let malformed = try JSONDecoder().decode(EditorialEnvelope.self,from:JSONSerialization.data(withJSONObject:raw))
            check(malformed.lifeline_review == nil && !malformed.decision.should_suggest,"malformed optional Lifeline data cannot break an existing follow-up response")
            let finalQuestion = p.questions[1]
            let card = SavedLifeline(profileID:p.id,question:finalQuestion,bridge:"A neutral bridge.",reason:"A relevant next topic.",mode:"manual",evidence:[])
            var saved = liveRecord; saved.lifelines = [card]
            let decoded = try JSONDecoder().decode(InterviewRecord.self,from:JSONEncoder().encode(saved))
            check(decoded.lifelines?.first?.question.text == finalQuestion.text && decoded.lines == saved.lines,"interview history roundtrips exact prepared question and unchanged transcript")
            check(String(decoding:try InterviewStore.export(saved,format:"md"),as:UTF8.self).contains("Question Lifeline history"),"readable interview export includes Lifeline history")
            try library.shortcut(key:"Q",modifiers:"Control+Option",enabled:true)
            check(LifelineLibrary(url:file).state.shortcutKey == "Q","configurable global shortcut persists")
            let corrupt = folder.appendingPathComponent("corrupt.json"); try Data("broken".utf8).write(to:corrupt)
            let broken = LifelineLibrary(url:corrupt)
            rejects("unreadable saved bank is never silently overwritten") { try broken.flush() }
            check(try Data(contentsOf:corrupt) == Data("broken".utf8),"unreadable original bank remains intact for recovery")
        } catch { check(false,"unexpected error: \(error.localizedDescription)") }
        print("Question Lifeline tests: \(total-failures.count)/\(total) passed. Temporary profiles and synthetic transcripts; no real audio or cloud requests.")
        for f in failures { print("  \(f)") }
        return failures.isEmpty ? 0 : 1
    }
}
