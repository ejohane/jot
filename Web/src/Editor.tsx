import { attachmentBaseURL, attachmentPresentation, beginImageImport, endImageImport, insertImportedImage, pendingImageImport } from "./attachments";
import { deleteMarkupBackward, insertNewlineContinueMarkupCommand, markdown } from "@codemirror/lang-markdown";
import { defaultKeymap, history, historyKeymap, selectAll } from "@codemirror/commands";
import { Annotation, Compartment, EditorSelection, EditorState, Transaction } from "@codemirror/state";
import { drawSelection, EditorView, keymap, tooltips } from "@codemirror/view";
import { GFM } from "@lezer/markdown";
import { useCallback, useEffect, useRef, useState } from "react";
import { sendToNative, type EditorToNative, type NoteSearchResult } from "./bridge";
import { clickableLinks } from "./links";
import { editorTheme } from "./editorTheme";
import { markdownPresentation } from "./presentation";
import { beginDictation, clearDictation, dictationPreview, insertionForDictation, reviseDictation } from "./dictationPreview";
import { inlineTagEditor, setTagVocabulary } from "./tagEditor";
import { indentListItem, outdentListItem } from "./listIndent";
import { toggleInlineFormat } from "./formatting";
import { formattingToolbar } from "./formattingToolbar";
import { usePointerActivity } from "./usePointerActivity";
import { NoteRail, type RailNote } from "./NoteRail";
import { NoteSearchPanel } from "./NoteSearchPanel";
import { ActionPanel, type Action } from "./ActionPanel";
import { findInNote } from "./findInNote";
import { closeSearchPanel, findNext, findPrevious, openSearchPanel, searchPanelOpen } from "@codemirror/search";

type RecoveryAction = "restoreRoot" | "saveCopy" | "reloadExternal";
type ErrorStatus = { message: string; actions?: RecoveryAction[] };
const loadSession = Annotation.define<boolean>();
const continueMarkdownList = insertNewlineContinueMarkupCommand({ nonTightLists: false });
const waveformBars = 48;

// A dash below a paragraph is usually the start of a list while typing.
// Use explicit # headings so Setext parsing cannot resize the previous line.
export const jotMarkdown = markdown({
  extensions: [GFM, { remove: ["SetextHeading"] }],
  addKeymap: false,
  pasteURLAsLink: false,
});

export function insertLiteralNewline(view: EditorView): boolean {
  view.dispatch({
    ...view.state.replaceSelection("\n"),
    scrollIntoView: true,
    userEvent: "input.type",
  });
  return true;
}

