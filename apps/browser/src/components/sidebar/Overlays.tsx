import { useEffect, useState } from "react";
import { StyleSheet, View } from "react-native";
import { useWindowId } from "../../store/hooks";
import { startSidebarEffects } from "./effects";
import { MeetingAlert } from "../live/MeetingAlert";
import { HoverCard } from "./HoverCard";
import { IconPicker } from "./IconPicker";
import { useSidebarWidth } from "./tokens";

export function SidebarOverlays({ windowWidth }: { windowWidth: number }) {
  const windowId = useWindowId();
  const sidebarWidth = useSidebarWidth(windowId);
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(startSidebarEffects, []);
  return (
    <View pointerEvents="box-none" style={StyleSheet.absoluteFill} onLayout={(e) => {
      const { width, height } = e.nativeEvent.layout;
      setSize((size) => size.width === width && size.height === height ? size : { width, height });
    }}>
      <HoverCard windowId={windowId} width={size.width} height={size.height} />
      <MeetingAlert windowId={windowId} windowWidth={windowWidth} />
      <IconPicker windowId={windowId} sidebarWidth={sidebarWidth} />
    </View>
  );
}
