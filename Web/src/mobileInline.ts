import { invertedEffects, isolateHistory } from "@codemirror/commands";
import { syntaxTree } from "@codemirror/language";
import { Annotation, EditorSelection, EditorState, Facet, findClusterBreak, Prec, StateEffect, StateField, Transaction, type Extension, type TransactionSpec } from "@codemirror/state";
import { Decoration, Direction, EditorView, keymap } from "@codemirror/view";

// The source remains Markdown. Only edits that touch emphasis are reconstructed;
// loading, presentation, and edits elsewhere never serialize the whole document.
export const mobileInlineEnabled = Facet.define<boolean, boolean>({ combine: values => values.some(Boolean) });
const handled = Annotation.define<boolean>();
const setTyping = StateEffect.define<number | null>();
export const resetMobileInline = StateEffect.define<void>();
type Conversion = { from: number; to: number; raw: boolean };
const conversion = StateEffect.define<Conversion | null>({
  map: (value, changes) => value && ({ ...value, from: changes.mapPos(value.from), to: changes.mapPos(value.to) }),
});
const composingSpans = StateEffect.define<Span[] | null>();
export const mobileInlineState = StateField.define<{ typing: number | null; conversion: Conversion | null; composing: Span[] | null }>({
  create: () => ({ typing: null, conversion: null, composing: null }),
  update(value, tr) {
    let typing = value.typing;
    let converted = value.conversion;
    let composing = value.composing;
    if (composing && tr.docChanged) composing = composing.map(span => ({ ...span, from: tr.changes.mapPos(span.from), to: tr.changes.mapPos(span.to) }));
    if (tr.selection && !tr.docChanged && !tr.annotation(handled)) typing = null;
    if (tr.docChanged) converted = converted?.raw && !tr.isUserEvent("input.format")
      ? { ...converted, from: tr.changes.mapPos(converted.from), to: tr.changes.mapPos(converted.to) } : null;
    for (const effect of tr.effects) {
      if (effect.is(setTyping)) typing = effect.value;
      if (effect.is(conversion)) converted = effect.value;
      if (effect.is(composingSpans)) composing = effect.value;
      if (effect.is(resetMobileInline)) { typing = null; converted = null; composing = null; }
    }
    return { typing, conversion: converted, composing };
  },
});

type Span = { from: number; to: number; start: number; end: number; bit: number };
type Unit = { text: string; style: number; from: number; to: number; protected?: boolean };
const spanCache = new WeakMap<EditorState, Span[]>();
export function emphasisSpans(state: EditorState): Span[] {
  const cached = spanCache.get(state);
  if (cached) return cached;
  const spans: Span[] = [];
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== "StrongEmphasis" && node.name !== "Emphasis") return;
    const marks = node.node.getChildren("EmphasisMark");
    if (marks.length === 2) spans.push({ from: node.from, to: node.to, start: marks[0].to, end: marks[1].from, bit: node.name === "StrongEmphasis" ? 1 : 2 });
  } });
  const source = state.doc.toString();
  const complete = spans.filter(span => {
    const marker = source[span.from];
    // A parser may recognize the inner *word* before the final star of
    // **word** arrives. Keep that incomplete outer construct literal.
    return !(span.from > 0 && source[span.from - 1] === marker
      && !spans.some(parent => parent !== span && ((parent.from < span.from && parent.start <= span.from && parent.end >= span.to) || parent.to === span.from)));
  });
  spanCache.set(state, complete);
  return complete;
}

