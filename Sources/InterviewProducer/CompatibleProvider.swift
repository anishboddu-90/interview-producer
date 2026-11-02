import Foundation

/// Explicit opt-in for an OpenAI-compatible HTTPS API. Credentials are scoped to the exact base URL.
struct APIConfiguration: Equatable, Sendable {
    var baseURL: String
    var model: String
    var tokenParameter = "max_completion_tokens"
    func endpoint(_ path: String) throws -> URL {
        guard let parts = URLComponents(string:baseURL), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.path.contains(".."), !model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              model.count <= 200, ["max_completion_tokens","max_tokens"].contains(tokenParameter),
              let base = parts.url else { throw ProducerError.message("Enter an HTTPS API base URL without credentials, query or fragment, and an explicit model ID.") }
        return base.appendingPathComponent(path)
    }
    var identity: String { String(MemoryIdentity.digest(baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/")))).prefix(24).description }
    func keyName(_ kind: String) -> String { "compatible-\(kind)-\(identity)" }
    static func load(_ kind: String,defaults: UserDefaults = ProducerDefaults.shared) -> Self {
        .init(baseURL:defaults.string(forKey:"api.\(kind).base") ?? "https://api.openai.com/v1",
              model:defaults.string(forKey:"api.\(kind).model") ?? "",
              tokenParameter:defaults.string(forKey:"api.text.tokenParameter") ?? "max_completion_tokens")
    }
    static func enabled(_ kind: String) -> Bool { ProducerDefaults.shared.bool(forKey:"api.\(kind).enabled") }
    func key(_ kind: String) throws -> String {
        guard let data = ProducerSecrets.read(keyName(kind)), let key = String(data:data,encoding:.utf8), !key.isEmpty else {
            throw ProducerError.message("Save an API key for this exact \(kind) endpoint in Connection. No other provider was tried.")
        }
        return key
    }
}

final class NoAPIRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum CompatibleProvider {
    static let session = URLSession(configuration:.ephemeral,delegate:NoAPIRedirect(),delegateQueue:nil)
    static func textRequest(config: APIConfiguration,key: String,instructions: String,input: String) throws -> URLRequest {
        var request = URLRequest(url:try config.endpoint("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["model":config.model,"messages":[["role":"system","content":instructions],["role":"user","content":input]],config.tokenParameter:6000,"stream":false,"store":false])
        return request
    }
    static func decodeText(_ data: Data,status: Int) throws -> String {
        guard status == 200 else { throw ProducerError.message("Text API HTTP \(status). Check endpoint, model, permissions and quota. No provider switch was made.") }
        let root = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        guard let first = (root?["choices"] as? [[String:Any]])?.first, first["finish_reason"] as? String == "stop",
              let message = first["message"] as? [String:Any], let text = message["content"] as? String, !text.isEmpty else {
            throw ProducerError.message("Text API returned incomplete or unsupported output; it was not used.")
        }
        return text
    }
    static func complete(config: APIConfiguration,key: String,instructions: String,input: String,session: URLSession = session) async throws -> String {
        let (data,response) = try await session.data(for:textRequest(config:config,key:key,instructions:instructions,input:input))
        return try decodeText(data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    static func audioRequest(config: APIConfiguration,key: String,samples: [Float],language: String) throws -> URLRequest {
        var request = URLRequest(url:try config.endpoint("audio/transcriptions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        let boundary = "interview-\(UUID())"
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        var fields = [("model",config.model),("response_format","json")]
        if language != "auto" { fields.append(("language",language)) }
        request.httpBody = Multipart.body(boundary:boundary,fields:fields,file:("file","chunk.wav","audio/wav",WAVEncoder.encode(samples:samples,sampleRate:16000)))
        return request
    }
    static func transcribe(config: APIConfiguration,key: String,samples: [Float],language: String,session: URLSession = session) async throws -> String {
        let (data,response) = try await session.data(for:audioRequest(config:config,key:key,samples:samples,language:language))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProducerError.message("Transcription API HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Audio remains local; no other provider was tried.") }
        struct Result: Decodable { var text: String }
        return try JSONDecoder().decode(Result.self,from:data).text
    }
}
enum TranscriptionProvider {
    static var ready: Bool {
        if APIConfiguration.enabled("audio") { let c = APIConfiguration.load("audio"); return (try? c.endpoint("audio/transcriptions")) != nil && (try? c.key("audio")) != nil }
        return ProducerDefaults.shared.bool(forKey:"producer.groqFreeConfirmed") && ProducerSecrets.read("groq") != nil
    }
    static func transcribe(_ item: AudioChunk) async throws -> String {
        let language = InterviewSettings.current.language
        if APIConfiguration.enabled("audio") {
            let config = APIConfiguration.load("audio")
            return try await CompatibleProvider.transcribe(config:config,key:config.key("audio"),samples:item.samples,language:language)
        }
        guard let data = ProducerSecrets.read("groq"),let key = String(data:data,encoding:.utf8),!key.isEmpty else { throw ProducerError.message("Groq key missing; audio is recorded but not transcribed.") }
        guard ProducerDefaults.shared.bool(forKey:"producer.groqFreeConfirmed") else { throw ProducerError.message("Confirm your Groq plan in Connection before cloud transcription.") }
        return try await GroqTranscriber.transcribe(samples:item.samples,language:language,apiKey:key)
    }
}
