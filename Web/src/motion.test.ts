import { describe, expect, it } from "vitest";
import { adjacentIndex, edgeDisplacement, notePreview, shouldCommit, type LabNote } from "./motion";

describe("motion lab navigation gates", () => {
  it("moves top to older and bottom to newer, stopping at history ends", () => {
    expect(adjacentIndex(4, -1, 9)).toBe(3);
    expect(adjacentIndex(4, 1, 9)).toBe(5);
    expect(adjacentIndex(0, -1, 9)).toBeNull();
    expect(adjacentIndex(8, 1, 9)).toBeNull();
  });
  it("requires deliberate repeated effort and makes short notes harder", () => {
    expect(shouldCommit(400, 255, 1, 200, false)).toBe(false);
    expect(shouldCommit(255, 255, 3, 40, false)).toBe(false);
    expect(shouldCommit(220, 255, 5, 250, false)).toBe(false);
    expect(shouldCommit(280, 255, 4, 200, false)).toBe(true);
    expect(shouldCommit(280, 255, 4, 200, true)).toBe(false);
    expect(shouldCommit(380, 255, 4, 200, true)).toBe(true);
  });
  it("has bounded elastic displacement with resistance", () => {
    expect(edgeDisplacement(0, 1)).toBe(0);
    expect(edgeDisplacement(200, 2)).toBeLessThan(edgeDisplacement(200, 1));
    expect(edgeDisplacement(10000, 1)).toBeLessThanOrEqual(110);
  });
  it("previews first meaningful line and an excerpt for a dense rail", () => {
    const note: LabNote = { id: "x", capturedAt: "2026-05-22T10:30:00Z", text: "\n# Hello world\n\nA second thought", anchor: 0, head: 0, scrollTop: 0 };
    expect(notePreview(note).title).toBe("Hello world");
    expect(notePreview(note).excerpt).toBe("A second thought");
    const many = Array.from({ length: 100 }, (_, index) => ({ ...note, id: String(index) }));
    expect(many.map(notePreview)).toHaveLength(100);
  });
});
