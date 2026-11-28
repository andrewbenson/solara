import { View } from "react-native";
import { commitSidebarWidth, SIDEBAR_DEFAULT_WIDTH } from "../../store/sidebarRail";
import { useWindowLayoutPreferences } from "../layout/windowLayout";
import { useResizeDrag } from "../layout/useResizeDrag";
import { setSidebarUi, sidebarUi } from "./state";
import { SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_WIDTH } from "./tokens";

export function ResizeHandle({ windowId }: { windowId: string }) {
  const { savedSidebarWidth } = useWindowLayoutPreferences();
  const handlers = useResizeDrag({
    min: SIDEBAR_MIN_WIDTH,
    max: SIDEBAR_MAX_WIDTH,
    direction: 1,
    saved: () => savedSidebarWidth,
    onLive: (w) => {
      const { [windowId]: _, ...rest } = sidebarUi().dragWidth;
      setSidebarUi({ dragWidth: w === null ? rest : { ...rest, [windowId]: Math.round(w * 2) / 2 } });
    },
    onCommit: (width) => commitSidebarWidth(windowId, width, false),
  });
  return (
    <View
      {...handlers}
      onDoubleClick={() => commitSidebarWidth(windowId, SIDEBAR_DEFAULT_WIDTH, false)}
      style={{ position: "absolute", top: 46, bottom: 0, right: 0, width: 4, cursor: "col-resize" }}
    />
  );
}
