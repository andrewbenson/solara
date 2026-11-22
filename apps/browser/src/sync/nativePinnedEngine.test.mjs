import assert from "node:assert/strict";
import { test } from "node:test";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { sealedState } from "./sealedState.mjs";

globalThis.setTimeout = (fn, delay) => delay === 250 ? setImmediate(fn) : 0;
globalThis.clearTimeout = () => {};
let redesign = false;
let data = {};
const sent = [];
let files = new Map();
let logins = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, syncRedesign: redesign }),
    useSyncOrigins: () => true,
    snapshot: () => JSON.stringify({ rev: 0, data }),
    dispatch(json) {
      const decoded = JSON.parse(json);
      const command = decoded.commands ?? decoded;
      sent.push(command);
      return JSON.stringify({ rev: 0, result: command.name === "syncPinsApply" && command.args[1].kind === "homes" ? [] : true });
    },
  },
  SolaraSyncAdapter: {
    newDeviceId: () => "local",
    deviceName: () => "Test Mac",
    unlock: async () => true,
    chainStatus: async () => "ok",
    write: async (_folder, scope, payload) => {
      const id = `f${files.size}`;
      files.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      const here = [...files].filter(([, file]) => file.scope === scope);
      return { files: here.filter(([id]) => !known.includes(id)).map(([id, file]) => ({ id, payload: file.payload })), present: here.map(([id]) => id), damaged: [], pending: [] };
    },
    remove: async (_folder, _scope, ids) => ids.forEach((id) => files.delete(id)),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (text) => text?.startsWith("sealed:") ? text.slice(7) : null,
    readPasswords: async () => logins,
  },
};

const { useBrowser } = await import("../store/browser.ts");
const { emptyScope, Clock } = await import("@solara/sync");
const { docs } = await import("../test-native/index.ts");
const { digest, choice } = await import("./notes.ts");
const { startNativeStore, standDown } = await import("../store/nativeStore.ts");
const { syncRedesign } = await import("./redesignSwitch.ts");
const S = () => useBrowser.getState();

test("native pin partial-key mode preserves legacy password Set behavior", () => {
  execFileSync(process.execPath, ["--no-warnings", "--import", fileURLToPath(new URL("../test-loader.mjs", import.meta.url)), fileURLToPath(new URL("./fixtures/nativePasswordCompatibility.mjs", import.meta.url))], { timeout: 30_000 });
});

for (const on of [false, true]) {
  test(`native home rejection keeps its base and unapplied key, redesign ${on}`, async () => {
    standDown();
    syncRedesign.on = on;
    S().hydrate({});
    const window = S().createWindow({ url: "https://B.example" });
    const tab = S().windows[window].tabIds[0];
    S().groupTabs([tab], { pinned: true, name: "Group" });
    S().setPinnedUrl(tab, "https://B.example");
    const key = `pgh:${tab}`;
    const now = Date.now();
    const stamp = new Clock("remote").tick(now);
    const state = { ...emptyScope(), joined: true, records: { [key]: { v: "https://C.example", h: stamp, o: ["remote", 1] } }, base: { [key]: JSON.stringify("https://A.example") }, unapplied: [key], rebuild: { since: now, noted: { "pgh:": { [key]: digest(JSON.stringify("https://B.example")) } } } };
    files = new Map();
    docs.clear();
    docs.set("sync.json", JSON.stringify({ v: 1, enabled: true, folder: "/sync", deviceId: "local", profiles: { default: { syncId: "pins", enabled: true } }, types: { bookmarks: false, history: false, tabs: false, pinned: true, passwords: false, extensions: false, settings: false } }));
    docs.set("sync-state.nns", `sealed:${JSON.stringify({ app: { ...emptyScope(), joined: true }, "p:pins": state })}`);
    redesign = on;
    data = S();
    startNativeStore();
    sent.length = 0;
    const engine = await import(`./engine.ts?nativePins${on}`);
    engine.startSync();
    for (let i = 0; i < 30; i++) await new Promise((resolve) => setImmediate(resolve));
    await engine.syncNow();
    assert.ok(sent.some((command) => command.name === "syncPinsApply" && command.args[1].kind === "homes"));
    const saved = sealedState(docs)["p:pins"];
    assert.equal(saved.base[key], JSON.stringify("https://A.example"));
    assert.ok(saved.unapplied.includes(key));
    assert.equal(saved.rebuild.noted["pgh:"][key], digest(JSON.stringify("https://B.example")));
    assert.equal(S().tabs[tab].pinnedUrl, "https://B.example");
    standDown();
  });
}
