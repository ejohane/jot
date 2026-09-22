import { syntaxTree } from "@codemirror/language";
import { RangeSetBuilder } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";

const markerNodes = new Set([
  "HeaderMark",
  "EmphasisMark",
  "StrikethroughMark",
  "QuoteMark",
  "ListMark",
  "LinkMark",
  "CodeMark",
  "URL",
]);

function markerDecorations(view: EditorView): DecorationSet {
  const ranges: Array<{ from: number; to: number; active: boolean }> = [];
  const selection = view.state.selection.main;
  const activeLine = view.state.doc.lineAt(selection.head);

  syntaxTree(view.state).iterate({
    enter(node) {
      if (!markerNodes.has(node.name) || node.from === node.to) return;
      const active = node.to >= activeLine.from && node.from <= activeLine.to;
      ranges.push({ from: node.from, to: node.to, active });
    },
  });

  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  const builder = new RangeSetBuilder<Decoration>();
  let lastTo = -1;
  for (const range of ranges) {
    if (range.from < lastTo) continue;
    builder.add(
      range.from,
      range.to,
      Decoration.mark({ class: range.active ? "cm-markdown-marker-active" : "cm-markdown-marker" }),
    );
    lastTo = range.to;
  }
  return builder.finish();
}

export const markdownPresentation = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = markerDecorations(view);
    }

    update(update: ViewUpdate) {
      if (update.docChanged || update.selectionSet || update.viewportChanged) {
        this.decorations = markerDecorations(update.view);
      }
    }
  },
  { decorations: (value) => value.decorations },
);
