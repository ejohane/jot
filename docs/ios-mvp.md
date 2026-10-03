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
