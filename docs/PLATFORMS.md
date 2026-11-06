# Platform support

| Capability | macOS 15+ | Windows 10/11 x64 preview |
| --- | --- | --- |
| Native desktop UI, no localhost server | SwiftUI | Tk/ttk |
| Call audio | Selected app process tap / ScreenCaptureKit fallback | Entire default playback device via WASAPI loopback |
| Microphone-only conversation | Yes; selectable input | Yes; system default input |
| Verbatim official export / branches / local FTS5 | Yes | Yes; active-branch automatic retrieval, alternative branches inspectable |
| Memory annotation, pins, exclusion, deletion, dossier | Yes | Yes; per-message controls and whole-conversation deletion |
| Automatic memory in follow-up context | Yes | Yes |
| Provider choices | Granted ChatGPT, Groq, compatible APIs | Compatible APIs |
| Transcript autosave | JSON; export TXT/MD/JSON | JSON and TXT after each received segment |
| Audio recordings | Separate CAF source channels | Separate WAV source channels |
| Prepared source-specific questions | Full Lifeline, answer receipts, editable statuses | Manual sequential bank and persisted position |
| Global shortcut / protected floating panel | Yes, with environment-specific limits | Not implemented |
| Source-specific briefs / seven-part reports / investigation ledger | Yes | Not implemented |
| Portable test coverage | Native deterministic suite | Portable unit/controller tests and Windows package smoke test |
| Physical call/device testing for new general capture choices | Still needed | Still needed |

The Windows preview is a focused port of the interview, local-memory and evidence workflow. It does not pretend SwiftUI, CoreAudio, macOS Keychain or Carbon run on Windows. Windows Credential Locker uses keyring; WASAPI capture uses [PyAudioWPatch](https://github.com/s0d3s/PyAudioWPatch). No audio driver or local model is installed.

Windows recordings use the system's default input/output device at Start. Use headphones, close unrelated sound sources, and check both meters. Devices changing mid-call are not recovered automatically. Native capture errors stop the preview safely and preserve received text/audio; queue overload and transcription failures record explicit gaps. Windows speaker labels describe channels, not diarized people.

Each platform keeps local data under its OS user account. A separate OS account is needed for another person's clean workspace. This release does not introduce independent project databases or automatically migrate memory databases between platforms. Interview JSON retains the macOS-compatible transcript/date/source fields; TXT is also available for exchange. Importing JSON on macOS clears foreign audio paths rather than granting deletion access to them.
