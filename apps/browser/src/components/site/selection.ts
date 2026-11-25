import { setSearchEngineName, setSelectionPopover } from "@solara/solaracore";
import { searchUrl } from "@solara/core";
import { create } from "zustand";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { defaultSearchEngine } from "../../store/settings";
import { openModeFor } from "../bookmarks/actions";
import { openFromPage } from "../layout/openFromPage";

export type PageSelection = { text: string; rect: { x: number; y: number; width: number; height: number } };

export const usePageSelection = create<Record<string, PageSelection | null>>()(() => ({}));

export function setPageSelection(tabId: string, selection: PageSelection | null) {
  if (!selection && !usePageSelection.getState()[tabId]) return;
  usePageSelection.setState({ [tabId]: selection });
}

const store = () => useBrowser.getState();

export function startSelectionTools() {
  let name = "";
  let popover: boolean | null = null;
  const sync = () => {
    const next = defaultSearchEngine(store().settings).name;
    if (next !== name) void setSearchEngineName((name = next));
    const enabled = store().settings.showSelectionSearch;
    if (enabled === popover) return;
    popover = enabled;
    void setSelectionPopover(enabled);
    if (!enabled) usePageSelection.setState({}, true);
  };
  sync();
  return useBrowser.subscribe((s, prev) => s.settings !== prev.settings && sync());
}

export type ClickModifiers = { metaKey?: boolean; shiftKey?: boolean; altKey?: boolean; middle?: boolean };

export function searchSelection(tabId: string, text: string, modifiers: ClickModifiers = {}) {
  const tab = store().tabs[tabId];
  const query = text.replace(/\s+/g, " ").trim();
  if (!tab || !query) return;
  setPageSelection(tabId, null);
  const url = searchUrl(defaultSearchEngine(store().settings), query);
  const mode = openModeFor(modifiers);
  const disposition = mode === "current" || mode === "incognito" ? "foreground" : mode;
  openFromPage({ url, disposition }, { windowId: tab.windowId, profileId: tab.profileId, tabId });
}

const FOCUSED = `const focused = () => {
  let el = document.activeElement;
  for (;;) {
    if (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    else if (el && el.tagName === "IFRAME") {
      try { el = el.contentDocument.activeElement; } catch (e) { return el; }
    } else return el;
  }
};
const isTextField = (el) => !!el && !el.readOnly && !el.disabled &&
  (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && /^(text|search|url|email|tel|)$/i.test(el.getAttribute("type") || "")));`;

type ReplaceResult = { field: boolean; count: number };

const REPLACE = `(query, replacement, all) => {
  ${FOCUSED}
  const el = focused();
  const done = (field, count) => post("result", JSON.stringify({ field, count }));
  const q = query.toLowerCase();
  if (!el || !q) return done(false, 0);
  const doc = el.ownerDocument, win = doc.defaultView;
  if (isTextField(el)) {
    // Through the editing commands, so the page sees input events and ⌘Z undoes it.
    const insert = (start, end, text) => {
      el.focus();
      el.setSelectionRange(start, end);
      if (!doc.execCommand("insertText", false, text)) {
        el.setRangeText(text, start, end, "end");
        el.dispatchEvent(new win.InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: text }));
      }
    };
    const value = el.value, lower = value.toLowerCase();
    if (all) {
      let out = "", last = 0, count = 0;
      for (let i = lower.indexOf(q); i !== -1; i = lower.indexOf(q, i + q.length), count++) {
        out += value.slice(last, i) + replacement;
        last = i + q.length;
      }
      if (count) insert(0, value.length, out + value.slice(last));
      return done(true, count);
    }
    // The selected match, else the next one after the caret (wrapping).
    const selected = lower.slice(el.selectionStart, el.selectionEnd) === q;
    let at = selected ? el.selectionStart : lower.indexOf(q, el.selectionEnd);
    if (at === -1) at = lower.indexOf(q);
    if (at === -1) return done(true, 0);
    insert(at, at + q.length, replacement);
    const after = el.value.toLowerCase();
    let next = after.indexOf(q, at + replacement.length);
    if (next === -1) next = after.indexOf(q);
    if (next !== -1) el.setSelectionRange(next, next + q.length);
    return done(true, 1);
  }
  if (!el.isContentEditable) return done(false, 0);
  const matches = () => {
    const found = [];
    const walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n; (n = walker.nextNode()); ) {
      const t = n.data.toLowerCase();
      for (let i = t.indexOf(q); i !== -1; i = t.indexOf(q, i + q.length)) {
        const r = doc.createRange();
        r.setStart(n, i);
        r.setEnd(n, i + q.length);
        found.push(r);
      }
    }
    return found;
  };
  const sel = win.getSelection();
  const select = (r) => {
    sel.removeAllRanges();
    sel.addRange(r);
  };
  const replace = (r) => {
    select(r);
    if (!doc.execCommand("insertText", false, replacement)) {
      r.deleteContents();
      r.insertNode(doc.createTextNode(replacement));
    }
  };
  el.focus();
  const found = matches();
  if (all) {
    // Last to first keeps the earlier ranges valid.
    for (const r of found.reverse()) replace(r);
    return done(true, found.length);
  }
  const current = sel.rangeCount ? sel.getRangeAt(0) : null;
  const isCurrent = (r) => current && r.compareBoundaryPoints(Range.START_TO_START, current) === 0 && r.compareBoundaryPoints(Range.END_TO_END, current) === 0;
  const target = found.find(isCurrent) || (current && found.find((r) => r.compareBoundaryPoints(Range.START_TO_START, current) >= 0)) || found[0];
  if (!target) return done(true, 0);
  replace(target);
  const caret = sel.rangeCount ? sel.getRangeAt(0) : null;
  const rest = matches();
  const next = (caret && rest.find((r) => r.compareBoundaryPoints(Range.START_TO_END, caret) >= 0)) || rest[0];
  if (next) select(next);
  done(true, 1);
}`;

export async function replaceInField(tabId: string, query: string, replacement: string, all: boolean): Promise<ReplaceResult> {
  const web = webviews.get(tabId);
  const args = [query, replacement, all].map((v) => JSON.stringify(v)).join(", ");
  const result = web ? await web.evaluate<ReplaceResult | { error: string }>(`(${REPLACE})(${args})`) : null;
  return result && "field" in result ? result : { field: false, count: 0 };
}

if (__DEV__) {
  (globalThis as { acSelection?: unknown }).acSelection = { usePageSelection, searchSelection, replaceInField };
}
