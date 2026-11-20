import { setSidebarUi, sidebarUi, type Target } from "./state";

type Entry = { target: Target; order: number };

const sequences = new Map<string, number>();
const active = new Map<string, Entry>();
let order = 0;

function accept(windowId: string, sequence: number): boolean {
  if (!(sequence > (sequences.get(windowId) ?? 0))) return false;
  sequences.set(windowId, sequence);
  return true;
}

function showNewest() {
  let latest: [string, Entry] | undefined;
  for (const entry of active) if (!latest || entry[1].order > latest[1].order) latest = entry;
  setSidebarUi({ renaming: latest ? { windowId: latest[0], ...latest[1].target } : null });
}

export function applyNativeRenameState(windowId: string, kind: unknown, id: string, sequence: number): boolean {
  if (!accept(windowId, sequence)) return false;
  if (kind === "tab" || kind === "group") {
    active.set(windowId, { target: { kind, id }, order: ++order });
    setSidebarUi({ renaming: { windowId, kind, id } });
    return true;
  }
  active.delete(windowId);
  if (sidebarUi().renaming?.windowId === windowId) showNewest();
  return true;
}

export function resetNativeRenames(windows: Record<string, number>) {
  for (const [windowId, sequence] of Object.entries(windows)) if (accept(windowId, sequence)) active.delete(windowId);
  if (!Object.keys(windows).length) active.clear();
  const shown = sidebarUi().renaming;
  if (shown && !active.has(shown.windowId)) showNewest();
}
