import Foundation

enum QuestionBankIO {
    static func validate(_ p: QuestionProfile) throws {
        guard !p.id.isEmpty, p.id.count <= 150, p.name.count <= 250, p.source.count <= 200,
              p.questions.count <= 500, Set(p.questions.map(\.id)).count == p.questions.count,
              (6...60).contains(p.settings.silenceSeconds), (30...600).contains(p.settings.cooldownSeconds),
              ["Conservative","Balanced"].contains(p.settings.sensitivity),
              p.settings.remainingMinutes.map({(1...240).contains($0)}) ?? true else { throw ProducerError.message("Invalid question profile, duplicate IDs or unsupported settings.") }
        for q in p.questions {
            guard !q.id.isEmpty, q.id.count <= 150, q.text.count <= 3000, q.category.count <= 150, (1...5).contains(q.priority),
                  (q.transition ?? "").count <= 400, (q.researchContext ?? "").count <= 6000, (q.notes ?? "").count <= 6000 else { throw ProducerError.message("Question fields exceed their limits or have invalid values. No question was truncated.") }
        }
    }
    static func read(_ url: URL) throws -> QuestionProfile {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw ProducerError.message("Question import is limited to 10 MB.") }
        let data = try Data(contentsOf:url)
        let profile: QuestionProfile
        if url.pathExtension.lowercased() == "json" {
            if let array = try? JSONDecoder().decode([LifelineQuestion].self,from:data) { profile = .init(name:url.deletingPathExtension().lastPathComponent,questions:array) }
            else { profile = try JSONDecoder().decode(QuestionProfile.self,from:data) }
        } else {
            guard let text = String(data:data,encoding:.utf8) else { throw ProducerError.message("Markdown questions must use UTF-8.") }
            profile = try markdown(text,name:url.deletingPathExtension().lastPathComponent)
        }
        try validate(profile); return profile
    }
    static func export(_ p: QuestionProfile,format: String) throws -> Data {
        try validate(p)
        if format == "json" { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; return try e.encode(p) }
        // A complete JSON block keeps all fields and exact wording lossless across Markdown roundtrips.
        let json = String(decoding:try export(p,format:"json"),as:UTF8.self)
        let readable = p.questions.enumerated().map { i,q in "\(i+1). \(q.text)\n   Category: \(q.category) · Priority: \(q.priority) · Status: \(q.status.rawValue) · Essential: \(q.essential)" }.joined(separator:"\n\n")
        return Data(("# \(p.name)\n\n\(readable)\n\n<!-- Complete reusable profile; importer prefers this exact metadata block. -->\n```interview-producer-questions\n\(json)\n```\n").utf8)
    }
    static func markdown(_ text: String,name: String) throws -> QuestionProfile {
        if let open = text.range(of:"```interview-producer-questions\n"), let close = text.range(of:"\n```",range:open.upperBound..<text.endIndex) {
            let p = try JSONDecoder().decode(QuestionProfile.self,from:Data(text[open.upperBound..<close.lowerBound].utf8)); try validate(p); return p
        }
        let pattern = try NSRegularExpression(pattern:#"^\s*(?:\d+[.)]|[-*]\s+\[[ xX]\])\s+(.+)$"#)
        var p = QuestionProfile(name:name); var category = "General"
        var sawTitle = false
        for raw in text.components(separatedBy:.newlines) {
            if raw.hasPrefix("# ") { p.name = String(raw.dropFirst(2)); sawTitle = true; continue }
            if raw.hasPrefix("## ") { category = String(raw.dropFirst(3)); continue }
            if let m = pattern.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)), let range = Range(m.range(at:1),in:raw) {
                p.questions.append(.init(text:String(raw[range]),category:category)); continue
            }
            guard !raw.trimmingCharacters(in:.whitespaces).isEmpty else { continue }
            if p.questions.isEmpty {
                if !sawTitle { p.name = raw; sawTitle = true; category = raw; continue }
                throw ProducerError.message("Use numbered Markdown questions; no unrecognized text was silently dropped.")
            }
            let field = raw.trimmingCharacters(in:.whitespaces)
            let i = p.questions.count-1
            func value(_ prefix: String) -> String? { field.hasPrefix(prefix+": ") ? String(field.dropFirst(prefix.count+2)) : nil }
            if let v = value("ID") { p.questions[i].id = v }
            else if let v = value("Category") { p.questions[i].category = v }
            else if let v = value("Priority") { guard let n = Int(v) else { throw ProducerError.message("Priority must be 1–5.") }; p.questions[i].priority = n }
            else if let v = value("Status") { guard let status = QuestionStatus(rawValue:v) else { throw ProducerError.message("Unknown question status.") }; p.questions[i].status = status }
            else if let v = value("Essential") { guard ["true","false"].contains(v.lowercased()) else { throw ProducerError.message("Essential must be true or false.") }; p.questions[i].essential = v.lowercased() == "true" }
            else if let v = value("Transition") { p.questions[i].transition = v }
            else if let v = value("Research context") { p.questions[i].researchContext = v }
            else if let v = value("Notes") { p.questions[i].notes = v }
            else { p.questions[i].text += "\n"+raw }
        }
        guard !p.questions.isEmpty else { throw ProducerError.message("No numbered questions were found.") }
        try validate(p); return p
    }
}
