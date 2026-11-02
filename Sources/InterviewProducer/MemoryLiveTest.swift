import Foundation

@MainActor enum MemoryLiveTest {
    /// Explicit opt-in CLI smoke test. Only synthetic, temporary memory is used.
    static func run() async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-live-memory-test-\(UUID().uuidString)")
        do {
            guard !ProducerInference.model.isEmpty else { throw ProducerError.message("Choose an eligible model in the existing app first.") }
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:folder) }
            let file = folder.appendingPathComponent("conversations.json"); try MemoryFixtures.export().write(to:file)
            let preview = try ChatGPTExportReader.open(file)
            let memory = ConversationMemory(url:folder.appendingPathComponent("memory.sqlite"))
            let selected = preview.conversations.first { $0.originalID == "synthetic-noise-research" }!
            _ = try await memory.importSelected(preview,ids:[selected.id])
            let retrieved = try await memory.retrieve(current:"Project Aurora Project Beacon")
            let text = try await ProducerInference.complete(instructions:"""
            This is a synthetic memory-recall test, not a real interview. Read the supplied original conversation excerpts.
            Return JSON only with keys winter_quote, psychic_quote, correction_quote, assistant_is_verified, source_refs.
            winter_quote: copy one exact user-authored sentence containing "minimal traditional rhythm".
            psychic_quote: copy one exact user-authored sentence containing "corrupted-IDM".
            correction_quote: copy an exact user correction sentence explaining that intention must not be attributed to Alex.
            assistant_is_verified: boolean, whether the assistant's earlier claim about Alex's intention is established fact.
            source_refs: exact MEM-... identifiers for the user passages that supply these three quotes.
            Do not use an assistant assertion as a verified fact. Do not paraphrase or browse.
            """,input:"<retrieved_originals>\(retrieved.prompt)</retrieved_originals>")
            struct Recall: Decodable { var winter_quote: String; var psychic_quote: String; var correction_quote: String; var assistant_is_verified: Bool; var source_refs: [String] }
            let answer = try JSONDecoder().decode(Recall.self,from:Data(text.utf8))
            let citations = try ResearchEvidence.validatedReferences(answer.source_refs,candidates:retrieved.evidence)
            let winterOK = !answer.winter_quote.isEmpty && MemoryFixtures.winter.contains(answer.winter_quote) && answer.winter_quote.contains("minimal traditional rhythm")
            let psychicOK = !answer.psychic_quote.isEmpty && MemoryFixtures.psychic.contains(answer.psychic_quote) && answer.psychic_quote.contains("corrupted-IDM")
            let correctionOK = !answer.correction_quote.isEmpty && MemoryFixtures.correction.contains(answer.correction_quote) && (answer.correction_quote.contains("intention") || answer.correction_quote.contains("subjective"))
            let citationNodes = Set(citations.compactMap(\.nodeID))
            guard winterOK, psychicOK, correctionOK, !answer.assistant_is_verified, citationNodes.isSuperset(of:["u1","u2","u3"]) else {
                throw ProducerError.message("The model's recall, uncertainty or original-source references did not pass the exact-text assertions.")
            }
            print("PASS: real \(ProducerInference.useGroq ? "explicit Groq text" : "ChatGPT-plan") inference recalled exact Project Aurora and Project Beacon observations, preserved the user's correction, rejected assistant speculation as fact, and cited three validated original message passages.")
            let service = EditorialService(archive:memory)
            let result = try await service.analyze(lines:[
                .init(start:10,end:17,speaker:.them,text:"Project Aurora came out of a turning point that nearly made me stop making music."),
                .init(start:18,end:22,speaker:.me,text:"Interesting. Let's talk about tour dates.")
            ],research:"Synthetic test. No verified publication is supplied.",known:[])
            print("Real automatic editorial path completed. should_suggest=\(result.decision.should_suggest); supplied \(result.suppliedEvidence?.count ?? 0) historical/dossier references; cited \(result.citedEvidence?.count ?? 0).")
            if result.decision.should_suggest { print("Question: \(result.decision.suggested_question)") }
            print("No personal export, real interview audio, or ordinary memory database was accessed by this smoke test.")
            return 0
        } catch { print("LIVE MEMORY TEST NOT VERIFIED: \(error.localizedDescription)"); return 1 }
    }
}
