import { useEffect } from "react";
import { StyleSheet, View } from "react-native";
import { useBrowser } from "../../store/browser";
import { bookmarkProfileId } from "../../store/model";
import { setPageProgress } from "../../store/pageProgress";
import { NativeBookmarksPage } from "./NativeBookmarksPage";
import { NativeDownloadsPage } from "./NativeDownloadsPage";
import { NativeHistoryPage } from "./NativeHistoryPage";
import { INTERNAL_PAGES, internalPageOf, internalQuery, tabDestination } from "./urls";

export function InternalPage({ tabId }: { tabId: string }) {
  const url = useBrowser((s) => {
    const t = s.tabs[tabId];
    return t ? tabDestination(t) : "";
  });
  const page = internalPageOf(url);
  const profileId = useBrowser((s) => s.tabs[tabId]?.profileId ?? "");
  const bookmarkProfile = useBrowser((s) => bookmarkProfileId(s, s.windows[s.tabs[tabId]?.windowId ?? ""]));

  useEffect(() => {
    if (!page) return;
    const t = useBrowser.getState().tabs[tabId];
    const title = INTERNAL_PAGES[page].title;
    if (t && (t.url !== url || t.title !== title)) useBrowser.getState().updateTab(tabId, { url, title, favicon: null });
    useBrowser.getState().updateLive(tabId, { isLoading: false, canGoBack: false, canGoForward: false });
    setPageProgress(tabId, 0);
  }, [page, url]);

  if (!page) return null;
  return (
    <View style={StyleSheet.absoluteFill}>
      {page === "history" && <NativeHistoryPage tabId={tabId} profileId={profileId} initialQuery={internalQuery(url)} />}
      {page === "bookmarks" && <NativeBookmarksPage key={bookmarkProfile} tabId={tabId} profileId={bookmarkProfile} />}
      {page === "downloads" && <NativeDownloadsPage tabId={tabId} />}
    </View>
  );
}
