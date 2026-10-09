import { pendingImageImport } from "./attachments";
import { history, redo, undo } from "@codemirror/commands";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { syntaxTree } from "@codemirror/language";
import { editorTheme } from "./editorTheme";
import { Editor, insertLiteralNewline, jotMarkdown } from "./Editor";
import type { EditorToNative } from "./bridge";
import { markdownPresentation } from "./presentation";
import { findInlineTags } from "./tags";
import { completionStatus, currentCompletions } from "@codemirror/autocomplete";
import { indentListItem } from "./listIndent";
import { toggleInlineFormat } from "./formatting";
import { searchPanelOpen } from "@codemirror/search";

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
        jotMarkdown,
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
  it("reveals chrome on pointer movement, resets its idle delay, and hides on window blur", async () => {
    const { parent, view, messages } = await makeConnectedEditor("A quiet jot");
    vi.useFakeTimers();
    const composer = parent.querySelector(".composer")!;
    expect(composer.classList.contains("is-pointer-active")).toBe(false);
    await act(async () => composer.dispatchEvent(new Event("pointermove", { bubbles: true })));
    expect(composer.classList.contains("is-pointer-active")).toBe(true);
    await act(async () => vi.advanceTimersByTime(1400));
    await act(async () => composer.dispatchEvent(new Event("pointermove", { bubbles: true })));
    await act(async () => vi.advanceTimersByTime(1400));
    expect(composer.classList.contains("is-pointer-active")).toBe(true);
    await act(async () => vi.advanceTimersByTime(100));
    expect(composer.classList.contains("is-pointer-active")).toBe(false);
    await act(async () => composer.dispatchEvent(new Event("pointermove", { bubbles: true })));
    await act(async () => window.dispatchEvent(new Event("blur")));
    expect(composer.classList.contains("is-pointer-active")).toBe(false);
    expect(view.state.doc.toString()).toBe("A quiet jot");
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(0);
  });

  it("opens commands from its separate corner control without changing the note", async () => {
    const { parent, view, messages } = await makeConnectedEditor("A quiet jot");
    const buttons = parent.querySelectorAll<HTMLButtonElement>(".dictation-controls button, .command-controls button");
    expect(buttons[0].getAttribute("aria-label")).toBe("Start dictation");
    expect(buttons[1].getAttribute("aria-label")).toBe("Commands");
    expect(buttons[1].getAttribute("title")).toBe("Commands (⌘K)");
    expect(buttons[0].className).toBe(buttons[1].className);
    await act(async () => buttons[1].click());
    expect(parent.querySelector('[aria-label="Search for actions"][role="combobox"]')).not.toBeNull();
    expect(messages.some((message) => message.type === "searchNotes")).toBe(false);
    expect(view.state.doc.toString()).toBe("A quiet jot");
    expect(messages.filter((message) => message.type === "contentChanged")).toHaveLength(0);
  });

  it("shows rail previews and requests the selected jot in this editor", async () => {
    const { parent, messages } = await makeConnectedEditor("current note");
    await act(async () => window.JotNative?.receive({
      version: 1,
      type: "noteRail",
      notes: [
        { id: "note-2", timestamp: Date.parse("2026-09-24T18:20:00Z"), excerpt: "A short preview" },
        { id: "note-1", timestamp: Date.parse("2026-09-23T18:20:00Z"), excerpt: "Current note" },
      ],
    }));
    const ticks = parent.querySelectorAll<HTMLButtonElement>(".note-tick");
    expect(ticks).toHaveLength(2);
    expect(ticks[1].getAttribute("aria-current")).toBe("true");
    await act(async () => ticks[0].dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientY: 5 })));
    expect(parent.querySelector(".note-rail-preview")?.textContent).toContain("A short preview");
    await act(async () => ticks[0].click());
    expect(messages.filter((message) => message.type === "openNote").at(-1)).toEqual({ version: 1, type: "openNote", noteID: "note-2", revision: 1 });
  });

  it("updates the preview as the rail scrolls under a stationary pointer", async () => {
    const { parent } = await makeConnectedEditor();
    await act(async () => window.JotNative?.receive({
      version: 1,
      type: "noteRail",
      notes: Array.from({ length: 100 }, (_, index) => ({
        id: `note-${index}`, timestamp: Date.now() - index * 1_000, excerpt: `Preview ${index}`,
      })),
    }));
    const rail = parent.querySelector<HTMLElement>(".note-rail-scroll");
    if (!rail) throw new Error("Note rail was unavailable");
    const list = parent.querySelector<HTMLElement>(".note-rail-list")!;
    list.getBoundingClientRect = () => new DOMRect(0, -rail.scrollTop, 37, 1_000);
    await act(async () => rail.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientY: 5 })));
    expect(parent.querySelector(".note-rail-preview")?.textContent).toContain("Preview 0");
    await act(async () => {
      rail.scrollTop = 100;
      rail.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    expect(parent.querySelector(".note-rail-preview")?.textContent).toContain("Preview 10");
    expect(parent.querySelectorAll(".note-tick").length).toBeLessThan(100);
  });

  it("maps hover and hovercard position to a centered short stack", async () => {
    const { parent } = await makeConnectedEditor();
    await act(async () => window.JotNative?.receive({
      version: 1,
      type: "noteRail",
      notes: Array.from({ length: 3 }, (_, index) => ({
        id: `note-${index}`, timestamp: Date.now() - index * 1_000, excerpt: `Centered ${index}`,
      })),
    }));
    const rail = parent.querySelector<HTMLElement>(".note-rail-scroll")!;
    const list = parent.querySelector<HTMLElement>(".note-rail-list")!;
    Object.defineProperty(rail, "clientHeight", { configurable: true, value: 200 });
    rail.getBoundingClientRect = () => new DOMRect(0, 0, 37, 200);
    list.getBoundingClientRect = () => new DOMRect(0, 85, 37, 30);
    await act(async () => rail.dispatchEvent(new Event("scroll", { bubbles: true })));
    await act(async () => rail.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientY: 90 })));
    expect(parent.querySelector(".note-rail-preview")?.textContent).toContain("Centered 0");
    expect(parent.querySelector<HTMLElement>(".note-rail-preview")?.style.top).toBe("90px");
    await act(async () => rail.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientY: 70 })));
    expect(parent.querySelector(".note-rail-preview")).toBeNull();
    expect(parent.querySelector(".note-rail")?.classList.contains("is-resting")).toBe(true);
  });

  it("swells nearby ticks and settles to a fixed selected tick when the pointer leaves", async () => {
    const { parent, messages } = await makeConnectedEditor("Selected note");
    await act(async () => window.JotNative?.receive({
      version: 1,
      type: "noteRail",
      notes: Array.from({ length: 9 }, (_, index) => ({
        id: `note-${index}`, timestamp: Date.now() - index * 1_000, excerpt: `Note ${index}`,
      })),
    }));
    const rail = parent.querySelector<HTMLElement>(".note-rail-scroll")!;
    const list = parent.querySelector<HTMLElement>(".note-rail-list")!;
    list.getBoundingClientRect = () => new DOMRect(0, -rail.scrollTop, 37, 90);
    Object.defineProperty(rail, "clientHeight", { configurable: true, value: 180 });
    await act(async () => rail.dispatchEvent(new Event("scroll", { bubbles: true })));
    const lengths = () => Array.from(parent.querySelectorAll<HTMLElement>(".note-tick span"), (span) =>
      Number.parseFloat(span.style.transform.match(/scaleX\(([^)]+)\)/)?.[1] ?? "0") * 31);
    expect(lengths()[1]).toBeCloseTo(10);
    expect(lengths()[2]).toBeCloseTo(6);
    expect(parent.querySelector(".note-rail")?.classList.contains("is-resting")).toBe(true);
    await act(async () => rail.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientY: 3.5 * 10 })));
    expect(parent.querySelector(".note-rail")?.classList.contains("is-resting")).toBe(false);
    const wave = lengths();
    expect(wave[3]).toBeCloseTo(26);
    expect(wave[1]).toBeLessThan(wave[2]);
    expect(wave[2]).toBeLessThan(wave[3]);
    expect(parent.querySelectorAll<HTMLButtonElement>(".note-tick")[1].classList.contains("is-active")).toBe(true);
    expect(wave[4]).toBeGreaterThan(wave[5]);
    expect(wave[5]).toBeGreaterThan(wave[6]);
    expect(wave[4]).toBeCloseTo(wave[2]);
    await act(async () => {
      const tick = parent.querySelectorAll<HTMLButtonElement>(".note-tick")[3];
      tick.focus();
      tick.blur();
    });
    expect(lengths()[2]).toBeCloseTo(wave[2]);
    await act(async () => rail.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body })));
    expect(parent.querySelector(".note-rail")?.classList.contains("is-resting")).toBe(true);
    expect(lengths()[1]).toBeCloseTo(10);
    lengths().forEach((length, index) => {
      if (index !== 1) expect(length).toBeCloseTo(6);
    });
    await act(async () => parent.querySelectorAll<HTMLButtonElement>(".note-tick")[3].click());
    expect(messages.filter(message => message.type === "openNote").at(-1)).toMatchObject({ type: "openNote", noteID: "note-3" });
    await act(async () => window.JotNative?.receive({
      version: 1, type: "loadSession", text: "Note 3", noteID: "note-3", revision: 2,
      selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 },
    }));
    expect(lengths()[3]).toBeCloseTo(10);
    expect(lengths()[1]).toBeCloseTo(6);
    expect(parent.querySelectorAll<HTMLButtonElement>(".note-tick")[3].getAttribute("aria-current")).toBe("true");
  });

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
      parent.querySelector<HTMLButtonElement>(".chrome-button")?.click();
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "downloading" });
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording", message: "Recording…" });
    });
    expect(messages.some((message) => message.type === "toggleDictation")).toBe(true);
    expect(parent.querySelector('.chrome-button[aria-label="Keep dictation"]')).not.toBeNull();
    expect(parent.querySelector('.chrome-button[aria-label="Cancel dictation"]')).not.toBeNull();
    await act(async () => parent.querySelector<HTMLButtonElement>('.chrome-button[aria-label="Keep dictation"]')?.click());
    expect(messages.some((message) => message.type === "finishDictation")).toBe(true);
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationResult", text: "there" });
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "idle" });
    });
    expect(view.state.doc.toString()).toBe("Hello there world");
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "Hello there world" });
    expect(parent.querySelector('.chrome-button[aria-label="Start dictation"]')).not.toBeNull();
  });

  it("discards provisional dictation when cancelled, without touching existing text", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Keep this");
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording" });
      window.JotNative?.receive({ version: 1, type: "dictationPartial", text: "throw away" });
    });
    await act(async () => {
      parent.querySelector<HTMLButtonElement>('.chrome-button[aria-label="Cancel dictation"]')?.click();
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

  it("reveals a list marker while editing and renders it as a bullet when the caret leaves", async () => {
    const { view, messages } = await makeConnectedEditor("-");
    await act(async () => view.dispatch({ ...view.state.replaceSelection(" "), userEvent: "input.type" }));
    expect(view.dom.querySelector(".cm-list-bullet")).toBeNull();
    expect(view.contentDOM.textContent).toContain("- ");
    expect(view.state.doc.toString()).toBe("- ");
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "- " });
    view.dispatch({ changes: { from: 2, insert: "one\nplain" }, selection: { anchor: 11 } });
    expect(view.dom.querySelector(".cm-list-bullet")?.textContent).toBe("•");
  });

  it("renders unordered markers, but leaves code and ordered lists alone", () => {
    const view = makeView("- one\n  - nested\n\n* two\n\n+ three\n\n1. ordered\n\n```\n- code\n```\n\n`- inline code`");
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    expect(view.dom.querySelectorAll(".cm-list-bullet")).toHaveLength(4);
    expect(view.dom.querySelector(".cm-list-number")?.textContent).toBe("1.");
  });

  it("alternates filled and open bullets by list depth without changing Markdown", () => {
    const source = "- one\n     - two\n          - three\n     - four\n- five\nplain";
    const view = makeView(source);
    view.dispatch({ selection: { anchor: source.length } });
    expect([...view.dom.querySelectorAll(".cm-list-bullet")].map((bullet) => bullet.textContent)).toEqual([
      "•", "○", "•", "○", "•",
    ]);
    expect(view.state.doc.toString()).toBe(source);
  });

  it("shows the nested marker in the same update as Tab", async () => {
    const { view } = await makeConnectedEditor("- one\n- two");
    view.focus();
    expect(view.dom.querySelector(".cm-cursorLayer")).not.toBeNull();
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("- one\n     - two");
    expect([...view.dom.querySelectorAll(".cm-list-bullet")].map((bullet) => bullet.textContent)).toEqual(["•"]);
    expect(view.contentDOM.textContent).toContain("- two");
    expect(view.dom.querySelector(".cm-cursorLayer")).not.toBeNull();
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
    expect(indentListItem(view)).toBe(true);
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

  it("leaves prose, code, and mixed selections to their existing Tab behavior", async () => {
    for (const [text, position] of [
      ["plain prose", 5], ["```\n- code\n```", 7],
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

  it("hides completed hand-typed emphasis markers away from the caret and reveals them for editing", () => {
    const source = "plain\n**bold** and *italic*\nunfinished **marker";
    const view = makeView(source);
    expect(view.contentDOM.textContent).toContain("bold and italic");
    expect(view.contentDOM.textContent).not.toContain("**bold**");
    expect(view.contentDOM.textContent).toContain("unfinished **marker");
    view.dispatch({ selection: { anchor: source.indexOf("bold") + 1 } });
    expect(view.contentDOM.textContent).toContain("**bold**");
    expect(view.contentDOM.textContent).not.toContain("*italic*");
    view.dispatch({ selection: { anchor: source.indexOf("italic") + 1 } });
    expect(view.contentDOM.textContent).toContain("*italic*");
    expect(view.contentDOM.textContent).not.toContain("**bold**");
    view.dispatch({ selection: { anchor: source.indexOf("*italic*") + "*italic*".length } });
    expect(view.contentDOM.textContent).not.toContain("*italic*");
    expect(view.state.doc.toString()).toBe(source);
  });

  it("presents headings, code, strikethrough, links, and quotes without Markdown markers", () => {
    const source = "plain\n# Heading\n`code` ~~strike~~ [label](https://example.test/a)\n> quote\n[incomplete](";
    const view = makeView(source);
    expect(view.contentDOM.textContent).toContain("Heading");
    expect(view.contentDOM.textContent).not.toContain("# Heading");
    expect(view.contentDOM.textContent).toContain("code strike label");
    expect(view.contentDOM.textContent).not.toContain("`code`");
    expect(view.contentDOM.textContent).not.toContain("~~strike~~");
    expect(view.contentDOM.textContent).not.toContain("https://example.test/a");
    expect(view.contentDOM.textContent).toContain("quote");
    expect(view.contentDOM.textContent).not.toContain("> quote");
    expect(view.contentDOM.textContent).toContain("[incomplete](");

    view.dispatch({ selection: { anchor: source.indexOf("Heading") + 2 } });
    expect(view.contentDOM.textContent).toContain("# Heading");
    expect(view.contentDOM.textContent).not.toContain("`code`");
    view.dispatch({ selection: { anchor: source.indexOf("code") + 2 } });
    expect(view.contentDOM.textContent).toContain("`code`");
    expect(view.contentDOM.textContent).not.toContain("# Heading");
    view.dispatch({ selection: { anchor: source.indexOf("label") + 2 } });
    expect(view.contentDOM.textContent).toContain("[label](https://example.test/a)");
    expect(view.state.doc.toString()).toBe(source);
  });

  it("handles closing heading marks, multiline quotes, and autolinks without hiding unsupported source", () => {
    const source = "plain\n# Heading ###\n> first\n> second\n<https://example.test>\n![alt](image.png)\n# \nplain";
    const view = makeView(source);
    expect(view.contentDOM.textContent).toContain("Heading");
    expect(view.contentDOM.textContent).not.toContain("###");
    expect(view.contentDOM.textContent).not.toContain("> first");
    expect(view.contentDOM.textContent).not.toContain("> second");
    expect(view.contentDOM.textContent).toContain("https://example.test");
    expect(view.contentDOM.textContent).not.toContain("<https://example.test>");
    expect(view.contentDOM.textContent).toContain("![alt](image.png)");
    expect(view.contentDOM.textContent).toContain("# ");
    view.dispatch({ selection: { anchor: source.indexOf("second") + 1 } });
    expect(view.contentDOM.textContent).toContain("> second");
    expect(view.contentDOM.textContent).not.toContain("> first");
    expect(view.state.doc.toString()).toBe(source);
  });

  it("shows list, task, fence, and rule source only while editing those constructs", () => {
    const source = "plain\n- bullet\n1. numbered\n- [x] done\n---\n```js\nconst x = 1\n```\nplain";
    const view = makeView(source);
    expect(view.dom.querySelectorAll(".cm-list-bullet")).toHaveLength(2);
    expect(view.dom.querySelector(".cm-list-number")?.textContent).toBe("1.");
    expect(view.dom.querySelector(".cm-task-checkbox.is-checked")).not.toBeNull();
    expect(view.dom.querySelector(".cm-horizontal-rule")).not.toBeNull();
    expect(view.contentDOM.textContent).not.toContain("[x]");
    expect(view.contentDOM.textContent).not.toContain("```js");

    view.dispatch({ selection: { anchor: source.indexOf("done") + 1 } });
    expect(view.contentDOM.textContent).toContain("- [x] done");
    expect(view.dom.querySelector(".cm-task-checkbox.is-checked")).toBeNull();
    view.dispatch({ selection: { anchor: source.indexOf("const x") + 2 } });
    expect(view.contentDOM.textContent).toContain("```js");
    view.dispatch({ selection: { anchor: source.indexOf("---") + 1 } });
    expect(view.contentDOM.textContent).toContain("---");
    expect(view.dom.querySelector(".cm-horizontal-rule")).toBeNull();
    expect(view.state.doc.toString()).toBe(source);
  });

  it("leaves an unfinished code fence visible", () => {
    const view = makeView("plain\n```js\nwork in progress");
    expect(view.contentDOM.textContent).toContain("```js");
    expect(view.state.doc.toString()).toBe("plain\n```js\nwork in progress");
  });

  it("formats selected text as Markdown, toggles it off, and keeps undo and persistence intact", async () => {
    const { view, messages } = await makeConnectedEditor("hello world");
    view.dispatch({ selection: { anchor: 6, head: 11 } });
    expect(toggleInlineFormat(view, "bold")).toBe(true);
    expect(view.state.doc.toString()).toBe("hello **world**");
    expect(view.state.selection.main.from).toBe(8);
    expect(view.state.selection.main.to).toBe(13);
    expect(messages.filter((message) => message.type === "contentChanged").at(-1)).toMatchObject({ text: "hello **world**" });
    expect(toggleInlineFormat(view, "bold")).toBe(true);
    expect(view.state.doc.toString()).toBe("hello world");
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("hello **world**");
  });

  it("formats at an empty caret and accepts the same toggle through the native menu bridge", async () => {
    const { view } = await makeConnectedEditor("hello ");
    expect(toggleInlineFormat(view, "italic")).toBe(true);
    expect(view.state.doc.toString()).toBe("hello **");
    expect(view.state.selection.main.head).toBe(7);
    view.dispatch({ ...view.state.replaceSelection("world"), userEvent: "input.type" });
    expect(view.state.doc.toString()).toBe("hello *world*");
    view.dispatch({ selection: { anchor: 1, head: 5 } });
    window.JotNative?.receive({ version: 1, type: "toggleFormat", format: "bold" });
    expect(view.state.doc.toString()).toBe("h**ello** *world*");
  });

  it("toggles hand-typed formatting off from a caret within its text", () => {
    const view = makeView("before **bold** after");
    view.dispatch({ selection: { anchor: 11 } });
    expect(toggleInlineFormat(view, "bold")).toBe(true);
    expect(view.state.doc.toString()).toBe("before bold after");
    for (const [source, format, position, expected] of [
      ["_italic_", "italic", 4, "italic"],
      ["__bold__", "bold", 4, "bold"],
    ] as const) {
      const handTyped = makeView(source);
      handTyped.dispatch({ selection: { anchor: position } });
      expect(toggleInlineFormat(handTyped, format)).toBe(true);
      expect(handTyped.state.doc.toString()).toBe(expected);
    }
  });

  it("starts a new format at the boundary after an existing span", () => {
    const view = makeView("**bold**");
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    expect(toggleInlineFormat(view, "bold")).toBe(true);
    expect(view.state.doc.toString()).toBe("**bold******");
    expect(view.state.selection.main.head).toBe(10);
  });

  it("handles the platform formatting shortcut in the editor", async () => {
    const { view } = await makeConnectedEditor("text");
    view.focus();
    view.dispatch({ selection: { anchor: 0, head: 4 } });
    const modifier = /Mac/.test(navigator.platform) ? { metaKey: true } : { ctrlKey: true };
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", {
      key: "b", code: "KeyB", ...modifier, bubbles: true, cancelable: true,
    })));
    expect(view.state.doc.toString()).toBe("**text**");
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


describe("note actions", () => {
  async function openActions(parent: HTMLElement) {
    await act(async () => window.JotNative?.receive({ version: 1, type: "toggleActionPanel" }));
    const input = parent.querySelector<HTMLInputElement>(".action-panel-search")!;
    expect(document.activeElement).toBe(input);
    return input;
  }
  async function query(input: HTMLInputElement, value: string) {
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
  }
  it("opens with Command-K and native Escape restores the selection without changing or saving text", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Keep **this** source");
    view.dispatch({ selection: { anchor: 2, head: 8 } });
    messages.length = 0;
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "k", metaKey: true, bubbles: true, cancelable: true })));
    expect(parent.querySelector('[role="dialog"]')).not.toBeNull();
    expect(parent.querySelector(".composer-content")?.hasAttribute("inert")).toBe(true);
    await act(async () => window.JotNative?.receive({ version: 1, type: "escape" }));
    expect(parent.querySelector('[role="dialog"]')).toBeNull();
    expect(view.state.selection.main.anchor).toBe(2);
    expect(view.state.selection.main.head).toBe(8);
    expect(view.state.doc.toString()).toBe("Keep **this** source");
    expect(messages.some((message) => message.type === "hide" || message.type === "contentChanged")).toBe(false);
    expect(messages.filter((message) => message.type === "actionPanelChanged")).toEqual([
      { version: 1, type: "actionPanelChanged", visible: true },
      { version: 1, type: "actionPanelChanged", visible: false },
    ]);
  });
  it("filters synonyms and copies the entire Markdown while preserving the editor selection", async () => {
    const { parent, view, messages } = await makeConnectedEditor("# Title\n\n**exact** 📝");
    view.dispatch({ selection: { anchor: 0, head: 2 } });
    const input = await openActions(parent);
    await query(input, "clipboard");
    expect(parent.querySelectorAll('[role="option"]')).toHaveLength(1);
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.find((message) => message.type === "noteAction")).toEqual({
      version: 1, type: "noteAction", action: "copyNote", revision: 1, text: "# Title\n\n**exact** 📝",
    });
    expect(view.state.selection.main.to).toBe(2);
    expect(parent.querySelector('[role="dialog"]')).toBeNull();
  });
  it("keeps unavailable file and history actions disabled, shows reasons, and handles no matches", async () => {
    const { parent, messages } = await makeConnectedEditor();
    const input = await openActions(parent);
    await query(input, "reveal");
    expect(parent.querySelector('[role="option"]')?.getAttribute("aria-disabled")).toBe("true");
    expect(parent.querySelector(".action-panel-reason")?.textContent).toContain("saved note");
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.some((message) => message.type === "noteAction")).toBe(false);
    await query(input, "no such action");
    expect(parent.querySelector(".action-panel-empty")?.textContent).toBe("No matching actions");
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true })));
    expect(parent.querySelector('[role="dialog"]')).not.toBeNull();
  });
  it("uses current native availability and routes new-note, history, and active dictation actions", async () => {
    const { parent, messages } = await makeConnectedEditor("Saved note");
    await act(async () => window.JotNative?.receive({ version: 1, type: "actionState", canNew: true, canReveal: true, canLatest: true, canBack: true, canForward: false }));
    let input = await openActions(parent);
    await query(input, "new note");
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.some((message) => message.type === "finishAndNew" && message.revision === 1)).toBe(true);
    input = await openActions(parent);
    await query(input, "back");
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.some((message) => message.type === "navigateBack")).toBe(true);
    await act(async () => window.JotNative?.receive({ version: 1, type: "dictationState", status: "recording" }));
    input = await openActions(parent);
    await query(input, "microphone");
    expect(parent.querySelector('[role="option"]')?.textContent).toContain("Finish Dictation");
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.some((message) => message.type === "finishDictation")).toBe(true);
  });
  it("finds text from the panel, steps through matches, and closes find before hiding Jot", async () => {
    const { parent, view, messages } = await makeConnectedEditor("one two one");
    const input = await openActions(parent);
    await query(input, "find");
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    // The find panel opens after the editor receives focus again.
    await act(async () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())));
    const find = parent.querySelector<HTMLInputElement>(".note-find input")!;
    expect(find).not.toBeNull();
    await query(find, "one");
    await act(async () => find.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("one");
    const first = view.state.selection.main.from;
    await act(async () => find.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(view.state.selection.main.from).not.toBe(first);
    await act(async () => window.JotNative?.receive({ version: 1, type: "escape" }));
    expect(searchPanelOpen(view.state)).toBe(false);
    expect(messages.some((message) => message.type === "hide")).toBe(false);
    await act(async () => window.JotNative?.receive({ version: 1, type: "escape" }));
    expect(messages.some((message) => message.type === "hide")).toBe(true);
  });
});

