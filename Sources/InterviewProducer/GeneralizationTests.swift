import Foundation

@MainActor enum GeneralizationTests {
    static func run() async -> Int32 {
        var total = 0, failed = 0
        func check(_ value: Bool,_ name: String) { total += 1; if !value { failed += 1; print("FAIL portability: \(name)") } }
        func rejects(_ name: String,_ action: () throws -> Void) { do { try action(); check(false,name) } catch { check(true,name) } }
        let domain = "org.interviewproducer.tests.setup.\(UUID())"
        let defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let initial = InterviewSettings.load(from:defaults)
        check(initial.topic.isEmpty && initial.goals.isEmpty,"fresh installation has no personal topic or goal")
        check(EditorialProfile.registryEvidence.isEmpty && EditorialProfile.coverage.isEmpty,"no built-in publication assertions")
        check(!ConversationMemory.initialDossier.contains("2026"),"fresh dossier has no fixed date or subject")
        for (purpose,stage) in zip(InterviewSettings.purposes,InterviewSettings.stages+["Discovery"]) {
            defaults.set(purpose,forKey:"interview.purpose"); defaults.set(stage,forKey:"interview.stage")
            defaults.set("Urban transport research",forKey:"interview.topic")
            defaults.set("Test specific examples and differing accounts",forKey:"interview.goals")
            let restored = InterviewSettings.load(from:defaults)
            check(restored.purpose == purpose && restored.stage == stage && restored.context.contains("Urban transport"),"\(purpose) / \(stage) persist into model context")
        }
        var invalid = initial; invalid.language = "english"
        rejects("invalid transcription language is refused") { try invalid.validate() }
        invalid = initial; invalid.goals = String(repeating:"a",count:4001)
        rejects("oversized setup is refused before recording") { try invalid.validate() }
        var mic = initial; mic.captureMode = "Microphone only"; mic.applicationID = ""
        check((try? mic.validate()) != nil && mic.microphoneOnly,"in-person mode does not require a call application")
        check(StoryDirection.initial.first?.id == "subject","new investigation lanes are topic-neutral")
        var frozenRecord = InterviewRecord(); frozenRecord.setupContext = "SAVED original transit project"
        check(EditorialProfile.forInterview(frozenRecord).contains("SAVED original transit project"),"old interviews retain their recorded setup in later reports")
        var verify = initial; verify.stage = "Verification"
        check(verify.stageRules.contains("primary records"),"verification prioritizes primary records")
        verify.purpose = "Meeting"
        check(verify.stageRules.contains("Do not impose a publication pitch"),"meeting purpose does not inherit publication goals")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-neutral-tests-\(UUID())")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let file = folder.appendingPathComponent("research.json")
            let empty = ResearchLibrary(url:file)
            check(empty.documents.isEmpty && !FileManager.default.fileExists(atPath:file.path),"fresh research contains no asserted facts and writes no starter data")
            try Data("unreadable original".utf8).write(to:file)
            let broken = ResearchLibrary(url:file); broken.save()
            check(try String(contentsOf:file,encoding:.utf8) == "unreadable original" && !broken.error.isEmpty,"unreadable existing research is preserved")
        } catch { check(false,"research isolation: \(error.localizedDescription)") }
        let config = APIConfiguration(baseURL:"https://example.test/v1",model:"chosen-model")
        for bad in ["http://example.test/v1","https://user:secret@example.test/v1","https://example.test/v1?key=hidden","https://example.test/v1#fragment"] {
            rejects("unsafe API base rejected") { _ = try APIConfiguration(baseURL:bad,model:"chosen-model").endpoint("chat/completions") }
        }
        check(config.keyName("text") != APIConfiguration(baseURL:"https://other.test/v1",model:"chosen-model").keyName("text"),"endpoint changes cannot reuse another host's secret")
        check(config.keyName("text") != config.keyName("audio"),"text and audio keys are independent")
        do {
            let request = try CompatibleProvider.textRequest(config:config,key:"test-key",instructions:"Evidence rules",input:"Original testimony")
            let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            check(request.url?.absoluteString == "https://example.test/v1/chat/completions" && request.value(forHTTPHeaderField:"Authorization") == "Bearer test-key","custom text endpoint and explicit authorization")
            check(body["model"] as? String == "chosen-model" && body["store"] as? Bool == false,"chosen model and non-storage request setting")
            let audio = try CompatibleProvider.audioRequest(config:config,key:"audio-test",samples:[0.1,-0.2],language:"es")
            check(audio.url?.path == "/v1/audio/transcriptions" && audio.httpBody!.range(of:Data("es\r\n".utf8)) != nil,"custom transcription endpoint and requested language")
            let auto = try CompatibleProvider.audioRequest(config:config,key:"audio-test",samples:[0.1],language:"auto")
            check(auto.httpBody!.range(of:Data("name=\"language\"".utf8)) == nil,"auto language is omitted rather than forced English")
            let good = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"complete"}}]}"#.utf8)
            check(try CompatibleProvider.decodeText(good,status:200) == "complete","complete compatible API output accepted")
            rejects("provider quota errors do not return invented text") { _ = try CompatibleProvider.decodeText(good,status:429) }
            rejects("truncated model output is not treated as completed inference") { _ = try CompatibleProvider.decodeText(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#.utf8),status:200) }
            check(WAVEncoder.encode(samples:[.nan,.infinity,-.infinity],sampleRate:16000).count == 50,"nonfinite samples cannot crash WAV encoding")
            let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [ProviderTestProtocol.self]
            let session = URLSession(configuration:sessionConfig)
            defer { session.invalidateAndCancel() }
            let output = try await CompatibleProvider.complete(config:config,key:"synthetic-test-key",instructions:"rules",input:"test",session:session)
            check(output == "mock transport passed","compatible provider traverses URLSession transport with injected response")
        } catch { check(false,"provider protocol checks: \(error.localizedDescription)") }
        print("Generalization/provider checks: \(total-failed)/\(total) passed. Local fixtures only; no real API or hardware requests.")
        return failed == 0 ? 0 : 1
    }
}
private final class ProviderTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"mock transport passed"}}]}"#.utf8)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
