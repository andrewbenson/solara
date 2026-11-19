import { requireOptionalNativeModule } from "expo-modules-core";
import { useBrowser } from "../store/browser";
import { isIncognitoProfile } from "../store/model";
import { webviews } from "./webviews";

type Picture = { data: string; frame: [number, number, number, number] };

const SETTLE_MS = 1500;
const KEEP = 40;
const pictures = new Map<string, Picture>();
const timers = new Map<string, ReturnType<typeof setTimeout>>();
let started = false;

type NativePictures = { lastTabPicture?(tabId: string): Promise<string | null>; tabPicturesNative?(): boolean };
const native = requireOptionalNativeModule<NativePictures>("SolaraSidebarDrag");
const nativePictures = () => typeof native?.lastTabPicture === "function" && native.tabPicturesNative?.() === true;

export function parsePicture(json: unknown): Picture | null {
  if (typeof json !== "string") return null;
  try {
    const value: unknown = JSON.parse(json);
    if (!value || typeof value !== "object") return null;
    const { data, frame } = value as { data?: unknown; frame?: unknown };
    if (typeof data !== "string" || !Array.isArray(frame) || frame.length !== 4 || !frame.every((n) => typeof n === "number" && Number.isFinite(n))) return null;
    return { data, frame: frame as Picture["frame"] };
  } catch {
    return null;
  }
}

export async function lastPicture(tabId: string, from: NativePictures | null = nativePictures() ? native : null): Promise<Picture | null> {
  if (from?.lastTabPicture) {
    const picture = parsePicture(await from.lastTabPicture(tabId).catch(() => null));
    if (picture) return picture;
  }
  return pictures.get(tabId) ?? null;
}

function remember(tabId: string) {
  void webviews
    .get(tabId)
    ?.capturePicture(0.25)
    .then((picture) => {
      if (!picture || !useBrowser.getState().tabs[tabId]) return;
      pictures.delete(tabId);
      pictures.set(tabId, picture);
      for (const old of pictures.keys()) {
        if (pictures.size <= KEEP) break;
        pictures.delete(old);
      }
    })
    .catch(() => {});
}

export function startTabPictures() {
  if (started || nativePictures()) return;
  started = true;
  useBrowser.subscribe((s, prev) => {
    if (s.windows === prev.windows && s.tabs === prev.tabs) return;
    for (const [windowId, timer] of timers)
      if (!s.windows[windowId]) {
        clearTimeout(timer);
        timers.delete(windowId);
      }
    for (const w of Object.values(s.windows)) {
      const id = w.activeTabIds[w.profileId];
      if (!id || w.incognito) continue;
      const was = prev.windows[w.id];
      if (id === was?.activeTabIds[was.profileId] && s.tabs[id]?.url === prev.tabs[id]?.url) continue;
      if (isIncognitoProfile(s.tabs[id]?.profileId ?? "")) continue;
      clearTimeout(timers.get(w.id));
      timers.set(
        w.id,
        setTimeout(() => {
          timers.delete(w.id);
          const now = useBrowser.getState().windows[w.id];
          if (now?.activeTabIds[now.profileId] === id) remember(id);
        }, SETTLE_MS),
      );
    }
    if (s.tabs !== prev.tabs) for (const id of pictures.keys()) if (!s.tabs[id]) pictures.delete(id);
  });
}
