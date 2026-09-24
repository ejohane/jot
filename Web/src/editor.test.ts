import { history, redo, undo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { GFM } from "@lezer/markdown";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { editorTheme } from "./editorTheme";
import { Editor, insertLiteralNewline } from "./Editor";
import type { EditorToNative } from "./bridge";
import { markdownPresentation } from "./presentation";
import { findInlineTags } from "./tags";
import { completionStatus, currentCompletions } from "@codemirror/autocomplete";
import { indentBulletItem } from "./listIndent";

const views: EditorView[] = [];
const roots: Root[] = [];
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// JSDOM has no layout; CodeMirror's asynchronous measurements need these APIs.
Object.defineProperties(Range.prototype, {
  getClientRects: { configurable: true, value: () => [] },
  getBoundingClientRect: { configurable: true, value: () => new DOMRect() },
});

function makeView(doc: string) {
  const parent = document.createElement("div");
  document.body.append(parent);
  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc,
      extensions: [
        markdown({ extensions: GFM, addKeymap: false, pasteURLAsLink: false }),
        markdownPresentation,
        editorTheme,
        history(),
      ],
    }),
  });
  views.push(view);
  return view;
}

async function makeConnectedEditor(text = "") {
  const messages: EditorToNative[] = [];
  window.webkit = {
    messageHandlers: {
      jot: { postMessage: (message) => messages.push(message) },
    },
  };
  const parent = document.createElement("div");
  document.body.append(parent);
  const root = createRoot(parent);
  roots.push(root);
  await act(async () => root.render(createElement(Editor)));
  await act(async () => {
    window.JotNative?.receive({
      version: 1,
      type: "loadSession",
      text,
      noteID: text ? "note-1" : undefined,
      revision: text ? 1 : 0,
      selection: { anchor: text.length, head: text.length },
      viewport: { scrollTop: 0 },
    });
  });
  const editorElement = parent.querySelector<HTMLElement>(".cm-editor");
  if (!editorElement) throw new Error("CodeMirror did not mount");
  const view = EditorView.findFromDOM(editorElement);
  if (!view) throw new Error("CodeMirror view was unavailable");
  messages.length = 0;
  return { parent, view, messages };
}

function syntheticClipboardEvent(
  type: "copy" | "paste",
  values: Record<string, string>,
  files: unknown[] = [],
) {
  const written: Record<string, string> = {};
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      files,
      clearData: () => {
        for (const key of Object.keys(written)) delete written[key];
      },
      getData: (format: string) => values[format] ?? "",
      setData: (format: string, value: string) => {
        written[format] = value;
      },
    },
  });
  return { event, written };
}

afterEach(async () => {
  for (const view of views.splice(0)) view.destroy();
  await act(async () => {
    for (const root of roots.splice(0)) root.unmount();
  });
  delete window.webkit;
  vi.useRealTimers();
  document.body.replaceChildren();
});

