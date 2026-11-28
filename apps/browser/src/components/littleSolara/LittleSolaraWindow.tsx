import { View } from "react-native";
import { ContentCard } from "../ContentCard";
import { SMALL_BAR_HEIGHT, SMALL_INSET } from "./SmallChrome";

export function LittleSolaraWindow() {
  return (
    <View pointerEvents="box-none" style={{ flex: 1, flexDirection: "row", paddingTop: SMALL_BAR_HEIGHT, paddingLeft: SMALL_INSET, paddingRight: SMALL_INSET, paddingBottom: SMALL_INSET }}>
      <ContentCard small />
    </View>
  );
}
