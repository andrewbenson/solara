import { onAppEvent, shortcutHints, type ShortcutHints } from "@solara/shell";
import { create } from "zustand";

const useHints = create<{ hints: ReadonlyMap<string, string>; revision: number }>(() => ({ hints: new Map(), revision: 0 }));
let started = false;

export function setShortcutHints(hints: ShortcutHints) {
  useHints.setState((state) => ({ hints: new Map(hints), revision: state.revision + 1 }));
}

export function startShortcutHints() {
  if (started) return;
  started = true;
  onAppEvent((event) => {
    if (event.type === "shortcutHints") setShortcutHints(event.hints);
  });
  const revision = menuBarRevision();
  void shortcutHints().then((hints) => {
    if (menuBarRevision() === revision) setShortcutHints(hints);
  }, () => {});
}

export const watchShortcutHints = (listener: () => void) => useHints.subscribe(listener);
export const menuBarRevision = () => useHints.getState().revision;
export const shortcutHint = (id: string) => useHints.getState().hints.get(id);

export function withShortcut(title: string, hint: string | undefined): string {
  return hint ? `${title} (${hint})` : title;
}

export const useShortcutHint = (id: string) => useHints((state) => state.hints.get(id));
