import { requireNativeViewManager } from "expo-modules-core";
import { useState } from "react";
import type { ViewProps } from "react-native";

type Props = ViewProps & {
  windowId: string;
  tabId: string;
  onBandHeight: (event: { nativeEvent: { height: number } }) => void;
};

const NativeBand = requireNativeViewManager<Props>("SolaraMedia", "DisplayShareBarHost");

export function NativeDisplayShareBand({ windowId, tabId }: Pick<Props, "windowId" | "tabId">) {
  const [height, setHeight] = useState(0);
  return <NativeBand windowId={windowId} tabId={tabId} onBandHeight={(event) => setHeight(event.nativeEvent.height)} style={{ height }} />;
}
