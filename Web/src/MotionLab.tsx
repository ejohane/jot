import { deleteMarkupBackward, insertNewlineContinueMarkupCommand, markdown } from "@codemirror/lang-markdown";
import { history, historyKeymap } from "@codemirror/commands";
import { EditorSelection, EditorState, Transaction } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { GFM } from "@lezer/markdown";
import { useEffect, useRef, useState } from "react";
import { editorTheme } from "./editorTheme";
import { markdownPresentation } from "./presentation";
import { inlineTagEditor } from "./tagEditor";
import { adjacentIndex, defaultSettings, edgeDisplacement, mergeSettings, notePreview, presets, shouldCommit, type LabNote, type MotionSettings } from "./motion";

type Payload = { notes: LabNote[]; selectedID: string; settings: Partial<MotionSettings> };
type NativeMessage = { type: "hydrate" | "selected"; payload: Payload } | { type: "saved" | "saveFailed"; id: string } | { type: "exported" };
declare global {
  interface Window {
    MotionLabNative?: { receive(message: NativeMessage): void };
  }
}
function send(message: Record<string, unknown>) { window.webkit?.messageHandlers?.motionLab?.postMessage(message); }
const continueList = insertNewlineContinueMarkupCommand({ nonTightLists: false });

type Gesture = { direction: -1 | 1; effort: number; events: number; started: number; timer?: number };

