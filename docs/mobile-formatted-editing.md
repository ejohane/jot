# iPhone formatted Markdown editing

## Contract

Markdown remains the canonical editor document and saved `.md` file. On iPhone,
completed bold and italic syntax stays hidden while editing. Users can type
Markdown or use the native formatting bar. Mac editing retains its current
source-revealing behavior.

This first release covers bold and italic. Headings, lists, links, code, and other
constructs retain their existing editing behavior. A dedicated source view is
outside this release; Undo immediately after typed conversion reveals that
construct's literal source.

## Acceptance criteria

- Completing `**hello**`, `__hello__`, `*hello*`, or `_hello_` renders emphasis.
  Incomplete outer syntax remains literal; escaped characters are not converted.
- Bold/Italic apply to selections, remove formatting from fully formatted
  selections, and apply throughout mixed selections. Reversed selections survive.
- With a caret, the toolbar changes upcoming text without adding empty wrappers.
  Native controls reflect active formatting and expose their selected state to
  accessibility. Explicit caret movement resets the pending style.
- Editing inside a span keeps delimiters hidden. Typing at its end continues its
  style; switching the button off inserts subsequent text outside that style.
  Enter resets upcoming inline formatting.
- Bold and italic coexist. Removing one preserves the other, including overlapping
  ranges and adjacent characters with different styles.
- Cursor movement follows visible graphemes, with no stops inside hidden syntax.
  Touch selection must follow visible content and retain the selection when the
  native formatting bar is tapped.
- Backspace removes visible content, including Unicode characters, and removes
  empty wrappers. It never deletes the first character when targeting opening
  syntax at the start of a note.
- Selection formatting undoes in one step. Typed conversion has its own reversible
  presentation step: first Undo reveals the original source; Redo renders it.
- Composition stays under WebKit's control until committed. Pending formatting
  applies after commit, joins composition Undo, and saves only the final source.
  Predictive text, autocorrect, and real dictation require device acceptance.
- Mobile copy supplies readable emphasis text and safe HTML rich text; cut edits
  canonical source and supports Undo. Paste continues to accept plain Markdown.
  The existing Copy Note action continues to copy the canonical file source.
- Opening or presenting a note never rewrites its source. Formatting edits only
  rebuild their affected inline region; structural syntax, destinations, and code
  remain intact. Source offsets continue through autosave and session recovery.
- Pending styles and conversion state reset when loading a different note.

## Implementation and incremental verification

1. Added a mobile-only editor extension and transient typing styles; verified
   toolbar input, source preservation, partial selections, and cleanup.
2. Added reversible typed conversion; character-by-character tests caught parser
   fallback to italic before bold's final star. Incomplete outer syntax now waits.
3. Tested overlapping styles and every one of the 64 three-character style
   combinations. Fixed delimiter nesting and coalesced adjacent affected spans.
4. Added composition, clipboard, native active-state messages, and note-switch
   checks. A connected composition test caught duplicate save notifications;
   the bridge now sends only the final formatted source.
5. Browser arrow-key checks caught invisible stops between nested delimiters.
   Mobile cursor movement now uses visible graphemes; hidden atomic ranges merge.
6. Added structural-Markdown protection and a 50,000-character formatted-span
   edit check. Serialization computes style lifetimes in linear time.
7. Verified native Simulator selection and clipboard, and Mac source editing and
   relaunch. Neighbor previews now enable mobile editing at document start,
   matching the main editor without depending on script-load timing.
8. Final review caught an IME commit queued across note loading. The commit now
   requires its original composition snapshot; a regression proves the newly
   loaded note stays byte-for-byte unchanged.

## Definition of done and evidence

A passing build is not evidence of touch interaction or live synchronization.
After trying the implementation, Erik confirmed it works as expected and
authorized shipment on October 9, 2026. This records user acceptance separately
from the automated and agent-observed evidence below.

