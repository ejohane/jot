# Anchored quick capture and native pop-out

Implemented on `codex/anchored-quick-capture`, based on `e539a75`.

Clicking the menu-bar icon opens the capture bubble; right-click retains the app menu. The Show Jot shortcut opens capture beneath the icon. New installations default to Command–Shift–J; existing customized shortcuts remain intact. The bubble has rounded corners, an attachment tip, a short opening animation, and respects Reduce Motion. Its upper-right Pop Out Note button (also Window → Pop Out Note) changes the same editor into a normal-level titled window with native close, minimize, resize and full-screen capabilities. Returning to capture reuses the same editor.

## Observed on November 5, 2026

The packaged release build was launched with `JOT_TEST_SESSION_PATH=/tmp/jot-quick-capture-proof/session.json`, using a disposable local notebook. Actual native screenshots are stored locally in the ignored `artifacts/quick-capture/` directory:

- `06-unified-bubble.png`: approved continuous bubble with matched surface color.
- `02-native-window.png`: same note in a native window with traffic-light controls.
- `04-native-fullscreen.png`: native full screen.
- `05-returned-to-capture.png`: return to capture with the note intact.

Observed: Command–Shift–J opens capture; clicking Pop Out Note changes the accessibility role to standard window; text can be added after detaching; the exact persisted Markdown retains that text; Command–Control–F enters native full screen, Escape restores the window, and Command–Shift–J returns to capture. The note also survived relaunch between verification builds.

140 native tests executed, 2 optional tests skipped, 0 failures; 196 editor tests and the release-tool check passed. Added checks cover anchor placement at both edges of an external display and retention of the same content view across the presentation transition. The production web bundle built successfully. Strict deep codesign verification passed. The workspace's iCloud metadata caused one packaging signing failure; the final bundle was copied outside iCloud to `/Users/erikjohansson/.codex/artifacts/jot-quick-capture/Jot.app`, cleared of extended attributes, and passed strict deep signature verification there. iCloud continued adding metadata to the workspace copy.

Native verification also exposed a crash in the existing app-reopen delegate's Swift executor check. Its Objective-C callback now queues the reopen action onto the main actor; subsequent reopening succeeded.

## Remaining visual acceptance

This is partial visual proof, not complete acceptance. The available native automation captures individual windows and did not reliably demonstrate title-bar movement or edge resizing. Those attempts did not yield a changed persisted frame. The full desktop relationship between menu-bar icon and bubble, clicking the actual menu-bar icon, the opening animation, and physical-key global invocation from another application remain unverified. Full-screen success does not substitute for dragging or edge resizing.

Remaining manual coverage includes those interactions on the actual desktop, auto-hidden menu bars, and multiple displays. The user approved the unified bubble appearance and requested release with these verification limits documented.
