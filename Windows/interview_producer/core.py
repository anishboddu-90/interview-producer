"""Portable storage/retrieval core. No GUI, microphone or network side effects on import."""
from __future__ import annotations
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import time
import uuid
import zipfile


def atomic_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as file:
        json.dump(value, file, ensure_ascii=False, allow_nan=False, indent=2)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def export_objects(path: Path):
    """Return exact UTF-8 object slices; never extract unrelated ZIP entries."""
    sources = []
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            infos = [i for i in archive.infolist() if re.fullmatch(r"conversations(?:-\d+)?\.json", Path(i.filename).name)]
            if not infos or sum(i.file_size for i in infos) > 512_000_000:
                raise ValueError("Export has no conversation JSON or exceeds the 512 MB preview limit.")
            sources = [(i.filename, archive.read(i)) for i in infos]
    else:
        if path.stat().st_size > 512_000_000:
            raise ValueError("Conversation JSON exceeds 512 MB.")
        sources = [(path.name, path.read_bytes())]
    result = []
    decoder = json.JSONDecoder()
    for name, raw in sources:
        text = raw.decode("utf-8-sig")
        index = len(text) - len(text.lstrip())
        if not text[index:].startswith("["):
            raise ValueError("Expected the official conversation array.")
        index += 1
        while True:
            while index < len(text) and text[index].isspace():
                index += 1
            if index < len(text) and text[index] == "]":
                index += 1
                break
            start = index
            item, index = decoder.raw_decode(text, index)
            if not isinstance(item, dict) or not isinstance(item.get("mapping"), dict):
                raise ValueError("Conversation has no official mapping graph.")
            result.append({"id": str(item.get("id") or item.get("conversation_id") or hashlib.sha256(text[start:index].encode()).hexdigest()),
                           "title": item.get("title") or "Untitled conversation", "object": item,
                           "raw": text[start:index].encode("utf-8"), "source": name})
            while index < len(text) and text[index].isspace():
                index += 1
            if index < len(text) and text[index] == ",":
                index += 1
                if text[index:].lstrip().startswith("]"):
                    raise ValueError("Trailing comma in conversation array.")
                continue
            if index < len(text) and text[index] == "]":
                index += 1
                break
            raise ValueError("Malformed conversation array.")
        if text[index:].strip():
            raise ValueError("Unexpected data after conversation array.")
    return result


def active_path(conversation):
    mapping = conversation["mapping"]
    current = conversation.get("current_node")
    if not current:
        parents = {n.get("parent") for n in mapping.values()}
        leaves = [key for key in mapping if key not in parents]
        current = leaves[0] if len(leaves) == 1 else None
    path, seen = [], set()
    while current:
        if current in seen or current not in mapping:
            return []  # Preserve invalid graph, but never silently use an uncertain branch.
        seen.add(current)
        path.append(current)
        current = mapping[current].get("parent")
    return list(reversed(path))


def message_text(message):
    parts = message.get("content", {}).get("parts", [])
    # Non-text/multimodal data remains in raw originals; no invented transcription.
    return "\n".join(part for part in parts if isinstance(part, str))


