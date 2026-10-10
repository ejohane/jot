import { deleteCharBackward, history, redo, undo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, it } from "vitest";
import { toggleInlineFormat } from "./formatting";
import { emphasisSpans, mobileFormatActive, mobileInlineEditing, moveMobileCursor, resetMobileInline } from "./mobileInline";
import { markdownPresentation } from "./presentation";

const views: EditorView[] = [];
Object.defineProperties(Range.prototype, {
  getClientRects: { configurable: true, value: () => [] },
  getBoundingClientRect: { configurable: true, value: () => new DOMRect() },
});
afterEach(() => { views.forEach(view => view.destroy()); views.length = 0; document.body.replaceChildren(); });
function editor(doc = "", anchor = doc.length, head = anchor) {
  const parent = document.createElement("div"); document.body.append(parent);
  const view = new EditorView({ parent, state: EditorState.create({ doc, selection: { anchor, head }, extensions: [markdown(), history(), mobileInlineEditing(), markdownPresentation] }) });
  views.push(view); return view;
}
function type(view: EditorView, text: string, userEvent = "input.type") {
  const selection = view.state.selection.main;
  view.dispatch({ changes: { from: selection.from, to: selection.to, insert: text }, selection: { anchor: selection.from + text.length }, userEvent });
}
const source = (view: EditorView) => view.state.doc.toString();
const visible = (view: EditorView) => view.contentDOM.textContent;
function styleOf(view: EditorView, word: string) {
  const pos = source(view).indexOf(word);
  return emphasisSpans(view.state).reduce((bits, span) => pos >= span.start && pos < span.end ? bits | span.bit : bits, 0);
}

describe("mobile source-preserving inline editing", () => {
  it("hides complete emphasis while editing, keeps incomplete and literal syntax", () => {
    const text = "**bold** *italic* unfinished **word \\*literal\\*";
    const view = editor(text, 3);
    expect(visible(view)).toContain("bold italic unfinished **word");
    expect(source(view)).toBe(text);
    view.dispatch({ selection: { anchor: 2, head: 6 } });
    expect(visible(view)).not.toContain("**bold**");
  });
  it("toggles upcoming typing without allocating empty Markdown wrappers", () => {
    const view = editor(); toggleInlineFormat(view, "bold");
    expect(source(view)).toBe(""); expect(mobileFormatActive(view.state, "bold")).toBe(true);
    type(view, "hello"); expect(source(view)).toBe("**hello**");
    expect(view.state.selection.main.head).toBe(7);
    type(view, " world"); expect(source(view)).toBe("**hello world**");
    toggleInlineFormat(view, "bold"); type(view, " plain");
    expect(source(view)).toBe("**hello world** plain");
  });
  it("converts completed typed Markdown and undoes only presentation first", async () => {
    const view = editor();
    for (const char of "**hello**") { type(view, char); await Promise.resolve(); }
    expect(visible(view)).toBe("hello"); expect(source(view)).toBe("**hello**");
    expect(view.state.selection.main.head).toBe(7);
    expect(undo(view)).toBe(true); expect(source(view)).toBe("**hello**");
    expect(visible(view)).toBe("**hello**");
    expect(redo(view)).toBe(true); expect(visible(view)).toBe("hello");
  });
  it("edits inside formatting and continues at its outside boundary", () => {
    const view = editor("**hello**", 4); type(view, "X");
    expect(source(view)).toBe("**heXllo**"); expect(visible(view)).toBe("heXllo");
    view.dispatch({ selection: { anchor: source(view).length } }); type(view, "!");
    expect(source(view)).toBe("**heXllo!**");
  });
  it("starts a new paragraph without inline formatting", () => {
    const view = editor("**hello**", 7); type(view, "\n"); type(view, "world");
    expect(source(view)).toBe("**hello**\nworld");
  });
  it("removes selected formatting in one undo step while preserving the rest", () => {
    const view = editor("before **hello world** after", 2 + 7, 2 + 12);
    toggleInlineFormat(view, "bold");
    expect(source(view)).toBe("before hello **world** after");
    undo(view); expect(source(view)).toBe("before **hello world** after");
    redo(view); expect(source(view)).toBe("before hello **world** after");
  });
  it("applies mixed selections throughout, then removes throughout", () => {
    const view = editor("**one** two", 2, 11);
    expect(mobileFormatActive(view.state, "bold")).toBe(false);
    toggleInlineFormat(view, "bold"); expect(source(view)).toBe("**one two**");
    expect(mobileFormatActive(view.state, "bold")).toBe(true);
    toggleInlineFormat(view, "bold"); expect(source(view)).toBe("one two");
  });
  it("preserves reversed selections and unrelated Markdown byte for byte", () => {
    const original = "# Heading\n\n[link](https://example.com)\n\n__hello world__\n\n```text\n**raw**\n```";
    const start = original.indexOf("hello"), end = start + 5;
    const view = editor(original, end, start); toggleInlineFormat(view, "italic");
    expect(source(view).slice(0, start - 2)).toBe(original.slice(0, start - 2));
    expect(source(view).slice(source(view).indexOf("\n\n```"))).toBe(original.slice(original.indexOf("\n\n```")));
    expect(view.state.selection.main.anchor).toBeGreaterThan(view.state.selection.main.head);
    expect(styleOf(view, "hello")).toBe(3); expect(styleOf(view, "world")).toBe(1);
  });
  it("keeps bold when italic is toggled off in combined text", () => {
    const view = editor("***hello***", 3, 8); toggleInlineFormat(view, "italic");
    expect(source(view)).toBe("**hello**"); expect(styleOf(view, "hello")).toBe(1);
  });
  it("deletes the last visible character without orphan delimiters", () => {
    const view = editor("**x**", 3); deleteCharBackward(view);
    expect(source(view)).toBe(""); expect(visible(view)).toBe("");
    type(view, "y"); expect(source(view)).toBe("**y**");
  });
  it("deletes the visible character when native Backspace targets a closing marker", () => {
    const view = editor("**hi**");
    view.dispatch({ changes: { from: 5, to: 6 }, selection: { anchor: 5 }, userEvent: "delete.backward" });
    expect(source(view)).toBe("**h**");
  });
  it("handles emoji deletion at hidden boundaries", () => {
    const view = editor("**😀**");
    view.dispatch({ changes: { from: 5, to: 6 }, selection: { anchor: 5 }, userEvent: "delete.backward" });
    expect(source(view)).toBe("");
  });
  it("does not reserialize notes on load or formatting elsewhere", () => {
    const text = "__keep__  \n**also**\n";
    const view = editor(text, text.length); type(view, "plain");
    expect(source(view)).toBe(text + "plain");
  });
});

