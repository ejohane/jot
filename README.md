# Jot

Jot is a local-first macOS Markdown capture utility. It keeps one active jot,
autosaves the exact source to ordinary date-sharded Markdown files, and starts a
new blank jot with Command-Return.

## Requirements

- macOS 14 or newer
- Swift 6.2 toolchain
- Node.js and npm

## Build, test, and run

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

The first launch asks for a local Jots folder. The suggested location is
`~/Documents/Jots`. No server, account, database, telemetry, or network access
is used at runtime.

## Controls

- Option-Space by default: show and focus Jot
- Escape: flush pending changes and hide
- Command-Return: finish the active jot and show a new blank composer
- Command-Q: flush session state and quit

The menu-bar item can change the shortcut or Jots folder, reveal the active jot,
open the Jots folder, and control launch at login.
