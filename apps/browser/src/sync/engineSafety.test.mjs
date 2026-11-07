import { startProfileConfirmation } from "../test-native/profileConfirmation.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import { sealedJournal } from "./sealedState.mjs";

const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
let ids = 0;
const fake = {
  locked: false,
  unlockGate: null,
  unlockResult: true,
  failWrite: null,
  readGate: null,
  forgetGate: null,
  phraseGate: null,
  passwordReads: 0,
  seals: 0,
};
const guard = () => {
  if (fake.locked) throw new Error("locked");
};
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    async createSync(folder) {
      const account = this.newDeviceId();
      if (!(await this.createPhrase(account))) return null;
      await this.createChain(folder);
      return account;
    },
    newDeviceId: () => `dev${++ids}`,
    deviceName: () => "Test Mac",
    createPhrase: async () => {
      if (fake.phraseGate) await fake.phraseGate;
      fake.locked = false;
      return true;
    },
    enterPhrase: async () => {
      if (fake.phraseGate) await fake.phraseGate;
      fake.locked = false;
      return { ok: true };
    },
    createChain: async () => {},
    unlock: async () => {
      if (fake.unlockGate) await fake.unlockGate;
      if (fake.unlockResult) fake.locked = false;
      return fake.unlockResult;
    },
    forget: async () => {
      if (fake.forgetGate) await fake.forgetGate;
    },
    chainStatus: async () => (guard(), fake.chain ?? "ok"),
    write: async (_folder, scope, payload) => {
      guard();
      if (fake.failWrite?.(scope, JSON.parse(payload))) throw new Error("offline");
      const id = `f${++ids}`;
      folder.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      guard();
      const gate = fake.readGate?.(scope);
      if (gate) await gate;
      const here = [...folder].filter(([, f]) => f.scope === scope);
      return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    deleteChain: async () => folder.clear(),
    sealLocal: async (text) => (fake.seals++, guard(), `sealed:${text}`),
    openLocal: async (sealed) => {
      guard();
      if (fake.openFails) throw new Error("couldn't open");
      return sealed.startsWith("sealed:") ? sealed.slice(7) : null;
    },
    readPasswords: async () => (fake.passwordReads++, []),
  },
};

const shell = await import("../test-native/index.ts");
const sync = await import("@solara/sync");
const { useBrowser } = await import("../store/browser.ts");
await startProfileConfirmation();
const S = () => useBrowser.getState();
const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = async () => import(`./engine.ts?safety${++launches}`);

function reset() {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  folder.clear();
  shell.docs.clear();
  shell.heldSaves.on = false;
  shell.heldSaves.fail = false;
  shell.heldSaves.only = null;
  shell.heldSaves.queue.length = 0;
  Object.assign(fake, { locked: false, unlockGate: null, unlockResult: true, failWrite: null, readGate: null, forgetGate: null, phraseGate: null, openFails: false, chain: "ok", passwordReads: 0, seals: 0 });
}

const files = () => [...folder.values()].map((f) => ({ scope: f.scope, file: JSON.parse(f.payload), payload: f.payload }));

function assertNoSeqReused() {
  const seen = new Map();
  for (const { scope, file, payload } of files()) {
    if (file.kind !== "log") continue;
    const key = `${scope} ${file.device} ${file.seq}`;
    const ops = JSON.stringify(file.ops);
    assert.equal(seen.get(key) ?? ops, ops, `${key} was published twice with different changes`);
    seen.set(key, ops);
    void payload;
  }
}

async function onAndSynced() {
  const engine = await launch();
  engine.startSync();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  S().addBookmark({ profileId: "default", url: "https://one.example/", title: "One" });
  await engine.syncNow();
  await settle();
  return engine;
}

test("B1: a locked Mac doesn't run cycles, stays locked, and the phrase unlocks the same device", async () => {
  reset();
  const first = await onAndSynced();
  const device = first.useSync.getState().devices.find((d) => d.current)?.id;
  fake.locked = true;
  fake.unlockResult = false;
  const engine = await launch();
  engine.startSync();
  await settle();
  assert.equal(engine.useSync.getState().status, "locked");
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "locked", "a cycle while locked doesn't turn it into stalled");
  assert.ok("ok" in (await engine.enterRecoveryPhrase("/sync", "words")));
  await engine.syncNow();
  await settle();
  const now = engine.useSync.getState().devices.find((d) => d.current)?.id;
  assert.equal(now, device, "the phrase unlocks this device, not a new one");
});

