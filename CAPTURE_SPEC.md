# Local Markdown Capture Utility — v0.1 Specification

Status: Product and implementation direction approved; ready for implementation planning.

This specification defines the first complete slice: one active, continuously autosaved Markdown jot in a global macOS composer. It deliberately stops before library, organization, and AI features.

## 1. Product contract

The product makes one promise:

> Invoke the composer, write, move between applications as needed, and trust that the exact Markdown is already stored locally. Press Command-Return when the thought is complete and continue in a new blank jot.

The user never performs a separate save operation. Command-Return means **Finish & New**, not Save.

## 2. Goals

- Make shortcut-to-writing feel immediate.
- Preserve one active jot across focus changes, hiding, quitting, and relaunching.
- Create the canonical Markdown file as soon as the blank composer first receives text.
- Autosave the exact source continuously without converting it through a rich-document model.
- Provide live Markdown presentation without changing the source string.
- Keep capture performance independent of the total archive size.
- Make every failure visible and recoverable without clearing the editor.

## 3. Non-goals

The following are explicitly outside v0.1:

- A library, recent-notes view, search, or indexing
- Tags, highlights, backlinks, relationships, or folders managed by the app
- AI, summarization, embeddings, or generated content
- Attachments, image storage, drawing, audio, or rich-text persistence
- Cloud sync, accounts, collaboration, or a mobile client
- Editing, moving, renaming, organizing, or deleting previous jots inside the app
- Markdown preview mode or split-pane preview
- Multiple active jots, tabs, or multiple composer windows
- Automatic titles, slugs derived from content, frontmatter, or body metadata

## 4. Terms

- **Composer:** The floating editor window.
- **Blank composer:** A composer whose current buffer has never produced a jot file.
- **Active jot:** The Markdown file currently bound to the composer.
- **Finish & New:** The Command-Return action that flushes the active jot, releases it, and creates a new blank composer state.
- **Canonical source:** The exact UTF-8 Markdown string stored in the jot file.
- **Presentation:** Disposable styling and widgets derived from the canonical source.

## 5. Interaction model

### 5.1 State transitions

| Current state | Event | Required result |
|---|---|---|
| Hidden | Global shortcut | Show and focus the composer, restoring its current buffer, selection, scroll position, and size. |
| Visible but inactive | Global shortcut | Bring the existing composer forward and focus the editor. |
| Visible and focused | Global shortcut | Keep the composer focused; do not hide, clear, or create another window. |
| Blank composer | First committed text mutation | Allocate the jot identifier and path, create the Markdown file, bind it as active, and begin autosaving. |
| Blank composer | Command-Return | Do nothing. No file is created. |
| Blank composer | Escape | Hide the composer. No file is created. |
| Active jot | Text mutation | Update CodeMirror immediately and schedule the newest exact source for serialized persistence. |
| Active jot | Click or switch to another application | Preserve the active jot and force any pending write. Keep the composer open but inactive. |
| Active jot | Escape | Force pending writes, then hide without ending the jot. |
| Active jot | Global shortcut after hiding or covering | Recall the same jot and editor state. |
| Active jot | Command-Return | Force and verify the latest write. On success, release the jot and show a focused blank composer. |
| Active jot | Normal quit | Flush writes and persist session state before terminating. |
| Active jot | Relaunch | Reopen the same active file and restore the best available selection, scroll position, and window frame. |
| Any saving state | Write failure | Retain the full editor buffer, keep the jot active, show a persistent actionable error, and refuse Finish & New. |

Only one composer and one active jot may exist.

### 5.2 Window behavior

- The composer is a floating macOS panel available from a configurable global shortcut and the menu-bar item.
- It appears on the currently active display, using its last sensible size and position for that display.
- It begins compact, grows vertically with its content up to a defined maximum, and scrolls thereafter.
- The user may resize it; the size is restored later.
- Losing focus does not dismiss, clear, finish, or replace the active jot.
- Escape hides the panel. The global shortcut recalls it.
- The composer must not steal focus except when the user invokes it or selects it.
- Normal Return inserts a newline. Command-Return invokes Finish & New.

### 5.3 Minimal controls

The editor contains no title field, toolbar, formatting buttons, tags, folders, or AI controls.

The menu-bar menu provides:

