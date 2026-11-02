import Foundation

@MainActor enum MemoryTests {
    static func run() async -> Int32 {
        var failures = [String](); var total = 0
        func check(_ value: Bool,_ label: String) { total += 1; if !value { failures.append(label); print("FAIL memory: \(label)") } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-memory-tests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:folder) }
            let exportURL = folder.appendingPathComponent("conversations.json")
            try MemoryFixtures.export().write(to:exportURL)
            let session = try ChatGPTExportReader.open(exportURL)
            check(session.conversations.count == 2,"standard export array previews every conversation before selection")
            let chosen = session.conversations.first { $0.originalID == "synthetic-noise-research" }!
            let raw = try ChatGPTExportReader.raw(chosen)
            let memory = ConversationMemory(url:folder.appendingPathComponent("memory.sqlite"))
            let imported = try await memory.importSelected(session,ids:[chosen.id])
            check(imported.imported == 1,"only explicitly selected conversation imported")
            let conversations = try await memory.conversations()
            check(conversations.count == 1 && conversations[0].originalID == "synthetic-noise-research","unselected conversation not persisted")
            let id = conversations[0].id
            check(try await memory.originalConversation(id) == raw,"selected original JSON object is byte-for-byte lossless")
            let originals = try await memory.messages(conversation:id)
            check(originals.count == 19,"root, tools, hidden messages and alternate branches all preserved")
            check(originals.first(where:{$0.nodeID == "u1"})?.text == MemoryFixtures.winter,"listening observation exact wording preserved")
            check(originals.first(where:{$0.nodeID == "u7"})?.text == "Exact Unicode: café 🎛️ — “quoted”\nsecond line\twith tab\u{0000}after-null","Unicode, whitespace and embedded null preserved")
            check(originals.first(where:{$0.nodeID == "u7"})?.created == nil,"missing original message date remains unknown")
            check(conversations[0].created == 1699999999.75,"original conversation date preserved")
            let imageJSON = originals.first(where:{$0.nodeID == "u9"})!.originalJSON
            let imageObject = try JSONSerialization.jsonObject(with:Data(imageJSON.utf8)) as! [String:Any]
            let imageMessage = imageObject["message"] as! [String:Any]
            let contentParts = (imageMessage["content"] as! [String:Any])["parts"] as! [Any]
            let asset = contentParts[1] as! [String:Any]
            check(asset["asset_pointer"] as? String == "file-service://preserve-image-reference" && (imageMessage["metadata"] as! [String:Any])["unknown_export_field"] != nil,"multimodal pointers and unknown message metadata retained")
            let branches = try await memory.branches(conversation:id)
            check(branches.count == 2 && branches.contains(where:{$0.0 == "u9" && $0.1}),"active path and alternate branch stored separately")
            let active = try await memory.messages(conversation:id,branch:"u9")
            check(active.map(\.nodeID) == ["root","u1","a1","u2","a2","u3","a3","u4","a4","u5","a5","u6","hidden","tool","u7","u8","u9"],"parent-chain conversational order reconstructed exactly")
            let alternate = try await memory.messages(conversation:id,branch:"old-a4")
            check(alternate.suffix(2).map(\.nodeID) == ["old-u4","old-a4"],"alternate branch continuation is not flattened into active path")
            var repeatedNodes: [String:Any] = ["root":["id":"root","parent":NSNull(),"message":NSNull()]]
            for i in 0..<40 {
                repeatedNodes["a\(i)"] = ["id":"a\(i)","parent":i == 0 ? "root" : "a\(i-1)","message":["id":"repeat-\(i)","author":["role":"assistant"],"content":["content_type":"text","parts":["Project Aurora Project Aurora Project Aurora."]],"create_time":1700000100+i]]
            }
            let repeated: [String:Any] = ["id":"repeated-assistant","title":"Synthetic repeated interpretations","current_node":"a39","mapping":repeatedNodes]
            let crowdURL = folder.appendingPathComponent("repeated-assistant.json")
            try JSONSerialization.data(withJSONObject:[MemoryFixtures.conversation(),repeated]).write(to:crowdURL)
            let crowdSession = try ChatGPTExportReader.open(crowdURL)
            let directMemory = ConversationMemory(url:folder.appendingPathComponent("original-priority.sqlite"))
            _ = try await directMemory.importSelected(crowdSession,ids:Set(crowdSession.conversations.map(\.id)))
            let genericHits = try await directMemory.search("Project Aurora",limit:12,includeAlternatives:false)
            check(!genericHits.contains(where:{$0.role == "user"}),"repeated short assistant summaries can crowd the ordinary FTS candidate window")
            let directRetrieval = try await directMemory.retrieve(current:"Project Aurora")
            check(directRetrieval.passages.contains(where:{$0.role == "user" && $0.nodeID == "u1"}) && directRetrieval.prompt.contains(MemoryFixtures.correction),"automatic retrieval recovers original observation and linked correction without manual pins")
            let directConversation = try await directMemory.conversations().first { $0.originalID == "synthetic-noise-research" }!
            try await directMemory.annotate(conversation:directConversation.id,node:"u1",annotation:.init(kind:MemoryKind.observation.rawValue,note:"",sourceURL:"",threadStatus:"",pinned:false,excluded:true))
            let excludedDirect = try await directMemory.retrieve(current:"Project Aurora")
            check(!excludedDirect.passages.contains(where:{$0.conversationID == directConversation.id && $0.nodeID == "u1"}),"original-priority candidate retrieval respects material exclusion")
            let winter = try await memory.retrieve(current:"Project Aurora",rolling:"")
            check(winter.passages.contains(where:{$0.excerpt.contains("minimal traditional rhythm")}),"FTS accurately recalls the specific Project Aurora listening observation")
            check(winter.prompt.contains(MemoryFixtures.correction),"a later user correction is recovered even without repeating the album name")
            check(winter.passages.contains(where:{$0.nodeID == "u2"}),"correction has its own citable passage reference")
            try await memory.annotate(conversation:id,node:"u1",annotation:.init(kind:MemoryKind.observation.rawValue,note:"",sourceURL:"",threadStatus:"",pinned:true,excluded:false))
            let crowded = try await memory.retrieve(current:RehearsalTape.script[1].1,rolling:RehearsalTape.script[0].1)
            check(crowded.prompt.contains(MemoryFixtures.winter) && crowded.prompt.contains(MemoryFixtures.correction),"a crowded live query cannot evict a pinned observation or its linked original correction")
            try await memory.annotate(conversation:id,node:"u1",annotation:.init(kind:MemoryKind.observation.rawValue,note:"",sourceURL:"",threadStatus:"",pinned:false,excluded:false))
            let assistant = originals.first { $0.nodeID == "a1" }!
            check(assistant.kind == MemoryKind.interpretation.rawValue,"confident assistant speculation is never automatically promoted to fact")
            let psychic = try await memory.retrieve(current:"Project Beacon",rolling:"")
            check(psychic.prompt.contains("corrupted-IDM") && psychic.prompt.contains("conscious decisions or different projects"),"recall retains nuanced texture observation and alternative explanations")
            check(!psychic.prompt.contains("DiscardedDraftOnly") && !psychic.prompt.contains("ALTERNATE_REPLY_ONLY"),"alternate draft assertions excluded from automatic active-path retrieval")
            check(!(try await memory.search("HiddenOnlyNeverRetrieve")).contains(where:{$0.excerpt.contains("HiddenOnlyNeverRetrieve")}),"hidden messages excluded from normal search")
            check(!(try await memory.retrieve(current:"ToolResultOnlyPreserveRaw")).prompt.contains("ToolResultOnlyPreserveRaw"),"tool content never silently becomes user or assistant evidence")
            let manualAlternate = try await memory.search("DiscardedDraftOnly")
            check(!manualAlternate.isEmpty && manualAlternate[0].reference.contains("ALTERNATE"),"manual inspection can find separately labeled alternate branches")
            let sources = try await memory.search("example harbor history")
            check(sources.contains(where:{$0.sourceURL?.contains("https://example.test/harbor/history") == true && $0.classification != MemoryKind.verifiedSource.rawValue}),"source links retained without mistaking links for verification")
            let annotate = MemoryAnnotation(kind:MemoryKind.observation.rawValue,note:"Correction: the texture felt algorithmic; that is subjective, not a claim about how Alex produced it.",sourceURL:"",threadStatus:"",pinned:true,excluded:false)
            try await memory.annotate(conversation:id,node:"u3",annotation:annotate)
            let annotationHits = try await memory.search("algorithmic")
            check(annotationHits.contains(where:{$0.nodeID == "u3" && $0.annotation?.contains("subjective") == true}),"user correction annotations are searchable without editing originals")
            check(try await memory.originalConversation(id) == raw,"annotations and pins leave complete original JSON unchanged")
            let pinned = try await memory.retrieve(current:"unrelatedtopiczz")
            check(pinned.passages.contains(where:{$0.nodeID == "u3"}),"explicit pins remain available during automatic retrieval")
            do { try await memory.annotate(conversation:id,node:"a1",annotation:.init(kind:MemoryKind.verifiedSource.rawValue,note:"",sourceURL:"",threadStatus:"",pinned:false,excluded:false)); check(false,"verification requires evidence") } catch { check(true,"verification requires source URL and journalist verification note") }
            try await memory.annotate(conversation:id,node:"u4",annotation:.init(kind:MemoryKind.question.rawValue,note:"The interviewee answered this in the earlier conversation; follow the later correction.",sourceURL:"",threadStatus:"answered",pinned:false,excluded:false))
            let answered = try await memory.retrieve(current:"Cedar Workshop physical venue",rolling:"")
            check(answered.prompt.contains("answered") && answered.prompt.contains("I already asked"),"previously answered question and its corrective continuation are recalled together")
            try await memory.annotate(conversation:id,node:"u2",annotation:.init(kind:MemoryKind.correction.rawValue,note:"",sourceURL:"",threadStatus:"",pinned:false,excluded:true))
            let afterExclude = try await memory.retrieve(current:"Project Aurora")
            check(!afterExclude.prompt.contains(MemoryFixtures.correction),"excluded message cannot leak through overlapping/context/correction retrieval")
            check(try await memory.originalConversation(id) == raw,"excluded material remains losslessly inspectable until deleted")
            try await memory.annotate(conversation:id,node:"u2",annotation:.init(kind:MemoryKind.correction.rawValue,note:"",sourceURL:"",threadStatus:"",pinned:false,excluded:false))
            let duplicate = try await memory.importSelected(session,ids:[chosen.id])
            check(duplicate.skipped == 1 && duplicate.imported == 0,"reimport deduplicates exact snapshots without resetting annotations")
            check((try await memory.search("algorithmic")).first?.annotation == annotate.note,"reimport preserves user corrections")
            let longHits = try await memory.search("TapeGhostCollage")
            check(longHits.contains(where:{$0.excerpt.contains("TapeGhostCollage")}),"long-message content remains searchable beyond its opening")
            let sqlite = try MemorySQLite(url:folder.appendingPathComponent("memory.sqlite"))
            let slices = try sqlite.rows("SELECT start_offset,end_offset,text_exact FROM passages WHERE node_id='u8' ORDER BY start_offset")
            check(slices.count > 30 && slices[1]["start_offset"]!.int < slices[0]["end_offset"]!.int,"long messages have genuinely overlapping passages")
            let chars = Array(MemoryFixtures.longText)
            check(slices.allSatisfy { row in String(chars[row["start_offset"]!.int..<row["end_offset"]!.int]) == row["text_exact"]!.string },"every indexed long passage matches the exact original character range")
            _ = try await memory.search("\" OR * ; DROP TABLE nodes; --")
            check((try await memory.messages(conversation:id)).count == 19,"FTS query sanitization cannot execute SQL or corrupt memory")
            try await memory.saveDossier("Current priority: compare projects rather than assume artistic intention. Source: original conversation u2 and u3.")
            let dossier = try await memory.dossier()
            check(dossier.1 == 2 && dossier.0.contains("compare projects"),"dossier is editable, separately versioned and exact")
            check(try await memory.originalConversation(id) == raw,"dossier updates never replace or summarize original messages")
            do { try await memory.saveDossier(String(repeating:"x",count:6001)); check(false,"dossier limit") } catch { check(true,"oversized dossier rejected explicitly instead of truncating original history") }
            let answeredCandidates = answered.passages.filter { $0.threadStatus == "answered" }
            check(MemoryEvidenceRules.repeatsAnswered("What continued after Cedar Workshop stopped being a physical house venue?",evidence:answeredCandidates),"locally suppress an explicitly already-answered historical question")
            check(!MemoryEvidenceRules.repeatsAnswered("Who is organizing shows for younger artists today?",evidence:answeredCandidates),"answered-topic protection still permits a genuinely different reporting angle")
            check(!MemoryEvidenceRules.repeatsAnswered("What continued after Cedar Workshop stopped being a physical house venue, and what continues today?",evidence:answeredCandidates),"temporal updates are not suppressed merely for sharing an answered historical topic")
            let captured = MemoryPromptProbe()
            let service = EditorialService(archive:memory,inference:{ system,input in await captured.record(system:system,input:input); return try await captured.response() })
            let lines = [InterviewLine(start:10,end:15,speaker:.them,text:"Let's talk about Project Aurora and Project Beacon.")]
            let response = try await service.analyze(lines:lines,research:"Publication fixture",known:["A question already suggested"])
            let prompt = await captured.snapshot()
            check(prompt.input.contains("minimal traditional rhythm") && prompt.input.contains(MemoryFixtures.correction),"live analysis automatically retrieves original listening detail and correction without a manual search")
            check(prompt.input.contains("A question already suggested") && prompt.input.contains("compare projects"),"rolling suggestion history and active dossier accompany retrieved originals")
            check(prompt.system.contains("unverified") && prompt.system.contains("mutually exclusive branch"),"cloud instructions explicitly preserve role and branch uncertainty")
            check(!prompt.input.contains("UnselectedPrivateCanary") && !prompt.input.contains("DoNotUploadWholeArchive"),"live request contains selected relevant passages, not the full export/archive")
            check((response.suppliedEvidence ?? []).contains(where:{$0.nodeID == "u3"}),"retrieved source IDs and original passage snapshots are attached to the analysis result")
            let candidate = winter.passages.first!
            var historicalDecision = SimulationFixtures.revelationDecision
            historicalDecision.evidence_excerpt = "There was a difficult turning point behind Project Aurora."
            historicalDecision.suggested_question = "What was the turning point behind Project Aurora?"
            historicalDecision.related_topic = "Project Aurora turning point"
            let citingJSON = String(decoding:try JSONEncoder().encode(EditorialEnvelope(decision:historicalDecision,threads:[],resolved_titles:[],source_refs:[candidate.id])),as:UTF8.self)
            let citingService = EditorialService(archive:memory,inference:{ _,_ in citingJSON })
            let citingResult = try await citingService.analyze(lines:[.init(start:10,end:16,speaker:.them,text:historicalDecision.evidence_excerpt)],research:"",known:[])
            check(citingResult.decision.should_suggest && citingResult.citedEvidence?.first?.id == candidate.id,"actual live analysis path accepts an eligible decision and attaches only validated historical citations")
            let badJSON = String(decoding:try JSONEncoder().encode(EditorialEnvelope(decision:historicalDecision,threads:[],resolved_titles:[],source_refs:["MEM-invented"])),as:UTF8.self)
            let badService = EditorialService(archive:memory,inference:{ _,_ in badJSON })
            do { _ = try await badService.analyze(lines:lines,research:"",known:[]); check(false,"model invented citation") } catch { check(true,"live analysis withholds an output containing an invented source reference") }

