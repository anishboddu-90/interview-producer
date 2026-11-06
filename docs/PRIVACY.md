# Privacy and local data

The repository and build artifacts contain source and fictional fixtures. They exclude imported conversations, research files, personal question banks, session archives, recordings, credentials, local verification logs and database backups. The privacy guard scans tracked files before CI builds. Maintainers can additionally pass a private JSON deny-list from outside the repository using `--deny-file`.

macOS retains the existing `org.interviewproducer.mac` app identity. Installed user data remains under `~/Library/Application Support/InterviewProducer/`; secrets remain in macOS Keychain. Windows preview data is under `%LOCALAPPDATA%\InterviewProducer\`; keys use Windows Credential Locker. The app relies on the current OS user's account protections. It does not encrypt all local content or isolate independent projects/users within one account.

Audio capture, file parsing and FTS5 indexing are local. When enabled, the selected transcription service receives speech chunks, and the selected editorial provider receives bounded transcript/research/memory excerpts. The complete export is never automatically uploaded. `store:false` is a request setting, not a guarantee about all provider logging or retention. Review the provider's policies for your interview.

All successfully received transcript segments are saved incrementally. Speech recognition can omit/mishear words; pending speech, outages or overload can leave gaps. The local recording is the source for checking quotations. Use Stop and wait for processing before closing; on abrupt termination, already-saved text remains available. No promise of crash-proof disk writes or recoverable audio after power failure is made.

Deleting an imported conversation removes its local memory index and annotations, not the original export on disk. Existing saved suggestions/reports can contain historical evidence snapshots; inspect/delete those separately when removing a source completely. Removing local data cannot retract material a selected provider already processed. Source deletion and exclusion semantics should be reviewed before sharing a completed archive.

Screen-share exclusion is environment-dependent on macOS. The Windows preview has no share-hidden overlay. Share a specific unrelated application window and verify with the receiver if privacy matters. Full-desktop sharing can expose the main app and other private content.
