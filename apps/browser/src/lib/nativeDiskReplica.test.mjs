import assert from "node:assert/strict";
import { test } from "node:test";

const saved = { id: "Saved-MixedCase", dataId: "Saved-Data", name: "Saved", color: "blue", icon: null, createdAt: 0 };
const sent = [];
const refused = [];
const native = { profiles: {}, profileOrder: [], attached: false, rev: 0, recordedAliases: new Set() };
const generated = (id) => id === "default" || /^p-[a-z0-9]+-[1-9a-z][a-z0-9]*$/.test(id);
const response = () => ({ rev: native.rev, patches: [] });
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "settingsAndDownloads" }),
    snapshot: () => JSON.stringify({ rev: native.rev, data: { settings: { chosen: [], inferred: [] }, downloads: [] } }),
    dispatch(json) {
      for (const command of [JSON.parse(json)].flat()) {
        sent.push(command);
        const data = command.args[0];
        if (command.name === "attachReplicaProfiles") {
          const accepted = Object.fromEntries(Object.entries(data.profiles).filter(([key, profile]) => {
            const existing = native.profiles[key];
            if (!native.attached || (generated(key) && generated(profile.id) && generated(profile.dataId ?? profile.id)) || (existing && existing.id === profile.id && existing.dataId === profile.dataId)) return true;
            refused.push(key);
            return false;
          }));
          native.attached = true;
          native.profiles = accepted;
          native.profileOrder = data.profileOrder.filter((id) => accepted[id]);
        } else if (command.name === "applyState" && data.profiles) {
          if (Object.keys(data.profiles).some((id) => !native.profiles[id] && native.recordedAliases.has(id))) {
            return JSON.stringify({ ...response(), error: "This profile was deleted and cannot be reused. Choose a new profile." });
          }
          if (Object.entries(data.profiles).some(([key, profile]) => !generated(key) || !generated(profile.id) || !generated(profile.dataId ?? profile.id))) {
            return JSON.stringify({ ...response(), error: "Profile ids and data ids must use a generated lowercase profile id." });
          }
          native.profiles = data.profiles;
          native.profileOrder = data.profileOrder;
        }
        native.rev++;
      }
      return JSON.stringify(response());
    },
    catchUp: () => JSON.stringify(response()),
    addListener: () => ({ remove() {} }),
    freeze: () => true,
  },
};

const { docs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { startPersistence } = await import("./persist.ts");
const { nativeWrite, standDown } = await import("../store/nativeStore.ts");

test("fallback startup reloads saved off-shape profiles while later live writes stay strict", () => {
  docs.set("session.json", JSON.stringify({ version: 2, profiles: { [saved.id]: saved }, profileOrder: [saved.id], windows: [], tabs: [] }));
  let stop;
  try {
    assert.doesNotThrow(() => { stop = startPersistence(); });
    assert.equal(typeof stop, "function");
    assert.deepEqual(useBrowser.getState().profiles[saved.id], saved);
    assert.deepEqual(native.profiles[saved.id], saved);
    assert.deepEqual(native.profileOrder, [saved.id]);
    assert.equal(sent.filter(({ name }) => name === "attachReplicaProfiles").length, 1);
    const payload = { profiles: { [saved.id]: saved }, profileOrder: [saved.id] };
    assert.throws(() => nativeWrite({ name: "applyState", args: [payload, { attach: true }] }), /generated lowercase/);
    stop();
    stop = undefined;
    standDown();
    assert.doesNotThrow(() => { stop = startPersistence(); });
    assert.equal(typeof stop, "function");
    assert.equal(sent.filter(({ name }) => name === "attachReplicaProfiles").length, 2);
    assert.deepEqual(native.profiles[saved.id], saved);
    stop();
    stop = undefined;
    standDown();
    const fresh = { ...saved, id: "New-OffShape", dataId: "New-Data" };
    docs.set("session.json", JSON.stringify({ version: 2, profiles: { [saved.id]: saved, [fresh.id]: fresh }, profileOrder: [saved.id, fresh.id], windows: [], tabs: [] }));
    assert.doesNotThrow(() => { stop = startPersistence(); });
    assert.equal(typeof stop, "function");
    assert.deepEqual(native.profiles[saved.id], saved);
    assert.equal(native.profiles[fresh.id], undefined);
    assert.deepEqual(refused, [fresh.id]);
  } finally {
    stop?.();
    standDown();
  }
});

test("fallback persistence reloads a stale saved session after a shared alias was deleted", () => {
  const owner = { ...saved, id: "p-owner-1", dataId: "p-engine-1" };
  const alias = { ...saved, id: "p-alias-1", dataId: "p-engine-1" };
  docs.set("session.json", JSON.stringify({ version: 2, profiles: { [owner.id]: owner, [alias.id]: alias }, profileOrder: [owner.id, alias.id], windows: [], tabs: [] }));
  let stop;
  try {
    stop = startPersistence();
    stop();
    stop = undefined;
    standDown();
    for (let reload = 0; reload < 2; reload++) {
      delete native.profiles[alias.id];
      native.profileOrder = [owner.id];
      native.recordedAliases.add(alias.id);
      docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: [alias.id], deleted: [], reserved: [] }));
      assert.doesNotThrow(() => { stop = startPersistence(); });
      assert.deepEqual(native.profiles[alias.id], alias);
      assert.deepEqual(useBrowser.getState().profiles[alias.id], alias);
      assert.deepEqual(native.profileOrder, [owner.id, alias.id]);
      stop();
      stop = undefined;
      standDown();
    }
  } finally {
    stop?.();
    standDown();
  }
});

test("native disk attach command admits exact reload identities and refuses new off-shape profiles per key", async () => {
  const { runNative, source } = await import("../test-native/safe-host/run.mjs");
  const command = source("native/SolaraKit/Sources/SolaraStore/Command.swift");
  const start = command.indexOf('    case "attachReplicaProfiles":');
  const end = command.indexOf('    case "applyState":', start);
  assert.ok(start >= 0 && end > start);
  const store = source("native/SolaraKit/Sources/SolaraStore/Store.swift");
  const originStart = store.indexOf("      let previousSyncOrigin = session.fromSyncOrigin");
  const originEnd = store.indexOf("      if let reason = config.persistenceRefusal", originStart);
  assert.ok(originStart >= 0 && originEnd > originStart);
  const production = `
  func apply(_ name: String, _ data: JSONObject) throws {
    let a = Args(data: data)
    switch name {
${command.slice(start, end)}
    default: throw CommandError("unknown")
    }
  }
  func dispatch(_ name: String, _ data: JSONObject, fromSync: Bool = false, originSync: Bool = false) throws {
    let session = self
    let syncRequest = fromSync || originSync
    let replaying = false
    let body: (Fixture) throws -> Void = { try $0.apply(name, data) }
${store.slice(originStart, originEnd)}
  }`;
  assert.deepEqual(runNative("ReplicaProfiles.swift", production, [], true), Array(25).fill(true));
});
