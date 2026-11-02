import Foundation

enum QuestionStatus: String, Codable, CaseIterable, Sendable {
    case available, suggested, asked, answered, skipped
}
struct LifelineStatusReceipt: Codable, Equatable, Sendable {
    var date = Date(); var status: QuestionStatus; var explanation: String
    var evidence: [StoryReceipt]; var questionFingerprint: String
}
struct LifelineQuestion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var text: String
    var category = "General"
    var priority = 3 // 1..5; 5 highest
    var transition: String? = nil
    var researchContext: String? = nil
    var status: QuestionStatus = .available
    var essential = false
    var notes: String? = nil
    var manualStatus = false
    var savedForLater = false
    var lastSuggested: Date? = nil
    var statusHistory: [LifelineStatusReceipt] = []
    var fingerprint: String { MemoryIdentity.digest(text) }
    var eligible: Bool { text.trimmingCharacters(in:.whitespacesAndNewlines).count >= 4 && (status == .available || status == .suggested) }
}
extension LifelineQuestion {
    private enum CodingKeys: String, CodingKey { case id,text,category,priority,transition,researchContext,status,essential,notes,manualStatus,savedForLater,lastSuggested,statusHistory }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decodeIfPresent(String.self,forKey:.id) ?? UUID().uuidString
        text = try c.decode(String.self,forKey:.text)
        category = try c.decodeIfPresent(String.self,forKey:.category) ?? "General"
        priority = try c.decodeIfPresent(Int.self,forKey:.priority) ?? 3
        transition = try c.decodeIfPresent(String.self,forKey:.transition)
        researchContext = try c.decodeIfPresent(String.self,forKey:.researchContext)
        status = try c.decodeIfPresent(QuestionStatus.self,forKey:.status) ?? .available
        essential = try c.decodeIfPresent(Bool.self,forKey:.essential) ?? false
        notes = try c.decodeIfPresent(String.self,forKey:.notes)
        manualStatus = try c.decodeIfPresent(Bool.self,forKey:.manualStatus) ?? false
        savedForLater = try c.decodeIfPresent(Bool.self,forKey:.savedForLater) ?? false
        lastSuggested = try c.decodeIfPresent(Date.self,forKey:.lastSuggested)
        statusHistory = try c.decodeIfPresent([LifelineStatusReceipt].self,forKey:.statusHistory) ?? []
    }
}
struct LifelineSettings: Codable, Equatable, Sendable {
    var automatic = false
    var silenceSeconds = 8
    var cooldownSeconds = 75
    var sensitivity = "Conservative"
    var remainingMinutes: Int? = nil
}
struct QuestionProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var source = ""
    var questions: [LifelineQuestion] = []
    var settings = LifelineSettings()
    var revision = 0
    var matchesSource: (String) -> Bool { { source.isEmpty || source.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() } }
}
extension QuestionProfile {
    private enum CodingKeys: String, CodingKey { case id,name,source,questions,settings,revision }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decodeIfPresent(String.self,forKey:.id) ?? UUID().uuidString
        name = try c.decode(String.self,forKey:.name)
        source = try c.decodeIfPresent(String.self,forKey:.source) ?? ""
        questions = try c.decode([LifelineQuestion].self,forKey:.questions)
        settings = try c.decodeIfPresent(LifelineSettings.self,forKey:.settings) ?? .init()
        revision = try c.decodeIfPresent(Int.self,forKey:.revision) ?? 0
    }
}
struct LifelineLibraryState: Codable, Sendable {
    var version = 1
    var profiles: [QuestionProfile] = []
    var selectedProfileID: String? = nil
    var shortcutKey = "Q"
    var shortcutModifiers = "Control+Option"
    var shortcutEnabled = true
}
struct LifelineAnswerUpdate: Codable, Sendable {
    var question_id: String
    var confidence: Double
    var explanation: String
    var citations: [StoryCitation]
}
struct LifelineReview: Codable, Sendable {
    var next_question_id: String?
    var bridge: String
    var reason: String
    var confidence: Double
    var answer_complete: Bool
    var thinking_pause: Bool
    var pending_followup: Bool
    var anchor_ref: String?
    var answers: [LifelineAnswerUpdate]
    var source_refs: [String]
}
struct SavedLifeline: Codable, Identifiable, Sendable {
    var id = UUID(); var date = Date()
    var profileID: String; var question: LifelineQuestion
    var bridge: String; var reason: String; var mode: String
    var evidence: [ResearchEvidence]
    var status = "suggested"
    var transcriptAnchor: String? = nil
}
struct LifelineCache: Sendable {
    var review: LifelineReview; var evidence: [ResearchEvidence]
    var profileID: String; var revision: Int; var recordID: UUID; var anchor: String
    var date = Date()
}