function units(state: EditorState, from: number, to: number): Unit[] {
  const spans = emphasisSpans(state).filter(span => mobileMarkerHidden(state, span.from, span.to));
  const result: Unit[] = [];
  const source = state.doc.toString();
  const protectedRanges: { from: number; to: number }[] = [];
  const protectedNodes = new Set(["HeaderMark", "QuoteMark", "ListMark", "TaskMarker", "LinkMark", "URL", "LinkTitle", "InlineCode", "FencedCode", "CodeBlock", "Image", "HTMLBlock", "HTMLTag", "HorizontalRule"]);
  syntaxTree(state).iterate({ from, to, enter(node) {
    if (protectedNodes.has(node.name)) { protectedRanges.push({ from: node.from, to: node.to }); return false; }
  } });
  for (let pos = from; pos < to; pos++) {
    if (spans.some(span => pos >= span.from && pos < span.start || pos >= span.end && pos < span.to)) continue;
    result.push({ text: source[pos], style: spans.reduce((bits, span) => pos >= span.start && pos < span.end ? bits | span.bit : bits, 0), from: pos, to: pos + 1, protected: protectedRanges.some(range => pos >= range.from && pos < range.to) });
  }
  return result;
}
function offsetAt(list: Unit[], position: number) { return list.filter(unit => unit.to <= position).length; }
function caretStyle(state: EditorState, position: number): number {
  // Prefer the content on the left at a span's closing boundary.
  return emphasisSpans(state).filter(span => mobileMarkerHidden(state, span.from, span.to)).reduce((bits, span) => position > span.start && position <= span.to || position === span.start ? bits | span.bit : bits, 0);
}
export function mobileFormatActive(state: EditorState, format: "bold" | "italic"): boolean {
  const bit = format === "bold" ? 1 : 2;
  const selection = state.selection.main;
  if (selection.empty) return Boolean((state.field(mobileInlineState).typing ?? caretStyle(state, selection.head)) & bit);
  const selected = units(state, selection.from, selection.to).filter(unit => !unit.protected && !/\s/.test(unit.text));
  return selected.length > 0 && selected.every(unit => (unit.style & bit) !== 0);
}

// Keep whitespace outside delimiters at run boundaries, as CommonMark requires.
// Interior whitespace keeps its style; a pending typing style carries it forward.
function serialize(list: Unit[]) {
  const styles = list.map(unit => unit.text === "\n" ? 0 : unit.style);
  for (let start = 0; start < list.length;) {
    let end = start + 1;
    while (end < list.length && styles[end] === styles[start]) end++;
    let left = start, right = end;
    while (left < right && /\s/.test(list[left].text)) styles[left++] = 0;
    while (right > left && /\s/.test(list[right - 1].text)) styles[--right] = 0;
    start = end;
  }
  const endings = [new Array<number>(styles.length + 1), new Array<number>(styles.length + 1)];
  for (const [column, bit] of [1, 2].entries()) {
    endings[column][styles.length] = styles.length;
    for (let index = styles.length - 1; index >= 0; index--) {
      endings[column][index] = styles[index] & bit ? endings[column][index + 1] : index;
    }
  }
  let text = "";
  const before: number[] = [], after: number[] = [];
  let stack: string[] = [];
  for (let index = 0; index <= list.length; index++) {
    const style = styles[index] ?? 0;
    const bits = [...(style & 1 ? [1] : []), ...(style & 2 ? [2] : [])];
    // Keep the longest-lived style outermost. This avoids closing/reopening
    // italic when a selection removes bold from the middle of combined text.
    const lifetime = (bit: number) => endings[bit === 1 ? 0 : 1][index];
    bits.sort((a, b) => lifetime(b) - lifetime(a)
      || (stack.indexOf(a === 1 ? "**" : "*") < 0 ? 2 : stack.indexOf(a === 1 ? "**" : "*"))
      - (stack.indexOf(b === 1 ? "**" : "*") < 0 ? 2 : stack.indexOf(b === 1 ? "**" : "*")));
    const next = bits.map(bit => bit === 1 ? "**" : "*");
    let shared = 0;
    while (shared < stack.length && shared < next.length && stack[shared] === next[shared]) shared++;
    before[index] = text.length;
    for (let close = stack.length - 1; close >= shared; close--) text += stack[close];
    for (let open = shared; open < next.length; open++) text += next[open];
    after[index] = text.length;
    stack = next;
    if (index < list.length) text += list[index].text;
  }
  return { text, before, after };
}

function affectedRegion(state: EditorState, from: number, to: number) {
  let start = from, end = to;
  const spans = emphasisSpans(state);
  let changed = true;
  while (changed) {
    changed = false;
    for (const span of spans) {
      if (span.to < start || span.from > end) continue;
      const a = Math.min(start, span.from), b = Math.max(end, span.to);
      if (a !== start || b !== end) { start = a; end = b; changed = true; }
    }
  }
  return { from: start, to: end };
}

