import Foundation

struct ExportConversationPreview: Identifiable, Sendable {
    var id: String; var originalID: String; var title: String; var created: Double?
    var messageCount: Int; var branchCount: Int; var source: URL; var offset: UInt64; var length: Int; var sha256: String
}
/// Holds only local temporary JSON files and lightweight descriptors, not the whole export in RAM.
final class MemoryImportSession: Identifiable, @unchecked Sendable {
    let id = UUID(); let conversations: [ExportConversationPreview]; let temporaryDirectory: URL?
    init(conversations: [ExportConversationPreview],temporaryDirectory: URL? = nil) { self.conversations = conversations; self.temporaryDirectory = temporaryDirectory }
    deinit { if let temporaryDirectory { try? FileManager.default.removeItem(at:temporaryDirectory) } }
}
enum ChatGPTExportReader {
    static let fileLimit = 1_073_741_824
    static let conversationLimit = 67_108_864
    static func open(_ url: URL) throws -> MemoryImportSession {
        if url.pathExtension.lowercased() != "zip" { return MemoryImportSession(conversations:try preview(url)) }
        let listing = try runUnzip(["-Z1",url.path],limit:4_194_304)
        let names = String(decoding:listing,as:UTF8.self).components(separatedBy:.newlines).filter {
            $0.range(of:"(^|/)conversations(?:-[0-9]+)?\\.json$",options:.regularExpression) != nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty, names.count <= 1000, Set(names).count == names.count else { throw ProducerError.message("The ZIP must contain conversations.json or numbered conversations-*.json export shards.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterviewProducer-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            var previews = [ExportConversationPreview](); var totalBytes = 0
            for (index,name) in names.enumerated() {
                guard !name.hasPrefix("-"), !name.contains("*"), !name.contains("?"), !name.contains("["), !name.contains("]") else { throw ProducerError.message("Unsupported ZIP member name. Extract conversations.json yourself and choose it directly.") }
                let target = folder.appendingPathComponent("conversations-\(index).json")
                _ = FileManager.default.createFile(atPath:target.path,contents:nil,attributes:[.posixPermissions:0o600])
                let file = try FileHandle(forWritingTo:target); defer { try? file.close() }
                _ = try runUnzip(["-p",url.path,name],limit:fileLimit,output:file)
                totalBytes += (try target.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
                guard totalBytes <= fileLimit else { throw ProducerError.message("Combined conversation JSON exceeds 1 GiB. Import extracted shards separately.") }
                previews += try preview(target)
            }
            return MemoryImportSession(conversations:previews,temporaryDirectory:folder)
        } catch { try? FileManager.default.removeItem(at:folder); throw error }
    }
    private static func runUnzip(_ arguments: [String],limit: Int,output: FileHandle? = nil) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); var result = Data(); var count = 0
        do {
            while let bytes = try pipe.fileHandleForReading.read(upToCount:65536), !bytes.isEmpty {
                count += bytes.count
                guard count <= limit else { process.terminate(); throw ProducerError.message("Export exceeds the supported size. No conversations were imported.") }
                if let output { try output.write(contentsOf:bytes) } else { result.append(bytes) }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProducerError.message("Cannot read this ZIP. Choose its extracted conversations.json instead.") }
            return result
        } catch { if process.isRunning { process.terminate() }; process.waitUntilExit(); throw error }
    }
    static func raw(_ preview: ExportConversationPreview) throws -> Data {
        let file = try FileHandle(forReadingFrom:preview.source); defer { try? file.close() }
        try file.seek(toOffset:preview.offset)
        guard let data = try file.read(upToCount:preview.length), data.count == preview.length,
              MemoryIdentity.digest(data) == preview.sha256 else { throw ProducerError.message("The export changed after preview. Select it again before importing.") }
        return data
    }
    /// Frame one top-level conversation object at a time. Quoting and escapes are
    /// tracked across 64 KiB reads; exact object bytes are retained on import.
    static func preview(_ url: URL) throws -> [ExportConversationPreview] {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= fileLimit else { throw ProducerError.message("JSON export exceeds 1 GiB. Import smaller export shards.") }
        let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
        var offset: UInt64 = 0; var objectStart: UInt64 = 0
        var started = false; var ended = false; var depth = 0; var quoted = false; var escaped = false
        var needComma = false; var afterComma = false
        var result = [ExportConversationPreview]()
        while let data = try file.read(upToCount:65536), !data.isEmpty {
            for byte in data {
                defer { offset += 1 }
                let white = byte == 32 || byte == 9 || byte == 10 || byte == 13
                if !started { if white { continue }; guard byte == 91 else { throw ProducerError.message("Expected ChatGPT's JSON array of conversations, with mapping message trees.") }; started = true; continue }
                if ended { guard white else { throw ProducerError.message("Unexpected content after the export array.") }; continue }
                if depth == 0 {
                    if white { continue }
                    if byte == 93 { guard !afterComma else { throw ProducerError.message("Malformed export array.") }; ended = true; continue }
                    if needComma { guard byte == 44 else { throw ProducerError.message("Malformed export array separator.") }; needComma = false; afterComma = true; continue }
                    guard byte == 123 else { throw ProducerError.message("Every exported conversation must be a JSON object.") }
                    depth = 1; objectStart = offset; quoted = false; escaped = false; afterComma = false; continue
                }
                guard offset-objectStart < UInt64(conversationLimit) else { throw ProducerError.message("A conversation exceeds 64 MiB. No text was truncated; this import was stopped.") }
                if quoted {
                    if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 123 { depth += 1 }
                else if byte == 125 {
                    depth -= 1
                    if depth == 0 {
                        let length = Int(offset-objectStart+1)
                        let read = try FileHandle(forReadingFrom:url); try read.seek(toOffset:objectStart)
                        let raw = try read.read(upToCount:length) ?? Data(); try read.close()
                        guard let root = try JSONSerialization.jsonObject(with:raw) as? [String:Any], let mapping = root["mapping"] as? [String:Any] else { throw ProducerError.message("A conversation has no mapping tree. No messages were silently discarded.") }
                        let hash = MemoryIdentity.digest(raw)
                        let originalID = root["id"] as? String ?? root["conversation_id"] as? String ?? "missing-id-\(hash)"
                        let messages = mapping.values.compactMap { ($0 as? [String:Any])?["message"] as? [String:Any] }.count
                        let branches = try ExportGraph(root:root).paths.count
                        result.append(.init(id:MemoryIdentity.digest("\(url.path)|\(objectStart)|\(hash)"),originalID:originalID,
                                            title:root["title"] as? String ?? "Untitled conversation",created:timestamp(root["create_time"]),
                                            messageCount:messages,branchCount:branches,source:url,offset:objectStart,length:length,sha256:hash))
                        needComma = true
                    }
                }
            }
        }
        guard started, ended, depth == 0, !quoted else { throw ProducerError.message("The export is truncated or malformed. Nothing was imported.") }
        return result
    }
    static func timestamp(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? ISO8601DateFormatter().date(from:s)?.timeIntervalSince1970 }
        return nil
    }
    static func text(_ message: [String:Any]) -> String {
        guard let content = message["content"] as? [String:Any] else { return "" }
        func partText(_ value: Any) -> [String] {
            if let text = value as? String { return [text] }
            if let object = value as? [String:Any] {
                if let text = object["text"] as? String { return [text] }
                if let text = object["transcription"] as? String { return [text] }
                if let nested = object["content"] { return partText(nested) }
            }
            return []
        }
        if let parts = content["parts"] as? [Any] { return parts.flatMap(partText).joined(separator:"\n") }
        if let text = content["text"] as? String { return text }
        return ""
    }
}
