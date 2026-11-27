import { StyleSheet, View } from "react-native";
import { tourAnchorRef } from "../onboarding/tour/anchors";
import { CheckInBanner } from "./CheckInBanner";
import { PersonalizeButton } from "./Personalize";
import { ReleaseNotesNotices } from "./Postcard";

export type Frame = { x: number; y: number; width: number; height: number };

export function NewTabExtras({ windowId, tabId, bar, onboarding }: { windowId: string; tabId: string; bar: Frame; onboarding: boolean }) {
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="box-none">
      <View ref={tourAnchorRef(windowId, "page")} style={StyleSheet.absoluteFill} pointerEvents="none" />
      <View ref={tourAnchorRef(windowId, "commandBar")} style={{ position: "absolute", left: bar.x, top: bar.y, width: bar.width, height: bar.height }} pointerEvents="none" />
      <CheckInBanner windowId={windowId} tabId={tabId} onboarding={onboarding} />
      <PersonalizeButton windowId={windowId} />
      <ReleaseNotesNotices windowId={windowId} tabId={tabId} onboarding={onboarding} />
    </View>
  );
}