export function toggleMobileFormat(view: EditorView, format: "bold" | "italic", focus = true): boolean {
  if (view.state.readOnly) return true;
  const bit = format === "bold" ? 1 : 2;
  const selection = view.state.selection.main;
  if (selection.empty) {
    const style = view.state.field(mobileInlineState).typing ?? caretStyle(view.state, selection.head);
    view.dispatch({ effects: [setTyping.of(style ^ bit), conversion.of(null)], annotations: [handled.of(true), isolateHistory.of("full")], userEvent: "input.format" });
    if (focus) view.focus();
    return true;
  }
  const region = affectedRegion(view.state, selection.from, selection.to);
  const list = units(view.state, region.from, region.to);
  const start = offsetAt(list, selection.from), end = offsetAt(list, selection.to);
  const remove = mobileFormatActive(view.state, format);
  if (!list.slice(start, end).some(unit => !unit.protected && unit.text.trim())) return true;
  for (let index = start; index < end; index++) {
    if (!list[index].protected) list[index].style = remove ? list[index].style & ~bit : list[index].style | bit;
  }
  const result = serialize(list);
  const from = region.from + result.after[start], to = region.from + result.before[end];
  view.dispatch({
    changes: { ...region, insert: result.text },
    selection: EditorSelection.single(selection.anchor <= selection.head ? from : to, selection.anchor <= selection.head ? to : from),
    effects: setTyping.of(null), annotations: [handled.of(true), isolateHistory.of("full")], userEvent: "input.format", scrollIntoView: true,
  });
  if (focus) view.focus();
  return true;
}

function editTransaction(tr: Transaction): Transaction | TransactionSpec | readonly TransactionSpec[] {
  if (!tr.docChanged || tr.annotation(handled) || tr.startState.readOnly
    || !(tr.isUserEvent("input") || tr.isUserEvent("delete")) || tr.isUserEvent("input.format")
    || tr.isUserEvent("input.type.compose")) return tr;
  const changes: { from: number; to: number; text: string }[] = [];
  tr.changes.iterChanges((from, to, _a, _b, text) => changes.push({ from, to, text: text.toString() }));
  if (changes.length !== 1) return tr;
  const change = changes[0];
  const state = tr.startState;
  const inlineState = state.field(mobileInlineState);
  const typing = inlineState.typing;
  if (inlineState.conversion?.raw && change.from >= inlineState.conversion.from && change.to <= inlineState.conversion.to) return tr;
  const spans = emphasisSpans(state);
  const touches = spans.some(span => change.from <= span.to && change.to >= span.from);
  if (!touches && !typing) return tr;
  const region = affectedRegion(state, change.from, change.to);
  if (tr.isUserEvent("delete.backward") && region.from > 0) {
    region.from--;
    if (/[\uDC00-\uDFFF]/.test(state.sliceDoc(region.from, region.from + 1)) && region.from > 0) region.from--;
  }
  if (tr.isUserEvent("delete.forward") && region.to < state.doc.length) {
    region.to++;
    if (/[\uD800-\uDBFF]/.test(state.sliceDoc(region.to - 1, region.to)) && region.to < state.doc.length) region.to++;
  }
  const list = units(state, region.from, region.to);
  let start = offsetAt(list, change.from), end = offsetAt(list, change.to);
  // Native backward/forward deletion may initially target a hidden delimiter.
  // Delete one visible Unicode code point in the intended direction instead.
  if (tr.isUserEvent("delete") && start === end && change.from !== change.to) {
    if (tr.isUserEvent("delete.backward") && start > 0) {
      start = findClusterBreak(list.map(unit => unit.text).join(""), start, false);
    } else if (tr.isUserEvent("delete.backward")) {
      return { selection: EditorSelection.cursor(spans.find(span => span.from === region.from)?.start ?? region.from), annotations: handled.of(true) };
    } else if (end < list.length) {
      end = findClusterBreak(list.map(unit => unit.text).join(""), end, true);
    }
  }
  const inherited = typing ?? caretStyle(state, change.from);
  const inserted = change.text.split("").map(text => ({ text, style: text === "\n" ? 0 : inherited, from: change.from, to: change.from }));
  // Text after a paragraph break starts without inline formatting.
  let afterBreak = false;
  for (const unit of inserted) { if (unit.text === "\n") afterBreak = true; if (afterBreak) unit.style = 0; }
  list.splice(start, end - start, ...inserted);
  const result = serialize(list);
  const cursor = start + inserted.length;
  const nextStyle = change.text.includes("\n") ? 0 : inherited;
  return {
    changes: { ...region, insert: result.text },
    selection: EditorSelection.cursor(region.from + (nextStyle ? result.before[cursor] : result.after[cursor])),
    effects: [...tr.effects, setTyping.of(nextStyle)],
    annotations: [handled.of(true), Transaction.userEvent.of(tr.annotation(Transaction.userEvent) ?? "input.type")],
    scrollIntoView: tr.scrollIntoView,
  };
}

