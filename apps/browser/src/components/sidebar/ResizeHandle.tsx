import { View } from "react-native";
import { useBrowser } from "../../store/browser";
import { commitSidebarWidth, SIDEBAR_DEFAULT_WIDTH, sidebarWidthOf } from "../../store/sidebarRail";
import { useResizeDrag } from "../layout/useResizeDrag";
import { setSidebarUi, sidebarUi } from "./state";
import { SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_WIDTH } from "./tokens";

export function ResizeHandle({ windowId }: { windowId: string }) {
  const handlers = useResizeDrag({
    min: SIDEBAR_MIN_WIDTH,
    max: SIDEBAR_MAX_WIDTH,
    direction: 1,
    saved: () => sidebarWidthOf(useBrowser.getState().settings, false),
    onLive: (w) => {
      const { [windowId]: _, ...rest } = sidebarUi().dragWidth;
      setSidebarUi({ dragWidth: w === null ? rest : { ...rest, [windowId]: Math.round(w * 2) / 2 } });
    },
    onCommit: (width) => commitSidebarWidth(width, false),
  });
  return (
    <View
      {...handlers}
      onDoubleClick={() => commitSidebarWidth(SIDEBAR_DEFAULT_WIDTH, false)}
      style={{ position: "absolute", top: 46, bottom: 0, right: 0, width: 4, cursor: "col-resize" }}
    />
  );
}
