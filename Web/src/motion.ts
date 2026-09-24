export type MotionSettings = {
  resistance: number;
  revealPoint: number;
  commitThreshold: number;
  snapMs: number;
  railSpacing: number;
  previewDelayMs: number;
};
export type LabNote = { id: string; capturedAt: string; text: string; anchor: number; head: number; scrollTop: number };

export const defaultSettings: MotionSettings = {
  resistance: 1.35, revealPoint: 58, commitThreshold: 255,
  snapMs: 280, railSpacing: 19, previewDelayMs: 180,
};
export const presets: Record<string, MotionSettings> = {
  Gentle: { resistance: 1.8, revealPoint: 45, commitThreshold: 320, snapMs: 400, railSpacing: 22, previewDelayMs: 260 },
  Balanced: defaultSettings,
  Decisive: { resistance: 0.9, revealPoint: 38, commitThreshold: 200, snapMs: 190, railSpacing: 16, previewDelayMs: 90 },
};
export function mergeSettings(value: Partial<MotionSettings>): MotionSettings {
  return { ...defaultSettings, ...value };
}
export function notePreview(note: LabNote) {
  const lines = note.text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  const clean = (line: string) => line.replace(/^#{1,6}\s+|^[-*+]\s+|^>\s+/, "").replace(/[*_`~]/g, "").trim();
  const title = clean(lines[0] || "Untitled note");
  const excerpt = clean(lines.slice(1).find(line => clean(line) !== title) || "No further text");
  return { title, excerpt, date: new Date(note.capturedAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) };
}
export function edgeDisplacement(effort: number, resistance: number): number {
  return Math.min(110, Math.max(0, effort) / (resistance + Math.max(0, effort) / 115));
}
export function shouldCommit(effort: number, threshold: number, events: number, durationMs: number, shortNote: boolean): boolean {
  return events >= (shortNote ? 4 : 3) && durationMs >= 70 && effort >= threshold * (shortNote ? 1.45 : 1);
}
export function adjacentIndex(index: number, direction: -1 | 1, total: number): number | null {
  const next = index + direction;
  return next >= 0 && next < total ? next : null;
}
