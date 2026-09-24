import { useEffect, useRef, useState } from "react";
import { defaultSettings, notePreview, presets, type LabNote, type MotionSettings } from "./motion";

export type EdgePreview = { id: string; direction: -1 | 1; distance: number; effort: number; armed: boolean };

export function MotionLabControls({ settings, onSettings, onReset, onExport, onResetNotes, exported }: {
  settings: MotionSettings;
  onSettings: (settings: MotionSettings) => void;
  onReset: () => void;
  onExport: () => void;
  onResetNotes: () => void;
  exported: boolean;
}) {
  const update = (key: keyof MotionSettings, value: number) => onSettings({ ...settings, [key]: value });
  return <aside className="lab-controls" aria-label="Motion tuning">
    <div className="lab-heading"><h1>Motion lab</h1><span>JOT DEVELOPER MODE</span></div>
    <p className="lab-intro">Tune Jot's note movement on a trackpad. These are disposable sample notes.</p>
    <div className="lab-preset-row" aria-label="Presets">{Object.entries(presets).map(([name, preset]) => <button key={name} onClick={() => onSettings(preset)} className={JSON.stringify(settings) === JSON.stringify(preset) ? "is-active" : ""}>{name}</button>)}</div>
    <div className="lab-control-group"><h2>Edge gesture</h2>
      <Slider label="Resistance" detail="Drag weight" value={settings.resistance} min={0.6} max={2.4} step={0.05} unit="×" onChange={value => update("resistance", value)} />
      <Slider label="Preview reveal" detail="Effort to show neighbor" value={settings.revealPoint} min={20} max={120} step={5} unit="px" onChange={value => update("revealPoint", value)} />
      <Slider label="Commit threshold" detail="Effort before release opens" value={settings.commitThreshold} min={120} max={450} step={5} unit="px" onChange={value => update("commitThreshold", value)} />
      <Slider label="Spring / snap" detail="Return animation" value={settings.snapMs} min={100} max={650} step={10} unit="ms" onChange={value => update("snapMs", value)} />
    </div>
    <div className="lab-control-group"><h2>Timeline</h2>
      <Slider label="Stop spacing" detail="One stop per note" value={settings.railSpacing} min={12} max={36} step={1} unit="px" onChange={value => update("railSpacing", value)} />
      <Slider label="Preview delay" detail="Hover response" value={settings.previewDelayMs} min={0} max={600} step={10} unit="ms" onChange={value => update("previewDelayMs", value)} />
    </div>
    <div className="lab-actions"><button onClick={onReset}>Reset controls</button><button onClick={onExport}>{exported ? "Copied values" : "Export values"}</button></div>
    <button className="lab-reset-notes" onClick={onResetNotes}>Restore sample notes</button>
    <p className="lab-tip">Scroll normally inside a note. At an edge, keep pushing, then release. Top opens older; bottom opens newer.</p>
  </aside>;
}