describe("note search palette", () => {
  const results = [
    { id: "note-2", title: "A recent thought", excerpt: "Body match", timestamp: 1790400000000, titleMatches: [], excerptMatches: [{ from: 0, to: 4 }] },
    { id: "note-3", title: "An older thought", excerpt: "Other text", timestamp: 1790300000000, titleMatches: [], excerptMatches: [] },
  ];
  async function showSearch(parent: HTMLElement) {
    await act(async () => window.JotNative?.receive({ version: 1, type: "showNoteSearch" }));
    const input = parent.querySelector<HTMLInputElement>(".note-search-panel input")!;
    expect(document.activeElement).toBe(input);
    return input;
  }
  it("opens via Command-P, requests recent notes, and waits for Return to open the selected result", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Keep this note");
    view.dispatch({ selection: { anchor: 2, head: 7 } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true, bubbles: true, cancelable: true })));
    const request = messages.find((message) => message.type === "searchNotes")!;
    expect(request).toMatchObject({ query: "", refresh: true });
    if (request.type !== "searchNotes") throw new Error("Missing request");
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteSearchResults", requestID: request.requestID, results }));
    expect(parent.querySelector('[aria-label="Recent notes"]')).not.toBeNull();
    const input = parent.querySelector<HTMLInputElement>(".note-search-panel input")!;
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true })));
    expect(view.state.doc.toString()).toBe("Keep this note");
    expect(view.state.selection.main.anchor).toBe(2);
    expect(view.state.selection.main.head).toBe(7);
    expect(messages.some((message) => message.type === "openNote")).toBe(false);
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.find((message) => message.type === "openNote")).toEqual({ version: 1, type: "openNote", noteID: "note-3", revision: 1 });
    // Keep the palette until native saving and loading succeed.
    expect(parent.querySelector(".note-search-panel")).not.toBeNull();
    await act(async () => window.JotNative?.receive({ version: 1, type: "loadSession", noteID: "note-3", text: "An older thought", revision: 0, selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 } }));
    expect(parent.querySelector(".note-search-panel")).toBeNull();
  });
  it("ignores stale responses and preserves the note on Escape", async () => {
    const { parent, view, messages } = await makeConnectedEditor("Original");
    const input = await showSearch(parent);
    const old = messages.find((message) => message.type === "searchNotes")!;
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "body");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const latest = messages.filter((message) => message.type === "searchNotes").at(-1)!;
    if (old.type !== "searchNotes" || latest.type !== "searchNotes") throw new Error("Missing requests");
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteSearchResults", requestID: old.requestID, results }));
    expect(parent.querySelectorAll('[role="option"]')).toHaveLength(0);
    await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(messages.some((message) => message.type === "openNote")).toBe(false);
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteSearchResults", requestID: latest.requestID, results: [results[0]] }));
    expect(parent.querySelector("mark")?.textContent).toBe("Body");
    await act(async () => window.JotNative?.receive({ version: 1, type: "escape" }));
    expect(parent.querySelector(".note-search-panel")).toBeNull();
    expect(view.state.doc.toString()).toBe("Original");
    expect(view.state.selection.main.anchor).toBe(8);
    expect(messages.some((message) => message.type === "hide" || message.type === "contentChanged")).toBe(false);
  });
  it("offers Search Notes in actions and exposes empty results and folder errors", async () => {
    const { parent, messages } = await makeConnectedEditor("Original");
    await act(async () => window.JotNative?.receive({ version: 1, type: "toggleActionPanel" }));
    await act(async () => parent.querySelector<HTMLElement>("#action-search")?.click());
    expect(parent.querySelector(".note-search-panel")).not.toBeNull();
    const request = messages.filter((message) => message.type === "searchNotes").at(-1)!;
    if (request.type !== "searchNotes") throw new Error("Missing request");
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteSearchResults", requestID: request.requestID, results: [] }));
    expect(parent.querySelector('[role="status"]')?.textContent).toBe("No notes yet");
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteSearchResults", requestID: request.requestID, results: [], message: "Choose a notes folder" }));
    expect(parent.querySelector('[role="status"]')?.textContent).toBe("Choose a notes folder");
  });
});