function conversionSpec(state: EditorState, previous: EditorState): TransactionSpec | null {
  const position = state.selection.main.head;
  const old = emphasisSpans(previous);
  const span = emphasisSpans(state).filter(span => span.to === position && !old.some(before => before.from === span.from && before.to === span.to)).sort((a, b) => a.from - b.from)[0];
  if (!span) return null;
  return { selection: EditorSelection.cursor(span.end), effects: [conversion.of({ from: span.from, to: span.to, raw: false }), setTyping.of(caretStyle(state, span.end))], annotations: [handled.of(true), isolateHistory.of("full")], userEvent: "input.convert" };
}

export function mobileMarkerHidden(state: EditorState, from: number, to: number): boolean {
  if (!emphasisSpans(state).some(span => span.from === from && span.to === to)) return false;
  const value = state.field(mobileInlineState, false);
  if (value?.composing && !value.composing.some(span => span.from === from && span.to === to)) return false;
  const raw = value?.conversion;
  return !(raw?.raw && from >= raw.from && to <= raw.to);
}

export function mobileClipboard(state: EditorState): { text: string; html: string } {
  const selection = state.selection.main;
  const list = units(state, selection.from, selection.to);
  const container = document.createElement("div");
  let text = "";
  for (let start = 0; start < list.length;) {
    let end = start + 1;
    while (end < list.length && list[end].style === list[start].style) end++;
    const content = list.slice(start, end).map(unit => unit.text).join("");
    text += content;
    let node: Node = document.createTextNode(content);
    if (list[start].style & 2) { const em = document.createElement("em"); em.append(node); node = em; }
    if (list[start].style & 1) { const strong = document.createElement("strong"); strong.append(node); node = strong; }
    container.append(node); start = end;
  }
  return { text, html: `<div style="white-space: pre-wrap">${container.innerHTML}</div>` };
}

function copySelection(event: ClipboardEvent, view: EditorView, cut: boolean): boolean {
  if (view.state.selection.main.empty || !event.clipboardData) return false;
  const content = mobileClipboard(view.state);
  event.clipboardData.setData("text/plain", content.text);
  event.clipboardData.setData("text/html", content.html);
  event.preventDefault();
  if (cut && !view.state.readOnly) view.dispatch({ ...view.state.replaceSelection(""), userEvent: "delete.cut", scrollIntoView: true });
  return true;
}

export function moveMobileCursor(view: EditorView, forward: boolean, extend = false): boolean {
  const selection = view.state.selection.main;
  const list = units(view.state, 0, view.state.doc.length);
  const text = list.map(unit => unit.text).join("");
  const position = offsetAt(list, selection.head);
  const next = !extend && !selection.empty ? offsetAt(list, forward ? selection.to : selection.from)
    : findClusterBreak(text, position, forward);
  const head = next < list.length ? list[next].from : list.at(-1)?.to ?? 0;
  view.dispatch({ selection: EditorSelection.single(extend ? selection.anchor : head, head), scrollIntoView: true, userEvent: "select" });
  return true;
}

