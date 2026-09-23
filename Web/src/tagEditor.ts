import { acceptCompletion, autocompletion, completionKeymap, type CompletionContext } from "@codemirror/autocomplete";
import { StateEffect, StateField, Prec } from "@codemirror/state";
import { Decoration, EditorView, keymap, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { findInlineTags } from "./tags";

export const setTagVocabulary = StateEffect.define<string[]>();
export const tagVocabulary = StateField.define<string[]>({
  create: () => [],
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(setTagVocabulary)) return effect.value;
    return value;
  },
});

function tagCompletions(context: CompletionContext) {
  if (!context.state.selection.main.empty) return null;
  const tag = findInlineTags(context.state.doc.toString()).find((item) => item.from < context.pos && item.to >= context.pos);
  if (!tag) return null;
  const prefix = context.state.sliceDoc(tag.from + 1, context.pos);
  const options = context.state.field(tagVocabulary)
    .filter((name) => name.toLowerCase().startsWith(prefix.toLowerCase()) && name.toLowerCase() !== tag.name.toLowerCase())
    .map((name) => ({ label: `#${name}`, apply: `#${name}`, type: "keyword" }));
  return options.length ? { from: tag.from, to: tag.to, options, filter: false } : null;
}

const tagMarks = ViewPlugin.fromClass(class {
  decorations;
  constructor(view: EditorView) { this.decorations = this.build(view); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.viewportChanged) this.decorations = this.build(update.view);
  }
  build(view: EditorView) {
    return Decoration.set(findInlineTags(view.state.doc.toString()).map(({ from, to }) =>
      Decoration.mark({ class: "cm-inline-tag" }).range(from, to)));
  }
}, { decorations: (value) => value.decorations });

export const inlineTagEditor = [
  tagVocabulary,
  tagMarks,
  autocompletion({ override: [tagCompletions], defaultKeymap: false, activateOnTyping: true, interactionDelay: 0 }),
  Prec.highest(keymap.of([{ key: "Tab", run: acceptCompletion }, ...completionKeymap.filter((binding) => binding.key !== "Enter" && binding.key !== "Tab")])),
];
