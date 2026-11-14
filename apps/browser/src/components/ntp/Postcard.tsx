import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect, useRef } from "react";
import { Image, StyleSheet } from "react-native";
import { hex, profileAccent, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { closeReleaseNotesIfCurrent, releaseNotesPageReceipt, releaseNotesPendingReceipt, type ReleaseNotes } from "./releaseNotes";
import { PRODUCT } from "../../lib/productName";
import { APP_ICON as ICON } from "../../lib/appIcon";

type Size = { width: number; height: number };
let nextPresentation = 0;

function mix(a: string, b: string, t: number) {
  const ch = (h: string, i: number) => parseInt(h.slice(1 + 2 * i, 3 + 2 * i), 16);
  return `#${[0, 1, 2].map((i) => Math.round(ch(a, i) + (ch(b, i) - ch(a, i)) * t).toString(16).padStart(2, "0")).join("")}`;
}

function NativeReleaseNotes({ kind, notes, onOpen, onDismiss, onClose }: { kind: "releaseNotesPostcard" | "releaseNotesPage"; notes: ReleaseNotes; onOpen?: () => void; onDismiss?: () => void; onClose?: () => void }) {
  const windowId = useWindowId();
  const theme = useTheme();
  const window = useBrowser((state) => state.windows[windowId]);
  const focusContext = useBrowser(state => {
    const current = state.windows[windowId];
    const tabId = current?.activeTabIds?.[current.profileId];
    return JSON.stringify([windowId, current?.profileId, tabId, tabId ? state.tabs[tabId]?.url : null, state.ui?.focusedWindowId]);
  });
  const swatch = useBrowser((state) => profileAccent(state.profiles[window?.profileId ?? ""]));
  const pageReceipt = kind === "releaseNotesPage" ? releaseNotesPageReceipt(windowId, notes.version) : null;
  const pendingReceipt = kind === "releaseNotesPostcard" ? releaseNotesPendingReceipt() : null;
  const presentation = useRef<{ id: string; profileId: string | undefined; version: string; pageReceipt: number | null; pendingReceipt: ReturnType<typeof releaseNotesPendingReceipt> } | null>(null);
  if (presentation.current === null || presentation.current.profileId !== window?.profileId || presentation.current.version !== notes.version || presentation.current.pageReceipt !== pageReceipt || presentation.current.pendingReceipt !== pendingReceipt) {
    presentation.current = { id: `postcard-${++nextPresentation}`, profileId: window?.profileId, version: notes.version, pageReceipt, pendingReceipt };
  }
  const presentationId = presentation.current.id;
  const current = useRef({ notes, profileId: window?.profileId, onOpen, onDismiss, onClose, pageReceipt, pendingReceipt });
  current.current = { notes, profileId: window?.profileId, onOpen, onDismiss, onClose, pageReceipt, pendingReceipt };
  useEffect(() => {
    let mounted = true;
    const stop = onHostedEvent(kind, windowId, (name, payload) => {
    const latest = current.current;
    const active = useBrowser.getState().windows[windowId];
    if (!mounted || presentation.current?.id !== presentationId || !active || active.profileId !== latest.profileId || payload.profileId !== active.profileId || payload.version !== latest.notes.version || payload.presentationId !== presentationId) return;
    if (kind === "releaseNotesPostcard" && !active.incognito && latest.pendingReceipt === releaseNotesPendingReceipt()) {
      if (name === "open") latest.onOpen?.();
      else if (name === "dismiss") latest.onDismiss?.();
    } else if (kind === "releaseNotesPage" && name === "close") {
      if (latest.pageReceipt !== null) closeReleaseNotesIfCurrent(latest.pageReceipt, latest.onClose);
    }
    });
    return () => { mounted = false; stop(); };
  }, [kind, windowId, presentationId]);
  useEffect(() => () => {
    const latest = current.current;
    if (kind === "releaseNotesPage" && latest.pageReceipt !== null) closeReleaseNotesIfCurrent(latest.pageReceipt, latest.onClose);
  }, [kind]);
  if (!window || (kind === "releaseNotesPostcard" && window.incognito)) return null;
  return <SolaraHostedView
    kind={kind}
    windowId={windowId}
    state={JSON.stringify({
      notes,
      profileId: window.profileId,
      focusContext,
      presentationId,
      dark: theme.dark,
      tokens: { panel: hex(theme.panel), panelBorder: hex(theme.panelBorder), textPrimary: theme.textPrimary, textSecondary: theme.textSecondary },
      colors: [mix(swatch, "#FFFFFF", 0.45), mix(swatch, "#10121A", 0.5)],
      iconUri: Image.resolveAssetSource(ICON)?.uri ?? "",
      product: PRODUCT,
    })}
    style={StyleSheet.absoluteFill}
  />;
}

export function ReleaseNotesPostcard({ notes, onOpen, onDismiss }: { notes: ReleaseNotes; size: Size; onOpen: () => void; onDismiss: () => void }) {
  return <NativeReleaseNotes kind="releaseNotesPostcard" notes={notes} onOpen={onOpen} onDismiss={onDismiss} />;
}

export function ReleaseNotesPage({ notes, onClose }: { notes: ReleaseNotes; size: Size; onClose: () => void }) {
  return <NativeReleaseNotes kind="releaseNotesPage" notes={notes} onClose={onClose} />;
}
