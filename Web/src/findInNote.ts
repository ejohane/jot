import { closeSearchPanel, findNext, findPrevious, getSearchQuery, search, SearchQuery, setSearchQuery } from "@codemirror/search";

export const findInNote = search({
  top: true,
  literal: true,
  createPanel(view) {
    const dom = document.createElement("form");
    dom.className = "note-find";
    dom.setAttribute("aria-label", "Find in note");
    const input = document.createElement("input");
    input.type = "search";
    input.placeholder = "Find in note…";
    input.setAttribute("aria-label", "Find in note");
    input.setAttribute("main-field", "true");
    input.value = getSearchQuery(view.state).search;
    const status = document.createElement("span");
    status.className = "note-find-status";
    status.setAttribute("role", "status");
    const updateStatus = () => {
      const query = getSearchQuery(view.state);
      const cursor = query.getCursor(view.state.doc);
      const hasMatch = query.search && !cursor.next().done;
      status.textContent = query.search && !hasMatch ? "No matches" : "";
    };
    input.addEventListener("input", () => {
      view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: input.value, literal: true })) });
      updateStatus();
    });
    dom.append(input, status);
    const button = (label: string, path: string, run: () => void) => {
      const control = document.createElement("button");
      control.type = "button";
      control.title = label;
      control.setAttribute("aria-label", label);
      control.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${path}"/></svg>`;
      control.addEventListener("click", run);
      dom.append(control);
    };
    button("Previous match", "m6 14 6-6 6 6", () => findPrevious(view));
    button("Next match", "m6 10 6 6 6-6", () => findNext(view));
    button("Close find", "m6 6 12 12M18 6 6 18", () => { closeSearchPanel(view); view.focus(); });
    dom.addEventListener("submit", (event) => { event.preventDefault(); findNext(view); });
    dom.addEventListener("keydown", (event) => {
      if (event.isComposing) return;
      if (event.key === "Enter") { event.preventDefault(); (event.shiftKey ? findPrevious : findNext)(view); }
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closeSearchPanel(view); view.focus(); }
    });
    return { dom, mount: () => { input.focus(); input.select(); updateStatus(); }, update: () => {
      const query = getSearchQuery(view.state);
      if (input.value !== query.search) input.value = query.search;
      updateStatus();
    } };
  },
});
