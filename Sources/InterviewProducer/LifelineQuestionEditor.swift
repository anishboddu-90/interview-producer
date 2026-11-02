import SwiftUI

struct LifelineQuestionEditor: View {
    var question: LifelineQuestion; var profileID: String; var controller: InterviewController; var onRemove: () -> Void
    private var current: LifelineQuestion { controller.questions.profile(profileID)?.questions.first { $0.id == question.id } ?? question }
    var body: some View {
        DisclosureGroup {
            VStack(alignment:.leading,spacing:10) {
                TextField("Full question",text:text(\.text),axis:.vertical).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Category",text:text(\.category)).textFieldStyle(.roundedBorder)
                    Stepper("Priority: \(current.priority)",value:Binding(get:{current.priority},set:{ value in edit { $0.priority = value } }),in:1...5)
                    Toggle("Essential",isOn:Binding(get:{current.essential},set:{ value in edit { $0.essential = value } }))
                }
                TextField("Optional conversational transition",text:optional(\.transition),axis:.vertical).textFieldStyle(.roundedBorder)
                TextField("Optional research context",text:optional(\.researchContext),axis:.vertical).textFieldStyle(.roundedBorder)
                TextField("Notes",text:optional(\.notes),axis:.vertical).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Status",selection:Binding(get:{current.status},set:{ value in perform { try controller.questions.setStatus(profileID,id:question.id,status:value) } })) { ForEach(QuestionStatus.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Manual status lock",isOn:Binding(get:{current.manualStatus},set:{ value in edit { $0.manualStatus = value } }))
                    Toggle("Save for later",isOn:Binding(get:{current.savedForLater},set:{ value in edit { $0.savedForLater = value } }))
                }
                HStack {
                    Button("Move up") { perform { try controller.questions.move(profileID,id:question.id,delta:-1) } }
                    Button("Move down") { perform { try controller.questions.move(profileID,id:question.id,delta:1) } }
                    Button("Duplicate") { perform { try controller.questions.duplicateQuestion(profileID,id:question.id) } }
                    Button("Remove",role:.destructive,action:onRemove)
                }
                Text("ID: \(question.id)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !current.statusHistory.isEmpty {
                    DisclosureGroup("Attributed status history (\(current.statusHistory.count))") {
                        ForEach(Array(current.statusHistory.enumerated()),id:\.offset) { _,entry in
                            VStack(alignment:.leading,spacing:4) {
                                Text("\(entry.status.rawValue) · \(entry.date.formatted()) · \(entry.explanation)").font(.caption)
                                if entry.questionFingerprint != current.fingerprint { Text("Receipt belongs to earlier question wording.").font(.caption).foregroundStyle(.orange) }
                                ForEach(entry.evidence) { receipt in Text(receipt.prompt).font(.caption).textSelection(.enabled) }
                            }.padding(.vertical,5)
                        }
                    }
                }
            }.padding(.top,10)
        } label: {
            VStack(alignment:.leading,spacing:4) { Text(current.text).font(.headline); Text("\(current.category) · priority \(current.priority) · \(current.status.rawValue)\(current.essential ? " · essential" : "")\(current.manualStatus ? " · manually locked" : "")").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:12))
    }
    private func text(_ path: WritableKeyPath<LifelineQuestion,String>) -> Binding<String> { .init(get:{current[keyPath:path]},set:{ value in edit { $0[keyPath:path] = value } }) }
    private func optional(_ path: WritableKeyPath<LifelineQuestion,String?>) -> Binding<String> { .init(get:{current[keyPath:path] ?? ""},set:{ value in edit { $0[keyPath:path] = value.isEmpty ? nil : value } }) }
    private func edit(_ change: (inout LifelineQuestion) -> Void) { perform { try controller.questions.updateQuestion(profileID,id:question.id,change:change) } }
    private func perform(_ operation: () throws -> Void) { do { try operation(); controller.synchronizeLifelineCard() } catch { controller.lifelineStatus = error.localizedDescription } }
}

struct LifelineProfileSettings: View {
    var profile: QuestionProfile; var controller: InterviewController
    private var current: LifelineSettings { controller.questions.profile(profile.id)?.settings ?? profile.settings }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Toggle("Automatic Question Lifeline — this profile only",isOn:Binding(get:{current.automatic},set:{ value in edit { $0.automatic = value } }))
            Text(current.automatic ? "Lull checks require both audio channels, a completed-answer review, healthy transcription and cooldown. Silence alone never triggers a card." : "Off. Next Question and the global shortcut remain available.").font(.caption).foregroundStyle(.secondary)
            if current.automatic {
                HStack {
                    Stepper("Silence: \(current.silenceSeconds)s",value:integer(\.silenceSeconds),in:6...60)
                    Stepper("Cooldown: \(current.cooldownSeconds)s",value:integer(\.cooldownSeconds),in:30...600,step:15)
                    Picker("Sensitivity",selection:Binding(get:{current.sensitivity},set:{ value in edit { $0.sensitivity = value } })) { Text("Conservative").tag("Conservative"); Text("Balanced").tag("Balanced") }
                }
            }
            Toggle("Remaining interview time is known",isOn:Binding(get:{current.remainingMinutes != nil},set:{ value in edit { $0.remainingMinutes = value ? 30 : nil } }))
            if current.remainingMinutes != nil { Stepper("Remaining: \(current.remainingMinutes ?? 30) minutes",value:Binding(get:{current.remainingMinutes ?? 30},set:{ value in edit { $0.remainingMinutes = value } }),in:1...240) }
        }.padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:12))
    }
    private func integer(_ path: WritableKeyPath<LifelineSettings,Int>) -> Binding<Int> { .init(get:{current[keyPath:path]},set:{ value in edit { $0[keyPath:path] = value } }) }
    private func edit(_ change: (inout LifelineSettings) -> Void) { do { try controller.questions.updateProfile(profile.id) { change(&$0.settings) }; controller.lifelineCache = nil } catch { controller.lifelineStatus = error.localizedDescription } }
}
struct LifelineShortcutSettings: View {
    var controller: InterviewController
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Toggle("Global Next Question shortcut",isOn:Binding(get:{controller.questions.state.shortcutEnabled},set:{update(enabled:$0)}))
                Picker("Modifiers",selection:Binding(get:{controller.questions.state.shortcutModifiers},set:{update(modifiers:$0)})) { ForEach(["Control+Option","Control+Shift","Command+Shift","Control+Option+Shift"],id:\.self) { Text($0) } }
                Picker("Key",selection:Binding(get:{controller.questions.state.shortcutKey},set:{update(key:$0)})) { ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init),id:\.self) { Text($0) } }.frame(width:90)
            }
            Text(controller.questionShortcut.status).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func update(key: String? = nil,modifiers: String? = nil,enabled: Bool? = nil) {
        let s = controller.questions.state
        do { try controller.questions.shortcut(key:key ?? s.shortcutKey,modifiers:modifiers ?? s.shortcutModifiers,enabled:enabled ?? s.shortcutEnabled); controller.configureQuestionShortcut() }
        catch { controller.lifelineStatus = error.localizedDescription }
    }
}
