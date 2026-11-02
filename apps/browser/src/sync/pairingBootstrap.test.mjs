import assert from "node:assert/strict";
import { test } from "node:test";
import { startProfileConfirmation } from "../test-native/profileConfirmation.mjs";

const timers = [];
globalThis.setTimeout = (fn, ms) => (timers.push({ fn, ms }), 0);
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;
let ids = 0;
const invalidations = [];
const calls = { unlock: 0, write: 0, remove: 0, forget: 0, create: 0, reads: 0 };
const folder = new Map();
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    async createSync(folder) {
      const account = this.newDeviceId();
      if (!(await this.createPhrase(account))) return null;
      await this.createChain(folder);
      return account;
    },
    invalidatePairing: (reason) => invalidations.push(reason),
    chooseFolder: async () => null,
    newDeviceId: () => `device-${++ids}`,
    deviceName: () => "Joining Mac",
    createPhrase: async () => (calls.create++, true),
    enterPhrase: async () => ({ ok: true }),
    createChain: async () => {},
    unlock: async () => (calls.unlock++, true),
    forget: async () => { calls.forget++; },
    chainStatus: async () => "ok",
    write: async (_folder, scope, payload) => {
      calls.write++;
      const id = `file-${++ids}`;
      folder.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      calls.reads++;
      const all = [...folder].filter(([, f]) => f.scope === scope);
      return { files: all.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: all.map(([id]) => id) };
    },
    remove: async () => { calls.remove++; },
    deleteChain: async () => { calls.remove++; },
    sealLocal: async (value) => `sealed:${value}`,
    openLocal: async (value) => value.startsWith("sealed:") ? value.slice(7) : null,
    readPasswords: async () => null,
  },
};
const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
await startProfileConfirmation();
const S = () => useBrowser.getState();
const settle = async (n = 35) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };
let revision = 0;
const launch = async () => import(`./engine.ts?pair-${++revision}`);
const base = () => ({ v: 1, enabled: false, folder: "/sync", deviceId: null, clock: null, types: { bookmarks: true, history: true, tabs: true, pinned: true, passwords: true, extensions: true, settings: true }, profiles: {}, scopes: {}, lastSyncedAt: null, setupAt: null, joining: false });
const identity = () => ({ transaction: "a".repeat(64), folder: "/sync", folderIdentity: "folder-identity", cid: "b".repeat(32), deviceId: "joining-device", account: "joining-device", generation: 1, stopGeneration: 0, phase: "prepared", route: "settings", priorState: "0:ztntfp" });
const request = () => ({ handle: "installation-handle", folder: "/sync", folderIdentity: "folder-identity", cid: "b".repeat(32), generation: 1, stopGeneration: 0 });
const clone = (value) => JSON.parse(JSON.stringify(value));
function hostFor() {
  const state = { marker: null, key: false, consumed: 0, saves: 0, stopped: 0, receipts: new Map(), consumeGate: null, readGate: null, checkpointGate: null, failCheckpoint: false, failSave: false, corruptReceipt: false, descriptor: identity(), lostSave: false };
  const receipt = (op) => ({ operationId: op.operationId, transaction: op.transaction, generation: op.generation, key: op.key, value: op.localValue, disposition: op.disposition });
  const host = {
    acknowledgePairingInitialization: async (transaction, generation) => {
      state.initialized = { transaction, generation };
      if (state.initializationGate) await state.initializationGate;
      if (state.failInitialization) throw new Error("private initialization failure");
    },
    acknowledgePairingReady: async (transaction, generation) => {
      state.ready = { transaction, generation };
      if (state.readyGate) await state.readyGate;
      if (state.failReady) throw new Error("private ready failure");
    },
    consumeInstallation: async (handle, priorState) => {
      state.consumed++;
      if (state.consumeGate) await state.consumeGate;
      if (handle !== "installation-handle" || state.marker) throw new Error("invalid or consumed handle");
      state.marker = clone({ ...state.descriptor, priorState: state.priorOverride ?? priorState });
      return clone(state.marker);
    },
    saveInstallation: async (installed) => {
      state.saves++;
      state.key = true;
      state.marker = { ...installed, phase: "key-saved" };
      if (state.failSave) throw new Error("save callback lost");
      if (state.lostSave) await new Promise(() => {});
    },
    readInstallation: async (installed) => {
      if (state.readGate) await state.readGate;
      return { ...installed, ...(state.readOverride ?? {}), phase: state.key ? "key-saved" : "prepared" };
    },
    recoverInstallation: async () => state.marker && clone({ ...state.marker, phase: state.key ? "key-saved" : "prepared" }),
    stopInstallation: async (_installed, stopped) => { state.stopped = stopped; state.marker = null; },
    reconcileApplied: async (op) => state.receipts.get(op.operationId) ?? null,
    checkpointApplied: async (op) => {
      if (state.checkpointGate) await state.checkpointGate;
      if (state.failCheckpoint) throw new Error("store commit refused");
      const ack = receipt(op);
      const previous = state.receipts.get(op.operationId);
      if (previous && JSON.stringify(previous) !== JSON.stringify(ack)) throw new Error("operation ID reused with a different durable result");
      state.receipts.set(op.operationId, ack);
      shell.docs.set("pairing-store.json", JSON.stringify({ settings: S().settings, profiles: S().profiles }));
      return state.corruptReceipt ? { ...ack, transaction: "other" } : ack;
    },
  };
  return { host, state };
}
function reset(doc = null) {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  shell.docs.clear();
  shell.documentWrites.length = 0;
  shell.heldSaves.on = false;
  shell.heldSaves.fail = false;
  shell.heldSaves.only = null;
  shell.heldSaves.queue.length = 0;
  folder.clear();
  invalidations.length = 0;
  timers.length = 0;
  for (const key of Object.keys(calls)) calls[key] = 0;
  if (doc) shell.docs.set("sync.json", JSON.stringify(doc));
}
const saved = () => JSON.parse(shell.docs.get("sync.json"));
const addLog = (ops, seq = 1) => folder.set(`remote-${seq}`, { scope: "app", payload: JSON.stringify({ v: 1, kind: "log", device: "trusted", seq, at: Date.now(), ops: ops.map(([k, v]) => ({ k, v, h: `${(Date.now() + seq).toString(36).padStart(9, "0")}.0000.trusted` })) }) });
const remoteDefault = { n: "Remote default", c: "blue", i: null, d: true };
async function admit() {
  const { host, state } = hostFor();
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.joinFromPairing(request(), host), { ok: true });
  return { engine, host, state };
}
const pendingDoc = (phase) => ({ ...base(), v: 2, enabled: phase !== "stopped", deviceId: "joining-device", joining: phase !== "ready" && phase !== "stopped", joinTransaction: "a".repeat(64), installation: identity(), stopGeneration: phase === "stopped" ? 1 : 0, bootstrap: { phase, transaction: "a".repeat(64), generation: 1 } });

