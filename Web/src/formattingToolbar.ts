import { syntaxTree } from "@codemirror/language";
import { Prec, StateEffect, StateField } from "@codemirror/state";
import { EditorView, getTooltip, keymap, showTooltip, type Tooltip, type ViewUpdate } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";
import { toggleInlineFormat } from "./formatting";
import { sendToNative } from "./bridge";
import { applyLink, removeLink, selectedLink, setTextStyle, toggleInlineCode, type TextStyle } from "./selectionFormatting";

const visibility = StateEffect.define<boolean>();
const toolbarState = StateField.define<{ visible: boolean; tooltip: Tooltip | null }>({
  create: () => ({ visible: true, tooltip: null }),
  update(value, transaction) {
    let visible = value.visible;
    if (transaction.selection) visible = true;
    for (const effect of transaction.effects) if (effect.is(visibility)) visible = effect.value;
    const selection = transaction.state.selection.main;
    if ((selection.empty || !visible) && value.tooltip === null && visible === value.visible) return value;
    const tooltip = visible && !selection.empty && transaction.state.sliceDoc(selection.from, selection.to).trim()
      ? { pos: selection.from, end: selection.to, above: true, arrow: false, create: createToolbar }
      : null;
    return { visible, tooltip };
  },
  provide: (field) => showTooltip.from(field, (value) => value.tooltip),
});

function active(view: EditorView, name: string) {
  const selection = view.state.selection.main;
  for (let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(selection.from, 1); node; node = node.parent) {
    if (node.name === name && node.to >= selection.to) return true;
  }
  return false;
}