describe("image attachments", () => {
  it("inserts native Finder drops sequentially at the drop point", async () => {
    const { view, messages } = await makeConnectedEditor("Before After");
    vi.spyOn(view, "posAtCoords").mockReturnValue(7);
    await act(async () => window.JotNative?.receive({ version: 1, type: "beginImageFileDrop", dropID: "drop-1", count: 2, x: 40, y: 60 }));
    const first = messages.find((m) => m.type === "importDroppedFile")!;
    if (first.type !== "importDroppedFile") throw new Error("Missing Finder import request");
    expect(first.dropID).toBe("drop-1");
    await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: first.requestID,
      path: "attachments/n/first.png", baseURL: "jot://attachment/" }));
    const requests = messages.filter((m) => m.type === "importDroppedFile");
    expect(requests).toHaveLength(2);
    const second = requests[1];
    if (second.type !== "importDroppedFile") throw new Error("Missing second Finder import request");
    await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: second.requestID,
      path: "attachments/n/second.png", baseURL: "jot://attachment/" }));
    expect(view.state.doc.toString()).toContain("![Image](attachments/n/first.png)");
    expect(view.state.doc.toString()).toContain("![Image](attachments/n/second.png)");
    expect(view.state.doc.toString()).toContain("Before ");
    expect(view.state.doc.toString()).toContain("After");
  });

  it("accepts an image drop at the drop position and ignores unsupported files", async () => {
    const { view, parent, messages } = await makeConnectedEditor("Before After");
    vi.spyOn(view, "posAtCoords").mockReturnValue(7);
    const composer = parent.querySelector<HTMLElement>(".composer")!;
    const dragEvent = (type: string, files: File[]) => {
      const event = new Event(type, { bubbles: true, cancelable: true });
      Object.defineProperties(event, {
        dataTransfer: { value: { types: ["Files"], files, dropEffect: "none" } },
        clientX: { value: 40 },
        clientY: { value: 60 },
      });
      return event;
    };
    const image = new File([new Uint8Array([137, 80, 78, 71])], "photo.png", { type: "image/png" });
    await act(async () => {
      const over = dragEvent("dragover", [image]);
      composer.dispatchEvent(over);
      expect(over.defaultPrevented).toBe(true);
      expect(composer.classList.contains("is-image-dragging")).toBe(true);
      const drop = dragEvent("drop", [image]);
      composer.dispatchEvent(drop);
      expect(drop.defaultPrevented).toBe(true);
    });
    await vi.waitFor(() => expect(messages.some((m) => m.type === "importDroppedImage")).toBe(true));
    const request = messages.find((m) => m.type === "importDroppedImage")!;
    if (request.type !== "importDroppedImage") throw new Error("Missing image drop request");
    expect(request.data).toBe("iVBORw==");
    await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: request.requestID,
      path: "attachments/n/photo.png", baseURL: "jot://attachment/" }));
    expect(view.state.doc.toString()).toContain("Before \n\n![Image](attachments/n/photo.png)\n\nAfter");
    const unsupported = new File(["plain"], "notes.txt", { type: "text/plain" });
    await act(async () => composer.dispatchEvent(dragEvent("drop", [unsupported])));
    expect(messages.filter((m) => m.type === "importDroppedImage")).toHaveLength(1);
    expect(parent.textContent).toContain("Other file types are not supported yet");
  });

  it("commits an image-only jot as portable Markdown, renders a preview, and undoes as one edit", async () => {
    const { view, parent, messages } = await makeConnectedEditor();
    await act(async () => window.JotNative?.receive({ version: 1, type: "beginImagePaste" }));
    const request = messages.find((m) => m.type === "importClipboardImage");
    if (request?.type !== "importClipboardImage") throw new Error("No import request");
    await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: request.requestID,
      path: "attachments/n/screenshot.png", baseURL: "jot://attachment/2026/09/27/" }));
    expect(view.state.doc.toString()).toBe("![Image](attachments/n/screenshot.png)\n\n");
    expect(parent.querySelector(".cm-attachment-image img")?.getAttribute("src")).toBe("jot://attachment/2026/09/27/attachments/n/screenshot.png");
    await act(async () => { undo(view); });
    expect(view.state.doc.toString()).toBe("");
    await act(async () => { redo(view); });
    expect(parent.querySelector(".cm-attachment-image")).not.toBeNull();
  });

  it("maps the insertion point while typing and keeps image edits out of preferred window height", async () => {
    const { view, parent, messages } = await makeConnectedEditor("Before\n\nAfter");
    await act(async () => { view.dispatch({ selection: { anchor: 6 } }); window.JotNative?.receive({ version: 1, type: "beginImagePaste" }); });
    const pending = view.state.field(pendingImageImport)!;
    await act(async () => view.dispatch({ changes: { from: 0, insert: "New " } }));
    expect(view.state.field(pendingImageImport)?.from).toBe(10);
    messages.length = 0;
    await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: pending.id,
      path: "attachments/n/screenshot.png", baseURL: "jot://attachment/2026/09/27/" }));
    await new Promise((resolve) => requestAnimationFrame(resolve));
    expect(messages.some((m) => m.type === "preferredHeightChanged")).toBe(false);
    expect(view.state.doc.toString()).toContain("New Before\n\n![Image]");
    const button = parent.querySelector<HTMLButtonElement>(".cm-attachment-image")!;
    button.querySelector("img")!.dispatchEvent(new Event("load"));
    await act(async () => button.click());
    expect(messages).toContainEqual({ version: 1, type: "previewImage", path: "2026/09/27/attachments/n/screenshot.png" });
  });

  it("rejects late import replies after navigating and leaves text unchanged on failure", async () => {
    const { view } = await makeConnectedEditor("Keep this");
    await act(async () => window.JotNative?.receive({ version: 1, type: "beginImagePaste" }));
    const id = view.state.field(pendingImageImport)!.id;
    await act(async () => window.JotNative?.receive({ version: 1, type: "imageImportFailed", requestID: id, message: "Retry paste" }));
    expect(view.state.doc.toString()).toBe("Keep this");
    expect(view.state.field(pendingImageImport)).toBeNull();
    await act(async () => {
      window.JotNative?.receive({ version: 1, type: "loadSession", text: "Other note", revision: 0, noteID: "other",
        selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 } });
      window.JotNative?.receive({ version: 1, type: "imageImported", requestID: id, path: "attachments/a.png", baseURL: "jot://attachment/" });
    });
    expect(view.state.doc.toString()).toBe("Other note");
  });

  it("rebases recovery-copy images to the new dated folder and keeps that URL on reopen", async () => {
    const text = "![Image](attachments/original/image.png)\n\n";
    const { view, parent } = await makeConnectedEditor(text);
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteAllocated",
      noteID: "original", path: "/Jots/2026/09/27/original.md", revision: 1,
      baseURL: "jot://attachment/2026/09/27/" }));
    expect(parent.querySelector(".cm-attachment-image img")?.getAttribute("src")).toBe(
      "jot://attachment/2026/09/27/attachments/original/image.png");
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteAllocated",
      noteID: "copy", path: "/Jots/2026/10/01/copy.md", revision: 1,
      baseURL: "jot://attachment/2026/10/01/" }));
    expect(view.state.doc.toString()).toBe(text);
    const expected = "jot://attachment/2026/10/01/attachments/original/image.png";
    expect(parent.querySelector(".cm-attachment-image img")?.getAttribute("src")).toBe(expected);
    await act(async () => window.JotNative?.receive({ version: 1, type: "loadSession",
      noteID: "copy", text, revision: 1, selection: { anchor: 0, head: 0 },
      viewport: { scrollTop: 0 }, baseURL: "jot://attachment/2026/10/01/" }));
    expect(parent.querySelector(".cm-attachment-image img")?.getAttribute("src")).toBe(expected);
    expect(view.state.doc.toString()).toBe(text);
  });

  it("keeps the image visible at the caret, restores it after deleting and undoing, and reports a missing file", async () => {
    const text = "![Image](attachments/n/image.png)\n\n";
    const { view, parent } = await makeConnectedEditor(text);
    await act(async () => window.JotNative?.receive({ version: 1, type: "noteAllocated", noteID: "note-1", path: "/Jots/n.md", revision: 1, baseURL: "jot://attachment/" }));
    await act(async () => view.dispatch({ selection: { anchor: 10 } }));
    expect(parent.querySelector(".cm-attachment-image")).not.toBeNull();
    await act(async () => view.dispatch({ changes: { from: 0, to: text.indexOf("\n") } }));
    expect(parent.querySelector(".cm-attachment-image")).toBeNull();
    await act(async () => { undo(view); });
    const image = parent.querySelector<HTMLImageElement>(".cm-attachment-image img")!;
    image.dispatchEvent(new Event("error"));
    expect(parent.textContent).toContain("Image unavailable");
    const retry = parent.querySelector<HTMLButtonElement>(".cm-attachment-image")!;
    expect(retry.disabled).toBe(false);
    retry.click();
    expect(image.isConnected).toBe(true);
    expect(image.src).toContain("retry=1");
    expect(parent.textContent).toContain("Loading image");
    image.dispatchEvent(new Event("load"));
    expect(retry.getAttribute("aria-label")).toBe("Preview Image");
  });
});

