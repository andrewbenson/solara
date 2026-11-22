import assert from "node:assert/strict";
import { sealedState } from "../sealedState.mjs";

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

const { useBrowser } = await import("../../store/browser.ts");
const { emptyScope, Clock } = await import("@solara/sync");
const { docs } = await import("../../test-native/index.ts");
const { digest, choice } = await import("../notes.ts");
const { startNativeStore, standDown } = await import("../../store/nativeStore.ts");
const { syncRedesign } = await import("../redesignSwitch.ts");
const S = () => useBrowser.getState();

await (async () => {
  standDown();
  syncRedesign.on = false;
  S().hydrate({});
  const key = "pw:https://password.example\nuser";
  const value = { o: "https://password.example", u: "user", p: "C" };
  logins = [{ origin: value.o, username: "user", password: "B", created: Date.now() }];
  const state = { ...emptyScope(), joined: true, records: { [key]: { v: value, h: new Clock("remote").tick(Date.now()), o: ["remote", 1] } }, base: { [key]: JSON.stringify({ ...value, p: "A" }) }, unapplied: [key], rebuild: { since: Date.now(), noted: { "pw:": { [key]: digest(choice({ ...value, p: "B" })) } } } };
  files = new Map();
  docs.clear();
  docs.set("sync.json", JSON.stringify({ v: 1, enabled: true, folder: "/sync", deviceId: "local", profiles: { default: { syncId: "passwords", enabled: true } }, types: { bookmarks: false, history: false, tabs: false, pinned: false, passwords: true, extensions: false, settings: false } }));
  docs.set("sync-state.nns", `sealed:${JSON.stringify({ app: { ...emptyScope(), joined: true }, "p:passwords": state })}`);
  redesign = false;
  data = S();
  startNativeStore();
  const engine = await import("../engine.ts?nativePasswordCompatibility");
  engine.startSync();
  for (let i = 0; i < 30; i++) await new Promise((resolve) => setImmediate(resolve));
  await engine.syncNow();
  const saved = sealedState(docs)["p:passwords"];
  assert.deepEqual(JSON.parse(saved.base[key]), value);
  assert.ok(!saved.unapplied.includes(key));
  standDown();
  logins = [];
})();
