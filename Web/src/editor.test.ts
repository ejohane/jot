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

afterEach(() => {
  for (const view of views.splice(0)) view.destroy();
  for (const root of roots.splice(0)) root.unmount();
  delete window.webkit;
  vi.useRealTimers();
  document.body.replaceChildren();
});

describe("source-first Markdown presentation", () => {
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
