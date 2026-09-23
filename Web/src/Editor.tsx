import { deleteMarkupBackward, insertNewlineContinueMarkupCommand, markdown } from "@codemirror/lang-markdown";
import { history, historyKeymap } from "@codemirror/commands";
import { Annotation, EditorSelection, EditorState, Transaction } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { GFM } from "@lezer/markdown";
import { useEffect, useRef, useState } from "react";
import { sendToNative, type EditorToNative } from "./bridge";
import { editorTheme } from "./editorTheme";
import { markdownPresentation } from "./presentation";
import { beginDictation, clearDictation, dictationPreview, insertionForDictation, reviseDictation } from "./dictationPreview";
import { inlineTagEditor, setTagVocabulary } from "./tagEditor";

type RecoveryAction = "restoreRoot" | "saveCopy" | "reloadExternal";
type ErrorStatus = { message: string; actions?: RecoveryAction[] };
const loadSession = Annotation.define<boolean>();
const continueMarkdownList = insertNewlineContinueMarkupCommand({ nonTightLists: false });

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
  const revisionRef = useRef(0);
  const noteIDRef = useRef<string | undefined>(undefined);
  const compositionDirty = useRef(false);
  const hasLoadedSession = useRef(false);
  const readySent = useRef(false);
  const pendingBridgeSnapshot = useRef<Extract<EditorToNative, { type: "contentChanged" }> | null>(null);
  const [error, setError] = useState<ErrorStatus | null>(null);
  const [dictation, setDictation] = useState<{ status: "idle" | "downloading" | "recording" | "transcribing" | "error"; message?: string }>({ status: "idle" });

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
        const { paddingTop, paddingBottom } = getComputedStyle(view.scrollDOM);
        sendToNative({
          version: 1,
          type: "preferredHeightChanged",
          height: view.contentDOM.scrollHeight + parseFloat(paddingTop) + parseFloat(paddingBottom),
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
            }
            break;
          case "dictationState":
            if (["downloading", "recording", "transcribing"].includes(message.status) && !view.state.field(dictationPreview)) {
              const { from, to } = view.state.selection.main;
              view.dispatch({ effects: beginDictation.of({ from, to }) });
            } else if (message.status === "idle" || message.status === "error") {
              view.dispatch({ effects: clearDictation.of() });
            }
            setDictation({ status: message.status, message: message.message });
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
      view.destroy();
      delete window.JotNative;
    };
  }, []);

  const actionLabel = (action: string) => {
    if (action === "saveCopy") return "Save My Version as a Copy";
    if (action === "reloadExternal") return "Reload External Version";
    return "Restore Folder Access";
  };

  return (
    <main className="composer">
      <div ref={host} className="editor" role="textbox" aria-label="Jot — editable Markdown document" />
      <div className="dictation-controls">
        <button
          className={`dictation-button ${dictation.status === "recording" ? "is-recording" : ""}`}
          type="button"
          aria-label={dictation.status === "recording" ? "Stop dictation" : "Start dictation"}
          title="Dictate locally (⌘⇧D)"
          disabled={dictation.status === "transcribing"}
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => sendToNative({ version: 1, type: "toggleDictation" })}
        >
          <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <rect x="9" y="2" width="6" height="12" rx="3" />
            <path d="M5 10a7 7 0 0 0 14 0M12 17v5m-4 0h8" />
          </svg>
        </button>
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