class Memory:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
        PRAGMA foreign_keys=ON;
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, original_id TEXT, title TEXT, raw BLOB, source TEXT, excluded INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS nodes(conversation TEXT REFERENCES conversations(id) ON DELETE CASCADE, node TEXT, role TEXT, text TEXT, active INTEGER, position INTEGER, PRIMARY KEY(conversation,node));
        CREATE TABLE IF NOT EXISTS passages(id TEXT PRIMARY KEY, conversation TEXT REFERENCES conversations(id) ON DELETE CASCADE, node TEXT, role TEXT, text TEXT, context TEXT, reference TEXT, active INTEGER);
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED,text);
        CREATE TABLE IF NOT EXISTS annotations(conversation TEXT,node TEXT,note TEXT DEFAULT '',kind TEXT DEFAULT '',pinned INTEGER DEFAULT 0,excluded INTEGER DEFAULT 0,PRIMARY KEY(conversation,node),FOREIGN KEY(conversation,node) REFERENCES nodes(conversation,node) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS dossier(id INTEGER PRIMARY KEY,created REAL,text TEXT);
        """)
        if not self.db.execute("SELECT 1 FROM dossier LIMIT 1").fetchone():
            self.save_dossier("# Active research dossier\n\nGoals and priorities:\n\nFacts with checked source references:\n\nObservations and interpretations:\n\nCorrections and open questions:\n")

    def close(self):
        self.db.close()

    def import_selected(self, items, selected):
        if not selected:
            raise ValueError("Select at least one conversation.")
        available = {i["id"] for i in items}
        if not set(selected) <= available:
            raise ValueError("Selection refers to a missing conversation.")
        imported = 0
        with self.db:
            for item in items:
                if item["id"] not in selected:
                    continue
                raw = item["raw"]
                cid = hashlib.sha256(raw).hexdigest()
                if self.db.execute("SELECT 1 FROM conversations WHERE id=?", (cid,)).fetchone():
                    continue
                root = item["object"]
                path = active_path(root)
                positions = {node:i for i,node in enumerate(path)}
                self.db.execute("INSERT INTO conversations(id,original_id,title,raw,source) VALUES(?,?,?,?,?)", (cid,item["id"],item["title"],raw,item["source"]))
                for nid, node in root["mapping"].items():
                    message = node.get("message") or {}
                    role = message.get("author", {}).get("role", "unknown")
                    text = message_text(message)
                    is_active = nid in positions
                    self.db.execute("INSERT INTO nodes VALUES(?,?,?,?,?,?)", (cid,nid,role,text,is_active,positions.get(nid,-1)))
                    # Parent-only exports and non-chronological object order are supported.
                    neighbors = []
                    if is_active:
                        position = positions[nid]
                        for other in path[max(0,position-2):position+2]:
                            msg = root["mapping"][other].get("message") or {}
                            neighbors.append(msg.get("author",{}).get("role","unknown")+": "+message_text(msg))
                    for offset in range(0,len(text),1400):
                        excerpt = text[offset:offset+1600]
                        pid = hashlib.sha256(f"{cid}|{nid}|{offset}".encode()).hexdigest()
                        reference = f"{item['title']} · conversation {item['id']} · message {nid} · chars {offset}:{offset+len(excerpt)} · {message.get('create_time','date unavailable')}"
                        self.db.execute("INSERT INTO passages VALUES(?,?,?,?,?,?,?,?)", (pid,cid,nid,role,excerpt,"\n".join(neighbors),reference,is_active))
                        self.db.execute("INSERT INTO search VALUES(?,?)", (pid,excerpt))
                imported += 1
        return imported

    def search(self, query, include_excluded=False, limit=30):
        stop = {"the","and","that","this","what","when","where","which","with","from","have","there","they","were","was","for","you","your","our","not","but","because"}
        words = [word for word in dict.fromkeys(re.findall(r"[^\W_]{2,}",query.lower(),re.UNICODE)) if word not in stop][:16]
        if not words:
            return []
        match = " OR ".join('"'+word+'"' for word in words)
        conditions = "" if include_excluded else " AND c.excluded=0 AND COALESCE(a.excluded,0)=0"
        rows = self.db.execute("""SELECT p.*,c.title,c.original_id,COALESCE(a.note,'') annotation,COALESCE(a.kind,'') kind,COALESCE(a.pinned,0) pinned,COALESCE(a.excluded,0) excluded,c.excluded conversation_excluded,bm25(search) rank
        FROM search JOIN passages p ON p.id=search.id JOIN conversations c ON c.id=p.conversation
        LEFT JOIN annotations a ON a.conversation=p.conversation AND a.node=p.node
        WHERE search MATCH ?""" + conditions + " ORDER BY pinned DESC, CASE WHEN p.role='user' THEN 0 ELSE 1 END,rank LIMIT ?",(match,limit)).fetchall()
        return [dict(row) for row in rows]

    def retrieve(self, query):
        # Original user/correction lane before assistant repetition. Distinct messages only.
        rows = self.search(query,limit=80)
        pinned = self.db.execute("""SELECT p.*,c.title,COALESCE(a.note,'') annotation,COALESCE(a.kind,'') kind,1 pinned FROM passages p JOIN conversations c ON c.id=p.conversation JOIN annotations a ON a.conversation=p.conversation AND a.node=p.node WHERE a.pinned=1 AND a.excluded=0 AND c.excluded=0 AND p.active=1 LIMIT 6""").fetchall()
        output, seen, used = [], set(), 0
        for row in [dict(p) for p in pinned]+rows:
            key = (row["conversation"],row["node"])
            if not row["active"] or key in seen or used+len(row["text"])+len(row["context"]) > 16000:
                continue
            output.append(row); seen.add(key); used += len(row["text"])+len(row["context"])
            if len(output) == 6:
                break
        return output

    def annotate(self, cid, node, *, note="", kind="", pinned=False, excluded=False):
        row = self.db.execute("SELECT role FROM nodes WHERE conversation=? AND node=?",(cid,node)).fetchone()
        if not row or len(note) > 4000:
            raise ValueError("Missing message or annotation exceeds 4,000 characters.")
        if row[0] == "assistant" and kind != "Assistant interpretation":
            raise ValueError("Assistant text must remain an unverified interpretation.")
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO annotations VALUES(?,?,?,?,?,?)",(cid,node,note,kind,pinned,excluded))

    def delete(self, cid):
        with self.db:
            self.db.execute("DELETE FROM search WHERE id IN (SELECT id FROM passages WHERE conversation=?)",(cid,))
            self.db.execute("DELETE FROM conversations WHERE id=?",(cid,))

    def save_dossier(self, text):
        if len(text) > 6000:
            raise ValueError("Dossier is limited to 6,000 characters; preserve full originals in memory.")
        with self.db:
            self.db.execute("INSERT INTO dossier(created,text) VALUES(?,?)",(time.time(),text))

    def dossier(self):
        return self.db.execute("SELECT text FROM dossier ORDER BY id DESC LIMIT 1").fetchone()[0]


class Session:
    def __init__(self, root: Path, source: str, topic: str, setup: dict):
        if not source.strip() or len(source) > 200:
            raise ValueError("Enter a source name (up to 200 characters).")
        self.root = root
        self.record = {"id":str(uuid.uuid4()).upper(),"date":time.time()-978307200,"title":(topic.strip() or "Interview")+" — "+source,
                       "sourceName":source,"sourceBackground":"","consent":"User confirmed recording and selected cloud processing",
                       "simulation":False,"status":"recording","lines":[],"suggestions":[],"threads":[],"notes":"","research":"",
                       "setupContext":json.dumps(setup,ensure_ascii=False),"includeInStory":True,"gaps":[]}
        self.save()

    def save(self):
        atomic_json(self.root/(self.record["id"]+".json"),self.record)
        text = self.transcript()
        path = self.root/(self.record["id"]+".txt")
        temp = path.with_suffix(".txt.tmp")
        with temp.open("w",encoding="utf-8") as file:
            file.write(text); file.flush(); os.fsync(file.fileno())
        os.replace(temp,path)

    def transcript(self):
        return "\n".join(f"[{int(line['start'])//60:02}:{int(line['start'])%60:02}] {'Interviewer' if line['speaker']=='me' else 'Interviewee'}: {line['text']}" for line in sorted(self.record["lines"],key=lambda l:l["start"]))

    def append(self, speaker, start, end, text):
        if speaker not in {"me","them"} or not (math.isfinite(start) and math.isfinite(end) and 0 <= start <= end):
            raise ValueError("Invalid channel or timestamps.")
        self.record["lines"].append({"id":str(uuid.uuid4()).upper(),"speaker":speaker,"start":start,"end":end,"text":text})
        self.record["lines"].sort(key=lambda line:line["start"])
        self.save()

    def gap(self, speaker, start, end, reason):
        self.record["gaps"].append({"speaker":speaker,"start":start,"end":end,"reason":reason})
        self.save()

    def stop(self):
        self.record["status"] = "stopped"
        self.save()

    def add_suggestion(self, result, historical):
        question = str(result.get("question", "")).strip()
        if not question:
            return False
        if len(question) > 500:
            raise ValueError("Oversized follow-up.")
        words = set(re.findall(r"\w+",question.lower()))
        for saved in self.record["suggestions"]:
            old = set(re.findall(r"\w+",saved["decision"]["suggested_question"].lower()))
            if words and len(words & old)/len(words | old) > .65:
                return False
        refs = {"INT-"+line["id"]:{"id":"INT-"+line["id"],"excerpt":line["text"],"reference":f"Current transcript {line['start']}s", "role":line["speaker"],"origin":"interview","title":self.record["title"],"classification":"Attributed testimony, not independent verification","context":"","conversationID":self.record["id"],"nodeID":line["id"]} for line in self.record["lines"][-80:]}
        refs.update({p["id"]:{"id":p["id"],"excerpt":p["text"],"reference":p["reference"],"role":p["role"],"origin":"conversation","title":p["title"],"classification":"Assistant interpretation" if p["role"]=="assistant" else "User observation or claim — unverified","context":p["context"],"conversationID":p["conversation"],"nodeID":p["node"]} for p in historical})
        citations = result.get("citations",[])
        if not citations or not any(c.get("ref","").startswith("INT-") for c in citations):
            raise ValueError("Follow-up requires an exact current-transcript citation.")
        for citation in citations:
            quote = citation.get("quote")
            if citation.get("ref") not in refs or not quote or quote not in refs[citation["ref"]]["excerpt"]:
                raise ValueError("Follow-up has an invented reference or altered quote.")
        current = next(c for c in citations if c["ref"].startswith("INT-"))
        line = next(l for l in self.record["lines"] if "INT-"+l["id"] == current["ref"])
        receipt = {"id":str(uuid.uuid4()).upper(),"status":"new","decision":{"should_suggest":True,"confidence":.9,"priority":"medium","suggested_question":question,"reason":str(result.get("reason","")),"evidence_excerpt":current["quote"],"related_topic":question,"timestamp":line["start"]},"evidence":[refs[c["ref"]] for c in citations]}
        self.record["suggestions"].append(receipt); self.save()
        return True
