import type { PageEngine } from "@solara/solaracore";
import { ENGINE_NAMES, ENGINE_SYMBOLS, openPageInTitle } from "../../store/engines";

export const WEBKIT_PILL_ACTION = "webkit:openInChromium";
export const WEBKIT_PILL_WIDTH = 84;

export const webkitPill = () => ({
  id: "webkit",
  icon: ENGINE_SYMBOLS.webkit,
  label: ENGINE_NAMES.webkit,
  size: 12,
  box: 24,
  tooltip: `This page is open in ${ENGINE_NAMES.webkit}`,
  info: {
    title: `This page is open in ${ENGINE_NAMES.webkit}`,
    message: "Extensions, password autofill and casting don't run here.",
    action: openPageInTitle("chromium"),
    actionId: WEBKIT_PILL_ACTION,
  },
});

export const pageExtensionButtons = <T,>(engine: PageEngine, buttons: T[]): (T | ReturnType<typeof webkitPill>)[] =>
  engine === "webkit" ? [webkitPill()] : buttons;

export const pageExtensionsWidth = (engine: PageEngine, width: number) => (engine === "webkit" ? WEBKIT_PILL_WIDTH : width);
