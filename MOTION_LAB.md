# Jot Motion Lab

This is a developer mode of the **Jot app**, running the real `ComposerPanelController`, `EditorBridge`, `WKWebView`, and `Editor.tsx` composer. It adds the timeline, overscroll, and tuning controls to that composer for hands-on trackpad testing. The normal Jot launch stays unchanged. This PR is still an experiment, not a production release.

Run from this checkout:

```sh
./script/run_motion_lab.sh
```

Or use the **Motion Lab** action in Codex. The script builds `dist/Jot.app` with the developer mode enabled and launches that bundle with `--motion-lab`. It does **not** install over `/Applications/Jot.app` or stop a running installed Jot. Developer mode opens 64 disposable sample notes from `~/Library/Application Support/Jot Motion Lab/sample-notes.json`. It does not construct Jot's live coordinator, request access to the user's Jots folder, or read `~/Library/Application Support/Jot/session.json`.

## Feel the motion in Jot

- Scroll normally inside the center editor. At the top, push further to reveal the older note; at the bottom, push further to reveal the newer note. Releasing beyond the commit threshold opens the neighbor. Below threshold it springs back. Short notes need extra effort, and history ends never navigate.
- The slim right timeline has one stop per note and scrolls independently. Hover or drag to preview a meaningful first line, excerpt, and capture time. Click or release on a stop to select it. Browsing leaves the editor alone.
- Edit a sample note. The developer store saves it atomically and remembers cursor and scroll position. If saving fails, selection is blocked and the error appears in the editor.
- Tune **Resistance**, **Preview reveal**, **Commit threshold**, **Spring / snap**, **Stop spacing**, and **Preview delay** live. **Gentle**, **Balanced**, and **Decisive** are starting points. **Reset controls** returns to Balanced; **Export values** copies the current JSON to the clipboard. **Restore sample notes** resets the disposable data.

The normal Jot bundle build omits the developer coordinator and sample store, and its web build drops the motion lab interface. The normal composer is unchanged. No library, search, or tag-management UI is added.
