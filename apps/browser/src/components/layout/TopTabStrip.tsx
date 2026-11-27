import { SolaraHostedView } from "@solara/settings";
import { setTrafficLightsCenter } from "@solara/shell";
import { useEffect, useState } from "react";
import { StyleSheet, type ViewStyle } from "react-native";
import { layout } from "../../lib/theme";
import { useWindowId } from "../../store/hooks";
import { lightsCenter, TOP_STRIP_LIGHTS_CENTER } from "./dockMotion";
import { TabDropArea, type TabDropTarget } from "./fileDrop";
import { useIncomingFile, useTopStripPeekProbe } from "./NativeTopStrip";
import { beginExternalDrag, endExternalDrag, moveExternalDrag, useTabDrag } from "./tabDrag";

export const TOP_STRIP_HEIGHT = 42;
export const TOP_CARD_INSET = 6;

export function TopTabStrip({ hidden }: { hidden: boolean }) {
  const windowId = useWindowId();
  const dropOver = useTabDrag((drag) => drag.overWindow === windowId);
  useIncomingFile(windowId);
  useEffect(() => {
    if (hidden) return;
    void setTrafficLightsCenter(windowId, [...TOP_STRIP_LIGHTS_CENTER]);
    return () => void setTrafficLightsCenter(windowId, null);
  }, [hidden, windowId]);
  return (
    <StripDropArea style={{ height: TOP_STRIP_HEIGHT }}>
      <SolaraHostedView kind="topStrip" windowId={windowId} state={JSON.stringify({ dropOver })} style={StyleSheet.absoluteFill} />
    </StripDropArea>
  );
}

function StripDropArea({ style, children }: { style: ViewStyle; children: React.ReactNode }) {
  const windowId = useWindowId();
  const target: TabDropTarget = {
    windowId,
    enter: (_, at, token) => beginExternalDrag(windowId, at, token),
    move: (at, token) => moveExternalDrag(windowId, at, token),
    leave: (token) => void endExternalDrag(windowId, null, token),
    drop: (at, token) => {
      const beforeId = endExternalDrag(windowId, at, token);
      return beforeId === undefined ? null : { pinned: false, beforeId };
    },
  };
  return (
    <TabDropArea target={target} style={style}>
      {children}
    </TabDropArea>
  );
}

const PEEK_LEFT = 6;
const PEEK_TOP = 4;
const PEEK_HEIGHT = 46;
const PEEK_SHADOW_ROOM = 64;

export function TopStripPeek({ windowWidth, enabled }: { windowWidth: number; enabled: boolean }) {
  const windowId = useWindowId();
  const [live, setLive] = useState(false);
  useIncomingFile(windowId);
  useTopStripPeekProbe(windowId, setLive);
  useEffect(() => {
    if (!enabled) return;
    void setTrafficLightsCenter(windowId, lightsCenter(layout.sidebarWidth));
    return () => void setTrafficLightsCenter(windowId, null);
  }, [enabled, windowId]);
  return (
    <StripDropArea style={{ position: "absolute", left: PEEK_LEFT, top: PEEK_TOP, width: live ? windowWidth - PEEK_LEFT * 2 : 0, height: live ? PEEK_HEIGHT : 0 }}>
      <SolaraHostedView
        kind="topStripPeek"
        windowId={windowId}
        state={JSON.stringify({ enabled, bandLeft: layout.trafficLightsWidth })}
        style={{ position: "absolute", left: -PEEK_LEFT, top: -PEEK_TOP, width: windowWidth, height: PEEK_TOP + PEEK_HEIGHT + PEEK_SHADOW_ROOM }}
      />
    </StripDropArea>
  );
}