test("B2: a cycle that starts before the saved state is loaded doesn't reuse a seq", async () => {
  reset();
  const first = await onAndSynced();
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await first.syncNow();
  await settle();
  let open;
  fake.unlockGate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  engine.startSync();
  S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
  const early = engine.syncNow();
  await settle();
  open();
  await early;
  await settle();
  await engine.syncNow();
  await settle();
  assertNoSeqReused();
});

test("B3: a seal that keeps failing doesn't retry in a loop", async () => {
  reset();
  const engine = await onAndSynced();
  shell.heldSaves.fail = true;
  const before = fake.seals;
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle(200);
  assert.ok(fake.seals - before < 10, `sealed ${fake.seals - before} times`);
  shell.heldSaves.fail = false;
});

test("B4: a save before the state is loaded keeps the seqs and the sealed state", async () => {
  reset();
  await onAndSynced();
  const json = JSON.parse(shell.docs.get("sync.json"));
  const state = shell.docs.get("sync-state.nns");
  let open;
  fake.unlockGate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  engine.startSync();
  engine.setTypeSynced("history", false);
  await settle();
  assert.deepEqual(JSON.parse(shell.docs.get("sync.json")).seqs, json.seqs, "sync.json keeps its seqs");
  open();
  await settle(5);
  assert.equal(shell.docs.get("sync-state.nns"), state, "the sealed state isn't replaced before it is read");
  await settle();
});

test("B5: a deleted profile's scope is gone for good, and syncing that profile again doesn't reuse its seqs", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  S().addBookmark({ profileId: work, url: "https://work.example/", title: "Work" });
  await engine.syncNow();
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  assert.ok(!sealedJournal(shell.docs)[`p:${syncId}`], "the journal has nothing left for the deleted scope");
  const again = await launch();
  again.startSync();
  await settle();
  assert.equal(again.appScopeRecords()[`prof:${syncId}`]?.v === undefined, false, "the remote profile record is still there to add back");
  const id = again.addRemoteProfile(syncId);
  if (id) {
    useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [id]: true } });
    S().addBookmark({ profileId: id, url: "https://back.example/", title: "Back" });
    await again.syncNow();
    await again.syncNow();
    await settle();
  }
  assertNoSeqReused();
});

test("B7: Sync Now during a cycle still forces the next password read", async () => {
  reset();
  const engine = await onAndSynced();
  const timers = [];
  globalThis.setTimeout = (fn, delay) => (timers.push({ fn, delay }), timers.length);
  await engine.syncNow();
  await settle();
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  fake.readGate = (scope) => (scope.startsWith("p:") ? gate : null);
  const first = engine.syncNow();
  await settle();
  void engine.syncNow();
  fake.readGate = null;
  release();
  await first;
  await settle();
  const reads = fake.passwordReads;
  const next = timers.filter((t) => t.delay === 0).pop();
  timers.length = 0;
  next?.fn();
  await settle();
  globalThis.setTimeout = () => 0;
  assert.ok(next, "the Sync Now that arrived mid-cycle asked for another cycle");
  assert.ok(fake.passwordReads > reads, "and that cycle read the passwords");
});

test("B8: a cycle that fails after pulling keeps the clock it saw, so a later edit isn't dropped", async () => {
  reset();
  const engine = await onAndSynced();
  const future = (Date.now() + 86_400_000).toString(36).padStart(9, "0");
  folder.set("remote1", {
    scope: "app",
    payload: JSON.stringify({ v: 1, kind: "log", device: "far", seq: 1, at: Date.now(), ops: [{ k: "set:searchEngine", h: `${future}.0000.far`, v: { v: "bing" } }] }),
  });
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  fake.failWrite = (scope) => scope.startsWith("p:");
  await engine.syncNow();
  await settle();
  fake.failWrite = null;
  assert.equal(S().settings.searchEngine, "bing");
  S().updateSettings({ searchEngine: "duckduckgo" });
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const published = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:searchEngine" && op.v?.v === "duckduckgo");
  assert.equal(published.length, 1, "the later choice is published");
});

test("B9: stopping while the state is being sealed leaves no sealed state behind", async () => {
  reset();
  const engine = await onAndSynced();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-state";
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  assert.ok(shell.heldSaves.queue.length > 0, "the sealed state's save is in flight");
  await engine.stopSync();
  await settle();
  shell.heldSaves.on = false;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await settle();
  assert.equal(shell.docs.get("sync-state.nns") ?? "", "", "nothing sealed outlives the stop");
});

