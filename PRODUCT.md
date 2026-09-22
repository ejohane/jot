# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

The shipping product is a macOS desktop utility. Its primary designed surface is a React and CodeMirror 6 editor embedded in a thin native AppKit shell through `WKWebView`.

- Swift and AppKit own application lifecycle, the floating panel, menu-bar integration, global shortcuts, folder permissions, session restoration, and filesystem durability.
- React and TypeScript own the editor surface and future in-app product surfaces.
- CodeMirror 6 owns the live Markdown document and editor transactions.
- The macOS filesystem contains the canonical user data as ordinary UTF-8 Markdown files.
- No database, server, account, AI service, or network dependency is part of the first version.

Exact package versions, application name, bundle identifier, signing strategy, and distribution channel remain open until implementation begins.

## Users

The initial user is a person working on a Mac who needs to capture frequent thoughts without interrupting their current work. They may move repeatedly between applications while accumulating one thought and may create hundreds of notes per day.

## Product Purpose

The product provides an immediate, persistent writing surface for jotting Markdown. A global shortcut recalls one active jot, autosave makes the Markdown file durable from the first text edit, and Command-Return finishes that jot and presents a new blank surface.

Success means the user can capture a one-line thought or a substantial Markdown document without making filing decisions and without wondering whether their writing was saved.

## Positioning

The product combines a single persistent scratch surface with canonical, independently usable Markdown files. The application never requires an export operation to give the user ownership of their writing: the files on disk are always the source of truth.

## Operating Context

- The utility remains available from the macOS menu bar and a configurable global shortcut.
- The composer may remain visible while the user works in other applications.
- Clicking outside the composer preserves its exact state.
- Escape hides the composer without ending the active jot.
- The shortcut recalls the same jot with its editor state restored.
- Command-Return flushes the current file and starts a new blank jot in the same composer.
- Previous jots are accessed through Finder or the user's preferred Markdown editor in the first version.

## Capabilities and Constraints

- Exactly one jot can be active at a time.
- A blank composer does not create a file.
- The first committed text mutation creates a canonical Markdown file immediately.
- Every later text mutation is automatically persisted to that file.
- Markdown files are organized into date-sharded directories and contain exactly the user's text, with no injected title, frontmatter, or application metadata.
- The editor accepts Markdown syntax and presents live Markdown styling while leaving the source characters editable.
- Presentation state, indexes, caches, and future metadata are derived and must never become necessary to recover the notes.
- The first version has no library, search, tags, highlights, attachments, sync, collaboration, mobile client, AI, or deletion interface.
- Future tags, highlights, and library features must not require migrating canonical Markdown into a proprietary document model.

## Product Principles

1. Writing is durable from the first text edit.
2. Markdown files are canonical; presentation is disposable.
3. The composer preserves concentration by offering one active jot and no filing decisions.
4. No implicit action discards or silently overwrites writing.
5. The capture path stays fast regardless of archive size.

## Accessibility & Inclusion

- Every workflow must be operable with the keyboard.
- VoiceOver must announce the editor, saving state, errors, and actionable controls without reading decorative syntax styling as duplicate content.
- The editor must support macOS text input methods, IME composition, dictation, selection, undo, and paste without corrupting Markdown.
- Saving and error states must not rely on color alone.
- Motion must respect Reduce Motion, and text must remain usable with increased contrast and enlarged type.

