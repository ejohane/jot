# Jot iOS MVP

One notebook across Mac and iPhone when iCloud is selected; device-local notebooks otherwise. Each device owns its open note and editor position. The existing Markdown files and adjacent attachments remain canonical.

## Acceptance evidence

- [ ] Physical iPhone build, install, launch
- [ ] First-launch local / iCloud choice and explicit storage transfer
- [ ] Restore current jot, caret, scroll, keyboard
- [ ] Immediate durable capture; background / termination restoration
- [ ] New Jot preserves keyboard; blank notes do not accumulate
- [ ] Markdown, images, dictation, longer writing
- [ ] Newest-first library, full-text search, open / dismiss preservation
- [ ] Offline iCloud edits, reconnect, Mac ↔ phone notes and attachments
- [ ] Concurrent edits preserve both versions
- [ ] Mac local-folder behavior regression check

Check boxes require observed evidence, not just implementation or compilation. Widgets, Share Extension, Siri and iPad-specific layouts are deferred.

## Iteration 1 — 2026-10-02

Implemented a phone target using the existing CodeMirror editor and Swift persistence core, local capture with a device-local recovery journal, New Jot, library and search. Added `script/build_ios.sh` to reproduce Simulator or physical-device delivery.

Evidence:

- Simulator and paired-device Debug builds succeeded.
- Installed and launched `com.erikjohansson.Jot.ios` on Erik’s iPhone (`00008140-001A686E0EDB001C`).
- Shared Swift suite: 61 executed, 1 skipped, 0 failures.
- Web editor suite: 104 passed.
- Simulator screenshot proves the first-launch screen renders. Reported automation taps did not produce a visible transition, so capture and restoration are still unverified.
- Physical review is waiting at iPhone Mirroring’s Touch ID gate.

Outstanding: iCloud and storage transfer, images, dictation, conflict recovery UI, dynamic type, hardware keyboard behavior, interactive capture/restoration evidence, Mac–phone sync and regression proof. The build on the phone is an early local-only iteration, not the completed MVP.

## Iteration 2 — 2026-10-02

Added Photos selection, clipboard image import, and a native attachment preview. Picked images use the existing portable PNG/relative-Markdown attachment format and editor undo transaction. New Jot and library navigation are held while the attachment insertion is in flight. Fixed the phone navigation delegate's Swift concurrency signature.

Evidence:

- Simulator build and physical-device build succeeded.
- Shared attachment suite: 3 tests passed, covering image-only capture, failed import without allocation, retained files for undo, and resource path containment.
- Web editor suite: 104 passed, including attachment insertion/undo behavior.
- Physical iPhone Mirroring remains locked at Touch ID. Photos selection, clipboard paste, preview and relaunch are not manually verified.

These test results cover the reused writer/editor behavior, not the new Photos picker or UIKit conversion. Their acceptance remains open.

## Iteration 3 — 2026-10-02

Added the local/iCloud storage choice, iCloud document container declarations, storage Settings, and an explicit transfer confirmation. The shared transfer preserves Markdown/image bytes and relative paths, retains the source as a backup, preflights destination collisions, and rechecks collisions under file coordination. Storage mode is saved atomically with the phone recovery session. An unavailable saved iCloud notebook cannot silently become a local notebook.

Evidence:

- Shared Swift suite: 65 executed, 1 skipped, 0 failures, including four transfer tests.
- Transfer tests cover note/attachment bytes, retained source, repeat transfer, conflicting destination, nested roots, source symlinks and destination directory links.
- Simulator build succeeds with iCloud entitlements.
- Physical iCloud build cannot be provisioned: Xcode reports no Accounts, and the installed wildcard profile has no iCloud/container entitlements. No iCloud build was installed on the phone.
- `secretsctl` reports no signing profile mapped to Jot; existing credential profiles contain app test identities, not Apple signing credentials.
- Requested Xcode Apple Developer account setup and physical review unlock from the user.

Outstanding: actual iCloud container availability, Mac integration, coordinated notebook edits/conflict preservation, cloud download/reconciliation, phone storage-transfer UI and live Mac–phone/offline sync evidence. Simulator compilation and local-directory transfer tests do not prove iCloud sync.

## Iteration 4 — 2026-10-02

Moved the expected-file comparison and replacement into one coordinated write for the production filesystem, shared by Mac and phone. Concurrent cooperating writers cannot both replace the same baseline. Removed transfer's nested coordination lock exposed by the regression suite. Added a phone Keep Both Versions action that saves local writing separately while retaining the external version. Conflict copies keep the original base directory so existing relative attachment links remain usable across date boundaries.

Evidence:

- Shared Swift suite: 68 executed, 1 skipped, 0 failures.
- New tests exercise two concurrent real-filesystem writers sharing one baseline, missing/existing-file protection, and an old-date conflict copy with a relative image link.
- Existing external-conflict, failed-copy, missing-file and attachment tests pass.
- Atomic-write performance gate passes; observed allocation p95 ~1.79 ms and replacement p95 ~1.63 ms for 1,000 local writes.
- Simulator build succeeds.

Keep Both Versions is implemented but not manually exercised. This does not verify iCloud conflict-version delivery, offline sync, or the physical phone flow. Mac storage UI and cloud reconciliation remain outstanding.

## Iteration 5 — 2026-10-02