test("B6: Sync Now while sync is being turned off doesn't publish this Mac again", async () => {
  reset();
  const engine = await onAndSynced();
  let release;
  fake.forgetGate = new Promise((resolve) => (release = resolve));
  const stopping = engine.stopSync();
  await settle();
  await engine.syncNow();
  await settle();
  release();
  await stopping;
  await settle();
  const ops = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "dev:dev1");
  assert.equal(ops.at(-1)?.v ?? null, null, "the last word on this Mac is that it left");
});

test("B10: turning sync on twice at once makes one device", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  let release;
  fake.phraseGate = new Promise((resolve) => (release = resolve));
  const a = engine.turnOnSync("/sync");
  const b = engine.turnOnSync("/sync");
  await settle();
  release();
  await a;
  await b;
  await engine.syncNow();
  await settle();
  const devices = new Set(files().map(({ file }) => file.device));
  assert.equal(devices.size, 1, `devices: ${[...devices]}`);
});

test("B10b: turning on or joining while sync is on keeps the device, and a cycle in flight never writes after its journal is cleared", async () => {
  reset();
  const engine = await onAndSynced();
  shell.heldSaves.on = true;
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  const cycle = engine.syncNow();
  await settle();
  assert.ok("error" in (await engine.turnOnSync("/sync")), "turning on again is refused");
  assert.ok("error" in (await engine.enterRecoveryPhrase("/sync", "words")), "so is joining");
  shell.heldSaves.on = false;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await cycle;
  await settle();
  assert.equal(new Set(files().map(({ file }) => file.device)).size, 1);
});

test("B11: a saved state that parses but isn't scopes doesn't stop sync from starting", async () => {
  reset();
  await onAndSynced();
  shell.docs.set("sync-state.nns", 'sealed:{"journal":{"app":[{"v":1}]},"app":7}');
  const engine = await launch();
  engine.startSync();
  await settle();
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "updated");
  assertNoSeqReused();
});

test("B12: a journal entry from another device or without changes doesn't keep this device's batch out of the journal", async () => {
  reset();
  await onAndSynced();
  const synced = JSON.parse(shell.docs.get("sync.json"));
  shell.docs.set("sync-journal.nns", `sealed:${JSON.stringify({ journal: { app: [{ v: 1, kind: "log", device: "someone", seq: synced.seqs.app + 1, ops: [] }, { v: 1, kind: "log", device: synced.deviceId, seq: 99 }] } })}`);
  const engine = await launch();
  engine.startSync();
  await settle();
  let journaled = null;
  fake.failWrite = (scope, file) => {
    if (scope !== "app" || file.kind !== "log") return false;
    const list = sealedJournal(shell.docs).app ?? [];
    journaled = list.some((f) => f.device === file.device && f.seq === file.seq && f.ops?.length);
    return false;
  };
  S().updateSettings({ searchEngine: "duckduckgo" });
  await engine.syncNow();
  await settle();
  assert.equal(journaled, true, "the batch is in the journal before it goes out");
});

const rawTransport = {
  write: async (scope, payload) => {
    const id = `f${++ids}`;
    folder.set(id, { scope, payload });
    return id;
  },
  read: async (scope, known) => {
    const here = [...folder].filter(([, f]) => f.scope === scope);
    return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
  },
  remove: async (_scope, list) => list.forEach((id) => folder.delete(id)),
};

function otherMac(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("otherMac");
  const adapter = {
    prefix: "bm:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "otherMac" }) };
}

const titles = (profileId) => Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url" && S().bookmarks.roots[profileId] && n.title).map((n) => n.title);

test("B13: a profile deleted and added back gets this Mac's own bookmarks back, and compacting doesn't take them from the other Macs", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  S().addBookmark({ profileId: work, url: "https://work.example/", title: "Work" });
  await engine.syncNow();
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  other.store.set("bm:fromB", { k: "u", p: "bar", t: "From B", u: "https://b.example/", a: 1, pos: "m" });
  await other.sync();
  await engine.syncNow();
  await settle();
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const back = engine.addRemoteProfile(syncId);
  assert.ok(back, "the profile can be added back");
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [back]: true } });
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const here = Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title);
  assert.ok(here.includes("Work"), `this Mac gets its own bookmark back: ${here}`);
  assert.ok(here.includes("From B"), "and the other Mac's");
  for (let i = 0; i < 42; i++) {
    S().addBookmark({ profileId: back, url: `https://more${i}.example/`, title: `More ${i}` });
    await engine.syncNow();
  }
  await settle();
  assert.ok(files().some(({ scope, file }) => scope === `p:${syncId}` && file.kind === "snapshot"), "this Mac compacted the scope");
  await other.sync();
  const there = [...other.store.values()].map((v) => v.t);
  assert.ok(there.includes("Work"), "the other Mac still has this Mac's bookmark after this Mac compacts");
  assertNoSeqReused();
});

