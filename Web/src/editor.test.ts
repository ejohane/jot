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
import { toggleInlineFormat } from "./formatting";

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
    expect(messages.at(-1)).toEqual({ version: 1, type: "openNote", noteID: "note-2", revision: 1 });
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
    expect(messages.at(-1)).toMatchObject({ type: "openNote", noteID: "note-3" });
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