enum LifelineRanking {
    static func wasAsked(_ q: LifelineQuestion,lines: [InterviewLine]) -> InterviewLine? {
        guard !q.manualStatus else { return nil }
        let key = EditorialState.key(q.text)
        guard key.count >= 5 else { return nil }
        return lines.first { line in
            guard line.speaker == .me, line.text.contains("?") else { return false }
            let other = EditorialState.key(line.text)
            return Double(key.intersection(other).count)/Double(max(1,key.union(other).count)) >= 0.92
        }
    }
    static func candidates(_ profile: QuestionProfile,lines: [InterviewLine],excluding: Set<String> = [],evidence: [ResearchEvidence] = []) -> [LifelineQuestion] {
        let recent = lines.suffix(3).map(\.text).joined(separator:" ")
        let keys = EditorialState.key(recent)
        let remaining = profile.settings.remainingMinutes
        var ranked: [(score:Double,position:Int,question:LifelineQuestion)] = []
        for (i,q) in profile.questions.enumerated() {
            // Prior coverage/conversations inform ranking; they do not answer for a new interview source.
            guard q.eligible, !excluding.contains(q.id), wasAsked(q,lines:lines) == nil else { continue }
            let questionKeys: Set<String> = EditorialState.key(q.text+" "+q.category+" "+(q.researchContext ?? ""))
            let matches: Double = Double(keys.intersection(questionKeys).count)
            let denominator: Double = sqrt(Double(max(1,questionKeys.count)))
            let overlap: Double = matches/denominator
            let essential: Double = q.essential ? ((remaining ?? 60) <= 10 ? 4.0 : 1.3) : 0.0
            var score: Double = overlap*3.0 + Double(q.priority)*0.5 + essential
            if q.savedForLater { score -= 2.0 }
            if q.status == .suggested { score -= 0.6 }
            ranked.append((score,i,q))
        }
        ranked.sort { a,b in a.score == b.score ? a.position < b.position : a.score > b.score }
        return ranked.map { $0.question }
    }
    static func localBridge(_ question: LifelineQuestion,lines: [InterviewLine]) -> String {
        if let bridge = question.transition, !bridge.isEmpty { return bridge }
        guard !lines.isEmpty else { return "" }
        let keys = EditorialState.key(lines.suffix(2).map(\.text).joined(separator:" "))
        return keys.intersection(EditorialState.key(question.text+" "+question.category)).count >= 2 ? "" : "That brings me to another part of the story."
    }
}

struct LifelineLullState {
    private(set) var lastVoice = -Double.infinity
    private var heardMic = false; private var heardSystem = false
    private var lastAttempt = -Double.infinity
    private var attemptedVoice = -Double.infinity
    mutating func observe(at now: Double,mic: Float,system: Float) {
        guard now.isFinite else { return }
        if mic.isFinite && mic > 0.004 { heardMic = true; lastVoice = now }
        if system.isFinite && system > 0.004 { heardSystem = true; lastVoice = now }
    }
    func mayOffer(at now: Double,settings: LifelineSettings,recording: Bool,healthy: Bool,busy: Bool,visible: Bool,
                  unresolved: Bool,lastLine: InterviewLine?,review: LifelineReview?,reviewMatches: Bool) -> Bool {
        guard settings.automatic, recording, healthy, !busy, !visible, !unresolved, heardMic, heardSystem,
              lastVoice.isFinite, now-lastVoice >= Double(settings.silenceSeconds),
              now-lastAttempt >= Double(settings.cooldownSeconds), lastVoice > attemptedVoice,
              let line = lastLine, line.speaker == .them, line.end >= lastVoice-3,
              reviewMatches, let review, review.answer_complete, !review.thinking_pause, !review.pending_followup,
              review.confidence.isFinite, review.confidence >= (settings.sensitivity == "Conservative" ? 0.97 : 0.94),
              review.next_question_id != nil else { return false }
        let text = line.text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.hasSuffix(".") || text.hasSuffix("!"), !text.hasSuffix("..."), !text.hasSuffix("…"),
              !["let me think","give me a second","thinking about","hold on","hmm","[unclear]","untranscribed"].contains(where:text.contains) else { return false }
        return true
    }
    mutating func attempted(at now: Double) { lastAttempt = now; attemptedVoice = lastVoice }
}
