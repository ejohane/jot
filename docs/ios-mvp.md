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

## Iteration 10 — 2026-10-03

Added active-note reconciliation on phone cloud metadata updates, foregrounding and dictation completion. Unchanged canonical bytes bypass editor locking. A changed file is adopted only when the writer has no unsaved/failed snapshot; otherwise the local snapshot remains protected for Keep Both Versions. Missing active files also preserve the snapshot instead of recreating the external file.

The shared editor now provides a lock-and-snapshot bridge call that returns exact Markdown source, revision, caret and viewport in the same JavaScript turn that disables editing. The phone applies that captured snapshot to the writer before reconciliation, covering content messages queued behind the current operation. Library/new/storage/image/dictation entry points are held during reconciliation.

Evidence:

- Full Swift suite: 82 executed, 1 skipped, 0 failures. New reconciliation tests cover clean external adoption followed by editing, dirty conflict preservation plus a copy, and unchanged-file revision stability.
- Web suite: 106 passed; new coverage verifies complete source/caret capture and editor locking. Production Web build succeeds.
- Final Simulator build succeeds.
- Live iPhone Mirroring inspection still shows the Touch ID gate, so reconciliation has not been manually observed on the physical phone.

Outstanding: NSFileVersion conflict preservation, Mac reconciliation/recovery audit, attachment downloads and live cloud/manual acceptance. The injected-file tests do not prove cross-device delivery or the native WebKit handoff.

## Iteration 11 — 2026-10-03

Applied baseline-aware startup recovery to Mac. PersistedSession now records acknowledged canonical bytes, with optional decoding for older sessions. Startup restores newer journal text against that baseline, preserves differing external text for Save Copy, and retries safe recovered writes. A recovery captured before note allocation is retained and allocated once root access exists. The Mac journals content before sending a snapshot to its writer. Successful writes update the acknowledged note/data pair from one actor operation; opening/reloading/transferring clears or updates the baseline appropriately.

Evidence:

- Full Swift suite: 83 executed, 1 skipped, 0 failures. New coverage verifies capture recovery before allocation acknowledgement; the existing recovery tests prove external text preservation and safe copy behavior.
- Production Mac app packages and signs successfully with the standard packaging script.
- No Mac startup/force-quit UI interaction was manually proven in this iteration. Packaging is not that evidence.

Outstanding: live iCloud conflict-version handling, Mac external reconciliation/download integration, attachment downloads and physical/manual acceptance checks.

## Iteration 12 — 2026-10-03

Added shared NSFileVersion conflict preservation. Each unresolved Markdown version is read under file coordination, written to a deterministic sibling Markdown path and verified byte-for-byte before setting that version resolved. The canonical jot remains untouched. Sibling copies preserve relative attachment references, and content-derived filenames let interrupted retries and cooperating devices reuse the same copy. Failed reads/writes retain unresolved versions. Historical versions are not deleted by this implementation.

Phone inventory updates, foregrounding and refresh trigger preservation, with another scan queued if metadata changes while a scan runs. Mac iCloud notebook refreshes run the same archive path. Users receive a notice when separate versions are retained.

Evidence:

- Full Swift suite: 86 executed, 1 skipped, 0 failures. Three new tests cover retained original bytes, relative image directory, retry idempotence, distinct-version paths and failure before resolution acknowledgement.
- Final Simulator build succeeds. Standard Mac packaging/signing succeeds.
- Tests inject version readers/resolution callbacks; actual iCloud NSFileVersion delivery and resolution remain unverified. No live conflict was created or resolved on the user’s notebook.

Outstanding: Mac reactive cloud reconciliation/download integration, attachment downloads, actual iCloud provisioning/transport and manual phone/Mac acceptance.

## Iteration 13 — 2026-10-03

Shared attachment scheme requests now use bounded cloud preparation and coordinated reads off the UI thread. The handler tracks each request on the main actor, cancels its worker on WebKit stop or notebook-root changes, and checks request liveness before delivering callbacks. This avoids callbacks to stopped WKURLSchemeTask objects. Local attachments use the same path without requiring iCloud.

