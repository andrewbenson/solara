import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = true;

const folder = new Map();
let ids = 0;
let unlocks = true;
let fullStateFails = false;
const seals = [];
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
    createPhrase: async () => true,
    createChain: async () => {},
    unlock: async () => unlocks,
    forget: async () => {},
    chainStatus: async () => "ok",
    write: async (_folder, scope, payload) => {
      const id = `f${folder.size + 1}`;
      folder.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      const here = [...folder].filter(([, f]) => f.scope === scope);
      const files = here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload }));
      return { files, pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    sealLocal: async (text, kind, part) => {
      if (fullStateFails && kind === undefined && part === undefined && text.includes('"~n"')) throw new Error("disk full");
      seals.push(part ?? null);
      return `sealed:${part ?? ""}|${text}`;
    },
    openLocal: async (sealed, _kind, part) => (sealed.startsWith(`sealed:${part ?? ""}|`) ? sealed.slice(`sealed:${part ?? ""}|`.length) : null),
    readPasswords: async () => null,
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const d = await import("./stateDeltas.ts");
const S = () => useBrowser.getState();
const settle = async () => {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = async () => {
  const engine = await import(`./engine.ts?files${++launches}`);
  engine.startSync();
  await settle();
  return engine;
};

const opened = (name) => {
  const text = shell.docs.get(name);
  return JSON.parse(text.slice(text.indexOf("|") + 1));
};
const deltas = () => [...shell.docs.keys()].filter((name) => name.startsWith(d.DELTA_PREFIX)).sort((a, b) => d.parseDeltaName(a).g - d.parseDeltaName(b).g);
const batches = () => [...shell.docs.keys()].filter((name) => name.startsWith(d.BATCH_PREFIX));
const full = () => opened("sync-state.nns");
const replayed = () => {
  const state = full();
  for (const name of deltas()) {
    const delta = d.parseDeltaName(name);
    if (delta.n === state["~n"] && delta.epoch === state["~epoch"]) assert.ok(d.applyDelta(state, opened(name)));
  }
  return Object.fromEntries(Object.entries(state).filter(([key]) => !key.startsWith("~")));
};
const bookmarkTitles = (state) => Object.values(state).flatMap((scope) => Object.values(scope.records)).map((r) => r.v?.t).filter(Boolean).sort();
const rebuilding = (state) => Object.entries(state).filter(([, scope]) => scope.rebuild).map(([name]) => name).sort();

async function onAndSynced() {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  shell.docs.clear();
  folder.clear();
  unlocks = true;
  const engine = await launch();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  S().addBookmark({ profileId: "default", url: "https://one.example/", title: "One" });
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  return engine;
}

let profiles = 0;
async function compact(engine) {
  const n = full()["~n"];
  const id = S().createProfile({ name: `Work ${++profiles}` });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [id]: true } });
  engine.setProfileSynced(id, true);
  await engine.syncNow();
  await settle();
  assert.ok(full()["~n"] > n, "a new scope compacts");
  return id;
}

async function edit(engine, title) {
  S().addBookmark({ profileId: "default", url: `https://${title.toLowerCase()}.example/`, title });
  await engine.syncNow();
  await settle();
}

test("an edit writes a delta of only what changed, and a relaunch replays it", async () => {
  const engine = await onAndSynced();
  const before = shell.docs.get("sync-state.nns");
  const n = full()["~n"];
  await edit(engine, "Two");
  assert.equal(shell.docs.get("sync-state.nns"), before, "the full state isn't rewritten");
  assert.ok(deltas().length >= 1, "a delta is written");
  const last = opened(deltas().at(-1));
  const records = Object.values(last).flatMap((scope) => Object.keys(scope.records));
  assert.ok(records.length <= 3, `only the changed records are written (${records})`);
  assert.deepEqual(bookmarkTitles(replayed()), ["One", "Two"]);
  assert.ok(seals.includes(d.deltaPart(d.parseDeltaName(deltas().at(-1)))), "the delta is sealed for its own name");
  await launch();
  assert.equal(full()["~n"], n, "a healthy relaunch doesn't compact");
  assert.deepEqual(bookmarkTitles(replayed()), ["One", "Two"]);
  assert.deepEqual(rebuilding(replayed()), []);
});

test("a crash after a delta lands and before the next loads that delta, with nothing rebuilt", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Crash two");
  const disk = new Map(shell.docs);
  const published = new Map(folder);
  S().addBookmark({ profileId: "default", url: "https://crash-three.example/", title: "Crash three" });
  shell.docs.clear();
  for (const [name, text] of disk) shell.docs.set(name, text);
  folder.clear();
  for (const [id, file] of published) folder.set(id, file);
  assert.ok(deltas().length >= 1, "the crash keeps a landed delta");
  const again = await launch();
  assert.deepEqual(rebuilding(replayed()), []);
  await again.syncNow();
  await settle();
  assert.deepEqual(rebuilding(replayed()), []);
  assert.ok(bookmarkTitles(replayed()).includes("Crash two"));
  assert.ok(bookmarkTitles(replayed()).includes("Crash three"));
});

