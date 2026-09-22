# Jot v0.1 Verification Matrix

Status values: `pending`, `passing`, `failing`, `blocked`. A check is marked
`passing` only when the current tree has produced the complete required evidence.
Partial evidence is recorded without weakening the requirement.

## Automated behavior

| ID | Status | Current evidence |
| --- | --- | --- |
| CAP-001 | passing | Unit tests prove blank edits and blank Finish & New allocate no file. The installed release was opened blank, hidden, reopened, quit, and relaunched while the archive count remained exactly 11. |
| CAP-002 | passing | Unit test proves exact UTF-8 first-write allocation and local-date sharding; installed release created exactly one file on first text and byte inspection matched. The final clean-checkout 1,000-sample local allocation p95 was 0.373 ms. |
| CAP-003 | passing | Installed release performed insert, mid-document insert, deletion, multiline Return, plain-text paste, selection replacement, undo, and redo. The canonical file was independently byte-inspected after every acknowledged state and exactly matched CodeMirror; coalescing and stale-revision tests also pass. |
| CAP-004 | passing | Timed test generates continuous edits for ten seconds, proves snapshots remain under a 1.15 s maximum gap, and verifies the final canonical bytes are exact. |
| CAP-005 | pending | A release session moved among Finder, Google Chrome, Xcode, Simulator, and Linear, returning to Jot after each and editing without changing the active path, 250,014-byte text, selection 250,014, scroll position 87,822, or panel frame. Physical shortcut return is the sole missing portion. |
| CAP-006 | pending | Installed Escape now flushes and hides while the process remains alive. The Carbon shortcut does not respond to the automation-generated Option-Space event, so shortcut recall still needs physical-key confirmation. |
| CAP-007 | passing | Unit test proves the newest revision is flushed before rollover. Installed Command-Return preserved exact old bytes, showed a focused blank composer, created no blank file, and allocated one file only after typing. |
| CAP-008 | passing | Installed release quit and relaunched with the same active path and exact acknowledged text; session round-trip and stale-session-generation tests pass. |
| CAP-009 | passing | Unit test creates a jot, writes an empty revision, and verifies the original canonical file remains at zero bytes. |
| CAP-010 | passing | A deliberately blocked first write accepts a newer revision while the old write is in flight, then proves writes complete serially, revision 2 is acknowledged, and only the newest bytes remain canonical. Stale-revision coverage also passes. |
| CAP-011 | passing | Unit test generated 10,000 allocations at the same mocked timestamp with unique paths and no overwrite. |
| CAP-012 | passing | Unit and installed-app checks prove an active jot stays in its original root and only the next jot uses the newly selected root. |

## Failure and recovery

| ID | Status | Current evidence |
| --- | --- | --- |
| ERR-001 | passing | Unit tests retain and later flush the recovery buffer. Installed release rehydrated exact text with an unavailable bookmark, exposed Restore Folder Access and Save Copy, blocked clearing, and resumed saving after folder selection. |
| ERR-002 | passing | File-system doubles inject `fileWriteOutOfSpace` and `EIO`; no success acknowledgement occurs and Finish & New remains blocked. |
| ERR-003 | passing | Native tests cover conflict, Save as Copy, and explicit reload. Installed release stopped before overwrite and Save My Version as a Copy preserved both exact versions. |
| ERR-004 | passing | Unit test deletes the active file externally, proves it is not silently recreated, blocks rollover, and saves the in-memory version to a distinct path. |
| ERR-005 | passing | Terminating the app-owned WebContent process produced a new process that reloaded `jot://local`, restored the same text, and created no duplicate jot. |
| ERR-006 | passing | After a visible Saved acknowledgement, normal application termination and relaunch restored that exact revision and path. |
| ERR-007 | passing | Deterministic temporary-file tests recover a missing canonical file and refuse to overwrite an existing canonical file with stale temporary data. |

## Markdown and editor

