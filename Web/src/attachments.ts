import { syntaxTree } from "@codemirror/language";
import { EditorSelection, RangeSetBuilder, StateEffect, StateField, type EditorState } from "@codemirror/state";
import { Decoration, EditorView, WidgetType } from "@codemirror/view";
import { isolateHistory } from "@codemirror/commands";
import { sendToNative } from "./bridge";

export const attachmentBaseURL = StateEffect.define<string>();
export const beginImageImport = StateEffect.define<{ id: string; from: number; to: number }>();
export const endImageImport = StateEffect.define<null>();
export const pendingImageImport = StateField.define<{ id: string; from: number; to: number } | null>({
  create: () => null,
  update(value, transaction) {
    if (value) {
      const from = transaction.changes.mapPos(value.from, 1);
      value = { ...value, from, to: value.from === value.to ? from : Math.max(from, transaction.changes.mapPos(value.to, -1)) };
    }
    for (const effect of transaction.effects) {
      if (effect.is(beginImageImport)) value = effect.value;
      if (effect.is(endImageImport)) value = null;
    }
    return value;
  },
});

class ImageWidget extends WidgetType {
  constructor(readonly url: string, readonly label: string) { super(); }
  eq(other: ImageWidget) { return other.url === this.url && other.label === this.label; }
  toDOM() {
    const button = document.createElement("button");
    button.className = "cm-attachment-image";
    button.type = "button";
    button.setAttribute("aria-label", `Preview ${this.label || "image"}`);
    button.title = "Open image preview";
    const image = document.createElement("img");
    image.src = this.url;
    image.alt = this.label;
    image.draggable = false;
    button.append(image);
    const status = document.createElement("span");
    status.textContent = "Loading image…";
    status.className = "cm-attachment-status";
    button.append(status);
    let failed = false;
    let retry = 0;
    image.onload = () => {
      failed = false;
      status.remove(); button.classList.add("is-loaded");
      button.setAttribute("aria-label", `Preview ${this.label || "image"}`);
      button.title = "Open image preview";
    };
    image.onerror = () => {
      image.remove();
      failed = true;
      status.textContent = "Image unavailable. Tap to retry.";
      button.setAttribute("aria-label", `Retry ${this.label || "image"}`);
      button.title = "Retry image download";
    };
    button.onmousedown = (event) => event.preventDefault();
    button.onclick = () => {
      if (failed) {
        failed = false;
        status.textContent = "Loading image…";
        button.prepend(image);
        const url = new URL(this.url);
        url.searchParams.set("retry", String(++retry));
        image.src = url.toString();
      } else if (button.classList.contains("is-loaded")) {
        sendToNative({ version: 1, type: "previewImage", path: decodeURIComponent(new URL(this.url).pathname.slice(1)) });
      }
    };
    return button;
  }
  ignoreEvent() { return true; }
}

export function imageRanges(state: EditorState) {
  const images: Array<{ from: number; to: number; path: string; label: string }> = [];
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== "Image") return;
    const destination = node.node.getChild("URL");
    if (!destination) return;
    const raw = state.sliceDoc(destination.from, destination.to);
    const path = raw.startsWith("<") && raw.endsWith(">") ? raw.slice(1, -1) : raw;
    if (!path.includes("attachments/") || /^[a-z]+:/i.test(path) || path.startsWith("/")) return;
    const label = state.sliceDoc(node.from + 2, destination.from).replace(/\]\($/, "");
    images.push({ from: node.from, to: node.to, path, label });
    return false;
  } });
  return images;
}

export const attachmentPresentation = StateField.define<{ baseURL: string; decorations: ReturnType<RangeSetBuilder<Decoration>["finish"]> }>({
  create: () => ({ baseURL: "", decorations: Decoration.none }),
  update(value, transaction) {
    let baseURL = value.baseURL;
    for (const effect of transaction.effects) if (effect.is(attachmentBaseURL)) baseURL = effect.value;
    const builder = new RangeSetBuilder<Decoration>();
    if (baseURL) for (const image of imageRanges(transaction.state)) {
      const url = new URL(image.path, baseURL);
      if (url.host !== "attachment" || url.protocol !== "jot:") continue;
      // Keep the editable line around the widget so a caret can exist before an image at document start.
      builder.add(image.from, image.to, Decoration.replace({ widget: new ImageWidget(url.href, image.label) }));
    }
    return { baseURL, decorations: builder.finish() };
  },
  provide: (field) => [EditorView.decorations.from(field, (value) => value.decorations),
    EditorView.atomicRanges.of((view) => view.state.field(field).decorations)],
});

export function insertImportedImage(view: EditorView, requestID: string, path: string, baseURL: string): boolean {
  const pending = view.state.field(pendingImageImport);
  if (!pending || pending.id !== requestID) return false;
  const before = view.state.sliceDoc(0, pending.from);
  const after = view.state.sliceDoc(pending.to);
  const prefix = before && !before.endsWith("\n\n") ? (before.endsWith("\n") ? "\n" : "\n\n") : "";
  const suffix = after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n";
  const insert = `${prefix}![Image](${path})${suffix}`;
  view.dispatch({
    changes: { from: pending.from, to: pending.to, insert },
    selection: EditorSelection.cursor(pending.from + insert.length + (suffix === "" ? 2 : suffix === "\n" ? 1 : 0)),
    effects: [endImageImport.of(null), attachmentBaseURL.of(baseURL)],
    annotations: isolateHistory.of("full"),
    userEvent: "input.paste",
    scrollIntoView: true,
  });
  return true;
}
