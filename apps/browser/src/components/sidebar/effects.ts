import { onAppEvent, onWindowEvent } from "@solara/shell";
import { startLive } from "../../live";
import { dismissHover } from "./hover";
import { sidebarUi } from "./state";

let started = false;

export function startSidebarEffects() {
  if (started) return;
  started = true;
  startLive();

  onAppEvent((e) => {
    if (e.type === "resignActive" || e.type === "screenLocked") {
      dismissHover();
    }
  });

  onWindowEvent((e) => {
    const hover = sidebarUi().hover;
    if (e.type === "focus" && hover && hover.windowId !== e.id) dismissHover();
  });
}
