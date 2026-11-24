import { useBrowser } from "../store/browser";
import { nativeOwnsWorkspace } from "../store/nativeStore";

function refusedReplica() {
  if (!__DEV__ || nativeOwnsWorkspace()) throw new Error("Refusal checks require a refused development workspace");
  return useBrowser.getState();
}

export function exerciseWorkspace() {
  const s = refusedReplica();
  const w = Object.keys(s.windows)[0] ?? s.createWindow({});
  const tabsBefore = Object.keys(useBrowser.getState().tabs).length;
  const appearance = s.settings.appearance === "dark" ? "light" : "dark";
  s.newTab(w, { url: "data:text/html,<title>lost</title>lost" });
  s.updateSettings({ appearance });
  const after = useBrowser.getState();
  return { tabs: Object.keys(after.tabs).length - tabsBefore, appearance: after.settings.appearance === appearance };
}

export function exerciseDownloads() {
  const s = refusedReplica();
  s.upsertDownload({ id: "snapshot-refusal", url: "https://refusal.invalid/", state: "finished", profile: "", filename: "refusal", path: "", paused: false, received: 0, total: 0, speed: 0, mimeType: "application/octet-stream" });
  s.forgetDownloads("");
  return Object.keys(useBrowser.getState().windows)[0];
}

export function exerciseWindowAfterCancel() {
  const s = refusedReplica();
  s.createWindow({ url: "data:text/html,after-cancel" });
  s.updateSettings({ appearance: "light" });
}
