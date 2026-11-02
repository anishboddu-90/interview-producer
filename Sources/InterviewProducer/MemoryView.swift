import SwiftUI
import UniformTypeIdentifiers

struct MemoryView: View {
    @Environment(InterviewController.self) private var controller
    @State private var mode = "Search"
    @State private var query = ""
    @State private var includeExcluded = false
    @State private var selectedConversation = ""
    @State private var selectedBranch = ""
    @State private var branches = [(String,Bool)]()
    @State private var messages = [MemoryMessage]()
    @State private var selectedMessage: MemoryMessage?
    @State private var importSession: MemoryImportSession?
    @State private var reading = false
    @State private var deleteID: String?
    private var memory: MemoryLibrary { controller.memory }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("Conversation memory").font(.title.bold())
                    Text("Verbatim history and separate corrections. Relevant excerpts go to your selected AI automatically during interviews.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(reading ? "Reading export…" : "Import ChatGPT export…") { chooseExport() }
                    .disabled(reading || memory.busy || controller.isRecording || controller.isStopping)
            }
            Picker("Memory view",selection:$mode) { ForEach(["Search","Conversations","Active dossier"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            if mode == "Active dossier" { dossierView }
            else {
                HSplitView {
                    VStack(alignment:.leading,spacing:10) {
                        if mode == "Search" { searchView } else { conversationView }
                    }.frame(minWidth:230,idealWidth:300,maxWidth:370)
                    Group {
                        if let selectedMessage {
                            MemoryMessageInspector(message:selectedMessage,store:memory.store,readOnly:controller.isRecording) {
                                memory.revision += 1
                                Task { await reloadMessages() }
                            } onError: { memory.status = $0 }
                            .id(selectedMessage.conversationID+selectedMessage.nodeID)
                        } else {
                            ContentUnavailableView("Inspect original messages",systemImage:"text.magnifyingglass",description:Text("Select a passage or conversation turn. Corrections are annotations; original wording is never overwritten."))
                        }
                    }.frame(minWidth:300,maxWidth:.infinity,maxHeight:.infinity)
                }
            }
            Text(memory.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
        }.padding(22)
        .task { await memory.refresh() }
        .sheet(item:$importSession) { session in
            MemoryImportPreview(session:session,memory:memory) { importSession = nil }
        }
        .confirmationDialog("Delete this conversation and every stored branch and indexed passage?",isPresented:Binding(get:{deleteID != nil},set:{if !$0 { deleteID = nil }})) {
            Button("Delete imported conversation",role:.destructive) {
                guard let id = deleteID else { return }; deleteID = nil
                Task {
                    do { try await memory.store.deleteConversation(id); memory.revision += 1; selectedMessage = nil; messages = []; selectedConversation = ""; await memory.refresh(); memory.status = "Conversation deleted from local memory and search. Original export files and evidence already saved in interview records were not changed." }
                    catch { memory.status = error.localizedDescription }
                }
            }
        }
    }
    private var searchView: some View {
        VStack(alignment:.leading,spacing:10) {
            TextField("Search names, recordings, plans…",text:$query).textFieldStyle(.roundedBorder)
            Toggle("Inspect excluded / hidden material",isOn:$includeExcluded).font(.caption)
            Text("Search can inspect alternate branches. Live retrieval uses the active path unless you enable alternatives or explicitly pin a message.").font(.caption).foregroundStyle(.secondary)
            List(memory.hits) { hit in
                Button { Task { await inspect(hit) } } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text(hit.title).font(.headline)
                        Text("\(hit.role) · \(hit.classification)").font(.caption).foregroundStyle(.secondary)
                        Text(hit.excerpt).font(.callout).lineLimit(5)
                    }.padding(.vertical,5)
                }.buttonStyle(.plain)
            }
        }
        .task(id:query+"|\(includeExcluded)|\(memory.revision)") {
            do { try await Task.sleep(for:.milliseconds(200)); try Task.checkCancellation() } catch { return }
            await memory.search(query,includeExcluded:includeExcluded)
        }
    }
    private var conversationView: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("\(memory.conversations.count) stored snapshots").font(.caption).foregroundStyle(.secondary)
            Picker("Conversation",selection:$selectedConversation) {
                Text("Choose a conversation").tag("")
                ForEach(memory.conversations) { c in Text(conversationLabel(c)).tag(c.id) }
            }.onChange(of:selectedConversation) { Task { await selectConversation() } }
            if let c = memory.conversations.first(where:{$0.id == selectedConversation}) {
                Text("\(c.messages) messages · \(c.branches) branches\(c.excluded ? " · excluded" : "")").font(.caption)
                Picker("Branch",selection:$selectedBranch) {
                    Text("All nodes — tree traversal order").tag("")
                    ForEach(branches,id:\.0) { b in Text((b.1 ? "Active: " : "Alternate: ")+String(b.0.prefix(18))).tag(b.0) }
                }.onChange(of:selectedBranch) { Task { await reloadMessages() } }
                Menu("Conversation controls") {
                    Button(c.excluded ? "Include in live retrieval" : "Exclude from live retrieval") { changeConversation(c,excluded:!c.excluded,alternatives:c.includeAlternatives) }
                    Button(c.includeAlternatives ? "Use only active branch" : "Allow alternate branches in retrieval") { changeConversation(c,excluded:c.excluded,alternatives:!c.includeAlternatives) }
                    Button("Export original selected JSON…") { exportOriginal(c) }
                    Button("Delete imported conversation",role:.destructive) { deleteID = c.id }
                }.disabled(controller.isRecording || memory.busy)
            }
            List(messages.filter { $0.role != "none" }) { item in
                Button { selectedMessage = item } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text("\(item.role)\(item.active ? " · active path" : " · alternate/unresolved")\(item.pinned ? " · pinned" : "")\(item.excluded ? " · excluded" : "")").font(.caption).foregroundStyle(.secondary)
                        Text(item.text.isEmpty ? "[Non-text content: inspect original JSON]" : item.text).lineLimit(4)
                    }.padding(.vertical,4)
                }.buttonStyle(.plain)
            }
        }
    }
    private var dossierView: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("A small, journalist-edited working document. Include original source references for facts. This supplements the complete archive; the app never summarizes over your original messages.").foregroundStyle(.secondary)
            TextEditor(text:Binding(get:{memory.dossier},set:{memory.dossier = $0; memory.dossierDirty = true})).font(.body.monospaced()).frame(minHeight:300)
            HStack {
                Text("\(memory.dossier.count) / 6,000 characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save dossier version") { Task { await memory.saveDossier() } }.disabled(controller.isRecording || memory.dossier.count > 6000)
            }
        }
    }
    private func conversationLabel(_ c: MemoryConversation) -> String {
        let date = c.created.map { Date(timeIntervalSince1970:$0).formatted(date:.numeric,time:.omitted) } ?? "undated"
        return "\(c.title) · \(date) · \(c.id.prefix(6))"
    }
    private func chooseExport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json,.zip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reading = true; memory.status = "Reading export locally. Nothing will be imported until you select conversations."
        Task {
            do { let session = try await Task.detached(priority:.utility) { try ChatGPTExportReader.open(url) }.value; memory.status = "\(session.conversations.count) conversations ready for local review; none imported yet."; importSession = session }
            catch { memory.status = error.localizedDescription }
            reading = false
        }
    }
    private func selectConversation() async {
        do {
            branches = try await memory.store.branches(conversation:selectedConversation)
            selectedBranch = branches.first(where:{$0.1})?.0 ?? ""
            await reloadMessages()
        } catch { memory.status = error.localizedDescription }
    }
    private func reloadMessages() async {
        guard !selectedConversation.isEmpty else { messages = []; return }
        do { messages = try await memory.store.messages(conversation:selectedConversation,branch:selectedBranch.isEmpty ? nil : selectedBranch) }
        catch { memory.status = error.localizedDescription }
    }
    private func inspect(_ hit: ResearchEvidence) async {
        guard let conv = hit.conversationID, let node = hit.nodeID else { return }
        do { selectedMessage = try await memory.store.messages(conversation:conv).first { $0.nodeID == node } }
        catch { memory.status = error.localizedDescription }
    }
    private func changeConversation(_ c: MemoryConversation,excluded: Bool,alternatives: Bool) {
        Task { do { try await memory.store.setConversation(c.id,excluded:excluded,alternatives:alternatives); memory.revision += 1; await memory.refresh() } catch { memory.status = error.localizedDescription } }
    }
    private func exportOriginal(_ c: MemoryConversation) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ChatGPT-original-conversation.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { let raw = try await memory.store.originalConversation(c.id); try (Data("[\n".utf8)+raw+Data("\n]\n".utf8)).write(to:url,options:.atomic); memory.status = "Original JSON exported without modifying the conversation object bytes." } catch { memory.status = error.localizedDescription } }
    }
}

