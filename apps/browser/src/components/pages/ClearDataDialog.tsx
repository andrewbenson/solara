import { clearBrowsingData, type BrowsingDataType } from "@solara/solaracore";
import { pruneProfileFavicons } from "../../lib/favicons";
import { useBrowser } from "../../store/browser";
import { engineProfile, isIncognitoProfile } from "../../store/model";
import { refuseSafeHistoryDeletion } from "../../store/safeLibraryEdits";

const RANGES = [
  { value: "hour", title: "Last hour", ms: 3_600_000 },
  { value: "day", title: "Last 24 hours", ms: 86_400_000 },
  { value: "week", title: "Last 7 days", ms: 7 * 86_400_000 },
  { value: "month", title: "Last 4 weeks", ms: 28 * 86_400_000 },
  { value: "all", title: "All time", ms: Infinity },
] as const;
type Range = (typeof RANGES)[number]["value"];

export type ClearRange = Range;

export async function clearDataFor(profileId: string, range: Range, history: boolean, siteData: boolean) {
  const ms = RANGES.find((r) => r.value === range)?.ms ?? RANGES[0].ms;
  const since = ms === Infinity ? undefined : Date.now() - ms;
  if (history && refuseSafeHistoryDeletion(engineProfile(profileId), undefined, since)) throw new Error("History deletion is unavailable until the legacy file has migrated in a normal launch.");
  if (history) {
    useBrowser.getState().clearHistory(profileId, since);
    pruneProfileFavicons(profileId);
  }
  const types: BrowsingDataType[] = [...(history ? ["history" as const] : []), ...(siteData ? ["siteData" as const, "cache" as const] : [])];
  if (types.length && !isIncognitoProfile(profileId)) await clearBrowsingData(engineProfile(profileId), types, since);
}

