"""Native Tk desktop interface; no browser or localhost server is required."""
import json
import os
from pathlib import Path
import queue
import sys
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from .core import Memory, atomic_json, export_objects
from .providers import Provider
from .capture import InterviewRunner


class App:
    def __init__(self, window, root=None):
        self.window=window
        self.root=Path(root) if root else Path(os.environ.get("LOCALAPPDATA",Path.home()/".local"/"share"))/"InterviewProducer"
        self.root.mkdir(parents=True,exist_ok=True)
        self.settings_file=self.root/"settings.json"
        self.read_only=False
        try:self.settings=json.loads(self.settings_file.read_text(encoding="utf-8")) if self.settings_file.exists() else {}
        except (ValueError,OSError):
            self.settings={};self.read_only=True
            messagebox.showerror("Settings unavailable","Existing settings could not be read and will not be overwritten. Back up and repair settings.json before saving.")
        self.memory=Memory(self.root/"Memory"/"conversations.sqlite")
        self.runner=None;self.closing=False;self.events=queue.SimpleQueue();self.rows=[];self.archive_paths=[]
        window.title("Interview Producer · Windows preview");window.geometry("1050x800");window.minsize(850,650)
        self.status=tk.StringVar(value="Ready. Configure your interview and explicit providers before recording.")
        self.book=ttk.Notebook(window);self.book.pack(fill="both",expand=True,padx=12,pady=12)
        self.pages={}
        for title in ["Interview","Connection","Memory","Questions","Archive"]:
            page=ttk.Frame(self.book,padding=14);self.book.add(page,text=title);self.pages[title]=page
        self.fields={};self.connection_fields={}
        self.interview_page();self.connection_page();self.memory_page();self.questions_page();self.archive_page()
        ttk.Label(window,textvariable=self.status,wraplength=1000).pack(fill="x",padx=16,pady=(0,12))
        window.protocol("WM_DELETE_WINDOW",self.close);window.after(100,self.poll)

    def field(self,page,label,key,default="",choices=None,secret=False,store=None):
        ttk.Label(page,text=label).pack(anchor="w",pady=(6,1))
        value=tk.StringVar(value=self.settings.get(key,default))
        control=ttk.Combobox(page,textvariable=value,values=choices,state="readonly") if choices else ttk.Entry(page,textvariable=value,show="*" if secret else "")
        control.pack(fill="x")
        (self.fields if store is None else store)[key]=value
        return value

    def interview_page(self):
        page=self.pages["Interview"]
        self.field(page,"Topic / project","topic")
        self.field(page,"Interviewee / source name","source")
        row=ttk.Frame(page);row.pack(fill="x")
        for label,key,choices,default in [("Purpose","purpose",["Journalism","Research interview","Oral history","Meeting","Interview practice"],"Journalism"),("Stage","stage",["Discovery","Follow-up","Verification","Wrap-up"],"Discovery"),("Audio source","mode",["Microphone only","Microphone + system output"],"Microphone only")]:
            group=ttk.Frame(row);group.pack(side="left",fill="x",expand=True,padx=(0,8));self.field(group,label,key,default,choices)
        self.field(page,"Goals and priorities (up to 4,000 characters)","goals")
        self.field(page,"Transcription language: auto or ISO code (en, es, fr…)","language","auto")
        self.transcription=tk.BooleanVar(value=self.settings.get("transcription",True))
        self.analysis=tk.BooleanVar(value=self.settings.get("analysis",False))
        ttk.Checkbutton(page,text="Transcribe using configured audio API",variable=self.transcription).pack(anchor="w",pady=(8,0))
        ttk.Checkbutton(page,text="Automatically retrieve memory and suggest evidence-linked follow-ups",variable=self.analysis).pack(anchor="w")
        ttk.Label(page,text="System-output mode records ALL sound on the default playback device, including other apps. Use headphones. Microphone-only mode does not separate individual speakers. Global shortcuts and share-hidden overlays are not included in this preview.",wraplength=980).pack(anchor="w",pady=8)
        self.consent=tk.BooleanVar(value=False)
        ttk.Checkbutton(page,text="I obtained consent to recording and the selected cloud processing.",variable=self.consent).pack(anchor="w")
        controls=ttk.Frame(page);controls.pack(fill="x",pady=8)
        self.start_button=ttk.Button(controls,text="Start interview",command=self.start);self.start_button.pack(side="left")
        self.stop_button=ttk.Button(controls,text="Stop and save",command=self.stop,state="disabled");self.stop_button.pack(side="left",padx=8)
        self.save_button=ttk.Button(controls,text="Save setup",command=self.save_settings);self.save_button.pack(side="left")
        self.levels=tk.StringVar(value="Microphone: 0% · System: 0%")
        ttk.Label(controls,textvariable=self.levels).pack(side="right");self.level_values={"me":0,"them":0}
        self.transcript=tk.Text(page,height=10,wrap="word",state="disabled");self.transcript.pack(fill="both",expand=True)
        self.suggestion=tk.StringVar(value="Quiet by default. Follow-ups appear when a consequential question remains open.")
        ttk.Label(page,textvariable=self.suggestion,wraplength=980).pack(fill="x",pady=8)
        self.evidence=tk.Text(page,height=4,wrap="word",state="disabled");self.evidence.pack(fill="x")

    def connection_page(self):
        page=self.pages["Connection"]
        ttk.Label(page,text="Explicit API connections",font=("Segoe UI",14,"bold")).pack(anchor="w")
        ttk.Label(page,text="Separate text and audio providers; keys stay in Windows Credential Locker. Supports HTTPS chat/completions and audio/transcriptions APIs. Provider usage may cost money and is separate from a ChatGPT subscription. There is no automatic fallback. Windows preview does not include ChatGPT-plan sign-in.",wraplength=980).pack(anchor="w",pady=8)
        self.key_fields={}
        for kind,label,base,model in [("text","Editorial analysis","https://api.openai.com/v1",""),("audio","Transcription","https://api.groq.com/openai/v1","whisper-large-v3-turbo")]:
            group=ttk.LabelFrame(page,text=label,padding=10);group.pack(fill="x",pady=6)
            self.field(group,"API base URL",kind+"_base",base,store=self.connection_fields)
            self.field(group,"Model ID",kind+"_model",model,store=self.connection_fields)
            value=tk.StringVar();self.key_fields[kind]=value
            ttk.Label(group,text="API key for this endpoint").pack(anchor="w")
            ttk.Entry(group,textvariable=value,show="*").pack(fill="x")
            ttk.Button(group,text="Save key to Credential Locker",command=lambda k=kind:self.save_key(k)).pack(anchor="w",pady=4)
            ttk.Button(group,text="Remove endpoint key",command=lambda k=kind:self.save_key(k,remove=True)).pack(anchor="w")
        self.field(page,"Output token field","token_parameter","max_completion_tokens",["max_completion_tokens","max_tokens"],store=self.connection_fields)
        ttk.Button(page,text="Save provider settings",command=self.save_settings).pack(anchor="w",pady=8)

    def provider(self,kind):
        return Provider(self.connection_fields[kind+"_base"].get().strip(),self.connection_fields[kind+"_model"].get().strip(),self.connection_fields["token_parameter"].get())

    def save_key(self,kind,remove=False):
        if self.runner:return
        try:
            self.provider(kind).save_key(kind,"" if remove else self.key_fields[kind].get())
            self.key_fields[kind].set("");self.status.set("Endpoint key removed." if remove else "Key saved for this exact endpoint.")
            self.save_settings()
        except Exception as error:messagebox.showerror("Connection",str(error))

    def save_settings(self):
        if self.runner:return
        if self.read_only:
            messagebox.showerror("Settings","Existing settings are unreadable and have not been overwritten.");return
        self.settings.update({k:v.get() for k,v in {**self.fields,**self.connection_fields}.items()})
        self.settings.update(transcription=self.transcription.get(),analysis=self.analysis.get())
        try:atomic_json(self.settings_file,self.settings);self.status.set("Setup and question banks saved locally.")
        except Exception as error:messagebox.showerror("Save",str(error))

    def start(self):
        if self.runner:return
        if self.read_only:messagebox.showerror("Settings","Repair unreadable settings before starting.");return
        if not self.consent.get():messagebox.showinfo("Consent","Confirm recording and selected cloud-processing consent first.");return
        try:
            self.save_settings()
            setup=dict(self.settings)
            if not setup.get("source","").strip():raise ValueError("Enter a source name.")
            if len(setup.get("goals",""))>4000 or len(setup.get("topic",""))>200:raise ValueError("Topic limit: 200 characters; goals: 4,000.")
            if setup["analysis"] and not setup["transcription"]:raise ValueError("Enable transcription to use automatic editorial analysis.")
            setup["audio_provider"]=self.provider("audio");setup["text_provider"]=self.provider("text")
            if setup["transcription"]:setup["audio_provider"].key("audio")
            if setup["analysis"]:setup["text_provider"].key("text")
            self.runner=InterviewRunner(self.root,setup,lambda kind,value:self.events.put((kind,value)))
            self.start_button.configure(state="disabled");self.stop_button.configure(state="normal")
            self.suggestion.set("Quiet by default.");self.set_text(self.transcript,"");self.set_text(self.evidence,"")
            self.runner.start();self.consent.set(False)
        except Exception as error:messagebox.showerror("Could not start",str(error))

    def stop(self):
        if self.runner:self.runner.stop();self.stop_button.configure(state="disabled")

    def memory_page(self):
        page=self.pages["Memory"]
        row=ttk.Frame(page);row.pack(fill="x")
        self.query=tk.StringVar();ttk.Entry(row,textvariable=self.query).pack(side="left",fill="x",expand=True)
        ttk.Button(row,text="Search",command=self.search).pack(side="left",padx=6)
        ttk.Button(row,text="Import official ZIP / JSON…",command=self.import_memory).pack(side="left")
        self.inspect_excluded=tk.BooleanVar();ttk.Checkbutton(page,text="Include excluded material for inspection",variable=self.inspect_excluded).pack(anchor="w")
        self.results=tk.Listbox(page,height=7,exportselection=False);self.results.pack(fill="x",pady=6);self.results.bind("<<ListboxSelect>>",self.inspect)
        self.original=tk.Text(page,height=8,wrap="word",state="disabled");self.original.pack(fill="both",expand=True)
        ttk.Label(page,text="Separate annotation / correction; originals remain unchanged").pack(anchor="w",pady=(6,0))
        self.note=tk.StringVar();ttk.Entry(page,textvariable=self.note).pack(fill="x")
        row=ttk.Frame(page);row.pack(fill="x",pady=6)
        self.pinned=tk.BooleanVar();self.excluded=tk.BooleanVar()
        ttk.Checkbutton(row,text="Pin",variable=self.pinned).pack(side="left")
        ttk.Checkbutton(row,text="Exclude",variable=self.excluded).pack(side="left")
        ttk.Button(row,text="Save annotation",command=self.annotate).pack(side="left",padx=8)
        ttk.Button(row,text="Delete this conversation…",command=self.delete_memory).pack(side="left")
        ttk.Label(page,text="Active dossier · supplements the original conversations (6,000-character limit)").pack(anchor="w")
        self.dossier=tk.Text(page,height=7,wrap="word");self.dossier.insert("1.0",self.memory.dossier());self.dossier.pack(fill="x")
        ttk.Button(page,text="Save dossier version",command=self.save_dossier).pack(anchor="w",pady=5)

    def import_memory(self):
        if self.runner:messagebox.showinfo("Memory","Stop recording before importing.");return
        name=filedialog.askopenfilename(filetypes=[("ChatGPT export","*.zip *.json")])
        if not name:return
        try:
            items=export_objects(Path(name));ids=[i["id"] for i in items]
            if len(ids)!=len(set(ids)):raise ValueError("Duplicate original conversation IDs require review before selection.")
        except Exception as error:messagebox.showerror("Import",str(error));return
        dialog=tk.Toplevel(self.window);dialog.title("Select conversations to import");dialog.geometry("700x500")
        ttk.Label(dialog,text="Select relevant conversations. Originals and all branches stay local.").pack(padx=12,pady=10)
        listing=tk.Listbox(dialog,selectmode="extended");listing.pack(fill="both",expand=True,padx=12)
        for item in items:listing.insert("end",item["title"]+" · "+str(len(item["object"]["mapping"]))+" nodes")
        def perform():
            try:
                count=self.memory.import_selected(items,{items[i]["id"] for i in listing.curselection()})
                self.status.set(f"Imported {count} complete conversations locally.");dialog.destroy()
            except Exception as error:messagebox.showerror("Import",str(error),parent=dialog)
        ttk.Button(dialog,text="Import selected",command=perform).pack(pady=10)

    def search(self):
        try:
            self.rows=self.memory.search(self.query.get(),include_excluded=self.inspect_excluded.get())
            self.results.delete(0,"end")
            for row in self.rows:self.results.insert("end",f"{row['role']} · {'active' if row['active'] else 'alternative branch'} · {row['title']} · {row['text'][:80]}")
        except Exception as error:messagebox.showerror("Search",str(error))

    def selected(self):
        selection=self.results.curselection()
        return self.rows[selection[0]] if selection else None

    def inspect(self,event=None):
        row=self.selected()
        if not row:return
        original=self.memory.db.execute("SELECT text FROM nodes WHERE conversation=? AND node=?",(row["conversation"],row["node"])).fetchone()[0]
        self.set_text(self.original,row["reference"]+"\nRole: "+row["role"]+"\n\n"+original)
        self.note.set(row["annotation"]);self.pinned.set(bool(row["pinned"]));self.excluded.set(bool(row["excluded"]))

    def annotate(self):
        row=self.selected()
        if not row:return
        try:
            self.memory.annotate(row["conversation"],row["node"],note=self.note.get(),kind="Assistant interpretation" if row["role"]=="assistant" else "User annotation / correction",pinned=self.pinned.get(),excluded=self.excluded.get())
            self.status.set("Annotation saved separately. Original text is unchanged.");self.search()
        except Exception as error:messagebox.showerror("Annotation",str(error))

    def delete_memory(self):
        row=self.selected()
        if row and messagebox.askyesno("Delete conversation","Delete this entire imported conversation and its local index? The original export file remains unchanged."):
            try:self.memory.delete(row["conversation"]);self.search();self.set_text(self.original,"")
            except Exception as error:messagebox.showerror("Delete",str(error))

    def save_dossier(self):
        try:self.memory.save_dossier(self.dossier.get("1.0","end-1c"));self.status.set("Dossier version saved locally.")
        except Exception as error:messagebox.showerror("Dossier",str(error))

    def questions_page(self):
        page=self.pages["Questions"]
        ttk.Label(page,text="Prepared questions",font=("Segoe UI",14,"bold")).pack(anchor="w")
        ttk.Label(page,text="Questions are saved by source name. One question per line. Automatic lull detection is off. Next Question advances only when you ask for it.",wraplength=980).pack(anchor="w",pady=8)
        self.question_text=tk.Text(page,height=14,wrap="word");self.question_text.pack(fill="both",expand=True)
        ttk.Button(page,text="Load bank for current source",command=self.load_questions).pack(anchor="w",pady=5)
        ttk.Button(page,text="Save bank for current source",command=self.save_questions).pack(anchor="w",pady=5)
        ttk.Button(page,text="Next Question",command=self.next_question).pack(anchor="w",pady=5)
        self.question_card=tk.StringVar(value="No prepared question selected.")
        ttk.Label(page,textvariable=self.question_card,wraplength=980,font=("Segoe UI",13)).pack(fill="x",pady=12)
        self.load_questions()

    def source_key(self):return self.fields["source"].get().strip().casefold()
    def load_questions(self):
        bank=self.settings.get("question_banks",{}).get(self.source_key(),{"questions":[],"next":0})
        self.question_text.delete("1.0","end");self.question_text.insert("1.0","\n".join(bank["questions"]))
    def save_questions(self):
        source=self.source_key()
        if not source:messagebox.showinfo("Questions","Enter a source name in Interview first.");return
        if self.runner:messagebox.showinfo("Questions","Stop recording before editing a bank.");return
        questions=[line.strip() for line in self.question_text.get("1.0","end").splitlines() if line.strip()]
        if len(questions)>200 or any(len(q)>1000 for q in questions):messagebox.showerror("Questions","Limit: 200 questions, 1,000 characters each.");return
        old=self.settings.get("question_banks",{}).get(source,{})
        self.settings.setdefault("question_banks",{})[source]={"questions":questions,"next":min(old.get("next",0),len(questions)) if questions==old.get("questions") else 0}
        self.save_settings()
    def next_question(self):
        source=self.runner.setup["source"].strip().casefold() if self.runner else self.source_key()
        bank=self.settings.get("question_banks",{}).get(source,{"questions":[],"next":0})
        index=bank.get("next",0)
        if index>=len(bank["questions"]):self.question_card.set("No remaining prepared questions.");return
        self.question_card.set(bank["questions"][index]);bank["next"]=index+1
        try:atomic_json(self.settings_file,self.settings)
        except Exception as error:messagebox.showerror("Questions",str(error))

    def archive_page(self):
        page=self.pages["Archive"]
        ttk.Button(page,text="Refresh saved interviews",command=self.refresh_archive).pack(anchor="w")
        self.archive_list=tk.Listbox(page,height=8);self.archive_list.pack(fill="x",pady=8);self.archive_list.bind("<<ListboxSelect>>",self.show_archive)
        self.archive_text=tk.Text(page,wrap="word",state="disabled");self.archive_text.pack(fill="both",expand=True)
        ttk.Label(page,text="Each interview has automatic .json and .txt files in local storage. WAV recordings are in Audio. Copy files using Export; copying does not change originals.",wraplength=980).pack(anchor="w",pady=8)
        ttk.Button(page,text="Export selected JSON / transcript…",command=self.export_archive).pack(anchor="w")
        self.refresh_archive()
    def refresh_archive(self):
        self.archive_paths=sorted((self.root/"Interviews").glob("*.json"),key=lambda p:p.stat().st_mtime,reverse=True)
        self.archive_list.delete(0,"end")
        for path in self.archive_paths:
            try:r=json.loads(path.read_text(encoding="utf-8"));self.archive_list.insert("end",r["title"]+" · "+r["status"])
            except (OSError,ValueError,KeyError):self.archive_list.insert("end",path.name+" · unreadable; original preserved")
    def show_archive(self,event=None):
        selection=self.archive_list.curselection()
        if selection:
            path=self.archive_paths[selection[0]].with_suffix(".txt")
            try:self.set_text(self.archive_text,path.read_text(encoding="utf-8"))
            except OSError as error:self.status.set(str(error))
    def export_archive(self):
        selection=self.archive_list.curselection()
        if not selection:return
        target=filedialog.asksaveasfilename(defaultextension=".json",filetypes=[("Full interview JSON","*.json"),("Transcript text","*.txt")])
        if target:
            try:
                source=self.archive_paths[selection[0]].with_suffix(".txt" if Path(target).suffix.lower()==".txt" else ".json")
                if source.resolve()==Path(target).resolve():raise ValueError("Choose a separate export destination.")
                Path(target).write_bytes(source.read_bytes());self.status.set("Export copied successfully.")
            except Exception as error:messagebox.showerror("Export",str(error))

    @staticmethod
    def set_text(widget,text):widget.configure(state="normal");widget.delete("1.0","end");widget.insert("1.0",text);widget.configure(state="disabled")
    def poll(self):
        while not self.events.empty():
            kind,value=self.events.get()
            if kind in {"status","error"}:self.status.set(value)
            elif kind=="transcript":self.set_text(self.transcript,value)
            elif kind=="suggestion":
                self.suggestion.set(value["decision"]["suggested_question"]+"\n"+value["decision"]["reason"])
                self.set_text(self.evidence,"\n\n".join(p["reference"]+"\n"+p["excerpt"] for p in value["evidence"]))
            elif kind=="level":
                role,level=value;self.level_values[role]=level
                self.levels.set(f"Microphone: {self.level_values['me']:.0%} · System: {self.level_values['them']:.0%}")
            elif kind=="finished":
                self.runner=None;self.start_button.configure(state="normal");self.stop_button.configure(state="disabled");self.refresh_archive()
                if self.closing:self.memory.close();self.window.destroy();return
        self.window.after(100,self.poll)
    def close(self):
        if self.runner:
            self.closing=True;self.stop();self.status.set("Finishing saved audio and pending transcription before closing…")
        else:self.save_settings();self.memory.close();self.window.destroy()


def main():
    if sys.platform!="win32":
        print("Windows desktop preview requires Windows 10/11. Core tests run on any platform.");return 1
    if "--smoke-test" in sys.argv:
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            window=tk.Tk();window.withdraw();app=App(window,root=temp)
            window.update_idletasks();window.update()
            app.fields["source"].set("Synthetic bootstrap source")
            app.fields["topic"].set("Synthetic bootstrap topic")
            app.question_text.insert("1.0","What changed, and what records show it?")
            app.save_questions();app.next_question()
            assert app.settings["question_banks"]["synthetic bootstrap source"]["next"] == 1
            app.close()
            assert (Path(temp)/"settings.json").exists()
        return 0
    window=tk.Tk();App(window);window.mainloop();return 0