it("starts a fresh undo history when switching notes after an image paste", async () => {
  const { view } = await makeConnectedEditor();
  await act(async () => window.JotNative?.receive({ version: 1, type: "beginImagePaste" }));
  const id = view.state.field(pendingImageImport)!.id;
  await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: id,
    path: "attachments/n/image.png", baseURL: "jot://attachment/" }));
  await act(async () => window.JotNative?.receive({ version: 1, type: "loadSession", text: "Other note", revision: 0,
    noteID: "other", selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 } }));
  expect(undo(view)).toBe(false);
  expect(view.state.doc.toString()).toBe("Other note");
});

it("Select All and Backspace remove image source and undo restores the image", async () => {
  const { view, parent } = await makeConnectedEditor();
  await act(async () => window.JotNative?.receive({ version: 1, type: "beginImagePaste" }));
  const id = view.state.field(pendingImageImport)!.id;
  await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: id,
    path: "attachments/n/image.png", baseURL: "jot://attachment/" }));
  await act(async () => {
    window.JotNative?.receive({ version: 1, type: "selectAll" });
    view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true, cancelable: true }));
  });
  expect(view.state.doc.toString()).toBe("");
  expect(parent.querySelector(".cm-attachment-image")).toBeNull();
  await act(async () => { undo(view); });
  expect(parent.querySelector(".cm-attachment-image")).not.toBeNull();
});