- Show Jot
- Finish & New, enabled only when an active jot exists and is writable
- Reveal Current Jot in Finder, enabled only when a jot exists
- Open Jots Folder
- Change Shortcut
- Change Jots Folder
- Launch at Login
- Quit

The visible status vocabulary is limited to:

- `Saving…`
- `Saved`
- A specific persistent error with a recovery action

Status changes must be quiet and must not shift the editor layout.

## 6. Canonical file contract

### 6.1 Root and folder access

- First run asks the user to choose or create a local Jots root, suggesting `~/Documents/Jots`.
- The native shell persists access through a security-scoped bookmark.
- Changing the root affects future jots only. Existing files are never silently moved.
- If the root cannot be accessed, the composer retains its buffer and requests that the user restore or choose access. It must not redirect writing to an undisclosed location.

### 6.2 Path format

Each jot is sharded by the local calendar date on which its first text mutation occurred:

```text
<root>/YYYY/MM/DD/HH-mm-ss-SSS--<ULID>.md
```

Example:

```text
Jots/2026/09/21/14-42-18-391--01K5R8T7Q95W6E3G9A7D2P4M6N.md
```

Requirements:

- The identifier is collision-resistant and generated before the first file write.
- Path allocation never enumerates the archive.
- The date and clock component use the user's local time at jot creation.
- The identifier remains the stable machine identity of the file even if two jots share a timestamp.
- The body is UTF-8 without a byte-order mark and uses LF line endings for app-generated line breaks.
- The body contains exactly the editor source. No title, timestamp, frontmatter, ID, or application comment is injected.
- Once created, a file remains even if the user later edits its body to an empty string. The app does not silently delete it.

### 6.3 Atomic writes

- Native code owns all filesystem writes.
- Writes are serialized per active jot.
- A write uses a sibling temporary file followed by atomic replacement where the filesystem supports it.
- At most one latest snapshot may supersede queued, not-yet-started snapshots. An in-flight write is never reordered.
- A successful acknowledgement identifies the exact editor revision that reached disk.
- Focus loss, Escape, Finish & New, root changes, and normal termination force the newest revision to flush.
- Stale temporary files are detected at launch and either recovered safely or removed after verifying the canonical file.

### 6.4 External edits

Before replacing an existing active file, the writer compares the on-disk version with the last version it successfully wrote.

If the file changed externally:

- Autosave pauses before overwriting it.
- The in-memory composer buffer is retained.
- The user sees: `This jot changed outside the app.`
- `Save My Version as a Copy` writes the composer buffer to a new jot file and keeps the external file unchanged.
- `Reload External Version` replaces the composer buffer only after explicit confirmation that unsaved in-memory differences will be discarded.
- The app never attempts an automatic merge in v0.1.

## 7. Autosave contract

- The first committed content mutation, including paste or completed IME composition, starts file creation immediately.
- Transient IME composition text is not persisted until the input system commits it.
- Editor changes are sent to native code with a monotonically increasing revision number.
- The writer may coalesce rapid pending revisions but must persist the newest snapshot within 250 ms after editing becomes idle and at least once per second during sustained typing.
- Blur, hide, Finish & New, and normal quit bypass the idle delay and request an immediate flush.
- `Saved` may appear only when the current editor revision has received a successful native write acknowledgement.
- Finish & New may clear the editor only after the current revision is acknowledged.
- If native code or the embedded editor restarts, the canonical file plus session state determine what reopens. No acknowledged revision may be lost.

## 8. Live Markdown editor

### 8.1 Source model

- CodeMirror's document string is the editor source and must equal the canonical file body after the latest acknowledged write.
- React must not mirror the complete document as controlled component state on every keystroke.
- Markdown parsing and presentation are derived CodeMirror extensions.
- Presentation must never rewrite or normalize Markdown automatically.
- Incomplete, malformed, or unsupported Markdown remains editable literal source and remains safe to save.

### 8.2 Dialect

The presentation parser uses GitHub Flavored Markdown support while remaining tolerant of arbitrary plain Markdown source.

v0.1 live presentation covers:

- ATX headings
- Strong emphasis, emphasis, and strikethrough
- Inline code and fenced code blocks
- Links
- Blockquotes
- Bulleted and ordered lists
- Task-list checkboxes
- Horizontal rules

Tables, images, raw HTML, footnotes, math, diagrams, frontmatter, tags, highlights, and custom directives remain literal source in v0.1. They must not be damaged or rejected.

