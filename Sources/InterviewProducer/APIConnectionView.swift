import SwiftUI

struct APIConnectionView: View {
    let kind: String
    @State private var key = ""
    @State private var status = ""
    @State private var busy = false
    @AppStorage private var enabled: Bool
    @AppStorage private var base: String
    @AppStorage private var model: String
    @AppStorage("api.text.tokenParameter",store:ProducerDefaults.shared) private var tokenParameter = "max_completion_tokens"
    init(kind: String) {
        self.kind = kind
        _enabled = AppStorage(wrappedValue:false,"api.\(kind).enabled",store:ProducerDefaults.shared)
        _base = AppStorage(wrappedValue:"https://api.openai.com/v1","api.\(kind).base",store:ProducerDefaults.shared)
        _model = AppStorage(wrappedValue:"","api.\(kind).model",store:ProducerDefaults.shared)
    }
    var body: some View {
        Section("API key · \(kind == "text" ? "editorial analysis" : "transcription")") {
            Toggle("Use this API for \(kind == "text" ? "text analysis" : "audio transcription")",isOn:$enabled)
            Text("Optional, explicit provider choice. Accepts the OpenAI-compatible \(kind == "text" ? "chat/completions" : "audio/transcriptions") API. HTTPS only. Provider billing and retention apply; this is separate from a ChatGPT subscription. No automatic fallback.").font(.caption).foregroundStyle(.secondary)
            TextField("API base URL (including /v1 if required)",text:$base)
            TextField("Model ID from your provider",text:$model)
            if kind == "text" {
                Picker("Output token field",selection:$tokenParameter) {
                    Text("max_completion_tokens").tag("max_completion_tokens")
                    Text("max_tokens (other compatible services)").tag("max_tokens")
                }
            }
            SecureField("API key for this endpoint",text:$key)
            HStack {
                Button("Save key to Keychain") {
                    do { let c = config; _ = try c.endpoint(kind == "text" ? "chat/completions" : "audio/transcriptions"); try ProducerSecrets.write(c.keyName(kind),Data(key.utf8)); key = ""; status = "Key saved for this exact endpoint. Test the connection before recording." }
                    catch { status = error.localizedDescription }
                }.disabled(key.isEmpty || busy)
                Button("Remove endpoint key",role:.destructive) {
                    do { try ProducerSecrets.write(config.keyName(kind),nil); status = "This endpoint's key was removed." } catch { status = error.localizedDescription }
                }.disabled(busy)
            }
            if kind == "text" {
                Button(busy ? "Testing…" : "Test this text API") {
                    busy = true
                    Task {
                        do { let c = config; let result = try await CompatibleProvider.complete(config:c,key:c.key(kind),instructions:"Reply in one short sentence.",input:"Say: Interview Producer connection verified."); status = "Real response: "+result }
                        catch { status = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy)
            } else { Text("Enable this route, then use the local audio-file test below to verify transcription.").font(.caption) }
            if !status.isEmpty { Text(status).textSelection(.enabled).font(.caption) }
        }
    }
    private var config: APIConfiguration { .init(baseURL:base,model:model,tokenParameter:tokenParameter) }
}