test("pairing initializes v2 and awaiting-profile together in one acknowledged write, keeping opt-outs and journals", async () => {
  reset({ ...base(), types: { ...base().types, history: false, settings: false }, profiles: { local: { syncId: "old", enabled: false } } });
  shell.docs.set("sync-journal.nns", "prior-batch");
  shell.docs.set("sync-edit-journal.json", "prior-edit");
  const { engine } = await admit();
  assert.equal(saved().v, 2);
  assert.equal(saved().enabled, true);
  assert.equal(saved().joining, true);
  assert.equal(saved().joinTransaction, "a".repeat(64));
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(saved().types.settings, false);
  assert.equal(saved().types.history, false);
  assert.deepEqual(saved().profiles.local, { syncId: "old", enabled: false });
  assert.equal(shell.docs.get("sync-journal.nns"), "prior-batch");
  assert.equal(shell.docs.get("sync-edit-journal.json"), "prior-edit");
  assert.equal(calls.create + calls.write, 0);
  assert.equal(engine.useSync.getState().enabled, true);
});

test("initial enabled checkpoint must acknowledge before admission succeeds or cycles start", async () => {
  reset();
  const { host } = hostFor();
  const engine = await launch();
  engine.startSync(host);
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync.json";
  let resolved = false;
  const joining = engine.joinFromPairing(request(), host).then((v) => (resolved = true, v));
  await settle();
  assert.equal(resolved, false);
  assert.equal(shell.docs.has("sync.json"), false);
  await engine.syncNow();
  assert.equal(calls.write + calls.reads, 0);
  shell.heldSaves.on = false;
  shell.heldSaves.queue.shift()();
  assert.deepEqual(await joining, { ok: true });
  assert.equal(saved().v, 2);
});

for (const field of ["folder", "folderIdentity", "cid", "generation", "stopGeneration"]) {
  test(`pairing rejects consumed ${field} mismatch before saving key`, async () => {
    reset();
    const { host, state } = hostFor();
    state.descriptor[field] = typeof state.descriptor[field] === "number" ? 3 : "wrong";
    const engine = await launch();
    engine.startSync(host);
    const result = await engine.joinFromPairing(request(), host);
    assert.ok("error" in result);
    assert.equal(state.saves, 0);
    assert.equal(shell.docs.has("sync.json"), false);
  });
  test(`pairing rejects readback ${field} mismatch without initialization`, async () => {
    reset();
    const { host, state } = hostFor();
    state.readOverride = { [field]: typeof identity()[field] === "number" ? 3 : "wrong" };
    const engine = await launch();
    engine.startSync(host);
    assert.ok("error" in await engine.joinFromPairing(request(), host));
    assert.equal(shell.docs.has("sync.json"), false);
    assert.equal(calls.write, 0);
  });
}
for (const patch of [{ account: "other-account" }, { deviceId: "" }, { transaction: "bad" }, { phase: "ready" }, { generation: 0 }]) {
  test(`pairing rejects malformed native descriptor ${JSON.stringify(patch)}`, async () => {
    reset();
    const { host, state } = hostFor();
    Object.assign(state.descriptor, patch);
    const engine = await launch();
    engine.startSync(host);
    assert.ok("error" in await engine.joinFromPairing(request(), host));
    assert.equal(state.saves, 0);
    assert.equal(shell.docs.has("sync.json"), false);
  });
}

test("admission serializes pairing against duplicate handles, phrase join and turn on", async () => {
  reset();
  const { host, state } = hostFor();
  let release;
  state.consumeGate = new Promise((r) => { release = r; });
  const engine = await launch();
  engine.startSync(host);
  const first = engine.joinFromPairing(request(), host);
  await settle();
  assert.ok("error" in await engine.joinFromPairing(request(), host));
  assert.ok("error" in await engine.turnOnSync("/sync"));
  assert.ok("error" in await engine.enterRecoveryPhrase("/sync", "words"));
  assert.equal(state.consumed, 1);
  release();
  assert.deepEqual(await first, { ok: true });
  assert.equal(state.saves, 1);
});

test("unsupported version refuses admission even before startup", async () => {
  reset({ ...base(), v: 7 });
  const original = shell.docs.get("sync.json");
  const { host, state } = hostFor();
  const engine = await launch();
  assert.ok("error" in await engine.joinFromPairing(request(), host));
  assert.equal(state.consumed, 0);
  assert.equal(shell.docs.get("sync.json"), original);
});