The shared editor replaces an unavailable image with a Retry action, retaining the Markdown reference. Retry starts a fresh resource request; a loaded image resumes Preview behavior. Phone and Mac native previews also prepare the attachment before opening it and suppress a late preview after switching notes/notebooks.

Evidence:

- Full Swift suite: 88 executed, 1 skipped, 0 failures. New tests use real local attachment files and a recording WKURLSchemeTask to verify exact MIME/bytes/completion and zero callbacks after stopping a request.
- Web suite: 106 passed, including unavailable-image retry and return to preview behavior; production Web build succeeds.
- Simulator build and Mac packaging/signing succeed.
- Actual iCloud image transport, timeout/retry on the phone, and native previews remain manually unverified.

Outstanding: Mac reactive sync/download integration, cloud transfer readiness, physical iCloud provisioning, and manual acceptance checks for capture/relaunch/search/images/dictation/sync/Mac regression.

## Iteration 14 — 2026-10-03

Added a Mac notebook NSFilePresenter for coordinated/iCloud file notifications. Notifications coalesce before refreshing the library/tags and reconciling the open jot. Refresh waits while note switching, image insertion or dictation is active, retaining pending changes. Changing the notebook cancels the old refresh and replaces its presenter.

Mac reconciliation captures and locks the shared editor, persists its exact snapshot, then uses the shared writer’s clean-adoption/conflict-preservation path. Unchanged files do not lock editing. Late content messages with older revisions cannot replace reconciled recovery text. Mac startup/reconciliation prepares cloud files before treating them as missing. Current cloud copies bypass repeated download requests, avoiding refresh loops.

Evidence:

- Full Swift suite: 90 executed, 1 skipped, 0 failures.
- A new real-filesystem integration test registers NSFilePresenter and performs a coordinated external Markdown write; the presenter receives a notification and the file has the expected bytes. This proves local coordination notification delivery, not iCloud delivery or rendered Mac UI.
- New download coverage verifies current cloud files do not issue redundant refresh requests.
- Production Mac packaging/signing and Simulator build succeed.

Outstanding: Mac cloud-only note discovery/open handling, transfer download readiness, actual iCloud provisioning/transport and all unproven manual phone/Mac acceptance flows.

## Iteration 15 — 2026-10-03

Moved phone cloud inventory into a shared NotebookCloudInventory. It inventories all visible files in the selected notebook, while the phone library still filters Markdown and requests only Markdown downloads automatically. A bounded initial-gathering snapshot supports transfers on both platforms. Transfers gather cloud source/destination paths, require those paths to be current, and complete preparation before beginning destination writes. Cached stale copies remain usable for ordinary editing but cannot satisfy transfer readiness. Sources remain retained backups.

Phone transfer now captures and locks the editor before flushing, including hardware/native formatting input. Queued saves retain their original writer, and old writer events cannot update a newly configured notebook. Editing resumes after destination restoration, or immediately after a failed transfer.

Evidence:

- Full Swift suite: 93 executed, 1 skipped, 0 failures. New tests verify unavailable cloud content aborts before creating the destination, downloaded attachment bytes enter the transfer and remain at the source, and stale cached copies cannot satisfy strict readiness.
- Final Simulator build and standard Mac packaging/signing succeed.
- Metadata inventory transport, strict download readiness and native phone transfer handoff remain unverified against provisioned iCloud/on-device UI. The snapshot covers inventory known at gathering time; retained source backups protect later remote arrivals.

Outstanding: Mac cloud-only library discovery/open handling, current signing/account setup and physical/manual acceptance checks.

## Iteration 16 — 2026-10-03

Connected shared cloud inventory to Mac navigation and full-text search. Cloud-only Jot paths become navigable rail entries, and known downloaded paths replace placeholders without duplicates. Open waits for cloud preparation before reading the selected file. Inventory/file notifications refresh an open search; a pending-content status explains that full-text matches update after download. Root transfer configures inventory after committing the new storage mode. Rail previews avoid opening undownloaded content.

Evidence:

