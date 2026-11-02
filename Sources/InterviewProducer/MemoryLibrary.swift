import Foundation
import Observation

@MainActor @Observable final class MemoryLibrary {
    let store: ConversationMemory
    var conversations: [MemoryConversation] = []
    var hits: [ResearchEvidence] = []
    var dossier = ""
    var dossierDirty = false
    var status = "Original messages stay local. Only selected passages enter interview analysis."
    var busy = false
    var revision = 0
    init(store: ConversationMemory = .shared) { self.store = store }
    func refresh() async {
        do { conversations = try await store.conversations(); if !dossierDirty { dossier = try await store.dossier().0 } }
        catch { status = "Conversation memory unavailable: \(error.localizedDescription)" }
    }
    func search(_ query: String,includeExcluded: Bool) async {
        do { let result = try await store.search(query,includeExcluded:includeExcluded); if !Task.isCancelled { hits = result } }
        catch { if !Task.isCancelled { status = error.localizedDescription } }
    }
    func importSelected(_ session: MemoryImportSession,ids: Set<String>) async {
        busy = true; defer { busy = false }
        do {
            let result = try await store.importSelected(session,ids:ids)
            revision += 1
            status = "Imported \(result.imported); already present \(result.skipped). All branches preserved.\n"+result.warnings.prefix(10).joined(separator:"\n")
            await refresh()
        } catch { status = "Import stopped: \(error.localizedDescription). Completed conversations, if any, remain stored."; await refresh() }
    }
    func saveDossier() async {
        do { try await store.saveDossier(dossier); dossierDirty = false; revision += 1; status = "Dossier saved as a new version. Original messages were not changed." }
        catch { status = error.localizedDescription }
    }
}
