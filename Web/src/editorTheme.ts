import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorView } from "@codemirror/view";
import { tags } from "@lezer/highlight";

const highlights = HighlightStyle.define([
  { tag: tags.heading1, fontSize: "1.45em", fontWeight: "700" },
  { tag: tags.heading2, fontSize: "1.25em", fontWeight: "700" },
  { tag: tags.heading3, fontSize: "1.1em", fontWeight: "650" },
  { tag: tags.strong, fontWeight: "700" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through" },
  { tag: [tags.monospace, tags.literal], fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" },
  { tag: tags.link, color: "var(--link)" },
  { tag: tags.quote, color: "var(--secondary)" },
]);

export const editorTheme = [
  syntaxHighlighting(highlights),
  EditorView.theme({
    "&": { height: "100%", background: "transparent", color: "var(--text)" },
    ".cm-scroller": {
      overflow: "auto",
      fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
      fontSize: "var(--editor-size)",
      lineHeight: "1.55",
      padding: "8px 24px",
    },
    ".cm-content": { caretColor: "var(--text)", minHeight: "100%" },
    ".cm-line": { padding: "0" },
    ".cm-focused": { outline: "none" },
    ".cm-cursor": { borderLeftColor: "var(--text)" },
    ".cm-selectionBackground, ::selection": { backgroundColor: "var(--selection) !important" },
    ".cm-gutters": { display: "none" },
    ".cm-markdown-marker": { color: "var(--marker)", transition: "color 100ms ease" },
    ".cm-markdown-marker-active": { color: "var(--text)" },
    ".cm-list-bullet": { display: "inline-block", width: "0.65em", textAlign: "center", color: "var(--text)" },
  }),
];