private struct MemoryMessageInspector: View {
    let message: MemoryMessage; let store: ConversationMemory; let readOnly: Bool
    var onSaved: () -> Void; var onError: (String) -> Void
    @State private var kind = ""; @State private var note = ""; @State private var sourceURL = ""
    @State private var threadStatus = ""; @State private var pinned = false; @State private var excluded = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Text("Original \(message.role) message").font(.headline)
                Text(message.created.map { Date(timeIntervalSince1970:$0).formatted(date:.complete,time:.standard) } ?? "Original date not supplied").font(.caption).foregroundStyle(.secondary)
                Text("Node: \(message.nodeID)\nParent: \(message.parentID ?? "root")\n\(message.active ? "Active path at export" : "Alternate/unresolved branch")\(message.hidden ? " · hidden in original export" : "")").font(.caption.monospaced()).textSelection(.enabled)
                Text(message.text.isEmpty ? "[No text part. Complete content and metadata are preserved in the JSON below.]" : message.text).textSelection(.enabled).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                DisclosureGroup("Original node JSON / content parts / metadata") { Text(message.originalJSON).font(.caption.monospaced()).textSelection(.enabled) }
                Divider()
                Text("Separate annotations — original wording stays unchanged").font(.headline)
                Picker("Classification",selection:$kind) { ForEach(MemoryKind.allCases,id:\.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                TextEditor(text:$note).font(.callout).frame(height:95).overlay(alignment:.topLeading) { if note.isEmpty { Text("Your correction, disagreement, or verification note").foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) } }
                TextField("Source URL / verification reference",text:$sourceURL).textFieldStyle(.roundedBorder)
                Picker("Question/thread status",selection:$threadStatus) {
                    Text("Unspecified").tag(""); Text("Open").tag("open"); Text("Answered").tag("answered"); Text("Disputed").tag("disputed")
                }
                Toggle("Pin as a live retrieval priority",isOn:$pinned)
                Toggle("Exclude this message from retrieval",isOn:$excluded)
                Text("An assistant reply is not a verified fact. Marking a source verified requires its URL and your verification note. Exclusion also removes the message from retrieved surrounding context.").font(.caption).foregroundStyle(.secondary)
                Button("Save annotation") {
                    let annotation = MemoryAnnotation(kind:kind,note:note,sourceURL:sourceURL,threadStatus:threadStatus,pinned:pinned,excluded:excluded)
                    Task { do { try await store.annotate(conversation:message.conversationID,node:message.nodeID,annotation:annotation); onSaved(); onError("Annotation saved; original message unchanged.") } catch { onError(error.localizedDescription) } }
                }.disabled(readOnly)
            }.padding(14)
        }.onAppear { kind = message.kind; note = message.note; sourceURL = message.sourceURL; threadStatus = message.threadStatus; pinned = message.pinned; excluded = message.excluded }
    }
}

