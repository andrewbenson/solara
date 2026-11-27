import { SolaraHostedView } from "@solara/settings";
import { memo } from "react";
import { useTheme } from "../../lib/theme";

export const NativeBookmarksBar = memo(function NativeBookmarksBar({ windowId, height }: { windowId: string; height: number }) {
  const { toolbarHover, toolbarPressed, textTab, textTertiary, icon, divider, accent, dark } = useTheme();
  const state = JSON.stringify({ toolbarHover, toolbarPressed, textTab, textTertiary, icon, divider, accent, dark });
  return <SolaraHostedView kind="bookmarksBar" windowId={windowId} state={state} style={{ height }} />;
});
