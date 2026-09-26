import { syntaxTree } from "@codemirror/language";
import { EditorSelection } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

export type InlineFormat = "bold" | "italic";

const formats = {
  bold: { marker: "**", alternate: "__", node: "StrongEmphasis" },
  italic: { marker: "*", alternate: "_", node: "Emphasis" },
} as const;

export function toggleInlineFormat(view: EditorView, format: InlineFormat): boolean {
  const { marker, alternate, node: nodeName } = formats[format];
  const selection = view.state.selection.main;
  const source = view.state.doc.toString();
  const markLength = marker.length;

  // A selection inside a complete construct, or a caret within it, toggles
  // that construct off. The parser keeps this safe for hand-typed Markdown too.
  for (let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(selection.head, -1); node; node = node.parent) {
    if (node.name !== nodeName || selection.from < node.from || selection.to > node.to) continue;
    if (selection.empty && (selection.head <= node.from || selection.head >= node.to)) continue;
    const opening = source.slice(node.from, node.from + markLength);
    if ((opening !== marker && opening !== alternate)
      || source.slice(node.to - markLength, node.to) !== opening) continue;
    const from = node.from;
    const to = node.to;
    const anchor = Math.max(from, Math.min(to - markLength * 2, selection.anchor - markLength));
    const head = Math.max(from, Math.min(to - markLength * 2, selection.head - markLength));
    view.dispatch({
      changes: [{ from, to: from + markLength }, { from: to - markLength, to }],
      selection: EditorSelection.single(anchor, head),
      scrollIntoView: true,
      userEvent: "input.format",
    });
    view.focus();
    return true;
  }

  const { from, to } = selection;
  // Also accept a selection of the visible word whose markers sit just outside it.
  const opening = source.slice(from - markLength, from);
  if (!selection.empty && from >= markLength
    && (opening === marker || opening === alternate)
    && source.slice(to, to + markLength) === opening
    // A single star beside a selection may belong to bold's double marker.
    && (format !== "italic" || (source[from - markLength - 1] !== opening[0]
      && source[to + markLength] !== opening[0]))) {
    view.dispatch({
      changes: [{ from: from - markLength, to: from }, { from: to, to: to + markLength }],
      selection: EditorSelection.single(from - markLength, to - markLength),
      scrollIntoView: true,
      userEvent: "input.format",
    });
    view.focus();
    return true;
  }

  const selected = source.slice(from, to);
  if (selected && !selected.trim()) return true;
  const leading = selected.length - selected.trimStart().length;
  const trailing = selected.length - selected.trimEnd().length;
  const start = from + leading;
  const end = to - trailing;
  view.dispatch({
    changes: [{ from: start, insert: marker }, { from: end, insert: marker }],
    selection: selection.empty
      ? EditorSelection.single(start + markLength)
      : EditorSelection.single(start + markLength, end + markLength),
    scrollIntoView: true,
    userEvent: "input.format",
  });
  view.focus();
  return true;
}
