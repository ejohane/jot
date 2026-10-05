export const bridgeVersion = 1 as const;

export type Selection = { anchor: number; head: number };
export type Viewport = { scrollTop: number };

export type EditorToNative = { sessionID?: string } & (
  | { version: 1; type: "editorReady" }
  | { version: 1; type: "showLibrary" }
  | { version: 1; type: "openBrowserURL"; url: string }
  | { version: 1; type: "importClipboardImage"; requestID: string }
  | { version: 1; type: "importDroppedImage"; requestID: string; data: string }
  | { version: 1; type: "importDroppedFile"; requestID: string; dropID: string }
  | { version: 1; type: "previewImage"; path: string }
  | { version: 1; type: "contentChanged"; sessionID?: string; noteID?: string; revision: number; text: string; selection: Selection; viewport: Viewport }
  | { version: 1; type: "editorStateChanged"; sessionID?: string; selection: Selection; viewport: Viewport }
  | { version: 1; type: "preferredHeightChanged"; height: number }
  | { version: 1; type: "formattingToolbarBounds"; bounds: { x: number; y: number; width: number; height: number } | null }
  | { version: 1; type: "searchNotes"; query: string; requestID: number; refresh: boolean }
  | { version: 1; type: "actionPanelChanged"; visible: boolean }
  | { version: 1; type: "noteAction"; action: "revealInFinder" | "openNotesFolder" | "copyNote"; revision: number; text?: string }
  | { version: 1; type: "finishAndNew"; revision: number }
  | { version: 1; type: "hide"; revision: number }
  | { version: 1; type: "openNote"; noteID: string; revision: number }
  | { version: 1; type: "navigateLatest" | "navigateBack" | "navigateForward" }
  | { version: 1; type: "toggleDictation" }
  | { version: 1; type: "finishDictation" }
  | { version: 1; type: "cancelDictation" }
  | { version: 1; type: "recover"; action: "restoreRoot" | "saveCopy" | "reloadExternal" });

export type NoteSearchResult = { id: string; timestamp: number; title: string; excerpt: string; titleMatches: Array<{ from: number; to: number }>; excerptMatches: Array<{ from: number; to: number }> };

export type NativeToEditor =
  | { version: 1; type: "setEditingEnabled"; enabled: boolean }
  | { version: 1; type: "beginImageFileDrop"; dropID: string; count: number; x: number; y: number }
  | { version: 1; type: "noteSearchResults"; requestID: number; results: NoteSearchResult[]; message?: string }
  | { version: 1; type: "toggleActionPanel" | "showNoteSearch" | "findInNote" | "escape" }
  | { version: 1; type: "actionState"; canNew: boolean; canReveal: boolean; canLatest: boolean; canBack: boolean; canForward: boolean }
  | { version: 1; type: "loadSession"; sessionID?: string; baseURL?: string; text: string; noteID?: string; revision: number; selection: Selection; viewport: Viewport }
  | { version: 1; type: "beginImagePaste" | "selectAll" }
  | { version: 1; type: "imageImported"; requestID: string; path: string; baseURL: string }
  | { version: 1; type: "imageImportFailed"; requestID: string; message: string }
  | { version: 1; type: "toggleFormat"; format: "bold" | "italic" }
  | { version: 1; type: "setTextStyle"; style: "bullet" }
  | { version: 1; type: "changeListIndent"; direction: "in" | "out" }
  | { version: 1; type: "noteAllocated"; baseURL?: string; noteID: string; path: string; revision: number }
  | { version: 1; type: "saving"; revision: number }
  | { version: 1; type: "writeSucceeded"; noteID: string; revision: number }
  | { version: 1; type: "writeFailed"; noteID?: string; revision: number; errorCode: string; message: string; actions: Array<"restoreRoot" | "saveCopy" | "reloadExternal"> }
  | { version: 1; type: "externalConflict"; noteID: string; revision: number }
  | { version: 1; type: "dictationState"; status: "idle" | "downloading" | "recording" | "transcribing" | "error"; message?: string }
  | { version: 1; type: "dictationResult"; text: string }
  | { version: 1; type: "dictationPartial"; text: string }
  | { version: 1; type: "dictationLevel"; level: number }
  | { version: 1; type: "tagVocabulary"; tags: string[] }
  | { version: 1; type: "notePreview"; noteID: string; excerpt: string }
  | { version: 1; type: "noteRail"; notes: Array<{ id: string; timestamp: number; excerpt: string }> };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { jot?: { postMessage(message: EditorToNative): void } } };
    JotNative?: {
      receive(message: NativeToEditor): void;
      lockAndSnapshot(): { sessionID?: string; text: string; revision: number; selection: { anchor: number; head: number }; viewport: { scrollTop: number } };
    };
  }
}

let activeSessionID: string | undefined;
export function setBridgeSessionID(sessionID: string | undefined) { activeSessionID = sessionID; }

export function sendToNative(message: EditorToNative): boolean {
  const handler = window.webkit?.messageHandlers?.jot;
  if (!handler) return false;
  try {
    handler.postMessage(activeSessionID ? { sessionID: activeSessionID, ...message } : message);
    return true;
  } catch {
    return false;
  }
}
