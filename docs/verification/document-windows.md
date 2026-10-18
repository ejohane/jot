# Markdown files and multiple windows

Agreed behavior: Jot remains a menu-bar app. External Markdown documents and notebook
jots can have separate windows, with one window per file. Edits save to the original
location. Option-Space recalls the dedicated capture window. Command-Return finishes
and creates another jot only in capture. Safe outside changes reload; overlapping
edits retain both versions. Open windows and reading positions survive a restart.

## Implementation

- File → Open… (Command-O), the menu-bar Open File… item, and Finder Open With accept
  `.md`, `.markdown`, `.mdown`, `.mkd`, and `.mkdn` files containing UTF-8 text.
- Open Jot in Window… starts in the current notebook. Option-clicking a note in the
  notebook rail also opens it separately. Opening a file already in capture or another
  document window focuses that window. Symlink and normalized paths share a window.
- Each document owns its editor, undo history, writer, position, frame, and recovery
  state. External files are never imported into the notebook. Relative images and
  file links resolve beside the document.
- The file is saved only after its recovery journal is durable. Canonical writes
  compare the acknowledged bytes under file coordination. Existing file permissions
  are preserved. Read-only and missing files retain pending writing and report errors.
- Save My Version as a Copy writes a uniquely named sibling before reloading the
  outside version. Neither version is overwritten by resolving a conflict.
- Open-document state is separate from the notebook session, so changing notebooks
  cannot transfer or erase external-document state.
- Document windows support normal close/minimize/full-screen controls and the Window
  menu. Command-W closes and flushes a file; Escape dismisses editor panels.

## Reproduce

Run `swift test`, `npm --prefix Web test -- --run`, and
`JOT_TEST_SESSION_PATH=/absolute/disposable/session.json ./script/build_and_run.sh --verify`.
Choose a disposable notebook through the native folder chooser. Open two disposable
project files, edit them, inspect their actual bytes, quit normally, and launch the
same bundle with the same test-session path. The document journal sits beside that
session as `session.json.documents.json`.

The test-session override isolates both capture and external-window journals. It does
not redirect external file writes: use disposable files for verification.

## Automated evidence

- Native: 123 discovered, 122 executed, zero failures; the pre-existing opt-in 100,000
  note scale test is skipped. Eleven new document tests cover original-path exact
  bytes, independent files, session restoration, outside reload, conflicts and durable
  copies, conflict relaunch, missing-file protection, failed journals, canonical
  identity, read-only protection, permission preservation, and relative-image bounds.
- Editor: 189 tests passed, including new checks for document Command-Return/Command-N,
  Option-click opening a separate notebook window, and relative Markdown links.
- Production packaging: `./script/build_and_run.sh --verify` built, ad-hoc signed,
  and launched the final bundle; strict deep signature verification passed. SHA-256
  hashes identify the native binary, Info.plist, and recursively enumerated editor assets.
- Release signing/tamper test: one test passed with disposable signing keys.
- Shared-code regression: the iOS Simulator target built successfully with signing disabled.
- `git diff --check` and shell syntax checks passed. Hosted CI and universal Intel
  packaging were not run for this local implementation.

## Packaged-app evidence

Evidence is stored in `artifacts/document-windows/` in the implementation worktree.
Direct evidence: [outside conflict screenshot](../../artifacts/document-windows/conflict.png),
[notebook document screenshot](../../artifacts/document-windows/notebook-window.png),
[restored long document](../../artifacts/document-windows/beta-restored.png),
[exact restoration comparison](../../artifacts/document-windows/restoration-proof.json),
[conflict byte comparison](../../artifacts/document-windows/conflict-proof.txt).
Disposable data lives below its `fixture/` directory. Local logs are copied there
when verification is complete.

| Agreement | Evidence |
| --- | --- |
| Menu-bar app; no Dock icon | `LSUIElement=true`; the running final bundle reports accessory activation policy (`runtime.json`). |
| Native Open File | Alpha opened through Command-O and the native chooser. |
| Finder Open With | Finder → Open With → Other… selected this worktree’s exact `dist/Jot.app`; Alpha opened in Jot. Screenshot: `alpha-finder-open.png`. |
| Multiple independent files | Alpha and Beta were edited separately; original project paths contain their exact UTF-8 text and the capture file remained unchanged. |
| Notebook jot in a separate window | Open Jot in Window… opened the notebook file independently. Its edits saved in the notebook and capture stayed unchanged (`notebook-window.txt`, `notebook-window.png`). Rail Option-click has editor-test coverage; native automation did not establish that gesture. |
| Duplicate open focuses existing window | Finder opened already-open Alpha; document manifest contained one Alpha entry. The final package focused Alpha on a second native Open request; the Window menu listed each of the three files once (`duplicate-focus.txt`, `final-window-menu.txt`). |
| Command-Return only finishes capture | Alpha remained intact after Command-Return; both keyboard modes covered by editor tests. Packaged capture Command-Return cleared only capture, kept its original file intact, and left all three document windows open (`capture-finish-proof.json`). The native File menu disables Finish & New in a document (`document-file-menu.txt`). |
| External-change handling | Packaged Alpha automatically displayed a safe outside edit (`safe-reload.txt`, `safe-reload.png`). A deliberate pending-edit conflict left outside bytes untouched; the recovery button produced an exact sibling copy of local text (`conflict-proof.txt`, `conflict.png`). |
| Restore windows and positions | Normal quit/relaunch restored all three windows with exact text, selection, scroll offset, and frame equality (`restoration-proof.json`). Beta restored caret 5309 and scrollTop 4677; the moved notebook window restored frame {{590, 295}, {620, 540}}. Screenshot: `beta-restored.png`. |
| Quick-capture shortcut | Existing Carbon binding calls the dedicated capture handler. The Window menu invokes that same handler and recalled the untouched capture (`capture-independent.txt`). Synthetic Option-Space did not trigger Carbon reliably; physical-key confirmation remains pending. |

Closing Alpha through the final native Window menu removed only its journal entry,
kept its original bytes intact, and left Beta and the notebook document open
(`close-proof.json`). Menu focus tracking also keeps Finish & New disabled when
a document is active.

A test or successful process launch is not proof of a UI interaction. This report
keeps those evidence levels separate. No production release, update-feed change,
or replacement of `/Applications/Jot.app` is part of this implementation task.
