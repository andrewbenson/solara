import { SolaraHostedView } from "@solara/settings";
import { setTrafficLightsCenter } from "@solara/shell";
import { useEffect } from "react";
import { layout } from "../../lib/theme";
import { useWindowId } from "../../store/hooks";
import { lightsCenter, TOP_STRIP_LIGHTS_CENTER } from "./dockMotion";
import { useTopStripPeekProbe } from "./NativeTopStrip";
import { useTabDrag } from "./tabDrag";

export const TOP_STRIP_HEIGHT = 42;
export const TOP_CARD_INSET = 6;

export function TopTabStrip({ hidden }: { hidden: boolean }) {
  const windowId = useWindowId();
  const dropOver = useTabDrag((drag) => drag.overWindow === windowId);
  useEffect(() => {
    if (hidden) return;
    void setTrafficLightsCenter(windowId, [...TOP_STRIP_LIGHTS_CENTER]);
    return () => void setTrafficLightsCenter(windowId, null);
  }, [hidden, windowId]);
  return (
    <SolaraHostedView kind="topStrip" windowId={windowId} state={JSON.stringify({ dropOver })} style={{ height: TOP_STRIP_HEIGHT }} />
  );
}

const STRIP_PEEK_ROOM = 4 + 46 + 64;

export function TopStripPeek({ windowWidth, enabled }: { windowWidth: number; enabled: boolean }) {
  const windowId = useWindowId();
  useTopStripPeekProbe(windowId);
  useEffect(() => {
    if (!enabled) return;
    void setTrafficLightsCenter(windowId, lightsCenter(layout.sidebarWidth));
    return () => void setTrafficLightsCenter(windowId, null);
  }, [enabled, windowId]);
  return (
    <SolaraHostedView
      kind="topStripPeek"
      windowId={windowId}
      state={JSON.stringify({ enabled, bandLeft: layout.trafficLightsWidth })}
      style={{ position: "absolute", top: 0, left: 0, width: windowWidth, height: STRIP_PEEK_ROOM }}
    />
  );
}