export function MotionLabTimeline({ notes, selectedID, previewID, spacing, previewDelayMs, onPreview, onSelect }: {
  notes: LabNote[];
  selectedID: string;
  previewID: string | null;
  spacing: number;
  previewDelayMs: number;
  onPreview: (id: string | null) => void;
  onSelect: (id: string) => void;
}) {
  const railRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);
  const suppressClick = useRef(false);
  const hoverTimer = useRef<number | undefined>(undefined);
  const [dragPreview, setDragPreview] = useState<string | null>(null);
  useEffect(() => () => { if (hoverTimer.current) window.clearTimeout(hoverTimer.current); }, []);
  const preview = (id: string | null, immediate = false) => {
    if (hoverTimer.current) window.clearTimeout(hoverTimer.current);
    if (immediate || !id) { onPreview(id); return; }
    hoverTimer.current = window.setTimeout(() => onPreview(id), previewDelayMs);
  };
  const nearest = (clientY: number) => {
    const stops = Array.from(railRef.current?.querySelectorAll<HTMLButtonElement>(".rail-stop") ?? []);
    return stops.reduce<{ id: string; distance: number } | null>((best, stop) => {
      const rect = stop.getBoundingClientRect();
      const distance = Math.abs(clientY - (rect.top + rect.height / 2));
      return !best || distance < best.distance ? { id: stop.dataset.id || "", distance } : best;
    }, null)?.id;
  };
  const inside = (clientX: number, clientY: number) => {
    const rect = railRef.current?.getBoundingClientRect();
    return !!rect && clientX >= rect.left && clientX <= rect.right && clientY >= rect.top && clientY <= rect.bottom;
  };
  const visiblePreview = notes.find(note => note.id === (dragPreview ?? previewID));
  return <aside className="lab-timeline" aria-label="Note timeline">
    <div className="lab-rail-caption">NOTES</div>
    <div className="lab-rail" ref={railRef}
      onPointerDown={event => { dragging.current = true; suppressClick.current = false; event.currentTarget.setPointerCapture(event.pointerId); const id = nearest(event.clientY) ?? null; setDragPreview(id); preview(id, true); }}
      onPointerMove={event => { if (dragging.current) { const id = nearest(event.clientY) ?? null; setDragPreview(id); preview(id, true); } }}
      onPointerUp={event => { if (!dragging.current) return; dragging.current = false; const id = inside(event.clientX, event.clientY) ? nearest(event.clientY) : null; setDragPreview(null); preview(null, true); if (id) { suppressClick.current = true; onSelect(id); } }}
      onPointerCancel={() => { dragging.current = false; setDragPreview(null); preview(null, true); }}
      onPointerLeave={() => { if (!dragging.current) preview(null, true); }}>
      {notes.map((note, index) => <button key={note.id} data-id={note.id} className={`rail-stop ${note.id === selectedID ? "is-current" : ""} ${note.id === previewID ? "is-preview" : ""}`} style={{ height: spacing }} aria-label={`Open note ${index + 1}: ${notePreview(note).title}`} aria-current={note.id === selectedID ? "true" : undefined} onPointerEnter={() => { if (!dragging.current) preview(note.id); }} onFocus={() => preview(note.id, true)} onBlur={() => preview(null, true)} onClick={() => { if (suppressClick.current) { suppressClick.current = false; return; } onSelect(note.id); }}><span className="rail-mark" /></button>)}
    </div>
    {visiblePreview && <div className="lab-rail-preview" role="status"><small>{notePreview(visiblePreview).date}</small><strong>{notePreview(visiblePreview).title}</strong><span>{notePreview(visiblePreview).excerpt}</span><em>Click or release to open</em></div>}
  </aside>;
}

function Slider({ label, detail, value, min, max, step, unit, onChange }: { label: string; detail: string; value: number; min: number; max: number; step: number; unit: string; onChange: (value: number) => void }) {
  return <label className="lab-slider"><span className="lab-slider-top"><span>{label}<small>{detail}</small></span><output>{value}{unit}</output></span><input type="range" value={value} min={min} max={max} step={step} onChange={event => onChange(Number(event.target.value))} /></label>;
}

export function MotionLabStageMeta({ notes, selectedID, status }: { notes: LabNote[]; selectedID: string; status: string }) {
  const index = notes.findIndex(note => note.id === selectedID);
  const selected = notes[index];
  return <header className="lab-stage-header"><span className="lab-stage-index">{index + 1} / {notes.length}</span><span>{selected ? notePreview(selected).date : "Loading samples…"}</span><span className="lab-save" role="status">{status}</span></header>;
}

export function MotionLabEdge({ edge, notes, revealPoint }: { edge: EdgePreview | null; notes: LabNote[]; revealPoint: number }) {
  const note = notes.find(note => note.id === edge?.id);
  if (!edge || edge.effort < revealPoint || !note) return null;
  const label = edge.direction < 0 ? "Older note" : "Newer note";
  return <div className={`lab-edge-preview ${edge.direction < 0 ? "at-top" : "at-bottom"}`} aria-live="polite"><span>{label} · {edge.armed ? "Release to open" : "Keep pushing"}</span><strong>{notePreview(note).title}</strong><small>{notePreview(note).excerpt}</small></div>;
}

export { defaultSettings };