Added the Mac Use iCloud Notebook action and explicit transfer confirmation. The folder picker prepares access without replacing the current folder. Transfer copies first, validates a replacement writer, saves the updated root/active-note session, then changes the live writer and indexes. The original notebook remains intact. Editing, native formatting and image import are locked during the switch; transfer is unavailable while dictation is preparing or active. A missing original root must be restored before transfer.

The Mac iCloud picker requires Jot's shared Jots folder, rather than accepting any iCloud folder that the phone would not use. Its container path check still needs confirmation against the real provisioned container on this Mac.

Evidence:

- Swift suite: 68 executed, 1 skipped, 0 failures.
- Web editor suite: 105 passed, including transfer locking for editable state, native formatting and clipboard image import.
- Production Mac app packages and signs successfully using the normal packaging script.
- Launched a disposable, separately identified Jot Review app with a session under `/tmp/jot-mvp-mac.KnnDXB`. Native inspection observed its initial Choose a Jots Folder panel. Subsequent automation did not reliably advance the picker; writing and transfer were not manually proven.
- No real user notebook was selected or migrated during this review.

Outstanding: manual Mac local capture/transfer regression proof, actual shared iCloud path validation, cloud download/reconciliation and conflict-version handling, phone dictation and remaining physical-device checks. iCloud signing and phone review still require the requested account/Touch ID setup.

## Iteration 6 — 2026-10-02

Added native phone dictation with microphone and speech permission requests, on-device recognition, an editor preview, and explicit Keep/Cancel controls. Keep inserts the transcript through the shared editor transaction; Cancel leaves saved text unchanged. Backgrounding, audio interruption and editor-process termination cancel the preview. Navigation and storage switching are held while dictation is active. Keyboard-row controls have 44-point targets.

Evidence:

- Simulator build succeeds with the new Speech/AVFoundation integration and privacy descriptions.
- Existing Web editor suite: 105 passed, including dictation preview, commit, cancel and undo behavior. These tests do not exercise native speech recognition.
- No microphone permission, transcription or interruption flow was manually observed on a phone.
- Physical delivery of this iteration still requires the previously requested iCloud signing setup.

Acceptance remains open for real dictation, live iCloud reconciliation/conflict delivery, and all outstanding physical-device and Mac interaction checks.

## Iteration 7 — 2026-10-02

Added a shared cloud-file availability helper and used it before phone active-note restoration and library opens. Remote-only files request a download and wait up to 15 seconds before returning a recoverable error. Cached cloud notes remain usable offline; refresh errors do not block opening that copy. Notebook opening now displays progress and offers retry after failure, with capture/library controls disabled until restoration completes.

Evidence:

- Five focused tests pass: local bypass, cached offline access, download completion, remote timeout and cancellation. Tests use injected download state and do not prove actual iCloud transport.
- Simulator build succeeds.
- Live iPhone Mirroring inspection still shows the Touch ID lock screen. No physical interaction was possible.

Outstanding: cloud-only notes are not yet discoverable by the full-text index until downloaded; active-note external reconciliation, iCloud conflict-version recovery, Mac download integration and attachment downloads still need implementation and live validation. The helper alone does not establish sync acceptance.

## Iteration 8 — 2026-10-02

Fixed phone journal restoration against newer external edits. The phone session now stores the canonical bytes last acknowledged by its writer. Unacknowledged recovery text restores against that baseline, rather than adopting newly read cloud bytes as permission to overwrite them. A differing or unknown baseline preserves the external file and supports saving recovered text separately. A disk write that completed before journal acknowledgement is recognized without creating a duplicate.

Evidence:

- Four new recovery tests pass, including external-version preservation plus a recovery copy, unchanged-baseline save, legacy journals with no baseline, and disk-write/journal-ack interruption.
- Full Swift suite: 77 executed, 1 skipped, 0 failures. Atomic write performance gates pass.
- Simulator build, install and launch succeed. Runtime inspection shows first-launch storage selection. The simulated On This iPhone tap left the same UI visible, so capture and relaunch remain unverified.

Outstanding: live cloud reconciliation and conflict versions, cloud-only library discovery, attachment/Mac download integration, and the physical-device/manual acceptance checklist. This recovery change applies to the phone journal; Mac startup recovery still needs a separate audit.

## Iteration 9 — 2026-10-02

Added phone iCloud inventory using a persistent NSMetadataQuery scoped to the app’s ubiquitous Documents and filtered to the selected notebook. Discovered Markdown paths join the shared library index even before contents are local. Unavailable notes show a cloud/download row and can be opened through the bounded download check. Markdown downloads are requested once per inventory configuration; metadata updates refresh an open library. Pull-to-refresh retries downloads. A quiet pending count states that search updates as note text downloads. Attachment downloads remain lazy and still need implementation.

Evidence:

- Full Swift suite: 79 executed, 1 skipped, 0 failures.
- New tests prove remote-only inventory rows have openable paths, unknown text does not produce false search matches, downloaded text replaces the pending row and becomes searchable, and paths outside the notebook/hidden files/non-Markdown are excluded.
- Final Simulator build succeeds after correcting Foundation notification names.
- Tests supply inventory URLs; the actual metadata-query transport and iCloud arrival notifications remain unverified without provisioned access. No live sync acceptance is claimed.

Outstanding: active-note reconciliation, NSFileVersion conflict preservation, attachment download behavior, Mac cloud integration/recovery audit, and manual phone/Mac acceptance.
