import { syntaxTree } from "@codemirror/language";
import { RangeSetBuilder } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

class BulletWidget extends WidgetType {
  constructor(private readonly open: boolean) { super(); }

  eq(other: BulletWidget) { return other.open === this.open; }

  toDOM() {
    const bullet = document.createElement("span");
    bullet.className = this.open ? "cm-list-bullet cm-list-bullet-open" : "cm-list-bullet";
    bullet.textContent = this.open ? "○" : "•";
    bullet.setAttribute("aria-hidden", "true");
    return bullet;
  }

  ignoreEvent() { return false; }
}

const bulletDecorations = [
  Decoration.replace({ widget: new BulletWidget(false) }),
  Decoration.replace({ widget: new BulletWidget(true) }),
];

function bulletDepth(mark: SyntaxNode): number {
  let depth = -1;
  for (let ancestor = mark.parent; ancestor; ancestor = ancestor.parent) {
    if (ancestor.name === "BulletList" || ancestor.name === "OrderedList") depth += 1;
  }
  return Math.max(0, depth);
}

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
  const ranges: Array<{ from: number; to: number; decoration: Decoration }> = [];
  const selection = view.state.selection.main;
  const activeLine = view.state.doc.lineAt(selection.head);

  syntaxTree(view.state).iterate({
    enter(node) {
      if (!markerNodes.has(node.name) || node.from === node.to) return;
      const active = node.to >= activeLine.from && node.from <= activeLine.to;
      const isBullet = node.name === "ListMark" && /^[*+-]$/.test(view.state.sliceDoc(node.from, node.to));
      ranges.push({
        from: node.from,
        to: node.to,
        decoration: isBullet ? bulletDecorations[bulletDepth(node.node) % 2] : Decoration.mark({
          class: active ? "cm-markdown-marker-active" : "cm-markdown-marker",
        }),
      });
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
      range.decoration,
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
