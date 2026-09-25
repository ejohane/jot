import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

export type RailNote = { id: string; timestamp: number; excerpt: string };

const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
const waveRadius = 3.7;
const rowHeight = 10;
const tickCapacity = 31;
const idleTickLength = 6;
const wavePeakLength = 26;
const selectedRestLength = 10;

function tickLength(index: number, centerY: number): number {
  const distance = Math.abs((index + 0.5) * rowHeight - centerY) / rowHeight;
  const swell = Math.max(0, 1 - distance / waveRadius);
  return idleTickLength + (wavePeakLength - idleTickLength) * swell;
}

export function NoteRail({ notes, activeID, onOpen }: {
  notes: RailNote[];
  activeID?: string;
  onOpen: (id: string) => void;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const pointerY = useRef<number | null>(null);
  const hoveredRef = useRef<number | null>(null);
  const trackingRef = useRef(false);
  const [scrollTop, setScrollTop] = useState(0);
  const [hovered, setHovered] = useState<number | null>(null);
  const [tracking, setTracking] = useState(false);
  const [viewportHeight, setViewportHeight] = useState(500);
  const activeIndex = useMemo(() => notes.findIndex((note) => note.id === activeID), [notes, activeID]);
  const start = Math.max(0, Math.floor(scrollTop / rowHeight) - 3);
  const end = Math.min(notes.length, Math.ceil((scrollTop + viewportHeight) / rowHeight) + 3);
  const visible = useMemo(() => notes.slice(start, end).map((note) => ({
    note,
    label: `Open jot from ${dateFormat.format(new Date(note.timestamp))}: ${note.excerpt || "Empty jot"}`,
  })), [notes, start, end]);

  useLayoutEffect(() => {
    const rail = scrollRef.current;
    if (!rail) return;
    const measure = () => setViewportHeight(rail.clientHeight);
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(rail);
    return () => observer.disconnect();
  }, []);

  useLayoutEffect(() => {
    const rail = scrollRef.current;
    if (!rail) return;
    const maxScroll = Math.max(0, notes.length * rowHeight - viewportHeight);
    if (rail.scrollTop <= maxScroll) return;
    rail.scrollTop = maxScroll;
    setScrollTop(maxScroll);
  }, [notes.length, rowHeight, viewportHeight]);

  useEffect(() => {
    const rail = scrollRef.current;
    if (!rail || rail.clientHeight <= 0 || activeIndex < 0) return;
    const top = activeIndex * rowHeight;
    if (top < rail.scrollTop || top + rowHeight > rail.scrollTop + rail.clientHeight) {
      rail.scrollTop = Math.max(0, top - rail.clientHeight / 2);
      setScrollTop(rail.scrollTop);
    }
  }, [activeIndex, rowHeight]);

  const paintWave = (hoverCenterY: number) => {
    const rail = scrollRef.current;
    if (!rail) return;
    rail.querySelectorAll<HTMLButtonElement>(".note-tick").forEach((tick) => {
      const index = Number(tick.dataset.index);
      const length = tickLength(index, hoverCenterY);
      const span = tick.firstElementChild as HTMLElement | null;
      if (span) span.style.transform = `scaleX(${length / tickCapacity})`;
    });
  };

  const paintResting = () => {
    const rail = scrollRef.current;
    if (!rail) return;
    rail.querySelectorAll<HTMLButtonElement>(".note-tick").forEach((tick) => {
      const length = Number(tick.dataset.index) === activeIndex ? selectedRestLength : idleTickLength;
      const span = tick.firstElementChild as HTMLElement | null;
      if (span) span.style.transform = `scaleX(${length / tickCapacity})`;
    });
  };

  const updateTracking = (value: boolean) => {
    if (trackingRef.current === value) return;
    trackingRef.current = value;
    setTracking(value);
  };

  const updateHovered = (index: number | null) => {
    if (hoveredRef.current === index) return;
    hoveredRef.current = index;
    setHovered(index);
  };

  useLayoutEffect(() => {
    const rail = scrollRef.current;
    const list = listRef.current;
    if (pointerY.current === null || !rail || !list) {
      updateTracking(false);
      paintResting();
    } else {
      const center = pointerY.current - list.getBoundingClientRect().top;
      if (center >= 0 && center < notes.length * rowHeight) {
        updateTracking(true);
        paintWave(center);
      } else {
        updateTracking(false);
        updateHovered(null);
        paintResting();
      }
    }
  }, [activeIndex, notes, scrollTop, viewportHeight]);

  const hoverAt = (clientY: number) => {
    const list = listRef.current;
    if (!list) return;
    const center = clientY - list.getBoundingClientRect().top;
    const index = Math.floor(center / rowHeight);
    if (index >= 0 && index < notes.length) {
      updateTracking(true);
      paintWave(center);
    } else {
      updateTracking(false);
      paintResting();
    }
    updateHovered(index >= 0 && index < notes.length ? index : null);
  };

  const preview = hovered === null ? undefined : notes[hovered];
  const listOffset = listRef.current && scrollRef.current
    ? listRef.current.getBoundingClientRect().top - scrollRef.current.getBoundingClientRect().top
    : 0;
  const hoverTop = hovered === null ? 0 : Math.max(55, Math.min(
    listOffset + (hovered + 0.5) * rowHeight,
    viewportHeight - 55,
  ));

  return (
    <aside className={`note-rail${tracking ? "" : " is-resting"}`} aria-label="Jot notes">
      <div
        className="note-rail-scroll"
        ref={scrollRef}
        onMouseMove={(event) => { pointerY.current = event.clientY; hoverAt(event.clientY); }}
        onMouseLeave={() => { pointerY.current = null; updateHovered(null); updateTracking(false); paintResting(); }}
        onScroll={(event) => {
          setScrollTop(event.currentTarget.scrollTop);
          setViewportHeight(event.currentTarget.clientHeight);
          if (pointerY.current !== null) hoverAt(pointerY.current);
        }}
      >
        <div className="note-rail-list" ref={listRef} style={{ height: notes.length * rowHeight }}>
          {visible.map(({ note, label }, offset) => {
            const index = start + offset;
            return (
              <button
                className={`note-tick${note.id === activeID ? " is-active" : ""}${hovered === index ? " is-hovered" : ""}`}
                key={note.id}
                type="button"
                data-index={index}
                style={{ top: index * rowHeight }}
                aria-label={label}
                aria-current={note.id === activeID ? "true" : undefined}
                onFocus={() => { updateHovered(index); updateTracking(true); paintWave((index + 0.5) * rowHeight); }}
                onBlur={() => {
                  if (pointerY.current === null) { updateHovered(null); updateTracking(false); paintResting(); }
                }}
                onClick={() => onOpen(note.id)}
              ><span /></button>
            );
          })}
        </div>
      </div>
      {preview && (
        <div className="note-rail-preview" style={{ top: hoverTop }} role="tooltip">
          <div className="note-rail-date">{dateFormat.format(new Date(preview.timestamp))}</div>
          <div className="note-rail-excerpt">{preview.excerpt || "Empty jot"}</div>
        </div>
      )}
    </aside>
  );
}
