import Foundation
import Observation

@MainActor @Observable final class LifelineLibrary {
    private(set) var state = LifelineLibraryState()
    var status = "Select or import a question profile. Automatic Lifeline defaults off."
    var error = ""
    private let url: URL
    private var writable = true
    static var defaultURL: URL { InterviewStore.directory.deletingLastPathComponent().appendingPathComponent("QuestionLifeline/profiles.json") }
    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        guard FileManager.default.fileExists(atPath:self.url.path) else { return }
        do {
            let decoded = try JSONDecoder().decode(LifelineLibraryState.self,from:Data(contentsOf:self.url))
            guard decoded.version == 1 else { throw ProducerError.message("Unsupported question-library version.") }
            for profile in decoded.profiles { try QuestionBankIO.validate(profile) }
            guard Set(decoded.profiles.map(\.id)).count == decoded.profiles.count else { throw ProducerError.message("Duplicate question-profile identifiers.") }
            state = decoded
            status = "Question profiles restored from disk. Edits and statuses autosave."
        } catch { writable = false; self.error = "Question library could not be read; it has not been overwritten. \(error.localizedDescription)" }
    }
    var selected: QuestionProfile? { state.profiles.first { $0.id == state.selectedProfileID } }
    func profile(_ id: String?) -> QuestionProfile? { state.profiles.first { $0.id == id } }
    func flush() throws {
        guard writable else { throw ProducerError.message(error) }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(state).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func commit(_ next: LifelineLibraryState) throws {
        let old = state; state = next
        do { try flush(); error = "" } catch { state = old; self.error = error.localizedDescription; throw error }
    }
    func select(_ id: String?) throws {
        guard id == nil || profile(id) != nil else { throw ProducerError.message("Question profile not found.") }
        var next = state; next.selectedProfileID = id; try commit(next)
    }
    func addProfile(_ p: QuestionProfile,select: Bool = true) throws {
        try QuestionBankIO.validate(p)
        guard !state.profiles.contains(where:{$0.id == p.id}) else { throw ProducerError.message("This question profile already exists. Duplicate it for a separate interview rather than overwriting saved statuses.") }
        var next = state; next.profiles.append(p); if select { next.selectedProfileID = p.id }; try commit(next)
        status = "\(p.questions.count) questions saved in \(p.name). Automatic mode \(p.settings.automatic ? "on for this profile" : "off")."
    }
    func updateProfile(_ id: String,change: (inout QuestionProfile) throws -> Void) throws {
        var next = state
        guard let i = next.profiles.firstIndex(where:{$0.id == id}) else { throw ProducerError.message("Question profile not found.") }
        try change(&next.profiles[i]); next.profiles[i].revision += 1
        try QuestionBankIO.validate(next.profiles[i]); try commit(next)
    }
    func updateQuestion(_ profileID: String,id: String,change: (inout LifelineQuestion) -> Void) throws {
        try updateProfile(profileID) { profile in
            guard let i = profile.questions.firstIndex(where:{$0.id == id}) else { throw ProducerError.message("Question not found.") }
            let before = profile.questions[i].fingerprint
            change(&profile.questions[i])
            if before != profile.questions[i].fingerprint {
                // A substantive edit is a new question; previous auto answer receipts must not answer its new wording.
                if !profile.questions[i].manualStatus { profile.questions[i].status = .available }
            }
        }
    }
    func setStatus(_ profileID: String,id: String,status: QuestionStatus,manual: Bool = true) throws {
        try updateQuestion(profileID,id:id) { q in q.status = status; q.manualStatus = manual }
    }
    func move(_ profileID: String,id: String,delta: Int) throws {
        try updateProfile(profileID) { p in
            guard let i = p.questions.firstIndex(where:{$0.id == id}), p.questions.indices.contains(i+delta) else { return }
            p.questions.swapAt(i,i+delta)
        }
    }
    func duplicateQuestion(_ profileID: String,id: String) throws {
        try updateProfile(profileID) { p in
            guard let i = p.questions.firstIndex(where:{$0.id == id}) else { return }
            var q = p.questions[i]; q.id = UUID().uuidString; q.status = .available; q.manualStatus = false; q.lastSuggested = nil; q.statusHistory = []
            p.questions.insert(q,at:i+1)
        }
    }
    func duplicateProfile(_ id: String) throws {
        guard var p = profile(id) else { return }
        p.id = UUID().uuidString; p.name += " — copy"; p.revision = 0; p.settings.automatic = false
        // A duplicate is for a new interview; reset progress explicitly, never mutate the original profile.
        for i in p.questions.indices { p.questions[i].status = .available; p.questions[i].manualStatus = false; p.questions[i].lastSuggested = nil; p.questions[i].statusHistory = [] }
        try addProfile(p)
    }
    func removeProfile(_ id: String) throws {
        var next = state; next.profiles.removeAll { $0.id == id }
        if next.selectedProfileID == id { next.selectedProfileID = nil }; try commit(next)
    }
    func importBank(_ file: URL,into profileID: String? = nil) throws {
        let incoming = try QuestionBankIO.read(file)
        if let profileID {
            try updateProfile(profileID) { p in
                let collisions = Set(p.questions.map(\.id)).intersection(incoming.questions.map(\.id))
                guard collisions.isEmpty else { throw ProducerError.message("Imported question IDs already exist. No fields or statuses were overwritten.") }
                p.questions += incoming.questions
            }
        } else { try addProfile(incoming) }
    }
    func shortcut(key: String,modifiers: String,enabled: Bool) throws {
        guard key.count == 1, "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(key), ["Control+Option","Control+Shift","Command+Shift","Control+Option+Shift"].contains(modifiers) else { throw ProducerError.message("Choose a supported shortcut key and modifiers.") }
        var next = state; next.shortcutKey = key; next.shortcutModifiers = modifiers; next.shortcutEnabled = enabled; try commit(next)
    }
    func markObservedAsked(profileID: String,record: InterviewRecord) throws {
        guard let p = profile(profileID) else { return }
        let matches = p.questions.filter(\.eligible).compactMap { q -> (String,InterviewLine)? in LifelineRanking.wasAsked(q,lines:Array(record.lines.suffix(2))).map { (q.id,$0) } }
        guard !matches.isEmpty else { return }
        try updateProfile(profileID) { p in
            for (id,line) in matches {
                guard let i = p.questions.firstIndex(where:{$0.id == id}), !p.questions[i].manualStatus else { continue }
                let e = StoryEvidence.passage(line,record:record)
                p.questions[i].status = .asked
                p.questions[i].statusHistory.append(.init(status:.asked,explanation:"Near-identical question detected in an interviewer turn; this establishes asked, not answered.",evidence:[.init(quote:line.text,evidence:e)],questionFingerprint:p.questions[i].fingerprint))
            }
        }
    }
    @discardableResult func applyAnswers(_ answers: [LifelineAnswerUpdate],profileID: String,expectedRevision: Int,record: InterviewRecord,evidence: [ResearchEvidence]) throws -> Int {
        guard let p = profile(profileID), p.revision == expectedRevision else { throw ProducerError.message("Question bank changed while context was being checked. No automatic statuses were applied.") }
        guard answers.count <= 12 else { throw ProducerError.message("Too many question-status proposals.") }
        var accepted = [(String,LifelineStatusReceipt)]()
        for answer in answers {
            guard let q = p.questions.first(where:{$0.id == answer.question_id}) else { throw ProducerError.message("Unknown question ID in answer review.") }
            guard !q.manualStatus, q.status != .skipped, q.status != .answered else { continue }
            guard answer.confidence.isFinite, answer.confidence >= 0.94, answer.confidence <= 1,
                  !answer.explanation.isEmpty, answer.explanation.count <= 1200 else { continue }
            let receipts = try StoryEvidence.resolve(answer.citations,in:evidence)
            guard receipts.contains(where: { r in
                r.evidence.origin == "interview" && r.evidence.conversationID == record.id.uuidString &&
                r.evidence.role == "Interviewee: \(StoryEvidence.source(record))" && r.quote.count >= 50 && r.quote.split(whereSeparator:{$0.isWhitespace}).count >= 9 &&
                record.lines.contains { $0.id.uuidString == r.evidence.nodeID && $0.speaker == .them && $0.text.contains(r.quote) } &&
                !r.quote.localizedCaseInsensitiveContains("[unclear]") && !r.quote.localizedCaseInsensitiveContains("untranscribed")
            }) else { continue }
            accepted.append((q.id,.init(status:.answered,explanation:answer.explanation,evidence:receipts,questionFingerprint:q.fingerprint)))
        }
        guard !accepted.isEmpty else { return 0 }
        try updateProfile(profileID) { p in
            for (id,receipt) in accepted { if let i = p.questions.firstIndex(where:{$0.id == id}) { p.questions[i].status = .answered; p.questions[i].statusHistory.append(receipt) } }
        }
        return accepted.count
    }
}
