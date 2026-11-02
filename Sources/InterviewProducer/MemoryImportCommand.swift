import Foundation

/// Explicit local selection for an authorized import; never selects the whole archive by default.
@MainActor enum MemoryImportCommand {
    struct RetrievalCheck: Decodable { let query: String; let originalID: String; let nodeID: String; let exactExcerpt: String }
    struct AnnotationEdit: Decodable { let originalID: String; let nodeID: String; let kind: String; let note: String }
    struct Selection: Decodable { let conversationIDs: [String]; let dossier: String?; let retrievalChecks: [RetrievalCheck]?; let annotations: [AnnotationEdit]? }
    static func run(export: URL,selection: URL) async -> Int32 {
        do {
            let requested = try JSONDecoder().decode(Selection.self,from:Data(contentsOf:selection))
            let ids = Set(requested.conversationIDs)
            guard !ids.isEmpty, ids.count == requested.conversationIDs.count else { throw ProducerError.message("Select distinct original conversation IDs explicitly.") }
            if let dossier = requested.dossier, dossier.count > 6000 { throw ProducerError.message("Dossier exceeds 6,000 characters; nothing imported.") }
            let session = try await Task.detached(priority:.utility) { try ChatGPTExportReader.open(export) }.value
            let selected = session.conversations.filter { ids.contains($0.originalID) }
            guard selected.count == ids.count, Set(selected.map(\.originalID)) == ids else { throw ProducerError.message("Selection is missing or ambiguous in this export; nothing imported.") }
            // Validate every selected graph before any mutation.
            for item in selected {
                let bytes = try ChatGPTExportReader.raw(item)
                guard let root = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw ProducerError.message("Invalid selected original.") }
                _ = try ExportGraph(root:root)
            }
            let store = ConversationMemory.shared
            let result = try await store.importSelected(session,ids:Set(selected.map(\.id)))
            for item in selected {
                let id = MemoryIdentity.digest(item.originalID+"|"+item.sha256)
                let original = try ChatGPTExportReader.raw(item)
                guard try await store.originalConversation(id) == original else { throw ProducerError.message("Stored original verification failed.") }
                print("PASS exact original: \(item.title) — \(item.messageCount) messages, \(item.branchCount) branch paths; SHA-256 \(item.sha256)")
            }
            for edit in requested.annotations ?? [] {
                guard let original = selected.first(where:{$0.originalID == edit.originalID}),
                      let kind = MemoryKind(rawValue:edit.kind), kind != .verifiedSource else { throw ProducerError.message("Annotation must refer to a selected original and cannot establish source verification.") }
                let storedID = MemoryIdentity.digest(original.originalID+"|"+original.sha256)
                guard let message = try await store.messages(conversation:storedID).first(where:{$0.nodeID == edit.nodeID}),message.role == "user" else { throw ProducerError.message("Selected user message for annotation not found.") }
                try await store.annotate(conversation:storedID,node:edit.nodeID,annotation:.init(kind:kind.rawValue,note:edit.note,sourceURL:message.sourceURL,threadStatus:message.threadStatus,pinned:message.pinned,excluded:message.excluded))
                print("PASS separate annotation: \(edit.nodeID) — original text unchanged")
            }
            for test in requested.retrievalChecks ?? [] {
                guard let original = selected.first(where:{$0.originalID == test.originalID}) else { throw ProducerError.message("Retrieval check refers to an unselected original.") }
                let storedID = MemoryIdentity.digest(original.originalID+"|"+original.sha256)
                let context = try await store.retrieve(current:test.query)
                guard context.passages.contains(where:{$0.conversationID == storedID && $0.nodeID == test.nodeID && $0.role == "user" && $0.excerpt.contains(test.exactExcerpt)}) else { throw ProducerError.message("Automatic retrieval check did not recover the required verbatim user passage.") }
                print("PASS automatic local retrieval: \(test.query) — original user node \(test.nodeID)")
            }
            if let dossier = requested.dossier, try await store.dossier().0 != dossier { try await store.saveDossier(dossier) }
            print("Local selected import complete: \(result.imported) added, \(result.skipped) already present. Warnings: \(result.warnings.count). No network inference was called.")
            fflush(stdout); return 0
        } catch { print("Selected import failed: \(error.localizedDescription)"); fflush(stdout); return 1 }
    }
}