it("moves the caret before and after an image using ordinary document navigation", async () => {
  const { view } = await makeConnectedEditor();
  await act(async () => window.JotNative?.receive({ version: 1, type: "beginImagePaste" }));
  const id = view.state.field(pendingImageImport)!.id;
  await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: id,
    path: "attachments/n/image.png", baseURL: "jot://attachment/" }));
  await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Home", code: "Home", ctrlKey: true, bubbles: true, cancelable: true })));
  expect(view.state.selection.main.head).toBe(0);
  await act(async () => view.dispatch({ changes: { from: 0, insert: "Above\n\n" } }));
  expect(view.state.doc.toString()).toMatch(/^Above\n\n!\[Image\]/);
});

it("places the caret underneath an image pasted between existing paragraphs", async () => {
  const { view } = await makeConnectedEditor("Before\n\nAfter");
  await act(async () => { view.dispatch({ selection: { anchor: 6 } }); window.JotNative?.receive({ version: 1, type: "beginImagePaste" }); });
  const id = view.state.field(pendingImageImport)!.id;
  await act(async () => window.JotNative?.receive({ version: 1, type: "imageImported", requestID: id,
    path: "attachments/n/image.png", baseURL: "jot://attachment/" }));
  await act(async () => view.dispatch(view.state.replaceSelection("Writing below. ")));
  expect(view.state.doc.toString()).toBe("Before\n\n![Image](attachments/n/image.png)\n\nWriting below. After");
});