test("a delta that goes missing is a gap: every scope rebuilds and the next save compacts", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Two");
  await edit(engine, "Three");
  const n = full()["~n"];
  assert.ok(deltas().length >= 2);
  shell.docs.delete(deltas()[0]);
  await launch();
  assert.ok(full()["~n"] > n, "compacted at once");
  assert.deepEqual(rebuilding(replayed()), Object.keys(replayed()).sort(), "every scope rebuilds");
});

test("a delta under another delta's name doesn't open, and is a gap", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Two");
  await edit(engine, "Three");
  const [first, second] = deltas();
  const text = shell.docs.get(second);
  shell.docs.set(second, shell.docs.get(first));
  shell.docs.set(first, text);
  await launch();
  assert.deepEqual(rebuilding(replayed()), Object.keys(replayed()).sort());
});

test("a full state from an older build (no ~n) ignores and deletes every delta", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Downgraded");
  assert.ok(deltas().length);
  const older = Object.fromEntries(Object.entries(full()).filter(([key]) => !key.startsWith("~")));
  shell.docs.set("sync-state.nns", `sealed:|${JSON.stringify(older)}`);
  const again = await launch();
  assert.deepEqual(deltas(), [], "every delta is deleted, none replayed");
  await again.syncNow();
  await settle();
  assert.equal(typeof full()["~n"], "number", "the next save is a compaction");
});

test("a lost compaction (power cut after its deltas landed, before its rename) rebuilds instead of rolling back silently", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Two");
  const previous = shell.docs.get("sync-state.nns");
  const previousN = full()["~n"];
  await compact(engine);
  await edit(engine, "Four");
  assert.ok(deltas().some((name) => d.parseDeltaName(name).n > previousN), "the new generation has deltas");
  shell.docs.set("sync-state.nns", previous);
  await launch();
  assert.deepEqual(rebuilding(replayed()), Object.keys(replayed()).sort(), "every scope rebuilds");
});

test("compaction keeps the previous generation's deltas and removes older ones", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Two");
  const n = full()["~n"];
  const kept = deltas();
  assert.ok(kept.length);
  await compact(engine);
  for (const name of kept) assert.ok(shell.docs.has(name), `${name} is kept while its generation is the previous one`);
  await edit(engine, "Three");
  await compact(engine);
  for (const name of kept) assert.ok(!shell.docs.has(name), `${name} goes two compactions later`);
  await launch();
  assert.deepEqual(rebuilding(replayed()), []);
});

test("Stop with a delta in flight: the delta lands after the clear and is never replayed", async () => {
  const engine = await onAndSynced();
  shell.heldSaves.on = true;
  shell.heldSaves.only = d.DELTA_PREFIX;
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  assert.equal(shell.heldSaves.queue.length, 1, "the delta's save is in flight");
  const land = shell.heldSaves.queue.shift();
  shell.heldSaves.on = false;
  shell.heldSaves.only = null;
  await engine.stopSync();
  await settle();
  land();
  await settle();
  assert.equal(shell.docs.get("sync-state.nns") ?? "", "");
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  await settle();
  await launch();
  assert.ok(deltas().every((name) => d.parseDeltaName(name).device === JSON.parse(shell.docs.get("sync.json")).deviceId), "the old device's delta is gone");
  assert.deepEqual(rebuilding(replayed()), []);
});

test("a batch file from another device, or one that doesn't open, is deleted at load", async () => {
  await onAndSynced();
  const scope = "app";
  const foreign = { v: 1, kind: "log", device: "someone", seq: 7, at: 1, ops: [] };
  shell.docs.set(d.batchName(scope, 7), `sealed:${d.batchPart(scope, 7)}|${JSON.stringify({ journal: { [scope]: [foreign] } })}`);
  shell.docs.set(d.batchName(scope, 8), `sealed:${d.batchPart(scope, 9)}|${JSON.stringify({ journal: { [scope]: [] } })}`);
  await launch();
  assert.deepEqual(batches(), []);
});

test("each journal batch is its own file, sealed for its scope and seq, and goes once the state has it", async () => {
  const engine = await onAndSynced();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-state";
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  const names = batches();
  assert.ok(names.length >= 1, "the batch is on disk before the state lands");
  for (const name of names) {
    const { scope, seq } = d.parseBatchName(name);
    assert.ok(seals.includes(d.batchPart(scope, seq)));
    assert.equal(opened(name).journal[scope][0].seq, seq);
  }
  shell.heldSaves.on = false;
  shell.heldSaves.only = null;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await settle();
  await engine.syncNow();
  await settle();
  assert.deepEqual(batches(), []);
});

test("a locked Mac writes neither a delta nor a full state", async () => {
  await onAndSynced();
  const before = new Map(shell.docs);
  unlocks = false;
  await launch();
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await settle();
  for (const [name, text] of shell.docs) if (name.startsWith("sync-state")) assert.equal(text, before.get(name));
  assert.deepEqual(deltas(), [...before.keys()].filter((name) => name.startsWith(d.DELTA_PREFIX)).sort((a, b) => d.parseDeltaName(a).g - d.parseDeltaName(b).g));
});

