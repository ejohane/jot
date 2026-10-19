import { StateEffect, StateField, type EditorState } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { Decoration, EditorView, ViewPlugin, type DecorationSet, type ViewUpdate } from "@codemirror/view";

export type ZenMode = "off" | "sentence" | "paragraph";
export const setZenMode = StateEffect.define<ZenMode>();
export const zenMode = StateField.define<ZenMode>({
  create: () => "off",
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(setZenMode)) value = effect.value;
    return value;
  },
});

// Resolve the Markdown block so adjacent list items and headings remain distinct.
export function focusRange(state: EditorState, mode: ZenMode) {
  const selection = state.selection.main;
  if (!selection.empty) return { from: selection.from, to: selection.to };
  const position = selection.head;
  const line = state.doc.lineAt(position);
  let from = line.from, to = line.to;
  for (let node = syntaxTree(state).resolveInner(position, -1); node; node = node.parent!) {
    if (/^(Paragraph|ATXHeading[1-6]|FencedCode|CodeBlock)$/.test(node.name)) {
      from = node.from; to = node.to; break;
    }
  }
  if (mode === "sentence" && to > from) {
    const text = state.doc.sliceString(from, to);
    const segments = new Intl.Segmenter(undefined, { granularity: "sentence" }).segment(text);
    for (const segment of segments) {
      const end = from + segment.index + segment.segment.length;
      if (position < end || end === to) return { from: from + segment.index, to: end };
    }
  }
  return { from, to };
}

function dimming(view: EditorView): DecorationSet {
  const mode = view.state.field(zenMode);
  if (mode === "off") return Decoration.none;
  const { from, to } = focusRange(view.state, mode);
  const mark = Decoration.mark({ class: "cm-zen-dim" });
  const ranges = [];
  if (from > 0) ranges.push(mark.range(0, from));
  if (to < view.state.doc.length) ranges.push(mark.range(to, view.state.doc.length));
  return Decoration.set(ranges);
}

export const zenWriting = [zenMode,
  EditorView.editorAttributes.of(view => ({ class: view.state.field(zenMode) === "off" ? "" : "cm-zen" })),
  ViewPlugin.fromClass(class {
    decorations: DecorationSet;
    private previousScroll = 0;
    constructor(view: EditorView) { this.decorations = dimming(view); }
    update(update: ViewUpdate) {
      const before = update.startState.field(zenMode), after = update.state.field(zenMode);
      if (update.docChanged || update.selectionSet || before !== after || update.viewportChanged) {
        this.decorations = dimming(update.view);
      }
      if (before === "off" && after !== "off") this.previousScroll = update.view.scrollDOM.scrollTop;
      if (before !== "off" && after === "off") {
        const top = this.previousScroll;
        update.view.requestMeasure({ read: () => top, write: value => { update.view.scrollDOM.scrollTop = value; } });
      } else if (after !== "off" && (before !== after || update.docChanged || update.selectionSet || update.geometryChanged)) {
        update.view.requestMeasure({
          key: this,
          read(view) {
            const cursor = view.coordsAtPos(view.state.selection.main.head);
            const box = view.scrollDOM.getBoundingClientRect();
            return cursor ? (cursor.top + cursor.bottom) / 2 - (box.top + box.bottom) / 2 : 0;
          },
          write(delta, view) { if (Math.abs(delta) > 1) view.scrollDOM.scrollTop += delta; },
        });
      }
    }
  }, { decorations: plugin => plugin.decorations }),
];
