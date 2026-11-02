import Foundation

/// Entirely invented interview testimony for tests. Never added to the user's archive.
enum StoryFixtures {
    static let registry: [ResearchEvidence] = [.init(id:"COV-DEMO-2015",origin:"coverage_register",title:"SYNTHETIC Example Gazette coverage",reference:"https://example.test/coverage",role:"test-provided coverage reference",classification:"Coverage description — actual contents unverified",excerpt:"Cedar Workshop origins, closure and continued booking were previously covered.",context:"Synthetic constraint on novelty, not an established historical claim.")]

    static func interview(_ name: String = "Synthetic Source Alder") -> InterviewRecord {
        var r = InterviewRecord(); r.title = "SYNTHETIC editorial test"; r.sourceName = name
        r.date = Date(timeIntervalSince1970:1700000000); r.status = "test fixture"
        r.lines = [
            .init(start:10,end:20,speaker:.them,text:"I hear more electronic textures now, but I cannot tell whether that represents the whole scene. Compare the earlier Tape Cedar with the later Tape Elm; those are fictional test recordings."),
            .init(start:25,end:32,speaker:.them,text:"The fictional Cedar Route exchange began in 2018, and a Portland organizer kept the tour going by swapping bills."),
            .init(start:36,end:43,speaker:.them,text:"An overlooked volunteer called Test Rowan repaired the tape machines; I still have a flyer, though we should check the date."),
            .init(start:45,end:49,speaker:.me,text:"Let's move on to something else.")
        ]
        return r
    }
    static func opposing() -> InterviewRecord {
        var r = interview("Synthetic Source Birch")
        r.id = UUID(); r.date = Date(timeIntervalSince1970:1701000000)
        r.lines = [
            .init(start:75,end:83,speaker:.them,text:"The fictional Cedar Route exchange began in 2021, not 2018. I helped arrange its first bill, but the old series might have used a different name."),
            .init(start:90,end:98,speaker:.them,text:"I do not hear a scene-wide shift toward electronics. Some artists changed, and others kept making acoustic experiments.")
        ]
        return r
    }
    static func lead(_ evidence: ResearchEvidence,lane: String = "music") -> StoryLead {
        .init(lane:lane,question:lane == "music" ? "Do changes in particular recordings represent a wider musical development?" : "How did a specific touring exchange sustain connections beyond Texas?",
              why:"Concrete recordings and accounts could test a wider pattern without assuming one.",stage:"lead",provisional_thesis:"Provisional: connected practices may matter; scope remains unverified.",
              supporting:[.init(ref:evidence.id,quote:String(evidence.excerpt.prefix(180)))],contradicting:[],coverage_refs:["COV-DEMO-2015"],
              originality:"Potentially new evidence, not proof that the theme has never been reported.",unverified:["Compare the named recordings and ask other musicians for counterexamples."],
              next_sources:[.init(name:"A musician who disagrees",contribution:"Test whether the audible examples represent a scene rather than one artist.",basis:[evidence.id])],
              wider_significance:"No national significance established; document a mechanism and outside perspective first.")
    }
    static func report(_ record: InterviewRecord,prior: ResearchEvidence? = nil) -> StoryReport {
        let e = StoryEvidence.passages([record])[0]
        var direction = lead(e)
        if let prior { direction.contradicting = [.init(ref:prior.id,quote:prior.excerpt)] }
        return .init(discoveries:[.init(text:"The source describes possible textural differences but explicitly doubts representativeness.",citations:[.init(ref:e.id,quote:e.excerpt)])],
                     directions:[direction],originality_audit:[.init(theme:"House closure and continued booking",category:"already extensively covered",explanation:"The journalist identifies prior 2015 reporting; original text is not supplied in this fixture.",refs:["COV-DEMO-2015"])],
                     next_sources:direction.next_sources,materials:[.init(name:"Tape Cedar and Tape Elm — fictional test recordings",why:"Could test a specific musical comparison.",citations:[.init(ref:e.id,quote:e.excerpt)])],
                     contradictions:[],pitch:.init(assessment:"not ready",criteria:["Central question is provisional","Original evidence is one attributed account","Additional perspectives needed","Overlap needs actual text review","Wider significance not established","A listening comparison and archival check are feasible"].map { .init(text:$0,refs:[e.id]) },gaps:["Independent primary evidence and broader perspectives"],outlet_fit:"Choose an outlet after the story's scope is established."))
    }
    static func brief() -> StoryBriefContent {
        .init(positioning:"Source background is journalist-supplied; ask what they directly witnessed.",established:[.init(text:"Origins and continued booking are identified as previously covered; article text is unverified here.",refs:["COV-DEMO-2015"])],
              open_questions:["Whose role is missing?"],hypotheses:["A contribution may matter beyond an individual profile."],
              questions:(1...10).map { "Which specific firsthand example would you use to test question \($0)?" },essential_indices:[1,4,8],sensitive:[.init(text:"Ask neutrally whether the dates refer to different events.",refs:[])])
    }
    static func json<T: Encodable>(_ value: T) throws -> String { String(decoding:try JSONEncoder().encode(value),as:UTF8.self) }
}

actor StoryPromptProbe {
    var requests: [(String,String)] = []
    let output: String
    init(_ output: String) { self.output = output }
    func complete(_ system: String,_ input: String) -> String { requests.append((system,input)); return output }
    func snapshot() -> [(String,String)] { requests }
}
actor StoryPacketProbe {
    let evidence: [ResearchEvidence]; let report: String
    var packets = [String](); var finalRequests = 0
    init(evidence: [ResearchEvidence],report: String) { self.evidence = evidence; self.report = report }
    func complete(_ system: String,_ input: String) throws -> String {
        if system.contains("Select original evidence for a post-interview") {
            packets.append(input)
            let candidates = evidence.filter { input.contains("[\($0.id)]") }
            let picked = [candidates.first,candidates.last].compactMap { $0 }
            let unique = StoryEngine.unique(picked)
            struct Response: Encodable { var citations: [StoryCitation] }
            return try StoryFixtures.json(Response(citations:unique.map { .init(ref:$0.id,quote:$0.excerpt) }))
        }
        finalRequests += 1; return report
    }
    func snapshot() -> ([String],Int) { (packets,finalRequests) }
}