| Gate | Status | Evidence |
| --- | --- | --- |
| Focused acceptance and regression tests | Passing | Web suite: 161 tests. Includes 36 mobile extension tests plus connected bridge, clipboard, composition, and dictation-result tests. |
| Core persistence/recovery/sync regression suite | Passing | `swift test`: 105 executed, 1 skipped, zero failures. |
| Web production build | Passing | TypeScript and Vite build succeed. |
| Release-script regression and shell syntax | Passing | `python3 script/test_release.py`; `bash -n` on build/package scripts. |
| Browser input/Undo/cursor/deletion | Passing | Headed browser typed Markdown, conversion Undo/Redo, style-off typing, mixed selection formatting/Undo, combined-style cursor movement and Backspace. Evidence in ignored `output/playwright/mobile-inline-browser.log` and `.png`. |
| iOS Simulator build/install/launch | Passing | Final Debug Simulator build installed and launched on iPhone 17, iOS 26.2, including the preview initialization fix. |
| Simulator visible typing and actual file | Passing | On-screen keyboard entered `mi` with Bold selected. UI shows bold `mi` without delimiters; file and session contain `**mi**`, selection offset 4, acknowledged revision 2. |
| Signed physical build/install/launch | Passing | Final `script/build_ios.sh --device` built, installed and launched on Erik's iPhone 16 Pro Max. Strict signature verification passes. |
| macOS package/signature | Passing | `script/package_app.sh` succeeded for the final Web code, including strict signature verification. |
| Mac relaunch and recovery | Passing on final artifact | Isolated native Mac app saved exact `***mobile verification***` bytes to the file and recovery journal, then restored source after quit/relaunch. Automated interrupted-write and journal recovery tests pass. |
| Simulator selection and clipboard | Passing before final preview/IME guards | Double-tap selected visible `mi`; native Italic removed only italic and retained selection. Canonical file and acknowledged recovery journal both contained `**mi**`. Native Copy supplied plain `mi` and HTML containing `<strong>mi</strong>`. |
| Final iPhone relaunch/recovery | User acceptance; not independently observed | Simulator persistence observed across prior launches; final physical relaunch and interrupted-session acceptance remain. |
| Physical touch placement/selection/deletion | User acceptance | Mac unlocked on resumption. iPhone Mirroring still displays its separate Touch ID/Mac-login lock; that window was brought forward and human unlock requested. |
| Physical keyboard suggestions/autocorrect/composed input | User acceptance; individual paths not reported | Requires unlocked physical interaction. Synthetic composition tests pass. |
| Real microphone dictation | User acceptance; spoken path not independently observed | Dictation preview/result integration and Undo pass; actual spoken-input acceptance remains. |
| Live iPhone → Mac → iPhone synchronization | Not independently observed | Phone is configured for iCloud, confirmed from session metadata without exposing note text. A real note round trip remains. |
| Mac UI regression | Passing on final artifact | Native Mac editor reveals source as before. Combined formatting saved exact Markdown and restored on relaunch in an isolated test notebook. |
| Paging and keyboard regression | User acceptance; gesture automation inconclusive | Final Simulator restored visible bold `mi` without syntax. Gesture automation did not reach the native paging recognizer (verified using resolved LLDB breakpoints), so paging and keyboard retention cannot be claimed from these attempts. Physical Mirroring remains locked. |

No user notes were used as test content. Device journal inspection was restricted
to storage mode, revision, active-note presence, and text length. No PR or release
is implied by local build/install evidence.

Mac/Simulator interoperability used a manually transferred test file, not live
iCloud synchronization. The live sync gate remains open. Neighbor-preview
initialization compiles in both final iOS builds; its paging behavior still needs
observed UI verification.

Final Web build, all 161 Web tests, browser acceptance, Mac packaging, and both
iOS builds were repeated after the IME guard. Final Simulator and physical apps
were installed and launched. Native interaction evidence above predates only
the documented preview initialization and IME guard changes.

On resumption, the final Mac artifact was verified again with isolated test
content. No implementation changes were made. Simulator test-note opening
restored the saved bold presentation; attempted automated swipes were
inconclusive and did not hit the paging delegate breakpoints. The debugger was
detached after diagnosis. The Mac is accessible, but iPhone Mirroring still
requires its separate Touch ID unlock.

## Shipment acceptance

Erik: "i verified it works as expected. pull in the latest changes from remote
main and then ship it" (October 9, 2026). This authorizes shipping the implemented
scope. It does not establish separate agent-observed evidence for spoken
dictation or a live iCloud round trip. Remote main was fetched before publication;
its commit matched the implementation base (`9016ac6`).
