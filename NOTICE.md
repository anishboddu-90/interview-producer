# Attribution and modifications

This application is distributed under GPL-3.0. LICENSE contains the complete upstream license.

Upstream: Uygar Turantekin / Parrot, https://github.com/turantekin/Parrot, inspected revision `f9f2e2beab374b641d445a3390e15b132090ecd6`.

Reused files: AudioCaptureManager.swift, SystemAudioTap.swift, EchoCanceller.swift, EchoGate.swift and PermissionFlow.swift. GroqTranscriber.swift contains Parrot's Groq transport, multipart and WAV helpers. SpeexDSP is vendored from Parrot's Vendor/CSpeexDSP; original Xiph/SpeexDSP BSD-style notices are preserved in each source file.

Modifications on November 2, 2026: app-specific Zoom process tap and ScreenCaptureKit filters; private audio directory; per-engine built-in microphone selection; renamed local storage; Groq request budget reservation and error handling. The focused package replaces Parrot's orchestration, UI, assistant and storage with the included Interview Producer sources. It does not use WhisperKit, FluidAudio, Ollama, Sparkle or their downloaded artifacts.

New code includes the official ChatGPT public-client OAuth/Responses implementation, research library, editorial validation, bounded streaming/transcription orchestration, persistent interviews, nonactivating UI, fixtures and deterministic tests. All corresponding source and build scripts are supplied with the app. Preserve these notices and provide corresponding source under GPL-3.0 when redistributing a modified or compiled version.


Version 0.2 modifications: added local SQLite/FTS5 conversation storage, exact export-object preservation, branch-aware selective import, original-passage retrieval, separate annotations/versioned dossier, native memory UI, source-evidence snapshots and memory tests. SQLite is provided by macOS; no third-party Swift database package was added. Published export-schema inspection informed compatibility tests; no source code from that schema project was incorporated. Existing GPL-3.0 attribution remains in effect.

Version 0.3.0 (November 3, 2026): extended this same app with evidence-attributed music-journalism prompts, a local investigation ledger, source-specific briefs and seven-part reports. Audio/transcription/authentication and conversation-memory implementation retained. New code is included under this project’s GPL-3.0 license.

Version 0.4.0 (November 3, 2026): extended this same app with persistent source-specific question profiles, manual and optional automatic Question Lifeline, exact answer receipts and configurable system hotkey registration. Capture/transcription/authentication and original conversation-memory implementations retained. The personal bank is imported local data, not an application default.

Version 0.5.0: neutral interview setup and defaults; selected-application and microphone-only capture; configurable language; endpoint-scoped compatible APIs; privacy guard and CI; a separate Windows desktop preview with WASAPI capture, SQLite memory, evidence validation and source-specific question banks. Dependencies retain their respective licenses. No personal reporting material forms part of this distribution.
