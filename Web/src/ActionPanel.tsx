import { useEffect, useMemo, useRef, useState } from "react";

export type Action = {
  id: string;
  label: string;
  keywords: string;
  icon: string;
  shortcut?: string[];
  disabledReason?: string;
  group: number;
};

export function ActionPanel({ actions, onRun, onClose }: {
  actions: Action[];
  onRun: (id: string) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const matches = useMemo(() => {
    const words = query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
    const filtered = actions.filter((action) => words.every((word) => `${action.label} ${action.keywords}`.toLocaleLowerCase().includes(word)));
    if (!words.length) return filtered;
    const score = (action: Action) => words.reduce((total, word) => {
      const label = action.label.toLocaleLowerCase();
      return total + (label.startsWith(word) ? 3 : label.split(/\s+/).includes(word) ? 2 : label.includes(word) ? 1 : 0);
    }, 0);
    return filtered.sort((a, b) => score(b) - score(a));
  }, [actions, query]);
  const active = matches.find((action) => action.id === selected) ?? matches.find((action) => !action.disabledReason) ?? matches[0];

  useEffect(() => { input.current?.focus(); }, []);
  useEffect(() => {
    list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ block: "nearest" });
  }, [active?.id]);

  return (
    <div className="action-panel-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section className="action-panel" role="dialog" aria-modal="true" aria-label="Note actions"
        onKeyDown={(event) => {
          if (event.nativeEvent.isComposing) return;
          if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onClose(); }
          if (event.key === "Tab") { event.preventDefault(); input.current?.focus(); }
          if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            const enabled = matches.filter((action) => !action.disabledReason);
            const index = enabled.findIndex((action) => action.id === active?.id);
            const direction = event.key === "ArrowDown" ? 1 : -1;
            const next = index < 0 ? direction > 0 ? 0 : enabled.length - 1 : (index + direction + enabled.length) % enabled.length;
            setSelected(enabled[next]?.id ?? "");
          }
          if (event.key === "Enter") {
            event.preventDefault();
            if (active && !active.disabledReason) onRun(active.id);
          }
        }}>
        <input ref={input} className="action-panel-search" placeholder="Search for actions…" aria-label="Search for actions"
          autoComplete="off" autoCorrect="off" autoCapitalize="none" spellCheck={false}
          role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="note-actions"
          aria-activedescendant={active ? `action-${active.id}` : undefined}
          value={query} onChange={(event) => { setQuery(event.target.value); setSelected(""); }} />
        <div ref={list} id="note-actions" className="action-panel-list" role="listbox" aria-label="Actions">
          {matches.map((action, index) => (
            <div key={action.id} id={`action-${action.id}`} role="option" aria-selected={active?.id === action.id}
              aria-disabled={Boolean(action.disabledReason)} aria-label={action.disabledReason ? `${action.label}. ${action.disabledReason}` : undefined}
              className={`action-panel-row${index > 0 && !query.trim() && matches[index - 1].group !== action.group ? " action-panel-group-start" : ""}`}
              onMouseMove={() => setSelected(action.id)}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => { if (!action.disabledReason) onRun(action.id); }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={action.icon} /></svg>
              <span className="action-panel-label">{action.label}</span>
              {action.shortcut && <span className="action-panel-shortcut" aria-hidden="true">{action.shortcut.map((key) => <kbd key={key}>{key}</kbd>)}</span>}
            </div>
          ))}
          {!matches.length && <div className="action-panel-empty" role="status">No matching actions</div>}
        </div>
        {active?.disabledReason && <div id="action-disabled-reason" className="action-panel-reason" role="status">{active.disabledReason}</div>}
      </section>
    </div>
  );
}
