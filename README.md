# Jot

Jot is a local-first macOS Markdown capture utility. It keeps one active jot,
autosaves the exact source to ordinary date-sharded Markdown files, and starts a
new blank jot with Command-Return.

## Install and update

Run this one line in Terminal (no developer tools needed):

```sh
curl -fsSLo "$HOME/Downloads/Jot-install.sh" https://raw.githubusercontent.com/ejohane/jot/main/script/install.sh && sh "$HOME/Downloads/Jot-install.sh"
```

This saves the installer script in Downloads, then runs it. The installer
downloads the latest release, verifies its checksum, Apple signing identity,
and notarization, installs Jot in `~/Applications`, and opens it. Quit Jot
first if it is already running. Set `JOT_INSTALL_DIR` to a writable absolute
path to choose a different location.

Or download `Jot.zip` from the [latest release](https://github.com/ejohane/jot/releases/latest),
unzip it, and move **Jot.app** into `~/Applications` before opening it. The universal
app supports Apple Silicon and Intel Macs running macOS 14 or newer.

The first launch asks for a local Jots folder. The suggested location is
`~/Documents/Jots`. Writing requires no server, account, database, or network connection.
Published builds use GitHub only to check for and download app updates.

Published apps are Developer ID signed and notarized. Jot checks for updates
hourly and offers a download and installation when you choose. **Check for
Updates…** is available in both the Jot application menu and its menu-bar menu.
The normal save/recovery gate runs before quitting for an update. Notes remain
in your chosen folder, outside the app bundle.

**About Jot** shows the version and build. Update checks contact GitHub; note
contents are never sent with them.

## Build from source

### Requirements

- macOS 14 or newer
- Swift 6.2 toolchain
- Node.js and npm
- CMake (for building the bundled Whisper transcription helper)

### Build, test, and run

```sh
npm --prefix Web ci
npm --prefix Web test
swift test
./script/build_and_run.sh --verify
```

The final command builds the locked React production bundle, embeds it into the
Swift release product, creates and ad-hoc signs `dist/Jot.app`, launches that
bundle without a development server, and verifies that its process starts.

Install the same release bundle into `/Applications` and launch it with:

```sh
./script/build_and_run.sh --install
```

Local development builds keep updates disabled so a published build cannot
replace a working development build.

## Controls

- Option-Space by default: show and focus Jot
- Escape: flush pending changes and hide
- Command-Return: finish the active jot and show a new blank composer
- Command-Q: flush session state and quit
- Enter in a Markdown list: continue the list; Enter on an empty item exits it
- Shift-Enter: insert a plain newline without a new list marker
- Command-Shift-D or the microphone button: start voice dictation
- Check button: finish recording and keep the transcript
- X button: cancel recording and discard the provisional transcript

Unordered list markers (`-`, `*`, or `+` followed by a space) display as round
bullets while the saved and copied text remains ordinary Markdown.

The menu-bar item can change the shortcut or Jots folder, reveal the active jot,
open the Jots folder, and control launch at login.
The composer opens centered on the active display. After you move it, Jot
remembers that position when you close and reopen it or relaunch the app.

Dictation transcribes English speech on this Mac using Whisper `small.en`.
The first use downloads a roughly 465 MB model from the
[Jot voice model release](https://github.com/ejohane/jot-voice-models/releases/tag/v1),
checks its pinned SHA-256 digest, and caches it in Jot's Application Support
folder. Later dictation works offline. The microphone is captured locally and
partial words appear at the insertion point while you speak, with a live
microphone waveform beside the controls. Partial guesses do not change the
saved Markdown or undo history; pressing the check button commits the final
transcript as one edit, while X discards it. Pauses finalize phrases within the preview.
Command-Shift-D also finishes an active recording. If the audio device changes
during capture, Jot restarts its audio engine.
Jot does not save a recording or upload speech or transcripts.

## Releases

Every push to `main` runs `.github/workflows/release.yml`: tests, universal build,
Developer ID signing, Apple notarization, signature validation, and publication.
The release version is `0.1.<workflow run number>`; the build number is that same
run number. No manual version edit or tag is necessary. A failed run leaves the
previous release available. Workflow dispatch can retry a release from `main`.
A run from an older commit never replaces the current update feed.
The signed app contains an Apple Silicon and Intel Whisper helper, built from a
pinned `whisper.cpp` revision. Model weights live in a separate GitHub Release,
so publishing or updating the model cannot change Jot's Sparkle app update feed.

GitHub Releases hosts `Jot.zip`, its SHA-256 checksum, and `appcast.xml` for
Sparkle. This requires a public repository. Signing credentials are Actions
secrets and never belong in source control. The Apple secret names retain the Lattice naming convention, but Jot uses its
own Developer ID certificate and a dedicated Developer-role notarization key:

- `LATTICE_MACOS_CODESIGN_CERTIFICATE_BASE64`: exported Developer ID Application `.p12`, base64 encoded.
- `LATTICE_MACOS_CODESIGN_CERTIFICATE_PASSWORD`: password for that export.
- `LATTICE_CODESIGN_IDENTITY`: full `Developer ID Application: …` identity.
- `LATTICE_NOTARY_KEY_ID`, `LATTICE_NOTARY_ISSUER_ID`, `LATTICE_NOTARY_PRIVATE_KEY`: Apple notarization API credentials.
- `JOT_SPARKLE_PRIVATE_KEY`: Jot's own Sparkle Ed25519 signing seed, base64 encoded.

`Config/sparkle-public-key.txt` is the matching public key embedded in the app.
Keep the private key stable across releases. A backup was created in the macOS
login Keychain under **Jot Sparkle release signing**, account `ejohane/jot`.

The Apple credentials also have local recovery backups:

- The encrypted certificate export is `~/Library/Application Support/Jot Release Setup/Jot-Developer-ID.p12`.
- Its password and the notarization API key are in the login Keychain under **Jot release credentials**.
- The notarization key and issuer IDs are in `notarization-metadata.txt` beside the encrypted export.

These files are outside the repository. The unencrypted RSA key and downloaded
API-key file are removed after configuration. Keep these backups when migrating
to another development Mac; GitHub Actions secrets cannot be downloaded later.

To build a universal local app without publishing or launching:

```sh
JOT_UNIVERSAL=1 ./script/package_app.sh
```

CI verifies builds and process launch. Before accepting the first release,
exercise a real upgrade from an earlier installed release and confirm the
active note is restored after relaunch. Installation on a managed work Mac
still follows that machine's application policy.

# Inline tags

Write a tag directly in a jot as `#project`. It remains ordinary Markdown text on disk. Jot subtly colors the literal characters in the editor and suggests existing tags from the selected Jots folder as you type. Press Tab to accept a suggestion; Enter keeps its normal Markdown newline behavior. No separate tag metadata or index file is saved.

The v1 grammar is intentionally small: `#` followed by an ASCII letter, then zero or more ASCII letters, digits, `_`, or `-`. The `#` must begin a line or follow whitespace or an opening `(`, `[`, `{`, single quote, or double quote. Tags stop before punctuation such as `,` and `.`. Jot ignores headings with a space after `#`, escaped hashes, inline code spans, fenced code blocks, and Markdown link destinations. The boundary rule also excludes URL fragments. Matching is case-insensitive; completion uses a deterministic existing spelling when the folder contains case variants. The editor and native index use the same grammar and are tested with equivalent Markdown fixtures.

The native index holds tag sets per Markdown file and a distinct vocabulary in memory. A scan after each save and a periodic background reconciliation pick up external additions, edits, renames, removals, and missed file events. Capture and typing never wait for that scan; the editor filters the latest vocabulary locally.

For disposable UI verification, launch the packaged app with `JOT_TEST_SESSION_PATH` set to an absolute path outside the normal Application Support directory, then choose a disposable Jots folder. This keeps the test session separate from the installed app's session.

## Developer motion lab

Jot's developer-mode note navigation jig is documented in [MOTION_LAB.md](MOTION_LAB.md). Run `./script/run_motion_lab.sh` from a checkout; it launches the actual Jot composer with disposable sample notes without installing over Jot.