export function Editor() {
  const pointer = usePointerActivity();
  const viewRef = useRef<EditorView | null>(null);
  const panelOpenRef = useRef(false);
  const [panelOpen, setPanelOpen] = useState(false);
  const panelModeRef = useRef<"actions" | "notes">("actions");
  const [panelMode, setPanelMode] = useState<"actions" | "notes">("actions");
  const searchRequestID = useRef(0);
  const [searchResults, setSearchResults] = useState<NoteSearchResult[]>([]);
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchError, setSearchError] = useState<string | undefined>();
  const requestNoteSearch = useCallback((query: string, refresh: boolean) => {
    searchRequestID.current += 1;
    setSearchResults([]);
    setSearchLoading(true);
    setSearchError(undefined);
    if (!sendToNative({ version: 1, type: "searchNotes", query, requestID: searchRequestID.current, refresh })) {
      setSearchLoading(false);
      setSearchError("Note search is unavailable. Close and reopen Jot to try again.");
    }
  }, []);
  const [documentEmpty, setDocumentEmpty] = useState(true);
  const [actionState, setActionState] = useState({ canNew: false, canReveal: false, canLatest: false, canBack: false, canForward: false });
  const changePanel = (visible: boolean) => {
    panelOpenRef.current = visible;
    setPanelOpen(visible);
    sendToNative({ version: 1, type: "actionPanelChanged", visible });
    if (!visible) requestAnimationFrame(() => { if (!panelOpenRef.current) viewRef.current?.focus(); });
  };
  const showPalette = (mode: "actions" | "notes") => {
    if (panelOpenRef.current && panelModeRef.current === mode) { changePanel(false); return; }
    panelModeRef.current = mode;
    setPanelMode(mode);
    if (mode === "notes") { setSearchResults([]); setSearchLoading(true); }
    changePanel(true);
  };
  const host = useRef<HTMLDivElement>(null);
  const revisionRef = useRef(0);
  const noteIDRef = useRef<string | undefined>(undefined);
  const compositionDirty = useRef(false);
  const hasLoadedSession = useRef(false);
  const readySent = useRef(false);
  const pendingBridgeSnapshot = useRef<Extract<EditorToNative, { type: "contentChanged" }> | null>(null);
  const [importingImage, setImportingImage] = useState(false);
  const [error, setError] = useState<ErrorStatus | null>(null);
  const [dictation, setDictation] = useState<{ status: "idle" | "downloading" | "recording" | "transcribing" | "error"; message?: string }>({ status: "idle" });
  const [waveform, setWaveform] = useState<number[]>(() => Array(waveformBars).fill(0));
  const [railNotes, setRailNotes] = useState<RailNote[]>([]);
  const [activeNoteID, setActiveNoteID] = useState<string | undefined>();

  useEffect(() => {
    if (!host.current) return;
    let retryTimer: number | undefined;
    let imageKeepsFrame = false;
    let nextImageRequest = 0;
    let droppedImages: File[] = [];
    let nativeFileDropsRemaining = 0;
    let nativeDropID = "";
    const noteHistory = new Compartment();

    const scheduleBridgeRetry = () => {
      if (retryTimer !== undefined) return;
      retryTimer = window.setTimeout(() => {
        retryTimer = undefined;
        if (!readySent.current) {
          if (sendToNative({ version: 1, type: "editorReady" })) {
            readySent.current = true;
          } else {
            scheduleBridgeRetry();
          }
          return;
        }
        const pending = pendingBridgeSnapshot.current;
        if (!pending) return;
        if (sendToNative(pending)) {
          pendingBridgeSnapshot.current = null;
        } else {
          scheduleBridgeRetry();
        }
      }, 250);
    };

    const sendCurrentDocument = (view: EditorView) => {
      revisionRef.current += 1;
      const selection = view.state.selection.main;
      const message: Extract<EditorToNative, { type: "contentChanged" }> = {
        version: 1,
        type: "contentChanged",
        noteID: noteIDRef.current,
        revision: revisionRef.current,
        text: view.state.doc.toString(),
        selection: { anchor: selection.anchor, head: selection.head },
        viewport: { scrollTop: view.scrollDOM.scrollTop },
      };
      if (!hasLoadedSession.current) {
        pendingBridgeSnapshot.current = message;
        return;
      }
      if (!sendToNative(message)) {
        pendingBridgeSnapshot.current = message;
        setError({ message: "Saving is interrupted. Your text remains in this window." });
        scheduleBridgeRetry();
      }
    };

    const sendEditorState = (view: EditorView) => {
      const selection = view.state.selection.main;
      sendToNative({
        version: 1,
        type: "editorStateChanged",
        selection: { anchor: selection.anchor, head: selection.head },
        viewport: { scrollTop: view.scrollDOM.scrollTop },
      });
    };

    const sendPreferredHeight = (view: EditorView) => {
      requestAnimationFrame(() => {
        if (imageKeepsFrame || view.state.field(pendingImageImport) || /!\[[^\n]*\]\([^\n]*attachments\//.test(view.state.doc.toString())) return;
        const composer = host.current?.parentElement;
        if (!composer) return;
        const { paddingTop, paddingBottom } = getComputedStyle(view.scrollDOM);
        const composerStyle = getComputedStyle(composer);
        const topInset = parseFloat(composerStyle.getPropertyValue("--editor-top-inset")) || 0;
        const bottomInset = parseFloat(composerStyle.getPropertyValue("--editor-bottom-inset")) || 0;
        sendToNative({
          version: 1,
          type: "preferredHeightChanged",
          height: view.contentDOM.scrollHeight + parseFloat(paddingTop) + parseFloat(paddingBottom)
            + topInset + bottomInset,
        });
      });
    };

    const requestImagePaste = (view: EditorView) => {
      if (!hasLoadedSession.current || view.state.field(pendingImageImport)) return;
      const { from, to } = view.state.selection.main;
      const id = `image-${++nextImageRequest}`;
      view.dispatch({ effects: beginImageImport.of({ id, from, to }) });
      setImportingImage(true);
      if (!sendToNative({ version: 1, type: "importClipboardImage", requestID: id })) {
        view.dispatch({ effects: endImageImport.of(null) });
        setImportingImage(false);
        setError({ message: "Image import is unavailable. Copy the image and retry after reopening Jot." });
      }
    };

    const startDroppedImage = (view: EditorView, position?: number) => {
      if (!hasLoadedSession.current || view.state.field(pendingImageImport)) return;
      const file = droppedImages.shift();
      if (!file) return;
      const from = position ?? view.state.selection.main.from;
      const to = position ?? view.state.selection.main.to;
      const id = `image-${++nextImageRequest}`;
      view.dispatch({ effects: beginImageImport.of({ id, from, to }) });
      setImportingImage(true);
      const reader = new FileReader();
      reader.onload = () => {
        if (view.state.field(pendingImageImport)?.id !== id) return;
        const data = typeof reader.result === "string" ? reader.result.split(",", 2)[1] : undefined;
        if (!data || !sendToNative({ version: 1, type: "importDroppedImage", requestID: id, data })) {
          droppedImages = [];
          view.dispatch({ effects: endImageImport.of(null) });
          setImportingImage(false);
          setError({ message: `Could not import ${file.name}. Try dropping it again.` });
        }
      };
      reader.onerror = () => {
        if (view.state.field(pendingImageImport)?.id !== id) return;
        droppedImages = [];
        view.dispatch({ effects: endImageImport.of(null) });
        setImportingImage(false);
        setError({ message: `Could not read ${file.name}. Try dropping it again.` });
      };
      reader.readAsDataURL(file);
    };

    const startNativeFileDrop = (view: EditorView, position?: number) => {
      if (!hasLoadedSession.current || !nativeFileDropsRemaining || view.state.field(pendingImageImport)) return;
      nativeFileDropsRemaining -= 1;
      const from = position ?? view.state.selection.main.from;
      const to = position ?? view.state.selection.main.to;
      const id = `image-${++nextImageRequest}`;
      view.dispatch({ effects: beginImageImport.of({ id, from, to }) });
      setImportingImage(true);
      if (!sendToNative({ version: 1, type: "importDroppedFile", requestID: id, dropID: nativeDropID })) {
        nativeFileDropsRemaining = 0;
        view.dispatch({ effects: endImageImport.of(null) });
        setImportingImage(false);
        setError({ message: "Image import is unavailable. Drop the file again after reopening Jot." });
      }
    };

    const editing = new Compartment();
    const state = EditorState.create({
      doc: "",
      extensions: [
        editing.of([EditorState.readOnly.of(false), EditorView.editable.of(true)]),
        jotMarkdown,
        markdownPresentation,
        clickableLinks,
        attachmentPresentation,
        pendingImageImport,
        inlineTagEditor,
        formattingToolbar,
        dictationPreview,
        editorTheme,
        // WebKit's native caret animates behind programmatic list indentation.
        drawSelection(),
        tooltips({ parent: document.body, tooltipSpace: () => ({ top: 8, left: 8, right: window.innerWidth - 8, bottom: window.innerHeight - 8 }) }),
        EditorView.lineWrapping,
        noteHistory.of(history()),
        findInNote,
        keymap.of([
          { key: "Mod-p", run: () => { showPalette("notes"); return true; } },
          { key: "Mod-k", run: () => { showPalette("actions"); return true; } },
          { key: "Mod-f", run: openSearchPanel },
          { key: "Mod-g", run: findNext },
          { key: "Mod-Shift-g", run: findPrevious },

          { key: "Mod-a", run: selectAll },
          { key: "Mod-b", run: (view) => toggleInlineFormat(view, "bold") },
          { key: "Mod-i", run: (view) => toggleInlineFormat(view, "italic") },
          ...["Mod-Enter", "Mod-n"].map(key => ({
            key,
            run: () => {
              sendToNative({ version: 1, type: "finishAndNew", revision: revisionRef.current });
              return true;
            },
          })),
          { key: "Mod-Shift-d", run: () => sendToNative({ version: 1, type: "toggleDictation" }) },
          { key: "Mod-l", run: () => sendToNative({ version: 1, type: "navigateLatest" }) },
          { key: "Mod-[", run: () => sendToNative({ version: 1, type: "navigateBack" }) },
          { key: "Mod-]", run: () => sendToNative({ version: 1, type: "navigateForward" }) },
          { key: "Enter", run: continueMarkdownList },
          { key: "Enter", run: insertLiteralNewline },
          { key: "Shift-Enter", run: insertLiteralNewline },
          { key: "Backspace", run: deleteMarkupBackward },
          { key: "Tab", run: indentListItem },
          { key: "Shift-Tab", run: outdentListItem },
          {
            key: "Escape",
            run: (view) => {
              if (searchPanelOpen(view.state)) { closeSearchPanel(view); view.focus(); }
              else sendToNative({ version: 1, type: "hide", revision: revisionRef.current });
              return true;
            },
          },
          ...defaultKeymap,
          ...historyKeymap,
        ]),
        EditorView.domEventHandlers({
          compositionend: (_event, view) => {
            if (compositionDirty.current) {
              compositionDirty.current = false;
              queueMicrotask(() => sendCurrentDocument(view));
            }
          },
          paste: (event, view) => {
            const images = Array.from(event.clipboardData?.files ?? []).some((file) => file.type?.startsWith("image/"));
            if (images) {
              event.preventDefault();
              requestImagePaste(view);
              return true;
            }
            if (event.clipboardData?.getData("text/plain")) return false;
            if (event.clipboardData?.files.length) {
              event.preventDefault();
              return true;
            }
            return false;
          },
          scroll: (_event, view) => {
            sendEditorState(view);
            return false;
          },
        }),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) setDocumentEmpty(update.state.doc.length === 0);
          const isSessionLoad = update.transactions.some((transaction) => transaction.annotation(loadSession));
          if (update.docChanged && !isSessionLoad) {
            if (update.view.compositionStarted) {
              compositionDirty.current = true;
              return;
            }
            sendCurrentDocument(update.view);
            sendPreferredHeight(update.view);
          }
          if (update.selectionSet && !isSessionLoad) sendEditorState(update.view);
        }),
      ],
    });

    const view = new EditorView({ state, parent: host.current });
    viewRef.current = view;
    const composer = host.current.closest<HTMLElement>(".composer");
    const acceptsFiles = (event: DragEvent) => Array.from(event.dataTransfer?.types ?? []).includes("Files");
    const dragOver = (event: DragEvent) => {
      if (!acceptsFiles(event)) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
      composer?.classList.add("is-image-dragging");
    };
    const dragLeave = (event: DragEvent) => {
      if (!composer?.contains(event.relatedTarget as Node | null)) composer?.classList.remove("is-image-dragging");
    };
    const drop = (event: DragEvent) => {
      if (!acceptsFiles(event)) return;
      event.preventDefault();
      event.stopPropagation();
      composer?.classList.remove("is-image-dragging");
      const files = Array.from(event.dataTransfer?.files ?? []);
      const supported = (file: File) => file.type.startsWith("image/") || /\.(png|jpe?g|gif|tiff?|heic|webp|bmp)$/i.test(file.name);
      if (!files.length || files.some((file) => !supported(file))) {
        setError({ message: "Drop an image file here. Other file types are not supported yet." });
        return;
      }
      if (files.some((file) => file.size > 20 * 1024 * 1024)) {
        setError({ message: "Images over 20 MB cannot be dropped yet." });
        return;
      }
      if (view.state.field(pendingImageImport)) {
        setError({ message: "Wait for the current image to finish importing, then drop again." });
        return;
      }
      droppedImages = files;
      const position = view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.from;
      startDroppedImage(view, position);
    };
    composer?.addEventListener("dragover", dragOver, true);
    composer?.addEventListener("dragleave", dragLeave, true);
    composer?.addEventListener("drop", drop, true);
    const documentKeyDown = (event: KeyboardEvent) => {
      if (event.isComposing) return;
      if (event.metaKey && event.key.toLowerCase() === "p") {
        event.preventDefault(); event.stopPropagation(); showPalette("notes");
      } else if (event.metaKey && event.key.toLowerCase() === "k") {
        event.preventDefault(); event.stopPropagation(); showPalette("actions");
      } else if (event.metaKey && event.key.toLowerCase() === "f") {
        event.preventDefault(); event.stopPropagation();
        if (panelOpenRef.current) changePanel(false);
        requestAnimationFrame(() => openSearchPanel(view));
      }
    };
    document.addEventListener("keydown", documentKeyDown, true);
    sendPreferredHeight(view);
    window.JotNative = {
      lockAndSnapshot() {
        view.dispatch({ effects: editing.reconfigure([EditorState.readOnly.of(true), EditorView.editable.of(false)]) });
        const selection = view.state.selection.main;
        return { text: view.state.doc.toString(), revision: revisionRef.current,
          selection: { anchor: selection.anchor, head: selection.head }, viewport: { scrollTop: view.scrollDOM.scrollTop } };
      },
      receive(message) {
        if (message.version !== 1) return;
        switch (message.type) {
          case "setEditingEnabled":
            view.dispatch({ effects: editing.reconfigure([EditorState.readOnly.of(!message.enabled), EditorView.editable.of(message.enabled)]) });
            break;
          case "showNoteSearch":
            showPalette("notes");
            break;
          case "noteSearchResults":
            if (panelOpenRef.current && panelModeRef.current === "notes" && message.requestID === searchRequestID.current) {
              setSearchResults(message.results);
              setSearchLoading(false);
              setSearchError(message.message);
            }
            break;
          case "toggleActionPanel":
            showPalette("actions");
            break;
          case "actionState":
            setActionState(message);
            break;
          case "findInNote":
            if (panelOpenRef.current) changePanel(false);
            requestAnimationFrame(() => openSearchPanel(view));
            break;
          case "escape":
            if (panelOpenRef.current) changePanel(false);
            else if (searchPanelOpen(view.state)) { closeSearchPanel(view); view.focus(); }
            else sendToNative({ version: 1, type: "hide", revision: revisionRef.current });
            break;
          case "selectAll":
            selectAll(view);
            break;
          case "beginImagePaste":
            if (view.state.readOnly) break;
            requestImagePaste(view);
            break;
          case "beginImageFileDrop":
            if (view.state.readOnly) break;
            if (view.state.field(pendingImageImport)) {
              setError({ message: "Wait for the current image to finish importing, then drop again." });
              break;
            }
            nativeDropID = message.dropID;
            nativeFileDropsRemaining = message.count;
            startNativeFileDrop(view, view.posAtCoords({ x: message.x, y: message.y }) ?? view.state.selection.main.from);
            break;
          case "imageImported":
            if (insertImportedImage(view, message.requestID, message.path, message.baseURL)) {
              imageKeepsFrame = true;
              setImportingImage(false);
              setError(null);
              if (nativeFileDropsRemaining) startNativeFileDrop(view);
              else startDroppedImage(view);
            }
            break;
          case "imageImportFailed":
            if (view.state.field(pendingImageImport)?.id === message.requestID) {
              droppedImages = [];
              nativeFileDropsRemaining = 0;
              view.dispatch({ effects: endImageImport.of(null) });
              setImportingImage(false);
              setError({ message: message.message });
            }
            break;
          case "toggleFormat":
            if (view.state.readOnly) break;
            toggleInlineFormat(view, message.format);
            break;
          case "loadSession": {
            droppedImages = [];
            nativeFileDropsRemaining = 0;
            if (panelOpenRef.current) changePanel(false);
            closeSearchPanel(view);
            view.dispatch({ effects: [clearDictation.of(), endImageImport.of(null), attachmentBaseURL.of(message.baseURL ?? "")] });
            setImportingImage(false);
            imageKeepsFrame = false;
            noteIDRef.current = message.noteID;
            setActiveNoteID(message.noteID);
            hasLoadedSession.current = true;
            const pending = pendingBridgeSnapshot.current;
            if (pending) {
              revisionRef.current = Math.max(message.revision, pending.revision) + 1;
              const selection = view.state.selection.main;
              const retry: Extract<EditorToNative, { type: "contentChanged" }> = {
                ...pending,
                noteID: message.noteID,
                revision: revisionRef.current,
                text: view.state.doc.toString(),
                selection: { anchor: selection.anchor, head: selection.head },
                viewport: { scrollTop: view.scrollDOM.scrollTop },
              };
              pendingBridgeSnapshot.current = retry;
              if (sendToNative(retry)) {
                pendingBridgeSnapshot.current = null;
              } else {
                setError({ message: "Saving is interrupted. Your text remains in this window." });
                scheduleBridgeRetry();
              }
              requestAnimationFrame(() => {
                if (!panelOpenRef.current) view.focus();
                sendPreferredHeight(view);
              });
              break;
            }
            revisionRef.current = message.revision;
            const anchor = Math.min(message.selection.anchor, message.text.length);
            const head = Math.min(message.selection.head, message.text.length);
            view.dispatch({ effects: noteHistory.reconfigure([]) });
            view.dispatch({
              effects: noteHistory.reconfigure(history()),
              changes: { from: 0, to: view.state.doc.length, insert: message.text },
              selection: EditorSelection.single(anchor, head),
              annotations: [loadSession.of(true), Transaction.addToHistory.of(false)],
            });
            imageKeepsFrame = /!\[[^\n]*\]\([^\n]*attachments\//.test(message.text);
            requestAnimationFrame(() => {
              view.scrollDOM.scrollTop = message.viewport.scrollTop;
              if (!panelOpenRef.current) view.focus();
              sendPreferredHeight(view);
            });
            setError(null);
            break;
          }
          case "noteAllocated":
            noteIDRef.current = message.noteID;
            setActiveNoteID(message.noteID);
            if (message.baseURL) view.dispatch({ effects: attachmentBaseURL.of(message.baseURL) });
            break;
          case "noteRail":
            setRailNotes(message.notes);
            break;
          case "notePreview":
            setRailNotes((notes) => notes.map((note) => note.id === message.noteID
              ? { ...note, excerpt: message.excerpt } : note));
            break;
          case "saving":
            break;
          case "writeSucceeded":
            if (message.noteID === noteIDRef.current && message.revision === revisionRef.current) {
              setError(null);
            }
            break;
          case "externalConflict":
            if (panelOpenRef.current) changePanel(false);
            if (message.noteID === noteIDRef.current) {
              setError({ message: "This jot changed outside the app.", actions: ["saveCopy", "reloadExternal"] });
            }
            break;
          case "writeFailed":
            if (panelOpenRef.current) changePanel(false);
            if (!message.noteID || message.noteID === noteIDRef.current) {
              setError({ message: message.message, actions: message.actions });
            }
            break;
          case "dictationState":
            if (["downloading", "recording", "transcribing"].includes(message.status) && !view.state.field(dictationPreview)) {
              const { from, to } = view.state.selection.main;
              view.dispatch({ effects: beginDictation.of({ from, to }) });
              setWaveform(Array(waveformBars).fill(0));
            } else if (message.status === "idle" || message.status === "error") {
              view.dispatch({ effects: clearDictation.of() });
              setWaveform(Array(waveformBars).fill(0));
            }
            setDictation({ status: message.status, message: message.message });
            break;
          case "dictationLevel":
            if (view.state.field(dictationPreview)) {
              setWaveform((levels) => [...levels.slice(1), Math.max(0, Math.min(1, message.level))]);
            }
            break;
          case "dictationPartial":
            view.dispatch({ effects: reviseDictation.of(message.text) });
            break;
          case "dictationResult": {
            const text = message.text.trim();
            const preview = view.state.field(dictationPreview);
            if (!text || !hasLoadedSession.current || !preview) break;
            const insert = insertionForDictation(view, text, preview);
            view.dispatch({
              changes: { from: preview.from, to: preview.to, insert },
              effects: clearDictation.of(),
              scrollIntoView: true,
              userEvent: "input.dictation",
            });
            break;
          }
          case "tagVocabulary":
            view.dispatch({ effects: setTagVocabulary.of(message.tags) });
            break;
        }
      },
    };

    if (sendToNative({ version: 1, type: "editorReady" })) {
      readySent.current = true;
    } else {
      setError({ message: "Saving is interrupted. Your text remains in this window." });
      scheduleBridgeRetry();
    }
    return () => {
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      document.removeEventListener("keydown", documentKeyDown, true);
      composer?.removeEventListener("dragover", dragOver, true);
      composer?.removeEventListener("dragleave", dragLeave, true);
      composer?.removeEventListener("drop", drop, true);
      viewRef.current = null;
      view.destroy();
      delete window.JotNative;
    };
  }, []);

  const actionLabel = (action: string) => {
    if (action === "saveCopy") return "Save My Version as a Copy";
    if (action === "reloadExternal") return "Reload External Version";
    return "Restore Folder Access";
  };
  const dictationActive = dictation.status === "downloading" || dictation.status === "recording" || dictation.status === "transcribing";

  const openNote = (id: string) => {
    const pending = pendingBridgeSnapshot.current;
    if (pending) {
      if (!sendToNative(pending)) return;
      pendingBridgeSnapshot.current = null;
    }
    sendToNative({ version: 1, type: "openNote", noteID: id, revision: revisionRef.current });
  };

  const actions: Action[] = [
    { id: "new", label: "New Note", keywords: "create blank finish jot", icon: "M12 5v14M5 12h14", shortcut: ["⌘", "N"], group: 0,
      disabledReason: !actionState.canNew ? documentEmpty ? "You’re already on a blank note." : "Wait for the current note to save before starting a new one." : undefined },
    { id: "search", label: "Search Notes…", keywords: "browse find archive recent switch open", icon: "M11 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14Zm5 13 5 5", shortcut: ["⌘", "P"], group: 0 },
    { id: "reveal", label: "Reveal in Finder", keywords: "file locate show folder markdown", icon: "M3 7h7l2 2h9v11H3V7ZM3 7V4h7l2 3M12 12v5m-2-2 2 2 2-2", group: 0,
      disabledReason: !actionState.canReveal ? "A saved note and an accessible notes folder are required." : undefined },
    { id: "folder", label: "Open Notes Folder", keywords: "finder jots directory files", icon: "M3 7V4h7l2 3h9v13H3V7Zm0 0h9", group: 0 },
    { id: "copy", label: "Copy Note", keywords: "clipboard markdown entire text", icon: "M9 5H5v16h12v-4M9 3h12v14H9V3Z", group: 1,
      disabledReason: documentEmpty ? "Write something first to copy this note." : undefined },
    { id: "find", label: "Find in Note", keywords: "search text phrase", icon: "M11 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14Zm5 13 5 5", shortcut: ["⌘", "F"], group: 1 },
    { id: "dictation", label: dictation.status === "recording" ? "Finish Dictation" : "Start Dictation", keywords: "voice microphone speech transcribe record stop", icon: "M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0V5ZM5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8", shortcut: ["⇧", "⌘", "D"], group: 1,
      disabledReason: dictation.status === "downloading" ? "The voice model is downloading." : dictation.status === "transcribing" ? "Dictation is finishing." : undefined },
    { id: "latest", label: "Go to Latest Note", keywords: "current recent capture jot", icon: "M12 3v12m-4-4 4 4 4-4M5 17v4h14v-4", shortcut: ["⌘", "L"], group: 2,
      disabledReason: !actionState.canLatest ? "No latest note is available yet." : undefined },
    { id: "back", label: "Go Back", keywords: "previous history navigation", icon: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm4 9H8m4-4-4 4 4 4", shortcut: ["⌘", "["], group: 2,
      disabledReason: !actionState.canBack ? "No earlier note in your viewing history." : undefined },
    { id: "forward", label: "Go Forward", keywords: "next history navigation", icon: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM8 12h8m-4-4 4 4-4 4", shortcut: ["⌘", "]"], group: 2,
      disabledReason: !actionState.canForward ? "No later note in your viewing history." : undefined },
  ];
  const runAction = (id: string) => {
    const view = viewRef.current;
    if (!view) return;
    const pending = pendingBridgeSnapshot.current;
    if (pending) {
      if (!sendToNative(pending)) return;
      pendingBridgeSnapshot.current = null;
    }
    if (id === "search") { showPalette("notes"); return; }
    changePanel(false);
    switch (id) {
      case "new": sendToNative({ version: 1, type: "finishAndNew", revision: revisionRef.current }); break;
      case "reveal": case "folder": case "copy":
        sendToNative({ version: 1, type: "noteAction", action: id === "reveal" ? "revealInFinder" : id === "folder" ? "openNotesFolder" : "copyNote", revision: revisionRef.current, ...(id === "copy" ? { text: view.state.doc.toString() } : {}) }); break;
      case "find": requestAnimationFrame(() => openSearchPanel(view)); break;
      case "dictation": sendToNative({ version: 1, type: dictation.status === "recording" ? "finishDictation" : "toggleDictation" }); break;
      case "latest": sendToNative({ version: 1, type: "navigateLatest" }); break;
      case "back": sendToNative({ version: 1, type: "navigateBack" }); break;
      case "forward": sendToNative({ version: 1, type: "navigateForward" }); break;
    }
  };

  return (
    <main
      className={`composer${pointer.active ? " is-pointer-active" : ""}`}
      onPointerEnter={pointer.reveal}
      onPointerMove={pointer.reveal}
      onPointerLeave={pointer.hide}
    >
      <div className="composer-content" inert={panelOpen}>
      <div ref={host} className="editor" role="textbox" aria-label="Jot — editable Markdown document" />
      <NoteRail notes={railNotes} activeID={activeNoteID} onOpen={openNote} />
      <div className={`dictation-controls${dictation.status !== "idle" ? " is-persistent" : ""}`}>
        {dictationActive ? (
          <>
            <button
              className="chrome-button dictation-keep"
              type="button"
              aria-label="Keep dictation"
              title="Finish and keep dictation"
              disabled={dictation.status !== "recording"}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => sendToNative({ version: 1, type: "finishDictation" })}
            >
              <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="m5 12 4.5 4.5L19 7" />
              </svg>
            </button>
            <button
              className="chrome-button dictation-cancel"
              type="button"
              aria-label="Cancel dictation"
              title="Cancel and discard dictation"
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => sendToNative({ version: 1, type: "cancelDictation" })}
            >
              <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
                <path d="M5 5 19 19M19 5 5 19" />
              </svg>
            </button>
            {dictation.status === "recording" && (
              <div className="dictation-waveform" aria-hidden="true">
                {waveform.map((level, index) => (
                  <span key={index} className="dictation-waveform-bar" style={{ transform: `scaleY(${(2 + level * 22) / 24})` }} />
                ))}
              </div>
            )}
          </>
        ) : (
          <button
            className="chrome-button"
            type="button"
            aria-label="Start dictation"
            title="Dictate locally (⌘⇧D)"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => sendToNative({ version: 1, type: "toggleDictation" })}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <rect x="9" y="2" width="6" height="12" rx="3" />
              <path d="M5 10a7 7 0 0 0 14 0M12 17v5m-4 0h8" />
            </svg>
          </button>
        )}
        {dictation.status !== "idle" && dictation.message && <span className={`dictation-message ${dictation.status === "error" ? "is-error" : ""}`} role={dictation.status === "error" ? "alert" : "status"}>{dictation.message}</span>}
      </div>
      <div className="command-controls">
        <button
          className="chrome-button"
          type="button"
          aria-label="Commands"
          title="Commands (⌘K)"
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => showPalette("actions")}
        >
          <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M8 8H5a3 3 0 1 1 3-3v14a3 3 0 1 1-3-3h14a3 3 0 1 1-3 3V5a3 3 0 1 1 3 3H8Z" />
          </svg>
        </button>
      </div>
      {importingImage && <footer className="status" role="status">Importing image…</footer>}
      {error && (
        <footer className="status status-error" role="alert" aria-atomic="true">
          <span>{error.message}</span>
          {error.actions?.map((action) => (
            <button key={action} onClick={() => sendToNative({ version: 1, type: "recover", action })}>
              {actionLabel(action)}
            </button>
          ))}
        </footer>
      )}
      </div>
      {panelOpen && (panelMode === "notes"
        ? <NoteSearchPanel results={searchResults} loading={searchLoading} error={searchError} onQuery={requestNoteSearch}
            onOpen={(id) => { if (id === noteIDRef.current) changePanel(false); else openNote(id); }} onClose={() => changePanel(false)} />
        : <ActionPanel actions={actions} onRun={runAction} onClose={() => changePanel(false)} />)}
    </main>
  );
}
