import { SolaraHostedView } from "@solara/settings";
import { useEffect } from "react";
import { StyleSheet } from "react-native";
import { startPinHandoff } from "./pinHandoff";

export function FrozenPage({ windowId, tabId, top = 0, headless = false }: { windowId: string; tabId: string | undefined; top?: number; headless?: boolean }) {
  useEffect(startPinHandoff, []);
  if (headless || !tabId) return null;
  return <SolaraHostedView kind="frozenPage" windowId={windowId} state={JSON.stringify({ tabId })} style={[StyleSheet.absoluteFill, { top }]} />;
}