for (const phase of ["unknown", null, "ready"]) {
  test(`contradictory v2 ${phase} fails closed without native reads or overwrite`, async () => {
    const doc = pendingDoc(phase);
    if (phase === null) delete doc.bootstrap;
    if (phase === "ready") doc.joining = true;
    reset(doc);
    const before = new Map(shell.docs);
    const { host, state } = hostFor();
    const engine = await launch();
    engine.startSync(host);
    await settle();
    await engine.syncNow();
    await engine.stopSync({ deleteData: true });
    assert.equal(engine.useSync.getState().status, "unavailable");
    assert.equal(calls.unlock + calls.write + calls.remove, 0);
    assert.equal(state.consumed, 0);
    assert.deepEqual(shell.docs, before);
  });
}

test("device/settings-only authenticated logs keep bootstrap pending across relaunch without allocating or publishing", async () => {
  reset();
  const { engine, host, state } = await admit();
  addLog([["dev:trusted", { n: "Trusted" }], ["set:searchEngine", { v: "bing" }]]);
  const allocated = ids;
  for (let i = 0; i < 3; i++) await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(saved().joining, true);
  assert.equal(ids, allocated);
  assert.equal(calls.write + calls.remove, 0);
  const again = await launch();
  again.startSync(host);
  await settle();
  await again.syncNow();
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(state.saves, 1);
  assert.equal(calls.write + calls.remove, 0);
});

for (const ops of [
  [["prof:r", { n: 7, c: "blue", i: null, d: true }]],
  [["prof:r", remoteDefault], ["prof:s", { ...remoteDefault, n: "Other" }]],
  [["prof:r", remoteDefault], ["share:r", { o: "missing" }]],
  [["prof:r", remoteDefault], ["pth:r", { t: { invalid: true } }]],
]) {
  test(`invalid or incomplete default plan remains pending ${JSON.stringify(ops)}`, async () => {
    reset();
    const { engine } = await admit();
    addLog(ops);
    await engine.syncNow();
    assert.equal(saved().bootstrap.phase, "awaiting-profile");
    assert.equal(saved().joining, true);
    assert.equal(calls.write + calls.remove, 0);
  });
}

test("valid default and required settings use durable binding, applying and ready checkpoints before publication", async () => {
  reset();
  const { engine, state } = await admit();
  addLog([["prof:remote-default", remoteDefault], ["set:searchEngine", { v: "bing" }]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error ?? "ready");
  assert.equal(saved().joining, false);
  assert.equal(saved().profiles.default.syncId, "remote-default");
  assert.equal(S().profiles.default.name, "Remote default");
  assert.equal(S().settings.searchEngine, "bing");
  assert.equal(calls.write + calls.remove, 0);
  assert.ok(state.receipts.size >= 2);
  assert.ok(shell.docs.has("pairing-store.json"));
  await engine.syncNow();
  assert.ok(calls.write > 0);
  assert.equal(saved().v, 2);
});

for (const failure of ["failCheckpoint", "corruptReceipt"]) {
  test(`required durable apply ${failure} cannot advance ready`, async () => {
    reset();
    const { engine, state } = await admit();
    state[failure] = true;
    addLog([["prof:r", remoteDefault], ["set:searchEngine", { v: "bing" }]]);
    await engine.syncNow();
    assert.equal(saved().bootstrap.phase, "applying");
    assert.equal(saved().joining, true);
    assert.equal(calls.write + calls.remove, 0);
    state[failure] = false;
    await engine.syncNow();
    assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error ?? "ready");
  });
}

test("prepared marker without key never enables, while key-saved marker completes one initialization", async () => {
  reset();
  let pair = hostFor();
  pair.state.marker = identity();
  let engine = await launch();
  engine.startSync(pair.host);
  await settle();
  assert.equal(shell.docs.has("sync.json"), false);
  assert.equal(calls.write + calls.unlock, 0);
  reset();
  pair = hostFor();
  pair.state.marker = { ...identity(), phase: "key-saved" };
  pair.state.key = true;
  engine = await launch();
  engine.startSync(pair.host);
  await settle();
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(saved().v, 2);
  assert.equal(pair.state.saves, 0);
});

test("key-save callback lost is recovered by actual key readback without another save or identity", async () => {
  reset();
  const { host, state } = hostFor();
  state.failSave = true;
  const engine = await launch();
  engine.startSync(host);
  await engine.joinFromPairing(request(), host);
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(state.saves, 1);
  assert.equal(saved().deviceId, "joining-device");
});

for (const boundary of ["binding-persisted", "applying", "ready"]) {
  test(`crash before ${boundary} acknowledgment recovers without publishing or replacing identity`, async () => {
    reset();
    const { engine, host, state } = await admit();
    addLog([["prof:r", remoteDefault], ["set:searchEngine", { v: "bing" }]]);
    shell.heldSaves.on = true;
    shell.heldSaves.only = "sync.json";
    const running = engine.syncNow();
    await settle();
    let guard = 0;
    while (shell.heldSaves.queue.length && saved().bootstrap.phase !== boundary && guard++ < 15) {
      const land = shell.heldSaves.queue.shift();
      land();
      await settle();
      if (saved().bootstrap.phase === boundary) break;
    }
    assert.equal(saved().bootstrap.phase, boundary);
    const snapshot = new Map(shell.docs);
    const receipts = state.receipts.size;
    shell.heldSaves.on = false;
    shell.heldSaves.queue.length = 0;
    const again = await launch();
    again.startSync(host);
    await settle();
    if (boundary !== "ready") await again.syncNow();
    assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error ?? "ready");
    assert.equal(saved().deviceId, "joining-device");
    assert.equal(state.saves, 1);
    assert.ok(state.receipts.size >= receipts);
    assert.equal(snapshot.has("sync.json"), true);
    void running;
  });
}

