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
