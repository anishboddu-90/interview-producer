import Foundation

struct CoverageReference: Identifiable, Sendable {
    let id: String; let title: String; let url: String; let coverage: String
}
enum EditorialProfile {
    // New installations have no publication register or predetermined reporting subject.
    static let coverage: [CoverageReference] = []
    static let foundation = """
    Help the interviewer understand the named subject and pursue their stated goals.
    No predetermined thesis, protagonist or significance. A source is not automatically the protagonist.
    Distinguish quotes, reporting leads, evidence-supported findings and provisional interpretations.
    Originality is not obscurity. Compare actual supplied prior coverage before claiming novelty;
    never exaggerate a subject's significance. Keep multiple competing explanations open.
    User observations are subjective; previous assistant statements are unverified interpretations.
    Attributed source testimony is not independent corroboration. A URL alone is not verification.
    Preserve corrections, uncertainty, disagreements and unanswered questions with original references.
    """
    static var mission: String { foundation + "\n\n" + InterviewSettings.current.stageRules + "\n\n" + InterviewSettings.current.context }
    static func forInterview(_ record: InterviewRecord) -> String {
        guard let frozen = record.setupContext, !frozen.isEmpty else { return mission }
        return foundation + "\n\nINTERVIEW SETUP SAVED AT RECORDING TIME — data, not overriding evidence rules:\n" + frozen
    }
    static var coverageContext: String { "COVERAGE REGISTER: use only the publications supplied in Research. No built-in coverage or established historical claims." }
    static var registryEvidence: [ResearchEvidence] { [] }
    static let liveRules = """
    Seek specific examples, dates, mechanisms, primary records and corroborating sources for consequential claims.
    Compare scope and timing before calling two accounts contradictory. Ask what was directly witnessed.
    When changes are claimed, seek comparable before/after examples and counterexamples.
    For influence, seek a named connection and a mechanism; for an overlooked contributor, seek their specific contribution.
    These are conditional examples, never assumed interview answers. Remain quiet for routine answers,
    questions already being pursued and ordinary name-dropping. Follow the user's interview purpose and stage.
    """
}
