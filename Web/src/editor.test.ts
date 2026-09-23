import { history, undo } from "@codemirror/commands";
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
  it("starts dictation and saves inserted transcript at the current selection", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Hello world");
    view.dispatch({ selection: { anchor: 5 } });
    await act(async () => {
      parent.querySelector<HTMLButtonElement>(".dictation-button")?.click();
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording", message: "Recording…" });
    });
    expect(messages.some((message) => message.type === "toggleDictation")).toBe(true);
    expect(parent.querySelector('.dictation-button[aria-label="Stop dictation"]')).not.toBeNull();
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "there" });
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "idle" });
    });
    expect(view.state.doc.toString()).toBe("Hello there world");
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "Hello there world" });
    expect(parent.querySelector('.dictation-button[aria-label="Start dictation"]')).not.toBeNull();
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
