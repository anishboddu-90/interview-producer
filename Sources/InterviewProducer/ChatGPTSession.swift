import Foundation
import AppKit
import CryptoKit
import Security
import LocalAuthentication
import Network

enum ProducerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum ProducerSecrets {
    static let service = "org.interviewproducer.credentials"
    static func read(_ account: String, allowInteraction: Bool = true) -> Data? {
        var result: CFTypeRef?
        var q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
                               kSecAttrAccount as String:account, kSecReturnData as String:true]
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    static func write(_ account: String, _ data: Data?) throws {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:account]
        guard let data else { SecItemDelete(q as CFDictionary); return }
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ProducerError.message("Could not save credentials in Keychain.") }; return
        }
        guard status == errSecSuccess else { throw ProducerError.message("Keychain update failed (\(status)).") }
    }
}

enum OAuthValidation {
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ s: String) -> Data? {
        let t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded:t + String(repeating:"=", count:(4-t.count%4)%4))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating:0, count:32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ProducerError.message("Secure randomness unavailable.") }
        return base64URL(Data(bytes))
    }
    static func challenge(_ s: String) -> String { base64URL(Data(SHA256.hash(data: Data(s.utf8)))) }
    static func callback(_ url: URL, state: String, clientID: String?) throws -> (String, String) {
        guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/auth/callback", let c = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw ProducerError.message("Invalid callback path.") }
        let items = c.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw ProducerError.message("Duplicate callback parameters.") }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("state") == state else { throw ProducerError.message("Authorization state mismatch.") }
        if value("error") != nil { throw ProducerError.message("ChatGPT authorization was declined or unavailable. No connection was activated.") }
        let issued = value("client_id") ?? clientID ?? ""
        guard !issued.isEmpty, issued != "dynamic_agent_client", clientID == nil || issued == clientID,
              let code = value("code"), !code.isEmpty else { throw ProducerError.message("Incomplete or mismatched client registration.") }
        return (code, issued)
    }
    static func validateClaims(_ c: [String:Any], clientID: String, nonce: String?, now: Date = Date()) throws -> String {
        let audiences = (c["aud"] as? [String]) ?? (c["aud"] as? String).map { [$0] } ?? []
        guard c["iss"] as? String == "https://auth.openai.com", audiences.contains(clientID),
              let exp = c["exp"] as? Double, exp > now.timeIntervalSince1970,
              let sub = c["sub"] as? String, !sub.isEmpty,
              nonce == nil || c["nonce"] as? String == nonce else { throw ProducerError.message("ID-token identity validation failed.") }
        return sub
    }
    static func grantedScopes(_ scope: String) throws -> [String] {
        let scopes = scope.split(separator:" ").map(String.init)
        guard scopes.contains("chatgpt.tokens.use.direct"), scopes.contains("resource.invoke") else { throw ProducerError.message("ChatGPT-plan usage permission was not granted. Enable plan access and reconnect.") }
        return scopes
    }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var len = Data()
        if data.count < 128 { len.append(UInt8(data.count)) }
        else { var n = data.count; var b = [UInt8](); while n > 0 { b.insert(UInt8(n & 255),at:0); n >>= 8 }; len.append(0x80 | UInt8(b.count)); len.append(contentsOf:b) }
        return Data([tag]) + len + data
    }
    static func verifyJWT(_ token: String, jwks: Data, clientID: String, nonce: String?) throws -> [String:Any] {
        let p = token.split(separator:".").map(String.init)
        guard p.count == 3, let h = decode(p[0]), let payload = decode(p[1]), let signature = decode(p[2]),
              let header = try JSONSerialization.jsonObject(with:h) as? [String:Any], header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              let root = try JSONSerialization.jsonObject(with:jwks) as? [String:Any], let keys = root["keys"] as? [[String:Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = jwk["n"] as? String, let e = jwk["e"] as? String, var modulus = decode(n), var exponent = decode(e) else { throw ProducerError.message("Invalid signed ID token or signing key.") }
        if (modulus.first ?? 0) & 0x80 != 0 { modulus.insert(0,at:0) }
        if (exponent.first ?? 0) & 0x80 != 0 { exponent.insert(0,at:0) }
        let keyData = der(0x30,der(0x02,modulus)+der(0x02,exponent))
        let attrs: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeRSA, kSecAttrKeyClass as String:kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData,attrs as CFDictionary,nil),
              SecKeyVerifySignature(key,.rsaSignatureMessagePKCS1v15SHA256,Data((p[0]+"."+p[1]).utf8) as CFData,signature as CFData,nil),
              let claims = try JSONSerialization.jsonObject(with:payload) as? [String:Any] else { throw ProducerError.message("ID-token signature verification failed.") }
        _ = try validateClaims(claims,clientID:clientID,nonce:nonce)
        return claims
    }
}

