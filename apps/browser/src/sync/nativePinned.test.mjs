import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
let redesign = false;
let response = { result: true };
let snapshot = {};
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, syncRedesign: redesign }),
    useSyncOrigins: () => true,
    snapshot: () => JSON.stringify({ rev: 0, data: snapshot }),
    dispatch(json) {
      sent.push(JSON.parse(json));
      return JSON.stringify({ rev: 0, ...response });
    },
  },
};

const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore, standDown } = await import("../store/nativeStore.ts");
const pinned = await import("./pinned.ts");
const { syncRedesign } = await import("./redesignSwitch.ts");
const S = () => useBrowser.getState();
const records = { known: (key) => key === "pin:g:remote", now: 900, horizon: 8000, joined: true };
const command = () => sent.at(-1).commands ?? sent.at(-1);
const adapters = [
  ["pins", "pinnedAdapter", "pin:t:remote", { g: "remote", u: "https://remote.example", pos: "a" }],
  ["rows", "pinnedRowsAdapter", "pinrow:remote", 1],
  ["order", "pinnedOrderAdapter", "pord:g:remote", { a: "local" }],
  ["looks", "groupLooksAdapter", "pgc:remote", "none"],
  ["homes", "pinnedHomesAdapter", "pgh:remote", "https://remote.example"],
  ["tileFolders", "tileFoldersAdapter", "tilefold:remote", { f: "folder" }],
];

for (const on of [false, true]) {
  test(`native adapters send one kind-tagged command and preserve outcomes, redesign ${on}`, () => {
    standDown();
    syncRedesign.on = on;
    S().hydrate({});
    redesign = on;
    startNativeStore();
    for (const [kind, name, key, value] of adapters) {
      sent.length = 0;
      response = { result: true };
      const apply = () => pinned[name]("default").apply(new Map([[key, value]]), new Set([key]), () => undefined, records);
      assert.equal(apply(), true);
      assert.equal(sent.length, 1);
      assert.equal(command().name, "syncPinsApply");
      assert.equal(command().args[0], "default");
      assert.equal(command().args[1].kind, kind);
      assert.deepEqual(command().args[1].visible, [[key, value]]);
      assert.deepEqual(command().args[1].changed, [key]);
      assert.deepEqual(command().args[1].base, {});
      assert.equal(command().args[1].now, 900);
      assert.equal(command().args[1].horizon, 8000);
      for (const failure of [{ result: false }, { error: "bad decoder" }, { busy: true }, {}, { result: null }, { result: [key, null] }]) {
        response = failure;
        assert.equal(apply(), false);
      }
      response = { result: [key] };
      assert.deepEqual(apply(), new Set([key]));
    }
    standDown();
  });

  test(`native inputs freeze cross-prefix base, absent and null, redesign ${on}`, () => {
    standDown();
    redesign = on;
    snapshot = { tabs: { current: { id: "current", pinKey: "native", profileId: "default" } }, groups: { currentGroup: { id: "currentGroup", pinKey: "nativeGroup", profileId: "default" } } };
    response = { result: true };
    startNativeStore();
    const base = { "pinrow:remote": null, "tilefold:remote": { f: "baseFolder" }, "tilefold:n:baseFolder": { n: "Frozen" }, "pgh:native": "https://native.example", "pord:g:nativeGroup": { a: null } };
    pinned.pinnedAdapter("default").apply(new Map([["pin:t:remote", { g: "remote", u: "https://remote.example", pos: "a" }]]), new Set(["pin:t:remote"]), (key) => base[key], records);
    assert.deepEqual(command().args[1].base, base);
    assert.ok(!Object.hasOwn(command().args[1].base, "pgc:remote"));
    assert.ok(command().args[1].known.includes("pin:g:remote"));
    base["tilefold:n:baseFolder"].n = "Later";
    assert.equal(command().args[1].base["tilefold:n:baseFolder"].n, "Frozen");
    pinned.pinnedAdapter("default").apply(new Map([["pin:t:malformed", { g: 7, u: "https://remote.example", pos: "a" }]]), new Set(["pin:t:malformed"]), () => undefined, { ...records, known: (key) => key === "pin:g:7" });
    assert.deepEqual(command().args[1].known, ["pin:g:7"]);
    snapshot = {};
    standDown();
  });

  test(`durable publication settles natively without changing the replica, redesign ${on}`, () => {
    standDown();
    syncRedesign.on = on;
    S().hydrate({});
    const window = S().createWindow({ url: "https://row.example" });
    const id = S().windows[window].tabIds[0];
    S().pinTabs([id], true, true);
    const chosen = S().pinChoices;
    const extraction = pinned.pinnedRowsAdapter("default").extract(() => undefined, () => false);
    redesign = on;
    response = { result: true };
    startNativeStore();
    sent.length = 0;
    extraction.published(new Set([`pinrow:${id}`]));
    assert.equal(sent.length, 1);
    assert.equal(command().name, "settlePinChoices");
    assert.deepEqual(command().args, ["default", { [id]: chosen.default[id] }]);
    assert.equal(S().pinChoices, chosen);
    standDown();
  });
}