describe("starting a dash list after text", () => {
  it("keeps paragraph styling throughout typing, undo, and redo", () => {
    const view = makeView("Hello");
    view.dispatch({ selection: { anchor: 5 } });
    for (const text of ["\n", "-", " ", "world"]) {
      view.dispatch({ ...view.state.replaceSelection(text), userEvent: "input.type" });
      expect(syntaxTree(view.state).toString()).not.toContain("SetextHeading");
      expect(view.contentDOM.querySelector(".cm-line")?.querySelector("span")).toBeNull();
    }
    expect(view.state.doc.toString()).toBe("Hello\n- world");
    undo(view);
    expect(syntaxTree(view.state).toString()).not.toContain("SetextHeading");
    redo(view);
    expect(syntaxTree(view.state).toString()).not.toContain("SetextHeading");
  });

  it("retains explicit headings and horizontal rules", () => {
    const view = makeView("## Heading\n\n---");
    expect(syntaxTree(view.state).toString()).toContain("ATXHeading2");
    expect(syntaxTree(view.state).toString()).toContain("HorizontalRule");
  });
});

describe("mixed numbered and bullet lists", () => {
  it.each([
    ["1. parent\n2. child", "1. parent\n     2. child"],
    ["1. parent\n- child", "1. parent\n     - child"],
    ["- parent\n1. child", "- parent\n     1. child"],
    ["1. parent\n   - first\n   1. child", "1. parent\n   - first\n        1. child"],
    ["- parent\n  1. first\n  - child", "- parent\n  1. first\n       - child"],
    ["123456789. parent\n- child", "123456789. parent\n           - child"],
  ])("nests and outdents %s with Tab", async (original, nested) => {
    const { view } = await makeConnectedEditor(original);
    const press = async (shiftKey = false) => act(async () => {
      view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", shiftKey, bubbles: true, cancelable: true }));
    });
    await press();
    expect(view.state.doc.toString()).toBe(nested);
    expect(syntaxTree(view.state).toString()).toMatch(/ListItem.*(?:BulletList|OrderedList).*ListItem/);
    await press();
    expect(view.state.doc.toString()).toBe(nested);
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe(original);
    expect(redo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe(nested);
    await press(true);
    expect(view.state.doc.toString()).toBe(original);
  });

  it("moves numbered parents with mixed descendants", async () => {
    const original = "1. first\n2. second\n   - child\n     1. grandchild\n3. third";
    const { view } = await makeConnectedEditor(original);
    view.dispatch({ selection: { anchor: original.indexOf("second") } });
    await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", code: "Tab", bubbles: true })));
    expect(view.state.doc.toString()).toBe("1. first\n     2. second\n        - child\n          1. grandchild\n3. third");
  });
});

it.each([
  ["1. parent\n     - child", "1. parent\n     - child\n     - "],
  ["- parent\n     1. child", "- parent\n     1. child\n     2. "],
])("continues the nested marker type with Enter in %s", async (source, expected) => {
  const { view } = await makeConnectedEditor(source);
  await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true })));
  expect(view.state.doc.toString()).toBe(expected);
});