            let noRefsJSON = String(decoding:try JSONEncoder().encode(EditorialEnvelope(decision:historicalDecision,threads:[],resolved_titles:[])),as:UTF8.self)
            let noRefsService = EditorialService(archive:memory,inference:{ _,_ in noRefsJSON })
            do { _ = try await noRefsService.analyze(lines:lines,research:"",known:[]); check(false,"missing source attribution") } catch { check(true,"new suggestions without the source attribution field are withheld") }
            check(try ResearchEvidence.validatedReferences([candidate.id],candidates:[candidate]) == [candidate],"valid source citation maps to the exact supplied passage")
            do { _ = try ResearchEvidence.validatedReferences(["MEM-invented"],candidates:[candidate]); check(false,"invented reference") } catch { check(true,"invented source references rejected") }
            var saved = SavedSuggestion(decision:SimulationFixtures.revelationDecision,evidence:[candidate],suppliedEvidence:winter.evidence)
            saved.status = "saved"
            var interview = InterviewRecord(); interview.suggestions = [saved]
            let json = try InterviewStore.export(interview,format:"json")
            let restored = try JSONDecoder().decode(InterviewRecord.self,from:json)
            check(restored.suggestions.first?.evidence == [candidate],"saved/exported suggestions preserve exact original-source evidence")
            let markdown = String(decoding:try InterviewStore.export(interview,format:"md"),as:UTF8.self)
            check(markdown.contains(candidate.id) && markdown.contains(candidate.excerpt) && markdown.contains(candidate.classification) && markdown.contains("Author: "+candidate.role),"Markdown export includes source references and verbatim evidence")
            var legacy = try JSONSerialization.jsonObject(with:json) as! [String:Any]
            var legacySuggestions = legacy["suggestions"] as! [[String:Any]]
            legacySuggestions[0].removeValue(forKey:"evidence"); legacySuggestions[0].removeValue(forKey:"suppliedEvidence"); legacy["suggestions"] = legacySuggestions
            let oldRecord = try JSONDecoder().decode(InterviewRecord.self,from:JSONSerialization.data(withJSONObject:legacy))
            check(oldRecord.suggestions.count == 1 && oldRecord.suggestions[0].evidence == nil,"existing saved interviews migrate without losing data")
            try await memory.setConversation(id,excluded:true,alternatives:false)
            check((try await memory.retrieve(current:"Project Aurora Project Beacon")).passages.isEmpty,"whole-conversation exclusion overrides pins and context")
            check(!(try await memory.search("Project Aurora",includeExcluded:true)).isEmpty,"excluded material remains available for explicit inspection")
            try await memory.setConversation(id,excluded:false,alternatives:true)
            check((try await memory.retrieve(current:"DiscardedDraftOnly")).passages.contains(where:{$0.reference.contains("ALTERNATE")}),"alternate branches require explicit enablement and retain labels")
            try await memory.deleteConversation(id)
            let deletedConversations = try await memory.conversations(); let deletedHits = try await memory.search("Project Aurora Project Beacon",includeExcluded:true)
            check(deletedConversations.isEmpty && deletedHits.isEmpty,"deletion removes conversation, nodes, relations, passages and FTS results")
            check(try sqlite.rows("SELECT count(*) AS n FROM nodes").first!["n"]!.int == 0 && sqlite.rows("SELECT count(*) AS n FROM passages_fts").first!["n"]!.int == 0,"SQLite and full-text rows are actually removed")
            // Exercise ZIP selection without importing any unrelated attachment/media files.
            try Data("not an attachment import".utf8).write(to:folder.appendingPathComponent("chat.html"))
            let zip = Process(); zip.executableURL = URL(fileURLWithPath:"/usr/bin/zip"); zip.currentDirectoryURL = folder; zip.arguments = ["-q","sample-export.zip","conversations.json","chat.html"]
            try zip.run(); zip.waitUntilExit(); guard zip.terminationStatus == 0 else { throw ProducerError.message("Fixture ZIP creation failed") }
            let zipped = try ChatGPTExportReader.open(folder.appendingPathComponent("sample-export.zip"))
            check(zipped.conversations.count == 2,"official-style ZIP previews conversations.json without manual extraction")
            let extracted = try FileManager.default.contentsOfDirectory(at:zipped.temporaryDirectory!,includingPropertiesForKeys:nil)
            check(extracted.allSatisfy {$0.pathExtension == "json"},"ZIP import extracts only conversation JSON, not media or unrelated files")
            let nested = folder.appendingPathComponent("nested"); try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:[MemoryFixtures.conversation()]).write(to:nested.appendingPathComponent("conversations-000.json"))
            let allObjects = try JSONSerialization.jsonObject(with:MemoryFixtures.export()) as! [[String:Any]]
            try JSONSerialization.data(withJSONObject:[allObjects[1]]).write(to:nested.appendingPathComponent("conversations-001.json"))
            let shardZip = Process(); shardZip.executableURL = URL(fileURLWithPath:"/usr/bin/zip"); shardZip.currentDirectoryURL = folder
            shardZip.arguments = ["-q","sharded.zip","nested/conversations-000.json","nested/conversations-001.json"]
            try shardZip.run(); shardZip.waitUntilExit()
            let sharded = try ChatGPTExportReader.open(folder.appendingPathComponent("sharded.zip"))
            check(sharded.conversations.count == 2,"numbered JSON shards in nested export ZIPs are supported")
            var parentOnly = MemoryFixtures.conversation()
            let fullGraph = try ExportGraph(root:parentOnly)
            parentOnly["mapping"] = (parentOnly["mapping"] as! [String:[String:Any]]).mapValues { node in
                var copy = node; copy.removeValue(forKey:"children"); return copy
            }
            let parentOnlyURL = folder.appendingPathComponent("parent-only.json")
            try JSONSerialization.data(withJSONObject:[parentOnly],options:[.sortedKeys]).write(to:parentOnlyURL)
            let parentSession = try ChatGPTExportReader.open(parentOnlyURL)
            check(parentSession.conversations[0].branchCount == 2,"parent-only official export preview counts actual branch paths rather than every node")
            let parentGraph = try ExportGraph(root:parentOnly)
            check(parentGraph.activeNodes == fullGraph.activeNodes && parentGraph.paths.count == fullGraph.paths.count,"parent-only export preserves active and alternate paths")
            check(parentGraph.warnings.isEmpty,"omitted children fields are valid export structure, not a mismatch warning")
            let parentMemory = ConversationMemory(url:folder.appendingPathComponent("parent-only.sqlite"))
            let parentResult = try await parentMemory.importSelected(parentSession,ids:[parentSession.conversations[0].id])
            let parentID = try await parentMemory.conversations()[0].id
            let parentStoredOriginal = try await parentMemory.originalConversation(parentID)
            let parentExportOriginal = try ChatGPTExportReader.raw(parentSession.conversations[0])
            check(parentResult.imported == 1 && parentStoredOriginal == parentExportOriginal,"parent-only original remains byte-for-byte lossless in SQLite")
            let parentMessages = try await parentMemory.messages(conversation:parentID,branch:"u9")
            check(parentMessages.map(\.nodeID) == active.map(\.nodeID),"parent-only messages retain conversational order despite unordered mapping keys")
            _ = try await memory.importSelected(session,ids:[chosen.id])
            var revised = MemoryFixtures.conversation(); revised["title"] = "Revised snapshot of the same original conversation"
            let revisionURL = folder.appendingPathComponent("revision.json")
            try JSONSerialization.data(withJSONObject:[revised],options:[.sortedKeys]).write(to:revisionURL)
            let revisions = try ChatGPTExportReader.open(revisionURL)
            _ = try await memory.importSelected(revisions,ids:Set(revisions.conversations.map(\.id)))
            let snapshots = try await memory.conversations()
            check(snapshots.count == 2 && Set(snapshots.map(\.originalID)).count == 1,"changed export appends a lossless revision instead of overwriting history")
            check(try await memory.originalConversation(id) == raw,"older original bytes survive importing a changed snapshot")
            var cyclic = MemoryFixtures.conversation(); var cyclicNodes = cyclic["mapping"] as! [String:Any]
            var cyclicNode = cyclicNodes["u1"] as! [String:Any]; cyclicNode["parent"] = "u9"; cyclicNodes["u1"] = cyclicNode; cyclic["mapping"] = cyclicNodes
            let cyclicURL = folder.appendingPathComponent("cyclic.json")
            try JSONSerialization.data(withJSONObject:[cyclic],options:[.sortedKeys]).write(to:cyclicURL)
            let cyclicSession = try ChatGPTExportReader.open(cyclicURL)
            let cyclicMemory = ConversationMemory(url:folder.appendingPathComponent("cyclic.sqlite"))
            let cyclicResult = try await cyclicMemory.importSelected(cyclicSession,ids:Set(cyclicSession.conversations.map(\.id)))
            let cyclicConversations = try await cyclicMemory.conversations()
            let preservedCycle = try await cyclicMemory.originalConversation(cyclicConversations[0].id)
            let expectedCycle = try ChatGPTExportReader.raw(cyclicSession.conversations[0])
            check(!cyclicResult.warnings.isEmpty && preservedCycle == expectedCycle,"damaged branch graphs retain original bytes and report a warning")
            check((try await cyclicMemory.retrieve(current:"Project Aurora")).passages.isEmpty,"unresolved cyclic branches do not silently become current interview evidence")
            let broken = folder.appendingPathComponent("broken.json"); try Data("[{\"mapping\":{}}".utf8).write(to:broken)
            do { _ = try ChatGPTExportReader.open(broken); check(false,"truncated input") } catch { check(true,"truncated exports rejected without silent loss") }
            let changed = folder.appendingPathComponent("changed.json"); try MemoryFixtures.export().write(to:changed)
            let changedSession = try ChatGPTExportReader.open(changed); try Data("[]".utf8).write(to:changed)
            do { _ = try ChatGPTExportReader.raw(changedSession.conversations[0]); check(false,"changed preview input") } catch { check(true,"changed file rejected between preview and import") }
        } catch { check(false,"unexpected integration error: \(error.localizedDescription)") }
        print("\n\(total-failures.count)/\(total) conversation-memory checks passed. All fixtures are synthetic, all inference is injected locally; no private export, cloud account, Zoom or microphone was used.")
        return failures.isEmpty ? 0 : 1
    }
}
actor MemoryPromptProbe {
    private var system = ""; private var input = ""
    func record(system: String,input: String) { self.system = system; self.input = input }
    func snapshot() -> (system:String,input:String) { (system,input) }
    func response() throws -> String {
        let decision = EditorialDecision(should_suggest:false,confidence:0,priority:"medium",suggested_question:"",reason:"",evidence_excerpt:"",related_topic:"",timestamp:0)
        let envelope = EditorialEnvelope(decision:decision,threads:[],resolved_titles:[],source_refs:[])
        return String(decoding:try JSONEncoder().encode(envelope),as:UTF8.self)
    }
}
