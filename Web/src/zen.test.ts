import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, it } from "vitest";
import { focusRange, setZenMode, zenMode, zenWriting } from "./zen";

const views: EditorView[] = [];
afterEach(() => { views.splice(0).forEach(v => v.destroy()); document.body.replaceChildren(); });
const text = "First paragraph. Still first.\nWrapped line.\n\nSecond paragraph. Another sentence!\n\nLast paragraph.";
function state(at: number) { return EditorState.create({ doc: text, selection: { anchor: at }, extensions: [markdown(), zenWriting] }); }
function focused(s: EditorState, mode: "sentence" | "paragraph") { const r = focusRange(s, mode); return s.doc.sliceString(r.from, r.to); }

describe("Zen focus", () => {
  it("focuses the whole multiline paragraph without including its neighbors", () => {
    expect(focused(state(20), "paragraph")).toBe("First paragraph. Still first.\nWrapped line.");
    expect(focused(state(text.indexOf("Second")), "paragraph")).toBe("Second paragraph. Another sentence!");
  });
  it("follows sentences and uses the following sentence at a boundary", () => {
    expect(focused(state(3), "sentence").trim()).toBe("First paragraph.");
    expect(focused(state(text.indexOf("Still")), "sentence").trim()).toBe("Still first.");
    expect(focused(state(text.indexOf("Another")), "sentence").trim()).toBe("Another sentence!");
    expect(focused(state(text.length), "sentence")).toBe("Last paragraph.");
  });
  it("keeps the whole selection readable across paragraph boundaries", () => {
    const s = state(0).update({ selection: { anchor: 3, head: text.indexOf("Another") } }).state;
    expect(focusRange(s, "sentence")).toEqual({ from: 3, to: text.indexOf("Another") });
  });
  it("handles blank documents, blank lines, emoji, headings and list boundaries", () => {
    for (const doc of ["", "\n\n", "# Heading", "Emoji 👩🏽‍💻. Next!", "- One\n- Two"]) {
      const s = EditorState.create({ doc, selection: { anchor: doc.length }, extensions: [markdown(), zenWriting] });
      const range = focusRange(s, "sentence");
      expect(range.from).toBeGreaterThanOrEqual(0);
      expect(range.to).toBeLessThanOrEqual(doc.length);
    }
    const s = EditorState.create({ doc: "- One\n- Two", selection: { anchor: 4 }, extensions: [markdown(), zenWriting] });
    expect(focused(s, "paragraph")).toBe("One");
  });
  it("moves the dimmed ranges with the cursor, removes them on exit, and preserves exact Markdown and selection", () => {
    const view = new EditorView({ parent: document.body, state: state(20) }); views.push(view);
    view.dispatch({ effects: setZenMode.of("paragraph") });
    expect(view.dom.classList.contains("cm-zen")).toBe(true);
    expect(view.dom.querySelector(".cm-zen-dim")?.textContent).toContain("Second paragraph");
    view.dispatch({ effects: setZenMode.of("sentence"), selection: { anchor: text.indexOf("Another") } });
    expect(view.state.field(zenMode)).toBe("sentence");
    expect([...view.dom.querySelectorAll(".cm-zen-dim")].map(e => e.textContent).join("")).not.toContain("Another sentence!");
    const selection = view.state.selection;
    view.dispatch({ effects: setZenMode.of("off") });
    expect(view.dom.querySelector(".cm-zen-dim")).toBeNull();
    expect(view.dom.classList.contains("cm-zen")).toBe(false);
    expect(view.state.doc.toString()).toBe(text);
    expect(view.state.selection.eq(selection)).toBe(true);
  });
});
