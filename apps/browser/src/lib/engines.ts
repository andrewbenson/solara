import type { PageEngine } from "@solara/solaracore";
import { nativeEngineCommand } from "@solara/settings";

export const persistEngine = (tabId: string, engine: PageEngine) => { void nativeEngineCommand(tabId, "persist", { engine }); };
export const goBackAcrossEngines = (tabId: string) => nativeEngineCommand(tabId, "back");
export const openPageIn = (tabId: string, engine: PageEngine, options: { rule?: PageEngine | null; checkWork?: boolean } = {}) =>
  nativeEngineCommand(tabId, "open", { engine, ...options });
export const togglePageEngine = (tabId: string) => nativeEngineCommand(tabId, "toggle");
