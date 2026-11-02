import SwiftUI

struct SuggestionEvidenceView: View {
    let suggestion: SavedSuggestion
    var body: some View {
        let cited = suggestion.evidence ?? []
        let delivered = (suggestion.suppliedEvidence ?? []).filter { candidate in !cited.contains(where:{$0.id == candidate.id}) }
        DisclosureGroup("Evidence and original sources (\(cited.count) cited)") {
            VStack(alignment:.leading,spacing:10) {
                Text("Current interview evidence [\(Int(suggestion.decision.timestamp))s]").font(.caption.bold())
                Text(suggestion.decision.evidence_excerpt).textSelection(.enabled)
                if cited.isEmpty { Text("The model cited no historical source. Earlier suggestions may predate memory provenance.").font(.caption).foregroundStyle(.secondary) }
                ForEach(cited) { evidence in source(evidence) }
                if !delivered.isEmpty {
                    DisclosureGroup("Other passages supplied to the model (not claimed as cited)") { ForEach(delivered) { evidence in source(evidence) } }
                }
            }.padding(.top,6)
        }.font(.callout)
    }
    private func source(_ evidence: ResearchEvidence) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text("[\(evidence.id)] \(evidence.title)").font(.caption.bold())
            Text("\(evidence.role) · \(evidence.classification)").font(.caption).foregroundStyle(.secondary)
            Text(evidence.reference).font(.caption.monospaced()).textSelection(.enabled)
            if let date = evidence.created { Text(Date(timeIntervalSince1970:date).formatted()).font(.caption) }
            Text(evidence.excerpt).textSelection(.enabled)
            if let note = evidence.annotation, !note.isEmpty { Text("Separate correction/annotation: \(note)").textSelection(.enabled) }
            if let state = evidence.threadStatus, !state.isEmpty { Text("Thread status: \(state)").font(.caption) }
            if let url = evidence.sourceURL, !url.isEmpty { Text("Source reference: \(url)").font(.caption).textSelection(.enabled) }
            if !evidence.context.isEmpty { DisclosureGroup("Surrounding original turns and corrections") { Text(evidence.context).font(.caption).textSelection(.enabled) } }
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
    }
}
