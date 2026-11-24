import { cancelDownload, endWebKitPrivateSession } from "@solara/solaracore";
import { useBrowser, type BrowserState } from "../store/browser";
import { privateSession } from "../store/model";
import { downloadSession } from "../store/ui";

export function startPrivateCleanup() {
  return useBrowser.subscribe((s, prev) => {
    if (s.windows !== prev.windows) forgetClosedIncognito(s, prev);
  });
}

export function forgetClosedIncognito(s: BrowserState, prev: BrowserState) {
  for (const w of Object.values(prev.windows)) {
    if (!w.incognito || s.windows[w.id]) continue;
    const session = privateSession(w.profileId);
    if (Object.values(s.windows).some((o) => o.incognito && privateSession(o.profileId) === session)) continue;
    for (const d of s.downloads) if (downloadSession(d) === session && d.state === "downloading") void cancelDownload(d.id);
    s.forgetDownloads(w.profileId);
    if (session !== null) void endWebKitPrivateSession(session);
  }
}
