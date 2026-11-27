import { prompt } from "@solara/shell";
import { bookmarkWriter, reportBookmarkFailure, submitBookmarks } from "../../lib/bookmarkWriter";
import { useBrowser } from "../../store/browser";
import { bookmarkProfileId } from "../../store/model";
import type { Tab } from "../../store/types";

const store = () => useBrowser.getState();

const urlLabel = (url: string) => url.replace(/^[a-z][\w+.-]*:\/\//i, "").replace(/^www\./, "").replace(/\/$/, "");
export const tabTitle = (t: Pick<Tab, "customTitle" | "title" | "url">) => t.customTitle || t.title || (t.url && urlLabel(t.url)) || "New Tab";

export async function bookmarkTabs(windowId: string, ids: string[], folder: string | "bar" | "new") {
  const s = store();
  const profileId = bookmarkProfileId(s, s.windows[windowId]);
  let parentId: string | undefined = folder === "bar" ? undefined : folder;
  if (folder === "new") {
    const title = await prompt({ title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId });
    if (!title) return;
    try {
      parentId = await bookmarkWriter.addBookmarkFolder({ profileId, title });
    } catch (error) {
      return reportBookmarkFailure(error);
    }
  }
  const pages = ids.map((id) => store().tabs[id]).filter((t): t is Tab => !!t?.url);
  if (pages.length) await submitBookmarks(profileId, pages.map((t) => ({ method: "addBookmark", args: [{ profileId, url: t.url, title: tabTitle(t), favicon: t.favicon, parentId }] }))).catch(reportBookmarkFailure);
}