describe("opening presented links", () => {
  it.each([
    ["[Example](https://example.com)", "https://example.com/"],
    ["[**Example**](https://example.com/a?q=1 \"Title\")", "https://example.com/a?q=1"],
    ["<https://example.com>", "https://example.com/"],
    ["https://example.com", "https://example.com/"],
  ])("opens %s without moving the caret or changing Markdown", async (link, url) => {
    const source = `${link}\nplain`;
    const { view, messages } = await makeConnectedEditor(source);
    const target = view.dom.querySelector<HTMLElement>(".cm-browser-link");
    expect(target).not.toBeNull();
    const position = view.state.selection.main.head;
    const mouse = new MouseEvent("mousedown", { button: 0, bubbles: true, cancelable: true });
    await act(async () => {
      target!.dispatchEvent(mouse);
      target!.dispatchEvent(new MouseEvent("click", { button: 0, bubbles: true, cancelable: true }));
    });
    expect(mouse.defaultPrevented).toBe(true);
    expect(view.state.selection.main.head).toBe(position);
    expect(view.state.doc.toString()).toBe(source);
    expect(messages).toContainEqual({ version: 1, type: "openBrowserURL", url });
    view.dispatch({ selection: { anchor: 0 } });
    await act(async () => {
      view.focus();
      view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", code: "ArrowRight", bubbles: true, cancelable: true }));
    });
    expect(view.state.selection.main.head).toBe(1);
    expect(view.dom.querySelector(".cm-browser-link")).toBeNull();
    expect(view.contentDOM.textContent).toContain(link.replaceAll("**", ""));
  });

  it("keeps unsafe destinations, images, and code from opening a browser", async () => {
    const { view } = await makeConnectedEditor('[bad](javascript:alert) [file](file:///tmp/private) ![image](https://example.com/a.png) `https://example.com`\nplain');
    expect(view.dom.querySelector(".cm-browser-link")).toBeNull();
  });
});

