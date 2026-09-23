export const bridgeVersion = 1 as const;

export type Selection = { anchor: number; head: number };
export type Viewport = { scrollTop: number };

export type EditorToNative =
  | { version: 1; type: "editorReady" }
  | { version: 1; type: "contentChanged"; noteID?: string; revision: number; text: string; selection: Selection; viewport: Viewport }
  | { version: 1; type: "editorStateChanged"; selection: Selection; viewport: Viewport }
  | { version: 1; type: "preferredHeightChanged"; height: number }
  | { version: 1; type: "finishAndNew"; revision: number }
  | { version: 1; type: "hide"; revision: number }
  | { version: 1; type: "toggleDictation" }
  | { version: 1; type: "recover"; action: "restoreRoot" | "saveCopy" | "reloadExternal" };

export type NativeToEditor =
  | { version: 1; type: "loadSession"; text: string; noteID?: string; revision: number; selection: Selection; viewport: Viewport }
  | { version: 1; type: "noteAllocated"; noteID: string; path: string; revision: number }
  | { version: 1; type: "saving"; revision: number }
  | { version: 1; type: "writeSucceeded"; noteID: string; revision: number }
  | { version: 1; type: "writeFailed"; noteID?: string; revision: number; errorCode: string; message: string; actions: Array<"restoreRoot" | "saveCopy" | "reloadExternal"> }
  | { version: 1; type: "externalConflict"; noteID: string; revision: number }
  | { version: 1; type: "dictationState"; status: "idle" | "downloading" | "recording" | "transcribing" | "error"; message?: string }
  | { version: 1; type: "dictationResult"; text: string }
  | { version: 1; type: "dictationPartial"; text: string }
  | { version: 1; type: "tagVocabulary"; tags: string[] };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { jot?: { postMessage(message: EditorToNative): void } } };
    JotNative?: { receive(message: NativeToEditor): void };
  }
}

export function sendToNative(message: EditorToNative): boolean {
  const handler = window.webkit?.messageHandlers?.jot;
  if (!handler) return false;
  try {
    handler.postMessage(message);
    return true;
  } catch {
    return false;
  }
}