| ID | Status | Current evidence |
| --- | --- | --- |
| MD-001 | passing | Vitest round-trips CommonMark/GFM, unsupported table and HTML syntax, Unicode, emoji, and incomplete syntax. Installed Return and Markdown byte inspection showed exact source with no continuation or normalization. |
| MD-002 | passing | Installed visual fixtures covered headings, strong, emphasis, strikethrough, inline/fenced code, links, quotes, bulleted and ordered lists, task items, and rules. Vitest confirms decorations preserve source and offsets. |
| MD-003 | passing | Vitest proves markers are dim away from the caret, become active on the selected construct, and preserve exact offsets/source. Installed visual review confirmed the two marker states. |
| MD-004 | passing | Vitest and installed release safely edited incomplete link, fence, emphasis, raw HTML, list, and strikethrough source with no crash, correction, cursor jump, or byte loss. |
| MD-005 | passing | Deterministic editor tests verify rich clipboard paste is exact plain text, copy returns canonical Markdown, and pasted files are rejected; installed rich-text paste stored plain canonical text and created no attachment. |
| MD-006 | pending | A connected CodeMirror composition test proves transient composition text is not emitted and only committed `かなé` is sent. Installed Option-E then E persisted exact UTF-8 `é`. A representative installed non-Latin macOS IME remains. |
| MD-007 | passing | Vitest proves presentation and selection updates do not add undo steps and that undo restores exact source; installed undo/redo also preserved exact bytes. |

## Accessibility

| ID | Status | Current evidence |
| --- | --- | --- |
| A11Y-001 | pending | Writing, rollover, hide, folder chooser, and menu commands are keyboard reachable. In an installed conflict, ordinary Tab under the current macOS keyboard-navigation configuration cycled between the editor and web document rather than reaching recovery buttons; the Option-Tab follow-up was interrupted by the Mac lock screen. Physical global-shortcut and complete keyboard-only recovery confirmation remain. |
| A11Y-002 | pending | Accessibility exposes one named editable Markdown document and an `aria-live` textual status, but VoiceOver must still verify single source announcement and named error actions. |
| A11Y-003 | pending | Dark appearance is visually usable; light mode, Increase Contrast, Reduce Transparency, Reduce Motion, and enlarged text remain. |
| A11Y-004 | pending | Focus stayed in the text entry through autosaves, presentation updates, rollover, and appearance of an external-conflict error. Post-recovery focus remains unverified because the keyboard recovery path was interrupted. |

## Performance and scale

| ID | Status | Current evidence |
| --- | --- | --- |
| PERF-001 | pending | A 100-invocation physical global-shortcut p95 run on the oldest supported Mac remains. |
| PERF-002 | pending | Final clean-checkout benchmark: 1,000 allocations p95 0.373 ms and 1,000 replacements p95 0.324 ms, both below 250 ms on the current Mac. The contract requires the oldest-supported-Mac measurement. |
| PERF-003 | pending | The installed release created, saved, quit, and restored a 250,014-character jot exactly. A headed Chromium production-bundle benchmark over 100 insert samples measured a two-animation-frame proxy at p50 0.4 ms, p95 0.7 ms, max 4 ms; an installed WKWebView input-to-paint p95 on the oldest supported Mac remains. |
| PERF-004 | pending | The final opt-in test generated 100,000 date-sharded jots; baseline p95 0.400 ms, scaled p95 0.351 ms, ratio 0.879, within 10% on the current Mac. Oldest-supported-Mac shortcut and save repetitions remain. |
| PERF-005 | passing | Instrumented capture-path test records one current-file write and no archive-recovery/enumeration call; the production filesystem exposes no archive-listing operation. |

## Privacy and packaging

| ID | Status | Current evidence |
| --- | --- | --- |
| PRIV-001 | passing | Static scan found no runtime fetch/WebSocket/remote URL code. A 45-second watch sampled Jot and its GPU, WebContent, and Networking processes 45 times and observed zero sockets while exercising edit, autosave, Finish & New, hide, recall, and another finish. |
| PRIV-002 | passing | With `/Applications/Jot.app` temporarily absent, `/usr/bin/file` identified the newest jot as ordinary text and `/bin/cat` read its exact contents; the signed app was then restored. |
| PKG-001 | passing | A final source-only temporary copy with no generated source resources or dependencies passed fresh `npm ci`, all 9 editor tests, all 34 non-scale native tests, the React production build, release packaging, launch, and strict signature checks. |
| PKG-002 | passing | `/Applications/Jot.app` launches the bundled `jot://local/index.html` editor with no development server. |
| PKG-003 | passing | `codesign --verify --deep --strict` passes; the bundle contains only local minified HTML/CSS/JS editor assets, no source maps, and release code disables WebKit developer extras. |

## Manual acceptance