export function mobileInlineEditing(): Extension {
  let composing: { from: number; to: number; style: number | null; previous: EditorState } | null = null;
  return [
    mobileInlineEnabled.of(true), mobileInlineState,
    Prec.high(keymap.of([false, true].flatMap(extend => [false, true].map(right => ({
      key: `${extend ? "Shift-" : ""}Arrow${right ? "Right" : "Left"}`,
      run: (view: EditorView) => moveMobileCursor(view, view.textDirectionAt(view.state.selection.main.head) === Direction.RTL ? !right : right, extend),
    }))))),
    EditorState.transactionFilter.of(editTransaction),
    invertedEffects.of(tr => {
      const effects = [];
      for (const effect of tr.effects) {
        if (effect.is(setTyping)) effects.push(setTyping.of(tr.startState.field(mobileInlineState).typing));
        if (effect.is(conversion)) effects.push(conversion.of(effect.value ? { ...effect.value, raw: !effect.value.raw } : tr.startState.field(mobileInlineState).conversion));
      }
      return effects;
    }),
    EditorView.atomicRanges.of(view => {
      const spans = emphasisSpans(view.state);
      const ranges = spans.flatMap(span => mobileMarkerHidden(view.state, span.from, span.to)
        ? [Decoration.replace({}).range(span.from, span.start), Decoration.replace({}).range(span.end, span.to)] : []);
      ranges.sort((a, b) => a.from - b.from || a.to - b.to);
      const merged: { from: number; to: number }[] = [];
      for (const range of ranges) {
        const last = merged.at(-1);
        if (last && range.from <= last.to) last.to = Math.max(last.to, range.to);
        else merged.push({ from: range.from, to: range.to });
      }
      return Decoration.set(merged.map(range => Decoration.replace({}).range(range.from, range.to)), true);
    }),
    EditorView.domEventHandlers({
      copy: (event, view) => copySelection(event, view, false),
      cut: (event, view) => copySelection(event, view, true),
      compositionstart: (_event, view) => {
        const selection = view.state.selection.main;
        composing = { from: selection.from, to: selection.to, style: view.state.field(mobileInlineState).typing, previous: view.state };
        view.dispatch({ effects: composingSpans.of(emphasisSpans(view.state)), annotations: Transaction.addToHistory.of(false) });
        return false;
      },
      compositionend: (_event, view) => {
        const snapshot = composing; composing = null;
        const pending = view.state.field(mobileInlineState).composing;
        queueMicrotask(() => {
          if (!snapshot || !pending || view.state.readOnly
            || view.state.field(mobileInlineState).composing !== pending) return;
          view.dispatch({ effects: composingSpans.of(null), annotations: Transaction.addToHistory.of(false) });
          // Do not touch marked text while WebKit owns it. The final formatting
          // edit joins the composition's undo event instead of adding a step.
          const end = view.state.selection.main.head;
          if (snapshot.style !== null && end > snapshot.from && snapshot.style !== caretStyle(view.state, snapshot.from)) {
            const region = affectedRegion(view.state, snapshot.from, end);
            const list = units(view.state, region.from, region.to);
            const start = offsetAt(list, snapshot.from), finish = offsetAt(list, end);
            for (let index = start; index < finish; index++) list[index].style = snapshot.style;
            const result = serialize(list);
            view.dispatch({ changes: { ...region, insert: result.text }, selection: { anchor: region.from + result.before[finish] },
              effects: setTyping.of(snapshot.style), annotations: [handled.of(true), isolateHistory.of("after")], userEvent: "input.type.compose" });
          }
          const spec = conversionSpec(view.state, snapshot.previous);
          if (spec) view.dispatch(spec);
        });
        return false;
      },
    }),
    EditorView.updateListener.of(update => {
      if (!update.docChanged || update.view.compositionStarted || update.transactions.some(tr => tr.annotation(handled) || tr.isUserEvent("undo") || tr.isUserEvent("redo"))) return;
      if (!update.transactions.some(tr => tr.isUserEvent("input.type"))) return;
      const spec = conversionSpec(update.state, update.startState);
      if (spec) queueMicrotask(() => { if (update.view.state === update.state) update.view.dispatch(spec); });
    }),
  ];
}
