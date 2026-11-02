import Foundation

extension SavedStoryReport {
    var markdown: String {
        func refs(_ ids: [String]) -> String { ids.map { "[\($0)]" }.joined(separator:" ") }
        func citations(_ values: [StoryCitation]) -> String {
            (try? StoryEvidence.resolve(values,in:evidence).map { "\n> \($0.quote)\n\n[\($0.evidence.id)] \($0.evidence.title) · \($0.evidence.role) · \($0.evidence.reference)\nClassification: \($0.evidence.classification)" }.joined(separator:"\n")) ?? "[Evidence no longer resolves; inspect saved JSON.]"
        }
        let r = content
        let discoveries = r.discoveries.map { "- \($0.text)\n\(citations($0.citations))" }.joined(separator:"\n\n")
        let directions = r.directions.enumerated().map { i,d in
            let update = try? StoryEvidence.validate(d,evidence:evidence,label:"Report")
            return "### \(i+1). \(d.question)\n\nStage: \(update?.stage ?? "Unverified hypothesis")\n\nWhy it may matter: \(d.why)\n\nProvisional thesis: \(d.provisional_thesis.isEmpty ? "Not established" : d.provisional_thesis)\n\nSupporting original reporting:\n\(citations(d.supporting))\n\nOpposing evidence:\n\(citations(d.contradicting))\n\nOriginality: \(d.originality)\n\nOverlapping coverage: \(refs(d.coverage_refs))\n\nUnanswered / required reporting:\n"+d.unverified.map { "- \($0)" }.joined(separator:"\n")+"\n\nAdditional sources:\n"+d.next_sources.map { "- \($0.name): \($0.contribution) \(refs($0.basis))" }.joined(separator:"\n")+"\n\nPotential wider significance: \(d.wider_significance)"
        }.joined(separator:"\n\n")
        let audit = r.originality_audit.map { "- **\($0.category)** — \($0.theme): \($0.explanation) \(refs($0.refs))" }.joined(separator:"\n\n")
        let next = r.next_sources.map { "- \($0.name): \($0.contribution) \(refs($0.basis))" }.joined(separator:"\n")
        let materials = r.materials.map { "- \($0.name): \($0.why)\n\(citations($0.citations))" }.joined(separator:"\n\n")
        let contradictions = r.contradictions.map { "- **\($0.kind)**: \($0.explanation)\n\(citations($0.sides))" }.joined(separator:"\n\n")
        let pitch = "\(r.pitch.assessment)\n\n"+r.pitch.criteria.map(\.markdown).joined(separator:"\n")+"\n\nRemaining gaps:\n"+r.pitch.gaps.map { "- \($0)" }.joined(separator:"\n")+"\n\nOutlet fit: \(r.pitch.outlet_fit)"
        let sources = evidence.map { "- [\($0.id)] \($0.title) · \($0.role) · \($0.classification) · \($0.reference)" }.joined(separator:"\n")
        return "# Investigative editorial report\n\n\(date.formatted())\n\nAnalysis scope: \(scope)\n\n## A. Most important discoveries\n\n\(discoveries.isEmpty ? "No sufficiently supported new discovery identified." : discoveries)\n\n## B. Strongest emerging article directions\n\n\(directions.isEmpty ? "Insufficient evidence to propose an article direction." : directions)\n\n## C. Originality audit\n\n\(audit)\n\n## D. Next sources\n\n\(next)\n\n## E. Suggested recordings and archival material\n\n\(materials.isEmpty ? "No specific material extracted." : materials)\n\n## F. Unresolved contradictions\n\n\(contradictions.isEmpty ? "No adequately sourced contradiction identified; absence here is not proof of agreement." : contradictions)\n\n## G. Pitch readiness\n\n\(pitch)\n\n## Source register\n\n\(sources)\n"
    }
}
