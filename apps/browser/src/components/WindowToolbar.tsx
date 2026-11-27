import { View } from "react-native";
import { nativeToolbarAvailable, windowShellActive } from "@solara/settings";
import { layout } from "../lib/theme";
import type { ToolbarGeometry } from "./layout/geometry";
import { Toolbar } from "./Toolbar";

const FRAME = { position: "absolute", left: 0, top: 0, right: 0, height: layout.toolbarHeight } as const;

export function WindowToolbar({ windowId, tabId, geometry }: { windowId: string; tabId: string; geometry: ToolbarGeometry }) {
  const nativeStatic = windowShellActive(windowId) && nativeToolbarAvailable();
  return (
    <View pointerEvents="box-none" style={FRAME}>
      <Toolbar tabId={tabId} geometry={geometry} windowId={windowId} inSplit={false} focused bare={!nativeStatic} windowToolbar={nativeStatic} />
    </View>
  );
}