### 8.3 Presentation rules

- Headings receive typographic hierarchy without removing their source line.
- Strong, emphasis, strikethrough, inline code, links, quotes, lists, task items, and code fences receive semantic styling.
- Markdown delimiter characters remain present in the document and are visually de-emphasized.
- Delimiters belonging to the current selection or construct become sufficiently visible for precise editing.
- Unsupported or incomplete constructs remain legible source rather than flickering between representations.
- Decorations must not change document offsets, undo history, copied Markdown, selection, or autosaved text.
- Pasting rich text inserts plain text. Pasting files or images does not create attachments in v0.1.

## 9. Technical architecture

### 9.1 Native shell

- Swift macOS application using AppKit.
- `NSPanel` hosts the composer and implements focus, floating, display placement, hiding, and restoration.
- `NSStatusItem` owns the menu-bar surface.
- A global-shortcut component invokes or focuses the single panel.
- `WKWebView` hosts bundled, local editor assets.
- A serial Swift actor owns note allocation, revision ordering, atomic writes, conflict detection, and acknowledgements.
- Native application state stores the active path, acknowledged revision, selection, scroll anchor, panel frame, chosen root bookmark, shortcut, and launch-at-login preference.
- Session metadata lives under Application Support and is never required to understand the Markdown archive.

### 9.2 Web editor

- React with TypeScript, built as static local assets.
- CodeMirror 6 with the Markdown language package and a product-owned live-presentation extension.
- CodeMirror owns editor text, selection, history, and transactions.
- React owns the surrounding status and error interface.
- The editor makes no network requests and receives no Node.js access.

### 9.3 Bridge

The bridge is narrow, versioned, and typed. Its conceptual messages are:

```text
native → editor: loadSession(text, noteID?, revision, selection, scroll)
editor → native: contentChanged(noteID?, revision, text, selection, scroll)
editor → native: finishAndNew(revision)
native → editor: noteAllocated(noteID, path, revision)
native → editor: writeSucceeded(noteID, revision)
native → editor: writeFailed(noteID?, revision, errorCode, recoveryActions)
native → editor: externalConflict(noteID, recoveryActions)
```

Rules:

- Messages for obsolete note IDs or revisions are ignored.
- The editor never clears because of a timeout; it waits for an explicit success.
- Native errors use stable codes plus user-readable copy.
- Bridge payloads contain only local editor and session data.

### 9.4 Build and dependencies

- JavaScript dependencies are locked and reproducible.
- The React bundle is built before the native app packages its resources.
- Runtime assets are entirely local and governed by a restrictive content-security policy.
- Third-party live-Markdown wrappers are not foundational dependencies in v0.1; the presentation extension is built directly on CodeMirror primitives.
- No runtime analytics, telemetry, update check, remote font, CDN, or external request is permitted in v0.1.

## 10. Error behavior

| Failure | Required behavior |
|---|---|
| Root permission revoked | Retain the editor buffer, pause writes, and offer to restore folder access. |
| Root moved or deleted | Retain the buffer and request a valid root. Do not silently choose another folder. |
| Disk full or atomic replacement fails | Keep the buffer and active jot, show the error persistently, and disable Finish & New. |
| Web editor reloads | Rehydrate from native session state and the latest canonical file without allocating a second jot. |
| Native bridge unavailable | Keep text in CodeMirror, show that saving is interrupted, and retry when the bridge returns. |
| External file edit | Pause and require Save as Copy or explicit Reload; never overwrite silently. |
| Current file deleted externally | Treat it as a conflict and offer Save My Version as a Copy. |
| Stale session path | Start safely from the existing file if readable; otherwise preserve recovery state and present a resolvable error. |

## 11. Accessibility and platform behavior

- The complete capture and rollover flow is keyboard operable.
- Focus order contains only the editor, error actions when present, and necessary system controls.
- VoiceOver announces the composer as an editable Markdown document, the saving state, Finish & New, and errors.
- Decorative rendered presentation does not cause source text to be announced twice.
- Selection, arrow navigation, Option/Command word and line movement, undo/redo, copy/paste, dictation, and common IMEs behave correctly.
- The interface supports light mode, dark mode, Increase Contrast, Reduce Transparency, and Reduce Motion.
- Saving is communicated by text or accessibility status, not color alone.
- Window placement works across multiple displays and Spaces without stranding the composer off-screen.

