import type { Range } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { Decoration, EditorView, ViewPlugin } from "@codemirror/view";
import { sendToNative } from "./bridge";

function browserURL(value: string): string | null {
  try {
    const url = new URL(value.replace(/^<|>$/g, ""));
    return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
  } catch { return null; }
}

// Mark only presented links. Keyboard navigation into their source removes the
// click target and lets CodeMirror reveal and edit the original Markdown.
function decorations(view: EditorView) {
  const ranges: Range<Decoration>[] = [];
  const selection = view.state.selection.main;
  syntaxTree(view.state).iterate({ enter(node) {
    const standaloneURL = node.name === "URL" && node.node.parent?.name === "Paragraph";
    if (node.name !== "Link" && node.name !== "Autolink" && !standaloneURL) return;
    const url = standaloneURL ? node.node : node.node.getChild("URL");
    if (!url) return;
    const href = browserURL(view.state.sliceDoc(url.from, url.to));
    if (!href) return;
    const active = selection.empty
      ? selection.head > node.from && selection.head < node.to
      : selection.from < node.to && selection.to > node.from;
    if (active) return false;
    const marks = node.node.getChildren("LinkMark");
    const from = standaloneURL ? node.from : marks[0]?.to;
    const to = standaloneURL ? node.to : marks[1]?.from;
    if (from !== undefined && to !== undefined && from < to) {
      ranges.push(Decoration.mark({ class: "cm-browser-link", attributes: {
        "data-browser-url": href, role: "link", title: href,
      } }).range(from, to));
    }
    return false;
  } });
  return Decoration.set(ranges, true);
}

function targetLink(event: MouseEvent): HTMLElement | null {
  return event.target instanceof Element ? event.target.closest<HTMLElement>(".cm-browser-link") : null;
}

export const clickableLinks = ViewPlugin.fromClass(class {
  decorations;
  constructor(view: EditorView) { this.decorations = decorations(view); }
  update(update: import("@codemirror/view").ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged) this.decorations = decorations(update.view);
  }
}, {
  decorations: value => value.decorations,
  eventHandlers: {
    mousedown(event) {
      if (event.button !== 0 || !targetLink(event)) return false;
      event.preventDefault();
      return true;
    },
    click(event) {
      if (event.button !== 0) return false;
      const href = targetLink(event)?.dataset.browserUrl;
      if (!href) return false;
      event.preventDefault();
      sendToNative({ version: 1, type: "openBrowserURL", url: href });
      return true;
    },
  },
});