test("B14: a load that fails at startup or after the phrase leaves the phrase able to recover, and two phrase entries at once load once", async () => {
  reset();
  await onAndSynced();
  const device = JSON.parse(shell.docs.get("sync.json")).deviceId;
  fake.openFails = true;
  const engine = await launch();
  engine.startSync();
  await settle();
  assert.equal(engine.useSync.getState().status, "locked", "a state that can't be opened asks for the phrase");
  await engine.enterRecoveryPhrase("/sync", "words").catch(() => null);
  await settle();
  assert.equal(engine.useSync.getState().status, "locked", "and still does after a phrase that couldn't load it");
  fake.openFails = false;
  let release;
  fake.phraseGate = new Promise((resolve) => (release = resolve));
  const first = engine.enterRecoveryPhrase("/sync", "words");
  const second = engine.enterRecoveryPhrase("/sync", "words");
  await settle();
  release();
  const results = [await first, await second];
  fake.phraseGate = null;
  assert.deepEqual(results, [{ ok: true }, { ok: true }], "both entries get the one unlock's answer");
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "updated");
  assert.equal(JSON.parse(shell.docs.get("sync.json")).deviceId, device, "the same device recovers");
  assertNoSeqReused();
});

test("B15: Sync Now whose cycle goes offline still forces the password read when the folder is back", async () => {
  reset();
  const engine = await onAndSynced();
  const timers = [];
  globalThis.setTimeout = (fn, delay) => (timers.push({ fn, delay }), timers.length);
  fake.chain = "unavailable";
  await engine.syncNow();
  await settle();
  fake.chain = "ok";
  const reads = fake.passwordReads;
  const next = timers.filter((t) => t.delay === 15_000).pop();
  timers.length = 0;
  next?.fn();
  await settle();
  globalThis.setTimeout = () => 0;
  assert.ok(next, "the offline cycle scheduled the next one");
  assert.ok(fake.passwordReads > reads, "which reads the passwords Sync Now asked for");
});

test("B16: a seal from before sync was turned off and on again doesn't prune the new device's journal", async () => {
  reset();
  const engine = await onAndSynced();
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-state";
  await engine.syncNow();
  await settle();
  const oldSeal = shell.heldSaves.queue.shift();
  assert.ok(oldSeal, "the old device's state save is in flight");
  shell.heldSaves.queue.length = 0;
  await engine.stopSync();
  await settle();
  shell.heldSaves.queue.length = 0;
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
  await engine.syncNow();
  await settle();
  const fresh = JSON.parse(shell.docs.get("sync.json")).deviceId;
  oldSeal();
  await settle();
  const kept = sealedJournal(shell.docs).app ?? [];
  assert.ok(kept.some((f) => f.device === fresh), "the new device's batches stay journaled until its own state lands");
});

test("B17: a retired scope that a linked profile uses again, after an older build ran, is loaded like any other", async () => {
  reset();
  const engine = await onAndSynced();
  const saved = JSON.parse(shell.docs.get("sync.json"));
  const [profileId, link] = Object.entries(saved.profiles)[0];
  const scope = `p:${link.syncId}`;
  shell.docs.set("sync.json", JSON.stringify({ ...saved, retired: { [scope]: 1 } }));
  void profileId;
  const again = await launch();
  again.startSync();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://after.example/", title: "After" });
  await again.syncNow();
  await settle();
  assertNoSeqReused();
  assert.equal(JSON.parse(shell.docs.get("sync.json")).retired?.[scope], undefined, "the live scope isn't retired any more");
});

test("B18: stopping while locked clears the sealed state it can no longer open", async () => {
  reset();
  await onAndSynced();
  fake.locked = true;
  fake.unlockResult = false;
  const engine = await launch();
  engine.startSync();
  await settle();
  assert.equal(engine.useSync.getState().status, "locked");
  await engine.stopSync();
  await settle();
  assert.equal(shell.docs.get("sync-state.nns") ?? "", "");
});

