import Foundation

@MainActor enum StoryTests {
    static func run() async -> Int32 {
        var total = 0; var failures = [String]()
        func check(_ value: Bool,_ name: String) { total += 1; if !value { failures.append(name); print("FAIL story: \(name)") } }
        func rejects(_ name: String,_ action: () throws -> Void) { do { try action(); check(false,name) } catch { check(true,name) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-story-tests-\(UUID())")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let r = StoryFixtures.interview(), b = StoryFixtures.opposing()
            let e = StoryEvidence.passages([r]), opposite = StoryEvidence.passages([b])
            let candidates = e+opposite+StoryFixtures.registry
            check(e[0].role.contains("Synthetic Source Alder") && opposite[0].role.contains("Synthetic Source Birch"),"separate named source attribution in original passages")
            check(e[0].reference.contains("[00:10]") && opposite[0].reference.contains("[01:15]"),"source timestamps and interview identities remain intact")
            let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
            let original = try canonical.encode(r)
            var lead = StoryFixtures.lead(e[0]); lead.stage = "finding"
            let first = try StoryEvidence.validate(lead,evidence:candidates,label:"Synthetic")
            check(first.stage.contains("hypothesis") && !first.stage.contains("Evidence-supported finding"),"new musical observation cannot auto-promote itself into an established finding")
            check(first.support[0].quote == lead.supporting[0].quote && first.support[0].evidence == e[0],"validated exact quote retains its original source snapshot")
            var bad = lead; bad.supporting[0].quote = "A fabricated scene-wide evolution nobody stated."
            rejects("reject invented quotes") { _ = try StoryEvidence.validate(bad,evidence:candidates,label:"test") }
            bad = lead; bad.supporting[0].ref = "INT-unknown"
            rejects("reject invented source references") { _ = try StoryEvidence.validate(bad,evidence:candidates,label:"test") }
            bad = lead; bad.coverage_refs = [e[0].id]
            rejects("testimony cannot masquerade as prior published coverage") { _ = try StoryEvidence.validate(bad,evidence:candidates,label:"test") }
            bad = lead; bad.supporting = [.init(ref:"COV-DEMO-2015",quote:StoryFixtures.registry[0].excerpt)]
            rejects("coverage description alone cannot establish a new story lead") { _ = try StoryEvidence.validate(bad,evidence:candidates,label:"test") }
            bad = lead; bad.next_sources[0].basis = []
            rejects("next source needs a specific evidence basis") { _ = try StoryEvidence.validate(bad,evidence:candidates,label:"test") }
            bad = lead; bad.lane = "unexpected: access and repair"
            let unexpected = try StoryEvidence.validate(bad,evidence:candidates,label:"test")
            check(unexpected.lead.lane.contains("access and repair"),"unexpected discoveries can create a new category")
            let ledgerURL = folder.appendingPathComponent("story.json")
            let library = StoryLibrary(url:ledgerURL)
            check(library.ledger.directions.count == 3 && library.ledger.directions.allSatisfy(\.updates.isEmpty),"initial directions are competing questions, not predetermined theses")
            var historyLead = StoryFixtures.lead(e[2],lane:"history"); historyLead.question = "Which uncredited contributions made these practices possible?"
            let history = try StoryEvidence.validate(historyLead,evidence:candidates,label:"first interview")
            let network = try StoryEvidence.validate(StoryFixtures.lead(e[1],lane:"networks"),evidence:candidates,label:"first interview")
            try library.apply([first,network,history,unexpected],interview:r)
            check(library.ledger.directions.filter { !$0.updates.isEmpty }.count == 4,"several competing directions coexist without choosing an article")
            let count = library.ledger.directions.reduce(0) { $0+$1.updates.count }
            try library.apply([first,network,history,unexpected])
            check(library.ledger.directions.reduce(0) { $0+$1.updates.count } == count,"same receipts do not produce a stream of repeated leads")
            var competing = StoryFixtures.lead(e[0]); competing.question = "Does quietness rather than electronics explain changes in live performance?"
            try library.apply([StoryEvidence.validate(competing,evidence:candidates,label:"alternative")])
            check(library.ledger.directions.filter { $0.id.hasPrefix("music") && !$0.updates.isEmpty }.count == 2,"different questions within one lane remain competing hypotheses")
            var dispute = StoryFixtures.lead(e[1],lane:"networks")
            dispute.contradicting = [.init(ref:opposite[0].id,quote:opposite[0].excerpt)]
            try library.apply([StoryEvidence.validate(dispute,evidence:candidates,label:"second interview")],interview:b)
            let reopened = StoryLibrary(url:ledgerURL)
            let disputed = reopened.ledger.directions.flatMap(\.updates).first { !$0.opposition.isEmpty }!
            check(disputed.support[0].evidence.role.contains("Alder") && disputed.opposition[0].evidence.role.contains("Birch"),"conflicting testimony survives disk roundtrip without becoming one generic narrative")
            check(disputed.support[0].quote.contains("2018") && disputed.opposition[0].quote.contains("2021"),"different dates and caveats preserved verbatim")
            check(reopened.ledger.interviewVersions[r.id.uuidString] == StoryEvidence.fingerprint(r),"tracks which transcript version has already been reviewed")
            reopened.index([r,b])
            let cross = reopened.crossEvidence(query:"Cedar Route exchange began",currentID:r.id)
            check(cross.contains(where:{$0.role.contains("Birch")}) && !cross.contains(where:{$0.conversationID == r.id.uuidString}),"automatic cross-interview retrieval excludes current source and recovers another account")
            var excluded = b; excluded.includeInStory = false; reopened.index([r,excluded])
            check(reopened.crossEvidence(query:"Cedar Route",currentID:r.id).isEmpty,"excluded interviews never enter automatic continuity retrieval")
            check(reopened.isCurrent(disputed.support[0],records:[r,b]),"unchanged evidence snapshot remains current")
            var edited = r; edited.lines[1].text += " Correction: the date is uncertain."
            check(!reopened.isCurrent(disputed.support[0],records:[edited,b]),"edited transcript invalidates old editorial receipts")
            var renamed = r; renamed.sourceName = "Corrected source identity"
            check(!reopened.isCurrent(disputed.support[0],records:[renamed,b]),"corrected attribution invalidates old source snapshots")
            try reopened.edit(id:reopened.ledger.directions[0].id,note:"Compare actual recordings; seek counterexamples.",parked:true)
            check(reopened.ledger.directions[0].parked && reopened.ledger.directions[0].note.contains("counterexamples"),"journalist can edit priorities and park a direction")
            check(try canonical.encode(r) == original,"investigation tracking leaves original transcript unchanged")

            var report = StoryFixtures.report(r,prior:opposite[1])
            report.contradictions = [.init(kind:"verified inconsistency",explanation:"Sources give different start dates; perhaps different series.",sides:[.init(ref:e[1].id,quote:e[1].excerpt),.init(ref:opposite[0].id,quote:opposite[0].excerpt)])]
            report.pitch.assessment = "ready for journalist review"
            try StoryEngine.validateReport(&report,evidence:candidates,currentID:r.id)
            check(report.contradictions[0].kind == "possible inconsistency", "unconfirmed testimony disagreements cannot become verified inconsistencies")
            check(report.pitch.assessment != "ready for journalist review", "open reporting gaps block automatic pitch readiness")
            check(report.originality_audit[0].explanation.contains("contents remain unverified"),"originality audit visibly labels unavailable article contents")
            let saved = SavedStoryReport(content:report,evidence:candidates,scope:"Synthetic test",interviewFingerprint:StoryEvidence.fingerprint(r))
            check(["A. Most important","B. Strongest","C. Originality","D. Next sources","E. Suggested recordings","F. Unresolved","G. Pitch readiness"].allSatisfy(saved.markdown.contains),"post-interview report contains all seven required sections")
            check(saved.markdown.contains("[00:10]") && saved.markdown.contains(e[0].excerpt),"report renders timestamped exact original receipts")
            check(saved.markdown.contains("already extensively covered") && saved.markdown.contains("COV-DEMO-2015"),"originality audit recognizes documented House closure and continuation")
            var missing = report; missing.discoveries[0].citations = [.init(ref:opposite[0].id,quote:opposite[0].excerpt)]
            rejects("new discovery must have a current interview receipt") { try StoryEngine.validateReport(&missing,evidence:candidates,currentID:r.id) }
            missing = report; missing.originality_audit = []
            rejects("report cannot omit originality audit") { try StoryEngine.validateReport(&missing,evidence:candidates,currentID:r.id) }
            missing = report; missing.materials[0].citations = []
            rejects("no invented recordings or archives without original evidence") { try StoryEngine.validateReport(&missing,evidence:candidates,currentID:r.id) }
            var assistant = opposite[0]; assistant.id = "MEM-assistant-test"; assistant.origin = "conversation"; assistant.role = "assistant"; assistant.classification = MemoryKind.interpretation.rawValue
            missing = report; missing.contradictions[0].sides[1] = .init(ref:assistant.id,quote:assistant.excerpt)
            rejects("assistant speculation cannot be independent contradictory testimony") { try StoryEngine.validateReport(&missing,evidence:candidates+[assistant],currentID:r.id) }
            var onlyAssistant = lead; onlyAssistant.supporting = [.init(ref:assistant.id,quote:assistant.excerpt)]
            check(try StoryEvidence.validate(onlyAssistant,evidence:candidates+[assistant],label:"test").stage.contains("hypothesis"),"prior speculative assistant remains an unverified hypothesis")

            let memory = ConversationMemory(url:folder.appendingPathComponent("memory.sqlite"))
            let export = folder.appendingPathComponent("conversations.json"); try MemoryFixtures.export().write(to:export)
            let preview = try ChatGPTExportReader.open(export)
            _ = try await memory.importSelected(preview,ids:[preview.conversations.first { $0.originalID == "synthetic-noise-research" }!.id])
            let briefProbe = StoryPromptProbe(try StoryFixtures.json(StoryFixtures.brief()))
            let engine = StoryEngine(memory:memory,inference:{ system,input in await briefProbe.complete(system,input) })
            let context = try await engine.prepare(query:"Project Aurora Project Beacon Cedar Route",records:[r,b],publications:StoryFixtures.registry,currentID:r.id)
            check(context.evidence.contains(where:{$0.role.contains("Birch")}) && context.evidence.contains(where:{$0.classification == MemoryKind.interpretation.rawValue}),"deeper context retrieves another interview and role-labeled assistant memory")
            check(context.prompt.contains(MemoryFixtures.correction),"original listening correction survives Story Editor retrieval")
            let brief = try await engine.brief(source:"Casey Reed",background:"Journalist identifies the documentary director; test scope and omissions.",directions:StoryDirection.initial,context:context)
            check(brief.content.questions.count == 10 && brief.content.essential_indices.count == 3,"pre-interview brief has ten questions and three essentials")
            let prompt = await briefProbe.snapshot()[0]
            check(prompt.1.contains("Casey Reed") && prompt.1.contains("documentary director"),"brief request uses this source's specific supplied background")
            check(prompt.0.contains("Do not reuse another source") && prompt.0.contains("not independently verified"),"brief instructions prevent generic profile reuse and invented biography")
            try reopened.saveBrief(brief)
            check(StoryLibrary(url:ledgerURL).ledger.briefs.last?.source == "Casey Reed","source-specific brief persists locally")
            var invalidBrief = StoryFixtures.brief(); invalidBrief.essential_indices = [1,1,11]
            let badBriefOutput = try StoryFixtures.json(invalidBrief)
            let badBriefEngine = StoryEngine(memory:memory,inference:{ _,_ in badBriefOutput })
            do { _ = try await badBriefEngine.brief(source:"Other source",background:"",directions:[],context:context); check(false,"reject malformed essentials") } catch { check(true,"reject malformed or duplicate essential questions") }
            let fixtureReport = StoryFixtures.report(r)
            let reportProbe = StoryPromptProbe(try StoryFixtures.json(fixtureReport))
            let reportEngine = StoryEngine(memory:memory,inference:{ system,input in await reportProbe.complete(system,input) })
            let generated = try await reportEngine.report(record:r,directions:StoryDirection.initial,context:context)
            check(generated.content.directions.count == 1 && generated.evidence.contains(where:{$0.id == e[0].id}),"actual deep-report service validates and saves original candidate evidence")
            let requests = await reportProbe.snapshot()
            check(requests.count == 1,"short report uses one inference request, not one per transcript sentence")
            check(requests[0].1.contains("Synthetic Source Birch") && requests[0].1.contains("COV-DEMO-2015"),"report compares other sources and prior coverage")

            var long = r
            for i in 0..<140 { long.lines.append(.init(start:Double(100+i*5),end:Double(104+i*5),speaker:.them,
                text:"Synthetic long interview turn \(i). "+String(repeating:"This attributed account needs checking against recordings and other witnesses. ",count:5))) }
            long.lines.append(.init(start:900,end:910,speaker:.them,text:"Correction at the end: the fictional exchange was a different event; do not merge the dates without checking the flyers."))
            let longEvidence = StoryEvidence.passages([long]); let last = longEvidence.last!
            var longReport = StoryFixtures.report(long)
            longReport.discoveries.append(.init(text:"A late correction changes how the disputed chronology should be checked.",citations:[.init(ref:last.id,quote:last.excerpt)]))
            var longJSON = try StoryFixtures.json(longReport)
            for source in [longEvidence.first!,last] { longJSON = longJSON.replacingOccurrences(of:source.id,with:source.id+"-"+String(MemoryIdentity.digest(source.excerpt).prefix(8))) }
            let packetProbe = StoryPacketProbe(evidence:longEvidence,report:longJSON)
            let packetEngine = StoryEngine(memory:memory,inference:{ system,input in try await packetProbe.complete(system,input) })
            let longResult = try await packetEngine.report(record:long,directions:[],context:context)
            let packetSnapshot = await packetProbe.snapshot()
            check(packetSnapshot.0.count > 2 && packetSnapshot.1 == 1,"long interview uses bounded chronological extraction followed by one deep report")
            check(packetSnapshot.0.last?.contains(last.excerpt) == true && longResult.evidence.contains(where:{$0.excerpt == last.excerpt}),"late corrections reach final report; no silent last-chunk truncation")
            check(longResult.scope.contains("Every one") && longResult.scope.contains("not the entire interview"),"long-report evidence selection and limitations are disclosed")
            check(long.lines.last?.text == last.excerpt,"long-interview evidence selection leaves complete original testimony unchanged")

            let quietOutput = try StoryFixtures.json(EditorialEnvelope(decision:.init(should_suggest:false,confidence:0,priority:"medium",suggested_question:"",reason:"Routine answer",evidence_excerpt:"",related_topic:"",timestamp:0),threads:[],resolved_titles:[],source_refs:[],story_leads:[]))
            let liveProbe = StoryPromptProbe(quietOutput)
            let service = EditorialService(archive:memory,inference:{ system,input in await liveProbe.complete(system,input) })
            let quiet = try await service.analyze(lines:[.init(start:0,end:3,speaker:.them,text:"We rehearsed on Tuesday and it went fine.")],research:EditorialProfile.coverageContext,known:[],interviewEvidence:[e[0]],crossInterviewEvidence:[opposite[0]])
            check(!quiet.decision.should_suggest && quiet.story_leads?.isEmpty == true,"ordinary scripted no-alert remains quiet in full live pipeline")
            let live = await liveProbe.snapshot()[0]
            check(live.0.contains("before/after examples") && live.0.contains("named connection"),"live prompt asks for concrete musical examples and specific national links")
            check(live.0.contains("Originality is not obscurity") && live.0.contains("exaggerate a subject's significance"),"live editorial objective rejects obscurity and unsupported national importance")
            check(live.0.contains("No predetermined thesis") && live.0.contains("not automatically the protagonist"),"live objective no longer defaults to a generic Alex profile")
            check(live.1.contains("Synthetic Source Alder") && live.1.contains("Synthetic Source Birch"),"live inference preserves named cross-interview accounts")
            check(await liveProbe.snapshot().count == 1,"live story bookkeeping shares the existing follow-up request")
            var rawEnvelope = try JSONSerialization.jsonObject(with:Data(quietOutput.utf8)) as! [String:Any]
            rawEnvelope["story_leads"] = [["malformed":"bookkeeping"]]
            let isolated = try JSONDecoder().decode(EditorialEnvelope.self,from:JSONSerialization.data(withJSONObject:rawEnvelope))
            check(!isolated.decision.should_suggest && isolated.story_leads == nil,"malformed story bookkeeping cannot break an otherwise valid live response")
            let transcript = folder.appendingPathComponent("other.txt")
            let raw = "[00:01] Journalist: What did you hear?\n[00:04] Interviewee: A different texture.\nBut that is just my interpretation.\n"
            try raw.write(to:transcript,atomically:true,encoding:.utf8)
            let imported = try StoryInterviewImport.read(transcript,source:"Another source",background:"Firsthand witness")
            check(imported.sourceName == "Another source" && imported.lines[1].text.contains("just my interpretation"),"timestamped import preserves source identity, roles and multiline caveats")
            check(imported.importedOriginal == Data(raw.utf8) && imported.lines[1].start == 4,"imported original bytes and source times retained")
            let json = folder.appendingPathComponent("import.json"); var unsafe = r; unsafe.systemAudioPath = "/outside/audio.caf"; try JSONEncoder().encode(unsafe).write(to:json)
            let sanitized = try StoryInterviewImport.read(json,source:"",background:"")
            check(sanitized.systemAudioPath == nil && sanitized.sourceName == r.sourceName,"JSON import preserves attribution without granting authority over arbitrary audio paths")
            let named = try StoryInterviewImport.read(json,source:"A different planned interviewee",background:"")
            check(named.sourceName == r.sourceName,"a prior planned source cannot overwrite imported JSON source identity")
            unsafe.lines[0].start = -100; try JSONEncoder().encode(unsafe).write(to:json)
            rejects("reject invalid imported timestamps before rendering or analysis") { _ = try StoryInterviewImport.read(json,source:"",background:"") }
            try "No timestamp or speaker attribution".write(to:transcript,atomically:true,encoding:.utf8)
            rejects("do not guess speakers or dates for unsupported transcript input") { _ = try StoryInterviewImport.read(transcript,source:"Named source",background:"") }
            var persisted = r; persisted.storyReport = generated
            let roundtrip = try JSONDecoder().decode(InterviewRecord.self,from:JSONEncoder().encode(persisted))
            check(roundtrip.storyReport?.evidence == generated.evidence && roundtrip.lines == r.lines,"saved interviews roundtrip structured report and original transcript")
            try reopened.removeInterview(b.id)
            check(!reopened.ledger.directions.flatMap(\.updates).flatMap { $0.support+$0.opposition }.contains(where:{$0.evidence.conversationID == b.id.uuidString}),"deleting an interview removes its testimony from future investigation context")
            let corruptURL = folder.appendingPathComponent("corrupt.json"); try Data("broken".utf8).write(to:corruptURL)
            let corrupt = StoryLibrary(url:corruptURL)
            rejects("unreadable story state is never silently overwritten") { try corrupt.persist() }
            check(try Data(contentsOf:corruptURL) == Data("broken".utf8),"corrupted original state preserved for recovery")
        } catch { check(false,"unexpected error: \(error.localizedDescription)") }
        print("Story discovery tests: \(total-failures.count)/\(total) passed. Deterministic fixtures and injected inference; no cloud calls.")
        for f in failures { print("  \(f)") }
        return failures.isEmpty ? 0 : 1
    }
}