it.each([
  ["***abc***", 3, 4, "bold", [2, 3, 3]],
  ["***abc***", 4, 5, "bold", [3, 2, 3]],
  ["***abc***", 5, 6, "bold", [3, 3, 2]],
  ["***abc***", 4, 5, "italic", [3, 1, 3]],
  ["abc", 1, 2, "italic", [0, 2, 0]],
  ["**abc**", 3, 4, "italic", [1, 3, 1]],
] as const)("preserves adjacent character styles in %s at %i..%i (%s)", (text, start, end, format, expected) => {
  const view = editor(text, start, end); toggleInlineFormat(view, format);
  expect([styleOf(view, "a"), styleOf(view, "b"), styleOf(view, "c")], source(view)).toEqual(expected);
});

it("does not delete the first visible character when Backspace targets opening syntax", () => {
  const view = editor("**hi**", 2);
  view.dispatch({ changes: { from: 1, to: 2 }, selection: { anchor: 1 }, userEvent: "delete.backward" });
  expect(source(view)).toBe("**hi**");
});

it("Backspace at an opening boundary deletes the preceding visible text", () => {
  const view = editor("a **hi**", 4);
  view.dispatch({ changes: { from: 3, to: 4 }, selection: { anchor: 3 }, userEvent: "delete.backward" });
  expect(source(view)).toBe("a**hi**");
});

it("preserves a crossing bold/italic boundary", () => {
  const view = editor("**ab**c", 3, 7); toggleInlineFormat(view, "italic");
  expect([styleOf(view, "a"), styleOf(view, "b"), styleOf(view, "c")], source(view)).toEqual([1, 3, 2]);
});

it("continues combined typing when bold is switched off", () => {
  const view = editor(); toggleInlineFormat(view, "bold"); toggleInlineFormat(view, "italic"); type(view, "a");
  toggleInlineFormat(view, "bold"); type(view, "b");
  expect([styleOf(view, "a"), styleOf(view, "b")], source(view)).toEqual([3, 2]);
});