const stateOf = () => {
  const sealed = shell.docs.get("sync-state.nns");
  return sealed ? JSON.parse(sealed.slice(7)) : {};
};

test("B19: a scope an older build re-added starts after the retired floor, not after the older build's seqs", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  for (let i = 0; i < 4; i++) {
    S().addBookmark({ profileId: work, url: `https://w${i}.example/`, title: `W${i}` });
    await engine.syncNow();
  }
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  const scope = `p:${syncId}`;
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const saved = JSON.parse(shell.docs.get("sync.json"));
  assert.ok(saved.retired?.[scope] >= 3);
  const again = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [again]: true } });
  shell.docs.set("sync.json", JSON.stringify({ ...saved, profiles: { ...saved.profiles, [again]: { syncId, enabled: true } }, seqs: { ...saved.seqs, [scope]: 1 } }));
  shell.docs.set("sync-state.nns", `sealed:${JSON.stringify({ ...stateOf(), [scope]: { ...sync.emptyScope(), seq: 1, joined: true } })}`);
  const next = await launch();
  next.startSync();
  await settle();
  S().addBookmark({ profileId: again, url: "https://new.example/", title: "New" });
  await next.syncNow();
  await settle();
  assertNoSeqReused();
});

async function staleLoad(viaPhrase, failLate) {
  reset();
  await onAndSynced();
  let open;
  const gate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  let phrase = null;
  if (viaPhrase) {
    fake.unlockResult = false;
    engine.startSync();
    await settle();
    fake.unlockResult = true;
    fake.phraseGate = gate;
    phrase = engine.enterRecoveryPhrase("/sync", "words");
  } else {
    fake.unlockGate = gate;
    engine.startSync();
  }
  await settle();
  globalThis.setTimeout = realSetTimeout;
  await engine.stopSync();
  globalThis.setTimeout = () => 0;
  await settle();
  fake.phraseGate = null;
  fake.unlockGate = null;
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await settle();
  S().addBookmark({ profileId: "default", url: "https://a.example/", title: "a" });
  await engine.syncNow();
  await settle();
  let releaseRead;
  const readHeld = new Promise((resolve) => (releaseRead = resolve));
  fake.readGate = (scope) => (scope.startsWith("p:") ? readHeld : null);
  S().addBookmark({ profileId: "default", url: "https://b.example/", title: "b" });
  const cycle = engine.syncNow();
  await settle();
  if (failLate === "noKey") fake.unlockResult = false;
  if (failLate === "throws") fake.openFails = true;
  open();
  await phrase;
  await settle();
  fake.openFails = false;
  fake.unlockResult = true;
  S().addBookmark({ profileId: "default", url: "https://c.example/", title: "c" });
  fake.readGate = null;
  releaseRead();
  await cycle;
  await settle();
  S().addBookmark({ profileId: "default", url: "https://d.example/", title: "d" });
  await engine.syncNow();
  await settle();
  assertNoSeqReused();
  assert.equal(engine.useSync.getState().status, "updated", "the new device keeps syncing");
}

test("B20: a startup load that finishes after sync was stopped and turned on again is dropped", () => staleLoad(false, null));
test("B20b: so is a phrase unlock's load", () => staleLoad(true, null));
async function lateFailure(kind) {
  reset();
  await onAndSynced();
  let open;
  fake.unlockGate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  engine.startSync();
  await settle();
  globalThis.setTimeout = realSetTimeout;
  await engine.stopSync();
  globalThis.setTimeout = () => 0;
  await settle();
  fake.unlockGate = null;
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await settle();
  S().addBookmark({ profileId: "default", url: "https://a.example/", title: "a" });
  await engine.syncNow();
  await settle();
  if (kind === "noKey") fake.unlockResult = false;
  else fake.openFails = true;
  open();
  await settle();
  fake.openFails = false;
  fake.unlockResult = true;
  S().addBookmark({ profileId: "default", url: "https://b.example/", title: "b" });
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "updated", "the new device keeps syncing");
}

test("B21: a stale unlock that finds no key doesn't lock the new device", () => lateFailure("noKey"));
test("B21b: nor does a stale load that fails", () => lateFailure("throws"));

