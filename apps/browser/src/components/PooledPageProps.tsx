import { toEngineUrl } from "@solara/core";
import { useEffect, useMemo } from "react";
import { opaqueCard } from "../lib/opaqueCard";
import { useTheme } from "../lib/theme";
import { isIncognitoProfile } from "../store/model";
import { useProfilesValue, useTabValue } from "../store/tabWatch";
import { useAutoPictureInPicture } from "./media/pip";
import type { TabPool } from "@solara/settings";

const pageTab = (t: { profileId?: string; url?: string } | undefined) => ({ profileId: t?.profileId ?? "", shownUrl: t?.url ?? "" });

export function PooledPageProps({ pool, tabId, visible }: { pool: TabPool; tabId: string; visible: boolean }) {
  const { profileId, shownUrl } = useTabValue(tabId, pageTab, (a, b) => a.profileId === b.profileId && a.shownUrl === b.shownUrl);
  const pageColor = useProfilesValue(profileId, (profiles) => (isIncognitoProfile(profileId) ? "incognito" : (profiles[profileId]?.color ?? "plum")));
  const theme = useTheme();
  const contentsBackgroundColor = useMemo(() => opaqueCard(theme), [theme.card, theme.windowTint[0], theme.windowTint[1]]);
  const autoPictureInPicture = useAutoPictureInPicture(tabId, visible);
  useEffect(() => {
    pool.setPageProps(tabId, { pageColor, contentsBackgroundColor, autoPictureInPicture, shownUrl: toEngineUrl(shownUrl) });
  }, [tabId, pageColor, contentsBackgroundColor, autoPictureInPicture, shownUrl]);
  return null;
}