describe("source-first Markdown presentation", () => {
  it("includes the fixed editor bands when requesting a taller panel", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Short note");
    const composer = parent.querySelector<HTMLElement>(".composer")!;
    composer.style.setProperty("--editor-top-inset", "44px");
    composer.style.setProperty("--editor-bottom-inset", "46px");
    view.scrollDOM.style.paddingTop = "9px";
    view.scrollDOM.style.paddingBottom = "11px";
    Object.defineProperty(view.contentDOM, "scrollHeight", { configurable: true, value: 300 });

    view.dispatch({ changes: { from: view.state.doc.length, insert: "!" } });
    await vi.waitFor(() => expect(messages.filter((message) => message.type === "preferredHeightChanged").at(-1))
      .toMatchObject({ height: 410 }));
  });

  it("recognizes only literal inline tags in ordinary Markdown", () => {
    const source = "# Heading\nHello #Project, (#second).\n`#inline` ``code #double`` \\#escaped\n```md\n#fenced\n```\n~~~\n#otherFence\n~~~\n[#label](https://example.test/#destination) https://example.test/#fragment\n😀 #emojiNeighbor";
    expect(findInlineTags(source).map((tag) => tag.name)).toEqual(["Project", "second", "label", "emojiNeighbor"]);
    expect(findInlineTags("#tag! #9bad ##double").map((tag) => tag.name)).toEqual(["tag"]);
  });

  it("styles literal source without changing selection, copy, or undo", async () => {
    const { view } = await makeConnectedEditor("Hello #Project.");
    expect(view.dom.querySelector(".cm-inline-tag")?.textContent).toBe("#Project");
    view.dispatch({ selection: { anchor: 6, head: 14 } });
    expect(view.state.selection.main.from).toBe(6);
    const copy = syntheticClipboardEvent("copy", {});
    view.focus();
    view.contentDOM.dispatchEvent(copy.event);
    expect(copy.written["text/plain"]).toBe("#Project");
    view.dispatch({ changes: { from: 14, insert: " #new" }, userEvent: "input.type" });
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("Hello #Project.");
  });

  it("completes an existing tag with Tab while keeping Enter and list Tab behavior", async () => {
    const { view, messages } = await makeConnectedEditor("- ");
    await act(async () => window.JotNative?.receive({ version: 1, type: "tagVocabulary", tags: ["MyTag", "other"] }));
    view.focus();
    await act(async () => view.dispatch({ ...view.state.replaceSelection("#my"), userEvent: "input.type" }));
    await vi.waitFor(() => expect(completionStatus(view.state)).toBe("active"));
    expect(currentCompletions(view.state).map((item) => item.label)).toEqual(["#MyTag"]);
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- #MyTag");
    expect(view.state.selection.main.head).toBe(8);
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "- #MyTag" });
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("- #my");
    view.dispatch({ changes: { from: 2, to: 5, insert: "#MyTag" }, selection: { anchor: 8 } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- #MyTag\n- ");
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- #MyTag\n     - ");
    view.dispatch({ changes: { from: view.state.doc.length, insert: "#fresh" }, selection: { anchor: view.state.doc.length + 6 }, userEvent: "input.type" });
    expect(view.state.doc.toString()).toContain("#fresh");
  });

  it("keeps Enter as a list newline while a suggestion is visible", async () => {
    const { view } = await makeConnectedEditor("- ");
    await act(async () => window.JotNative?.receive({ version: 1, type: "tagVocabulary", tags: ["MyTag"] }));
    view.focus();
    await act(async () => view.dispatch({ ...view.state.replaceSelection("#my"), userEvent: "input.type" }));
    await vi.waitFor(() => expect(completionStatus(view.state)).toBe("active"));
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- #my\n- ");
  });

  it("does not offer completions for an empty or unfamiliar tag", async () => {
    const { view } = await makeConnectedEditor();
    await act(async () => window.JotNative?.receive({ version: 1, type: "tagVocabulary", tags: ["MyTag"] }));
    view.focus();
    await act(async () => view.dispatch({ ...view.state.replaceSelection("#"), userEvent: "input.type" }));
    await vi.waitFor(() => expect(completionStatus(view.state)).toBeNull());
    await act(async () => view.dispatch({ ...view.state.replaceSelection("fresh"), userEvent: "input.type" }));
    await vi.waitFor(() => expect(completionStatus(view.state)).toBeNull());
    expect(view.state.doc.toString()).toBe("#fresh");
  });
  it("starts dictation and saves inserted transcript at the current selection", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Hello world");
    view.dispatch({ selection: { anchor: 5 } });
    await act(async () => {
      parent.querySelector<HTMLButtonElement>(".dictation-button")?.click();
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" });
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording", message: "Recording…" });
    });
    expect(messages.some((message) => message.type === "toggleDictation")).toBe(true);
    expect(parent.querySelector('.dictation-button[aria-label="Keep dictation"]')).not.toBeNull();
    expect(parent.querySelector('.dictation-button[aria-label="Cancel dictation"]')).not.toBeNull();
    await act(async () => parent.querySelector<HTMLButtonElement>('.dictation-button[aria-label="Keep dictation"]')?.click());
    expect(messages.some((message) => message.type === "finishDictation")).toBe(true);
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "there" });
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "idle" });
    });
    expect(view.state.doc.toString()).toBe("Hello there world");
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "Hello there world" });
    expect(parent.querySelector('.dictation-button[aria-label="Start dictation"]')).not.toBeNull();
  });

  it("discards provisional dictation when cancelled, without touching existing text", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Keep this");
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording" });
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "throw away" });
    });
    await act(async () => {
      parent.querySelector<HTMLButtonElement>('.dictation-button[aria-label="Cancel dictation"]')?.click();
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "idle" });
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "throw away" });
    });
    expect(messages.some((message) => message.type === "cancelDictation")).toBe(true);
    expect(view.state.doc.toString()).toBe("Keep this");
    expect(view.dom.querySelector(".cm-dictation-preview")).toBeNull();
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(0);
  });

  it("shows microphone levels only while recording", async () => {
    const { parent } = await makeConnectedEditor();
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording" });
      window.JotNative?.receive({ version: 1, type: "dictationLevel", level: 0.75 });
    });
    expect(parent.querySelectorAll(".dictation-waveform-bar")).toHaveLength(48);
    expect((parent.querySelector(".dictation-waveform-bar:last-child") as HTMLElement).style.transform).toBe("scaleY(0.7708333333333334)");
    await act(async () => window.JotNative?.receive({ version: 1, type: "dictationState", status: "idle" }));
    expect(parent.querySelector(".dictation-waveform")).toBeNull();
  });

  it("revises provisional text without saving it or adding undo history", async () => {
    const { view, messages } = await makeConnectedEditor("Hello world");
    view.dispatch({ selection: { anchor: 5 } });
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" });
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "there was" });
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "there" });
    });
    expect(view.dom.querySelector(".cm-dictation-preview")?.textContent).toBe("there");
    expect(view.state.doc.toString()).toBe("Hello world");
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(0);
    expect(undo(view)).toBe(false);
    await act(async () => window.JotNative?.receive({ version: 1, type: "dictationResult", text: "there" }));
    expect(view.state.doc.toString()).toBe("Hello there world");
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(1);
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("Hello world");
  });

  it("keeps the intended insertion point when the user types elsewhere", async () => {
    const { view } = await makeConnectedEditor("Alpha world");
    view.dispatch({ selection: { anchor: 6 } });
    await act(async () => window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" }));
    view.dispatch({ changes: { from: 0, insert: "New " }, selection: { anchor: 0 }, userEvent: "input.type" });
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "brave" });
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "brave" });
    });
    expect(view.state.doc.toString()).toBe("New Alpha brave world");
  });

  it("drops provisional text after cancellation or a session reload", async () => {
    const { view, messages } = await makeConnectedEditor("Keep");
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" });
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "guess" });
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "error", message: "Failed" });
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "guess" });
    });
    expect(view.state.doc.toString()).toBe("Keep");
    expect(view.dom.querySelector(".cm-dictation-preview")).toBeNull();
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(0);
  });

  it("replaces the original selection once and ignores a result after reloading", async () => {
    const { view, messages } = await makeConnectedEditor("Hello old world");
    view.dispatch({ selection: { anchor: 6, head: 9 } });
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" });
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "new" });
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "new" });
    });
    expect(view.state.doc.toString()).toBe("Hello new world");
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(1);
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" });
      window.JotNative?.receive({ version: 1, type: "loadSession", text: "External", noteID: "note-1", revision: 3, selection: { anchor: 8, head: 8 }, viewport: { scrollTop: 0 } });
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "stale" });
    });
    expect(view.state.doc.toString()).toBe("External");
  });

  it("shows no status during loading, saving, or successful writes", async () => {
    const { parent, view } = await makeConnectedEditor("Existing jot");
    expect(parent.querySelector(".status")).toBeNull();
    await act(async () => {
      view.dispatch({ changes: { from: view.state.doc.length, insert: " updated" } });
      window.JotNative?.receive({ version: 1, type: "saving", revision: 2 });
      window.JotNative?.receive({ version: 1, type: "writeSucceeded", noteID: "note-1", revision: 2 });
    });
    expect(parent.querySelector(".status")).toBeNull();
    expect(parent.textContent).not.toMatch(/Saving|Saved/);
  });

  it("keeps a write failure visible through saving and clears it after a confirmed write", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Existing jot");
    await act(async () => {
      view.dispatch({ changes: { from: view.state.doc.length, insert: " updated" } });
      window.JotNative?.receive({
        version: 1, type: "writeFailed", noteID: "note-1", revision: 2,
        errorCode: "root_unavailable", message: "The Jots folder is unavailable.", actions: ["restoreRoot"],
      });
    });
    expect(parent.querySelector('[role="alert"]')?.textContent).toContain("The Jots folder is unavailable.");
    expect(parent.querySelector(".status button")?.textContent).toBe("Restore Folder Access");
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "saving", revision: 2 });
      window.JotNative?.receive({ version: 1, type: "writeSucceeded", noteID: "note-1", revision: 1 });
    });
    expect(parent.querySelector('[role="alert"]')).not.toBeNull();
    await act(async () => {
      parent.querySelector<HTMLButtonElement>(".status button")?.click();
      window.JotNative?.receive({ version: 1, type: "writeSucceeded", noteID: "note-1", revision: 2 });
    });
    expect(messages.some((message) => message.type === "recover" && message.action === "restoreRoot")).toBe(true);
    expect(parent.querySelector(".status")).toBeNull();
  });

  it("renders typed list markers as round bullets while preserving Markdown", async () => {
    const { view, messages } = await makeConnectedEditor("-");
    await act(async () => view.dispatch({ ...view.state.replaceSelection(" "), userEvent: "input.type" }));
    expect(view.dom.querySelector(".cm-list-bullet")?.textContent).toBe("•");
    expect(view.state.doc.toString()).toBe("- ");
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "- " });
  });

  it("renders unordered markers, but leaves code and ordered lists alone", () => {
    const view = makeView("- one\n  - nested\n\n* two\n\n+ three\n\n1. ordered\n\n```\n- code\n```\n\n`- inline code`");
    expect(view.dom.querySelectorAll(".cm-list-bullet")).toHaveLength(4);
  });

  it("alternates filled and open bullets by list depth without changing Markdown", () => {
    const source = "- one\n     - two\n          - three\n     - four\n- five";
    const view = makeView(source);
    expect([...view.dom.querySelectorAll(".cm-list-bullet")].map((bullet) => bullet.textContent)).toEqual([
      "•", "○", "•", "○", "•",
    ]);
    expect(view.state.doc.toString()).toBe(source);
  });

  it("shows the nested marker in the same update as Tab", async () => {
    const { view } = await makeConnectedEditor("- one\n- two");
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- one\n     - two");
    expect([...view.dom.querySelectorAll(".cm-list-bullet")].map((bullet) => bullet.textContent)).toEqual(["•", "○"]);
  });

  it("accepts Tab immediately after a bullet was typed", async () => {
    const { view } = await makeConnectedEditor();
    view.dispatch({ changes: { from: 0, insert: "- one\n- two" }, selection: { anchor: 11 }, userEvent: "input.type" });
    view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true }));
    expect(view.state.doc.toString()).toBe("- one\n     - two");
  });

  it("indents a visible bullet near the end of a long note before background parsing finishes", () => {
    const source = Array.from({ length: 500 }, (_, index) => `- item ${index}`).join("\n");
    const view = makeView(source);
    view.dispatch({ selection: { anchor: source.length } });
    expect(indentBulletItem(view)).toBe(true);
    expect(view.state.doc.toString().endsWith("\n     - item 499")).toBe(true);
  });

  it.each([
    ["- first", "- first\n- ", "- first\n"],
    ["* first", "* first\n* ", "* first\n"],
    ["+ first", "+ first\n+ ", "+ first\n"],
    ["1. first", "1. first\n2. ", "1. first\n"],
    ["- [x] done", "- [x] done\n- [ ] ", "- [x] done\n"],
  ])("continues %s with Enter and exits an empty item with Enter", async (text, continued, exited) => {
    const { view, messages } = await makeConnectedEditor(text);
    const enter = async () => act(async () => {
      view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true }));
    });
    await enter();
    expect(view.state.doc.toString()).toBe(continued);
    expect(view.state.selection.main.head).toBe(continued.length);
    await enter();
    expect(view.state.doc.toString()).toBe(exited);
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: exited });
  });

  it("continues nested lists, splits items, and leaves fenced code literal", async () => {
    for (const [text, position, expected] of [
      ["- outer\n  - inner", 17, "- outer\n  - inner\n  - "],
      ["- first second", 8, "- first\n- second"],
      ["```\n- code\n```", 10, "```\n- code\n\n```"],
    ] as const) {
      const { view } = await makeConnectedEditor(text);
      view.dispatch({ selection: { anchor: position } });
      await act(async () => {
        view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true }));
      });
      expect(view.state.doc.toString()).toBe(expected);
    }
  });

  it("indents one bullet level at a time and outdents back to top level", async () => {
    const { view, messages } = await makeConnectedEditor("- parent\n  - first child\n  - next child");
    const press = async (shiftKey = false) => act(async () => {
      view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", shiftKey, bubbles: true, cancelable: true }));
    });
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    await press();
    expect(view.state.doc.toString()).toBe("- parent\n  - first child\n       - next child");
    expect(view.state.selection.main.head).toBe(view.state.doc.length);
    await press();
    expect(view.state.doc.toString()).toBe("- parent\n  - first child\n       - next child");
    await press(true);
    expect(view.state.doc.toString()).toBe("- parent\n  - first child\n  - next child");
    await press(true);
    expect(view.state.doc.toString()).toBe("- parent\n  - first child\n- next child");
    await press(true);
    expect(view.state.doc.toString()).toBe("- parent\n  - first child\n- next child");
    expect(messages.filter((message) => message.type === "contentChanged").map((message) => message.text)).toEqual([
      "- parent\n  - first child\n       - next child",
      "- parent\n  - first child\n  - next child",
      "- parent\n  - first child\n- next child",
    ]);
  });

  it("keeps the first bullet and an already nested first child from skipping a level", async () => {
    for (const [text, position] of [["- first\n- second", 2], ["- parent\n  - child", 18]] as const) {
      const { view } = await makeConnectedEditor(text);
      view.dispatch({ selection: { anchor: position } });
      const event = new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true, cancelable: true });
      await act(async () => view.contentDOM.dispatchEvent(event));
      expect(event.defaultPrevented).toBe(true);
      expect(view.state.doc.toString()).toBe(text);
    }
  });

  it("moves a selected item with its descendants and preserves selection, undo, and redo", async () => {
    const original = "- first\n- second\n  - child\n- third";
    const { view, messages } = await makeConnectedEditor(original);
    view.dispatch({ selection: { anchor: 8, head: 16 } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    const nested = "- first\n     - second\n       - child\n- third";
    expect(view.state.doc.toString()).toBe(nested);
    expect(view.state.selection.main.from).toBe(13);
    expect(view.state.selection.main.to).toBe(21);
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: nested });
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe(original);
    expect(redo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe(nested);
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", shiftKey: true, bubbles: true })));
    expect(view.state.doc.toString()).toBe(original);
  });

  it("indents selected sibling bullets, including an empty item, exactly once", async () => {
    const { view } = await makeConnectedEditor("- first\n- second\n- \n- fourth");
    view.dispatch({ selection: { anchor: 8, head: 19 } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- first\n     - second\n     - \n- fourth");
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", shiftKey: true, bubbles: true })));
    expect(view.state.doc.toString()).toBe("- first\n- second\n- \n- fourth");
  });

  it("outdents existing nested bullets with their original Markdown spacing", async () => {
    for (const spaces of ["   ", "    ", "\t"]) {
      const { view } = await makeConnectedEditor(`- parent\n${spaces}* child`);
      await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", shiftKey: true, bubbles: true })));
      expect(view.state.doc.toString()).toBe("- parent\n* child");
    }
  });

  it("outdents a bullet while preserving lazy continuation text", async () => {
    const { view } = await makeConnectedEditor("- parent\n  - child\ncontinuation");
    view.dispatch({ selection: { anchor: 16 } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", shiftKey: true, bubbles: true })));
    expect(view.state.doc.toString()).toBe("- parent\n- child\ncontinuation");
  });

  it("does not partially indent a selection that includes the first bullet", async () => {
    const original = "- first\n- second\n- third";
    const { view } = await makeConnectedEditor(original);
    view.dispatch({ selection: { anchor: 0, head: 17 } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe(original);
  });

  it("leaves prose, ordered lists, code, and mixed selections to their existing Tab behavior", async () => {
    for (const [text, position] of [
      ["plain prose", 5], ["1. ordered", 5], ["```\n- code\n```", 7],
      ["- bullet\n  ```\n  code\n  ```", 18],
    ] as const) {
      const { view } = await makeConnectedEditor(text);
      view.dispatch({ selection: { anchor: position } });
      const event = new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true, cancelable: true });
      await act(async () => view.contentDOM.dispatchEvent(event));
      expect(event.defaultPrevented).toBe(false);
      expect(view.state.doc.toString()).toBe(text);
    }
    const { view } = await makeConnectedEditor("- bullet\nprose");
    view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- bullet\nprose");
  });

  it("copies bullets as Markdown, and Backspace removes an empty bullet", async () => {
    const { view } = await makeConnectedEditor("- first\n- ");
    view.focus();
    view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } });
    const copy = syntheticClipboardEvent("copy", {});
    view.contentDOM.dispatchEvent(copy.event);
    expect(copy.written["text/plain"]).toBe("- first\n- ");
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    await act(async () => {
      view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true }));
    });
    expect(view.state.doc.toString()).toBe("- first\n  ");
  });

  it("preserves an exact mixed fixture corpus", () => {
    const fixture = [
      "# Heading",
      "",
      "**bold** _emphasis_ ~~strike~~ [link](https://example.test)",
      "> quote",
      "- [x] task",
      "1. ordered",
      "",
      "```ts",
      "const emoji = '📝';",
      "```",
      "",
      "| unsupported | table |",
      "<custom incomplete=\"yes\">",
      "unclosed **marker",
    ].join("\n");
    const view = makeView(fixture);
    expect(view.state.doc.toString()).toBe(fixture);
  });

  it("fades markers away from the caret and reveals the active line", () => {
    const view = makeView("# One\n\n**Two**");
    expect(view.dom.querySelectorAll(".cm-markdown-marker").length).toBeGreaterThan(0);
    view.dispatch({ selection: { anchor: 9 } });
    expect(view.dom.querySelectorAll(".cm-markdown-marker-active").length).toBeGreaterThan(0);
    expect(view.state.doc.toString()).toBe("# One\n\n**Two**");
  });

  it("keeps malformed and incomplete source editable", () => {
    const view = makeView("[unfinished\n```\n**");
    view.dispatch({ changes: { from: 1, to: 1, insert: "x" } });
    view.dispatch({ changes: { from: view.state.doc.length, insert: " tail" } });
    expect(view.state.doc.toString()).toBe("[xunfinished\n```\n** tail");
  });

  it("does not add undo steps for presentation updates", () => {
    const view = makeView("plain");
    view.dispatch({ changes: { from: 5, insert: " **bold**" }, userEvent: "input.type" });
    view.dispatch({ selection: { anchor: 9 } });
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("plain");
    expect(undo(view)).toBe(false);
  });

  it("inserts a literal newline without continuing Markdown structure", () => {
    const view = makeView("> quote\n- [x] task");
    view.dispatch({ selection: { anchor: 7 } });
    expect(insertLiteralNewline(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("> quote\n\n- [x] task");
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    insertLiteralNewline(view);
    expect(view.state.doc.toString()).toBe("> quote\n\n- [x] task\n");
  });

  it("retries editor readiness when the native bridge returns", async () => {
    vi.useFakeTimers();
    const messages: Array<{ type: string }> = [];
    const parent = document.createElement("div");
    document.body.append(parent);
    const root = createRoot(parent);
    roots.push(root);

    await act(async () => root.render(createElement(Editor)));
    expect(parent.textContent).toContain("Saving is interrupted");

    window.webkit = {
      messageHandlers: {
        jot: { postMessage: (message) => messages.push(message) },
      },
    };
    await act(async () => vi.advanceTimersByTimeAsync(250));
    expect(messages.map((message) => message.type)).toContain("editorReady");
  });

  it("persists only the committed result of IME composition", async () => {
    const { view, messages } = await makeConnectedEditor();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    expect(view.compositionStarted).toBe(true);

    view.dispatch({ changes: { from: 0, insert: "k" }, userEvent: "input.type.compose" });
    view.dispatch({ changes: { from: 0, to: 1, insert: "かなé" }, userEvent: "input.type.compose" });
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(0);

    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "かなé" }));
    await Promise.resolve();
    const changes = messages.filter((message) => message.type === "contentChanged");
    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ text: "かなé", revision: 1 });
  });

  it("pastes rich clipboard content as exact plain text and copies canonical Markdown", async () => {
    const { view } = await makeConnectedEditor();
    const paste = syntheticClipboardEvent("paste", {
      "text/plain": "**bold** & literal",
      "text/html": "<strong>bold</strong> &amp; literal",
    });
    view.contentDOM.dispatchEvent(paste.event);
    expect(view.state.doc.toString()).toBe("**bold** & literal");

    view.focus();
    view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } });
    const copy = syntheticClipboardEvent("copy", {});
    view.contentDOM.dispatchEvent(copy.event);
    expect(copy.written["text/plain"]).toBe("**bold** & literal");
  });

  it("rejects pasted files without changing the document", async () => {
    const { view } = await makeConnectedEditor("keep me");
    const paste = syntheticClipboardEvent("paste", {}, [{}]);
    view.contentDOM.dispatchEvent(paste.event);
    expect(paste.event.defaultPrevented).toBe(true);
    expect(view.state.doc.toString()).toBe("keep me");
  });
});
