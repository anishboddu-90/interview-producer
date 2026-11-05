import SwiftUI
import AppKit
@preconcurrency import AVFoundation

struct ProducerConnectionView: View {
    @Environment(InterviewController.self) private var controller
    @State private var account = "Not connected"
    @State private var status = "Connect, choose an eligible model, then test actual inference."
    @State private var busy = false
    @State private var models: [ChatGPTSession.Model] = []
    @State private var key = ""
    @State private var callbackAddress = ""
    @State private var showCallbackHelp = false
    @AppStorage("producer.model",store:ProducerDefaults.shared) private var selected = ""
    @AppStorage("producer.groqFreeConfirmed",store:ProducerDefaults.shared) private var freeConfirmed = false
    @AppStorage("producer.groqEditorial",store:ProducerDefaults.shared) private var groqEditorial = false
    @AppStorage("producer.groqTextModel",store:ProducerDefaults.shared) private var groqModel = "openai/gpt-oss-20b"
    var body: some View {
        Form {
            APIConnectionView(kind:"text")
            APIConnectionView(kind:"audio")
            Section("ChatGPT plan") {
                Text(account).textSelection(.enabled)
                Button(busy ? "Connecting…" : "Continue with ChatGPT") { connect() }.disabled(busy)
                Button("Check local sign-in callback") {
                    Task { do { status = try await OAuthLoopback.healthCheck() } catch { status = "Callback unavailable: \(error.localizedDescription). Groq Free does not need a loopback callback." } }
                }.disabled(busy)
                DisclosureGroup("Browser cannot open the final callback?",isExpanded:$showCallbackHelp) {
                    Text("The app has no local website. Sign-in returns to 127.0.0.1 on this Mac. If the browser reaches that address but shows a connection error, copy its entire final address into this local field. State, PKCE and the exact callback port are still validated. Never send this address in chat.").font(.caption)
                    SecureField("Final callback address",text:$callbackAddress)
                    Button("Submit callback locally") {
                        let address = callbackAddress; callbackAddress = ""
                        Task { do { try await ChatGPTSession.shared.submitManualCallback(address) } catch { status = error.localizedDescription } }
                    }.disabled(callbackAddress.isEmpty || !busy)
                }
                HStack {
                    Button("Refresh models") { Task { await fetchModels() } }.disabled(busy)
                    Button("Sign out") { Task { status = await ChatGPTSession.shared.signOut(); models = []; selected = ""; account = "Not connected" } }.disabled(busy)
                }
                Picker("Eligible model",selection:$selected) {
                    Text("Select a model").tag("")
                    ForEach(models) { m in Text(m.display_name).tag(m.slug) }
                }
                Button("Test real ChatGPT inference") {
                    busy = true
                    Task {
                        do { let result = try await ChatGPTSession.shared.complete(model:selected,instructions:"Reply in one short sentence.",input:"Say: Interview Producer connection verified."); status = "Completed real inference: \(result)" }
                        catch { status = "Inference not verified: \(error.localizedDescription)" }
                        busy = false
                    }
                }.disabled(busy || selected.isEmpty)
                Text("Uses granted ChatGPT-plan access. Limits are shared with other apps. No OpenAI API key or paid-provider fallback.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Groq Free transcription") {
                SecureField("Groq API key",text:$key)
                Button("Save Groq key to Keychain") {
                    do { try ProducerSecrets.write("groq",key.isEmpty ? nil : Data(key.utf8)); key = ""; status = "Groq key saved. Complete the audio test to verify transcription." }
                    catch { status = error.localizedDescription }
                }.disabled(key.isEmpty)
                Button("Remove saved Groq key",role:.destructive) {
                    do { try ProducerSecrets.write("groq",nil); status = "Groq key removed from Keychain." } catch { status = error.localizedDescription }
                }
                Toggle("I checked that this Groq organization is on Free with no paid billing",isOn:$freeConfirmed)
                Text("Audio → Groq whisper-large-v3-turbo. Published free limits: 20 requests/minute, 7,200 audio seconds/hour, 28,800/day. Local guards are lower and include retries; your organization's other usage also counts. This app cannot inspect your billing plan.").font(.caption).foregroundStyle(.secondary)
                Link("Check Groq plan and limits",destination:URL(string:"https://console.groq.com/settings/limits")!)
                Button("Test selected transcription provider with audio…") { testAudio() }.disabled(busy || !TranscriptionProvider.ready)
            }
            Section("Optional free text provider") {
                Toggle("Use Groq Free for editorial analysis instead of ChatGPT",isOn:$groqEditorial)
                Text("Explicit alternative only; never enabled automatically. Uses the same Groq key. Conservative text budget, no web tools, no billing activation. Long reports may exceed free request limits.").font(.caption).foregroundStyle(.secondary)
                if groqEditorial { TextField("Groq text model",text:$groqModel) }
            }
            Section("Connection status") { Text(status).textSelection(.enabled).foregroundStyle(.secondary) }
        }.formStyle(.grouped).disabled(controller.isStarting || controller.isRecording || controller.isStopping || controller.processingReport || controller.stories.busy).task { account = await ChatGPTSession.shared.accountLabel(); if await ChatGPTSession.shared.hasPermission() { await fetchModels() } }
    }
    private func connect() {
        busy = true; status = "Finish authorization in your browser. This app will verify the returned identity and plan permission."
        Task {
            do { try await ChatGPTSession.shared.signIn(); account = await ChatGPTSession.shared.accountLabel(); await fetchModels(); status = "Identity and plan permission verified. Test inference to verify the connection." }
            catch { status = "Not connected: \(error.localizedDescription)" }
            busy = false
        }
    }
    private func fetchModels() async {
        do { models = try await ChatGPTSession.shared.models(); if !models.contains(where:{$0.slug == selected}) { selected = "" } }
        catch { status = error.localizedDescription }
    }
    private func testAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            do {
                let file = try AVAudioFile(forReading:url)
                guard file.length <= Int64(file.fileFormat.sampleRate*30), let converter = AVAudioConverter(from:file.processingFormat,to:AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!),
                      let input = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)),
                      let output = AVAudioPCMBuffer(pcmFormat:AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!,frameCapacity:480000) else { throw ProducerError.message("Choose a spoken audio file of 30 seconds or less.") }
                try file.read(into:input); var sent = false; var err: NSError?
                converter.convert(to:output,error:&err) { _,state in if sent { state.pointee = .endOfStream; return nil }; sent = true; state.pointee = .haveData; return input }
                if let err { throw err }
                guard let ptr = output.floatChannelData?.pointee else { throw ProducerError.message("Could not decode the file.") }
                let text = try await TranscriptionProvider.transcribe(AudioChunk(speaker:.them,start:0,end:Double(output.frameLength)/16000,samples:Array(UnsafeBufferPointer(start:ptr,count:Int(output.frameLength)))))
                status = "Real transcription result: \(text)"
            } catch { status = "Transcription not verified: \(error.localizedDescription)" }
            busy = false
        }
    }
}