## 12. Performance budgets

Measured on the oldest supported Mac under a release build:

- Warm global shortcut to focused caret: p95 at or below 200 ms.
- First committed edit to canonical file existence: at or below 250 ms when the target volume is writable.
- Idle text edit to acknowledged disk state: at or below 250 ms.
- Sustained typing: the canonical file receives a current snapshot at least once per second.
- Editor input-to-paint latency in a 250,000-character note: p95 below 50 ms.
- Finish & New after an already acknowledged revision: blank composer visible within 150 ms.
- The capture path performs no recursive archive enumeration.
- With 100,000 synthetic jots distributed across date shards, shortcut and save timings remain within 10% of an empty archive baseline.

## 13. Definition of done

v0.1 is done only when every required item below has evidence. Passing unit tests alone is insufficient.

### 13.1 Automated behavior tests

- [ ] **CAP-001 — Empty invocation:** Open, hide, reopen, and quit a blank composer; verify no jot file is created.
- [ ] **CAP-002 — First mutation allocation:** Type one committed character; verify exactly one correctly sharded `.md` file appears within the budget and contains that character.
- [ ] **CAP-003 — Continuous autosave:** Perform inserts, deletions, multiline edits, undo, redo, paste, and selection replacement; after every acknowledged revision, verify file bytes equal the CodeMirror document string.
- [ ] **CAP-004 — Sustained typing:** Generate continuous edits for at least ten seconds; verify disk snapshots occur at least once per second and the final file is exact.
- [ ] **CAP-005 — Focus hopping:** Type, focus at least two other applications, return through the shortcut, and verify the same path, text, selection, scroll position, and window state are retained.
- [ ] **CAP-006 — Hide and recall:** Escape hides without finishing; the shortcut restores the same active jot.
- [ ] **CAP-007 — Finish & New:** Invoke Command-Return with writes both idle and in flight; verify the old file contains the latest text, then verify a blank focused composer appears and no next file exists until typing begins.
- [ ] **CAP-008 — Relaunch restoration:** Quit and relaunch with an active jot; verify the same file and latest acknowledged content reopen without duplication.
- [ ] **CAP-009 — Empty-after-creation:** Create a jot, delete all text, and verify the original file remains with a zero-length body.
- [ ] **CAP-010 — Concurrent revision ordering:** Artificially delay and reorder write completions; verify an older revision never overwrites a newer one.
- [ ] **CAP-011 — Unique allocation:** Create at least 10,000 jots with identical mocked timestamps; verify unique paths and no overwrite.
- [ ] **CAP-012 — Root change:** Change roots with an active jot; verify the active file stays in its original root and only the next jot uses the new root.

### 13.2 Failure and recovery tests

- [ ] **ERR-001 — Permission loss:** Revoke root access during editing; verify text remains, the error is actionable, and Finish & New cannot clear the buffer.
- [ ] **ERR-002 — Write failure:** Inject disk-full and atomic-replacement errors; verify no success acknowledgement and no data-clearing transition occurs.
- [ ] **ERR-003 — External modification:** Change the active file externally; verify autosave pauses before overwrite and both recovery actions preserve the chosen version.
- [ ] **ERR-004 — External deletion:** Delete the active file externally; verify Save My Version as a Copy succeeds without recreating over the deleted path silently.
- [ ] **ERR-005 — Editor reload:** Reload or terminate the web content process; verify the active jot rehydrates without a duplicate file.
- [ ] **ERR-006 — Application termination:** Terminate the app after a successful write acknowledgement; verify that revision survives and reopens.
- [ ] **ERR-007 — Temporary-file recovery:** Simulate interruption during replacement; verify launch recovery produces one valid canonical file and no ambiguous duplicate.

### 13.3 Markdown and editor tests