test("B22: a saved state whose records or batches hold entries of another shape is rebuilt, not trusted", async () => {
  reset();
  await onAndSynced();
  const state = stateOf();
  state.app.records["junk"] = null;
  shell.docs.set("sync-state.nns", `sealed:${JSON.stringify(state)}`);
  shell.docs.set("sync-journal.nns", `sealed:${JSON.stringify({ journal: { app: [{ v: 1, kind: "log", device: JSON.parse(shell.docs.get("sync.json")).deviceId, seq: 50, ops: [null] }] } })}`);
  const engine = await launch();
  engine.startSync();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://after.example/", title: "After" });
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "updated");
  assertNoSeqReused();
});

test("B23: batches an older build journaled for a re-added scope below the retired floor go out again under new seqs", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  for (let i = 0; i < 3; i++) {
    S().addBookmark({ profileId: work, url: `https://w${i}.example/`, title: `W${i}` });
    await engine.syncNow();
  }
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  const scope = `p:${syncId}`;
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const saved = JSON.parse(shell.docs.get("sync.json"));
  const floor = saved.retired[scope];
  const again = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [again]: true } });
  const older = { v: 1, kind: "log", device: saved.deviceId, seq: 1, at: Date.now(), ops: [{ k: "bm:older", h: "0zzzzzzzz.0000.older", v: { k: "u", p: "bar", t: "Older", u: "https://older.example/", a: 1, pos: "m" } }] };
  shell.docs.set("sync.json", JSON.stringify({ ...saved, profiles: { ...saved.profiles, [again]: { syncId, enabled: true } }, seqs: { ...saved.seqs, [scope]: 0 } }));
  shell.docs.set("sync-journal.nns", `sealed:${JSON.stringify({ journal: { [scope]: [older] } })}`);
  const next = await launch();
  next.startSync();
  await settle();
  await next.syncNow();
  await settle();
  const out = files().filter((f) => f.scope === scope && f.file.kind === "log" && f.file.ops.some((op) => op.k === "bm:older" && op.h === "0zzzzzzzz.0000.older"));
  assert.ok(out.length && out.every((f) => f.file.seq > floor), `the older batch goes out above the floor (${floor}): ${out.map((f) => f.file.seq)}`);
  assertNoSeqReused();
});

test("B24: a phrase unlock overtaken by stopping and turning sync on again says so instead of reporting success", async () => {
  reset();
  await onAndSynced();
  fake.unlockResult = false;
  const engine = await launch();
  engine.startSync();
  await settle();
  fake.unlockResult = true;
  let open;
  fake.phraseGate = new Promise((resolve) => (open = resolve));
  const phrase = engine.enterRecoveryPhrase("/sync", "words");
  await settle();
  await engine.stopSync();
  await settle();
  fake.phraseGate = null;
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  open();
  assert.deepEqual(await phrase, { error: "interrupted" });
});

test("B29: stopping while the saved state is still loading waits for it and retires this Mac", async () => {
  reset();
  await onAndSynced();
  const device = JSON.parse(shell.docs.get("sync.json")).deviceId;
  let open;
  fake.unlockGate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  engine.startSync();
  await settle();
  const stopping = engine.stopSync();
  await settle();
  fake.unlockGate = null;
  open();
  await stopping;
  await settle();
  const ops = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === `dev:${device}`);
  assert.equal(ops.at(-1)?.v ?? null, null, "the other Macs hear this Mac left");
});

test("bookmark records live in the scope of the profile's sync link, never one named by its local profile id", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  S().addBookmark({ profileId: work, url: "https://scoped.example/", title: "Scoped" });
  await engine.syncNow();
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  assert.notEqual(syncId, work, "the fixture needs a sync link that differs from the profile id");
  const carrying = (scope) => files().filter((f) => f.scope === scope && (f.file.ops ?? []).some((op) => op.k.startsWith("bm:") && op.v?.u === "https://scoped.example/"));
  assert.ok(carrying(`p:${syncId}`).length > 0, "the bookmark is published under p:<syncId>");
  assert.deepEqual(files().filter((f) => f.scope === `p:${work}`), [], "nothing is written under p:<profileId>");
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const back = engine.addRemoteProfile(syncId);
  assert.ok(back && back !== work, "added back under a new local id");
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [back]: true } });
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  S().addBookmark({ profileId: back, url: "https://again.example/", title: "Again" });
  await engine.syncNow();
  await settle();
  assert.ok(files().some((f) => f.scope === `p:${syncId}` && (f.file.ops ?? []).some((op) => op.v?.u === "https://again.example/")), "the new local id publishes into the same link's scope");
  assert.deepEqual(files().filter((f) => f.scope === `p:${back}`), []);
});
