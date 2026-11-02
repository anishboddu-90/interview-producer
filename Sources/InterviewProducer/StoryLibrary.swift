import Foundation
import Observation

@MainActor @Observable final class StoryLibrary {
    var ledger = StoryLedger()
    var status = "Investigations are provisional; open a direction to inspect its original evidence."
    var busy = false
    var progress = ""
    var activeBrief: StoryBrief?
    private let file: URL
    private var writable = true
    @ObservationIgnored private var indexedEvidence: [ResearchEvidence] = []
    @ObservationIgnored private var indexedTokens: [String:Set<String>] = [:]
    init(url: URL? = nil) {
        file = url ?? InterviewStore.directory.deletingLastPathComponent().appendingPathComponent("story-editor.json")
        if FileManager.default.fileExists(atPath:file.path) {
            do { ledger = try JSONDecoder().decode(StoryLedger.self,from:Data(contentsOf:file)); activeBrief = ledger.briefs.last }
            catch { writable = false; status = "Story state could not be read and has not been overwritten: \(error.localizedDescription)" }
        }
    }
    func persist() throws {
        guard writable else { throw ProducerError.message("Existing story state is unreadable. Keep a backup and repair that file before saving new state.") }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(ledger).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func index(_ records: [InterviewRecord]) {
        indexedEvidence = StoryEvidence.passages(records.filter { !$0.simulation && $0.includeInStory != false })
        indexedTokens = Dictionary(indexedEvidence.map { ($0.id,EditorialState.key($0.excerpt)) },uniquingKeysWith:{a,_ in a})
    }
    func crossEvidence(query: String,currentID: UUID?) -> [ResearchEvidence] {
        let keys = EditorialState.key(query)
        let ranked = indexedEvidence.enumerated().compactMap { index,e -> (Int,Int,ResearchEvidence)? in
            guard e.conversationID != currentID?.uuidString else { return nil }
            let score = keys.intersection(indexedTokens[e.id] ?? []).count
            return score == 0 ? nil : (score,index,e)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
        var byPerson = [String:Int]()
        return Array(ranked.prefix(20).map(\.2).filter { e in
            let key = e.role; guard byPerson[key,default:0] < 2 else { return false }; byPerson[key,default:0] += 1; return true
        }.prefix(4))
    }
    func apply(_ updates: [StoryUpdate],interview: InterviewRecord? = nil) throws {
        var next = ledger
        var added = 0
        for update in updates {
            let lane = try StoryEvidence.lane(update.lead.lane)
            let i = next.directions.firstIndex { d in
                d.id == lane && d.updates.isEmpty ||
                (d.id == lane || d.id.hasPrefix(lane+"-")) && EditorialState.sameTopic(d.title,update.lead.question)
            }
            let signature = update.support.map(\.id).sorted()+update.opposition.map(\.id).sorted()
            if let i {
                if next.directions[i].updates.contains(where: { $0.support.map(\.id).sorted()+$0.opposition.map(\.id).sorted() == signature }) { continue }
                next.directions[i].title = update.lead.question
                next.directions[i].updates.append(update)
            } else {
                let id = lane+"-"+String(MemoryIdentity.digest(update.lead.question).prefix(10))
                next.directions.append(.init(id:id,title:update.lead.question,updates:[update]))
            }
            added += 1
        }
        if let interview { next.interviewVersions[interview.id.uuidString] = StoryEvidence.fingerprint(interview) }
        let old = ledger; ledger = next
        do { try persist() } catch { ledger = old; throw error }
        status = added == 0 ? "No new consequential lead; original evidence remains available." : "\(added) investigation update\(added == 1 ? "" : "s") saved with original-source receipts."
    }
    func acceptLive(_ leads: [StoryLead],evidence: [ResearchEvidence],source: String) {
        guard !leads.isEmpty else { return }
        do {
            guard leads.count <= 1 else { throw ProducerError.message("Too many live investigation proposals.") }
            let updates = try leads.map { try StoryEvidence.validate($0,evidence:evidence,label:"Live interview — \(source)") }
            guard updates.allSatisfy({$0.support.contains(where:{$0.evidence.origin == "interview"})}) else { throw ProducerError.message("A live lead has no original interview receipt.") }
            try apply(updates)
        } catch { status = "Live follow-ups continue; a story update was withheld: \(error.localizedDescription)" }
    }
    func saveBrief(_ brief: StoryBrief) throws {
        let old = ledger; ledger.briefs.append(brief)
        do { try persist(); activeBrief = brief; status = "Source-specific brief saved. Confirm background and evidence before use." }
        catch { ledger = old; throw error }
    }
    func edit(id: String,note: String,parked: Bool) throws {
        guard note.count <= 6000, let i = ledger.directions.firstIndex(where:{$0.id == id}) else { throw ProducerError.message("Direction note exceeds 6,000 characters or direction is missing.") }
        let old = ledger
        ledger.directions[i].note = note; ledger.directions[i].parked = parked
        do { try persist() } catch { ledger = old; throw error }
    }
    func removeInterview(_ id: UUID) throws {
        let key = id.uuidString
        // Do not silently resend deleted originals through derived investigation state or brief snapshots.
        for i in ledger.directions.indices {
            ledger.directions[i].updates.removeAll { ($0.support+$0.opposition).contains(where:{$0.evidence.origin == "interview" && $0.evidence.conversationID == key}) }
        }
        ledger.briefs.removeAll { $0.evidence.contains(where:{$0.origin == "interview" && $0.conversationID == key}) }
        activeBrief = ledger.briefs.last; ledger.interviewVersions.removeValue(forKey:key)
        try persist()
    }
    func isCurrent(_ receipt: StoryReceipt,records: [InterviewRecord]) -> Bool {
        let e = receipt.evidence
        guard e.origin == "interview" else { return true }
        guard let record = records.first(where:{$0.id.uuidString == e.conversationID}), record.includeInStory != false,
              let line = record.lines.first(where:{$0.id.uuidString == e.nodeID}), line.text.contains(receipt.quote) else { return false }
        let chars = Array(line.text)
        return stride(from:0,to:chars.count,by:1400).contains { offset in
            e.id.hasPrefix(StoryEvidence.passage(line,record:record,text:String(chars[offset..<min(offset+1600,chars.count)]),offset:offset).id)
        }
    }
    func currentDirections(records: [InterviewRecord]) -> [StoryDirection] {
        // Keep old receipts visible in UI, but never send stale/excluded testimony as current source context.
        ledger.directions.map { direction in
            var result = direction
            result.updates = direction.updates.filter { ($0.support+$0.opposition).allSatisfy { isCurrent($0,records:records) } }
            return result
        }
    }
}

enum StoryInterviewImport {
    static func read(_ url: URL,source: String,background: String) throws -> InterviewRecord {
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count <= 20_000_000 else { throw ProducerError.message("Interview import is limited to 20 MB. Split a larger transcript into labeled parts.") }
        var record: InterviewRecord
        if url.pathExtension.lowercased() == "json" {
            record = try JSONDecoder().decode(InterviewRecord.self,from:data)
        } else {
            guard let text = String(data:data,encoding:.utf8) else { throw ProducerError.message("Import a UTF-8 timestamped transcript or an Interview Producer JSON export.") }
            let regex = try NSRegularExpression(pattern:#"^\[(\d{1,3}:\d{2}(?::\d{2})?)\]\s*(Interviewee|Them|Journalist|Me|Interviewer):\s*(.*)$"#,options:.caseInsensitive)
            var lines = [InterviewLine]()
            for row in text.components(separatedBy:.newlines) {
                if let match = regex.firstMatch(in:row,range:NSRange(row.startIndex...,in:row)),
                   let sr = Range(match.range(at:1),in:row), let rr = Range(match.range(at:2),in:row),let tr = Range(match.range(at:3),in:row) {
                    let parts = row[sr].split(separator:":").compactMap { Double($0) }
                    let start = parts.reduce(0) { $0*60+$1 }
                    guard start.isFinite, start >= 0, start <= 86400, parts.dropFirst().allSatisfy({$0 < 60}), start >= (lines.last?.start ?? 0) else { throw ProducerError.message("Transcript timestamps must be valid and chronological.") }
                    let role = row[rr].lowercased()
                    if !lines.isEmpty { lines[lines.count-1].end = start }
                    lines.append(.init(start:start,end:start+1,speaker:["interviewee","them"].contains(role) ? .them : .me,text:String(row[tr])))
                } else if !row.trimmingCharacters(in:.whitespaces).isEmpty {
                    guard !lines.isEmpty else { throw ProducerError.message("Each transcript turn must start with [mm:ss] Interviewee: or [mm:ss] Journalist:. No speaker identities are guessed.") }
                    lines[lines.count-1].text += "\n"+row
                }
            }
            guard !lines.isEmpty else { throw ProducerError.message("No timestamped speaker turns were found.") }
            record = InterviewRecord(); record.lines = lines; record.title = url.deletingPathExtension().lastPathComponent
        }
        let name = source.trimmingCharacters(in:.whitespacesAndNewlines)
        // A previous planned interview must never overwrite a named source in an imported JSON export.
        if (record.sourceName ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !name.isEmpty { record.sourceName = name }
        guard !(record.sourceName ?? "").isEmpty else { throw ProducerError.message("Name this interview's source before importing so testimony remains attributed.") }
        guard record.lines.count <= 200000, record.title.count <= 1000, (record.sourceName ?? "").count <= 200,
              record.date.timeIntervalSince1970.isFinite, abs(record.date.timeIntervalSince1970) < 10_000_000_000,
              record.lines.allSatisfy({$0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 86400 && $0.text.count <= 300000}) else {
            throw ProducerError.message("Imported interview has invalid dates, timestamps or oversized turns. No interview was saved.")
        }
        if (record.sourceBackground ?? "").isEmpty, !background.isEmpty { record.sourceBackground = background }
        // Imported files never grant authority to delete arbitrary audio paths.
        record.systemAudioPath = nil; record.micAudioPath = nil
        record.importedOriginal = data; record.status = "imported transcript — verify against original recording"
        record.includeInStory = true
        return record
    }
}
