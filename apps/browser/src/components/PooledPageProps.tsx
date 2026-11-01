import { toEngineUrl } from "@solara/core";
import { useEffect, useMemo } from "react";
import { opaqueCard } from "../lib/opaqueCard";
import { useTheme } from "../lib/theme";
import { isIncognitoProfile } from "../store/model";
import { useProfilesValue, useTabValue } from "../store/tabWatch";
import { useAutoPictureInPicture } from "./media/pip";
import type { TabPool } from "@solara/settings";
import { currentPageContext } from "./pageEvents";
import { usePages } from "./layout/pageState";

const pageTab = (t: { profileId?: string; url?: string; navigation?: { seq: number } | null } | undefined) => ({ profileId: t?.profileId ?? "", shownUrl: t?.url ?? "", navigationSeq: t?.navigation?.seq ?? null });

export function PooledPageProps({ pool, tabId, visible }: { pool: TabPool; tabId: string; visible: boolean }) {
  const { profileId, shownUrl, navigationSeq } = useTabValue(tabId, pageTab, (a, b) => a.profileId === b.profileId && a.shownUrl === b.shownUrl && a.navigationSeq === b.navigationSeq);
  const pageColor = useProfilesValue(profileId, (profiles) => (isIncognitoProfile(profileId) ? "incognito" : (profiles[profileId]?.color ?? "plum")));
  const theme = useTheme();
  const contentsBackgroundColor = useMemo(() => opaqueCard(theme), [theme.card, theme.windowTint[0], theme.windowTint[1]]);
  const contextKey = usePages((s) => {
    const page = s.pages[tabId];
    return `${!!page?.wasNewTab}|${page?.newTabShown?.url ?? ""}`;
  });
  const autoPictureInPicture = useAutoPictureInPicture(tabId, visible);
  useEffect(() => {
    pool.setPageProps(tabId, { pageColor, contentsBackgroundColor, autoPictureInPicture, shownUrl: toEngineUrl(shownUrl), ...currentPageContext(tabId) });
  }, [tabId, pageColor, contentsBackgroundColor, autoPictureInPicture, shownUrl, contextKey, navigationSeq]);
  return null;
}
