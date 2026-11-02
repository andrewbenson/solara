import { View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { TabIcon } from "./TabIcon";

const MOSAIC_CELL = 9;
const MOSAIC_GAP = 2;
const MOSAIC_PAD = 3.5;
const MOSAIC = MOSAIC_PAD * 2 + MOSAIC_CELL * 2 + MOSAIC_GAP;

export function FolderMosaic({ tabIds }: { tabIds: string[] }) {
  const theme = useTheme();
  return (
    <View
      style={{
        width: MOSAIC,
        height: MOSAIC,
        borderRadius: 7,
        padding: MOSAIC_PAD,
        flexDirection: "row",
        flexWrap: "wrap",
        gap: MOSAIC_GAP,
        backgroundColor: theme.dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)",
      }}
    >
      {tabIds.slice(0, 4).map((id) => (
        <MosaicIcon key={id} tabId={id} />
      ))}
    </View>
  );
}

function MosaicIcon({ tabId }: { tabId: string }) {
  const tab = useBrowser((s) => s.tabs[tabId]);
  if (!tab) return <View style={{ width: MOSAIC_CELL, height: MOSAIC_CELL }} />;
  return (
    <View style={{ width: MOSAIC_CELL, height: MOSAIC_CELL, alignItems: "center", justifyContent: "center" }}>
      <TabIcon tabId={tabId} url={tab.url} favicon={tab.favicon} icon={tab.customIcon} size={MOSAIC_CELL} />
    </View>
  );
}