test("Stop while install is pending writes v2 stopped tombstone and delayed callbacks cannot enable", async () => {
  reset();
  const { host, state } = hostFor();
  let release;
  state.readGate = new Promise((r) => { release = r; });
  const engine = await launch();
  engine.startSync(host);
  const joining = engine.joinFromPairing(request(), host);
  await settle();
  await engine.stopSync();
  assert.equal(saved().v, 2);
  assert.equal(saved().enabled, false);
  assert.equal(saved().bootstrap.phase, "stopped");
  assert.equal(saved().stopGeneration, 1);
  release();
  await joining;
  assert.equal(saved().enabled, false);
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(saved().enabled, false);
  assert.equal(calls.write + calls.forget, 0);
});

test("Stop pending bootstrap preserves v2 transaction and quarantined journals without publication", async () => {
  reset();
  shell.docs.set("sync-journal.nns", "prior-batch");
  const { engine, host, state } = await admit();
  await engine.stopSync();
  assert.equal(saved().v, 2);
  assert.equal(saved().bootstrap.phase, "stopped");
  assert.equal(saved().joinTransaction, "a".repeat(64));
  assert.equal(shell.docs.get("sync-journal.nns"), "prior-batch");
  assert.equal(calls.write + calls.remove + calls.forget, 0);
  state.marker = { ...identity(), phase: "key-saved" };
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(saved().enabled, false);
});

test("v1 phrase and creation keep v1, while explicit pairing is the only v1 to v2 migration", async () => {
  reset();
  let engine = await launch();
  engine.startSync();
  assert.deepEqual(await engine.enterRecoveryPhrase("/sync", "words"), { ok: true });
  assert.equal(saved().v, 1);
  reset();
  engine = await launch();
  engine.startSync();
  assert.deepEqual(await engine.turnOnSync("/sync"), { ok: true });
  assert.equal(saved().v, 1);
});

test("corrupt sync.json refuses explicit pairing instead of overwriting recovery state", async () => {
  reset();
  shell.docs.set("sync.json", '{"v":2,"bootstrap":');
  const original = shell.docs.get("sync.json");
  const { host, state } = hostFor();
  const engine = await launch();
  assert.ok("error" in await engine.joinFromPairing(request(), host));
  assert.equal(state.consumed, 0);
  assert.equal(shell.docs.get("sync.json"), original);
});

test("marker prior disabled state must match before initialization", async () => {
  reset({ ...base(), types: { ...base().types, history: false } });
  const { host, state } = hostFor();
  state.marker = { ...identity(), phase: "key-saved", priorState: "wrong-prior-state" };
  state.key = true;
  const before = new Map(shell.docs);
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(shell.docs, before);
  assert.equal(engine.useSync.getState().enabled, false);
});

test("Stop generation is independent of high installation generation and survives relaunch", async () => {
  reset();
  const { host, state } = hostFor();
  state.descriptor.generation = 100;
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.joinFromPairing({ ...request(), generation: 100 }, host), { ok: true });
  await engine.stopSync();
  assert.equal(saved().stopGeneration, 1);
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(again.useSync.getState().status, "off");
  assert.equal(saved().bootstrap.phase, "stopped");
});

test("an authenticated snapshot can bind a default whose origin is another writer", async () => {
  reset();
  const { engine } = await admit();
  const h = `${Date.now().toString(36).padStart(9, "0")}.0000.origin`;
  folder.set("compacted", { scope: "app", payload: JSON.stringify({ v: 1, kind: "snapshot", device: "compactor", at: Date.now(), vv: { origin: 9 }, seen: { origin: Date.now() }, records: { "prof:r": { h, o: ["origin", 9], v: remoteDefault } } }) });
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error);
  assert.equal(saved().profiles.default.syncId, "r");
});

test("a local edit during durable apply acknowledgment cannot be marked as the older remote value", async () => {
  reset();
  const { engine, host, state } = await admit();
  const checkpoint = host.checkpointApplied;
  let release;
  let reached = false;
  const gate = new Promise((r) => { release = r; });
  host.checkpointApplied = async (op) => {
    const receipt = await checkpoint(op);
    if (op.key === "set:searchEngine" && !reached) { reached = true; await gate; }
    return receipt;
  };
  addLog([["prof:r", remoteDefault], ["set:searchEngine", { v: "bing" }]]);
  const running = engine.syncNow();
  await settle();
  assert.equal(reached, true);
  S().updateSettings({ searchEngine: "duckduckgo" });
  release();
  await running;
  await engine.syncNow();
  assert.equal(S().settings.searchEngine, "duckduckgo");
  assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error);
  const last = [...state.receipts.values()].reverse().find((receipt) => receipt.key === "set:searchEngine");
  assert.equal(last.disposition, "local-choice");
  assert.deepEqual(last.value, { v: "duckduckgo" });
});

test("Stop queues behind an already-issued initial write and remains the final durable state", async () => {
  reset();
  const { host } = hostFor();
  const engine = await launch();
  engine.startSync(host);
  await settle();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync.json";
  const joining = engine.joinFromPairing(request(), host);
  await settle();
  assert.equal(shell.heldSaves.queue.length, 1);
  const stopping = engine.stopSync();
  await settle();
  shell.heldSaves.on = false;
  shell.heldSaves.queue.shift()();
  await Promise.all([joining, stopping]);
  assert.equal(saved().v, 2);
  assert.equal(saved().enabled, false);
  assert.equal(saved().bootstrap.phase, "stopped");
});