private struct MemoryImportPreview: View {
    let session: MemoryImportSession; let memory: MemoryLibrary; var close: () -> Void
    @State private var selected = Set<String>(); @State private var filter = ""; @State private var previewText = ""
    private var visible: [ExportConversationPreview] { session.conversations.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Select conversations to preserve").font(.title2.bold())
            Text("Nothing is selected automatically. Each selected conversation is stored locally in full, including alternate branches, timestamps, metadata and exact message wording. Import and indexing stay local. During interviews only retrieved passages go to the selected cloud AI; the full export is never uploaded.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Filter conversation titles",text:$filter); Button("Select visible") { selected.formUnion(visible.map(\.id)) }; Button("Clear") { selected = [] } }
            List(visible) { item in
                HStack(alignment:.top) {
                    Toggle(isOn:Binding(get:{selected.contains(item.id)},set:{if $0 { selected.insert(item.id) } else { selected.remove(item.id) }})) {
                        VStack(alignment:.leading,spacing:4) {
                            Text(item.title)
                            Text("\(item.messageCount) messages · \(item.branchCount) branch paths · \(item.created.map { Date(timeIntervalSince1970:$0).formatted(date:.numeric,time:.omitted) } ?? "undated")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Preview") {
                        Task {
                            do {
                                previewText = try await Task.detached(priority:.utility) {
                                    let raw = try ChatGPTExportReader.raw(item)
                                    let root = try JSONSerialization.jsonObject(with:raw) as! [String:Any]
                                    let graph = try ExportGraph(root:root)
                                    let text = graph.order.compactMap { id -> String? in
                                        let node = graph.mapping[id]!, message = node["message"] as? [String:Any] ?? [:]
                                        guard let role = (message["author"] as? [String:Any])?["role"] as? String else { return nil }
                                        return "[\(role); node \(id); \(graph.activeNodes.contains(id) ? "active" : "alternate/unresolved")]\n\(ChatGPTExportReader.text(message))"
                                    }.joined(separator:"\n\n")
                                    return String(text.prefix(40000))+(text.count > 40000 ? "\n[Preview display limit only; import preserves the full original.]" : "")
                                }.value
                            } catch { previewText = error.localizedDescription }
                        }
                    }
                }.padding(.vertical,4)
            }
            if !previewText.isEmpty { ScrollView { Text(previewText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:150) }
            HStack {
                Text("\(selected.count) selected / \(session.conversations.count) conversations").font(.caption)
                Spacer(); Button("Cancel") { memory.status = "Import preview cancelled; no new conversations stored."; close() }.disabled(memory.busy)
                Button(memory.busy ? "Importing locally…" : "Import selected") { Task { await memory.importSelected(session,ids:selected); close() } }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || memory.busy)
            }
        }.padding(22).frame(width:790,height:620).interactiveDismissDisabled(memory.busy)
    }
}