private final class OAuthReadyGate: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Bound exclusively to 127.0.0.1, one callback, no external network interface.
final class OAuthLoopback: @unchecked Sendable {
    private var listener: NWListener?
    private var pending: CheckedContinuation<URL,Error>?
    private var bufferedResult: Result<URL,Error>?
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"org.interviewproducer.oauth")
    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let l = try NWListener(using:params); listener = l
        l.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = OAuthReadyGate()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }; l.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string:"http://127.0.0.1:\(l.port!.rawValue)/auth/callback")!)
                case .failed(let e): guard gate.claim() else { return }; l.stateUpdateHandler = nil; continuation.resume(throwing:e)
                default: break
                }
            }
            l.start(queue:queue)
        }
    }
    func wait() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let result = bufferedResult { bufferedResult = nil; lock.unlock(); c.resume(with:result); return }
                pending = c; lock.unlock()
                queue.asyncAfter(deadline:.now()+240) { [weak self] in self?.finish(.failure(ProducerError.message("Sign-in timed out. Try Continue with ChatGPT again."))) }
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    func submitManual(_ url: URL) throws {
        guard let port = listener?.port?.rawValue, url.scheme == "http", url.host == "127.0.0.1", url.port == Int(port), url.path == "/auth/callback" else {
            throw ProducerError.message("Paste the final 127.0.0.1 callback address from this sign-in attempt. Its port and path must match; never paste it into chat.")
        }
        finish(.success(url))
    }
    func close() { finish(.failure(CancellationError())) }
    static func healthCheck() async throws -> String {
        let l = OAuthLoopback(); let callback = try await l.start(); defer { l.close() }
        var components = URLComponents(url:callback,resolvingAgainstBaseURL:false)!; components.path = "/health"
        var request = URLRequest(url:components.url!); request.timeoutInterval = 5
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, String(data:data,encoding:.utf8) == "Interview Producer callback ready" else { throw ProducerError.message("Local callback health check failed.") }
        return "127.0.0.1 callback works from this Mac. Browser filtering can still differ; manual callback paste is available if needed."
    }
    private func receive(_ c: NWConnection) {
        c.start(queue:queue)
        c.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] data,_,_,_ in
            guard let data, let line = String(data:data,encoding:.utf8)?.components(separatedBy:"\r\n").first,
                  let path = line.split(separator:" ").dropFirst().first,
                  line.hasPrefix("GET "), let port = self?.listener?.port?.rawValue,
                  let url = URL(string:"http://127.0.0.1:\(port)\(path)") else { c.cancel(); return }
            let health = path == "/health"
            guard health || path.hasPrefix("/auth/callback?") else { c.cancel(); return }
            let body = health ? "Interview Producer callback ready" : "Authorization callback received. Return to Interview Producer to check the result."
            c.send(content:Data("HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),completion:.contentProcessed { _ in c.cancel() })
            if !health { self?.finish(.success(url)) }
        }
    }
    private func finish(_ result: Result<URL,Error>) {
        lock.lock(); let c = pending; pending = nil; if c == nil { bufferedResult = result }; lock.unlock()
        c?.resume(with:result); listener?.cancel()
    }
}

