# Keyboard shortcuts

Open Jot → Settings → Shortcuts. Recording controls cover capture, application,
navigation, formatting, dictation, and editing commands. General retains notebook
and launch settings; About retains version and updater controls.

The current global preset migrates into the new bindings. Changes persist in the
session and survive notebook switches. Native menus and editor action hints use
the same bindings. A rejected duplicate or unavailable global registration leaves
the current bindings intact. Recording temporarily suspends the global shortcut;
cancelling, closing Settings, switching tabs, or changing windows restores it.

The host routes shortcuts for both quick capture and independent Markdown windows.
Finish & New and New Note remain exclusive to quick capture. Escape continues to
exit full screen and dismiss transient editor UI even if Hide Jot is remapped;
otherwise it only hides when assigned to Hide Jot. Cursor movement, plain text
editing, and operating-system dialog keys retain their standard behavior.

## Validation

- `swift test`: migration, session round-trip, duplicates, atomic reset, failed
  global replacement, modifier matching, unique defaults, notebook preservation,
  and existing native regression tests.
- `npm --prefix Web test`: native command routing, disabled former aliases,
  history preservation, Escape dismissal, and existing editor regressions.
- `python3 script/test_release.py`: Sparkle signing and tamper rejection.
- `JOT_TEST_SESSION_PATH=/tmp/jot-shortcuts-verification/session.json
  ./script/build_and_run.sh --verify`: packaged app with disposable preferences.

For UI checks, remap Finish & New and Undo, confirm their former combinations do
not fire, exercise the replacements, and relaunch. Repeat editing and close in an
independent Markdown window, confirm the original file autosaves in place, and
confirm Finish & New leaves that window intact. Verify duplicate feedback and
Restore Defaults from the Shortcuts tab. Physical global-hotkey activation requires
hardware observation; registration tests and synthetic input do not establish it.
