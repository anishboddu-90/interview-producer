"""Exercise capture orchestration with injected devices/providers, never a real microphone."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from interview_producer.capture import InterviewRunner, make_context
from interview_producer.core import Memory, Session
from test_core import fixture


class FakeRecorder:
    def __init__(self,folder,mode,on_chunk,on_error,on_level):
        self.paths={"me":str(folder/"me.wav"),"them":str(folder/"them.wav")}
        self.chunk,self.error,self.level=on_chunk,on_error,on_level
    def start(self):
        self.level("them",.5)
        self.chunk(("them",0,10,b"fictional-audio"))
    def stop(self):pass


class MockAudio:
    def transcribe(self,wav,language):return "The Cedar Station pilot nearly stopped because the route funding changed."


class MockText:
    def __init__(self):self.inputs=[]
    def text(self,rules,context):
        data=json.loads(context);self.inputs.append(data)
        line=data["transcript"][-1]
        return json.dumps({"question":"What changed in the route funding, and who can corroborate it?","reason":"Specific unexplained mechanism","citations":[{"ref":line["ref"],"quote":"the route funding changed"}]})


class RunnerTests(unittest.TestCase):
    def test_combined_audio_transcription_memory_suggestion_and_reload(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);memory=Memory(root/"Memory"/"conversations.sqlite")
            original=json.dumps(fixture()).encode()
            memory.import_selected([{"id":"synthetic-research","title":"Transport research","object":fixture(),"raw":original,"source":"fixture"}],{"synthetic-research"})
            memory.close()
            model=MockText();events=[];done=threading.Event();runner=None
            def notify(kind,value):
                events.append((kind,value))
                if kind=="suggestion":runner.stop()
                if kind=="finished":done.set()
            setup={"source":"Synthetic Source Alder","topic":"Transit","stage":"Verification","purpose":"Research interview","mode":"Microphone only","transcription":True,"analysis":True,"audio_provider":MockAudio(),"text_provider":model}
            runner=InterviewRunner(root,setup,notify,recorder_factory=FakeRecorder);runner.start()
            self.assertTrue(done.wait(5),"Combined mock interview failed to terminate")
            runner.thread.join(1)
            files=list((root/"Interviews").glob("*.json"));self.assertEqual(len(files),1)
            saved=json.loads(files[0].read_text())
            self.assertEqual(saved["status"],"stopped")
            self.assertIn("route funding changed",saved["lines"][0]["text"])
            self.assertEqual(len(saved["suggestions"]),1)
            self.assertTrue(model.inputs[0]["verbatim_history"])
            self.assertTrue(any("2018, not 2016" in e["text"] for e in model.inputs[0]["verbatim_history"]))
            self.assertEqual(model.inputs[0]["setup"]["stage"],"Verification")
            self.assertEqual(model.inputs[0]["transcript"][0]["speaker"],"them")
            self.assertTrue(saved["suggestions"][0]["evidence"][0]["reference"])
            self.assertFalse(any(k=="error" for k,v in events))
            self.assertTrue(files[0].with_suffix(".txt").exists())
            self.assertNotIn("_provider",saved["setupContext"])

    def test_transcription_failure_preserves_explicit_gap(self):
        class Outage:
            def transcribe(self,*args):raise ValueError("synthetic connection outage")
        with tempfile.TemporaryDirectory() as temp:
            done=threading.Event();runner=None
            def notify(kind,value):
                if kind=="status" and "gap" in str(value):runner.stop()
                if kind=="finished":done.set()
            runner=InterviewRunner(Path(temp),{"source":"Synthetic Source","mode":"Microphone only","transcription":True,"analysis":False,"audio_provider":Outage()},notify,recorder_factory=FakeRecorder)
            runner.start();self.assertTrue(done.wait(5));runner.thread.join(1)
            saved=json.loads(next((Path(temp)/"Interviews").glob("*.json")).read_text())
            self.assertEqual(saved["lines"],[]);self.assertEqual(len(saved["gaps"]),1)
            self.assertIn("outage",saved["gaps"][0]["reason"])

    def test_stop_signals_capture_before_blocked_transcription_completes(self):
        entered=threading.Event();release=threading.Event();done=threading.Event()
        class BlockingAudio:
            def transcribe(self,*args):entered.set();release.wait(3);return "Saved final answer."
        class SignalRecorder(FakeRecorder):
            def __init__(self,*args):super().__init__(*args);self.stop_event=threading.Event()
        with tempfile.TemporaryDirectory() as temp:
            runner=InterviewRunner(Path(temp),{"source":"Synthetic Source","mode":"Microphone only","transcription":True,"analysis":False,"audio_provider":BlockingAudio()},lambda k,v:done.set() if k=="finished" else None,recorder_factory=SignalRecorder)
            runner.start();self.assertTrue(entered.wait(2))
            runner.stop()
            self.assertTrue(runner.recorder.stop_event.is_set(),"Device reader must stop while HTTP is still blocked")
            self.assertFalse(done.is_set())
            release.set();self.assertTrue(done.wait(3));runner.thread.join(1)
            record=json.loads(next((Path(temp)/"Interviews").glob("*.json")).read_text())
            self.assertEqual(record["status"],"stopped");self.assertEqual(record["lines"][0]["text"],"Saved final answer.")

    def test_capture_failure_cleans_session(self):
        class BrokenRecorder(FakeRecorder):
            def start(self):raise ValueError("Synthetic unavailable device")
        with tempfile.TemporaryDirectory() as temp:
            events=[];done=threading.Event()
            def notify(k,v):
                events.append((k,v))
                if k=="finished":done.set()
            runner=InterviewRunner(Path(temp),{"source":"Synthetic Source","mode":"Microphone only"},notify,recorder_factory=BrokenRecorder)
            runner.start();self.assertTrue(done.wait(5));runner.thread.join(1)
            saved=json.loads(next((Path(temp)/"Interviews").glob("*.json")).read_text())
            self.assertEqual(saved["status"],"interrupted")
            self.assertTrue(any(k=="error" and "unavailable device" in v for k,v in events))

if __name__=="__main__":unittest.main()