it.each(["n", "Enter"])("finishes the current revision with Command-%s", async key => {
  const { view, messages } = await makeConnectedEditor("Saved note");
  const modifier = /Mac/.test(navigator.platform) ? { metaKey: true } : { ctrlKey: true };
  await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key, ...modifier, bubbles: true, cancelable: true })));
  expect(messages.filter(message => message.type === "finishAndNew")).toEqual([
    { version: 1, type: "finishAndNew", revision: 1 },
  ]);
  expect(view.state.doc.toString()).toBe("Saved note");
});


it("locks native formatting during a notebook transfer and enables it afterward", async () => {
  const { view, messages } = await makeConnectedEditor("a thought");
  await act(async () => window.JotNative?.receive({ version: 1, type: "setEditingEnabled", enabled: false }));
  expect(view.state.readOnly).toBe(true);
  expect(view.contentDOM.getAttribute("contenteditable")).toBe("false");
  await act(async () => window.JotNative?.receive({ version: 1, type: "toggleFormat", format: "bold" }));
  expect(view.state.doc.toString()).toBe("a thought");
  await act(async () => window.JotNative?.receive({ version: 1, type: "beginImagePaste" }));
  expect(messages.some((message) => message.type === "importClipboardImage")).toBe(false);
  await act(async () => window.JotNative?.receive({ version: 1, type: "setEditingEnabled", enabled: true }));
  expect(view.state.readOnly).toBe(false);
  expect(view.contentDOM.getAttribute("contenteditable")).toBe("true");
  await act(async () => window.JotNative?.receive({ version: 1, type: "toggleFormat", format: "bold" }));
  expect(view.state.doc.toString()).not.toBe("a thought");
});

it("captures the complete source and caret while locking reconciliation", async () => {
  const { view } = await makeConnectedEditor("# A heading\n\n**A thought**");
  await act(async () => view.dispatch({ changes: { from: view.state.doc.length, insert: " just typed" }, selection: { anchor: 5, head: 9 } }));
  const snapshot = window.JotNative?.lockAndSnapshot();
  expect(snapshot?.text).toBe("# A heading\n\n**A thought** just typed");
  expect(snapshot?.selection).toEqual({ anchor: 5, head: 9 });
  expect(snapshot?.revision).toBeGreaterThan(1);
  expect(view.state.readOnly).toBe(true);
  expect(view.contentDOM.getAttribute("contenteditable")).toBe("false");
});

it("routes phone palette shortcuts into the native library", async () => {
  document.documentElement.classList.add("ios");
  try {
    const { view, parent, messages } = await makeConnectedEditor("Phone thought");
    for (const key of ["p", "k"]) {
      await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key, metaKey: true, bubbles: true, cancelable: true })));
    }
    expect(messages.filter(message => message.type === "showLibrary")).toHaveLength(2);
    expect(messages.some(message => message.type === "searchNotes")).toBe(false);
    expect(parent.querySelector(".action-panel")).toBeNull();
    expect(view.state.doc.toString()).toBe("Phone thought");
  } finally { document.documentElement.classList.remove("ios"); }
});

it("identifies phone document callbacks and locked snapshots by loaded session", async () => {
  const { view, messages } = await makeConnectedEditor("Old thought");
  await act(async () => window.JotNative?.receive({ version: 1, type: "loadSession", sessionID: "phone-new",
    text: "New thought", revision: 0, selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 } }));
  await act(async () => view.dispatch({ changes: { from: view.state.doc.length, insert: " captured" } }));
  const content = messages.filter(message => message.type === "contentChanged").at(-1);
  expect(content).toMatchObject({ sessionID: "phone-new", text: "New thought captured" });
  expect(window.JotNative?.lockAndSnapshot().sessionID).toBe("phone-new");
  const modifier = /Mac/.test(navigator.platform) ? { metaKey: true } : { ctrlKey: true };
  await act(async () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "n", ...modifier, bubbles: true, cancelable: true })));
  expect(messages.filter(message => message.type === "finishAndNew").at(-1)).toMatchObject({ sessionID: "phone-new" });
});

describe("phone list controls", () => {
  it("creates bullets and round trips indentation through native controls", async () => {
    const { view, messages } = await makeConnectedEditor("parent\nchild");
    view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } });
    window.JotNative?.receive({ version: 1, type: "setTextStyle", style: "bullet" });
    expect(view.state.doc.toString()).toBe("- parent\n- child");
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    window.JotNative?.receive({ version: 1, type: "changeListIndent", direction: "in" });
    expect(view.state.doc.toString()).toBe("- parent\n     - child");
    window.JotNative?.receive({ version: 1, type: "changeListIndent", direction: "out" });
    expect(view.state.doc.toString()).toBe("- parent\n- child");
    expect(messages.filter(message => message.type === "contentChanged").at(-1)).toMatchObject({ text: "- parent\n- child" });
  });
  it("ignores list controls during a locked note transition", async () => {
    const { view } = await makeConnectedEditor("- parent\n- child");
    window.JotNative?.receive({ version: 1, type: "setEditingEnabled", enabled: false });
    for (const message of [
      { version: 1, type: "setTextStyle", style: "bullet" },
      { version: 1, type: "changeListIndent", direction: "in" },
      { version: 1, type: "changeListIndent", direction: "out" },
    ] as const) window.JotNative?.receive(message);
    expect(view.state.doc.toString()).toBe("- parent\n- child");
  });
});


it("loads a paging preview without stealing focus, and preserves default writing focus", async () => {
  const { view } = await makeConnectedEditor("Current jot");
  const focus = vi.spyOn(view, "focus");
  await act(async () => window.JotNative?.receive({
    version: 1, type: "loadSession", focus: false, text: "Next jot", noteID: "next", revision: 0,
    selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 },
  }));
  await act(async () => { await new Promise(resolve => requestAnimationFrame(resolve)); });
  expect(view.state.doc.toString()).toBe("Next jot");
  expect(focus).not.toHaveBeenCalled();
  await act(async () => window.JotNative?.receive({
    version: 1, type: "loadSession", text: "Writing jot", noteID: "writing", revision: 0,
    selection: { anchor: 0, head: 0 }, viewport: { scrollTop: 0 },
  }));
  await act(async () => { await new Promise(resolve => requestAnimationFrame(resolve)); });
  expect(focus).toHaveBeenCalled();
});


it("locks a page for saving while retaining its editable focus surface", async () => {
  const { view } = await makeConnectedEditor("In progress");
  view.focus();
  const snapshot = window.JotNative?.lockAndSnapshot(true);
  expect(snapshot?.text).toBe("In progress");
  expect(view.state.readOnly).toBe(true);
  expect(view.contentDOM.getAttribute("contenteditable")).toBe("true");
  expect(view.hasFocus).toBe(true);
});
