import { SolaraHostedView } from "@solara/settings";
import { StyleSheet } from "react-native";

export function SmallWindowCard({ windowId, tabId, fill, radius }: { windowId: string; tabId: string; fill: string | null; radius: number }) {
  return (
    <SolaraHostedView
      kind="smallWindowCard"
      windowId={windowId}
      pointerEvents="none"
      state={JSON.stringify({ tabId, fill, radius })}
      style={StyleSheet.absoluteFill}
    />
  );
}