- [ ] **MD-001 — Exact source:** Round-trip a fixture corpus containing CommonMark, GFM, unsupported extensions, mixed line content, Unicode, emoji, and incomplete syntax; verify no automatic normalization.
- [ ] **MD-002 — Live presentation:** Verify supported headings, emphasis, strikethrough, code, links, quotes, lists, task items, and rules receive the intended presentation without changing source offsets.
- [ ] **MD-003 — Marker visibility:** Verify delimiters are de-emphasized normally and become clearly editable when the selection enters their construct.
- [ ] **MD-004 — Malformed input:** Type and edit incomplete fences, links, emphasis, lists, and HTML; verify no crashes, content loss, cursor jump, or forced correction.
- [ ] **MD-005 — Clipboard:** Verify rich text pastes as plain text and copied editor content is canonical Markdown.
- [ ] **MD-006 — Composition:** Verify representative macOS IMEs and dead-key composition do not allocate or save transient composition states and correctly persist committed text.
- [ ] **MD-007 — History:** Verify presentation updates and write acknowledgements do not create undo steps or corrupt redo history.

### 13.4 Accessibility tests

- [ ] **A11Y-001 — Keyboard:** Complete show, write, hide, recall, Finish & New, folder recovery, and conflict resolution without a pointer.
- [ ] **A11Y-002 — VoiceOver:** Verify the source is announced once, status changes are understandable, and errors expose named actions.
- [ ] **A11Y-003 — System settings:** Verify light/dark appearance, Increase Contrast, Reduce Transparency, Reduce Motion, and enlarged text.
- [ ] **A11Y-004 — Focus:** Verify focus never disappears or moves unexpectedly during autosave, presentation refresh, error display, or rollover.

### 13.5 Performance and scale tests

- [ ] **PERF-001 — Warm invocation:** Record at least 100 shortcut invocations and meet the p95 focus budget.
- [ ] **PERF-002 — Autosave latency:** Record first-allocation and idle-write latency over at least 1,000 edits and meet the p95 budgets.
- [ ] **PERF-003 — Large note:** Exercise a 250,000-character Markdown fixture and meet the input-to-paint budget while autosaving.
- [ ] **PERF-004 — Large archive:** Repeat invocation and save benchmarks with 100,000 date-sharded jots and remain within 10% of baseline.
- [ ] **PERF-005 — No archive scan:** Instrument the capture path and verify it touches only session state, the current date directory, the active file, and its temporary replacement.

### 13.6 Privacy and packaging tests

- [ ] **PRIV-001 — Offline runtime:** Monitor network activity through the complete flow and verify the application makes no runtime requests.
- [ ] **PRIV-002 — Canonical ownership:** Remove the application and verify every jot remains readable as ordinary Markdown using another editor.
- [ ] **PKG-001 — Reproducible build:** A clean checkout produces the React assets and macOS application using documented commands and locked dependencies.
- [ ] **PKG-002 — Installed application:** Install and launch the release build; verify the bundled editor loads without a development server.
- [ ] **PKG-003 — Bundle integrity:** Verify the bundle contains only local production assets and that debug tooling is disabled in the release build.

### 13.7 Manual acceptance

- [ ] Use the installed release build as a real floating jot surface across at least five Mac applications for a sustained session.
- [ ] Capture one-line notes, multiline notes, pasted text, and a long-form note.
- [ ] Visually inspect supported Markdown presentation, selection behavior, marker fading, saving status, dark mode, errors, and rollover.
- [ ] Verify Finder shows the expected date-sharded files and an external Markdown editor displays their exact contents.
- [ ] Confirm the panel behaves correctly across multiple displays, Spaces, full-screen applications, sleep/wake, and app relaunch.
- [ ] Confirm no observed interaction loses, duplicates, normalizes, or silently overwrites text.

## 14. Completion evidence

The implementation handoff must report these independently:

1. Automated unit and integration tests
2. React production build
3. Native macOS build
4. Installed-app launch
5. Manual interaction results
6. Accessibility results
7. Performance measurements
8. Failure-injection results
9. Network/privacy observation
10. Known limitations or deferred items

Do not substitute one category for another. In particular, a successful build does not prove autosave behavior, and a passing source-level test does not prove focus, VoiceOver, or multi-application interaction.

## 15. Open, non-blocking decisions

These decisions may be made during implementation without changing the product contract:

- Product name and icon
- Bundle identifier
- Default global shortcut
- Minimum supported macOS version
- Exact typography, colors, spacing, corner treatment, and status placement
- Signing, notarization, updater, and distribution channel
- Whether the root chooser creates `~/Documents/Jots` directly or asks the user to confirm it in a standard panel

Any choice that changes canonical file contents, one-active-jot behavior, autosave semantics, Finish & New, archive enumeration, or source fidelity requires an explicit specification revision.