actor ChatGPTSession {
    static let shared = ChatGPTSession()
    struct Credential: Codable {
        var clientID: String; var subject: String; var email: String
        var access: String; var refresh: String; var idToken: String; var scopes: [String]; var expires: Date
    }
    struct Model: Decodable, Identifiable {
        var slug: String; var display_name: String; var visibility: String
        var id: String { slug }
    }
    private var refreshTask: Task<Credential,Error>?
    private var signingIn = false
    private var activeListener: OAuthLoopback?
    private var epoch = 0
    private func load() -> Credential? { ProducerSecrets.read("chatgpt-session").flatMap { try? JSONDecoder().decode(Credential.self,from:$0) } }
    func accountLabel() -> String { load()?.email ?? "Not connected" }
    func hasPermission() -> Bool { load()?.scopes.contains("chatgpt.tokens.use.direct") == true }
    private func form(_ fields: [String:String]) -> Data {
        var c = URLComponents(); c.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of:"+",with:"%2B").utf8)
    }
    private func requestToken(_ fields: [String:String], clientID: String, nonce: String?, previous: Credential?) async throws -> Credential {
        var r = URLRequest(url:URL(string:"https://auth.openai.com/api/accounts/oauth/token")!)
        r.httpMethod = "POST"; r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type"); r.httpBody = form(fields); r.timeoutInterval = 30
        let (d,response) = try await URLSession.shared.data(for:r)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with:d) as? [String:Any],
              let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let scope = o["scope"] as? String, let expiry = o["expires_in"] as? Double, expiry.isFinite, expiry > 0, !access.isEmpty, !refresh.isEmpty,
              (o["token_type"] as? String)?.lowercased() == "bearer" else { throw ProducerError.message("ChatGPT token exchange failed. Reconnect your account; no API-key fallback will run.") }
        let scopes = try OAuthValidation.grantedScopes(scope)
        var sub = previous?.subject ?? "", email = previous?.email ?? "", idToken = previous?.idToken ?? ""
        if let token = o["id_token"] as? String {
            let (jwks,http) = try await URLSession.shared.data(from:URL(string:"https://auth.openai.com/.well-known/jwks.json")!)
            guard (http as? HTTPURLResponse)?.statusCode == 200 else { throw ProducerError.message("Cannot retrieve OpenAI signing keys.") }
            let claims = try OAuthValidation.verifyJWT(token,jwks:jwks,clientID:clientID,nonce:nonce)
            sub = claims["sub"] as! String; email = claims["email"] as? String ?? sub; idToken = token
            guard previous == nil || previous?.subject == sub else { throw ProducerError.message("The returned account does not match the selected registration.") }
        } else if previous == nil { throw ProducerError.message("Sign-in did not return an ID token.") }
        return Credential(clientID:clientID,subject:sub,email:email,access:access,refresh:refresh,idToken:idToken,scopes:scopes,expires:Date().addingTimeInterval(expiry))
    }
    func signIn() async throws {
        guard !signingIn else { throw ProducerError.message("A sign-in is already in progress.") }
        signingIn = true; defer { signingIn = false; activeListener = nil }
        let generation = epoch
        let previous = load()
        let registeredID = ProducerDefaults.shared.string(forKey:"producer.clientID")
        let clientID = previous?.clientID ?? registeredID
        let state = try OAuthValidation.random(), nonce = try OAuthValidation.random(), verifier = try OAuthValidation.random()
        let hostKey = "producer.hostID"
        let host = ProducerDefaults.shared.string(forKey:hostKey) ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        ProducerDefaults.shared.set(host,forKey:hostKey)
        let listener = OAuthLoopback(); let redirect = try await listener.start(); activeListener = listener
        var c = URLComponents(string:"https://auth.openai.com/api/accounts/authorize")!
        var fields = ["client_id":clientID ?? "dynamic_agent_client", "ext_agent_host_id":host, "response_type":"code", "redirect_uri":redirect.absoluteString,
                      "scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource":"https://api.openai.com/v1", "state":state,"nonce":nonce,"code_challenge_method":"S256","code_challenge":OAuthValidation.challenge(verifier)]
        if clientID == nil { fields["agent_name_hint"] = "Interview Producer" }
        if let previous { fields["id_token_hint"] = previous.idToken; fields["login_hint"] = previous.email }
        c.queryItems = fields.map { URLQueryItem(name:$0.key,value:$0.value) }
        // Establish the callback waiter before opening the browser.
        let callbackTask = Task { try await listener.wait() }
        let authorizationURL = c.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authorizationURL) }
        let callback = try await callbackTask.value
        let (code,issued) = try OAuthValidation.callback(callback,state:state,clientID:clientID)
        let credential = try await requestToken(["grant_type":"authorization_code","client_id":issued,"code":code,"code_verifier":verifier,"redirect_uri":redirect.absoluteString,"resource":"https://api.openai.com/v1"],clientID:issued,nonce:nonce,previous:previous)
        guard generation == epoch else { throw CancellationError() }
        if let subject = ProducerDefaults.shared.string(forKey:"producer.subject"), clientID != nil, subject != credential.subject { throw ProducerError.message("Registered account identity changed.") }
        try ProducerSecrets.write("chatgpt-session",JSONEncoder().encode(credential))
        ProducerDefaults.shared.set(issued,forKey:"producer.clientID"); ProducerDefaults.shared.set(credential.subject,forKey:"producer.subject")
    }
    func submitManualCallback(_ address: String) throws {
        guard signingIn, let activeListener, let url = URL(string:address.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw ProducerError.message("Start Continue with ChatGPT first, then paste its final callback address if the browser cannot open it.") }
        try activeListener.submitManual(url)
    }
    func accessToken() async throws -> String {
        guard let old = load(), old.scopes.contains("chatgpt.tokens.use.direct") else { throw ProducerError.message("Connect ChatGPT and grant ChatGPT-plan usage first.") }
        if old.expires.timeIntervalSinceNow > 90 { return old.access }
        if let refreshTask { return try await refreshTask.value.access }
        let generation = epoch
        let t = Task { try await self.requestToken(["grant_type":"refresh_token","client_id":old.clientID,"refresh_token":old.refresh,"resource":"https://api.openai.com/v1"],clientID:old.clientID,nonce:nil,previous:old) }
        refreshTask = t; defer { refreshTask = nil }
        let updated = try await t.value
        guard generation == epoch else { throw CancellationError() }
        try ProducerSecrets.write("chatgpt-session",JSONEncoder().encode(updated))
        return updated.access
    }
    func signOut() async -> String {
        epoch += 1; activeListener?.close(); activeListener = nil; refreshTask?.cancel(); refreshTask = nil
        let old = load(); try? ProducerSecrets.write("chatgpt-session",nil)
        guard let old else { return "Signed out locally." }
        do {
            let (metadata,_) = try await URLSession.shared.data(from:URL(string:"https://auth.openai.com/.well-known/openid-configuration")!)
            let o = try JSONSerialization.jsonObject(with:metadata) as? [String:Any]
            guard let endpoint = o?["revocation_endpoint"] as? String, let url = URL(string:endpoint), url.scheme == "https", url.host == "auth.openai.com" else { throw ProducerError.message("Invalid revocation endpoint") }
            for attempt in 0..<2 {
                var r = URLRequest(url:url); r.httpMethod = "POST"; r.timeoutInterval = 15
                r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
                r.httpBody = form(["token":old.refresh,"token_type_hint":"refresh_token","client_id":old.clientID])
                let (_,response) = try await URLSession.shared.data(for:r)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return "Signed out; renewable session revoked." }
                if attempt == 0 { try await Task.sleep(for:.seconds(2)) }
            }
        } catch {}
        return "Signed out locally. Remote revocation was not confirmed; disconnect Interview Producer in ChatGPT Settings."
    }
    func models() async throws -> [Model] {
        var r = URLRequest(url:URL(string:"https://api.openai.com/v1/models")!); r.timeoutInterval = 30
        r.setValue("Bearer \(try await accessToken())",forHTTPHeaderField:"Authorization")
        let (d,response) = try await URLSession.shared.data(for:r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProducerError.message("ChatGPT model catalog unavailable. Check plan permission or reconnect.") }
        struct Catalog: Decodable { var models:[Model] }
        return try JSONDecoder().decode(Catalog.self,from:d).models.filter { $0.visibility == "list" }
    }
    func complete(model: String, instructions: String, input: String) async throws -> String {
        guard !model.isEmpty else { throw ProducerError.message("Choose an account-eligible model first.") }
        let generation = epoch
        var r = URLRequest(url:URL(string:"https://api.openai.com/v1/responses")!)
        r.httpMethod = "POST"; r.timeoutInterval = 65
        r.setValue("Bearer \(try await accessToken())",forHTTPHeaderField:"Authorization"); r.setValue("application/json",forHTTPHeaderField:"Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject:["model":model,"instructions":instructions,"input":[["role":"user","content":input]],"store":false,"stream":true])
        let (bytes,response) = try await URLSession.shared.bytes(for:r)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ProducerError.message("ChatGPT inference HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Reconnect for 401/403; wait for plan reset for 429. Capture continues.") }
        var parser = ProducerSSE()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try parser.consume(line)
            if parser.completed { break }
        }
        guard generation == epoch else { throw CancellationError() }
        return try parser.result()
    }
}

struct ProducerSSE {
    var text = ""; var completed = false
    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:"), let data = String(line.dropFirst(5)).trimmingCharacters(in:.whitespaces).data(using:.utf8),
              let o = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let type = o["type"] as? String else { return }
        if type == "response.output_text.delta", let delta = o["delta"] as? String { text += delta }
        if text.utf8.count > 131072 { throw ProducerError.message("Response exceeded the local size limit.") }
        if type == "response.completed" { completed = true }
        if ["response.failed","response.incomplete","error"].contains(type) {
            let response = o["response"] as? [String:Any]
            let error = (response?["error"] as? [String:Any]) ?? (o["error"] as? [String:Any])
            let code = error?["code"] as? String ?? type
            throw ProducerError.message("ChatGPT: \(code). No paid-provider fallback. Capture continues.")
        }
    }
    func result() throws -> String {
        guard completed, !text.isEmpty else { throw ProducerError.message("ChatGPT stream interrupted or empty; no suggestion was accepted.") }
        return text
    }
}
