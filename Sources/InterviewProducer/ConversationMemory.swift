import Foundation

struct MemoryImportResult: Sendable { var imported = 0; var skipped = 0; var warnings = [String]() }
struct ExportGraph {
    var mapping: [String:[String:Any]]
    var order: [String] = []
    var paths: [(leaf:String,path:[String],active:Bool)] = []
    var activeNodes = Set<String>()
    var canonical: [String:String] = [:]
    var warnings = [String]()
    init(root: [String:Any]) throws {
        guard let raw = root["mapping"] as? [String:Any], raw.count <= 200000 else { throw ProducerError.message("Invalid or oversized conversation mapping; original data was not truncated.") }
        mapping = raw.mapValues { $0 as? [String:Any] ?? [:] }
        guard mapping.values.allSatisfy({!$0.isEmpty}) || mapping.isEmpty else { throw ProducerError.message("A mapping node is malformed. This conversation was not imported.") }
        var children: [String:[String]] = [:]
        for (id,node) in mapping {
            children[id] = node["children"] as? [String] ?? []
        }
        for (id,node) in mapping {
            if let parent = node["parent"] as? String, mapping[parent] != nil, !(children[parent] ?? []).contains(id) {
                children[parent,default:[]].append(id)
                // Current official exports can omit children entirely. Parent-only
                // trees are valid; warn only when an explicit child list conflicts.
                if mapping[parent]?["children"] is [String] {
                    warnings.append("A parent/children mismatch was retained in the original JSON; traversal also follows parent links.")
                }
            }
        }
        let roots = mapping.keys.filter { (mapping[$0]?["parent"] as? String) == nil }.sorted()
        var visited = Set<String>()
        for rootID in roots + mapping.keys.sorted() {
            var stack = [rootID]
            while let id = stack.popLast() {
                guard mapping[id] != nil, visited.insert(id).inserted else { continue }
                order.append(id); stack += (children[id] ?? []).reversed()
            }
        }
        func ancestry(_ leaf: String) -> [String]? {
            var ids = [String](); var current: String? = leaf; var seen = Set<String>()
            while let id = current {
                guard let node = mapping[id], seen.insert(id).inserted else { return nil }
                ids.append(id); current = node["parent"] as? String
            }
            return ids.reversed()
        }
        let leaves = order.filter { (children[$0] ?? []).isEmpty }
        let current = root["current_node"] as? String
        let activeLeaf = current.flatMap { mapping[$0] == nil ? nil : $0 } ?? (leaves.count == 1 ? leaves.first : nil)
        for leaf in leaves + (activeLeaf.map { leaves.contains($0) ? [] : [$0] } ?? []) {
            guard let path = ancestry(leaf) else { warnings.append("An orphan/cyclic branch is preserved but excluded from automatic branch retrieval."); continue }
            paths.append((leaf,path,leaf == activeLeaf))
            for id in path where canonical[id] == nil { canonical[id] = leaf }
        }
        if let path = paths.first(where:{$0.active}) {
            activeNodes = Set(path.path)
            for id in path.path { canonical[id] = path.leaf }
        } else if !mapping.isEmpty { warnings.append("No valid active path was supplied; review alternate branches before enabling their retrieval.") }
        warnings = Array(Set(warnings)).sorted()
    }
}

