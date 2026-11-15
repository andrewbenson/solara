import { requireOptionalNativeModule } from "expo-modules-core";
import * as shell from "@solara/shell";
import { readDocument, writeDocument } from "@solara/shell";
import * as actions from "../../src/lib/actions";
import { runCommand } from "../../src/lib/commands";
import { webviews } from "../../src/lib/webviews";
import { usePages } from "../../src/components/layout/pageState";
import { useBrowser } from "../../src/store/browser";
import { devJourneys } from "../../src/lib/perfMarks";

writeDocument("bench-boot.json", JSON.stringify({ jsStart: Date.now() }));

let pausedUntil = 0;
const ac = {
  store: useBrowser,
  pages: usePages,
  actions,
  runCommand,
  webviews,
  shell,
  now: () => Date.now(),
  journeys: devJourneys,
  async nativeWork() {
    const native = requireOptionalNativeModule("SolaraWindowShell");
    if (typeof native?.nativeWork !== "function") return null;
    return JSON.parse(await native.nativeWork(false));
  },
  async omniboxFixture() {
    const native = requireOptionalNativeModule("SolaraNewTab");
    if (!native?.benchFixture) throw new Error("omnibox fixture probe unavailable; rebuild with the probe");
    const s = useBrowser.getState();
    const windowId = s.ui.focusedWindowId && s.windows[s.ui.focusedWindowId] ? s.ui.focusedWindowId : s.windowOrder.find((id) => s.windows[id] && !s.windows[id].kind);
    const w = s.windows[windowId];
    return { ...await native.benchFixture(w?.profileId ?? ""), tabs: Object.keys(s.tabs).length, profileId: w?.profileId };
  },
  get preload() {
    return require("../../src/lib/preload");
  },
  pause(ms) {
    pausedUntil = Date.now() + ms;
  },
};
globalThis.ac = ac;

const idOf = (source) => source?.match(/^\/\/ *(\S+)/)?.[1];
let lastId = idOf(readDocument("bench-cmd.js")) ?? "";

function poll() {
  const wait = pausedUntil - Date.now();
  if (wait > 0) return void setTimeout(poll, wait);
  const source = readDocument("bench-cmd.js");
  const id = idOf(source);
  if (source && id && id !== lastId) {
    lastId = id;
    const done = (body) => writeDocument("bench-result.json", JSON.stringify({ id, ...body }));
    try {
      Promise.resolve(new Function("ac", source)(ac)).then(
        (result) => done({ result: result ?? null }),
        (error) => done({ error: String(error) }),
      );
    } catch (error) {
      done({ error: String(error) });
    }
  }
  setTimeout(poll, 50);
}
setTimeout(poll, 50);
