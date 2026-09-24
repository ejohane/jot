import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { MotionLabTimeline } from "./MotionLabChrome";
import type { LabNote } from "./motion";

const sample = (id: string, text: string): LabNote => ({ id, text, capturedAt: "2026-05-22T10:30:00Z", anchor: 0, head: 0, scrollTop: 0 });
const notes = [sample("a", "# First note\n\nFirst body"), sample("b", "# Second note\n\nSecond body")];

describe("Jot developer timeline", () => {
  afterEach(() => { document.body.innerHTML = ""; });
  function Harness({ selections }: { selections: string[] }) {
    const [previewID, setPreviewID] = useState<string | null>(null);
    return <><span data-testid="selection">a</span><MotionLabTimeline notes={notes} selectedID="a" previewID={previewID} spacing={19} previewDelayMs={0} onPreview={setPreviewID} onSelect={id => selections.push(id)} /></>;
  }
  it("previews on focus without selecting, then selects on click", async () => {
    const selections: string[] = [];
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    await act(async () => { root.render(<Harness selections={selections} />); });
    const second = container.querySelectorAll<HTMLButtonElement>(".rail-stop")[1];
    await act(async () => { second.focus(); });
    expect(container.textContent).toContain("Second body");
    expect(selections).toEqual([]);
    await act(async () => { second.click(); });
    expect(selections).toEqual(["b"]);
    await act(async () => { root.unmount(); });
  });
  it("scrubs previews during a drag and opens only on release", async () => {
    const selections: string[] = [];
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    await act(async () => { root.render(<Harness selections={selections} />); });
    const rail = container.querySelector<HTMLElement>(".lab-rail")!;
    rail.setPointerCapture = () => {};
    rail.getBoundingClientRect = () => ({ x: 0, y: 0, left: 0, top: 0, right: 50, bottom: 100, width: 50, height: 100, toJSON: () => ({}) });
    container.querySelectorAll<HTMLElement>(".rail-stop").forEach((stop, index) => {
      stop.getBoundingClientRect = () => ({ x: 0, y: 10 + index * 20, left: 0, top: 10 + index * 20, right: 50, bottom: 20 + index * 20, width: 50, height: 10, toJSON: () => ({}) });
    });
    await act(async () => { rail.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, clientX: 10, clientY: 15 })); });
    await act(async () => { rail.dispatchEvent(new MouseEvent("pointermove", { bubbles: true, clientX: 10, clientY: 35 })); });
    expect(container.textContent).toContain("Second body");
    expect(selections).toEqual([]);
    await act(async () => { rail.dispatchEvent(new MouseEvent("pointerup", { bubbles: true, clientX: 10, clientY: 35 })); });
    await act(async () => { container.querySelectorAll<HTMLButtonElement>(".rail-stop")[1].click(); });
    expect(selections).toEqual(["b"]);
    await act(async () => { root.unmount(); });
  });
});
