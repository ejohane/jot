import { useEffect, useRef, useState } from "react";
import type { NoteSearchResult } from "./bridge";

const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });

function Highlight({ text, matches }: { text: string; matches: Array<{ from: number; to: number }> }) {
  let from = 0;
  const parts = matches.flatMap((match, index) => {
    const before = text.slice(from, match.from);
    from = match.to;
    return [before, <mark key={index}>{text.slice(match.from, match.to)}</mark>];
  });
  return <>{parts}{text.slice(from)}</>;
}

export function NoteSearchPanel({ results, loading, error, onQuery, onOpen, onClose }: {
  results: NoteSearchResult[];
  loading: boolean;
  error?: string;
  onQuery: (query: string, refresh: boolean) => void;
  onOpen: (id: string) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const active = results.find((note) => note.id === selected) ?? results[0];
  useEffect(() => { input.current?.focus(); onQuery("", true); }, [onQuery]);
  useEffect(() => {
    list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ block: "nearest" });
  }, [active?.id]);

  return (
    <div className="action-panel-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section className="action-panel note-search-panel" role="dialog" aria-modal="true" aria-label="Search notes"
        onKeyDown={(event) => {
          if (event.nativeEvent.isComposing) return;
          if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onClose(); }
          if (event.key === "Tab") { event.preventDefault(); input.current?.focus(); }
          if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            const index = results.findIndex((note) => note.id === active?.id);
            const direction = event.key === "ArrowDown" ? 1 : -1;
            setSelected(results[(index + direction + results.length) % results.length]?.id ?? "");
          }
          if (event.key === "Enter") {
            event.preventDefault();
            if (!loading && active) onOpen(active.id);
          }
        }}>
        <input ref={input} className="action-panel-search" placeholder="Search notes…" aria-label="Search notes"
          autoComplete="off" autoCorrect="off" autoCapitalize="none" spellCheck={false}
          role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="note-search-results"
          aria-activedescendant={active ? `search-note-${active.id}` : undefined}
          value={query} onChange={(event) => {
            setQuery(event.target.value); setSelected(""); onQuery(event.target.value, false);
          }} />
        <div ref={list} id="note-search-results" className="action-panel-list" role="listbox" aria-label={query.trim() ? "Matching notes" : "Recent notes"} aria-busy={loading}>
          {results.map((note) => (
            <div key={note.id} id={`search-note-${note.id}`} role="option" aria-selected={active?.id === note.id}
              className="action-panel-row note-search-row" onMouseMove={() => setSelected(note.id)}
              onMouseDown={(event) => event.preventDefault()} onClick={() => { if (!loading) onOpen(note.id); }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M14 3H5v18h14V8l-5-5Zm0 0v5h5M8 12h8M8 16h6" /></svg>
              <div className="note-search-content">
                <div className="note-search-title"><Highlight text={note.title} matches={note.titleMatches} /></div>
                {note.excerpt && <div className="note-search-excerpt"><Highlight text={note.excerpt} matches={note.excerptMatches} /></div>}
                <time className="note-search-date" dateTime={new Date(note.timestamp).toISOString()}>{dateFormat.format(new Date(note.timestamp))}</time>
              </div>
            </div>
          ))}
          {results.length > 0 && error && <div className="action-panel-empty" role="status">{error}</div>}
          {!results.length && <div className="action-panel-empty" role="status">{loading ? "Searching notes…" : error ?? (query.trim() ? "No matching notes" : "No notes yet")}</div>}
        </div>
      </section>
    </div>
  );
}