test("adding a scope compacts instead of writing a delta", async () => {
  const engine = await onAndSynced();
  const id = await compact(engine);
  assert.ok(`p:${engine.useSync.getState().profiles[id].syncId}` in full(), "the full state has the new scope");
});

test("a power cut that keeps a compaction's removals but loses its full state still finds the previous state's deltas", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Before cut");
  const previous = shell.docs.get("sync-state.nns");
  const kept = deltas();
  const added = await compact(engine);
  assert.ok(kept.every((name) => shell.docs.has(name)));
  shell.docs.set("sync-state.nns", previous);
  for (const name of deltas()) if (!kept.includes(name)) shell.docs.delete(name);
  const again = await launch();
  assert.deepEqual(rebuilding(replayed()), [`p:${again.useSync.getState().profiles[added].syncId}`], "the previous state and its deltas load whole; only the scope it never had rebuilds");
  await again.syncNow();
  await settle();
  assert.ok(bookmarkTitles(replayed()).includes("Before cut"));
});

test("after a gap and two more cycles, a reload loses nothing more and finds no new gap", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Gap one");
  await edit(engine, "Gap two");
  shell.docs.delete(deltas()[0]);
  const again = await launch();
  await edit(again, "After gap one");
  await edit(again, "After gap two");
  assert.ok(deltas().length >= 2);
  const before = replayed();
  await launch();
  const after = replayed();
  assert.deepEqual(bookmarkTitles(after), bookmarkTitles(before));
  for (const scope of Object.keys(before)) assert.equal(after[scope].seq, before[scope].seq);
  for (const title of ["After gap one", "After gap two"]) assert.ok(bookmarkTitles(after).includes(title));
});

test("a crash in the middle of a compaction's removals leaves files that load deletes without replaying", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Old one");
  const old = new Map(deltas().map((name) => [name, shell.docs.get(name)]));
  await compact(engine);
  await edit(engine, "Middle");
  await compact(engine);
  assert.ok([...old.keys()].every((name) => !shell.docs.has(name)), "two compactions later they're removed");
  const before = replayed();
  for (const [name, text] of old) {
    shell.docs.set(name, text);
    break;
  }
  await launch();
  assert.deepEqual(replayed(), before);
  assert.deepEqual(rebuilding(replayed()), []);
  assert.ok([...old.keys()].every((name) => !shell.docs.has(name)), "and load deletes the leftover");
});

test("a name under the delta prefix that doesn't parse is a gap", async () => {
  const engine = await onAndSynced();
  await edit(engine, "Unparsed");
  shell.docs.set(`${d.DELTA_PREFIX}from-a-newer-build.nns`, "sealed:|{}");
  await launch();
  assert.deepEqual(rebuilding(replayed()), Object.keys(replayed()).sort());
});

test("a held batch resent after a relaunch replaces its records instead of writing into the saved ones", async () => {
  const engine = await onAndSynced();
  const state = replayed();
  const name = `p:${engine.useSync.getState().profiles.default.syncId}`;
  const scope = state[name];
  const device = JSON.parse(shell.docs.get("sync.json")).deviceId;
  const h = `${Date.now().toString(36).padStart(9, "0")}.0000.${device}`;
  const value = { k: "u", p: "bar", t: "Held", u: "https://held.example/", a: 1, pos: "z" };
  scope.outbox = [{ k: "bm:held", h, v: value }];
  scope.records["bm:held"] = { h, v: value, o: [device, scope.seq + 1] };
  shell.docs.set("sync-state.nns", `sealed:|${JSON.stringify(state)}`);
  const again = await launch();
  const freeze = (item) => {
    if (item && typeof item === "object" && !Object.isFrozen(item)) {
      Object.freeze(item);
      for (const inner of Object.values(item)) freeze(inner);
    }
  };
  for (const loaded of Object.values(globalThis.acSync.doc().scopes)) for (const record of Object.values(loaded.records)) freeze(record);
  await again.syncNow();
  await settle();
  assert.equal(again.useSync.getState().status, "updated", "nothing was written into a saved record");
  const sent = [...folder.values()].map((f) => JSON.parse(f.payload)).find((f) => f.ops?.some((op) => op.k === "bm:held"));
  assert.ok(sent, "the held batch went out");
  assert.deepEqual(replayed()[name].records["bm:held"].o, [sent.device, sent.seq], "the saved record names the batch that carried it");
});

test("a compaction that fails still uses up its generation, so a late copy of it can never pass for the next one", async () => {
  const engine = await onAndSynced();
  const n = full()["~n"];
  fullStateFails = true;
  const id = S().createProfile({ name: `Work ${++profiles}` });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [id]: true } });
  engine.setProfileSynced(id, true);
  await engine.syncNow();
  await settle();
  fullStateFails = false;
  assert.equal(full()["~n"], n, "the failed compaction didn't land");
  await edit(engine, "After the failure");
  assert.equal(full()["~n"], n + 2);
});
