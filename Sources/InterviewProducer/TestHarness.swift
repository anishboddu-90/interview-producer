import Foundation
import Security

@MainActor enum ProducerTests {
    static func run() async -> Int32 {
        var failures = [String](); var total = 0
        func check(_ ok: @autoclosure () -> Bool,_ name: String) { total += 1; if !ok() { failures.append(name); print("FAIL \(name)") } }
        func rejects(_ name: String,_ f: () throws -> Void) { do { try f(); check(false,name) } catch { check(true,name) } }
        do { _ = try await OAuthLoopback.healthCheck(); check(true,"native 127.0.0.1 callback reachable") } catch { check(false,"native callback: \(error.localizedDescription)") }
        do {
            let listener = OAuthLoopback(); let redirect = try await listener.start()
            var callback = URLComponents(url:redirect,resolvingAgainstBaseURL:false)!
            callback.queryItems = [.init(name:"state",value:"test-state"),.init(name:"code",value:"test-code"),.init(name:"client_id",value:"test-issued")]
            let waiter = Task { try await listener.wait() }
            try listener.submitManual(callback.url!)
            let delivered = try await waiter.value
            let (code,client) = try OAuthValidation.callback(delivered,state:"test-state",clientID:nil)
            check(code == "test-code" && client == "test-issued","manual callback preserves validated attempt without browser HTTP")
        } catch { check(false,"manual callback delivery: \(error.localizedDescription)") }
        check(!ProducerDefaults.shared.dictionaryRepresentation().isEmpty,"application preferences initialize without forcing an optional suite")
        let base = SimulationFixtures.revelationDecision
        let transcript = SimulationFixtures.revelation.map(\.prompt).joined(separator:"\n")
        var state = EditorialState()
        check(state.accept(base,transcript:transcript,knownTitles:[],sensitivity:.balanced),"1: grounded major-revelation decision accepted")
        var historyState = EditorialState(); historyState.threads = [.init(topic:base.related_topic,status:"already_published",evidence:base.evidence_excerpt)]
        check(!historyState.accept(base,transcript:transcript,knownTitles:[],sensitivity:.balanced),"2: published thread suppressed")
        var person = base; person.related_topic = "Morgan contributions"; person.evidence_excerpt = SimulationFixtures.scenarios[2].lines[0].text; person.suggested_question = "What did Morgan do to keep the scene alive?"
        var personState = EditorialState()
        check(personState.accept(person,transcript:SimulationFixtures.scenarios[2].lines.map(\.prompt).joined(separator:"\n"),knownTitles:[],sensitivity:.balanced),"3: source contribution decision grounded")
        var answeredState = EditorialState(); answeredState.threads = [.init(topic:base.related_topic,status:"answered",evidence:base.evidence_excerpt)]
        check(!answeredState.accept(base,transcript:transcript,knownTitles:[],sensitivity:.balanced),"4: answered thread suppressed")
        var contradiction = base; contradiction.evidence_excerpt = SimulationFixtures.scenarios[4].lines[0].text; contradiction.related_topic = "Cedar Collective starting date"; contradiction.suggested_question = "Your Example Review interview dated the start to summer 2011. Are these different milestones?"; contradiction.reason = "Example Review / Josh Schafer / 2014-11-19 supplies a different date; ask neutrally."
        var contradictionState = EditorialState()
        check(contradictionState.accept(contradiction,transcript:SimulationFixtures.scenarios[4].lines.map(\.prompt).joined(separator:"\n"),knownTitles:[],sensitivity:.balanced),"5: grounded neutral clarification accepted")
        var silence = base; silence.should_suggest = false
        var silenceState = EditorialState()
        check(!silenceState.accept(silence,transcript:transcript,knownTitles:[],sensitivity:.balanced),"6: no-alert decision remains silent")
        var damaged = base; damaged.evidence_excerpt = "[unclear] nearly ??? 2019 maybe [unclear]"
        check(!silenceState.accept(damaged,transcript:SimulationFixtures.scenarios[6].lines.map(\.prompt).joined(separator:"\n"),knownTitles:[],sensitivity:.balanced),"7: damaged evidence rejected")
        var parser = ProducerSSE()
        do { try parser.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}"); rejects("8: interrupted inference never accepted") { _ = try parser.result() } } catch { check(false,"SSE delta parsing") }
        rejects("8: streamed subscription limit fails closed") { var p = ProducerSSE(); try p.consume("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}") }
        rejects("8: incomplete inference fails closed") { var p = ProducerSSE(); try p.consume("data: {\"type\":\"response.incomplete\"}") }
        do { try parser.consume("data: {\"type\":\"response.completed\"}"); let finalText = try parser.result(); check(finalText == "partial","completed stream accepted") } catch { check(false,"completed stream") }
        check(!state.accept(base,transcript:transcript,knownTitles:[],sensitivity:.balanced,now:Date().addingTimeInterval(120)),"9: recurring topic deduplicated after cooldown")
        check(!EditorialFreshness.mayPresent(anchor:10,latest:20,newQuestion:true,latency:3),"new interviewer question suppresses in-flight obsolete response")
        check(!EditorialFreshness.mayPresent(anchor:10,latest:11,newQuestion:false,latency:60),"late provider output suppressed")
        check(EditorialFreshness.mayPresent(anchor:10,latest:10,newQuestion:false,latency:3),"current response remains eligible")
        let t = Date(); var longState = EditorialState()
        for i in 0..<600 {
            let evidence = "A substantial event number \(i) changed our community."
            longState.update([.init(topic:"topic number \(i)",status:"open",evidence:evidence)],transcript:evidence)
            var d = base; d.related_topic = "source \(i)"; d.suggested_question = "What happened to source number \(i)?"; d.evidence_excerpt = evidence; d.timestamp = Double(i*6)
            _ = longState.accept(d,transcript:String(format:"[%02d:%02d] Interviewee: ",i*6/60,i*6%60)+evidence,knownTitles:[],sensitivity:.balanced,now:t.addingTimeInterval(Double(i*6)),cooldown:0)
        }
        check(longState.threads.count <= 20 && longState.accepted.count <= 100,"10: sixty-minute editorial memory remains bounded")
        let chunker = PCMChunker(); let collector = ChunkCollector()
        chunker.onChunk = { chunk in collector.append(chunk) }
        let samples = [Float](repeating:0.08,count:1600)
        for i in 0..<36000 { chunker.ingest(samples,speaker:i%2 == 0 ? .me : .them,at:Double(i)/10) }
        chunker.finish()
        check(collector.count >= 298 && collector.largest <= 193600,"10: one-hour audio segmenter stays bounded")
        check(collector.speakers == Set(AudioSource.allCases),"pipeline preserves both speaker channels")
        var bad = base; bad.evidence_excerpt = "A fabricated statement nobody said in this interview."
        var temp = EditorialState()
        check(!temp.accept(bad,transcript:transcript,knownTitles:[],sensitivity:.balanced),"fabricated evidence rejected")
        bad = base; bad.timestamp = 999
        check(!temp.accept(bad,transcript:transcript,knownTitles:[],sensitivity:.balanced),"invented timestamp rejected")
        bad = base; bad.confidence = 0.8
        check(!temp.accept(bad,transcript:transcript,knownTitles:[],sensitivity:.balanced),"balanced threshold applied")
        var cooldownState = EditorialState(); _ = cooldownState.accept(base,transcript:transcript,knownTitles:[],sensitivity:.balanced,now:t)
        check(!cooldownState.accept(person,transcript:SimulationFixtures.scenarios[2].lines.map(\.prompt).joined(separator:"\n"),knownTitles:[],sensitivity:.balanced,now:t.addingTimeInterval(1)),"cooldown rejects burst")
        rejects("OAuth rejects mismatched state") { _ = try OAuthValidation.callback(URL(string:"http://127.0.0.1/auth/callback?code=x&client_id=issued&state=evil")!,state:"expected",clientID:nil) }
        rejects("OAuth rejects registration entrypoint as issued ID") { _ = try OAuthValidation.callback(URL(string:"http://127.0.0.1/auth/callback?code=x&client_id=dynamic_agent_client&state=s")!,state:"s",clientID:nil) }
        rejects("OAuth rejects changed client ID") { _ = try OAuthValidation.callback(URL(string:"http://127.0.0.1/auth/callback?code=x&client_id=b&state=s")!,state:"s",clientID:"a") }
        rejects("OAuth rejects declined consent") { _ = try OAuthValidation.callback(URL(string:"http://127.0.0.1/auth/callback?error=access_denied&state=s")!,state:"s",clientID:nil) }
        rejects("OAuth rejects duplicate query") { _ = try OAuthValidation.callback(URL(string:"http://127.0.0.1/auth/callback?code=x&client_id=a&state=s&state=s")!,state:"s",clientID:nil) }
        check(OAuthValidation.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM","PKCE RFC7636 vector")
        let claims: [String:Any] = ["iss":"https://auth.openai.com","aud":"client","sub":"subject","nonce":"n","exp":Date().timeIntervalSince1970+300]
        do { let subject = try OAuthValidation.validateClaims(claims,clientID:"client",nonce:"n"); check(subject == "subject","identity claims validated") } catch { check(false,"valid claims") }
        rejects("OIDC rejects nonce mismatch") { _ = try OAuthValidation.validateClaims(claims,clientID:"client",nonce:"bad") }
        rejects("OIDC rejects expired identity") { _ = try OAuthValidation.validateClaims(claims,clientID:"client",nonce:"n",now:Date().addingTimeInterval(600)) }
        rejects("unsigned JWT rejected") { _ = try OAuthValidation.verifyJWT("e30.e30.fake",jwks:Data("{\"keys\":[]}".utf8),clientID:"client",nonce:"n") }
        rejects("manual callback rejects a different host") { let l = OAuthLoopback(); try l.submitManual(URL(string:"http://example.com/auth/callback?code=x")!) }
        rejects("identity-only scopes cannot authorize inference") { _ = try OAuthValidation.grantedScopes("openid profile email") }
        do { let scopes = try OAuthValidation.grantedScopes("openid resource.invoke chatgpt.tokens.use.direct"); check(scopes.count == 3,"plan usage scopes accepted") } catch { check(false,"plan scopes") }
        do {
            let attrs: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeySizeInBits as String:2048]
            guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary,nil), let publicKey = SecKeyCopyPublicKey(privateKey),
                  let representation = SecKeyCopyExternalRepresentation(publicKey,nil) as Data? else { throw ProducerError.message("test key generation failed") }
            let data = [UInt8](representation); var offset = 0
            func length() -> Int { let b = Int(data[offset]); offset += 1; if b < 128 { return b }; var n = 0; for _ in 0..<(b & 127) { n = (n << 8)|Int(data[offset]); offset += 1 }; return n }
            offset += 1; _ = length()
            func integer() -> Data { offset += 1; let count = length(); let result = Data(data[offset..<offset+count]); offset += count; return result.first == 0 ? result.dropFirst() : result }
            let modulus = integer(), exponent = integer()
            let header = OAuthValidation.base64URL(try JSONSerialization.data(withJSONObject:["alg":"RS256","kid":"test"]))
            let payload = OAuthValidation.base64URL(try JSONSerialization.data(withJSONObject:claims))
            let signingInput = Data((header+"."+payload).utf8)
            guard let signature = SecKeyCreateSignature(privateKey,.rsaSignatureMessagePKCS1v15SHA256,signingInput as CFData,nil) as Data? else { throw ProducerError.message("test signing failed") }
            let jwt = header+"."+payload+"."+OAuthValidation.base64URL(signature)
            let jwks = try JSONSerialization.data(withJSONObject:["keys":[["kid":"test","kty":"RSA","n":OAuthValidation.base64URL(modulus),"e":OAuthValidation.base64URL(exponent)]]])
            let validated = try OAuthValidation.verifyJWT(jwt,jwks:jwks,clientID:"client",nonce:"n")
            check(validated["sub"] as? String == "subject","real RSA signature validates against JWK")
            var corrupt = signature; corrupt[0] ^= 1
            rejects("tampered RSA signature rejected") { _ = try OAuthValidation.verifyJWT(header+"."+payload+"."+OAuthValidation.base64URL(corrupt),jwks:jwks,clientID:"client",nonce:"n") }
        } catch { check(false,"cryptographic JWT roundtrip: \(error.localizedDescription)") }
        let pipelineProbe = PipelineProbe()
        let pipeline = TranscriptPipeline(onLine:{ line in await pipelineProbe.add(line) },onError:{ error in await pipelineProbe.error(error) },transcriber:{ chunk in try await pipelineProbe.transcribe(chunk) })
        let a = AudioChunk(speaker:.them,start:1,end:2,samples:[0.1])
        await pipeline.enqueue(a); await pipeline.enqueue(a)
        let b = AudioChunk(speaker:.me,start:3,end:4,samples:[0.1]); await pipeline.enqueue(b)
        await pipeline.drain()
        let pipelineResult = await pipelineProbe.result()
        check(pipelineResult.calls == 2,"pipeline does not retranscribe a processed chunk")
        check(pipelineResult.errors == 1 && pipelineResult.lines == 1,"pipeline records outage gap then recovers on next chunk")
        let quietCollector = ChunkCollector(); let quiet = PCMChunker(); quiet.onChunk = { quietCollector.append($0) }
        for n in 0..<100 { quiet.ingest([Float](repeating:0,count:1600),speaker:.them,at:Double(n)/10) }; quiet.finish()
        check(quietCollector.count == 0,"silence generates no transcription requests")
        var r = InterviewRecord(); r.lines = SimulationFixtures.revelation; r.simulation = true; r.suggestions = [.init(decision:base,status:"saved")]
        do {
            let json = try InterviewStore.export(r,format:"json"); let round = try JSONDecoder().decode(InterviewRecord.self,from:json)
            check(round.lines == r.lines && round.suggestions[0].status == "saved","JSON export preserves labels, timestamps and status")
            let md = String(data:try InterviewStore.export(r,format:"md"),encoding:.utf8) ?? ""
            check(md.contains("[00:10] Interviewee") && md.contains("SIMULATION"),"Markdown export labels synthetic data and quotes")
            r.suggestions[0].status = "asked"; check(r.suggestions[0].status == "asked","manual asked state retained")
        } catch { check(false,"export roundtrip") }
        print("\n\(total-failures.count)/\(total) deterministic checks passed. These test validation, authorization rejection, pipeline bounds and management; they do not certify live model judgments, Zoom or cloud services.")
        return failures.isEmpty ? 0 : 1
    }
    static func live() async -> Int32 {
        var failed = 0
        for scenario in SimulationFixtures.scenarios {
            let service = EditorialService()
            do {
                let result = try await service.analyze(lines:scenario.lines,research:ProducerEditorialPrompt.research+"\n"+ResearchLibrary.published,known:[])
                let ok = result.decision.should_suggest == scenario.expectAlert
                print("\(ok ? "PASS" : "FAIL") \(scenario.name): \(result.decision.should_suggest ? result.decision.suggested_question : "silent")")
                if !ok { failed += 1 }
            } catch { print("UNVERIFIED \(scenario.name): \(error.localizedDescription)"); failed += 1 }
        }
        return failed == 0 ? 0 : 1
    }
}
final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private var maxSize = 0; private var sources = Set<AudioSource>()
    func append(_ chunk: AudioChunk) { lock.withLock { n += 1; maxSize = max(maxSize,chunk.samples.count); sources.insert(chunk.speaker) } }
    var count: Int { lock.withLock { n } }; var largest: Int { lock.withLock { maxSize } }; var speakers: Set<AudioSource> { lock.withLock { sources } }
}

actor PipelineProbe {
    private var calls = 0; private var errors = 0; private var lines = 0
    func transcribe(_ chunk: AudioChunk) throws -> String { calls += 1; if calls == 1 { throw ProducerError.message("simulated provider outage") }; return "Recovered transcript" }
    func add(_ line: InterviewLine) { lines += 1 }
    func error(_ text: String) { errors += 1 }
    func result() -> (calls:Int,errors:Int,lines:Int) { (calls,errors,lines) }
}