test("stopped paired documents cannot be silently down-converted by phrase, Turn On or local setters", async () => {
  reset();
  const { engine, host } = await admit();
  await engine.stopSync();
  assert.ok("error" in await engine.turnOnSync("/sync"));
  assert.ok("error" in await engine.enterRecoveryPhrase("/sync", "words"));
  engine.setTypeSynced("history", false);
  await settle();
  assert.equal(saved().v, 2);
  assert.equal(saved().bootstrap.phase, "stopped");
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(saved().enabled, false);
});

test("after ready ordinary state and publishing counters survive relaunch", async () => {
  reset();
  const { engine, host } = await admit();
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  await engine.syncNow();
  S().updateSettings({ searchEngine: "bing" });
  await engine.syncNow();
  await settle();
  const prior = [...folder.values()].filter((f) => f.scope === "app").map((f) => JSON.parse(f.payload)).filter((f) => f.kind === "log" && f.device === "joining-device");
  const previousSeq = Math.max(...prior.map((f) => f.seq));
  const again = await launch();
  again.startSync(host);
  await settle();
  S().updateSettings({ searchEngine: "duckduckgo" });
  await again.syncNow();
  await again.syncNow();
  await settle();
  const later = [...folder.values()].filter((f) => f.scope === "app").map((f) => JSON.parse(f.payload)).filter((f) => f.kind === "log" && f.device === "joining-device");
  assert.ok(Math.max(...later.map((f) => f.seq)) > previousSeq, `${again.useSync.getState().status}: ${again.useSync.getState().error}; seqs ${later.map((f) => f.seq)} before ${previousSeq}`);
  const seen = new Map();
  for (const file of later) {
    assert.equal(seen.get(file.seq) ?? JSON.stringify(file.ops), JSON.stringify(file.ops));
    seen.set(file.seq, JSON.stringify(file.ops));
  }
  assert.equal(saved().v, 2);
  assert.equal(S().settings.searchEngine, "duckduckgo");
});


test("Stop cancels a ready cycle held at chain status before any further publication", async () => {
  reset();
  const { engine } = await admit();
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready");
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const previous = native.chainStatus;
  let reached = false;
  native.chainStatus = async () => { reached = true; await gate; return "ok"; };
  try {
    const cycling = engine.syncNow();
    await settle();
    assert.equal(reached, true);
    await engine.stopSync();
    const writes = calls.write;
    release();
    await cycling;
    assert.equal(saved().bootstrap.phase, "stopped");
    assert.equal(calls.write, writes);
    assert.equal(engine.useSync.getState().status, "off");
  } finally {
    release();
    native.chainStatus = previous;
  }
});

test("bootstrap checkpoints retain the observed clock for a ready restart and later local edit", async () => {
  reset();
  const { engine, host } = await admit();
  const h = `${(Date.now() + 86_400_000).toString(36).padStart(9, "0")}.0000.trusted`;
  folder.set("future-log", { scope: "app", payload: JSON.stringify({ v: 1, kind: "log", device: "trusted", seq: 1, at: Date.now(), ops: [{ k: "prof:r", v: remoteDefault, h }, { k: "set:searchEngine", v: { v: "bing" }, h }] }) });
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready");
  const again = await launch();
  again.startSync(host);
  await settle();
  S().updateSettings({ searchEngine: "duckduckgo" });
  await again.syncNow();
  assert.equal(again.appScopeRecords()["set:searchEngine"].v.v, "duckduckgo");
  assert.ok(again.appScopeRecords()["set:searchEngine"].h > h);
});

