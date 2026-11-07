import Foundation

struct StoryCitation: Codable, Equatable, Sendable {
    var ref: String; var quote: String
}
struct StoryNextSource: Codable, Equatable, Sendable {
    var name: String; var contribution: String; var basis: [String]
}
/// Model proposal only. Validated receipts are resolved separately and originals never rewritten.
struct StoryLead: Codable, Equatable, Sendable {
    var lane: String // music, networks, history, or unexpected:<short label>
    var question: String
    var why: String
    var stage: String // quote, lead, finding, thesis (all provisional until reviewed)
    var provisional_thesis: String
    var supporting: [StoryCitation]
    var contradicting: [StoryCitation]
    var coverage_refs: [String]
    var originality: String
    var unverified: [String]
    var next_sources: [StoryNextSource]
    var wider_significance: String
}
struct StoryReceipt: Codable, Equatable, Identifiable, Sendable {
    var id: String { evidence.id + "|" + quote }
    var quote: String; var evidence: ResearchEvidence
    var prompt: String { "[\(evidence.id)] \(evidence.title) | \(evidence.role) | \(evidence.classification) | \(evidence.reference)\nExact excerpt: \(quote)" }
}
struct StoryUpdate: Codable, Identifiable, Sendable {
    var id = UUID(); var date = Date(); var lead: StoryLead; var stage: String
    var support: [StoryReceipt]; var opposition: [StoryReceipt]
    var contextLabel: String
}
struct StoryDirection: Codable, Identifiable, Sendable {
    var id: String; var title: String; var note = ""; var parked = false; var updates: [StoryUpdate] = []
    static var initial: [Self] { [
        .init(id:"subject",title:"What is changing, and what evidence explains it?"),
        .init(id:"networks",title:"Which relationships and mechanisms matter?"),
        .init(id:"history",title:"Whose contributions or interpretations are missing from the established history?")
    ] }
}
struct StoryBrief: Codable, Identifiable, Sendable {
    var id = UUID(); var date = Date(); var source: String; var background: String
    var content: StoryBriefContent
    var evidence: [ResearchEvidence] = []
    var markdown: String {
        var sections = ["# Pre-interview brief — \(source)", content.positioning]
        sections.append("## Previous reporting\n" + content.established.map(\.markdown).joined(separator:"\n"))
        sections.append("## Open questions\n" + content.open_questions.map { "- \($0)" }.joined(separator:"\n"))
        sections.append("## Hypotheses to test\n" + content.hypotheses.map { "- \($0)" }.joined(separator:"\n"))
        let questions = content.questions.enumerated().map { "\($0.offset+1). \($0.element)" }.joined(separator:"\n")
        sections.append("## Ten questions\n" + questions)
        let essentials = content.essential_indices.filter { (1...content.questions.count).contains($0) }.map { "- \(content.questions[$0-1])" }.joined(separator:"\n")
        sections.append("## Three essentials\n" + essentials)
        sections.append("## Sensitive or disputed claims — neutral questioning\n" + content.sensitive.map(\.markdown).joined(separator:"\n"))
        return sections.joined(separator:"\n\n")
    }
}
struct StoryBriefContent: Codable, Sendable {
    var positioning: String; var established: [StoryBriefPoint]; var open_questions: [String]
    var hypotheses: [String]; var questions: [String]; var essential_indices: [Int]; var sensitive: [StoryBriefPoint]
}
struct StoryBriefPoint: Codable, Sendable {
    var text: String; var refs: [String]
    var markdown: String { "- \(text) \(refs.map { "[\($0)]" }.joined(separator:" "))" }
}
struct StoryReportPoint: Codable, Sendable {
    var text: String; var citations: [StoryCitation]
}
struct StoryAudit: Codable, Sendable {
    var theme: String; var category: String; var explanation: String; var refs: [String]
}
struct StoryContradiction: Codable, Sendable {
    var kind: String; var explanation: String; var sides: [StoryCitation]
}
struct StoryMaterial: Codable, Sendable {
    var name: String; var why: String; var citations: [StoryCitation]
}
struct StoryPitch: Codable, Sendable {
    var assessment: String; var criteria: [StoryBriefPoint]; var gaps: [String]; var outlet_fit: String
}
struct StoryReport: Codable, Sendable {
    var discoveries: [StoryReportPoint]
    var directions: [StoryLead]
    var originality_audit: [StoryAudit]
    var next_sources: [StoryNextSource]
    var materials: [StoryMaterial]
    var contradictions: [StoryContradiction]
    var pitch: StoryPitch
}
struct SavedStoryReport: Codable, Sendable {
    var date = Date(); var content: StoryReport; var evidence: [ResearchEvidence]; var scope: String
    var interviewFingerprint: String
}
struct StoryLedger: Codable, Sendable {
    var version = 1; var directions = StoryDirection.initial
    var briefs: [StoryBrief] = []
    var interviewVersions: [String:String] = [:]
}
struct StoryPreparedContext: Sendable {
    var evidence: [ResearchEvidence]; var scope: String
    var prompt: String { "SCOPE: \(scope)\n" + evidence.map(\.prompt).joined(separator:"\n\n") }
}
enum StoryEvidence {
    static func source(_ r: InterviewRecord) -> String {
        let supplied = (r.sourceName ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return supplied.isEmpty ? "Unidentified interviewee — \(r.title)" : supplied
    }
    static func passage(_ line: InterviewLine,record: InterviewRecord,text: String? = nil,offset: Int = 0) -> ResearchEvidence {
        let excerpt = text ?? line.text
        let fingerprint = MemoryIdentity.digest(line.text+"|\(line.start)|\(line.end)|\(line.speaker.rawValue)|"+source(record)+"|\(record.date.timeIntervalSince1970)")
        return .init(id:"INT-"+String(MemoryIdentity.digest(record.id.uuidString+line.id.uuidString+fingerprint+"|\(offset)").prefix(24)),origin:"interview",
                     title:"\(source(record)) — \(record.date.formatted(date:.abbreviated,time:.shortened))",
                     reference:"Interview \(record.id), line \(line.id), [\(line.stamp)]–[\(Int(line.end)/60):\(String(format:"%02d",Int(line.end)%60))], source \(source(record)); \(record.isSynthetic ? "SYNTHETIC SIMULATION" : "attributed transcript; verify against audio")",
                     role:line.speaker == .them ? "Interviewee: \(source(record))" : "Journalist interviewing \(source(record))",
                     classification:record.isSynthetic ? "Synthetic fixture — not reporting" : "Attributed interview testimony — not independently verified",
                     excerpt:excerpt,context:"",conversationID:record.id.uuidString,nodeID:line.id.uuidString,created:record.date.timeIntervalSince1970,startOffset:offset,endOffset:offset+excerpt.count)
    }
    static func passages(_ records: [InterviewRecord]) -> [ResearchEvidence] {
        records.flatMap { r in r.lines.sorted { $0.start < $1.start }.flatMap { line -> [ResearchEvidence] in
            let chars = Array(line.text)
            return stride(from:0,to:chars.count,by:1400).map { offset in
                passage(line,record:r,text:String(chars[offset..<min(offset+1600,chars.count)]),offset:offset)
            }
        } }
    }
    static func rank(_ evidence: [ResearchEvidence],query: String,limit: Int) -> [ResearchEvidence] {
        let tokens = EditorialState.key(query)
        return evidence.enumerated().sorted { a,b in
            let x = tokens.intersection(EditorialState.key(a.element.excerpt)).count
            let y = tokens.intersection(EditorialState.key(b.element.excerpt)).count
            return x == y ? a.offset < b.offset : x > y
        }.prefix(limit).map { $0.element }
    }
    static func resolve(_ citations: [StoryCitation],in evidence: [ResearchEvidence]) throws -> [StoryReceipt] {
        let sources = Dictionary(evidence.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        guard citations.count <= 24 else { throw ProducerError.message("Too many editorial citations.") }
        return try citations.map { c in
            guard let e = sources[c.ref], (4...1600).contains(c.quote.count), e.excerpt.contains(c.quote) else {
                throw ProducerError.message("Editorial output cited an unknown source or changed an original quote. No investigation update was saved.")
            }
            return StoryReceipt(quote:c.quote,evidence:e)
        }
    }
    static func lane(_ value: String) throws -> String {
        if ["subject","music","networks","history"].contains(value) { return value }
        guard value.hasPrefix("unexpected:"), value.count > 11, value.count <= 100 else { throw ProducerError.message("Invalid investigation category.") }
        return value
    }
    static func validate(_ lead: StoryLead,evidence: [ResearchEvidence],label: String) throws -> StoryUpdate {
        _ = try lane(lead.lane)
        guard (8...300).contains(lead.question.count), lead.why.count <= 1800, lead.provisional_thesis.count <= 1800,
              lead.originality.count <= 2400, lead.wider_significance.count <= 1800,
              lead.unverified.count <= 15, lead.unverified.allSatisfy({$0.count <= 700}), lead.next_sources.count <= 10,
              ["quote","lead","finding","thesis"].contains(lead.stage) else { throw ProducerError.message("Invalid or oversized investigation proposal.") }
        let support = try resolve(lead.supporting,in:evidence), opposition = try resolve(lead.contradicting,in:evidence)
        guard !support.isEmpty, support.contains(where: { !["coverage_register","dossier"].contains($0.evidence.origin) }) else { throw ProducerError.message("A story lead needs original evidence, not just a project brief.") }
        try validateIDs(lead.coverage_refs,evidence:evidence)
        guard lead.coverage_refs.allSatisfy({ id in evidence.contains { $0.id == id && ["coverage_register","publication"].contains($0.origin) } }) else {
            throw ProducerError.message("Coverage comparisons must cite supplied publications or explicitly unverified coverage references.")
        }
        for next in lead.next_sources { try validateNext(next,evidence:evidence) }
        let independent = Set(support.filter { verifiedPrimary($0.evidence) }.map { $0.evidence.conversationID ?? $0.evidence.title })
        let stage: String
        switch lead.stage {
        case "quote": stage = "Interesting quote — significance unverified"
        case "finding" where independent.count >= 2: stage = "Evidence-supported finding — journalist review required"
        case "thesis": stage = "Provisional article thesis — not established fact"
        default: stage = "Promising reporting lead — hypothesis, not a finding"
        }
        return .init(lead:lead,stage:stage,support:support,opposition:opposition,contextLabel:label)
    }
    static func verifiedPrimary(_ e: ResearchEvidence) -> Bool {
        e.origin == "publication" && e.classification == "Confirmed primary-source evidence — journalist attested" &&
        !(e.annotation ?? "").isEmpty && !(e.sourceURL ?? "").isEmpty
    }
    static func validateIDs(_ ids: [String],evidence: [ResearchEvidence]) throws {
        let available = Set(evidence.map(\.id))
        guard ids.count <= 30, ids.allSatisfy({available.contains($0)}) else { throw ProducerError.message("Editorial output cited an unavailable source.") }
    }
    static func validateNext(_ next: StoryNextSource,evidence: [ResearchEvidence]) throws {
        guard !next.name.isEmpty, next.name.count <= 200, (8...1000).contains(next.contribution.count), !next.basis.isEmpty else { throw ProducerError.message("A proposed source needs a specific contribution and evidence basis.") }
        try validateIDs(next.basis,evidence:evidence)
    }
    static func fingerprint(_ r: InterviewRecord) -> String {
        MemoryIdentity.digest(source(r)+(r.sourceBackground ?? "")+r.lines.map { "\($0.id)|\($0.start)|\($0.end)|\($0.speaker.rawValue)|\($0.text)" }.joined(separator:"\n"))
    }
}
