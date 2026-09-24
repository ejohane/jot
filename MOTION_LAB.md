# Jot Motion Lab

This is a developer-only interaction jig for note navigation. It is packaged as **Jot Motion Lab.app** with its own bundle identifier and sample state. The launcher does not install or launch the regular Jot bundle. The lab does not construct Jot's live coordinator, request access to a Jots folder, or read `~/Library/Application Support/Jot/session.json`.

Run it from this checkout:

```sh
./script/run_motion_lab.sh
```

The script builds the same Swift executable and WKWebView editor assets as Jot, then copies them into `dist/Jot Motion Lab.app` with the `com.erikjohansson.JotMotionLab` identifier. It launches that bundle directly. Close the lab window to quit. Lab state is kept in `~/Library/Application Support/Jot Motion Lab/sample-notes.json`; **Restore sample notes** replaces that file's data with fresh samples. The lab never touches the user's Markdown folder.

## Feel the motion

- Scroll the center editor normally. On reaching the top, keep pushing to preview the older note. At the bottom, keep pushing to preview the newer note. Release past the commit threshold to open it; release below the threshold to spring back. A single wheel step cannot navigate. Short notes require extra effort. Nothing opens past either end of history.
- The narrow right timeline has one stop per note and scrolls independently. Hover or drag across stops to preview a first meaningful line, excerpt, and capture time. Click a stop or release a drag to open that note. Browsing alone leaves the editor untouched.
- Edit any sample. Content saves locally as you type. The selected note's cursor and scroll position are kept when switching away and returning. The lab blocks selection if its local state cannot be saved.
- Tune **Resistance**, **Preview reveal**, **Commit threshold**, **Spring / snap**, **Stop spacing**, and **Preview delay** while the app runs. **Gentle**, **Balanced**, and **Decisive** are starting points. **Reset controls** returns to Balanced. **Export values** copies the current JSON settings to the clipboard.

The lab intentionally has no library, search, tag-management, account, or publishing flow. The sample timeline has 64 notes, including short and long documents, so its rail can be tested under density.
