import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from interview_producer.core import Memory, Session, active_path, export_objects
from interview_producer.providers import Provider


def fixture():
    def node(parent,role,text):
        return {"parent":parent,"message":{"author":{"role":role},"content":{"content_type":"text","parts":[text]},"create_time":1700000000}}
    # Mapping insertion order intentionally differs from conversational order.
    return {"id":"synthetic-research","title":"Synthetic transport research","current_node":"correction","mapping":{
        "correction":node("assistant","user","Correction: the pilot began in 2018, not 2016. The longer wait was my observation, not a verified citywide result."),
        "original":node(None,"user","I observed a longer wait at Cedar Station during the morning pilot."),
        "assistant":node("original","assistant","The 2016 pilot definitely caused all citywide delays."),
        "alternate":node("original","assistant","ALTERNATIVE ONLY: the pilot never occurred.")}}


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.file = self.root/"conversations.json"
        # Noncanonical whitespace proves exact original-object preservation.
        self.raw = json.dumps(fixture(),ensure_ascii=False,indent=3).encode()
        self.file.write_bytes(b"[ \n"+self.raw+b"\n ]")
        self.memory = Memory(self.root/"memory.sqlite")

    def tearDown(self):
        self.memory.close(); self.temp.cleanup()

    def load(self):
        items = export_objects(self.file)
        self.memory.import_selected(items,{"synthetic-research"})
        return items

    def test_official_raw_bytes_and_order(self):
        items = self.load()
        self.assertEqual(items[0]["raw"],self.raw)
        stored = self.memory.db.execute("SELECT raw FROM conversations").fetchone()[0]
        self.assertEqual(stored,self.raw)
        self.assertEqual(active_path(fixture()),["original","assistant","correction"])
        self.assertEqual(self.memory.db.execute("SELECT COUNT(*) FROM nodes").fetchone()[0],4)

    def test_sharded_zip_selection(self):
        path = self.root/"export.zip"
        other = fixture();other["id"]="unselected"
        with zipfile.ZipFile(path,"w") as archive:
            archive.writestr("nested/conversations-000.json",self.file.read_bytes())
            archive.writestr("conversations-001.json",json.dumps([other]))
            archive.writestr("private-unrelated.txt","never extracted")
        items=export_objects(path)
        self.assertEqual(len(items),2)
        self.assertEqual(self.memory.import_selected(items,{"synthetic-research"}),1)
        self.assertEqual(self.memory.db.execute("SELECT COUNT(*) FROM conversations").fetchone()[0],1)
        self.assertFalse((self.root/"private-unrelated.txt").exists())

    def test_recall_correction_and_branch(self):
        self.load(); evidence=self.memory.retrieve("Cedar Station pilot")
        self.assertTrue(any("longer wait at Cedar Station" in p["text"] for p in evidence))
        self.assertTrue(any("2018, not 2016" in p["text"] for p in evidence))
        self.assertFalse(any("ALTERNATIVE ONLY" in p["text"] for p in evidence))
        self.assertTrue(all("message" in p["reference"] for p in evidence))

    def test_annotation_exclude_pin_delete(self):
        self.load(); row=self.memory.search("longer wait")[0]
        self.memory.annotate(row["conversation"],row["node"],note="Subjective firsthand account",kind="User observation",pinned=True)
        self.assertTrue(self.memory.retrieve("unrelated")[0]["pinned"])
        self.memory.annotate(row["conversation"],row["node"],excluded=True)
        self.assertFalse(any(p["node"]==row["node"] for p in self.memory.retrieve("Cedar Station")))
        self.assertTrue(any(p["node"]==row["node"] for p in self.memory.search("Cedar Station",include_excluded=True)))
        self.memory.delete(row["conversation"])
        self.assertEqual(self.memory.search("pilot",include_excluded=True),[])
        self.assertEqual(self.memory.db.execute("SELECT COUNT(*) FROM annotations").fetchone()[0],0)

    def test_assistant_cannot_be_verified(self):
        self.load();cid=self.memory.db.execute("SELECT id FROM conversations").fetchone()[0]
        with self.assertRaises(ValueError):self.memory.annotate(cid,"assistant",kind="Verified fact")

    def test_cyclic_active_path_is_not_retrieved(self):
        root=fixture();root["mapping"]["original"]["parent"]="correction"
        self.assertEqual(active_path(root),[])

    def test_dossier_versions_supplement_originals(self):
        self.load();self.memory.save_dossier("Current priority: compare primary records")
        self.assertEqual(self.memory.dossier(),"Current priority: compare primary records")
        self.assertEqual(self.memory.db.execute("SELECT COUNT(*) FROM dossier").fetchone()[0],2)
        self.assertEqual(self.memory.db.execute("SELECT raw FROM conversations").fetchone()[0],self.raw)
        with self.assertRaises(ValueError):self.memory.save_dossier("a"*6001)

    def test_no_selection_or_unknown_id(self):
        for ids in [set(),{"missing"}]:
            with self.assertRaises(ValueError):self.memory.import_selected(export_objects(self.file),ids)

    def test_incremental_session_autosave_and_exact_export(self):
        session=Session(self.root/"Interviews","Source Alder","Transport",{"purpose":"Research","stage":"Verification"})
        session.append("me",0,2,"When did the pilot begin?")
        session.append("them",3,8,"In 2018, not 2016.")
        saved=json.loads((session.root/(session.record["id"]+".json")).read_text())
        self.assertEqual(len(saved["lines"]),2)
        self.assertIn("[00:03] Interviewee: In 2018, not 2016.",(session.root/(session.record["id"]+".txt")).read_text())
        session.gap("them",8,10,"network unavailable"); session.stop()
        saved=json.loads((session.root/(session.record["id"]+".json")).read_text())
        self.assertEqual(saved["status"],"stopped");self.assertEqual(len(saved["gaps"]),1)
        self.assertIn("Verification",saved["setupContext"])

    def test_followup_receipts_and_repetition(self):
        self.load();history=self.memory.retrieve("pilot")
        session=Session(self.root/"Interviews","Source Alder","Transit",{})
        session.append("them",0,5,"We almost cancelled the pilot.")
        result={"question":"What nearly caused the pilot to be cancelled?","reason":"Unexplained turning point","citations":[{"ref":"INT-"+session.record["lines"][0]["id"],"quote":"almost cancelled the pilot"}]}
        self.assertTrue(session.add_suggestion(result,history))
        self.assertFalse(session.add_suggestion(result,history))
        result["question"]="Which records could independently corroborate the change?"
        result["citations"][0]["quote"]="invented quote"
        with self.assertRaises(ValueError):session.add_suggestion(result,history)

    def test_api_endpoint_and_credentials_scope(self):
        a=Provider("https://example.test/v1","chosen-model")
        self.assertEqual(a.endpoint("chat/completions"),"https://example.test/v1/chat/completions")
        self.assertNotEqual(a.account("text"),a.account("audio"))
        self.assertNotEqual(a.account("text"),Provider("https://other.test/v1","chosen-model").account("text"))
        for url in ["http://example.test/v1","https://u:p@example.test","https://example.test?token=secret","https://example.test#frag"]:
            with self.assertRaises(ValueError):Provider(url,"model").endpoint("chat/completions")

    def test_malformed_exports_are_rejected(self):
        for text in ['[{},]','[{}]garbage','{}','[{"id":"a","mapping":{}},]']:
            self.file.write_text(text)
            with self.assertRaises(ValueError):export_objects(self.file)


if __name__ == "__main__":unittest.main()
