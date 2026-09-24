import { deleteMarkupBackward, insertNewlineContinueMarkupCommand, markdown } from "@codemirror/lang-markdown";
import { history, historyKeymap } from "@codemirror/commands";
import { Annotation, EditorSelection, EditorState, Transaction } from "@codemirror/state";
import { EditorView, keymap, tooltips } from "@codemirror/view";
import { GFM } from "@lezer/markdown";
import { useEffect, useRef, useState } from "react";
import { sendToNative, type EditorToNative } from "./bridge";
import { editorTheme } from "./editorTheme";
import { markdownPresentation } from "./presentation";
import { beginDictation, clearDictation, dictationPreview, insertionForDictation, reviseDictation } from "./dictationPreview";
import { inlineTagEditor, setTagVocabulary } from "./tagEditor";
import { MotionLabControls, MotionLabTimeline, MotionLabStageMeta, MotionLabEdge, type EdgePreview } from "./MotionLabChrome";
import { adjacentIndex, defaultSettings, edgeDisplacement, mergeSettings, shouldCommit, type LabNote, type MotionSettings } from "./motion";

type RecoveryAction = "restoreRoot" | "saveCopy" | "reloadExternal";
type ErrorStatus = { message: string; actions?: RecoveryAction[] };
const loadSession = Annotation.define<boolean>();
const continueMarkdownList = insertNewlineContinueMarkupCommand({ nonTightLists: false });
const waveformBars = 48;
const motionLabMode = import.meta.env.MODE === "motion-lab" && new URLSearchParams(window.location.search).has("motionLab");
if (motionLabMode) void import("./motionLab.css");
type EdgeGesture = { direction: -1 | 1; effort: number; events: number; started: number; timer?: number };

export function insertLiteralNewline(view: EditorView): boolean {
  view.dispatch({
    ...view.state.replaceSelection("\n"),
    scrollIntoView: true,
    userEvent: "input.type",
  });
  return true;
}

