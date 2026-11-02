import Foundation
import Darwin

@MainActor enum StoryLiveTest {
    /// Uses only temporary synthetic material, the existing selected provider and its existing allowance.
    static func run() async -> Int32 {
        var total = 0; var failures = [String]()
        func check(_ value: Bool,_ label: String) {
            total += 1; print("\(value ? "PASS" : "FAIL") live story: \(label)"); if !value { failures.append(label) }; fflush(stdout)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-story-live-\(UUID())")
        do {
            guard !ProducerInference.model.isEmpty else { throw ProducerError.message("Select an eligible model using the existing Connection panel first.") }
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let memory = ConversationMemory(url:folder.appendingPathComponent("memory.sqlite"))
            try await memory.saveDossier("SYNTHETIC TEST ONLY. Open investigation; no predetermined protagonist or established scene-wide musical evolution. Use concrete evidence and preserve doubt.")
            struct Case {
                var name: String; var answer: String; var followup: String; var expected: Bool; var terms: [String]
            }
            let cases: [Case] = [
                .init(name:"documented house closure and continuation are not a new revelation",answer:"As that 2015 Observer article already reported, the house closed in 2010 and I continued booking at Cedar Hall. That's the familiar history, with no new information to add.",followup:"That covers the published background. Thank you.",expected:false,terms:[]),
                .init(name:"routine organizer biography does not trigger a generic Alex profile",answer:"I booked shows, met friends and tried to welcome newcomers. That community story has already been reported, and I have no new example to add here.",followup:"Thanks. Let's take a break.",expected:false,terms:[]),
                .init(name:"claimed musical change elicits concrete recordings",answer:"I think the sound has really changed: the recent work is more electronic and less continuously loud than the older work. I haven't given you any concrete recordings to compare, though.",followup:"Interesting. Let's move on to ticket prices.",expected:true,terms:["record","release","track","album","performance"]),
                .init(name:"national importance claim elicits a specific outside connection",answer:"I think Harbor City has become crucial to the national experimental underground. I mean artists outside Texas depend on us, though I haven't named any example.",followup:"Interesting. Tell me about your new equipment instead.",expected:true,terms:["tour","collaborat","artist","outside","connection","example","release"]),
                .init(name:"overlooked person needs a consequential contribution",answer:"A person I'll call Test Rowan made something possible that changed the way our whole group worked, but none of the histories mentions them. I haven't explained what they did.",followup:"Let's change the subject to rehearsal schedules.",expected:true,terms:["contribut","what did","what exactly","made possible","change","do ","did "] ),
                .init(name:"ordinary answer remains quiet",answer:"We rehearsed on Tuesday, then had dinner. It was an ordinary week and everything went fine.",followup:"Great, thanks.",expected:false,terms:[]),
                .init(name:"interviewer already asking for recordings is not interrupted",answer:"The sound seems more electronic to me these days, but I haven't offered examples.",followup:"Can you name an older recording and a recent one, and explain the audible differences?",expected:false,terms:[]),
                .init(name:"explicit limits do not inflate national significance",answer:"I don't have evidence of national influence. I can only speak about my two local shows, and those were normal evenings. We shouldn't make broader claims from that.",followup:"Understood. Let's pause here.",expected:false,terms:[])
            ]
            print("Synthetic live editorial checks through \(ProducerInference.useGroq ? "explicitly selected Groq text" : "existing ChatGPT-plan") model \(ProducerInference.model). No personal interviews or ordinary memory database read."); fflush(stdout)
            for fixture in cases {
                var r = StoryFixtures.interview(); r.lines = [
                    .init(start:10,end:20,speaker:.them,text:fixture.answer),
                    .init(start:22,end:28,speaker:.me,text:fixture.followup)
                ]
                let service = EditorialService(archive:memory)
                let result = try await service.analyze(lines:r.lines,research:EditorialProfile.coverageContext,known:[],
                    interviewEvidence:StoryEvidence.passages([r]),investigations:StoryEngine.context(StoryDirection.initial))
                check(result.decision.should_suggest == fixture.expected,fixture.name)
                if result.decision.should_suggest {
                    print("  Question: \(result.decision.suggested_question)")
                    if !fixture.terms.isEmpty { check(fixture.terms.contains(where:result.decision.suggested_question.lowercased().contains),"question seeks concrete evidence for \(fixture.name)") }
                }
                for lead in result.story_leads ?? [] {
                    let update = try StoryEvidence.validate(lead,evidence:result.suppliedEvidence ?? [],label:"Synthetic live test")
                    check(!update.stage.hasPrefix("Evidence-supported finding"),"live hypothesis never becomes a confirmed finding")
                }
                fflush(stdout)
            }
            let r = StoryFixtures.interview(), b = StoryFixtures.opposing()
            let engine = StoryEngine(memory:memory)
            let context = try await engine.prepare(query:"Cedar Route 2018 2021 electronics recordings repair Test Rowan",records:[r,b],publications:StoryFixtures.registry,currentID:r.id)
            let report = try await engine.report(record:r,directions:StoryDirection.initial,context:context)
            check((2...3).contains(report.content.directions.count),"post-interview analysis retains several competing article directions")
            check(report.content.originality_audit.contains(where:{$0.refs.contains("COV-DEMO-2015") && ["already extensively covered","partially covered"].contains($0.category)}),"post-interview originality audit recognizes existing Observer coverage")
            check(report.content.contradictions.contains(where: { c in
                let receipts = (try? StoryEvidence.resolve(c.sides,in:report.evidence)) ?? []
                return receipts.contains(where:{$0.evidence.role.contains("Alder")}) && receipts.contains(where:{$0.evidence.role.contains("Birch")}) && c.kind != "verified inconsistency"
            }),"report preserves conflicting attributed accounts without pretending verification")
            check(report.content.pitch.assessment != "ready for journalist review","single uncorroborated interview does not automatically become pitch ready")
            let director = try await engine.brief(source:"Casey Reed",background:"Journalist-supplied: filmmaker behind Community Voices. Ask about what was documented, editing choices, omissions and who could offer another account. No other biography verified.",directions:StoryDirection.initial,context:context)
            let musician = try await engine.brief(source:"Synthetic contemporary musician",background:"This source plays current experimental shows and can explain their own techniques and collaborations. They did not attend the old house shows and cannot testify to that period firsthand.",directions:StoryDirection.initial,context:context)
            check(director.content.questions.count == 10 && musician.content.questions.count == 10 && director.content.essential_indices.count == 3,"real briefs produce ten questions and three essentials per source")
            check(Set(director.content.questions).intersection(musician.content.questions).count <= 3,"different sources receive different question lists")
            check(director.content.questions.joined().lowercased().contains("film") || director.content.questions.joined().lowercased().contains("document"),"filmmaker brief addresses documentary knowledge")
            let updates = try await engine.review(record:r,directions:StoryDirection.initial,context:context)
            check(updates.count >= 2,"on-demand investigation review creates competing evidence-grounded updates")
            if let i = CommandLine.arguments.firstIndex(of:"--story-live-artifacts"), i+1 < CommandLine.arguments.count {
                let out = URL(fileURLWithPath:CommandLine.arguments[i+1],isDirectory:true)
                try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
                try ("SYNTHETIC TEST — invented testimony; not real reporting.\n\n"+report.markdown).write(to:out.appendingPathComponent("Story-editor-live-example.md"),atomically:true,encoding:.utf8)
                try ("SYNTHETIC TEST — background supplied for a test, not a verified biography.\n\n"+director.markdown).write(to:out.appendingPathComponent("Pre-interview-brief-example.md"),atomically:true,encoding:.utf8)
            }
        } catch { check(false,"request or validation failed: \(error.localizedDescription)") }
        print("Live story checks: \(total-failures.count)/\(total) passed. Qualitative judgments still require journalist review.")
        fflush(stdout)
        return failures.isEmpty ? 0 : 1
    }
}