test("bootstrap normalizes legacy shortcut names before durable apply expectations", async () => {
  reset();
  const { engine } = await admit();
  addLog([["prof:r", remoteDefault], ["set:shortcuts", { v: { toggleOpenLinksInSmallYahu: "Ctrl+Y" } }]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error);
  assert.deepEqual(S().settings.shortcuts, { toggleOpenLinksInLittleSolara: "Ctrl+Y" });
});

test("bootstrap accepts a remote share whose matched local profiles already share one data group", async () => {
  reset();
  const owner = S().createProfile({ name: "Owner", color: "blue", shareWith: "default" });
  const before = { default: S().profiles.default.dataId, owner: S().profiles[owner].dataId };
  const { engine } = await admit();
  addLog([["prof:r", remoteDefault], ["prof:owner", { n: "Owner", c: "blue", i: null }], ["share:r", { o: "owner" }]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error);
  assert.equal(S().profiles.default.dataId, before.default);
  assert.equal(S().profiles[owner].dataId, before.owner);
});

test("bootstrap leaves an incompatible existing shared data mapping pending without changing local identity", async () => {
  reset();
  const owner = S().createProfile({ name: "Owner", color: "blue" });
  const before = clone(S().profiles);
  const { engine } = await admit();
  addLog([["prof:r", remoteDefault], ["prof:owner", { n: "Owner", c: "blue", i: null }], ["share:r", { o: "owner" }]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(S().profiles.default.dataId, before.default.dataId);
  assert.match(engine.useSync.getState().error ?? "", /sharing|data group/i);
  assert.equal(S().profiles[owner].dataId, before[owner].dataId);
  assert.equal(S().profiles.default.name, before.default.name);
  assert.equal(calls.write, 0);
});

test("bootstrap read deadlines keep one unresolved native read and Stop remains available", async () => {
  reset();
  const { engine } = await admit();
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const originalRead = native.read;
  let reads = 0;
  native.read = async () => { reads++; return await new Promise(() => {}); };
  try {
    const first = engine.syncNow();
    await settle();
    assert.equal(reads, 1);
    timers.filter((timer) => timer.ms === 10_000).at(-1).fn();
    await first;
    for (let attempt = 0; attempt < 3; attempt++) {
      const retry = engine.syncNow();
      await settle();
      timers.filter((timer) => timer.ms === 10_000).at(-1).fn();
      await retry;
    }
    assert.equal(reads, 1, "timed-out native IO is coalesced until it actually settles");
    assert.equal(saved().bootstrap.phase, "awaiting-profile");
    await engine.stopSync();
    assert.equal(saved().bootstrap.phase, "stopped");
    assert.equal(calls.write + calls.remove, 0);
  } finally {
    native.read = originalRead;
  }
});

test("a newly authenticated second default invalidates an existing applying binding plan", async () => {
  reset();
  const { engine, state } = await admit();
  state.failCheckpoint = true;
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "applying");
  state.failCheckpoint = false;
  addLog([["prof:another", { n: "Second default", c: "green", i: null, d: true }]], 2);
  await engine.syncNow();
  assert.notEqual(saved().bootstrap.phase, "ready");
  assert.equal(calls.write, 0);
});

test("ready recovery refuses an empty binding proof despite vacuously matching operation receipts", async () => {
  reset();
  const { engine, host } = await admit();
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  const metadata = saved();
  const name = metadata.bootstrap.checkpoint.name;
  const replica = JSON.parse(shell.docs.get(name).slice("sealed:".length));
  replica.plan = { defaultKey: "prof:missing", links: {}, evidence: {}, operations: [], outcomes: {} };
  const text = JSON.stringify(replica);
  const { digest } = await import("./notes.ts");
  shell.docs.set(name, `sealed:${text}`);
  metadata.bootstrap.checkpoint.digest = digest(text);
  shell.docs.set("sync.json", JSON.stringify(metadata));
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(again.useSync.getState().status, "unavailable");
  await again.syncNow();
  assert.equal(calls.write, 0);
});

test("ready recovery refuses a document binding that contradicts its authenticated checkpoint", async () => {
  reset();
  const { engine, host } = await admit();
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  const metadata = saved();
  metadata.profiles.default.syncId = "evil";
  shell.docs.set("sync.json", JSON.stringify(metadata));
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.equal(again.useSync.getState().status, "unavailable");
  await again.syncNow();
  assert.equal(calls.write, 0);
});

test("onboarding completion preserves an opt-out made while its durable phase write is pending", async () => {
  reset();
  const { host, state } = hostFor();
  state.descriptor.route = "onboarding";
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.joinFromPairing(request(), host), { ok: true });
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready");
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync.json";
  const completing = engine.completePairingOnboarding("a".repeat(64));
  await settle();
  assert.equal(shell.heldSaves.queue.length, 1);
  engine.setTypeSynced("history", false);
  shell.heldSaves.on = false;
  shell.heldSaves.queue.shift()();
  assert.equal(await completing, true);
  await settle();
  assert.equal(saved().bootstrap.phase, "onboarding-completed");
  assert.equal(saved().types.history, false);
  assert.equal(engine.useSync.getState().types.history, false);
});

test("ready bootstrap remains recoverable after ordinary retirement of a matched nondefault profile", async () => {
  reset();
  const other = S().createProfile({ name: "Owner", color: "blue" });
  const { engine, host } = await admit();
  addLog([["prof:r", remoteDefault], ["prof:owner", { n: "Owner", c: "blue", i: null }]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready");
  S().deleteProfile(other);
  await settle();
  await engine.syncNow();
  await settle();
  assert.equal(saved().profiles[other], undefined);
  const again = await launch();
  again.startSync(host);
  await settle();
  assert.notEqual(again.useSync.getState().status, "unavailable");
});

test("onboarding completion serializes ordinary profile identity allocation without publishing duplicate identities", async () => {
  reset();
  const { host, state } = hostFor();
  state.descriptor.route = "onboarding";
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.joinFromPairing(request(), host), { ok: true });
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync.json";
  const completing = engine.completePairingOnboarding("a".repeat(64));
  await settle();
  assert.equal(shell.heldSaves.queue.length, 1);
  const other = S().createProfile({ name: "New local profile", color: "green" });
  const cycling = engine.syncNow();
  await settle();
  shell.heldSaves.on = false;
  shell.heldSaves.queue.shift()();
  assert.equal(await completing, true);
  await cycling;
  await settle();
  await engine.syncNow();
  await settle();
  const syncId = saved().profiles[other]?.syncId;
  assert.ok(syncId);
  const identities = new Set([...folder.values()].flatMap((file) => (JSON.parse(file.payload).ops ?? []).filter((op) => op.k.startsWith("prof:") && op.k !== "prof:r").map((op) => op.k)));
  assert.deepEqual([...identities], [`prof:${syncId}`]);
  await engine.syncNow();
  await settle();
  assert.equal(saved().profiles[other].syncId, syncId);
});

test("redesign pairing retains the edit journal and an explicit local claim instead of seeding defaults", async () => {
  reset();
  const { syncRedesign } = await import("./redesignSwitch.ts");
  const beforeLane = syncRedesign.on;
  S().updateSettings({ searchEngine: "duckduckgo" });
  const h = `${(Date.now() + 2000).toString(36).padStart(9, "0")}.0000.local`;
  const edits = JSON.stringify({ v: 1, g: 1, newest: h, entries: { app: { "set:searchEngine": { v: { v: "duckduckgo" }, h, seen: null } } } });
  const gen = JSON.stringify({ v: 1, g: 1, T: null, vv: null });
  shell.docs.set("sync-edits.json", edits);
  shell.docs.set("sync-edits.gen", gen);
  syncRedesign.on = true;
  try {
    const { engine } = await admit();
    assert.equal(shell.docs.get("sync-edits.json"), edits);
    assert.equal(shell.docs.get("sync-edits.gen"), gen);
    addLog([["prof:r", remoteDefault], ["set:searchEngine", { v: "bing" }]]);
    await engine.syncNow();
    assert.equal(saved().bootstrap.phase, "ready", engine.useSync.getState().error);
    assert.equal(S().settings.searchEngine, "duckduckgo");
    assert.equal(shell.docs.get("sync-edits.json"), edits);
    assert.equal(shell.docs.get("sync-edits.gen"), gen);
    assert.equal(calls.write + calls.remove, 0);
  } finally {
    syncRedesign.on = beforeLane;
  }
});

test("a stopped pairing accepts only a fresh transaction, device and installation generation", async () => {
  reset();
  const { engine, host, state } = await admit();
  await engine.stopSync();
  state.descriptor = { ...identity(), generation: 2, stopGeneration: 1 };
  assert.ok("error" in await engine.joinFromPairing({ ...request(), generation: 2, stopGeneration: 1 }, host));
  assert.equal(state.saves, 1);
  state.marker = null;
  state.descriptor = { ...identity(), transaction: "c".repeat(64), deviceId: "fresh-device", account: "fresh-device", generation: 2, stopGeneration: 1 };
  assert.deepEqual(await engine.joinFromPairing({ ...request(), generation: 2, stopGeneration: 1 }, host), { ok: true });
  assert.equal(saved().v, 2);
  assert.equal(saved().deviceId, "fresh-device");
  assert.equal(saved().joinTransaction, "c".repeat(64));
  assert.equal(saved().bootstrap.phase, "awaiting-profile");
  assert.equal(saved().stopGeneration, 1);
});

for (const method of ["turnOnSync", "enterRecoveryPhrase"]) {
  test(`native installation recovery excludes concurrent ${method} admission`, async () => {
    reset();
    const { host } = hostFor();
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    host.recoverInstallation = async () => { await gate; return null; };
    const engine = await launch();
    engine.startSync(host);
    await settle();
    const allocated = ids;
    try {
      const result = await engine[method]("/sync", "words");
      assert.ok("error" in result, "recovery owns the sync initialization admission");
      assert.equal(ids, allocated);
      assert.equal(calls.create, 0);
      assert.equal(shell.docs.has("sync.json"), false);
    } finally {
      release();
      await settle();
    }
  });
}

test("Stop during disabled-state marker recovery supersedes its delayed installation callback", async () => {
  reset();
  const { host, state } = hostFor();
  state.key = true;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  host.recoverInstallation = async () => { await gate; return { ...identity(), phase: "key-saved" }; };
  const engine = await launch();
  engine.startSync(host);
  await settle();
  try {
    await engine.stopSync();
    assert.equal(shell.docs.has("sync.json"), true, "Stop must acknowledge a tombstone while marker recovery is pending");
    assert.equal(saved().v, 2);
    assert.equal(saved().bootstrap.phase, "stopped");
  } finally {
    release();
    await settle();
  }
  assert.equal(saved().enabled, false);
  assert.equal(saved().bootstrap.phase, "stopped");
  assert.equal(state.stopped, 1);
  assert.equal(calls.write + calls.create + calls.forget, 0);
});

test("Stop suppresses a delayed rejected disabled-state marker recovery callback", async () => {
  reset();
  const { host } = hostFor();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  host.recoverInstallation = async () => { await gate; throw new Error("late native recovery failure"); };
  const engine = await launch();
  engine.startSync(host);
  await settle();
  await engine.stopSync();
  release();
  await settle();
  assert.equal(saved().bootstrap.phase, "stopped");
  assert.equal(engine.useSync.getState().status, "off");
});


test("native initialization acknowledgment holds admission and all bootstrap IO", async () => {
  reset();
  const { host, state } = hostFor();
  let release;
  state.initializationGate = new Promise((resolve) => { release = resolve; });
  const engine = await launch();
  engine.startSync(host);
  await settle();
  let result;
  const joining = engine.joinFromPairing(request(), host).then((value) => { result = value; });
  await settle();
  assert.deepEqual(state.initialized, { transaction: identity().transaction, generation: 1 });
  assert.equal(result, undefined);
  await engine.syncNow();
  assert.equal(calls.reads + calls.write, 0);
  release();
  await joining;
  assert.deepEqual(result, { ok: true });
});

test("native ready acknowledgment blocks publication and ordinary profile identity allocation", async () => {
  reset();
  const { engine, state } = await admit();
  let release;
  state.readyGate = new Promise((resolve) => { release = resolve; });
  addLog([["prof:r", remoteDefault]]);
  const cycling = engine.syncNow();
  await settle();
  assert.deepEqual(state.ready, { transaction: identity().transaction, generation: 1 });
  const allocated = ids;
  S().createProfile({ name: "Held local profile", color: "green" });
  await engine.syncNow();
  assert.equal(ids, allocated);
  assert.equal(calls.write, 0);
  release();
  await cycling;
});

test("Stop invalidates immediately and persists native Stop even when v2 document write fails", async () => {
  reset();
  const { engine, state } = await admit();
  shell.heldSaves.fail = true;
  const stopping = engine.stopSync();
  assert.deepEqual(invalidations, ["stop"]);
  await stopping;
  assert.equal(state.stopped, 1);
  assert.equal(calls.write, 0);
});

test("Stop invalidates with a null installation before blocked marker recovery or document save", async () => {
  reset();
  const { host, state } = hostFor();
  host.recoverInstallation = async () => new Promise(() => {});
  const engine = await launch();
  engine.startSync(host);
  await settle();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync.json";
  const stopping = engine.stopSync();
  assert.deepEqual(invalidations, ["stop"]);
  await settle();
  assert.equal(state.stopped, 1);
  shell.heldSaves.on = false;
  shell.heldSaves.queue.shift()();
  await stopping;
});

test("folder selection invalidates before the native panel wait", async () => {
  reset();
  const engine = await launch();
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const previous = native.chooseFolder;
  let release;
  native.chooseFolder = async () => new Promise((resolve) => { release = resolve; });
  try {
    const choosing = engine.chooseSyncFolder();
    assert.deepEqual(invalidations, ["folder"]);
    release(null);
    await choosing;
  } finally {
    native.chooseFolder = previous;
  }
});

test("v1 Stop invalidates before a retiring cycle waits on the provider", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  assert.deepEqual(await engine.turnOnSync("/sync"), { ok: true });
  invalidations.length = 0;
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const previous = native.chainStatus;
  let release;
  native.chainStatus = async () => new Promise((resolve) => { release = resolve; });
  try {
    const stopping = engine.stopSync();
    assert.deepEqual(invalidations, ["stop"]);
    await settle();
    assert.equal(typeof release, "function");
    release("ok");
    await stopping;
  } finally {
    native.chainStatus = previous;
  }
});

test("direct folder command invalidates before loading or changing the saved folder", async () => {
  reset();
  const engine = await launch();
  globalThis.__DEV__ = true;
  try {
    engine.startSync();
    assert.equal(typeof globalThis.acSync?.setSyncFolder, "function");
    globalThis.acSync.setSyncFolder("/selected");
    assert.deepEqual(invalidations, ["folder"]);
  } finally {
    globalThis.__DEV__ = false;
    delete globalThis.acSync;
  }
});

test("failed native ready acknowledgment keeps ordinary cycles and onboarding completion blocked", async () => {
  reset();
  const { host, state } = hostFor();
  state.descriptor.route = "onboarding";
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.joinFromPairing(request(), host), { ok: true });
  state.failReady = true;
  addLog([["prof:r", remoteDefault]]);
  await engine.syncNow();
  assert.equal(saved().bootstrap.phase, "ready");
  S().createProfile({ name: "Pending profile", color: "green" });
  const allocated = ids;
  await engine.syncNow();
  assert.equal(ids, allocated);
  assert.equal(calls.write, 0);
  assert.equal(await engine.completePairingOnboarding(identity().transaction), false);
});

for (const [entry, nativeMethod, argument] of [["turnOnSync", "createSync", null], ["enterRecoveryPhrase", "enterPhrase", { error: "keychain" }]]) {
  test(`${entry} invalidates before the native rekey wait`, async () => {
    reset();
    const engine = await launch();
    engine.startSync();
    const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
    const previous = native[nativeMethod];
    let release;
    native[nativeMethod] = async () => new Promise((resolve) => { release = resolve; });
    try {
      const action = engine[entry]("/sync", "words");
      assert.deepEqual(invalidations, ["rekey"]);
      release(argument);
      await action;
    } finally {
      native[nativeMethod] = previous;
    }
  });
}

test("remote-reset forget invalidates before its native keychain wait", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  assert.deepEqual(await engine.turnOnSync("/sync"), { ok: true });
  invalidations.length = 0;
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const previousStatus = native.chainStatus;
  const previousForget = native.forget;
  let release;
  native.chainStatus = async () => "missing";
  native.forget = async () => new Promise((resolve) => { release = resolve; });
  try {
    const cycling = engine.syncNow();
    await settle();
    assert.equal(typeof release, "function");
    assert.deepEqual(invalidations, ["forget"]);
    release();
    await cycling;
  } finally {
    native.chainStatus = previousStatus;
    native.forget = previousForget;
  }
});

