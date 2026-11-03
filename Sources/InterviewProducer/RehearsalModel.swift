import Foundation

@MainActor final class RehearsalControllerBox { weak var controller: InterviewController? }
actor RehearsalModel {
    enum Mode { case quiet, followup, unavailable }
    let box: RehearsalControllerBox
    var mode = Mode.quiet
    var calls = 0; var recalledObservation = false; var recalledCorrection = false
    var prompts = [String]()
    init(box: RehearsalControllerBox) { self.box = box }
    func setMode(_ value: Mode) { mode = value }
    func snapshot() -> (Int,Bool,Bool) { (calls,recalledObservation,recalledCorrection) }
    func observe(_ input: String) {
        guard input.contains("<conversation_archive>"), input.contains("<transcript>") else { return }
        recalledObservation = recalledObservation || input.contains(MemoryFixtures.winter)
        recalledCorrection = recalledCorrection || input.contains(MemoryFixtures.correction)
    }
    func complete(_ system: String,_ input: String) async throws -> String {
        calls += 1; observe(input)
        prompts.append(input)
        if mode == .unavailable { throw ProducerError.message("Injected provider outage") }
        if system.contains("Prepare a concise pre-interview brief") { return try fixtureJSON(StoryFixtures.brief(),input:input) }
        guard let record = await box.controller?.record else { throw ProducerError.message("Rehearsal controller has no record") }
        let supplied = StoryEvidence.passages([record]).filter { input.contains($0.id) }
        if system.contains("Write a rigorous post-interview editorial report") {
            var sourceRecord = record; sourceRecord.lines = record.lines.filter { $0.speaker == .them }
            return try fixtureJSON(StoryFixtures.report(sourceRecord),input:input)
        }
        if system.contains("Update the competing investigations") {
            struct Review: Encodable { var directions: [StoryLead] }
            return try StoryFixtures.json(Review(directions:supplied.filter { $0.role.hasPrefix("Interviewee:") }.prefix(1).map { StoryFixtures.lead($0) }))
        }
        let bank = Self.bank(input)
        let musicAnswer = supplied.first { $0.role.hasPrefix("Interviewee:") && $0.excerpt.contains("pulsing delay") }
        let answerIDs = musicAnswer == nil ? Set<String>() : Set(bank.filter { $0.id == "music" && !$0.manual }.map(\.id))
        let selection = ["networks","people","origins","music"].first { id in bank.contains { $0.id == id && ["available","suggested"].contains($0.status) } && !answerIDs.contains(id) }
        let answers: [LifelineAnswerUpdate] = musicAnswer.map { e in
            answerIDs.map { .init(question_id:$0,confidence:0.99,explanation:"Synthetic source gives two recordings, an audible comparison and a scope caveat.",citations:[.init(ref:e.id,quote:e.excerpt)]) }
        } ?? []
        let last = record.lines.last
        let anchor = supplied.last { $0.nodeID == last?.id.uuidString }
        var review = LifelineReview(next_question_id:selection,bridge:"Turning to another part of the story,",reason:"Choose an unanswered substantive bank question.",confidence:0.99,answer_complete:true,thinking_pause:false,pending_followup:false,anchor_ref:anchor?.id,answers:answers,source_refs:[])
        if system.contains("Return ONLY a JSON object with:") {
            let revelation = record.lines.last { $0.speaker == .them && $0.text.contains("nearly stopped organizing shows") }
            var d = EditorialDecision(should_suggest:false,confidence:0,priority:"medium",suggested_question:"",reason:"No missed opportunity.",evidence_excerpt:"",related_topic:"",timestamp:0)
            var threads = [EditorialThread]()
            if mode == .followup, let revelation {
                let quote = "There was a turning point when we nearly stopped organizing shows altogether."
                d = .init(should_suggest:true,confidence:0.99,priority:"high",suggested_question:"What happened at the turning point when you nearly stopped organizing shows?",reason:"The source introduced a consequential event without explaining it.",evidence_excerpt:quote,related_topic:"synthetic organizing turning point",timestamp:revelation.start)
                threads = [.init(topic:d.related_topic,status:"open",evidence:quote)]
                review.pending_followup = true; review.next_question_id = nil
            }
            return try StoryFixtures.json(EditorialEnvelope(decision:d,threads:threads,resolved_titles:[],source_refs:[],lifeline_review:review))
        }
        return try StoryFixtures.json(review)
    }
    private func fixtureJSON<T: Encodable>(_ value: T,input: String) throws -> String {
        let regex = try NSRegularExpression(pattern:#"\[PUB-[a-zA-Z0-9-]+\]"#)
        let range = NSRange(input.startIndex...,in:input)
        guard let match = regex.firstMatch(in:input,range:range),let r = Range(match.range,in:input) else { throw ProducerError.message("Synthetic rehearsal requires its explicit publication fixture.") }
        return try StoryFixtures.json(value).replacingOccurrences(of:"COV-DEMO-2015",with:String(input[r].dropFirst().dropLast()))
    }
    private struct BankItem { var id: String; var status: String; var manual: Bool }
    private static func bank(_ input: String) -> [BankItem] {
        let tag = input.contains("<prepared_question_bank>") ? "prepared_question_bank" : "question_bank"
        guard let start = input.range(of:"<\(tag)>"),let end = input.range(of:"</\(tag)>",range:start.upperBound..<input.endIndex) else { return [] }
        let part = input[start.upperBound..<end.lowerBound]
        guard let a = part.firstIndex(of:"["), let b = part.lastIndex(of:"]"),
              let data = String(part[a...b]).data(using:.utf8), let list = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] else { return [] }
        return list.compactMap { entry in guard let id = entry["id"] as? String else { return nil }; return .init(id:id,status:entry["status"] as? String ?? "available",manual:entry["manual_status"] as? Bool ?? false) }
    }
}
