import Foundation

actor StoryEngine {
    private let memory: ConversationMemory
    private let inference: @Sendable (String,String) async throws -> String
    init(memory: ConversationMemory = .shared,inference: @escaping @Sendable (String,String) async throws -> String = {
        try await ProducerInference.complete(instructions:$0,input:$1)
    }) { self.memory = memory; self.inference = inference }

    static func context(_ directions: [StoryDirection]) -> String {
        // Derived state is a navigation aid, never an independent source for its own claims.
        "DERIVED INVESTIGATIONS — provisional, not original evidence.\n" + directions.filter { !$0.parked }.prefix(12).map { d in
            let updates = d.updates.suffix(2)
            return "\(d.id): \(d.title)\nJournalist note: \(d.note.prefix(600))\n" + updates.map { u in
                "Stage: \(u.stage). Question: \(u.lead.question). Checks: \(u.lead.unverified.joined(separator:"; "))\n" +
                (u.support+u.opposition).prefix(4).map { "Prior receipt [\($0.evidence.id)] \($0.evidence.role) (re-retrieve original before relying on its claim)" }.joined(separator:"\n")
            }.joined(separator:"\n")
        }.joined(separator:"\n\n")
    }

    func prepare(query: String,records: [InterviewRecord],publications: [ResearchEvidence],currentID: UUID? = nil) async throws -> StoryPreparedContext {
        let archive = try await memory.retrieve(current:query,rolling:"")
        let previous = records.filter { $0.id != currentID && !$0.simulation && $0.includeInStory != false }
        // At least one matching passage per source, then fill remaining slots. Do not let a prolific source erase others.
        let perRecord = previous.map { StoryEvidence.rank(StoryEvidence.passages([$0]),query:query,limit:3) }
        var prior = perRecord.compactMap(\.first)
        prior = StoryEvidence.rank(prior,query:query,limit:8)
        let seen = Set(prior.map(\.id))
        prior += StoryEvidence.rank(perRecord.flatMap { $0 }.filter { !seen.contains($0.id) },query:query,limit:max(0,12-prior.count))
        let evidence = Self.unique(publications + archive.evidence + prior + EditorialProfile.registryEvidence)
        return .init(evidence:evidence,scope:"Relevant excerpts from \(prior.compactMap(\.conversationID).uniqued().count) of \(previous.count) other eligible interviews; local lexical selection, not an exhaustive comparison. Memory is verbatim but not independently verified. Coverage descriptions are unverified unless actual sources substantiate them.")
    }
    static func unique(_ evidence: [ResearchEvidence]) -> [ResearchEvidence] {
        var seen = Set<String>(); return evidence.filter { seen.insert($0.id).inserted }
    }
    func brief(source: String,background: String,directions: [StoryDirection],context: StoryPreparedContext) async throws -> StoryBrief {
        let name = source.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, background.count <= 4000 else { throw ProducerError.message("Provide a source name (up to 200 characters) and a short background (up to 4,000).") }
        let output = try await inference(StoryPrompts.safety+"\n"+EditorialProfile.mission+"\n"+StoryPrompts.brief,
                                         "SOURCE: \(name)\nJOURNALIST-SUPPLIED BACKGROUND: \(background)\n"+Self.context(directions)+"\n"+context.prompt)
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(StoryBriefContent.self,from:Data(output.utf8))
        guard result.questions.count == 10, result.questions.allSatisfy({(10...350).contains($0.count)}),
              Set(result.questions.map { $0.lowercased() }).count == 10,
              result.essential_indices.count == 3, Set(result.essential_indices).count == 3,
              result.essential_indices.allSatisfy({(1...10).contains($0)}), result.positioning.count <= 3000,
              result.established.count <= 12, result.sensitive.count <= 12 else { throw ProducerError.message("The model did not return ten distinct questions and three valid essentials. The incomplete brief was not saved.") }
        for p in result.established + result.sensitive { try StoryEvidence.validateIDs(p.refs,evidence:context.evidence) }
        return StoryBrief(source:name,background:background,content:result,evidence:context.evidence)
    }
    func review(record: InterviewRecord,directions: [StoryDirection],context: StoryPreparedContext) async throws -> [StoryUpdate] {
        let selected = try await selectedTranscript(record)
        let candidates = Self.unique(selected.evidence+context.evidence)
        let output = try await inference(StoryPrompts.safety+"\n"+EditorialProfile.forInterview(record)+"\n"+StoryPrompts.review,
                                        Self.context(directions)+"\n"+context.prompt+"\nCURRENT INTERVIEW: \(StoryEvidence.source(record))\n\(selected.scope)\n"+selected.evidence.map(\.prompt).joined(separator:"\n\n"))
        try Task.checkCancellation()
        struct Response: Decodable { var directions: [StoryLead] }
        let response = try JSONDecoder().decode(Response.self,from:Data(output.utf8))
        guard response.directions.count <= 4 else { throw ProducerError.message("Too many proposed directions.") }
        return try response.directions.map { try StoryEvidence.validate($0,evidence:candidates,label:"Review of \(StoryEvidence.source(record))") }
    }
    func report(record: InterviewRecord,directions: [StoryDirection],context: StoryPreparedContext) async throws -> SavedStoryReport {
        let selected = try await selectedTranscript(record)
        let candidates = Self.unique(selected.evidence+context.evidence)
        let prompt = Self.context(directions)+"\n"+context.prompt+"\nCURRENT INTERVIEW ID: \(record.id)\nSOURCE: \(StoryEvidence.source(record))\n"+selected.scope+"\n"+selected.evidence.map(\.prompt).joined(separator:"\n\n")
        guard prompt.count <= 90000 else { throw ProducerError.message("The selected report evidence exceeds the bounded request size. Split the interview into labeled parts; no partial report was saved.") }
        let output = try await inference(StoryPrompts.safety+"\n"+EditorialProfile.forInterview(record)+"\n"+StoryPrompts.report,prompt)
        try Task.checkCancellation()
        var result = try JSONDecoder().decode(StoryReport.self,from:Data(output.utf8))
        try Self.validateReport(&result,evidence:candidates,currentID:record.id)
        return SavedStoryReport(content:result,evidence:candidates,scope:selected.scope+"\n"+context.scope,interviewFingerprint:StoryEvidence.fingerprint(record))
    }

    private func selectedTranscript(_ record: InterviewRecord) async throws -> StoryPreparedContext {
        let passages = StoryEvidence.passages([record])
        guard !passages.isEmpty else { throw ProducerError.message("This interview has no transcript to analyze.") }
        var packets = [[ResearchEvidence]](); var packet = [ResearchEvidence](); var size = 0
        for passage in passages {
            let count = passage.prompt.count
            if size+count > 14000, !packet.isEmpty { packets.append(packet); packet = []; size = 0 }
            packet.append(passage); size += count
        }
        if !packet.isEmpty { packets.append(packet) }
        if packets.count <= 2, passages.map(\.prompt).joined().count <= 25000 {
            return .init(evidence:passages,scope:"Full current transcript supplied as original attributed passages, including overlapping slices of long turns.")
        }
        guard packets.count <= 20 else { throw ProducerError.message("This interview needs more than 20 bounded evidence packets. Split it into labeled parts before deep analysis; no portion was silently skipped.") }
        var selected = [ResearchEvidence]()
        for (i,part) in packets.enumerated() {
            try Task.checkCancellation()
            let output = try await inference(StoryPrompts.safety+"\n"+StoryPrompts.extract,
                "Interview \(record.id) source \(StoryEvidence.source(record)). Chronological packet \(i+1) of \(packets.count).\n"+part.map(\.prompt).joined(separator:"\n\n"))
            struct Extract: Decodable { var citations: [StoryCitation] }
            let extraction = try JSONDecoder().decode(Extract.self,from:Data(output.utf8))
            guard extraction.citations.count <= 8 else { throw ProducerError.message("Evidence selection returned too many passages.") }
            let receipts = try StoryEvidence.resolve(extraction.citations,in:part)
            for receipt in receipts {
                var e = receipt.evidence
                // Exact selected substring; keep original stable ID and source location. No AI summary replaces testimony.
                let relative = e.excerpt.range(of:receipt.quote).map { e.excerpt.distance(from:e.excerpt.startIndex,to:$0.lowerBound) } ?? 0
                e.startOffset = (e.startOffset ?? 0)+relative; e.endOffset = (e.startOffset ?? 0)+receipt.quote.count
                e.id += "-"+String(MemoryIdentity.digest(receipt.quote).prefix(8)); e.excerpt = receipt.quote
                selected.append(e)
            }
        }
        guard !selected.isEmpty else { throw ProducerError.message("No reportable evidence was selected. The full transcript remains intact; review it manually.") }
        return .init(evidence:Self.unique(selected),scope:"Every one of \(packets.count) chronological transcript packets was considered; \(selected.count) exact excerpts selected by the model. Final analysis sees this selection, not the entire interview. Check omissions against the saved full transcript. Maximum \(packets.count+1) inference requests for this job.")
    }
    static func validateReport(_ report: inout StoryReport,evidence: [ResearchEvidence],currentID: UUID) throws {
        guard report.directions.count <= 3, report.discoveries.count <= 10, report.originality_audit.count <= 20,
              report.next_sources.count <= 15, report.materials.count <= 20, report.contradictions.count <= 12,
              ["not ready","promising; more reporting needed","ready for journalist review"].contains(report.pitch.assessment),
              (6...10).contains(report.pitch.criteria.count) else { throw ProducerError.message("Incomplete or oversized post-interview report.") }
        for point in report.discoveries {
            let receipts = try StoryEvidence.resolve(point.citations,in:evidence)
            guard receipts.contains(where: { $0.evidence.origin == "interview" && $0.evidence.conversationID == currentID.uuidString }) else { throw ProducerError.message("A claimed interview discovery has no original current-interview receipt.") }
        }
        for lead in report.directions { _ = try StoryEvidence.validate(lead,evidence:evidence,label:"Post-interview") }
        for item in report.originality_audit {
            guard ["already extensively covered","partially covered","potentially new","not researched enough"].contains(item.category), !item.refs.isEmpty else { throw ProducerError.message("Originality audit needs labeled evidence and coverage uncertainty.") }
            try StoryEvidence.validateIDs(item.refs,evidence:evidence)
        }
        for i in report.originality_audit.indices {
            let audit = report.originality_audit[i]
            let referenced = evidence.filter { audit.refs.contains($0.id) }
            if referenced.allSatisfy({$0.origin == "coverage_register"}) {
                report.originality_audit[i].explanation += " [Coverage description only; actual publication contents remain unverified in this analysis.]"
            }
            if audit.category == "potentially new" { report.originality_audit[i].explanation += " [Provisional novelty within supplied material; an incomplete archive cannot establish originality.]" }
        }
        guard !report.originality_audit.isEmpty else { throw ProducerError.message("The report omitted its originality audit.") }
        for source in report.next_sources { try StoryEvidence.validateNext(source,evidence:evidence) }
        for material in report.materials {
            guard !(try StoryEvidence.resolve(material.citations,in:evidence)).isEmpty else { throw ProducerError.message("A proposed recording or archive has no original receipt.") }
        }
        for i in report.contradictions.indices {
            let c = report.contradictions[i]
            let sides = try StoryEvidence.resolve(c.sides,in:evidence)
            guard ["possible inconsistency","difference of interpretation","verified inconsistency"].contains(c.kind),
                  Set(sides.map(\.id)).count >= 2 else { throw ProducerError.message("A contradiction needs two distinct original statements.") }
            guard sides.allSatisfy({!$0.evidence.role.lowercased().contains("assistant")}) else { throw ProducerError.message("Assistant speculation cannot establish contradictory testimony.") }
            if c.kind == "verified inconsistency", !sides.allSatisfy({StoryEvidence.verifiedPrimary($0.evidence)}) {
                report.contradictions[i].kind = "possible inconsistency"
                report.contradictions[i].explanation += " [Locally downgraded: both sides lack journalist-confirmed primary evidence.]"
            }
        }
        for criterion in report.pitch.criteria { try StoryEvidence.validateIDs(criterion.refs,evidence:evidence) }
        let interviewees = Set(evidence.filter { $0.origin == "interview" && $0.role.hasPrefix("Interviewee:") }.map(\.role))
        if report.pitch.assessment == "ready for journalist review", interviewees.count < 2 || report.originality_audit.contains(where:{$0.category == "not researched enough"}) || !report.pitch.gaps.isEmpty {
            report.pitch.assessment = "promising; more reporting needed"
            report.pitch.gaps.append("Local readiness check: multiple perspectives, researched novelty and resolved reporting gaps require journalist review.")
        }
    }
}
private extension Array where Element: Hashable { func uniqued() -> [Element] { Array(Set(self)) } }
