import { syntaxTree } from "@codemirror/language";
import { type EditorState, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";

type Node = ReturnType<typeof syntaxTree>["topNode"];
type Cell = { from: number; to: number; node: Node | null };

// Use parser delimiters, so escaped pipes never become column boundaries.
function cells(row: Node, state: EditorState): Cell[] {
  const delimiters = row.getChildren("TableDelimiter");
  const boundaries = [row.from, ...delimiters.map((node) => node.to), row.to + 1];
  const result = boundaries.slice(0, -1).map((from, index) => ({
    from,
    to: boundaries[index + 1] - 1,
    node: row.getChildren("TableCell").find((node) => node.from >= from && node.to <= boundaries[index + 1] - 1) ?? null,
  }));
  const source = state.sliceDoc(row.from, row.to).trim();
  if (source.startsWith("|")) result.shift();
  if (source.endsWith("|")) result.pop();
  return result;
}

const inlineTags: Record<string, string> = {
  StrongEmphasis: "strong", Emphasis: "em", Strikethrough: "s", InlineCode: "code", Link: "span",
};
const hidden = new Set(["EmphasisMark", "StrikethroughMark", "CodeMark", "LinkMark", "URL", "LinkTitle"]);

function appendInline(parent: HTMLElement, node: Node, state: EditorState) {
  let position = node.from;
  for (let child = node.firstChild; child; child = child.nextSibling) {
    parent.append(document.createTextNode(state.sliceDoc(position, child.from)));
    if (child.name === "Escape") {
      parent.append(document.createTextNode(state.sliceDoc(child.from + 1, child.to)));
    } else if (!hidden.has(child.name)) {
      const tag = inlineTags[child.name];
      if (tag) {
        const element = document.createElement(tag);
        if (child.name === "Link") element.className = "cm-table-link";
        appendInline(element, child, state);
        parent.append(element);
      } else {
        // Raw HTML stays inert text; never feed Markdown to innerHTML.
        parent.append(document.createTextNode(state.sliceDoc(child.from, child.to)));
      }
    }
    position = child.to;
  }
  parent.append(document.createTextNode(state.sliceDoc(position, node.to)));
}

class TableWidget extends WidgetType {
  constructor(readonly node: Node, readonly state: EditorState) { super(); }

  eq(other: TableWidget) {
    return this.node.from === other.node.from && this.state.sliceDoc(this.node.from, this.node.to) === other.state.sliceDoc(other.node.from, other.node.to);
  }

  toDOM(view: EditorView) {
    const wrapper = document.createElement("div");
    wrapper.className = "cm-markdown-table";
    wrapper.title = "Click to edit Markdown";
    const table = document.createElement("table");
    const header = this.node.getChild("TableHeader")!;
    const separator = this.node.getChild("TableDelimiter")!;
    const alignment = this.state.sliceDoc(separator.from, separator.to).trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((part) => {
      const value = part.trim();
      return value.endsWith(":") ? (value.startsWith(":") ? "center" : "right") : "left";
    });
    const columns = cells(header, this.state).length;
    const head = table.createTHead();
    const body = table.createTBody();
    for (const row of [header, ...this.node.getChildren("TableRow")]) {
      const tr = document.createElement("tr");
      (row === header ? head : body).append(tr);
      const rowCells = cells(row, this.state);
      for (let index = 0; index < columns; index++) {
        const cell = rowCells[index];
        const td = document.createElement(row === header ? "th" : "td");
        if (row === header) td.setAttribute("scope", "col");
        td.style.textAlign = alignment[index] ?? "left";
        if (cell?.node) appendInline(td, cell.node, this.state);
        td.addEventListener("mousedown", (event) => {
          if (event.button !== 0 || event.shiftKey || event.metaKey) return;
          event.preventDefault();
          view.dispatch({ selection: { anchor: cell?.node?.from ?? cell?.from ?? row.to }, scrollIntoView: true });
          view.focus();
        });
        tr.append(td);
      }
    }
    wrapper.append(table);
    return wrapper;
  }

  ignoreEvent() { return false; }
}

function tableDecorations(state: EditorState): DecorationSet {
  const ranges: ReturnType<Decoration["range"]>[] = [];
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name !== "Table") return;
      const selected = state.selection.ranges.some((range) => range.from <= node.to && range.to >= node.from);
      if (!selected) ranges.push(Decoration.replace({ widget: new TableWidget(node.node, state), block: true }).range(node.from, node.to));
      return false;
    },
  });
  return Decoration.set(ranges, true);
}

// Block replacements belong to state, not viewport plugins: they change layout.
export const markdownTables = StateField.define<DecorationSet>({
  create: tableDecorations,
  update(value, transaction) {
    return transaction.docChanged || transaction.selection || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
      ? tableDecorations(transaction.state) : value;
  },
  provide: (field) => EditorView.decorations.from(field),
});
