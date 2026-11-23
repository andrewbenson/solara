import { liveCommand as nativeLiveCommand } from "@solara/settings";
import { persistenceRefused } from "../lib/persistLatch";

export const liveCommand: typeof nativeLiveCommand = (name, payload) =>
  persistenceRefused() ? Promise.reject(new Error("Live Folders are paused because this session saves nothing")) : nativeLiveCommand(name, payload);
