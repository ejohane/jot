import { ensureSyntaxTree, syntaxTree, syntaxTreeAvailable } from "@codemirror/language";
import type { EditorState } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

const indent = "     ";

type Item = { node: SyntaxNode };

function listItem(mark: SyntaxNode): Item | null {
  const node = mark.parent;
  return node?.name === "ListItem" && node.parent?.name === "BulletList" ? { node } : null;
}

function bulletItemAtLine(state: EditorState, number: number): Item | null {
  const line = state.doc.line(number);
  const match = /^([ \t]*)([*+-])(?:[ \t]+|$)/.exec(line.text);
  if (!match) return null;
  const markAt = line.from + match[1].length;
  let mark = syntaxTree(state).resolveInner(markAt, 1);
  if (mark.name !== "ListMark" && !syntaxTreeAvailable(state, markAt + 1)) {
    // A newly loaded long note may not be parsed to the caret yet. Give that
    // one-time parse enough time to reach the active marker on slower Macs.
    mark = (ensureSyntaxTree(state, markAt + 1, 100) ?? syntaxTree(state)).resolveInner(markAt, 1);
  }
  return mark.name === "ListMark" && mark.from === markAt && mark.to === markAt + 1
    ? listItem(mark) : null;
}

function selectedItems(state: EditorState): Item[] | null {
  const selected: Item[] = [];
  for (const range of state.selection.ranges) {
    const last = range.empty ? range.to : range.to > 0 && state.doc.lineAt(range.to).from === range.to
      ? range.to - 1 : range.to;
    const firstLine = state.doc.lineAt(range.from).number;
    const lastLine = state.doc.lineAt(last).number;
    for (let number = firstLine; number <= lastLine; number += 1) {
      const line = state.doc.line(number);
      if (!line.text.trim() && !range.empty) continue;
      const item = bulletItemAtLine(state, number);
      if (!item) return null;
      selected.push(item);
    }
  }
  // Moving a parent moves its whole subtree, including any selected children.
  selected.sort((a, b) => a.node.from - b.node.from || b.node.to - a.node.to);
  const roots: Item[] = [];
  for (const item of selected) {
    const previous = roots.at(-1);
    if (previous && previous.node.to >= item.node.to) continue;
    roots.push(item);
  }
  return roots;
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
  const selected = selectedItems(state);
  if (!selected?.length) return false;

  const outdents = new Map<Item, string>();
  for (const item of selected) {
    if (direction < 0) {
      const prefix = outdentPrefix(state, item);
      if (!prefix) return true;
      outdents.set(item, prefix);
    } else {
      // The first item has no parent to nest under. An existing first child
      // cannot skip another level beneath its parent.
      if (item.node.prevSibling?.name !== "ListItem") return true;
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
        // Markdown permits unindented continuation text inside a list item.
        if (!line.text.startsWith(prefix)) continue;
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
