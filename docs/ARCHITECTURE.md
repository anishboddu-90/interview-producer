# Architecture

## Existing macOS app

The SwiftUI workspace and InterviewController remain the production app. Interview setup adds persisted topic/goals, purpose, stage, audio routing and language without replacing capture, memory, Lifeline or the story pipeline. Setup/provider editing is disabled during capture or report work. Interview records retain their saved setup so later reports do not silently inherit a different current topic. Older records remain decodable through optional fields; the legacy music investigation lane remains accepted while new lanes are neutral.

Capture feeds the existing bounded PCM segmenter, independent transcription queue and atomic interview store. A selectable call bundle targets the existing process-tap and fallback filters. Microphone-only capture skips the system stream and remote-silence guidance. Explicit microphone selection uses the existing serial AVCaptureSession engine; an unavailable selection fails rather than silently choosing another input. Auto selection prefers a built-in device, then the system default.

ChatGPTExportReader and ConversationMemory preserve original export objects and branch graphs. FTS5 indexes overlapping exact passages, with user observations/corrections prioritized over repeated assistant restatements. Memory annotations, exclusions, verification attestations and dossier versions never rewrite original text. Live editorial requests retrieve relevant evidence automatically and retain per-suggestion receipts. Deep reports select bounded exact excerpts from every chronological packet of long interviews; the full transcript remains saved.

CompatibleProvider adds a small explicit transport boundary. Text and audio settings are independent, secrets are endpoint-scoped, HTTPS is required, redirects are refused, completion is checked, and no failure automatically activates a different provider. The existing Groq-specific pacing/budgets and ChatGPT session implementation remain separate.

## Windows preview

The Python desktop is deliberately separate from macOS frameworks. `core.py` implements local FTS5, exact JSON object preservation, parent-link traversal, annotations/dossiers, atomic JSON/TXT session storage and citation validation. `providers.py` implements explicit compatible HTTPS APIs and Credential Locker-backed keys. `capture.py` opens WASAPI/default input channels, writes WAV before bounded cloud work, and owns session writes on one worker. The Tk UI communicates through immutable queue events; each thread opens its own SQLite connection.

Memory selection is local. Only recent transcript, relevant active-branch passages, dossier and current setup accompany an editorial request. Other sources' question banks and provider credentials are omitted. Queues are bounded, recording precedes networking, gaps are explicit, and Stop ends capture before draining pending cloud work. The preview lacks several richer macOS features, documented in PLATFORMS.md.
