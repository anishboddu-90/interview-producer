import Foundation
import PDFKit
import Observation

struct ResearchDocument: Codable, Identifiable {
    var id = UUID(); var name: String; var kind: String; var text: String
    var sourceURL: String? = nil
    var verificationNote: String? = nil
    var primaryConfirmed: Bool? = nil
}
@MainActor @Observable final class ResearchLibrary {
    var documents: [ResearchDocument] = []
    var error = ""
    @ObservationIgnored private var cachedPassages: [(Set<String>,ResearchEvidence)]? = nil
    private let url: URL
    init(url: URL? = nil,includeDefaults: Bool = true) {
        self.url = url ?? InterviewStore.directory.deletingLastPathComponent().appendingPathComponent("research.json")
        try? FileManager.default.createDirectory(at:self.url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        documents = (try? JSONDecoder().decode([ResearchDocument].self,from:Data(contentsOf:self.url))) ?? []
        // Empty by default. An empty library must not silently resurrect deleted starter material.
    }
    // Synthetic coverage is used only by the explicit test harness.
    static let published = "SYNTHETIC EXAMPLE: Cedar Workshop origins were previously reported in Example Gazette. Claims remain attributed and need primary-source checks."
    func save() { cachedPassages = nil; do { try JSONEncoder().encode(documents).write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) } catch { self.error = error.localizedDescription } }
    func add(_ url: URL,kind: String,sourceURL: String = "",verificationNote: String = "",primaryConfirmed: Bool = false) throws {
        if primaryConfirmed {
            guard let link = URL(string:sourceURL), ["https","http"].contains(link.scheme ?? ""), link.host != nil,
                  verificationNote.trimmingCharacters(in:.whitespacesAndNewlines).count >= 12 else {
                throw ProducerError.message("Confirmed primary evidence requires its source URL and a note explaining what you checked. Imported testimony alone is not independent verification.")
            }
        }
        let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size <= 20_000_000, documents.count < 50 else { throw ProducerError.message("Research limit: 50 documents, 20 MB per file.") }
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url:url), let extracted = pdf.string, !extracted.isEmpty else { throw ProducerError.message("PDF has no extractable text. OCR is not included.") }; text = extracted
        } else { text = try String(contentsOf:url,encoding:.utf8) }
        guard text.count <= 300000 else { throw ProducerError.message("Research document exceeds 300,000 characters.") }
        documents.append(.init(name:url.lastPathComponent,kind:kind,text:text,sourceURL:sourceURL.isEmpty ? nil : sourceURL,
                               verificationNote:verificationNote.isEmpty ? nil : verificationNote,primaryConfirmed:primaryConfirmed)); save()
    }
    func evidence(for conversation: String) -> [ResearchEvidence] {
        let query = EditorialState.key(conversation)
        if cachedPassages == nil { cachedPassages = makePassages(documents) }
        return (cachedPassages ?? []).enumerated().sorted { a,b in
            let x = Double(query.intersection(a.element.0).count)/sqrt(Double(max(1,a.element.0.count)))
            let y = Double(query.intersection(b.element.0).count)/sqrt(Double(max(1,b.element.0.count)))
            return x == y ? a.offset < b.offset : x > y
        }.prefix(4).map { $0.element.1 }
    }
    func editorialEvidence(for query: String) -> [ResearchEvidence] {
        if cachedPassages == nil { cachedPassages = makePassages(documents) }
        let top = evidence(for:query)
        // Include a relevant excerpt per publication for originality comparisons, within a bounded archive context.
        let grouped = Dictionary(grouping:cachedPassages ?? [],by:{$0.1.conversationID ?? $0.1.title})
        let perDocument = grouped.values.compactMap { group in StoryEvidence.rank(group.map(\.1),query:query,limit:1).first }
        return StoryEngine.unique(top+StoryEvidence.rank(perDocument,query:query,limit:8))
    }
    private func makePassages(_ documents: [ResearchDocument]) -> [(Set<String>,ResearchEvidence)] {
        var chunks = [(Set<String>,ResearchEvidence)]()
        for doc in documents {
            let chars = Array(doc.text)
            let fingerprint = MemoryIdentity.digest(doc.text)
            for offset in stride(from:0,to:chars.count,by:1400) {
                let text = String(chars[offset..<min(offset+1600,chars.count)])
                let tokens = EditorialState.key(text)
                let confirmed = doc.primaryConfirmed == true && !(doc.verificationNote ?? "").isEmpty && !(doc.sourceURL ?? "").isEmpty
                let evidence = ResearchEvidence(id:"PUB-"+String(MemoryIdentity.digest(doc.id.uuidString+"|\(offset)|"+fingerprint).prefix(24)),origin:"publication",title:doc.name,
                    reference:"Research document \(doc.id.uuidString), characters \(offset)..<\(min(offset+1600,chars.count))",role:"supplied research",
                    classification:confirmed ? "Confirmed primary-source evidence — journalist attested" : doc.kind+" — supplied classification, not independent verification",excerpt:text,context:"",conversationID:doc.id.uuidString,
                    annotation:doc.verificationNote,sourceURL:doc.sourceURL ?? ConversationMemory.urls(in:text).first,startOffset:offset,endOffset:min(offset+1600,chars.count))
                chunks.append((tokens,evidence))
            }
        }
        return chunks
    }
    func context(for conversation: String) -> String {
        "\(EditorialProfile.coverageContext)\n\n"+evidence(for:conversation).map(\.prompt).joined(separator:"\n\n")
    }
}
