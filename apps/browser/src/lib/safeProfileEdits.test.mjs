import assert from "node:assert/strict";
import { test } from "node:test";

let status = { active: false, safeMode: null };
const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => status,
    dispatch: (json) => { sent.push(...[JSON.parse(json)].flat()); return JSON.stringify({ rev: 0 }); },
    addListener: () => ({ remove() {} }),
  },
};
const { shellNativeModules } = await import("../test-native/shell.ts");
const notices = [];
shellNativeModules.SolaraShell.confirm = async (options) => { notices.push(options); return { confirmed: false, suppressed: false }; };
const { createProfilesSlice } = await import("../store/profiles.ts");
const { startNativeStore, attachReplica } = await import("../store/nativeStore.ts");

function fixture() {
  const listeners = new Set();
  let state;
  const store = {
    getState: () => state,
    setState: (next) => {
      const before = state;
      state = { ...state, ...(typeof next === "function" ? next(state) : next) };
      for (const listener of listeners) listener(state, before);
    },
    subscribe: (listener) => { listeners.add(listener); return () => listeners.delete(listener); },
  };
  state = {
    ...createProfilesSlice(store.setState, store.getState, store),
    profiles: {
      default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 },
      work: { id: "work", name: "Work", color: "blue", icon: "briefcase", createdAt: 1 },
    },
    profileOrder: ["default", "work"],
    settings: {}, downloads: [], ui: {}, history: {}, bookmarks: { roots: {}, nodes: {} }, updateLive: () => {},
  };
  return store;
}

const theme = { mode: "dark", stops: [{ color: { r: 0.1, g: 0.2, b: 0.3, a: 1 }, x: 0.5, y: 0.5 }], intensity: 0.5, grain: 0.4, texture: "grain", translucency: 0.7 };
const edits = [
  ["rename", (state) => state.updateProfile("default", { name: "Renamed" })],
  ["color", (state) => state.updateProfile("default", { color: "green" })],
  ["icon", (state) => state.updateProfile("default", { icon: "star" })],
  ["theme", (state) => state.updateProfile("default", { theme })],
  ["reorder", (state) => state.reorderProfiles(["work", "default"])],
];

for (const safeMode of ["option", "failedLaunches"]) {
  for (const active of [false, true]) {
    test(`safe profile edits are visibly refused without mutation or native writes: ${safeMode}, active=${active}`, () => {
      status = { active, safeMode };
      startNativeStore();
      const store = fixture();
      attachReplica(store);
      const before = structuredClone({ profiles: store.getState().profiles, profileOrder: store.getState().profileOrder });
      sent.length = 0;
      notices.length = 0;
      for (const [index, [name, edit]] of edits.entries()) {
        edit(store.getState());
        const notice = notices.at(-1);
        assert.equal(notices.length, index + 1, name);
        assert.equal(notice.title, "Safe Mode");
        assert.match(notice.message, /Profile edits can't be saved in safe mode.*saved session and launch appearance.*Open Solara normally/);
        assert.equal(notice.confirmTitle, "OK");
        assert.deepEqual({ profiles: store.getState().profiles, profileOrder: store.getState().profileOrder }, before, name);
        assert.deepEqual(sent, [], name);
      }
    });
  }
}

test("normal profile edits still update their fields and order", () => {
  status = { active: false, safeMode: null };
  startNativeStore();
  const store = fixture();
  notices.length = 0;
  for (const [, edit] of edits) edit(store.getState());
  assert.equal(store.getState().profiles.default.name, "Renamed");
  assert.equal(store.getState().profiles.default.color, "green");
  assert.equal(store.getState().profiles.default.icon, "star");
  assert.deepEqual(store.getState().profiles.default.theme, theme);
  assert.deepEqual(store.getState().profileOrder, ["work", "default"]);
  assert.deepEqual(notices, []);
});
