# Interview Producer — Windows preview

Windows 10/11 x64, Python 3.12. This is a native desktop preview with local storage; it does not run a localhost website. See the repository's docs/PLATFORMS.md for feature differences and verification limits.

## Run from source

```powershell
py -3.12 -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m interview_producer
```

Set the interview topic/source, goals and stage. In Connection, save separate text/audio endpoint keys to Windows Credential Locker. Choose a model supported by that provider's compatible API. Audio transcription is enabled by default; editorial analysis requires explicit opt-in. Disable both for local recording without cloud processing. Obtain consent before Start.

Microphone-only mode records the default input and does not identify individual speakers. Microphone + system output records the entire default playback device, including other apps. Use headphones, close unrelated sound sources and verify the meters. Neither preview mode promises screen-share invisibility or mid-call device switching.

Memory accepts selected conversations from official JSON/ZIP exports. It preserves complete original JSON objects/branches and retrieves active-branch passages automatically when editorial analysis is enabled. Search inspects alternatives and excluded material explicitly. Separate annotations, pins, exclusions and dossier versions do not edit originals.

Questions are saved by source name using Save bank; Next Question advances the persisted position. There is no automatic lull trigger, answer detection or global shortcut in this preview. Session transcript JSON/TXT autosave after every successful received segment; WAV audio is under Audio. Archive can inspect and export saved files. Use Stop and let pending work finish before closing.

## Build a standalone folder

```powershell
python -m pip install -r requirements-build.txt
python -m unittest discover -s tests -v
python -m interview_producer --smoke-test
python -m PyInstaller --noconfirm --clean --windowed --name InterviewProducer --collect-all keyring --collect-all pyaudiowpatch launcher.py
```

Distribute the entire `dist\InterviewProducer` folder, along with LICENSE and these instructions. The executable is unsigned. The GitHub Windows workflow builds, tests, packages and uploads the preview ZIP; no real microphone or provider credentials are used by CI. A Windows hardware interview and live provider request remain separate checks.

Data: `%LOCALAPPDATA%\InterviewProducer`. Unreadable settings are not silently replaced. The Windows memory database is independent of an existing macOS database; no automatic migration or full feature parity is claimed.
