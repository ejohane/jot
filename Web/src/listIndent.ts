import { syntaxTree } from "@codemirror/language";
import type { EditorState } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

const indent = "  ";

type Item = { node: SyntaxNode; depth: number; rootFrom: number; rootTo: number };

function listItem(mark: SyntaxNode): Item | null {
  const node = mark.parent;
  if (node?.name !== "ListItem") return null;
  let depth = -1;
  let rootFrom = -1;
  let rootTo = -1;
  for (let ancestor: SyntaxNode | null = node.parent; ancestor; ancestor = ancestor.parent) {
    if (ancestor.name === "BulletList") {
      depth += 1;
      rootFrom = ancestor.from;
      rootTo = ancestor.to;
    }
  }
  return depth < 0 ? null : { node, depth, rootFrom, rootTo };
}

function bulletItems(state: EditorState): Item[] {
  const items: Item[] = [];
  syntaxTree(state).iterate({
    enter(mark) {
      if (mark.name !== "ListMark" || !/^[*+-]$/.test(state.sliceDoc(mark.from, mark.to))) return;
      const item = listItem(mark.node);
      if (item) items.push(item);
    },
  });
  return items;
}

function selectedItems(state: EditorState, items: Item[]): Item[] | null {
  const selected: Item[] = [];
  for (const range of state.selection.ranges) {
    const last = range.empty ? range.to : range.to > 0 && state.doc.lineAt(range.to).from === range.to
      ? range.to - 1 : range.to;
    const firstLine = state.doc.lineAt(range.from).number;
    const lastLine = state.doc.lineAt(last).number;
    for (let number = firstLine; number <= lastLine; number += 1) {
      const line = state.doc.line(number);
      if (!line.text.trim() && !range.empty) continue;
      const item = items.find((candidate) => state.doc.lineAt(candidate.node.from).number === number);
      if (!item) return null;
      selected.push(item);
    }
  }
  // Moving a parent moves its whole subtree, including any selected children.
  return selected.filter((item, index) => selected.findIndex((other) => other.node.from === item.node.from
    && other.node.to === item.node.to) === index && !selected.some((other) => other !== item
    && other.node.from <= item.node.from && other.node.to >= item.node.to));
}

function leadingWhitespace(state: EditorState, node: SyntaxNode): string {
  return state.doc.lineAt(node.from).text.match(/^[ \t]*/)?.[0] ?? "";
}

function outdentPrefix(state: EditorState, item: Item): string | null {
  const parent = item.node.parent?.parent;
  if (parent?.name !== "ListItem") return null;
  const current = leadingWhitespace(state, item.node);
  const outer = leadingWhitespace(state, parent);
  return current.startsWith(outer) && current.length > outer.length ? current.slice(outer.length) : null;
}

function changeIndent(view: EditorView, direction: 1 | -1): boolean {
  const { state } = view;
  const items = bulletItems(state);
  const selected = selectedItems(state, items);
  if (!selected?.length) return false;

  const outdents = new Map<Item, string>();
  for (const item of selected) {
    if (direction < 0) {
      const prefix = outdentPrefix(state, item);
      if (!prefix) return false;
      outdents.set(item, prefix);
    } else {
      const previous = items.filter((candidate) => candidate.node.from < item.node.from
        && candidate.rootFrom === item.rootFrom && candidate.rootTo === item.rootTo).at(-1);
      // The first item has no parent to nest under. An existing first child
      // cannot skip another level beneath its parent.
      if (!previous || item.depth > previous.depth) return false;
    }
  }

  const changes: Array<{ from: number; to?: number; insert: string }> = [];
  for (const item of selected) {
    const first = state.doc.lineAt(item.node.from).number;
    const last = state.doc.lineAt(item.node.to).number;
    for (let number = first; number <= last; number += 1) {
      const line = state.doc.line(number);
      if (!line.text) continue;
      if (direction > 0) changes.push({ from: line.from, insert: indent });
      else {
        const prefix = outdents.get(item)!;
        if (!line.text.startsWith(prefix)) return false;
        changes.push({ from: line.from, to: line.from + prefix.length, insert: "" });
      }
    }
  }
  if (!changes.length) return false;
  view.dispatch({ changes, scrollIntoView: true, userEvent: direction > 0 ? "input.indent" : "delete.dedent" });
  return true;
}

export const indentBulletItem = (view: EditorView) => changeIndent(view, 1);
export const outdentBulletItem = (view: EditorView) => changeIndent(view, -1);