| Requirement | Status | Current evidence |
| --- | --- | --- |
| Sustained use across five Mac applications | passing | The installed release was used across Finder, Google Chrome, Xcode, Simulator, and Linear; each return retained exact text, selection, scroll, frame, and active path. |
| One-line, multiline, pasted, and long-form notes | passing | One-line, multiline, rich-text paste, and a 250,014-character jot passed with independent byte inspection; the long note remained exactly 250,014 bytes with SHA-256 `a471623e6069c89fee77769ef6ba73c1daa7fa6e6098d7ea9066b3a1a2c515f1` after edits and relaunch. |
| Visual Markdown, selection, marker, status, dark-mode, error, and rollover review | pending | All supported constructs, status, dark mode, conflict/recovery, rollover, and marker states passed; alternate system appearances remain. |
| Finder sharding and independent-editor comparison | passing | Installed files use `YYYY/MM/DD` sharding and independent command-line readers matched exact canonical bytes while the app was absent. |
| Multiple displays, Spaces, full screen, sleep/wake, and relaunch | pending | Relaunch, off-screen-frame clamping, and recall/edit/finish over a full-screen Chrome Space pass; the resulting 23-byte file matched exactly and Chrome was restored afterward. A release-only expansion regression was found, fixed, covered by a geometry test, and visually rechecked. Multiple displays and sleep/wake remain. |
| No observed loss, duplication, normalization, or silent overwrite | pending | No issue was observed in completed tests, but this consolidated claim waits for the remaining acceptance matrix. |

## Evidence log

### 2026-09-22 — Final in-scope release checkpoint

- Automated native: final `swift test` discovered 35 tests, executed 34, skipped only the separately invoked 100,000-jot scale case, and passed every executed test. Coverage includes delayed in-flight revision ordering, bridge decoding, durable Save as Copy, termination gating, geometry clamping, allocation, exact bytes, rollover, coalescing, failures, conflicts, recovery, restoration, and unique paths.
- Automated editor: `npm --prefix Web test -- --run` passed 9 tests, including connected CodeMirror composition/clipboard behavior and bridge retry in addition to exact Markdown, marker, malformed-input, and history coverage.
- React production build: `npm --prefix Web run build` passed and produced local minified assets; Vite reports only a non-failing 707.02 kB chunk-size warning.
- Native release and install: the final tree built, ad-hoc signed, installed, and launched `/Applications/Jot.app`; strict deep signature verification passes and installed binary/editor entrypoint bytes match the locally packaged release.
- Installed interaction: exact file checks passed for ordinary edits, rollover, hide/recall, quit/relaunch, rich paste, malformed Markdown, a macOS dead key, the 250,014-character fixture, and writing/finishing over a full-screen Chrome Space. Focus hopping covered five named applications. The long note retained its exact length and hash after edits and relaunch.
- Accessibility conflict state: an externally modified canonical file remained exactly `External conflict version`, while Application Support retained `My conflict version!` at revision 20 and the editor kept focus when the conflict appeared. Ordinary Tab did not reach the recovery buttons in the current keyboard-navigation configuration; the alternate key-path check stopped at the macOS lock screen.
- Release geometry: verification exposed an expansion path that could move most of a restored long-note panel above the display. The resize now reclamps to the active visible frame; a deterministic test and installed visual recheck pass.
- Failure recovery: permission/bookmark loss, root restoration, disk-full/EIO, external edits/deletion, durable copy failure, stale temporary data, termination-state failure, and WebContent termination have passing evidence as itemized above.
- Performance: final current-Mac local p95 is 0.373 ms for 1,000 allocations and 0.324 ms for 1,000 replacements. The opt-in 100,000-jot test produced a 0.879 scaled/baseline ratio. A headed production-bundle 250k editor proxy measured p95 0.7 ms, while the contract-specific hardware measurements remain pending.
- Privacy: a 45-second, 45-sample complete-flow observation across the app and all three app-owned WebKit processes saw zero sockets.
- Reproducibility: `/tmp/jot-final-geometry.Y1vP7Y`, copied without Git state, build products, generated web assets, test data, or dependencies, passed fresh dependency installation, all editor/native tests, production builds, package launch, asset checks, and strict signature verification.

## Remaining completion blockers

The implementation is not yet declared complete. The outstanding contract requires
physical/hardware or assistive-technology evidence not produced in this run:

- physical Option-Space measurements and recall validation (synthetic accessibility keystrokes do not trigger the Carbon hot key);
- VoiceOver, a representative installed non-Latin IME, dictation, accessibility-setting, and complete keyboard-only acceptance;
- 250,000-character input-to-paint instrumentation and oldest-supported-Mac performance;
- multiple-display and sleep/wake hardware behavior;
- the remaining accessibility interaction corpus.