it("preserves every combination of adjacent bold and italic characters", () => {
  for (let a = 0; a < 4; a++) for (let b = 0; b < 4; b++) for (let c = 0; c < 4; c++) {
    const view = editor("abc");
    for (const [index, target] of [a, b, c].entries()) {
      const char = "abc"[index];
      for (const [bit, format] of [[1, "bold"], [2, "italic"]] as const) {
        if (!(target & bit)) continue;
        const from = source(view).indexOf(char);
        view.dispatch({ selection: { anchor: from, head: from + 1 } });
        toggleInlineFormat(view, format);
      }
    }
    expect([styleOf(view, "a"), styleOf(view, "b"), styleOf(view, "c")], `${a},${b},${c}: ${source(view)}`).toEqual([a, b, c]);
  }
});

it("formats committed IME input and undoes it as a single composition", async () => {
  const view = editor(); toggleInlineFormat(view, "bold");
  view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
  type(view, "k", "input.type.compose");
  view.dispatch({ changes: { from: 0, to: 1, insert: "かなé" }, selection: { anchor: 3 }, userEvent: "input.type.compose" });
  expect(source(view)).toBe("かなé");
  view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "かなé" }));
  await Promise.resolve();
  expect(source(view)).toBe("**かなé**"); expect(visible(view)).toBe("かなé");
  undo(view); expect(source(view)).toBe("");
  redo(view); expect(source(view)).toBe("**かなé**");
});

it("waits for composition to commit before hiding newly completed syntax", async () => {
  const view = editor("**hello", 7);
  view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
  type(view, "**", "input.type.compose");
  expect(visible(view)).toBe("**hello**");
  view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "**" }));
  await Promise.resolve();
  expect(visible(view)).toBe("hello"); expect(source(view)).toBe("**hello**");
});

it("discards a queued composition commit when another note loads", async () => {
  const view = editor(); toggleInlineFormat(view, "bold");
  view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
  type(view, "かな", "input.type.compose");
  view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
  view.dispatch({ effects: resetMobileInline.of(), changes: { from: 0, to: view.state.doc.length, insert: "next note" }, selection: { anchor: 9 } });
  await Promise.resolve();
  expect(source(view)).toBe("next note");
  expect(mobileFormatActive(view.state, "bold")).toBe(false);
});

it.each(["*hello*", "_hello_", "__hello__", "***hello***"])("converts character-by-character %s without losing syntax", async text => {
  const view = editor();
  for (const char of text) { type(view, char); await Promise.resolve(); }
  expect(visible(view)).toBe("hello");
  expect(styleOf(view, "hello")).toBe(text.startsWith("***") ? 3 : text.startsWith("**") || text.startsWith("__") ? 1 : 2);
});

it("lets a user edit literal source after undoing a conversion", async () => {
  const view = editor();
  for (const char of "**hello**") { type(view, char); await Promise.resolve(); }
  undo(view); expect(visible(view)).toBe("**hello**");
  view.dispatch({ selection: { anchor: 4 } }); type(view, "X");
  expect(visible(view)).toBe("**heXllo**");
});

it("preserves heading/list/link structure and code when formatting a multi-block selection", () => {
  const view = editor("# Heading\n\n- Item\n\n[link](https://example.com)\n\n```md\n**literal**\n```", 0, 69);
  toggleInlineFormat(view, "bold");
  expect(source(view)).toContain("# **Heading**");
  expect(source(view)).toContain("- **Item**");
  expect(source(view)).toContain("[**link**](https://example.com)");
  expect(source(view)).toContain("```md\n**literal**\n```");
});

it("moves by visible graphemes across combined formatting without invisible stops", () => {
  const view = editor("a***bc***d", 4);
  moveMobileCursor(view, false); expect(view.state.selection.main.head).toBe(0);
  moveMobileCursor(view, true); expect(view.state.selection.main.head).toBe(4);
  moveMobileCursor(view, true, true); expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("b");
  moveMobileCursor(view, true, true); expect(view.state.selection.main.head).toBe(9);
  moveMobileCursor(view, true); expect(view.state.selection.main.empty).toBe(true);
});

it("moves over a multi-code-point emoji in one step", () => {
  const view = editor("**👩🏽‍💻x**", 2);
  moveMobileCursor(view, true);
  expect(view.state.selection.main.head).toBe(9);
  moveMobileCursor(view, false); expect(view.state.selection.main.head).toBe(2);
});

it("edits a long formatted span without changing its surrounding source", () => {
  const content = "word ".repeat(10000).trim();
  const view = editor(`prefix **${content}** suffix`, 9 + content.length);
  type(view, "!");
  expect(source(view)).toBe(`prefix **${content}!** suffix`);
});
