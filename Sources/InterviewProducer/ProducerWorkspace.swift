import SwiftUI
import UniformTypeIdentifiers

struct ProducerWorkspace: View {
    @Environment(InterviewController.self) private var controller
    @State private var page = "Interview"
    @State private var consent = false
    @State private var confirmDelete = false
    @State private var researchKind = "Published coverage (user supplied)"
    @State private var sourceURL = ""
    @State private var verificationNote = ""
    @State private var primaryConfirmed = false
    @State private var showHistory = false
    @State private var transcriptSearch = ""
    @AppStorage("producer.sensitivity",store:ProducerDefaults.shared) private var sensitivity = "Balanced"
    @AppStorage("producer.cooldown",store:ProducerDefaults.shared) private var cooldown = 35
    @AppStorage("producer.showPanel",store:ProducerDefaults.shared) private var showPanel = true
    @AppStorage("producer.autoNotes",store:ProducerDefaults.shared) private var autoNotes = true
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:20) {
                Label("Interview Producer",systemImage:"waveform").font(.title3.bold())
                Text("INTERVIEWS · RESEARCH · FOLLOW-UPS").font(.caption.monospaced()).foregroundStyle(.secondary)
                ForEach(["Interview","Interview setup","Question Lifeline","Story Editor","Connection","Research","Memory","Archive"],id:\.self) { item in
                    Button { page = item } label: { Text(item).frame(maxWidth:.infinity,alignment:.leading).padding(8) }.buttonStyle(.bordered).tint(page == item ? .orange : .gray)
                }
                Spacer()
                Text("Your topic. Your questions.\nEvidence before interpretation.").font(.callout).foregroundStyle(.secondary)
                Text("Derived from Parrot · GPL-3.0").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18).navigationSplitViewColumnWidth(min:190,ideal:210,max:260)
        } detail: {
            Group {
                switch page {
                case "Interview setup": InterviewSetupView()
                case "Connection": ProducerConnectionView()
                case "Question Lifeline": LifelineView()
                case "Story Editor": StoryEditorView()
                case "Research": researchView
                case "Memory": MemoryView()
                case "Archive": archiveView
                default: interviewView
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:900,minHeight:650)
        .safeAreaInset(edge:.top,spacing:0) {
            if !controller.message.isEmpty {
                HStack(alignment:.top,spacing:12) {
                    Image(systemName:"info.circle")
                    Text(controller.message).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Button("Dismiss message") { controller.message = "" }
                }.padding(12).background(.orange.opacity(0.14))
            }
        }
        .confirmationDialog("Delete this interview, audio, transcript and suggestions permanently?",isPresented:$confirmDelete) {
            Button("Delete interview",role:.destructive) { do { try controller.deleteCurrent() } catch { controller.message = error.localizedDescription } }
        }
        .onChange(of:showPanel) { if !showPanel { ProducerPanel.shared.hide() } }
    }
    private var interviewView: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text("A second set of ears.").font(.largeTitle.weight(.semibold))
                        Text(controller.record.map(StoryEvidence.source) ?? "Set a topic and goals in Interview setup").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.isRecording { Label("REC \(Int(controller.elapsed)/60):\(String(format:"%02d",Int(controller.elapsed)%60))",systemImage:"record.circle.fill").foregroundStyle(.red).font(.headline.monospacedDigit()) }
                }
                if !controller.isStarting && !controller.isRecording && !controller.isStopping {
                    VStack(alignment:.leading,spacing:10) {
                        TextField("Interviewee name (for attribution)",text:Binding(get:{controller.plannedSource},set:{controller.plannedSource = $0})).textFieldStyle(.roundedBorder)
                        Toggle("I obtained consent to record and send audio to the selected transcription provider and transcript plus relevant research/memory excerpts to the selected AI provider.",isOn:$consent)
                        Text("Use headphones. Choose your audio source and microphone in Interview setup. Suggestions have no audio output. Keep screen sharing off, or share only a separate application window; full desktop sharing can expose private overlays.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Start interview") { Task { await controller.start(consent:consent); if controller.isRecording { consent = false } } }.buttonStyle(.borderedProminent).tint(.orange).disabled(!consent || controller.testing || controller.isStarting || controller.simulating || controller.processingReport || controller.stories.busy)
                            Menu(controller.testing ? "Running rehearsal…" : "Simulation") {
                                Button("Full automatic rehearsal (local, no microphone)") { Task { await controller.runAutomaticRehearsal() } }
                                Button("Full rehearsal (generated speech, current cloud)") { Task { await controller.runAutomaticRehearsal(live:true) } }
                                Button("Offline fixture replay (no AI)") { Task { await controller.simulate(live:false) } }
                                Button("Synthetic interview with real AI") { Task { await controller.simulate(live:true) } }
                            }.disabled(controller.processingReport || controller.simulating || controller.stories.busy || controller.testing)
                        }
                    }.padding(16).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
                }
                if !controller.rehearsalStatus.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Text(controller.rehearsalStatus).font(.callout).textSelection(.enabled)
                        if let url = controller.rehearsalResultsURL {
                            Button("Open rehearsal results") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                HStack {
                    if controller.isStarting || controller.isRecording || controller.isStopping || controller.simulating {
                        Button(controller.isStarting ? "Cancel starting interview" : controller.isStopping ? "Capture stopped · finishing transcript…" : "Stop capture now") { Task { await controller.stop() } }.buttonStyle(.borderedProminent).tint(.red).disabled(controller.isStopping)
                    }
                    Button(controller.alertsMuted ? "Resume analysis" : "Mute analysis") { controller.toggleMute() }
                    Button("Retry analysis") { controller.retryAnalysis() }.disabled((controller.record?.lines.isEmpty ?? true) || controller.stories.busy)
                    Spacer()
                    Picker("Sensitivity",selection:$sensitivity) { ForEach(ProducerSensitivity.allCases,id:\.rawValue) { Text($0.rawValue).tag($0.rawValue) } }.frame(width:220)
                }
                VStack(alignment:.leading,spacing:5) {
                    Label(controller.editorStatus,systemImage:"sparkle")
                    Label(controller.transcriptionStatus,systemImage:"text.bubble")
                    if controller.isRecording {
                        Text("Mic: \(controller.audio.inputDeviceName) · Zoom output: \(controller.audio.outputDeviceName)").font(.caption)
                        HStack { Text("Mic"); ProgressView(value:Double(min(1,controller.audio.micLevel*10))).frame(width:110); Text("Zoom"); ProgressView(value:Double(min(1,controller.audio.audioLevel*10))).frame(width:110) }
                        if !controller.audio.micActive || controller.audio.micSignalLost { Text("Microphone signal is unavailable. Check macOS input and permission.").foregroundStyle(.red) }
                    }
                }.font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(controller.lifelineBusy ? "Choosing next question…" : "Next Question") { controller.nextQuestion() }.buttonStyle(.borderedProminent).disabled(controller.lifelineBusy || controller.activeSuggestion != nil)
                    Text(controller.lifelineProfile?.name ?? "No question profile attached").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit question bank") { page = "Question Lifeline" }
                }
                Text(controller.lifelineStatus).font(.caption).foregroundStyle(.secondary)
                if controller.activeSuggestion == nil, let card = controller.activeLifeline { LifelineCard(card:card,controller:controller).padding(16).background(.cyan.opacity(0.07),in:RoundedRectangle(cornerRadius:14)) }
                DisclosureGroup("All Questions") { LifelineRemainingQuestions(controller:controller) }
                if let suggestion = controller.activeSuggestion { SuggestionCard(suggestion:suggestion,controller:controller).padding(18).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:14)) }
                else { Text("Quiet by default. An important unresolved reporting opportunity will appear here.").foregroundStyle(.secondary).padding(.vertical,10) }
                HStack {
                    Toggle("Floating panel",isOn:$showPanel).toggleStyle(.switch).frame(width:160)
                    Stepper("Cooldown: \(cooldown)s",value:$cooldown,in:10...180,step:5).frame(width:210)
                    Spacer()
                    Button("Closing checklist") { controller.showClosing.toggle() }
                }.font(.callout)
                Toggle("Generate editorial notes automatically after stop",isOn:$autoNotes).font(.callout)
                if controller.showClosing { closingView }
                DisclosureGroup("Suggestion history (\(controller.record?.suggestions.count ?? 0))",isExpanded:$showHistory) {
                    ForEach(controller.record?.suggestions.reversed() ?? [].reversed()) { item in
                        VStack(alignment:.leading) { Text(item.decision.suggested_question); Text("\(item.status) · \(item.decision.reason)").font(.caption).foregroundStyle(.secondary); SuggestionEvidenceView(suggestion:item) }.padding(.vertical,6)
                    }
                }
                if controller.record != nil {
                    HStack {
                        Text("Transcript").font(.headline)
                        Spacer()
                        TextField("Search transcript",text:$transcriptSearch).textFieldStyle(.roundedBorder).frame(width:220)
                    }
                    transcriptView
                    HStack {
                        Button(controller.processingReport ? "Writing editorial notes…" : "Generate editorial notes") { Task { await controller.generateReport() } }.disabled(controller.isRecording || controller.isStopping || controller.processingReport || controller.stories.busy || (controller.record?.lines.isEmpty ?? true))
                        Menu("Export") { ForEach(["md","txt","json"],id:\.self) { format in Button(format.uppercased()) { export(format) } } }
                        Spacer()
                        Button("Delete interview",role:.destructive) { confirmDelete = true }.disabled(controller.isRecording || controller.isStopping || controller.processingReport)
                    }
                    if let notes = controller.record?.notes, !notes.isEmpty { Text(notes).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:12)) }
                }
            }.padding(28).frame(maxWidth:1100,alignment:.leading)
        }
    }
    private var transcriptView: some View {
        LazyVStack(alignment:.leading,spacing:12) {
            ForEach((controller.record?.lines ?? []).filter { transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearch) }) { line in
                VStack(alignment:.leading,spacing:4) {
                    Text("\(line.stamp)  \(line.speaker.label)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    TextField("Transcript",text:Binding(get:{controller.record?.lines.first(where:{$0.id == line.id})?.text ?? line.text},set:{ value in if let i = controller.record?.lines.firstIndex(where:{$0.id == line.id}) { controller.record?.lines[i].text = value; controller.persist() } }),axis:.vertical).textFieldStyle(.plain).disabled(controller.isRecording)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
    private var closingView: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Unanswered threads & saved follow-ups").font(.headline)
            ForEach((controller.record?.threads ?? []).filter {$0.status == "open"},id:\.topic) { t in Text("• \(t.topic) — \(t.evidence)") }
            ForEach((controller.record?.suggestions ?? []).filter { ["saved","new"].contains($0.status) }) { s in Text("• \(s.decision.suggested_question)") }
            if (controller.record?.threads.isEmpty ?? true) { Text("No model-verified open threads yet. Review the transcript for people to contact.").foregroundStyle(.secondary) }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:12))
    }
    private var researchView: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Research pack").font(.largeTitle.bold())
            Text("Import actual publication text for originality comparisons. Labels, source URLs and journalist verification notes stay distinct from article contents.").font(.caption).foregroundStyle(.secondary)
            Text("Text, Markdown and text-based PDFs stay local. Relevant excerpts and their labels are sent with transcript text for editorial analysis.").foregroundStyle(.secondary)
            Picker("Import as",selection:$researchKind) {
                ForEach(["Published coverage (user supplied)","Interview questions","Subjective observations","Hypotheses"],id:\.self) { Text($0).tag($0) }
            }
            TextField("Original source URL (optional unless confirming primary evidence)",text:$sourceURL).textFieldStyle(.roundedBorder)
            Toggle("I checked this as primary-source evidence",isOn:$primaryConfirmed)
            if primaryConfirmed { TextField("What did you check, and what does it actually substantiate?",text:$verificationNote,axis:.vertical).textFieldStyle(.roundedBorder) }
            Button("Import research…") {
                let p = NSOpenPanel(); p.allowedContentTypes = [.plainText,.pdf,UTType(filenameExtension:"md") ?? .plainText]; p.allowsMultipleSelection = true
                if p.runModal() == .OK { for url in p.urls { do { try controller.research.add(url,kind:researchKind,sourceURL:sourceURL,verificationNote:verificationNote,primaryConfirmed:primaryConfirmed) } catch { controller.message = error.localizedDescription } } }
            }.disabled(controller.isRecording || controller.stories.busy)
            List {
                ForEach(controller.research.documents) { doc in
                    DisclosureGroup("\(doc.name) · \(doc.kind)") { Text(doc.text).font(.callout).textSelection(.enabled) }
                        .contextMenu { Button("Remove from research pack") { controller.research.documents.removeAll {$0.id == doc.id}; controller.research.save() } }
                }
            }
        }.padding(28)
    }
    private var archiveView: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Saved interviews").font(.largeTitle.bold())
            List(controller.archive) { r in
                Button { controller.openRecord(r); page = "Interview" } label: {
                    VStack(alignment:.leading) { Text(r.title); Text("\(r.date.formatted()) · \(r.lines.count) transcript lines\(r.simulation ? " · SIMULATION" : "")").font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
        }.padding(28).onAppear { controller.refreshArchive() }
    }
    private func export(_ format: String) {
        guard let r = controller.record else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "Interview-\(r.id.uuidString.prefix(8)).\(format)"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try InterviewStore.export(r,format:format).write(to:url,options:.atomic) } catch { controller.message = error.localizedDescription }
    }
}