export function Editor() {
  const host = useRef<HTMLDivElement>(null);
  const labNotesRef = useRef<LabNote[]>([]);
  const labSettingsRef = useRef<MotionSettings>(defaultSettings);
  const saveLabBeforeSelectRef = useRef<(() => boolean) | null>(null);
  const edgeGestureRef = useRef<EdgeGesture | null>(null);
  const edgeCooldownRef = useRef(0);
  const labWheelCleanup = useRef<(() => void) | null>(null);
  const [labNotes, setLabNotes] = useState<LabNote[]>([]);
  const [labSelectedID, setLabSelectedID] = useState("");
  const [labSettings, setLabSettings] = useState<MotionSettings>(defaultSettings);
  const [labPreviewID, setLabPreviewID] = useState<string | null>(null);
  const [labEdge, setLabEdge] = useState<EdgePreview | null>(null);
  const [labStatus, setLabStatus] = useState("Sample notes · local only");
  const [labExported, setLabExported] = useState(false);
  const revisionRef = useRef(0);
  const noteIDRef = useRef<string | undefined>(undefined);
  const compositionDirty = useRef(false);
  const hasLoadedSession = useRef(false);
  const readySent = useRef(false);
  const pendingBridgeSnapshot = useRef<Extract<EditorToNative, { type: "contentChanged" }> | null>(null);
  const [error, setError] = useState<ErrorStatus | null>(null);
  const [dictation, setDictation] = useState<{ status: "idle" | "downloading" | "recording" | "transcribing" | "error"; message?: string }>({ status: "idle" });
  const [waveform, setWaveform] = useState<number[]>(() => Array(waveformBars).fill(0));

  const clearLabGesture = () => {
    if (edgeGestureRef.current?.timer) window.clearTimeout(edgeGestureRef.current.timer);
    edgeGestureRef.current = null;
    setLabEdge(null);
  };
  const selectLabNote = (id: string) => {
    if (!motionLabMode || id === noteIDRef.current || !labNotesRef.current.some(note => note.id === id)) {
      setLabPreviewID(null);
      return;
    }
    if (!saveLabBeforeSelectRef.current?.()) return;
    clearLabGesture();
    setLabPreviewID(null);
    sendToNative({ version: 1, type: "labSelect", id });
  };
  const changeLabSettings = (next: MotionSettings) => {
    labSettingsRef.current = next;
    setLabSettings(next);
    sendToNative({ version: 1, type: "labSettings", value: { ...next } as Record<string, number> });
  };

  useEffect(() => {
    if (!host.current) return;
    let retryTimer: number | undefined;

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

    const sendCurrentDocument = (view: EditorView): boolean => {
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
      if (motionLabMode) {
        const updated = labNotesRef.current.map(note => note.id === noteIDRef.current
          ? { ...note, text: message.text, anchor: selection.anchor, head: selection.head, scrollTop: view.scrollDOM.scrollTop }
          : note);
        labNotesRef.current = updated;
        setLabNotes(updated);
        setLabStatus("Saving sample…");
      }
      if (!hasLoadedSession.current) {
        pendingBridgeSnapshot.current = message;
        return false;
      }
      if (!sendToNative(message)) {
        pendingBridgeSnapshot.current = message;
        setError({ message: "Saving is interrupted. Your text remains in this window." });
        scheduleBridgeRetry();
        return false;
      }
      return true;
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

    const state = EditorState.create({
      doc: "",
      extensions: [
        markdown({ extensions: GFM, addKeymap: false, pasteURLAsLink: false }),
        markdownPresentation,
        inlineTagEditor,
        dictationPreview,
        editorTheme,
        tooltips({ tooltipSpace: (view) => view.scrollDOM.getBoundingClientRect() }),
        EditorView.lineWrapping,
        history(),
        keymap.of([
          {
            key: "Mod-Enter",
            run: () => {
              sendToNative({ version: 1, type: "finishAndNew", revision: revisionRef.current });
              return true;
            },
          },
          { key: "Mod-Shift-d", run: () => sendToNative({ version: 1, type: "toggleDictation" }) },
          { key: "Enter", run: continueMarkdownList },
          { key: "Enter", run: insertLiteralNewline },
          { key: "Shift-Enter", run: insertLiteralNewline },
          { key: "Backspace", run: deleteMarkupBackward },
          {
            key: "Escape",
            run: () => {
              sendToNative({ version: 1, type: "hide", revision: revisionRef.current });
              return true;
            },
          },
          ...historyKeymap,
        ]),
        EditorView.domEventHandlers({
          compositionend: (_event, view) => {
            if (compositionDirty.current) {
              compositionDirty.current = false;
              queueMicrotask(() => sendCurrentDocument(view));
            }
          },
          paste: (event) => {
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
    if (motionLabMode) {
      saveLabBeforeSelectRef.current = () => sendCurrentDocument(view);
      const onWheel = (event: WheelEvent) => {
        if (Date.now() < edgeCooldownRef.current || !noteIDRef.current || event.deltaY === 0) return;
        const direction: -1 | 1 = event.deltaY < 0 ? -1 : 1;
        const index = labNotesRef.current.findIndex(note => note.id === noteIDRef.current);
        const next = adjacentIndex(index, direction, labNotesRef.current.length);
        if (next === null) { clearLabGesture(); return; }
        const maxScroll = Math.max(0, view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight);
        const atEdge = direction < 0 ? view.scrollDOM.scrollTop <= 1 : view.scrollDOM.scrollTop >= maxScroll - 1;
        if (!atEdge) { clearLabGesture(); return; }
        event.preventDefault();
        const now = performance.now();
        let gesture = edgeGestureRef.current;
        if (!gesture || gesture.direction !== direction || now - gesture.started > 1400) {
          clearLabGesture();
          gesture = { direction, effort: 0, events: 0, started: now };
          edgeGestureRef.current = gesture;
        }
        gesture.effort += Math.min(Math.abs(event.deltaY), 80);
        gesture.events += 1;
        const settings = labSettingsRef.current;
        const shortNote = maxScroll < 24;
        const armed = shouldCommit(gesture.effort, settings.commitThreshold, gesture.events, now - gesture.started, shortNote);
        setLabEdge({ id: labNotesRef.current[next].id, direction, distance: edgeDisplacement(gesture.effort, settings.resistance), effort: gesture.effort, armed });
        if (gesture.timer) window.clearTimeout(gesture.timer);
        gesture.timer = window.setTimeout(() => {
          if (edgeGestureRef.current !== gesture) return;
          const ready = shouldCommit(gesture.effort, labSettingsRef.current.commitThreshold, gesture.events, performance.now() - gesture.started, shortNote);
          const target = labNotesRef.current[next];
          clearLabGesture();
          if (ready && target) { edgeCooldownRef.current = Date.now() + 800; selectLabNote(target.id); }
        }, 170);
      };
      view.scrollDOM.addEventListener("wheel", onWheel, { passive: false });
      labWheelCleanup.current = () => view.scrollDOM.removeEventListener("wheel", onWheel);
    }
    sendPreferredHeight(view);
    window.JotNative = {
      receive(message) {
        if (message.version !== 1) return;
        switch (message.type) {
          case "loadSession": {
            view.dispatch({ effects: clearDictation.of() });
            noteIDRef.current = message.noteID;
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
                view.focus();
                sendPreferredHeight(view);
              });
              break;
            }
            revisionRef.current = message.revision;
            const anchor = Math.min(message.selection.anchor, message.text.length);
            const head = Math.min(message.selection.head, message.text.length);
            view.dispatch({
              changes: { from: 0, to: view.state.doc.length, insert: message.text },
              selection: EditorSelection.single(anchor, head),
              annotations: [loadSession.of(true), Transaction.addToHistory.of(false)],
            });
            requestAnimationFrame(() => {
              view.scrollDOM.scrollTop = message.viewport.scrollTop;
              view.focus();
              sendPreferredHeight(view);
            });
            setError(null);
            break;
          }
          case "noteAllocated":
            noteIDRef.current = message.noteID;
            break;
          case "saving":
            break;
          case "writeSucceeded":
            if (message.noteID === noteIDRef.current && message.revision === revisionRef.current) {
              setError(null);
              if (motionLabMode) setLabStatus("Saved locally");
            }
            break;
          case "externalConflict":
            if (message.noteID === noteIDRef.current) {
              setError({ message: "This jot changed outside the app.", actions: ["saveCopy", "reloadExternal"] });
            }
            break;
          case "writeFailed":
            if (!message.noteID || message.noteID === noteIDRef.current) {
              setError({ message: message.message, actions: message.actions });
              if (motionLabMode) setLabStatus(message.message);
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
          case "labHydrate": {
            const selected = message.payload.notes.find(note => note.id === message.payload.selectedID);
            labNotesRef.current = message.payload.notes;
            setLabNotes(message.payload.notes);
            setLabSelectedID(message.payload.selectedID);
            const settings = mergeSettings(message.payload.settings);
            labSettingsRef.current = settings;
            setLabSettings(settings);
            if (selected) setLabStatus("Saved locally");
            setLabPreviewID(null);
            clearLabGesture();
            break;
          }
          case "labExported":
            setLabExported(true);
            window.setTimeout(() => setLabExported(false), 1800);
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
      labWheelCleanup.current?.();
      clearLabGesture();
      saveLabBeforeSelectRef.current = null;
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

  if (motionLabMode) {
    return <main className="composer motion-lab-mode">
      <MotionLabControls settings={labSettings} onSettings={changeLabSettings} onReset={() => changeLabSettings(defaultSettings)} onExport={() => sendToNative({ version: 1, type: "labExport" })} onResetNotes={() => sendToNative({ version: 1, type: "labReset" })} exported={labExported} />
      <section className="lab-stage" aria-label="Sample note editor">
        <MotionLabStageMeta notes={labNotes} selectedID={labSelectedID} status={labStatus} />
        <div className="lab-editor-region">
          <MotionLabEdge edge={labEdge} notes={labNotes} revealPoint={labSettings.revealPoint} />
          <div ref={host} className="editor lab-editor" style={{ transform: labEdge ? `translateY(${labEdge.direction < 0 ? labEdge.distance : -labEdge.distance}px)` : "translateY(0)", transitionDuration: labEdge ? "0ms" : `${labSettings.snapMs}ms` }} role="textbox" aria-label="Jot — editable sample Markdown note" />
        </div>
        <footer className="lab-stage-footer"><span>↑ older</span><span>Push past the edge · release to open</span><span>newer ↓</span></footer>
      </section>
      <MotionLabTimeline notes={labNotes} selectedID={labSelectedID} previewID={labPreviewID} spacing={labSettings.railSpacing} previewDelayMs={labSettings.previewDelayMs} onPreview={setLabPreviewID} onSelect={selectLabNote} />
    </main>;
  }

  return (
    <main className="composer">
      <div ref={host} className="editor" role="textbox" aria-label="Jot — editable Markdown document" />
      <div className="dictation-controls">
        {dictationActive ? (
          <>
            <button
              className="dictation-button dictation-keep"
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
              className="dictation-button dictation-cancel"
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
            className="dictation-button"
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
    </main>
  );
}