test("v1 Stop durably fences native committed work before the retiring provider cycle", async () => {
  reset();
  const { host, state } = hostFor();
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.turnOnSync("/sync"), { ok: true });
  invalidations.length = 0;
  let releaseStop;
  let releaseProvider;
  let providerEntered = false;
  const stop = host.stopInstallation;
  host.stopInstallation = async (...args) => { await stop(...args); await new Promise((resolve) => { releaseStop = resolve; }); };
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const previous = native.chainStatus;
  native.chainStatus = async () => { providerEntered = true; return await new Promise((resolve) => { releaseProvider = resolve; }); };
  try {
    const stopping = engine.stopSync();
    assert.deepEqual(invalidations, ["stop"]);
    await settle();
    assert.equal(state.stopped, 1);
    assert.equal(providerEntered, false);
    releaseStop();
    await settle();
    assert.equal(providerEntered, true);
    releaseProvider("ok");
    await stopping;
  } finally {
    native.chainStatus = previous;
  }
});

test("null-installation Stop fences a native admission even after empty recovery completed", async () => {
  reset();
  const { host, state } = hostFor();
  const engine = await launch();
  engine.startSync(host);
  await settle();
  await engine.stopSync();
  assert.deepEqual(invalidations, ["stop"]);
  assert.equal(state.stopped, 1);
  assert.equal(calls.write + calls.create + calls.forget, 0);
});

test("onboarding cannot complete while native ready acknowledgment is withheld", async () => {
  reset();
  const { host, state } = hostFor();
  state.descriptor.route = "onboarding";
  let release;
  state.readyGate = new Promise((resolve) => { release = resolve; });
  const engine = await launch();
  engine.startSync(host);
  await settle();
  assert.deepEqual(await engine.joinFromPairing(request(), host), { ok: true });
  addLog([["prof:r", remoteDefault]]);
  const syncing = engine.syncNow();
  await settle();
  try {
    assert.deepEqual(state.ready, { transaction: "a".repeat(64), generation: 1 });
    assert.equal(saved().bootstrap.phase, "ready");
    assert.equal(await engine.completePairingOnboarding("a".repeat(64)), false);
    assert.equal(saved().bootstrap.phase, "ready");
  } finally {
    release();
    await syncing;
  }
  assert.equal(await engine.completePairingOnboarding("a".repeat(64)), true);
  assert.equal(saved().bootstrap.phase, "onboarding-completed");
});
