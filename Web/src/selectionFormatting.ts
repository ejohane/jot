import { syntaxTree } from "@codemirror/language";
import { EditorSelection } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

export type TextStyle = "paragraph" | "heading1" | "heading2" | "heading3" | "bullet" | "number" | "task" | "quote";
const prefixes: Record<TextStyle, string> = {
  paragraph: "", heading1: "# ", heading2: "## ", heading3: "### ",
  bullet: "- ", number: "1. ", task: "- [ ] ", quote: "> ",
};

export function setTextStyle(view: EditorView, style: TextStyle) {
  const { from, to, anchor, head } = view.state.selection.main;
  const first = view.state.doc.lineAt(from).number;
  const last = view.state.doc.lineAt(to > from && view.state.doc.lineAt(to).from === to ? to - 1 : to).number;
  const changes = [];
  for (let number = first; number <= last; number++) {
    const line = view.state.doc.line(number);
    const match = /^(\s*)(?:#{1,6}\s+|>\s?|[-+*]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)?/.exec(line.text)!;
    const prefix = style === "number" ? `${number - first + 1}. ` : prefixes[style];
    changes.push({ from: line.from + match[1].length, to: line.from + match[0].length, insert: prefix });
  }
  const transaction = view.state.update({ changes, userEvent: "input.format" });
  view.dispatch({ changes: transaction.changes, selection: EditorSelection.single(transaction.changes.mapPos(anchor, 1), transaction.changes.mapPos(head, 1)), scrollIntoView: true, userEvent: "input.format" });
  view.focus();
}

export function selectedLink(view: EditorView) {
  const selection = view.state.selection.main;
  for (let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(selection.from, 1); node; node = node.parent) {
    if (node.name !== "Link" || selection.to > node.to) continue;
    const url = node.getChild("URL");
    const marks = node.getChildren("LinkMark");
    if (!url || marks.length < 2) continue;
    return { from: node.from, to: node.to, label: view.state.sliceDoc(marks[0].to, marks[1].from), url: view.state.sliceDoc(url.from, url.to).replace(/^<|>$/g, "") };
  }
  return null;
}

export function applyLink(view: EditorView, address: string): boolean {
  const url = address.trim();
  if (!url || /[\s<>]/.test(url) || /^(?!https?:|mailto:|tel:)[a-z][a-z\d+.-]*:/i.test(url)) return false;
  const existing = selectedLink(view);
  const { from, to } = existing ?? view.state.selection.main;
  const label = existing?.label ?? view.state.sliceDoc(from, to).replace(/[\\[\]]/g, "\\$&");
  const destination = /[()]/.test(url) ? `<${url}>` : url;
  view.dispatch({ changes: { from, to, insert: `[${label}](${destination})` }, selection: EditorSelection.single(from + 1, from + 1 + label.length), userEvent: "input.format", scrollIntoView: true });
  view.focus();
  return true;
}

export function removeLink(view: EditorView) {
  const link = selectedLink(view);
  if (!link) return;
  view.dispatch({ changes: { from: link.from, to: link.to, insert: link.label }, selection: EditorSelection.single(link.from, link.from + link.label.length), userEvent: "input.format" });
  view.focus();
}

export function toggleInlineCode(view: EditorView) {
  const selection = view.state.selection.main;
  for (let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(selection.from, 1); node; node = node.parent) {
    if (node.name !== "InlineCode" || selection.to > node.to) continue;
    const marks = node.getChildren("CodeMark");
    if (marks.length !== 2) continue;
    const content = view.state.sliceDoc(marks[0].to, marks[1].from);
    view.dispatch({ changes: { from: node.from, to: node.to, insert: content }, selection: EditorSelection.single(node.from, node.from + content.length), userEvent: "input.format" });
    view.focus(); return;
  }
  const selected = view.state.sliceDoc(selection.from, selection.to);
  const marker = "`".repeat(Math.max(0, ...Array.from(selected.matchAll(/`+/g), (match) => match[0].length)) + 1);
  const pad = selected.startsWith("`") || selected.endsWith("`") ? " " : "";
  const from = selection.from + marker.length + pad.length;
  view.dispatch({ changes: { from: selection.from, to: selection.to, insert: `${marker}${pad}${selected}${pad}${marker}` }, selection: EditorSelection.single(from, from + selected.length), userEvent: "input.format" });
  view.focus();
}
