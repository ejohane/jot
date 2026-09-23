import { RangeSetBuilder, StateEffect, StateField } from "@codemirror/state";
import { Decoration, EditorView, WidgetType } from "@codemirror/view";

type Preview = { from: number; to: number; text: string };
export const beginDictation = StateEffect.define<{ from: number; to: number }>();
export const reviseDictation = StateEffect.define<string>();
export const clearDictation = StateEffect.define<void>();

class PreviewWidget extends WidgetType {
  constructor(readonly text: string) { super(); }
  eq(other: PreviewWidget) { return other.text === this.text; }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-dictation-preview";
    span.textContent = this.text || "Listening…";
    span.setAttribute("aria-label", `Provisional dictation: ${this.text || "Listening"}`);
    return span;
  }
}

export const dictationPreview = StateField.define<Preview | null>({
  create: () => null,
  update(preview, transaction) {
    if (preview && transaction.docChanged) {
      const previous = preview;
      let overlapsReplacement = false;
      transaction.changes.iterChangedRanges((from, to) => {
        if (previous.from < previous.to && from < previous.to && to > previous.from) overlapsReplacement = true;
      });
      preview = overlapsReplacement ? null : {
        ...preview,
        from: transaction.changes.mapPos(preview.from, 1),
        to: transaction.changes.mapPos(preview.to, -1),
      };
    }
    for (const effect of transaction.effects) {
      if (effect.is(beginDictation)) preview = { ...effect.value, text: "" };
      if (effect.is(reviseDictation) && preview) preview = { ...preview, text: effect.value };
      if (effect.is(clearDictation)) preview = null;
    }
    return preview;
  },
  provide: (field) => EditorView.decorations.from(field, (preview) => {
    if (!preview) return Decoration.none;
    const builder = new RangeSetBuilder<Decoration>();
    builder.add(preview.from, preview.from, Decoration.widget({ widget: new PreviewWidget(preview.text), side: 1 }));
    return builder.finish();
  }),
});

export function insertionForDictation(view: EditorView, text: string, preview: Preview) {
  const before = preview.from > 0 ? view.state.doc.sliceString(preview.from - 1, preview.from) : "";
  const after = preview.to < view.state.doc.length ? view.state.doc.sliceString(preview.to, preview.to + 1) : "";
  return `${before && !/\s/.test(before) ? " " : ""}${text}${after && !/\s/.test(after) ? " " : ""}`;
}
