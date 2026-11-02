import SwiftUI
import AppKit
import AVFoundation

struct InterviewSetupView: View {
    @Environment(InterviewController.self) private var controller
    @AppStorage("interview.topic",store:ProducerDefaults.shared) private var topic = ""
    @AppStorage("interview.goals",store:ProducerDefaults.shared) private var goals = ""
    @AppStorage("interview.purpose",store:ProducerDefaults.shared) private var purpose = "Journalism"
    @AppStorage("interview.stage",store:ProducerDefaults.shared) private var stage = "Discovery"
    @AppStorage("interview.captureMode",store:ProducerDefaults.shared) private var mode = "Call application + microphone"
    @AppStorage("interview.applicationID",store:ProducerDefaults.shared) private var applicationID = "us.zoom.xos"
    @AppStorage("interview.microphoneID",store:ProducerDefaults.shared) private var microphoneID = ""
    @AppStorage("interview.language",store:ProducerDefaults.shared) private var language = "auto"
    @State private var apps: [String:String] = [:]
    @State private var microphones: [AVCaptureDevice] = []
    var body: some View {
        Form {
            Section("Interview purpose") {
                TextField("Topic or project",text:$topic)
                Picker("Purpose",selection:$purpose) { ForEach(InterviewSettings.purposes,id:\.self) { Text($0).tag($0) } }
                Picker("Stage",selection:$stage) { ForEach(InterviewSettings.stages,id:\.self) { Text($0).tag($0) } }
                Text("Goals and priorities (up to 4,000 characters)").font(.caption)
                TextEditor(text:$goals).frame(minHeight:130)
                Text("Setup saves automatically. Research, verbatim memory and prepared questions remain separate and editable. Use a separate macOS user account when sharing a computer with another interviewer.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio and language") {
                Picker("Capture",selection:$mode) { ForEach(InterviewSettings.modes,id:\.self) { Text($0).tag($0) } }
                if mode != "Microphone only" {
                    Picker("Call application",selection:$applicationID) {
                        ForEach(apps.keys.sorted(),id:\.self) { id in Text(apps[id] ?? id).tag(id) }
                        if apps[applicationID] == nil { Text(applicationID+" (not running)").tag(applicationID) }
                    }
                    TextField("Application bundle identifier",text:$applicationID)
                    Text("Capture targets this application. Browsers can include unrelated tabs; close other audio tabs. Application support depends on macOS audio routing. Confirm incoming audio on the meter.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Microphone",selection:$microphoneID) {
                    Text("Built-in when available; otherwise system default").tag("")
                    ForEach(microphones,id:\.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    if !microphoneID.isEmpty && !microphones.contains(where:{$0.uniqueID == microphoneID}) { Text("Selected device unavailable").tag(microphoneID) }
                }
                TextField("Transcription language (auto or ISO code, e.g. en, es, fr)",text:$language)
                Button("Refresh applications and microphones") { refresh() }
                Text("Microphone-only mode works for in-person interviews and practice without a call app. It labels all captured voices as the microphone channel; it does not identify individual people.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear { refresh() }
        .disabled(controller.isStarting || controller.isRecording || controller.isStopping)
    }
    private func refresh() {
        apps = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app -> (String,String)? in
            guard let id = app.bundleIdentifier, app.activationPolicy == .regular, id != "org.interviewproducer.mac" else { return nil }
            return (id,app.localizedName ?? id)
        },uniquingKeysWith: { a,_ in a })
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone],mediaType:.audio,position:.unspecified).devices
    }
}
