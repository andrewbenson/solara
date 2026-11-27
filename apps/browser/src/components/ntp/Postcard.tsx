import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect, useRef } from "react";
import { Image, StyleSheet } from "react-native";
import { hex, useTheme } from "../../lib/theme";
import { useWindowId } from "../../store/hooks";
import { closeReleaseNotesIfCurrent, releaseNotesPageReceipt, releaseNotesPendingReceipt, type ReleaseNotes } from "./releaseNotes";
import { PRODUCT } from "../../lib/productName";
import { APP_ICON as ICON } from "../../lib/appIcon";

type Size = { width: number; height: number };
let nextPresentation = 0;

function NativeReleaseNotes({ kind, tabId, notes, onOpen, onDismiss, onClose }: { kind: "releaseNotesPostcard" | "releaseNotesPage"; tabId: string; notes: ReleaseNotes; onOpen?: () => void; onDismiss?: () => void; onClose?: () => void }) {
  const windowId = useWindowId();
  const theme = useTheme();
  const pageReceipt = kind === "releaseNotesPage" ? releaseNotesPageReceipt(windowId, notes.version) : null;
  const pendingReceipt = kind === "releaseNotesPostcard" ? releaseNotesPendingReceipt() : null;
  const presentation = useRef<{ id: string; tabId: string; version: string; pageReceipt: number | null; pendingReceipt: ReturnType<typeof releaseNotesPendingReceipt> } | null>(null);
  if (presentation.current === null || presentation.current.tabId !== tabId || presentation.current.version !== notes.version || presentation.current.pageReceipt !== pageReceipt || presentation.current.pendingReceipt !== pendingReceipt) {
    presentation.current = { id: `postcard-${++nextPresentation}`, tabId, version: notes.version, pageReceipt, pendingReceipt };
  }
  const presentationId = presentation.current.id;
  const current = useRef({ notes, tabId, onOpen, onDismiss, onClose, pageReceipt, pendingReceipt });
  current.current = { notes, tabId, onOpen, onDismiss, onClose, pageReceipt, pendingReceipt };
  useEffect(() => {
    let mounted = true;
    const stop = onHostedEvent(kind, windowId, (name, payload) => {
      const latest = current.current;
      if (!mounted || presentation.current?.id !== presentationId || payload.version !== latest.notes.version || payload.presentationId !== presentationId) return;
      if (kind === "releaseNotesPostcard" && latest.pendingReceipt === releaseNotesPendingReceipt()) {
        if (name === "open") latest.onOpen?.();
        else if (name === "dismiss") latest.onDismiss?.();
      } else if (kind === "releaseNotesPage" && name === "close" && latest.pageReceipt !== null) {
        closeReleaseNotesIfCurrent(latest.pageReceipt, latest.onClose);
      }
    });
    return () => { mounted = false; stop(); };
  }, [kind, windowId, presentationId]);
  useEffect(() => () => {
    const latest = current.current;
    if (kind === "releaseNotesPage" && latest.pageReceipt !== null) closeReleaseNotesIfCurrent(latest.pageReceipt, latest.onClose);
  }, [kind]);
  return <SolaraHostedView
    kind={kind}
    windowId={windowId}
    state={JSON.stringify({
      notes,
      tabId,
      presentationId,
      dark: theme.dark,
      tokens: { panel: hex(theme.panel), panelBorder: hex(theme.panelBorder), textPrimary: theme.textPrimary, textSecondary: theme.textSecondary },
      iconUri: Image.resolveAssetSource(ICON)?.uri ?? "",
      product: PRODUCT,
    })}
    style={StyleSheet.absoluteFill}
  />;
}

export function ReleaseNotesPostcard({ tabId, notes, onOpen, onDismiss }: { tabId: string; notes: ReleaseNotes; size: Size; onOpen: () => void; onDismiss: () => void }) {
  return <NativeReleaseNotes kind="releaseNotesPostcard" tabId={tabId} notes={notes} onOpen={onOpen} onDismiss={onDismiss} />;
}

export function ReleaseNotesPage({ tabId, notes, onClose }: { tabId: string; notes: ReleaseNotes; size: Size; onClose: () => void }) {
  return <NativeReleaseNotes kind="releaseNotesPage" tabId={tabId} notes={notes} onClose={onClose} />;
}
