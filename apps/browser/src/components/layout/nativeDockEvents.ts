import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { dismissHoverIn } from "../sidebar/hover";
import { applyWindowLayoutPreferences } from "./windowLayout";
import { setDockMoving, setPeekShown } from "./dockMotion";

export const nativeDockListeners = new Map<string, (value: number, moving: boolean) => void>();

addNativeSettingsHandlers({
  "window.layoutPreferences": applyWindowLayoutPreferences,
  ["sidebar.dock"]: (windowId: string, event: string, extra: { value?: number; moving?: boolean; live?: boolean; right?: number; rect?: [number, number, number, number] | null }) => {
    if (event === "dock") {
      setDockMoving(windowId, !!extra.moving);
      nativeDockListeners.get(windowId)?.(extra.value ?? 0, !!extra.moving);
    } else if (event === "peek") {
      setPeekShown(windowId, !!extra.live, extra.right ?? 0, extra.rect ?? undefined);
      dismissHoverIn(windowId);
    } else if (event === "slideOut") dismissHoverIn(windowId);
  },
});
