import { StyleSheet } from "react-native";
import { SolaraHostedView } from "@solara/settings";
import { SIDEBAR_FOOTER_DOWNLOADS } from "./layout/windowLayout";

export function DownloadsButton({ windowId }: { windowId: string }) {
  const { size } = SIDEBAR_FOOTER_DOWNLOADS;
  return <SolaraHostedView kind="downloadsButton" windowId={windowId} style={{ width: size, height: size }} />;
}


export function DownloadsSurface({ windowId }: { windowId: string }) {
  return <SolaraHostedView kind="downloadsSurface" windowId={windowId} style={StyleSheet.absoluteFill} />;
}