export function MotionLab() {
  const host = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const notesRef = useRef<LabNote[]>([]);
  const selectedRef = useRef("");
  const settingsRef = useRef<MotionSettings>(defaultSettings);
  const loadingRef = useRef(false);
  const gestureRef = useRef<Gesture | null>(null);
  const cooldownRef = useRef(0);
  const hoverTimer = useRef<number | undefined>(undefined);
  const scrollSaveTimer = useRef<number | undefined>(undefined);
  const railRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef(false);
  const [notes, setNotes] = useState<LabNote[]>([]);
  const [selectedID, setSelectedID] = useState("");
  const [settings, setSettings] = useState<MotionSettings>(defaultSettings);
  const [previewID, setPreviewID] = useState<string | null>(null);
  const [edge, setEdge] = useState<{ id: string; direction: -1 | 1; distance: number; effort: number; armed: boolean } | null>(null);
  const [exported, setExported] = useState(false);
  const [saveStatus, setSaveStatus] = useState("Sample notes · local only");

  const saveCurrent = (view: EditorView) => {
    if (loadingRef.current || !selectedRef.current) return;
    const selection = view.state.selection.main;
    const text = view.state.doc.toString();
    const id = selectedRef.current;
    const updated = notesRef.current.map(note => note.id === id ? {
      ...note, text, anchor: selection.anchor, head: selection.head, scrollTop: view.scrollDOM.scrollTop,
    } : note);
    notesRef.current = updated;
    setNotes(updated);
    setSaveStatus("Saving sample…");
    send({ type: "save", id, text, anchor: selection.anchor, head: selection.head, scrollTop: view.scrollDOM.scrollTop });
  };

  const select = (id: string) => {
    if (!notesRef.current.some(note => note.id === id) || selectedRef.current === id) { setPreviewID(null); return; }
    if (scrollSaveTimer.current) window.clearTimeout(scrollSaveTimer.current);
    if (viewRef.current) saveCurrent(viewRef.current);
    clearGesture();
    setPreviewID(null);
    send({ type: "select", id });
  };

  const clearGesture = () => {
    if (gestureRef.current?.timer) window.clearTimeout(gestureRef.current.timer);
    gestureRef.current = null;
    setEdge(null);
  };

  const applyPayload = (payload: Payload) => {
    const selected = payload.notes.find(note => note.id === payload.selectedID) ?? payload.notes[0];
    if (!selected || !viewRef.current) return;
    notesRef.current = payload.notes;
    selectedRef.current = selected.id;
    setNotes(payload.notes);
    setSelectedID(selected.id);
    const nextSettings = mergeSettings(payload.settings);
    settingsRef.current = nextSettings;
    setSettings(nextSettings);
    loadingRef.current = true;
    const view = viewRef.current;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: selected.text },
      selection: EditorSelection.single(Math.min(selected.anchor, selected.text.length), Math.min(selected.head, selected.text.length)),
      annotations: Transaction.addToHistory.of(false),
    });
    requestAnimationFrame(() => {
      view.scrollDOM.scrollTop = selected.scrollTop;
      loadingRef.current = false;
      view.focus();
    });
    setPreviewID(null);
    setEdge(null);
    setSaveStatus("Saved locally");
  };

  useEffect(() => {
    if (!host.current) return;
    const state = EditorState.create({
      extensions: [
        markdown({ extensions: GFM, addKeymap: false, pasteURLAsLink: false }),
        markdownPresentation,
        inlineTagEditor,
        editorTheme,
        EditorView.lineWrapping,
        history(),
        keymap.of([
          { key: "Enter", run: continueList },
          { key: "Enter", run: view => { view.dispatch({ ...view.state.replaceSelection("\n"), scrollIntoView: true, userEvent: "input.type" }); return true; } },
          { key: "Shift-Enter", run: view => { view.dispatch({ ...view.state.replaceSelection("\n"), scrollIntoView: true, userEvent: "input.type" }); return true; } },
          { key: "Backspace", run: deleteMarkupBackward },
          ...historyKeymap,
        ]),
        EditorView.updateListener.of(update => {
          if (!loadingRef.current && (update.docChanged || update.selectionSet)) saveCurrent(update.view);
        }),
      ],
    });
    const view = new EditorView({ state, parent: host.current });
    viewRef.current = view;
    const onScroll = () => {
      if (loadingRef.current) return;
      if (scrollSaveTimer.current) window.clearTimeout(scrollSaveTimer.current);
      scrollSaveTimer.current = window.setTimeout(() => saveCurrent(view), 180);
    };
    view.scrollDOM.addEventListener("scroll", onScroll, { passive: true });
    const onWheel = (event: WheelEvent) => {
      if (Date.now() < cooldownRef.current || !selectedRef.current || event.deltaY === 0) return;
      const direction: -1 | 1 = event.deltaY < 0 ? -1 : 1;
      const index = notesRef.current.findIndex(note => note.id === selectedRef.current);
      const next = adjacentIndex(index, direction, notesRef.current.length);
      if (next === null) { clearGesture(); return; }
      const maxScroll = Math.max(0, view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight);
      const atEdge = direction < 0 ? view.scrollDOM.scrollTop <= 1 : view.scrollDOM.scrollTop >= maxScroll - 1;
      if (!atEdge) { clearGesture(); return; }
      event.preventDefault();
      const now = performance.now();
      let gesture = gestureRef.current;
      if (!gesture || gesture.direction !== direction || now - gesture.started > 1400) {
        clearGesture();
        gesture = { direction, effort: 0, events: 0, started: now };
        gestureRef.current = gesture;
      }
      gesture.effort += Math.min(Math.abs(event.deltaY), 80);
      gesture.events += 1;
      const settings = settingsRef.current;
      const shortNote = maxScroll < 24;
      const armed = shouldCommit(gesture.effort, settings.commitThreshold, gesture.events, now - gesture.started, shortNote);
      const distance = edgeDisplacement(gesture.effort, settings.resistance);
      setEdge({ id: notesRef.current[next].id, direction, distance, effort: gesture.effort, armed });
      if (gesture.timer) window.clearTimeout(gesture.timer);
      gesture.timer = window.setTimeout(() => {
        const current = gestureRef.current;
        if (current !== gesture) return;
        const ready = shouldCommit(current.effort, settingsRef.current.commitThreshold, current.events, performance.now() - current.started, shortNote);
        const target = notesRef.current[next];
        clearGesture();
        if (ready && target) {
          cooldownRef.current = Date.now() + 800;
          select(target.id);
        }
      }, 170);
    };
    view.scrollDOM.addEventListener("wheel", onWheel, { passive: false });
    window.MotionLabNative = { receive(message) {
      if (message.type === "hydrate" || message.type === "selected") applyPayload(message.payload);
      else if (message.type === "saved") setSaveStatus("Saved locally");
      else if (message.type === "saveFailed") setSaveStatus("Save failed · stay on this note");
      else if (message.type === "exported") { setExported(true); window.setTimeout(() => setExported(false), 1800); }
    } };
    send({ type: "ready" });
    return () => {
      view.scrollDOM.removeEventListener("scroll", onScroll);
      view.scrollDOM.removeEventListener("wheel", onWheel);
      if (hoverTimer.current) window.clearTimeout(hoverTimer.current);
      if (scrollSaveTimer.current) window.clearTimeout(scrollSaveTimer.current);
      clearGesture();
      view.destroy();
      viewRef.current = null;
      delete window.MotionLabNative;
    };
  }, []);

  const updateSetting = (key: keyof MotionSettings, value: number) => {
    const next = { ...settingsRef.current, [key]: value };
    settingsRef.current = next;
    setSettings(next);
    send({ type: "settings", value: next });
  };
  const applyPreset = (preset: MotionSettings) => {
    settingsRef.current = preset;
    setSettings(preset);
    send({ type: "settings", value: preset });
  };
  const preview = (id: string | null, immediate = false) => {
    if (hoverTimer.current) window.clearTimeout(hoverTimer.current);
    if (immediate || !id) { setPreviewID(id); return; }
    hoverTimer.current = window.setTimeout(() => setPreviewID(id), settingsRef.current.previewDelayMs);
  };
  const pointInsideRail = (clientX: number, clientY: number) => {
    const rect = railRef.current?.getBoundingClientRect();
    return !!rect && clientX >= rect.left && clientX <= rect.right && clientY >= rect.top && clientY <= rect.bottom;
  };
  const nearestRailNote = (clientY: number) => {
    const stops = Array.from(railRef.current?.querySelectorAll<HTMLButtonElement>(".rail-stop") ?? []);
    return stops.reduce<{ id: string; distance: number } | null>((best, stop) => {
      const rect = stop.getBoundingClientRect();
      const distance = Math.abs(clientY - (rect.top + rect.height / 2));
      return !best || distance < best.distance ? { id: stop.dataset.id || "", distance } : best;
    }, null)?.id;
  };
  const visiblePreviewID = edge?.id ?? previewID;
  const previewNote = notes.find(note => note.id === visiblePreviewID);
  const activeIndex = notes.findIndex(note => note.id === selectedID);
  const edgeLabel = edge?.direction === -1 ? "Older note" : "Newer note";

  return <main className="lab-shell">
    <aside className="lab-controls" aria-label="Motion tuning">
      <div className="lab-heading"><h1>Motion lab</h1><span>DEVELOPER JIG</span></div>
      <p className="lab-intro">Feel the transition on a trackpad. All notes here are disposable samples.</p>
      <div className="lab-preset-row" aria-label="Presets">{Object.entries(presets).map(([name, preset]) => <button key={name} onClick={() => applyPreset(preset)} className={JSON.stringify(settings) === JSON.stringify(preset) ? "is-active" : ""}>{name}</button>)}</div>
      <div className="lab-control-group"><h2>Edge gesture</h2>
        <Slider label="Resistance" detail="Drag weight" value={settings.resistance} min={0.6} max={2.4} step={0.05} unit="×" onChange={value => updateSetting("resistance", value)} />
        <Slider label="Preview reveal" detail="Effort to show neighbor" value={settings.revealPoint} min={20} max={120} step={5} unit="px" onChange={value => updateSetting("revealPoint", value)} />
        <Slider label="Commit threshold" detail="Effort before release opens" value={settings.commitThreshold} min={120} max={450} step={5} unit="px" onChange={value => updateSetting("commitThreshold", value)} />
        <Slider label="Spring / snap" detail="Return animation" value={settings.snapMs} min={100} max={650} step={10} unit="ms" onChange={value => updateSetting("snapMs", value)} />
      </div>
      <div className="lab-control-group"><h2>Timeline</h2>
        <Slider label="Stop spacing" detail="One stop per note" value={settings.railSpacing} min={12} max={36} step={1} unit="px" onChange={value => updateSetting("railSpacing", value)} />
        <Slider label="Preview delay" detail="Hover response" value={settings.previewDelayMs} min={0} max={600} step={10} unit="ms" onChange={value => updateSetting("previewDelayMs", value)} />
      </div>
      <div className="lab-actions"><button onClick={() => applyPreset(defaultSettings)}>Reset controls</button><button onClick={() => send({ type: "export" })}>{exported ? "Copied values" : "Export values"}</button></div>
      <button className="lab-reset-notes" onClick={() => send({ type: "reset" })}>Restore sample notes</button>
      <p className="lab-tip">Scroll normally inside a note. At an edge, keep pushing, then release. Top opens older; bottom opens newer.</p>
    </aside>
    <section className="lab-stage" aria-label="Sample note editor">
      <header className="lab-stage-header"><span className="lab-stage-index">{activeIndex + 1} / {notes.length}</span><span>{notes.find(note => note.id === selectedID) ? notePreview(notes[activeIndex]).date : "Loading samples…"}</span><span className="lab-save" role="status">{saveStatus}</span></header>
      <div className="lab-editor-region">
        {edge && edge.effort >= settings.revealPoint && previewNote && <div className={`lab-edge-preview ${edge.direction < 0 ? "at-top" : "at-bottom"}`} aria-live="polite"><span>{edgeLabel} · {edge.armed ? "Release to open" : "Keep pushing"}</span><strong>{notePreview(previewNote).title}</strong><small>{notePreview(previewNote).excerpt}</small></div>}
        <div ref={host} className="lab-editor" style={{ transform: edge ? `translateY(${edge.direction < 0 ? edge.distance : -edge.distance}px)` : "translateY(0)", transitionDuration: edge ? "0ms" : `${settings.snapMs}ms` }} role="textbox" aria-label="Editable sample Markdown note" />
      </div>
      <footer className="lab-stage-footer"><span>↑ older</span><span>Push past the edge · release to open</span><span>newer ↓</span></footer>
    </section>
    <aside className="lab-timeline" aria-label="Note timeline">
      <div className="lab-rail-caption">NOTES</div>
      <div className="lab-rail" ref={railRef} onPointerDown={event => { dragRef.current = true; event.currentTarget.setPointerCapture(event.pointerId); preview(nearestRailNote(event.clientY) ?? null, true); }} onPointerMove={event => { if (dragRef.current) preview(nearestRailNote(event.clientY) ?? null, true); }} onPointerUp={event => { if (!dragRef.current) return; dragRef.current = false; const id = pointInsideRail(event.clientX, event.clientY) ? nearestRailNote(event.clientY) : null; if (id) select(id); else preview(null, true); }} onPointerCancel={() => { dragRef.current = false; preview(null, true); }} onPointerLeave={() => { if (!dragRef.current) preview(null, true); }}>
        {notes.map((note, index) => <button key={note.id} data-id={note.id} className={`rail-stop ${note.id === selectedID ? "is-current" : ""} ${note.id === previewID ? "is-preview" : ""}`} style={{ height: settings.railSpacing }} aria-label={`Open note ${index + 1}: ${notePreview(note).title}`} aria-current={note.id === selectedID ? "true" : undefined} onPointerEnter={() => { if (!dragRef.current) preview(note.id); }} onFocus={() => preview(note.id, true)} onBlur={() => preview(null, true)} onClick={() => select(note.id)}><span className="rail-mark" /></button>)}
      </div>
      {previewNote && !edge && <div className="lab-rail-preview" role="status"><small>{notePreview(previewNote).date}</small><strong>{notePreview(previewNote).title}</strong><span>{notePreview(previewNote).excerpt}</span><em>Click or release to open</em></div>}
    </aside>
  </main>;
}

function Slider({ label, detail, value, min, max, step, unit, onChange }: { label: string; detail: string; value: number; min: number; max: number; step: number; unit: string; onChange: (value: number) => void }) {
  return <label className="lab-slider"><span className="lab-slider-top"><span>{label}<small>{detail}</small></span><output>{value}{unit}</output></span><input type="range" value={value} min={min} max={max} step={step} onChange={event => onChange(Number(event.target.value))} /></label>;
}
