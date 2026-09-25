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

class TaskWidget extends WidgetType {
  constructor(private readonly checked: boolean) { super(); }

  eq(other: TaskWidget) { return this.checked === other.checked; }

  toDOM() {
    const checkbox = document.createElement("span");
    checkbox.className = this.checked ? "cm-task-checkbox is-checked" : "cm-task-checkbox";
    checkbox.setAttribute("aria-hidden", "true");
    return checkbox;
  }

  ignoreEvent() { return false; }
}

class NumberWidget extends WidgetType {
  constructor(private readonly label: string) { super(); }

  eq(other: NumberWidget) { return this.label === other.label; }

  toDOM() {
    const number = document.createElement("span");
    number.className = "cm-list-number";
    number.textContent = this.label;
    number.setAttribute("aria-hidden", "true");
    return number;
  }

  ignoreEvent() { return false; }
}

class RuleWidget extends WidgetType {
  toDOM() {
    const rule = document.createElement("span");
    rule.className = "cm-horizontal-rule";
    rule.setAttribute("aria-hidden", "true");
    return rule;
  }

  ignoreEvent() { return false; }
}

const bulletDecorations = [
  Decoration.replace({ widget: new BulletWidget(false) }),
  Decoration.replace({ widget: new BulletWidget(true) }),
];
const taskDecorations = [
  Decoration.replace({ widget: new TaskWidget(false) }),
  Decoration.replace({ widget: new TaskWidget(true) }),
];
const ruleDecoration = Decoration.replace({ widget: new RuleWidget() });

function bulletDepth(mark: SyntaxNode): number {
  let depth = -1;
  for (let ancestor = mark.parent; ancestor; ancestor = ancestor.parent) {
    if (ancestor.name === "BulletList" || ancestor.name === "OrderedList") depth += 1;
  }
  return Math.max(0, depth);
}

function hasAncestor(node: SyntaxNode, name: string): boolean {
  for (let ancestor = node.parent; ancestor; ancestor = ancestor.parent) {
    if (ancestor.name === name) return true;
  }
  return false;
}

const markerNodes = new Set([
  "HeaderMark",
  "EmphasisMark",
  "StrikethroughMark",
  "QuoteMark",
  "ListMark",
  "LinkMark",
  "CodeMark",
  "CodeInfo",
  "URL",
  "LinkTitle",
  "TaskMarker",
]);

function markerDecorations(view: EditorView): DecorationSet {
  const ranges: Array<{ from: number; to: number; decoration: Decoration }> = [];
  const selection = view.state.selection.main;
  const source = view.state.doc.toString();

  const touches = (from: number, to: number) => selection.empty
    ? selection.head > from && selection.head < to
    : selection.from < to && selection.to > from;
  const touchesLine = (from: number) => {
    const line = view.state.doc.lineAt(from);
    return selection.empty
      ? selection.head >= line.from && selection.head <= line.to
      : selection.from <= line.to && selection.to >= line.from;
  };
  const add = (from: number, to: number, decoration: Decoration) => {
    if (from < to) ranges.push({ from, to, decoration });
  };

  syntaxTree(view.state).iterate({
    enter(node) {
      if (node.name === "HorizontalRule") {
        add(node.from, node.to, touchesLine(node.from)
          ? Decoration.mark({ class: "cm-markdown-marker-active" }) : ruleDecoration);
        return false;
      }
      if (!markerNodes.has(node.name) || node.from === node.to) return;
      const parent = node.node.parent;
      if (!parent) return;
      const parentName = parent.name;
      const inBlockquote = node.name === "QuoteMark" && hasAncestor(node.node, "Blockquote");
      const inline = (node.name === "EmphasisMark" && (parentName === "Emphasis" || parentName === "StrongEmphasis"))
        || (node.name === "StrikethroughMark" && parentName === "Strikethrough")
        || (node.name === "CodeMark" && parentName === "InlineCode")
        || ((node.name === "LinkMark" || node.name === "URL" || node.name === "LinkTitle")
          && parentName === "Link" && source[parent.to - 1] === ")")
        || (node.name === "LinkMark" && parentName === "Autolink");
      const fence = parentName === "FencedCode" && parent.getChildren("CodeMark").length >= 2
        && (node.name === "CodeMark" || node.name === "CodeInfo");
      const lineMarker = node.name === "HeaderMark" && parentName.startsWith("ATXHeading")
        || inBlockquote
        || node.name === "ListMark" && parentName === "ListItem"
        || node.name === "TaskMarker" && parentName === "Task";
      const active = inline || fence ? touches(parent.from, parent.to) : touchesLine(node.from);
      const isBullet = node.name === "ListMark" && /^[*+-]$/.test(view.state.sliceDoc(node.from, node.to));
      if (isBullet) {
        add(node.from, node.to, active
          ? Decoration.mark({ class: "cm-markdown-marker-active" })
          : bulletDecorations[bulletDepth(node.node) % 2]);
        return;
      }
      if (node.name === "ListMark" && parentName === "ListItem") {
        add(node.from, node.to, active
          ? Decoration.mark({ class: "cm-markdown-marker-active" })
          : Decoration.replace({ widget: new NumberWidget(source.slice(node.from, node.to)) }));
        return;
      }
      if (node.name === "TaskMarker" && parentName === "Task") {
        add(node.from, node.to, active
          ? Decoration.mark({ class: "cm-markdown-marker-active" })
          : taskDecorations[/[xX]/.test(source.slice(node.from, node.to)) ? 1 : 0]);
        return;
      }
      let from = node.from;
      let to = node.to;
      let complete = true;
      if (node.name === "HeaderMark" && parentName.startsWith("ATXHeading") && node.from > view.state.doc.lineAt(node.from).from) {
        const line = view.state.doc.lineAt(node.from);
        while (from > line.from && /[ \t]/.test(source[from - 1])) from -= 1;
        complete = Boolean(source.slice(line.from, from).replace(/^[ \t]*#{1,6}[ \t]*/, "").trim());
      } else if (lineMarker && (node.name === "HeaderMark" || node.name === "QuoteMark")) {
        const line = view.state.doc.lineAt(node.from);
        while (to < line.to && /[ \t]/.test(source[to])) to += 1;
        // A bare marker is still being written and should remain visible.
        if (!source.slice(to, line.to).trim()) {
          to = node.to;
          complete = false;
        }
      }
      add(from, to, complete && (inline || fence || lineMarker) && !active
        ? Decoration.replace({})
        : Decoration.mark({ class: active ? "cm-markdown-marker-active" : "cm-markdown-marker" }));
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
