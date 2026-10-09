import { insertNewlineContinueMarkupCommand } from "@codemirror/lang-markdown";
import { ChangeSet, type ChangeSpec } from "@codemirror/state";
import type { Command } from "@codemirror/view";

const continueMarkup = insertNewlineContinueMarkupCommand({ nonTightLists: false });

export const continueMarkdownList: Command = ({ state, dispatch }) => continueMarkup({
  state,
  dispatch: transaction => {
    // nonTightLists:false makes Enter exit an empty item, but CodeMirror still
    // copies blank separators from an existing loose list. Remove only the
    // generated separator; keep existing prose, list spacing, and quote prefixes.
    const separators: ChangeSpec[] = [];
    transaction.changes.iterChanges((_from, _to, from, _end, inserted) => {
      const separator = /^\n[ \t>]*\n/.exec(inserted.toString());
      if (separator) separators.push({ from, to: from + separator[0].length - 1 });
    });
    if (!separators.length) {
      dispatch(transaction);
      return;
    }
    const compact = ChangeSet.of(separators, transaction.newDoc.length);
    dispatch(state.update({
      changes: transaction.changes.compose(compact),
      selection: transaction.newSelection.map(compact),
      userEvent: "input",
      scrollIntoView: true,
    }));
  },
});
