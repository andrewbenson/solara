import type { OpenWindowOptions, WindowEvent } from "@solara/shell";
import type { BrowserState } from "../store/browser";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { engineProfile, windowTitle } from "../store/model";
import { windowOpens } from "./windowOpenOrder";

export type LightsCenter = [number, number] | null;

export type WindowPort = {
  open(id: string, options: OpenWindowOptions & { claim?: string }, lightsCenter: LightsCenter): void;
  close(id: string): void;
  setTitle(id: string, title: string): void;
  windowIds(): Promise<string[]>;
  restoreFullScreen(ids: string[], focus: string | null): void;
  onEvent(listener: (e: WindowEvent) => void): void;
  releaseProfile(profile: string): void;
};

export type WindowSyncSetup = {
  port: WindowPort;
  getState(): BrowserState;
  isQuitting(): boolean;
  lightsCenter(s: BrowserState, id: string): LightsCenter;
  isUtilityWindow(id: string): boolean;
};

export function createWindowSync({ port, getState, isQuitting, lightsCenter, isUtilityWindow }: WindowSyncSetup) {
  const open = new Set<string>();
  const titles = new Map<string, string>();

  const releaseIfIncognito = (w: BrowserState["windows"][string] | undefined) => {
    if (nativeOwnsWorkspace() || !w?.incognito) return;
    const profileId = w.profileId;
    if (!Object.values(getState().windows).some((window) => window.profileId === profileId)) port.releaseProfile(engineProfile(profileId));
  };

  const listen = () =>
    port.onEvent((e) => {
      const s = getState();
      const owned = nativeOwnsWorkspace();
      if (!owned) {
        if (e.type === "keptOnClose") s.setWindowKeptOnClose(e.id, e.on);
        if (e.type === "focus") s.setFocusedWindow(e.id);
        if (e.type === "frame") s.setWindowFrame(e.id, e.frame);
        if (e.type === "fullScreen" && !isQuitting()) s.setWindowFullScreen(e.id, e.on);
      }
      if (e.type === "close") {
        if (isQuitting()) return;
        open.delete(e.id);
        if (!owned && s.windows[e.id]) s.closeWindow(e.id);
        releaseIfIncognito(s.windows[e.id]);
      }
    });

  const sync = (s: BrowserState, prev?: BrowserState) => {
    const opens = windowOpens(s, s.windowOrder.filter((id) => !open.has(id) && s.windows[id]?.kind !== "small"), !prev);
    for (const { id, focus, behind } of opens) {
      const w = s.windows[id]!;
      open.add(id);
      titles.set(id, windowTitle(s, id));
      const profile = engineProfile(w.profileId);
      const made = w.chromeWindow ? { chromeWindow: w.chromeWindow } : {};
      port.open(
        id,
        { frame: w.frame, incognito: w.incognito, title: titles.get(id), focus, profile, ...(behind ? { behind } : {}), ...(prev && !w.chromeWindow ? { animated: true } : {}), ...made },
        lightsCenter(s, id),
      );
    }
    for (const id of [...open]) {
      if (s.windows[id]) continue;
      open.delete(id);
      titles.delete(id);
      port.close(id);
      releaseIfIncognito(prev?.windows[id]);
    }
    if (prev && s.tabs === prev.tabs && s.windows === prev.windows && s.profiles === prev.profiles) return;
    for (const id of open) {
      const title = windowTitle(s, id);
      if (titles.get(id) !== title) {
        titles.set(id, title);
        port.setTitle(id, title);
      }
    }
  };

  const restoreFullScreen = (s: BrowserState) => {
    const stamp = (id: string) => s.windows[id]?.fullScreen ?? 0;
    const ids = s.windowOrder.filter((id) => stamp(id) > 0).sort((a, b) => stamp(a) - stamp(b));
    if (ids.length) port.restoreFullScreen(ids, s.ui.focusedWindowId);
  };

  const sweep = () =>
    port.windowIds().then((ids) => {
      const s = getState();
      for (const id of ids) {
        if (!s.windows[id]) {
          if (!isUtilityWindow(id)) port.close(id);
          continue;
        }
        if (s.windows[id]?.kind === "small") continue;
        const title = windowTitle(s, id);
        titles.set(id, title);
        port.setTitle(id, title);
      }
    });

  return { listen, sync, restoreFullScreen, sweep };
}
