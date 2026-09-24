import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { MotionLab } from "./MotionLab";
import type { LabNote } from "./motion";

const sample = (id: string, text: string): LabNote => ({ id, text, capturedAt: "2026-05-22T10:30:00Z", anchor: 0, head: 0, scrollTop: 0 });

describe("motion lab rail", () => {
  afterEach(() => { document.body.innerHTML = ""; delete window.MotionLabNative; delete window.webkit; });
  it("previews on focus without selecting, then selects on click", async () => {
    const messages: Record<string, unknown>[] = [];
    window.webkit = { messageHandlers: { motionLab: { postMessage: message => messages.push(message) } } };
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    await act(async () => { root.render(<MotionLab />); });
    await act(async () => {
      window.MotionLabNative?.receive({ type: "hydrate", payload: {
        notes: [sample("a", "# First note\n\nFirst body"), sample("b", "# Second note\n\nSecond body")],
        selectedID: "a", settings: {},
      } });
    });
    const second = Array.from(container.querySelectorAll("button")).find(button => button.getAttribute("aria-label")?.startsWith("Open note 2"));
    expect(second).toBeDefined();
    await act(async () => { second!.focus(); });
    expect(container.textContent).toContain("Second body");
    expect(container.textContent).toContain("1 / 2");
    expect(messages.some(message => message.type === "select")).toBe(false);
    await act(async () => { second!.click(); });
    expect(messages.some(message => message.type === "select" && message.id === "b")).toBe(true);
    expect(messages.findIndex(message => message.type === "save")).toBeLessThan(messages.findIndex(message => message.type === "select"));
    await act(async () => { root.unmount(); });
  });
  it("scrubs previews during a drag and opens only on release", async () => {
    const messages: Record<string, unknown>[] = [];
    window.webkit = { messageHandlers: { motionLab: { postMessage: message => messages.push(message) } } };
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    await act(async () => { root.render(<MotionLab />); });
    await act(async () => {
      window.MotionLabNative?.receive({ type: "hydrate", payload: {
        notes: [sample("a", "# First note\n\nFirst body"), sample("b", "# Second note\n\nSecond body")],
        selectedID: "a", settings: {},
      } });
    });
    const rail = container.querySelector<HTMLElement>(".lab-rail")!;
    rail.setPointerCapture = () => {};
    rail.getBoundingClientRect = () => ({ x: 0, y: 0, left: 0, top: 0, right: 50, bottom: 100, width: 50, height: 100, toJSON: () => ({}) });
    const stops = container.querySelectorAll<HTMLElement>(".rail-stop");
    stops.forEach((stop, index) => { stop.getBoundingClientRect = () => ({ x: 0, y: 10 + index * 20, left: 0, top: 10 + index * 20, right: 50, bottom: 20 + index * 20, width: 50, height: 10, toJSON: () => ({}) }); });
    await act(async () => { rail.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, clientX: 10, clientY: 15 })); });
    await act(async () => { rail.dispatchEvent(new MouseEvent("pointermove", { bubbles: true, clientX: 10, clientY: 35 })); });
    expect(container.textContent).toContain("Second body");
    expect(container.textContent).toContain("1 / 2");
    expect(messages.some(message => message.type === "select")).toBe(false);
    await act(async () => { rail.dispatchEvent(new MouseEvent("pointerup", { bubbles: true, clientX: 10, clientY: 35 })); });
    expect(messages.some(message => message.type === "select" && message.id === "b")).toBe(true);
    await act(async () => { root.unmount(); });
  });

});
