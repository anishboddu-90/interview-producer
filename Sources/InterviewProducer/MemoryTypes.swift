import Foundation
import CryptoKit

enum MemoryKind: String, Codable, CaseIterable {
    case discussion = "User discussion — unverified"
    case observation = "User listening observation — subjective"
    case correction = "User correction / disagreement"
    case interpretation = "Assistant interpretation — unverified"
    case sourceClaim = "Source mentioned — not verified"
    case verifiedSource = "Source verified by journalist"
    case plan = "Reporting plan"
    case question = "Unresolved question"
    static func inferred(role: String,text: String) -> Self {
        // Role takes precedence: an assistant's assertive wording never establishes verification.
        guard role == "user" else { return .interpretation }
        let t = text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        if ["no,","no.","correction","actually","i meant","i disagree","to be clear","that's not","that’s not","i was wrong"].contains(where:t.hasPrefix) { return .correction }
        if ["listening","i hear","i heard","sounds like","i noticed","my impression"].contains(where:t.contains) { return .observation }
        if t.contains("https://") || t.contains("http://") { return .sourceClaim }
        if ["reporting plan","interview plan","i plan to","i want to ask"].contains(where:t.contains) { return .plan }
        if t.hasSuffix("?") { return .question }
        return .discussion
    }
}
struct MemoryConversation: Identifiable, Sendable {
    var id: String; var originalID: String; var title: String; var created: Double?
    var messages: Int; var branches: Int; var excluded: Bool; var includeAlternatives: Bool
}
struct MemoryMessage: Identifiable, Sendable {
    var id: String { nodeID }
    var conversationID: String; var nodeID: String; var role: String; var text: String
    var created: Double?; var active: Bool; var hidden: Bool; var kind: String
    var note: String; var sourceURL: String; var threadStatus: String
    var pinned: Bool; var excluded: Bool; var parentID: String?; var originalJSON: String
}
struct MemoryAnnotation: Sendable {
    var kind: String; var note: String; var sourceURL: String; var threadStatus: String
    var pinned: Bool; var excluded: Bool
}
struct ResearchEvidence: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var origin: String // conversation, publication, dossier
    var title: String
    var reference: String
    var role: String
    var classification: String
    var excerpt: String // exact original substring, not a model summary
    var context: String // role-labeled surrounding turns; originals remain separately stored
    var conversationID: String? = nil
    var nodeID: String? = nil
    var branchID: String? = nil
    var created: Double? = nil
    var annotation: String? = nil
    var sourceURL: String? = nil
    var threadStatus: String? = nil
    var startOffset: Int? = nil
    var endOffset: Int? = nil
    var prompt: String {
        """
        [\(id)] \(origin.uppercased()) | \(title)
        Reference: \(reference)
        Author: \(role) | Classification: \(classification) | Original timestamp: \(created.map(String.init(describing:)) ?? "not supplied")
        Thread status (journalist annotation): \(threadStatus ?? "unspecified")
        User annotation/correction (separate from original): \(annotation ?? "none")
        Source URL (a URL alone is not verification): \(sourceURL ?? "none")
        VERBATIM EXCERPT (characters \(startOffset ?? 0)..<\(endOffset ?? excerpt.count)):
        \(excerpt)
        SURROUNDING ORIGINAL TURNS / LINKED CORRECTIONS:
        \(context)
        """
    }
    static func validatedReferences(_ ids: [String],candidates: [Self]) throws -> [Self] {
        let lookup = Dictionary(candidates.map { ($0.id,$0) },uniquingKeysWith: { first,_ in first })
        guard ids.count <= 12, ids.allSatisfy({lookup[$0] != nil}) else { throw ProducerError.message("The model cited an unknown research/memory reference. The suggestion was withheld.") }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap { lookup[$0] }
    }
}
struct ConversationMemoryContext: Sendable {
    var passages: [ResearchEvidence] = []
    var dossier: ResearchEvidence? = nil
    var evidence: [ResearchEvidence] { (dossier.map { [$0] } ?? []) + passages }
    var prompt: String { evidence.map(\.prompt).joined(separator:"\n\n") }
}
enum MemoryIdentity {
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
}

enum MemoryEvidenceRules {
    static func repeatsAnswered(_ question: String,evidence: [ResearchEvidence]) -> Bool {
        evidence.contains { source in
            let original = EditorialState.key(source.excerpt), proposed = EditorialState.key(question)
            guard source.threadStatus == "answered", original.count >= 3 else { return false }
            // Require near identity, not merely a shared topic: "today" can make a historical question new.
            return Double(original.intersection(proposed).count)/Double(max(1,original.union(proposed).count)) >= 0.95
        }
    }
}