function createToolbar(view: EditorView) {
  const dom = document.createElement("div");
  dom.className = "formatting-toolbar";
  dom.setAttribute("role", "toolbar");
  dom.setAttribute("aria-label", "Text formatting");
  const row = document.createElement("div");
  row.className = "formatting-toolbar-row";
  dom.append(row);
  let panel: HTMLElement | undefined;
  let opener: HTMLButtonElement | undefined;
  const closePanel = () => {
    panel?.remove(); panel = undefined;
    opener?.setAttribute("aria-expanded", "false");
  };
  function button(label: string, content: string, action: () => void, className = "") {
    const control = document.createElement("button");
    control.type = "button";
    control.className = className;
    control.setAttribute("aria-label", label);
    control.title = label;
    control.innerHTML = content;
    control.addEventListener("mousedown", (event) => event.preventDefault());
    control.addEventListener("click", action);
    row.append(control);
    return control;
  }
  const link = button("Edit link", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m10 13 4-4M8 16l-1 1a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0m0 2 1-1a4 4 0 0 1 6 6l-5 5a4 4 0 0 1-6 0" transform="translate(2 1)"/></svg>', () => {
    if (opener === link && panel) { closePanel(); view.focus(); return; }
    closePanel(); opener = link;
    link.setAttribute("aria-expanded", "true");
    const form = document.createElement("form");
    panel = form;
    form.className = "formatting-toolbar-panel formatting-link-form";
    const input = document.createElement("input");
    input.type = "text"; input.placeholder = "Paste or type a link";
    input.setAttribute("aria-label", "Link address");
    input.value = selectedLink(view)?.url ?? "";
    const submit = document.createElement("button");
    submit.type = "submit"; submit.textContent = "Apply";
    form.append(input, submit);
    if (selectedLink(view)) {
      const remove = document.createElement("button");
      remove.type = "button"; remove.textContent = "Remove link";
      remove.addEventListener("click", () => removeLink(view));
      form.append(remove);
    }
    input.addEventListener("input", () => input.setCustomValidity(""));
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!applyLink(view, input.value)) { input.setCustomValidity("Enter a valid link address without spaces."); input.reportValidity(); }
    });
    dom.append(form); view.requestMeasure(); input.focus();
  });
  link.setAttribute("aria-expanded", "false");
  const bold = button("Bold (⌘B)", "B", () => toggleInlineFormat(view, "bold"), "formatting-bold");
  const italic = button("Italic (⌘I)", "I", () => toggleInlineFormat(view, "italic"), "formatting-italic");
  bold.setAttribute("aria-pressed", String(active(view, "StrongEmphasis")));
  italic.setAttribute("aria-pressed", String(active(view, "Emphasis")));
  const text = button("Text style", 'Text <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="m3 6 5 5 5-5"/></svg>', () => {
    if (opener === text && panel) { closePanel(); view.focus(); return; }
    closePanel(); opener = text; text.setAttribute("aria-expanded", "true");
    const menu = document.createElement("div");
    panel = menu;
    menu.className = "formatting-toolbar-panel formatting-text-menu";
    const coords = view.coordsAtPos(view.state.selection.main.from);
    if (coords) {
      const available = Math.max(coords.top - 8, window.innerHeight - coords.bottom - 8);
      menu.style.maxHeight = `${Math.max(34, Math.min(350, available - row.offsetHeight - 27))}px`;
    }
    menu.setAttribute("role", "menu"); menu.setAttribute("aria-label", "Text style");
    const styles: [TextStyle, string][] = [["paragraph", "Text"], ["heading1", "Heading 1"], ["heading2", "Heading 2"], ["heading3", "Heading 3"], ["bullet", "Bulleted list"], ["number", "Numbered list"], ["task", "Checklist"], ["quote", "Quote"]];
    for (const [style, label] of styles) {
      const item = document.createElement("button");
      item.type = "button"; item.textContent = label; item.setAttribute("role", "menuitem");
      item.addEventListener("mousedown", (event) => event.preventDefault());
      item.addEventListener("click", () => setTextStyle(view, style));
      menu.append(item);
    }
    const code = document.createElement("button");
    code.type = "button"; code.textContent = "Inline code"; code.setAttribute("role", "menuitem");
    code.addEventListener("mousedown", (event) => event.preventDefault());
    code.addEventListener("click", () => toggleInlineCode(view));
    menu.append(code);
    dom.append(menu); view.requestMeasure(); menu.querySelector<HTMLButtonElement>("button")?.focus();
  }, "formatting-text");
  text.setAttribute("aria-haspopup", "menu"); text.setAttribute("aria-expanded", "false");
  dom.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault(); event.stopPropagation();
      if (panel) { closePanel(); opener?.focus(); view.requestMeasure(); }
      else { view.dispatch({ effects: visibility.of(false) }); view.focus(); }
    }
    if (panel?.getAttribute("role") === "menu" && ["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      const items = Array.from(panel.querySelectorAll("button"));
      const index = items.indexOf(document.activeElement as HTMLButtonElement);
      const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 : (index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      items[next].focus();
    }
  });
  dom.addEventListener("focusout", () => queueMicrotask(() => {
    if (view.dom.isConnected && !view.hasFocus && !dom.contains(document.activeElement)) view.dispatch({ effects: visibility.of(false) });
  }));
  let lastBounds = "";
  const reportBounds = () => {
    const rect = dom.getBoundingClientRect();
    const bounds = dom.isConnected && rect.bottom > 0 && rect.top < window.innerHeight
      ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height } : null;
    const serialized = JSON.stringify(bounds);
    if (serialized === lastBounds) return;
    lastBounds = serialized;
    sendToNative({ version: 1, type: "formattingToolbarBounds", bounds });
  };
  // CodeMirror moves an offscreen tooltip without calling positioned().
  const positionObserver = new MutationObserver(reportBounds);
  positionObserver.observe(dom, { attributes: true, attributeFilter: ["style"] });
  return {
    dom,
    offset: { x: 0, y: 6 },
    positioned: reportBounds,
    destroy: () => {
      positionObserver.disconnect();
      sendToNative({ version: 1, type: "formattingToolbarBounds", bounds: null });
    },
    update: (update: ViewUpdate) => {
      if (update.docChanged || update.selectionSet) closePanel();
      bold.setAttribute("aria-pressed", String(active(view, "StrongEmphasis")));
      italic.setAttribute("aria-pressed", String(active(view, "Emphasis")));
    },
    getCoords: (pos: number) => {
      const start = view.coordsAtPos(pos) ?? view.contentDOM.getBoundingClientRect();
      const end = view.coordsAtPos(view.state.selection.main.to);
      const center = end && Math.abs(end.top - start.top) < 2 ? (start.left + end.right) / 2 : start.left;
      const left = center - dom.offsetWidth / 2;
      return { left, right: center, top: start.top, bottom: start.bottom };
    },
  };
}

export const formattingToolbar = [
  toolbarState,
  EditorView.domEventHandlers({
    focus: (_event, view) => {
      if (!view.state.field(toolbarState).visible) view.dispatch({ effects: visibility.of(true) });
    },
    blur: (event, view) => {
      if (view.state.field(toolbarState).tooltip && !(event.relatedTarget instanceof Element && event.relatedTarget.closest(".formatting-toolbar"))) view.dispatch({ effects: visibility.of(false) });
    },
  }),
  Prec.high(keymap.of([
    { key: "Escape", run: (view) => {
      if (!view.state.field(toolbarState).tooltip) return false;
      view.dispatch({ effects: visibility.of(false) }); return true;
    } },
    { key: "Alt-F10", run: (view) => {
      const tooltip = view.state.field(toolbarState).tooltip;
      if (!tooltip) return false;
      getTooltip(view, tooltip)?.dom.querySelector<HTMLButtonElement>("button")?.focus(); return true;
    } },
  ])),
];
