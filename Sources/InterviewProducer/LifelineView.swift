import SwiftUI
import UniformTypeIdentifiers

struct LifelineCard: View {
    var card: SavedLifeline; var controller: InterviewController
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("NEXT QUESTION",systemImage:"questionmark.bubble").font(.caption.bold()).foregroundStyle(.cyan)
            Text("Category: \(card.question.category)").font(.caption).foregroundStyle(.secondary)
            if !card.bridge.isEmpty { Text(card.bridge).font(.callout).foregroundStyle(.secondary) }
            Text(card.question.text).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack {
                Button("Asked") { controller.lifelineAction("asked") }
                Button("Another") { controller.nextQuestion(another:true) }
                Button("Save") { controller.lifelineAction("save") }
                Button("Dismiss") { controller.lifelineAction("dismissed") }
            }.buttonStyle(.bordered).disabled(controller.lifelineBusy)
            Button("Skip this question") { controller.lifelineAction("skip") }.font(.caption)
            DisclosureGroup("Why this question / sources") {
                Text(card.reason).font(.callout).textSelection(.enabled)
                Text("Mode: \(card.mode)").font(.caption).foregroundStyle(.secondary)
                ForEach(card.evidence) { e in Text(e.prompt).font(.caption).textSelection(.enabled).padding(.vertical,4) }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct LifelineRemainingQuestions: View {
    var controller: InterviewController
    var body: some View {
        if let profile = controller.lifelineProfile {
            let groups = Dictionary(grouping:profile.questions.filter(\.eligible),by:\.category)
            if groups.isEmpty { Text("No available questions. Change a status or select another profile.").font(.caption) }
            ForEach(groups.keys.sorted(),id:\.self) { category in
                Text(category).font(.caption.bold()).padding(.top,5)
                ForEach(groups[category] ?? []) { q in
                    VStack(alignment:.leading,spacing:5) {
                        Text(q.text).font(.callout)
                        HStack {
                            Text("\(q.status.rawValue)\(q.essential ? " · essential" : "")").font(.caption2).foregroundStyle(.secondary)
                            Button("Mark asked") { controller.setQuestionStatus(profile:profile.id,id:q.id,status:.asked) }
                        }
                    }.padding(.vertical,5)
                }
            }
        } else { Text("Choose a profile in Question Lifeline.").font(.caption) }
    }
}

struct LifelineView: View {
    @Environment(InterviewController.self) private var controller
    @State private var confirmRemove: String?
    @State private var confirmProfileRemove = false
    private var library: LifelineLibrary { controller.questions }
    private var locked: Bool { controller.isStarting || controller.isRecording || controller.isStopping || controller.simulating || controller.lifelineBusy }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("Question Lifeline").font(.largeTitle.bold())
                Text("Prepared questions for this source. Your bank, edits and statuses autosave locally; other profiles keep their own questions and automatic setting.").foregroundStyle(.secondary)
                HStack {
                    Picker("Interview profile",selection:Binding(get:{library.state.selectedProfileID},set:{controller.selectQuestionProfile($0)})) {
                        Text("No profile").tag(Optional<String>.none)
                        ForEach(library.state.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                    }.disabled(locked)
                    Button("New profile") { perform { try library.addProfile(.init(name:"New interview profile")); controller.selectQuestionProfile(library.state.selectedProfileID) } }.disabled(locked)
                    Button("Import profile…") { importBank(into:nil) }.disabled(locked)
                }
                if !library.error.isEmpty { Text(library.error).foregroundStyle(.red).textSelection(.enabled) }
                Text(controller.lifelineStatus).font(.callout).foregroundStyle(.secondary)
                if let profile = library.selected {
                    profileEditor(profile)
                    LifelineProfileSettings(profile:profile,controller:controller)
                    HStack {
                        Button(controller.lifelineBusy ? "Choosing…" : "Next Question") { controller.nextQuestion() }.buttonStyle(.borderedProminent).disabled(controller.lifelineBusy || controller.activeSuggestion != nil)
                        Button("Show private overlay") { ProducerPanel.shared.showControls(controller:controller) }
                        Button("Reset deferred pass") { controller.lifelineExcluded = []; controller.lifelineCache = nil; controller.lifelineStatus = "Deferred questions are available again; asked/answered/skipped statuses are unchanged." }
                    }
                    if let card = controller.activeLifeline { LifelineCard(card:card,controller:controller).padding(16).background(.cyan.opacity(0.07),in:RoundedRectangle(cornerRadius:12)) }
                    HStack {
                        Text("\(profile.questions.count) questions · \(profile.questions.filter(\.eligible).count) available/suggested").font(.headline)
                        Spacer()
                        Button("Add question") { perform { try library.updateProfile(profile.id) { $0.questions.append(.init(text:"New question?")) } } }
                        Button("Import questions…") { importBank(into:profile.id) }
                        Menu("Export") { Button("JSON") { export(profile,format:"json") }; Button("Markdown") { export(profile,format:"md") } }
                    }.disabled(controller.isStopping)
                    Text("Manual statuses are protected from AI changes. Unlock a status to allow automatic answer detection. A substantive answer requires a current interviewee quote; a brief mention is insufficient.").font(.caption).foregroundStyle(.secondary)
                    ForEach(profile.questions) { q in
                        LifelineQuestionEditor(question:q,profileID:profile.id,controller:controller,onRemove:{confirmRemove = q.id})
                    }
                }
                Divider()
                LifelineShortcutSettings(controller:controller)
            }.padding(28).frame(maxWidth:1100,alignment:.leading)
        }.confirmationDialog("Remove this question from the profile?",isPresented:Binding(get:{confirmRemove != nil},set:{if !$0 { confirmRemove = nil }})) {
            Button("Remove question",role:.destructive) {
                guard let id = confirmRemove, let p = library.selected else { return }; perform { try library.updateProfile(p.id) { $0.questions.removeAll { $0.id == id } } }; confirmRemove = nil
            }
        }.confirmationDialog("Remove this question profile? Export it first if you want to reuse it.",isPresented:$confirmProfileRemove) {
            Button("Remove profile",role:.destructive) { if let p = library.selected { perform { try library.removeProfile(p.id); controller.selectQuestionProfile(nil) } } }
        }
    }
    private func profileEditor(_ profile: QuestionProfile) -> some View {
        VStack(alignment:.leading,spacing:9) {
            TextField("Profile name",text:profileText(profile.id,\.name)).textFieldStyle(.roundedBorder)
            TextField("Source name (blank only for an intentionally reusable profile)",text:profileText(profile.id,\.source)).textFieldStyle(.roundedBorder).disabled(locked)
            HStack {
                Button("Duplicate for a new interview") { perform { try library.duplicateProfile(profile.id); controller.selectQuestionProfile(library.state.selectedProfileID) } }.disabled(locked)
                Button("Remove profile",role:.destructive) { confirmProfileRemove = true }.disabled(locked)
                Spacer(); Text("Autosaved on every edit").font(.caption).foregroundStyle(.secondary)
            }
            if let record = controller.record, record.questionProfileID != profile.id {
                Text("This profile is not attached to the open interview. Other interviewees do not inherit its bank.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private func profileText(_ id: String,_ path: WritableKeyPath<QuestionProfile,String>) -> Binding<String> {
        .init(get:{library.profile(id)?[keyPath:path] ?? ""},set:{ value in perform { try library.updateProfile(id) { $0[keyPath:path] = value } } })
    }
    private func perform(_ operation: () throws -> Void) { do { try operation(); controller.synchronizeLifelineCard() } catch { controller.lifelineStatus = error.localizedDescription } }
    private func importBank(into: String?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json,.plainText,UTType(filenameExtension:"md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try library.importBank(url,into:into); if into == nil { controller.selectQuestionProfile(library.state.selectedProfileID) } }
    }
    private func export(_ profile: QuestionProfile,format: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Question-bank.\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try QuestionBankIO.export(profile,format:format).write(to:url,options:.atomic) }
    }
}
