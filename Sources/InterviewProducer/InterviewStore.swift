import Foundation

struct InterviewLine: Codable, Identifiable, Equatable {
    var id = UUID(); var start: Double; var end: Double; var speaker: AudioSource; var text: String
    var stamp: String { String(format:"%02d:%02d",Int(start)/60,Int(start)%60) }
    var prompt: String { "[\(stamp)] \(speaker.label): \(text)" }
}
struct SavedSuggestion: Codable, Identifiable {
    var id = UUID(); var decision: EditorialDecision; var status = "new"
    var evidence: [ResearchEvidence]? = nil
    var suppliedEvidence: [ResearchEvidence]? = nil
}
struct InterviewRecord: Codable, Identifiable {
    var id = UUID(); var date = Date(); var title = "Interview"
    var consent = ""; var simulation = false; var status = "recording"
    var lines: [InterviewLine] = []; var suggestions: [SavedSuggestion] = []
    var threads: [EditorialThread] = []; var notes = ""; var research = ""
    var systemAudioPath: String?; var micAudioPath: String?
    var setupContext: String? = nil
    var sourceName: String? = nil; var sourceBackground: String? = nil
    var includeInStory: Bool? = nil; var importedOriginal: Data? = nil
    var storyReport: SavedStoryReport? = nil
    var questionProfileID: String? = nil
    var lifelines: [SavedLifeline]? = nil
    var rehearsal: Bool? = nil
    var isSynthetic: Bool { simulation || rehearsal == true }
    var transcript: String { lines.sorted { $0.start < $1.start }.map(\.prompt).joined(separator:"\n") }
}
enum InterviewStore {
    static var directory: URL {
        let d = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("InterviewProducer/Interviews")
        try? FileManager.default.createDirectory(at:d,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); return d
    }
    static func save(_ r: InterviewRecord,in location: URL? = nil) throws {
        let folder = location ?? directory
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url = folder.appendingPathComponent(r.id.uuidString+".json")
        let data = try JSONEncoder().encode(r)
        try data.write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func list(in location: URL? = nil) -> [InterviewRecord] {
        ((try? FileManager.default.contentsOfDirectory(at:location ?? directory,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(InterviewRecord.self,from:Data(contentsOf:$0)) }.sorted { $0.date > $1.date }
    }
    static func delete(_ r: InterviewRecord,in location: URL? = nil,audioDirectory: URL? = nil) throws {
        for path in [r.systemAudioPath,r.micAudioPath].compactMap({$0}) {
            let url = URL(fileURLWithPath:path).standardizedFileURL
            guard url.path.hasPrefix((audioDirectory ?? AudioCaptureManager.storageDirectory()).standardizedFileURL.path+"/") else { continue }
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        }
        let url = (location ?? directory).appendingPathComponent(r.id.uuidString+".json")
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
    static func export(_ r: InterviewRecord, format: String) throws -> Data {
        if format == "json" { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; return try e.encode(r) }
        let questions = r.suggestions.map { item in "[\(Int(item.decision.timestamp)/60):\(String(format:"%02d",Int(item.decision.timestamp)%60))] [\(item.status)] \(item.decision.suggested_question)\n\(item.decision.reason)\nEvidence: \(item.decision.evidence_excerpt)" + (item.evidence ?? []).map { "\nSource [\($0.id)]: \($0.title)\nAuthor: \($0.role) · \($0.classification)\n\($0.reference)\n\($0.excerpt)\nSeparate annotation: \($0.annotation ?? "none")" }.joined() }.joined(separator:"\n\n")
        let lifelines = (r.lifelines ?? []).map { "[\($0.status)] \($0.question.text)\nBridge: \($0.bridge)\nReason: \($0.reason)\nQuestion ID: \($0.question.id) · profile \($0.profileID)" }.joined(separator:"\n\n")
        let out = "# \(r.title)\n\n\(r.date.formatted())\nSource: \(StoryEvidence.source(r))\nConsent: \(r.consent)\nMode: \(r.isSynthetic ? "SIMULATION — synthetic data" : "Recorded interview")\n\n## Editorial notes\n\n\(r.notes)\n\n## Follow-up history\n\n\(questions)\n\n## Question Lifeline history\n\n\(lifelines)\n\n## Full transcript\n\n\(r.transcript)\n"
        return Data((format == "txt" ? out.replacingOccurrences(of:"# ",with:"") : out).utf8)
    }
}
