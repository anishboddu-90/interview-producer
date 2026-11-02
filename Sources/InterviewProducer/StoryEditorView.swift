import SwiftUI
import UniformTypeIdentifiers

struct StoryEditorView: View {
    @Environment(InterviewController.self) private var controller
    @State private var tab = "Investigations"
    @State private var noteDrafts: [String:String] = [:]
    @State private var recordID: UUID?
    @State private var sourceDraft = ""
    @State private var backgroundDraft = ""
    @State private var includeRecord = true
    private var locked: Bool { controller.isRecording || controller.isStopping || controller.simulating || controller.processingReport || controller.stories.busy }
    var body: some View {
        @Bindable var controller = controller
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("Story Editor").font(.largeTitle.bold())
                Text("An open investigation into Harbor City's experimental underground. Evidence first; no predetermined protagonist, evolution or national thesis.").foregroundStyle(.secondary)
                Picker("Editorial workspace",selection:$tab) { ForEach(["Investigations","Pre-interview brief","Post-interview report","Coverage"],id:\.self) { Text($0) } }.pickerStyle(.segmented)
                if controller.stories.busy {
                    HStack { ProgressView().controlSize(.small); Text(controller.stories.progress) }
                } else { Text(controller.stories.status).font(.callout).foregroundStyle(.secondary) }
                if controller.isRecording { Text("Live follow-ups remain primary. Consequential leads are recorded silently; deeper analysis becomes available after capture stops.").font(.callout) }
                switch tab {
                case "Pre-interview brief": briefing
                case "Post-interview report": report
                case "Coverage": coverage
                default: investigations
                }
            }.padding(28).frame(maxWidth:1100,alignment:.leading)
        }.onAppear { controller.refreshArchive(); recordID = controller.record?.id; loadSource() }
    }
    private var investigations: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Subject · relationships · history · unexpected discoveries").font(.headline)
            Text("Directions compete; none is automatically selected as the article. Interesting quotes, leads, supported findings and provisional theses retain different labels. Previous testimony and current source coverage can be incomplete.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Review current interview against investigations") { Task { await controller.reviewInvestigations() } }.disabled(locked || controller.record?.lines.isEmpty != false)
                Spacer()
                Text("\(controller.archive.filter { !$0.simulation && $0.includeInStory != false }.count) eligible interviews").font(.caption)
            }
            ForEach(controller.stories.ledger.directions) { direction in
                DisclosureGroup {
                    VStack(alignment:.leading,spacing:12) {
                        TextField("Journalist's note or next reporting priority",text:Binding(get:{noteDrafts[direction.id] ?? direction.note},set:{noteDrafts[direction.id] = $0}),axis:.vertical).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save note") { save(direction,parked:direction.parked) }
                            Button(direction.parked ? "Resume investigation" : "Park investigation") { save(direction,parked:!direction.parked) }
                        }.disabled(locked)
                        if direction.updates.isEmpty { Text("Open question only; no evidence-supported lead recorded yet.").foregroundStyle(.secondary) }
                        ForEach(direction.updates.reversed()) { update in
                            VStack(alignment:.leading,spacing:9) {
                                Text(update.stage).font(.headline).foregroundStyle(.orange)
                                Text("\(update.contextLabel) · \(update.date.formatted())").font(.caption).foregroundStyle(.secondary)
                                Text(update.lead.question).font(.title3)
                                Text("Why it might matter: \(update.lead.why)")
                                if !update.lead.provisional_thesis.isEmpty { Text("Provisional thesis: \(update.lead.provisional_thesis)") }
                                Text("Originality: \(update.lead.originality)")
                                Text("Wider significance: \(update.lead.wider_significance)")
                                Text("Unverified / next reporting").font(.headline)
                                ForEach(Array(update.lead.unverified.enumerated()),id:\.offset) { _,q in Text("• \(q)") }
                                ForEach(Array(update.lead.next_sources.enumerated()),id:\.offset) { _,s in Text("\(s.name): \(s.contribution)") }
                                if !update.lead.coverage_refs.isEmpty { Text("Coverage: \(update.lead.coverage_refs.joined(separator:", "))").font(.caption) }
                                receipts(update.support,label:"Supporting original evidence")
                                receipts(update.opposition,label:"Opposing evidence / other accounts")
                            }.padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
                        }
                    }.padding(.top,12)
                } label: {
                    VStack(alignment:.leading,spacing:4) { Text(direction.title).font(.headline); Text("\(direction.id) · \(direction.updates.count) updates\(direction.parked ? " · parked" : "")").font(.caption).foregroundStyle(.secondary) }
                }.padding(14).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
            }
        }
    }
    private func receipts(_ receipts: [StoryReceipt],label: String) -> some View {
        DisclosureGroup("\(label) (\(receipts.count))") {
            ForEach(receipts) { receipt in
                VStack(alignment:.leading,spacing:5) {
                    if !controller.stories.isCurrent(receipt,records:controller.archive) { Text("Archived evidence snapshot — original interview changed, excluded or removed. Re-review before use.").font(.caption).foregroundStyle(.orange) }
                    Text(receipt.evidence.title).font(.headline)
                    Text("\(receipt.evidence.role) · \(receipt.evidence.classification)").font(.caption)
                    Text(receipt.quote).textSelection(.enabled)
                    Text("[\(receipt.evidence.id)] \(receipt.evidence.reference)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if let annotation = receipt.evidence.annotation { Text("Separate annotation: \(annotation)").font(.caption) }
                }.padding(.vertical,8)
            }
        }
    }
    private var briefing: some View {
        @Bindable var controller = controller
        return VStack(alignment:.leading,spacing:14) {
            TextField("Source name",text:$controller.plannedSource).textFieldStyle(.roundedBorder)
            TextField("What this person is positioned to know; your relationship; topics to test (optional)",text:$controller.plannedBackground,axis:.vertical).textFieldStyle(.roundedBorder)
            Text("Provide background you know. The editor won't invent a biography. Relevant local excerpts and the current investigations go to your existing selected model.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Generate source-specific brief") { Task { await controller.generateBrief() } }.buttonStyle(.borderedProminent).disabled(locked || controller.plannedSource.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if let brief = controller.stories.activeBrief { Button("Export brief…") { export(brief.markdown,name:"Pre-interview-brief.md") } }
            }
            if !controller.stories.ledger.briefs.isEmpty {
                Menu("Saved briefs") { ForEach(controller.stories.ledger.briefs.reversed()) { b in Button("\(b.source) · \(b.date.formatted())") { controller.stories.activeBrief = b } } }
            }
            if let brief = controller.stories.activeBrief {
                Text(brief.markdown).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                DisclosureGroup("Original sources available for this brief (\(brief.evidence.count))") {
                    ForEach(brief.evidence) { e in Text(e.prompt).font(.caption).textSelection(.enabled).padding(.vertical,5) }
                }
            }
        }.disabled(controller.isRecording || controller.isStopping)
    }
    private var report: some View {
        VStack(alignment:.leading,spacing:14) {
            Picker("Interview",selection:$recordID) {
                Text("Choose interview").tag(Optional<UUID>.none)
                ForEach(controller.archive) { r in Text("\(StoryEvidence.source(r)) · \(r.date.formatted())\(r.simulation ? " · synthetic" : "")").tag(Optional(r.id)) }
            }.disabled(locked).onChange(of:recordID) {
                if let r = controller.archive.first(where:{$0.id == recordID}) { controller.openRecord(r); loadSource() }
            }
            if let record = controller.record {
                TextField("Source name (one person's account per interview)",text:$sourceDraft).textFieldStyle(.roundedBorder)
                TextField("Source background",text:$backgroundDraft,axis:.vertical).textFieldStyle(.roundedBorder)
                Toggle("Use this interview for cross-source continuity",isOn:$includeRecord)
                Button("Save source attribution") { controller.updateSource(name:sourceDraft,background:backgroundDraft,included:includeRecord) }.disabled(locked)
                Text("\(record.lines.count) transcript turns. Quoted speech remains attributed testimony. Long interviews use sequential evidence selection from every packet, then one final report; at most 21 existing-provider requests. Oversized interviews fail explicitly rather than silently skipping content.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Generate seven-part editorial report") { Task { await controller.generateReport() } }.buttonStyle(.borderedProminent).disabled(locked || record.lines.isEmpty)
                    if !record.notes.isEmpty { Button("Export report…") { export(record.notes,name:"Editorial-report.md") } }
                }
                if let report = record.storyReport {
                    if report.interviewFingerprint != StoryEvidence.fingerprint(record) { Text("The source attribution or transcript changed after this report. Regenerate it before relying on the analysis.").foregroundStyle(.orange) }
                    Text("Analysis scope: \(report.scope)").font(.caption).foregroundStyle(.secondary)
                }
                if !record.notes.isEmpty { Text(record.notes).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
            }
            Divider()
            Text("Import another source's interview").font(.headline)
            Text("Import an Interview Producer JSON export (its source name is preserved), or set the source name in Pre-interview brief before importing UTF-8 text with [mm:ss] Interviewee: / [mm:ss] Journalist: turns. Audio capture is not required for importing.").font(.callout).foregroundStyle(.secondary)
            Button("Import transcript and analyze…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.json,.plainText]; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try controller.importInterview(url); recordID = controller.record?.id; loadSource(); Task { await controller.generateReport() } }
                catch { controller.message = error.localizedDescription }
            }.disabled(locked)
        }
    }
    private var coverage: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Originality requires comparing actual reporting").font(.title2)
            Text("These references came from your brief. Their descriptions constrain novelty; their full contents are unverified here. Import actual articles or a documentary transcript in Research. The editor receives relevant original excerpts alongside these labels; a filename or URL alone never verifies a claim.").foregroundStyle(.secondary)
            ForEach(EditorialProfile.coverage) { source in
                VStack(alignment:.leading,spacing:8) {
                    Text(source.title).font(.headline)
                    if let url = URL(string:source.url), !source.url.isEmpty { Link("Open publication reference",destination:url) }
                    Text(source.coverage).font(.callout)
                    Text("[\(source.id)] · coverage description; actual contents unverified").font(.caption).foregroundStyle(.orange)
                }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
            }
            Text("\(controller.research.documents.count) supplied research documents. Labels and excerpts are retained separately; imported summaries are not full article text.").font(.caption)
        }
    }
    private func loadSource() {
        sourceDraft = controller.record?.sourceName ?? ""; backgroundDraft = controller.record?.sourceBackground ?? ""; includeRecord = controller.record?.includeInStory != false
    }
    private func save(_ d: StoryDirection,parked: Bool) {
        do { try controller.stories.edit(id:d.id,note:noteDrafts[d.id] ?? d.note,parked:parked) }
        catch { controller.message = error.localizedDescription }
    }
    private func export(_ text: String,name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to:url,atomically:true,encoding:.utf8) } catch { controller.message = error.localizedDescription }
    }
}
