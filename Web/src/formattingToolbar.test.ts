import { history, undo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView, showTooltip, type Tooltip } from "@codemirror/view";
import { GFM } from "@lezer/markdown";
import { afterEach, expect, it } from "vitest";
import { formattingToolbar } from "./formattingToolbar";
import { applyLink, removeLink, selectedLink, setTextStyle, toggleInlineCode } from "./selectionFormatting";

const views: EditorView[] = [];
const getTooltips = (view: EditorView) => view.state.facet(showTooltip).filter((tip): tip is Tooltip => tip !== null);
Object.defineProperties(Range.prototype, {
  getClientRects: { configurable: true, value: () => [] },
  getBoundingClientRect: { configurable: true, value: () => new DOMRect() },
});
afterEach(() => { views.forEach((view) => view.destroy()); views.length = 0; document.body.replaceChildren(); });
function editor(doc: string, anchor = 0, head = doc.length) {
  const parent = document.createElement("div"); document.body.append(parent);
  const view = new EditorView({ parent, state: EditorState.create({ doc, extensions: [markdown({ extensions: GFM }), history(), formattingToolbar] }) });
  views.push(view);
  view.focus(); view.dispatch({ selection: { anchor, head } });
  return view;
}

it("shows only for nonblank selections and dismisses with Escape without changing text", () => {
  const view = editor("some text");
  expect(getTooltips(view).length).toBe(1);
  view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  expect(getTooltips(view).length).toBe(0);
  expect(view.state.doc.toString()).toBe("some text");
  view.dispatch({ selection: { anchor: 0 } });
  expect(getTooltips(view).length).toBe(0);
  view.dispatch({ selection: { anchor: 4, head: 5 } });
  expect(getTooltips(view).length).toBe(0);
});

it("keeps selected text through toolbar bold, italic, and undo", () => {
  const view = editor("some text", 0, 4);
  const tooltip = getTooltips(view)[0].create(view).dom;
  tooltip.querySelector<HTMLButtonElement>(".formatting-bold")!.click();
  expect(view.state.doc.toString()).toBe("**some** text");
  expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("some");
  getTooltips(view)[0].create(view).dom.querySelector<HTMLButtonElement>(".formatting-italic")!.click();
  expect(view.state.doc.toString()).toBe("***some*** text");
  undo(view); expect(view.state.doc.toString()).toBe("**some** text");
});

it("changes selected lines and excludes a next line selected only at its boundary", () => {
  const view = editor("- one\n- two\nthree", 0, 12);
  setTextStyle(view, "number");
  expect(view.state.doc.toString()).toBe("1. one\n2. two\nthree");
  undo(view); expect(view.state.doc.toString()).toBe("- one\n- two\nthree");
});

it("retains reversed selections and indentation when changing headings to text", () => {
  const view = editor("  ## Heading", 12, 5);
  setTextStyle(view, "paragraph");
  expect(view.state.doc.toString()).toBe("  Heading");
  expect(view.state.selection.main.anchor).toBeGreaterThan(view.state.selection.main.head);
  expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("Heading");
});

it("preserves the exact selected word when adding a heading prefix", () => {
  const view = editor("before\n\nsome text", 8, 12);
  setTextStyle(view, "heading2");
  expect(view.state.doc.toString()).toBe("before\n\n## some text");
  expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("some");
});

it("creates, edits, removes, and undoes Markdown links with nested parentheses", () => {
  const view = editor("read this", 0, 4);
  expect(applyLink(view, "https://example.com/a(b)")).toBe(true);
  expect(view.state.doc.toString()).toBe("[read](<https://example.com/a(b)>) this");
  expect(selectedLink(view)?.url).toBe("https://example.com/a(b)");
  expect(applyLink(view, "https://example.com/new")).toBe(true);
  expect(view.state.doc.toString()).toBe("[read](https://example.com/new) this");
  removeLink(view); expect(view.state.doc.toString()).toBe("read this");
  undo(view); expect(view.state.doc.toString()).toBe("[read](https://example.com/new) this");
});

it("rejects invalid link addresses and escapes literal label brackets", () => {
  const view = editor("a [label]");
  expect(applyLink(view, "javascript:alert(1)")).toBe(false);
  expect(applyLink(view, "https://bad link")).toBe(false);
  expect(view.state.doc.toString()).toBe("a [label]");
  applyLink(view, "https://example.com");
  expect(view.state.doc.toString()).toBe("[a \\[label\\]](https://example.com)");
});

it("wraps code containing backticks with a longer delimiter", () => {
  const view = editor("a `code` value");
  toggleInlineCode(view);
  expect(view.state.doc.toString()).toBe("``a `code` value``");
  toggleInlineCode(view);
  expect(view.state.doc.toString()).toBe("a `code` value");
});
