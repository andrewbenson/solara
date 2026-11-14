import { launchEnvironment, readDocument, systemInfo, writeDocument } from "@solara/shell";
import { persistenceRefused } from "../../lib/persistLatch";
import { nativeSafeMode } from "../../store/nativeStore";
import { create } from "zustand";
import { PRODUCT } from "../../lib/productName";

export type ReleaseNotes = {
  version: string;
  date: string;
  title: string;
  summary: string;
  items: { title: string; body: string }[];
};

const RELEASE_NOTES: ReleaseNotes[] = [
  {
    version: "1.0",
    date: "September 2026",
    title: `Hello, ${PRODUCT}`,
    summary: "The first release: a calm, fast browser that keeps your tabs, your pages and your focus in one place.",
    items: [
      { title: "A command bar for everything", body: "Search, type an address or jump to an open tab from the New Tab page, or from any page with ⌘L." },
      { title: "Split view", body: "Drag a tab onto the page to see two or three side by side, stacked or in columns." },
      { title: "Tab groups and pinned tabs", body: "Group related tabs, pin the ones you live in, and let Clean Up Tabs tidy the rest." },
      { title: "Picture in Picture that stays out of the way", body: "Stash a video at the edge of the screen; click its site name to jump back to the tab." },
      { title: "Bring everything with you", body: "Import bookmarks, history, passwords and open tabs from Chrome, Safari, Arc and more." },
      { title: "Profiles with their own colour", body: "Keep work and personal apart, each with its own theme on the New Tab page." },
    ],
  },
];

const POSTCARD_SECONDS = 86_400;

const DOC = "release-notes.json";
type Saved = { version: 1; lastVersion: string; pending: { version: string; since: number } | null };

function readSaved(): Saved | null {
  try {
    const json = readDocument(DOC);
    return json ? (JSON.parse(json) as Saved) : null;
  } catch {
    return null;
  }
}

function save(saved: Omit<Saved, "version">) {
  try {
    writeDocument(DOC, JSON.stringify({ version: 1, ...saved } satisfies Saved));
  } catch (error) {
    console.warn("Couldn't save release notes state", error);
  }
}

const notesFor = (version: string) => RELEASE_NOTES.find((n) => n.version === version) ?? null;

type State = {
  pending: Saved["pending"];
  page: { windowId: string; version: string } | null;
};

const useReleaseNotes = create<State>(() => ({ pending: null, page: null }));
let pageReceipt = 0;

export function releaseNotesPageReceipt(windowId: string, version: string): number | null {
  const page = useReleaseNotes.getState().page;
  return page?.windowId === windowId && page.version === version ? pageReceipt : null;
}

export function closeReleaseNotesIfCurrent(receipt: number, close = closeReleaseNotes) {
  if (receipt === pageReceipt && useReleaseNotes.getState().page !== null) close();
}

export const releaseNotesPendingReceipt = () => useReleaseNotes.getState().pending;

export const releaseNotesVersions = () => RELEASE_NOTES.map((notes) => notes.version);

export function applyPendingReleaseNotes(pending: Saved["pending"]) {
  useReleaseNotes.setState({ pending });
}

export function trackAppVersion(): boolean {
  const version = systemInfo().appVersion;
  if (!version || persistenceRefused()) return false;
  const saved = readSaved();
  const updated = saved ? saved.lastVersion !== version : !!readDocument("session.json");
  let pending = saved?.pending ?? null;
  if (__DEV__) {
    if (launchEnvironment("SOLARA_WHATS_NEW") === "1") pending = { version, since: Date.now() };
  } else if (updated) {
    pending = notesFor(version) ? { version, since: Date.now() } : null;
  }
  if (pending && Date.now() - pending.since > POSTCARD_SECONDS * 1000) pending = null;
  if (!nativeSafeMode()) save({ lastVersion: version, pending });
  useReleaseNotes.setState({ pending });
  return updated;
}

export function usePendingReleaseNotes(): ReleaseNotes | null {
  const pending = useReleaseNotes((s) => s.pending);
  return pending ? notesFor(pending.version) : null;
}

export function useReleaseNotesPage(windowId: string): ReleaseNotes | null {
  const page = useReleaseNotes((s) => s.page?.windowId === windowId ? s.page : null);
  return page ? notesFor(page.version) : null;
}

export function openReleaseNotes(windowId: string, version = useReleaseNotes.getState().pending?.version ?? systemInfo().appVersion) {
  if (!notesFor(version)) return;
  retireReleaseNotes();
  pageReceipt++;
  useReleaseNotes.setState({ page: { windowId, version } });
}

export const closeReleaseNotes = () => {
  pageReceipt++;
  useReleaseNotes.setState({ page: null });
};

export function retireReleaseNotes() {
  const pending = useReleaseNotes.getState().pending;
  if (!pending) return;
  useReleaseNotes.setState({ pending: null });
  save({ lastVersion: pending.version, pending: null });
}

function queueReleaseNotes(version = systemInfo().appVersion) {
  const pending = notesFor(version) ? { version, since: Date.now() } : null;
  useReleaseNotes.setState({ pending });
  save({ lastVersion: systemInfo().appVersion, pending });
}

if (__DEV__) (globalThis as { acReleaseNotes?: unknown }).acReleaseNotes = { store: useReleaseNotes, queue: queueReleaseNotes, retire: retireReleaseNotes, open: openReleaseNotes };