- Full Swift suite: 94 executed, 1 skipped, 0 failures. New coverage proves an absent cloud Jot has a navigation path and that downloaded content replaces its placeholder exactly once. Shared search coverage already verifies unknown text cannot produce matches and downloaded text becomes searchable.
- Web suite: 106 passed. Production Mac packaging/signing and Simulator build succeed.
- Retried the actual paired-device build: it fails with Xcode No Accounts and a wildcard profile lacking Jot’s iCloud/container entitlements. This iteration was not installed on the iPhone.
- Live iPhone Mirroring inspection still shows the Touch ID lock.

Outstanding: provisioned iCloud container/path validation, real Mac–phone/offline/conflict/transfer tests, manual phone capture/restoration/search/images/dictation and Mac local regression, plus remaining accessibility/hardware-keyboard/launch audits. No acceptance boxes are closed by these builds alone.

## Iteration 17 — 2026-10-03

Routed phone Cmd-P/Cmd-K into the native Jots library. The shared desktop palettes previously emitted actions/search requests that PhoneEditor did not handle; phone shortcuts now use its native library while Mac behavior remains unchanged. Library opening and New Jot are gated until notebook restoration is ready. The native library Done button accepts Escape. Toolbar input is disabled while restoration, transfer or reconciliation is in progress.

Phone editor body text now follows the SwiftUI Dynamic Type category through UIKit’s preferred body font size and the editor CSS variable, including accessibility categories and WebKit reload readiness. Header text uses the system subheadline style.

Evidence:

- Web suite: 107 passed. New coverage verifies the phone shortcuts emit native library requests, do not open desktop panels, and preserve document text; existing desktop palette tests pass. Production Web build succeeds.
- Simulator build succeeds.
- Physical keyboard appearance, hardware shortcuts, Dynamic Type layout and VoiceOver remain unverified on the iPhone.

Outstanding: editor/session lifecycle race audit, actual phone/manual acceptance, iCloud provisioning and live sync/transfer evidence. These tests do not close launch/keyboard acceptance.

## Iteration 18 — 2026-10-03

Added phone editor-session identities to loaded documents and native-bound bridge messages. PhoneEditor ignores messages from a replaced session; content/caret handling and queued saves also validate the identity at execution. Locked snapshots echo the identity. Deferred viewport/focus restoration checks the current load generation so an older load cannot reposition a newer document.

New Jot and open-note transitions now lock/capture/persist the exact current editor text before flushing or switching. Writer callbacks route through a current acknowledged-state snapshot, matching the current writer/session/note and blocking state before changing the UI. This prevents delayed allocation/error events from affecting a replacement document.

Evidence:

- Web suite: 108 passed. New coverage verifies document callbacks, locked snapshots and New Jot actions carry the loaded phone session identity. Existing source/recovery/undo tests remain green. Production Web build succeeds.
- Full Swift suite: 94 executed, 1 skipped, 0 failures after extending the acknowledged writer-state snapshot with blocking state.
- Final Simulator build succeeds.
- Native rejection of delayed callbacks and rapid New/open/typing transitions remain manually unverified; bridge tests alone do not prove their full WebKit ordering.

Outstanding: phone editor readiness/photo-picker lifecycle audit and observed acceptance flows, plus the existing signing/Touch ID and live iCloud verification requirements.

## Iteration 19 — 2026-10-03

Phone controls now wait for both notebook recovery and the WebKit editor readiness handshake. Renderer reload/failure disables editing until recovery completes. Photo selection reserves its source editor session before asynchronous loading; cancellation and stale results cannot insert into a replacement jot or replace its error state.

Interrupted imports discard only an uncommitted, empty allocation whose Markdown file does not exist. Staged image bytes remain available, and saved writing is preserved.

Evidence:

- Full Swift suite: 96 executed, 1 skipped, 0 failures. New tests exercise interrupted empty image capture and preservation of saved writing.
- Simulator build succeeds; diff whitespace check passes.
- Physical build could not find the paired iPhone destination. A separate generic-device signing check still fails (see local log `/tmp/jot-ready-signing.log`). No current physical install or launch is claimed.
- WebKit readiness, photo-picker cancellation/reload, and the original phone/sync acceptance flows remain manually unverified.