actor ConversationMemory {
    static let shared = ConversationMemory()
    static var defaultURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("InterviewProducer/Memory/conversations.sqlite")
    }
    static let initialDossier = """
    # Active research dossier
    ## Current goals and priorities
    Add the interview topic, purpose, audience and next reporting steps.
    ## Facts and sources checked by me
    Include a source reference and verification note for each established fact.
    ## Direct observations (subjective)
    Keep observations separate from inferred intentions and verified claims.
    ## Corrections, answered questions and open threads
    Reference original conversations, messages, publications or interview timestamps.
    """
    let url: URL
    private var connection: MemorySQLite?
    init(url: URL = ConversationMemory.defaultURL) { self.url = url }
    private func db() throws -> MemorySQLite {
        if let connection { return connection }
        let result = try MemorySQLite(url:url); connection = result
        if try result.rows("SELECT id FROM dossier_versions LIMIT 1").isEmpty {
            try result.write("INSERT INTO dossier_versions(text_exact,created) VALUES(?,?)",[.text(Self.initialDossier),.number(Date().timeIntervalSince1970)])
        }
        return result
    }
    func importSelected(_ session: MemoryImportSession,ids: Set<String>) async throws -> MemoryImportResult {
        let sql = try db(); var result = MemoryImportResult()
        for preview in session.conversations where ids.contains(preview.id) {
            try Task.checkCancellation()
            let bytes = try ChatGPTExportReader.raw(preview)
            let conversationID = MemoryIdentity.digest(preview.originalID+"|"+preview.sha256)
            if !(try sql.rows("SELECT id FROM conversations WHERE id=?",[.text(conversationID)])).isEmpty { result.skipped += 1; continue }
            guard let root = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw ProducerError.message("Malformed selected conversation.") }
            let graph = try ExportGraph(root:root)
            try sql.transaction {
                try sql.write("INSERT INTO conversations(id,original_id,title,created,updated,current_node,raw_json,sha256,source_name,imported) VALUES(?,?,?,?,?,?,?,?,?,?)",[
                    .text(conversationID),.text(preview.originalID),.text(preview.title),.optional(preview.created),.optional(ChatGPTExportReader.timestamp(root["update_time"])),
                    .optional(root["current_node"] as? String),.data(bytes),.text(preview.sha256),.text(preview.source.lastPathComponent),.number(Date().timeIntervalSince1970)])
                for (ordinal,nodeID) in graph.order.enumerated() {
                    let node = graph.mapping[nodeID]!
                    let message = node["message"] as? [String:Any] ?? [:]
                    let role = (message["author"] as? [String:Any])?["role"] as? String ?? "none"
                    let text = ChatGPTExportReader.text(message)
                    let hidden = ((message["metadata"] as? [String:Any])?["is_visually_hidden_from_conversation"] as? Bool) == true
                    let kind = MemoryKind.inferred(role:role,text:text).rawValue
                    let children = node["children"] as? [String] ?? []
                    let childrenData = try JSONSerialization.data(withJSONObject:children)
                    let rawNode = try JSONSerialization.data(withJSONObject:node,options:[.sortedKeys,.fragmentsAllowed])
                    try sql.write("""
                    INSERT INTO nodes(conversation_id,node_id,parent_id,children_json,ordinal,active,canonical_branch,message_id,role,text_exact,created,updated,hidden,raw_node,kind,source_url)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,[.text(conversationID),.text(nodeID),.optional(node["parent"] as? String),.text(String(decoding:childrenData,as:UTF8.self)),
                          .integer(Int64(ordinal)),.integer(graph.activeNodes.contains(nodeID) ? 1 : 0),.optional(graph.canonical[nodeID]),.optional(message["id"] as? String),
                          .text(role),.text(text),.optional(ChatGPTExportReader.timestamp(message["create_time"])),.optional(ChatGPTExportReader.timestamp(message["update_time"])),
                          .integer(hidden ? 1 : 0),.data(rawNode),.text(kind),.text(Self.urls(in:text).first ?? "")])
                    // Index exact slices only; never summarize or overwrite the original message.
                    let chars = Array(text); var start = 0
                    while start < chars.count {
                        let end = min(start+1000,chars.count); let passage = String(chars[start..<end])
                        let id = "MEM-"+String(MemoryIdentity.digest(conversationID+"|"+nodeID+"|\(start)").prefix(24))
                        try sql.write("INSERT INTO passages(id,conversation_id,node_id,start_offset,end_offset,text_exact) VALUES(?,?,?,?,?,?)",[
                            .text(id),.text(conversationID),.text(nodeID),.integer(Int64(start)),.integer(Int64(end)),.text(passage)])
                        try sql.write("INSERT INTO passages_fts(passage_id,title,text_exact,annotation) VALUES(?,?,?,?)",[.text(id),.text(preview.title),.text(passage),.text("")])
                        if end == chars.count { break }; start = end-200
                    }
                }
                for branch in graph.paths {
                    try sql.write("INSERT INTO branches(conversation_id,leaf_id,active,path_json) VALUES(?,?,?,?)",[
                        .text(conversationID),.text(branch.leaf),.integer(branch.active ? 1 : 0),.text(String(decoding:try JSONEncoder().encode(branch.path),as:UTF8.self))])
                    for (position,nodeID) in branch.path.enumerated() {
                        try sql.write("INSERT INTO branch_nodes(conversation_id,leaf_id,node_id,position) VALUES(?,?,?,?)",[.text(conversationID),.text(branch.leaf),.text(nodeID),.integer(Int64(position))])
                        guard let node = graph.mapping[nodeID], let message = node["message"] as? [String:Any],
                              (message["author"] as? [String:Any])?["role"] as? String == "user",
                              MemoryKind.inferred(role:"user",text:ChatGPTExportReader.text(message)) == .correction else { continue }
                        for previous in branch.path[max(0,position-4)..<position] {
                            try sql.write("INSERT OR IGNORE INTO relations(conversation_id,source_node,target_node,kind) VALUES(?,?,?,'possible correction/disagreement')",[.text(conversationID),.text(nodeID),.text(previous)])
                        }
                    }
                }
            }
            result.imported += 1; result.warnings += graph.warnings.map { "\(preview.title): \($0)" }
            await Task.yield()
        }
        return result
    }
    func conversations() throws -> [MemoryConversation] {
        try db().rows("""
        SELECT c.*, (SELECT count(*) FROM nodes n WHERE n.conversation_id=c.id AND role!='none') AS messages,
          (SELECT count(*) FROM branches b WHERE b.conversation_id=c.id) AS branches
        FROM conversations c ORDER BY coalesce(c.created,c.imported) DESC
        """).map { r in .init(id:r["id"]!.string,originalID:r["original_id"]!.string,title:r["title"]!.string,created:r["created"]?.double,
                            messages:r["messages"]!.int,branches:r["branches"]!.int,excluded:r["excluded"]!.int != 0,includeAlternatives:r["alternatives"]!.int != 0) }
    }
    private func message(_ r: SQLiteRow) -> MemoryMessage {
        .init(conversationID:r["conversation_id"]!.string,nodeID:r["node_id"]!.string,role:r["role"]!.string,text:r["text_exact"]!.string,
              created:r["created"]?.double,active:r["active"]!.int != 0,hidden:r["hidden"]!.int != 0,kind:r["kind"]!.string,note:r["note"]!.string,
              sourceURL:r["source_url"]!.string,threadStatus:r["thread_status"]!.string,pinned:r["pinned"]!.int != 0,excluded:r["excluded"]!.int != 0,
              parentID:r["parent_id"]?.string.nilIfMemoryEmpty,originalJSON:String(decoding:r["raw_node"]!.blob,as:UTF8.self))
    }
    func messages(conversation: String,branch: String? = nil) throws -> [MemoryMessage] {
        if let branch {
            return try db().rows("SELECT n.* FROM nodes n JOIN branch_nodes b ON b.conversation_id=n.conversation_id AND b.node_id=n.node_id WHERE n.conversation_id=? AND b.leaf_id=? ORDER BY b.position",[.text(conversation),.text(branch)]).map(message)
        }
        return try db().rows("SELECT * FROM nodes WHERE conversation_id=? ORDER BY ordinal",[.text(conversation)]).map(message)
    }
    func branches(conversation: String) throws -> [(String,Bool)] {
        try db().rows("SELECT leaf_id,active FROM branches WHERE conversation_id=? ORDER BY active DESC,leaf_id",[.text(conversation)]).map { ($0["leaf_id"]!.string,$0["active"]!.int != 0) }
    }
    func originalConversation(_ id: String) throws -> Data {
        guard let row = try db().rows("SELECT raw_json FROM conversations WHERE id=?",[.text(id)]).first else { throw ProducerError.message("Conversation no longer exists.") }
        return row["raw_json"]!.blob
    }
    func annotate(conversation: String,node: String,annotation: MemoryAnnotation) throws {
        guard MemoryKind(rawValue:annotation.kind) != nil, ["","open","answered","disputed"].contains(annotation.threadStatus), annotation.note.count <= 6000 else { throw ProducerError.message("Invalid memory annotation.") }
        if annotation.kind == MemoryKind.verifiedSource.rawValue {
            guard let url = URL(string:annotation.sourceURL), ["https","http"].contains(url.scheme ?? ""), !annotation.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ProducerError.message("A verified source needs a source URL and your verification note. Earlier assistant text alone is not evidence.") }
        }
        let sql = try db()
        try sql.transaction {
            try sql.write("UPDATE nodes SET kind=?,note=?,source_url=?,thread_status=?,pinned=?,excluded=? WHERE conversation_id=? AND node_id=?",[
                .text(annotation.kind),.text(annotation.note),.text(annotation.sourceURL),.text(annotation.threadStatus),.integer(annotation.pinned ? 1 : 0),.integer(annotation.excluded ? 1 : 0),.text(conversation),.text(node)])
            try sql.write("UPDATE passages_fts SET annotation=? WHERE passage_id IN(SELECT id FROM passages WHERE conversation_id=? AND node_id=?)",[
                .text(annotation.note+" "+annotation.kind+" "+annotation.threadStatus+" "+annotation.sourceURL),.text(conversation),.text(node)])
        }
    }
    func setConversation(_ id: String,excluded: Bool,alternatives: Bool) throws {
        try db().write("UPDATE conversations SET excluded=?,alternatives=? WHERE id=?",[.integer(excluded ? 1 : 0),.integer(alternatives ? 1 : 0),.text(id)])
    }
    func deleteConversation(_ id: String) throws {
        let sql = try db(); try sql.transaction { try sql.write("DELETE FROM conversations WHERE id=?",[.text(id)]) }
        try sql.exec("INSERT INTO passages_fts(passages_fts) VALUES('optimize'); PRAGMA wal_checkpoint(TRUNCATE);")
    }
    func dossier() throws -> (String,Int) {
        let row = try db().rows("SELECT id,text_exact FROM dossier_versions ORDER BY id DESC LIMIT 1").first!
        return (row["text_exact"]!.string,row["id"]!.int)
    }
    func saveDossier(_ text: String) throws {
        guard text.count <= 6000 else { throw ProducerError.message("Keep the active dossier at 6,000 characters or fewer. Original conversations are stored separately without this limit.") }
        try db().write("INSERT INTO dossier_versions(text_exact,created) VALUES(?,?)",[.text(text),.number(Date().timeIntervalSince1970)])
    }
    static func urls(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern:"https?://[^\\s<>\\\"\\)]+") else { return [] }
        return re.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { Range($0.range,in:text).map { String(text[$0]) } }
    }
}
private extension String { var nilIfMemoryEmpty: String? { isEmpty ? nil : self } }

extension ConversationMemory {
    static func query(_ input: String) -> String {
        let stop: Set<String> = ["the","and","for","that","this","with","what","when","where","which","how","why","you","your","our","are","was","were","have","has","had","did","does","can","could","would","should","about","into","from","there","then","they","them","their","will","just","really","think","tell","said","some","more","music","scene","talk","let","let’s","interview","sound","sounds","now","like","also"]
        var seen = Set<String>()
        let terms = input.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
        return terms.suffix(18).map { "\"\($0)\"" }.joined(separator:" OR ")
    }
    private static let selectEvidence = """
    SELECT p.id AS passage_id,p.text_exact AS passage_text,p.start_offset,p.end_offset,
      n.conversation_id,n.node_id,n.role,n.kind,n.note,n.source_url,n.thread_status,n.created,n.active,n.canonical_branch,c.title,c.original_id
    FROM passages p JOIN nodes n ON n.conversation_id=p.conversation_id AND n.node_id=p.node_id
    JOIN conversations c ON c.id=p.conversation_id
    """
    func search(_ input: String,limit: Int = 30,includeExcluded: Bool = false,includeAlternatives: Bool = true) throws -> [ResearchEvidence] {
        let sql = try db(); let query = Self.query(input)
        let filter = (includeExcluded ? "" : " AND c.excluded=0 AND n.excluded=0 AND n.hidden=0")
            + (includeAlternatives ? "" : " AND (n.active=1 OR c.alternatives=1 OR n.pinned=1)")
            + " AND n.role IN('user','assistant')"
        let rows: [SQLiteRow]
        if query.isEmpty {
            rows = try sql.rows(Self.selectEvidence+" WHERE 1=1"+filter+" ORDER BY n.pinned DESC,c.imported DESC,n.ordinal,p.start_offset LIMIT ?",[.integer(Int64(min(200,max(1,limit))))])
        } else {
            rows = try sql.rows(Self.selectEvidence+" JOIN passages_fts ON passages_fts.passage_id=p.id WHERE passages_fts MATCH ?"+filter+" ORDER BY bm25(passages_fts,0,0.4,1.0,1.5),n.pinned DESC LIMIT ?",[.text(query),.integer(Int64(min(200,max(1,limit))))])
        }
        return try rows.map(evidence)
    }
    private func evidence(_ row: SQLiteRow) throws -> ResearchEvidence {
        let conv = row["conversation_id"]!.string, node = row["node_id"]!.string
        let branch = row["canonical_branch"]?.string.nilIfMemoryEmpty
        var context = [String]()
        if let branch, let position = try db().rows("SELECT position FROM branch_nodes WHERE conversation_id=? AND leaf_id=? AND node_id=?",[.text(conv),.text(branch),.text(node)]).first?["position"]?.int {
            let neighbors = try db().rows("""
            SELECT n.node_id,n.role,n.kind,n.created,n.thread_status,n.note,substr(n.text_exact,1,1201) AS text_exact FROM branch_nodes b JOIN nodes n ON n.conversation_id=b.conversation_id AND n.node_id=b.node_id
            WHERE b.conversation_id=? AND b.leaf_id=? AND b.position BETWEEN ? AND ? AND n.node_id!=?
            AND n.excluded=0 AND n.hidden=0 AND n.role IN('user','assistant') ORDER BY b.position
            """,[.text(conv),.text(branch),.integer(Int64(max(0,position-1))),.integer(Int64(position+1)),.text(node)])
            for neighbor in neighbors {
                context.append(Self.turn(neighbor,limit:650))
            }
        }
        let corrections = try db().rows("""
        SELECT DISTINCT source.node_id,source.role,source.kind,source.created,source.thread_status,source.note,substr(source.text_exact,1,1201) AS text_exact FROM relations r JOIN nodes source ON source.conversation_id=r.conversation_id AND source.node_id=r.source_node
        JOIN nodes target ON target.conversation_id=r.conversation_id AND target.node_id=r.target_node
        WHERE r.conversation_id=? AND r.target_node=? AND source.excluded=0 AND source.hidden=0
        AND ((source.active=1 AND target.active=1) OR source.canonical_branch=target.canonical_branch)
        ORDER BY source.ordinal LIMIT 3
        """,[.text(conv),.text(node)])
        for correction in corrections { context.insert("LINKED POSSIBLE CORRECTION (heuristic relationship; read the original):\n"+Self.turn(correction,limit:1100),at:0) }
        return .init(id:row["passage_id"]!.string,origin:"conversation",title:row["title"]!.string,
                     reference:"ChatGPT conversation \(row["original_id"]!.string), stored revision \(conv.prefix(12)), node \(node), branch \(branch ?? "unresolved") [\(row["active"]!.int == 1 ? "active at export" : "ALTERNATE / not active at export")]",
                     role:row["role"]!.string,classification:row["kind"]!.string,excerpt:row["passage_text"]!.string,
                     context:context.joined(separator:"\n\n"),conversationID:conv,nodeID:node,branchID:branch,created:row["created"]?.double,
                     annotation:row["note"]!.string,sourceURL:row["source_url"]!.string,threadStatus:row["thread_status"]!.string,
                     startOffset:row["start_offset"]!.int,endOffset:row["end_offset"]!.int)
    }
    private static func turn(_ row: SQLiteRow,limit: Int) -> String {
        let text = row["text_exact"]!.string
        let excerpt = String(text.prefix(limit)) + (text.count > limit ? "\n[rest of original turn omitted from this retrieval excerpt]" : "")
        return "[node \(row["node_id"]!.string); \(row["role"]!.string); \(row["kind"]!.string); original time \(row["created"]?.double.map(String.init(describing:)) ?? "unknown"); status \(row["thread_status"]!.string)]\n\(excerpt)\nSeparate journalist annotation: \(row["note"]!.string)"
    }
    /// Retrieve original listening notes/corrections independently, so repeated
    /// assistant restatements cannot crowd them out of the candidate cutoff.
    private func directNotes(_ input: String) throws -> [ResearchEvidence] {
        let query = Self.query(input); guard !query.isEmpty else { return [] }
        let rows = try db().rows(Self.selectEvidence+"""
         JOIN passages_fts ON passages_fts.passage_id=p.id
         WHERE passages_fts MATCH ? AND c.excluded=0 AND n.excluded=0 AND n.hidden=0
         AND n.role='user' AND n.kind IN(?,?,?) AND (n.active=1 OR c.alternatives=1 OR n.pinned=1)
         ORDER BY bm25(passages_fts,0,0.4,1.0,1.5) LIMIT 4
        """,[.text(query),.text(MemoryKind.observation.rawValue),.text(MemoryKind.correction.rawValue),.text(MemoryKind.verifiedSource.rawValue)])
        return try rows.map(evidence)
    }
    func retrieve(current: String,rolling: String = "",budget: Int = 12000) throws -> ConversationMemoryContext {
        let sql = try db()
        var hits = Self.query(current).isEmpty ? [] : try search(current,limit:12,includeAlternatives:false)
        if hits.count < 5, !Self.query(rolling).isEmpty { hits += try search(rolling,limit:8,includeAlternatives:false) }
        hits = try directNotes(current) + hits
        // Explicit pins are editorial priorities, not newly verified facts.
        let pinned = try sql.rows(Self.selectEvidence+" WHERE c.excluded=0 AND n.excluded=0 AND n.hidden=0 AND n.pinned=1 AND n.role IN('user','assistant') AND p.start_offset=0 ORDER BY n.ordinal LIMIT 2")
        hits = try pinned.map(evidence) + hits
        var expanded = [ResearchEvidence]()
        for hit in hits {
            if let conv = hit.conversationID, let node = hit.nodeID {
                let corrections = try sql.rows(Self.selectEvidence+"""
                 JOIN relations r ON r.conversation_id=n.conversation_id AND r.source_node=n.node_id
                 JOIN nodes target ON target.conversation_id=r.conversation_id AND target.node_id=r.target_node
                 WHERE r.conversation_id=? AND r.target_node=? AND c.excluded=0 AND n.excluded=0 AND n.hidden=0
                 AND ((n.active=1 AND target.active=1) OR n.canonical_branch=target.canonical_branch)
                 AND p.start_offset=0 ORDER BY n.ordinal LIMIT 2
                """,[.text(conv),.text(node)])
                expanded += try corrections.map(evidence)
            }
            expanded.append(hit)
        }
        var used = Set<String>(); var size = 0; var selected = [ResearchEvidence]()
        for hit in expanded {
            let key = (hit.conversationID ?? "")+"|"+(hit.nodeID ?? hit.id)
            guard !used.contains(key), selected.count < 6 else { continue }
            let cost = hit.prompt.count
            guard size+cost <= budget else { continue }
            selected.append(hit); used.insert(key); size += cost
        }
        let (text,version) = try dossier()
        let dossierEvidence = text.isEmpty ? nil : ResearchEvidence(id:"DOSSIER-\(version)",origin:"dossier",title:"Active research dossier",
            reference:"Local journalist-edited dossier version \(version); does not replace original conversations",role:"journalist",classification:"Curated priorities and user-attested notes; inspect cited sources",excerpt:text,context:"")
        return .init(passages:selected,dossier:dossierEvidence)
    }
}
