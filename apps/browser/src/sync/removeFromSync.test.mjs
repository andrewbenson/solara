import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { registerHooks, stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
const { startProfileConfirmation } = await import('../test-native/profileConfirmation.mjs');

const shippedBlobs = { engine: "d0c180436941e9246ee5a6fbae091d4aabf484ea", adapters: "bcf6b449c7dd3659145c2e632671bf09ba4ec5ce" };
const shippedSource = (blob) =>
  execFileSync("git", ["cat-file", "blob", blob], {
    cwd: fileURLToPath(new URL(".", import.meta.url)),
    encoding: "utf8",
    maxBuffer: 1 << 24,
  });
const shippedEngine = new URL("./engine-shipped.ts", import.meta.url);
const shippedAdapters = new URL("./adapters-shipped.ts", import.meta.url);
const shippedSources = new Map([
  [shippedEngine.href, shippedSource(shippedBlobs.engine)],
  [shippedAdapters.href, shippedSource(shippedBlobs.adapters)],
]);
const engineLocation = new URL("./engine.ts", import.meta.url).href;
const shippedFixture = (url) => [...shippedSources.keys()].find((href) => url?.startsWith(href));
registerHooks({
  resolve(specifier, context, next) {
    if (shippedFixture(specifier)) return { url: specifier, format: "module", shortCircuit: true };
    const parent = shippedFixture(context.parentURL);
    if (parent === shippedEngine.href && (specifier === "./adapters" || specifier === "./adapters.ts")) {
      return { url: `${shippedAdapters.href}?${new URL(context.parentURL).search.slice(1)}`, format: "module", shortCircuit: true };
    }
    if (parent) return next(specifier, { ...context, parentURL: engineLocation });
    return next(specifier, context);
  },
  load(url, context, next) {
    const fixture = shippedFixture(url);
    if (fixture) return { format: "module", source: stripTypeScriptTypes(shippedSources.get(fixture)), shortCircuit: true };
    return next(url, context);
  },
});

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
let ids = 0;
let pendingFiles = [];
let heldRead = null;
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    async createSync(folder) {
      const account = this.newDeviceId();
      if (!(await this.createPhrase(account))) return null;
      await this.createChain(folder);
      return account;
    },
    newDeviceId: () => `id${1_000_000 - ++ids}`,
    deviceName: () => "Test Mac",
    createPhrase: async () => true,
    createChain: async () => {},
    enterPhrase: async () => ({ ok: true }),
    unlock: async () => true,
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
      if (scope === "app" && heldRead) await heldRead();
      return { files, pending: scope === "app" ? pendingFiles : [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (sealed) => (sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async () => null,
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
await startProfileConfirmation();
const S = () => useBrowser.getState();

class Mac {
  constructor(name) {
    this.name = name;
    S().hydrate({});
    useBrowser.setState({ bookmarksReady: { default: true } });
    this.browser = S();
    this.docs = new Map();
  }
  async with(fn) {
    useBrowser.setState(this.browser, true);
    shell.docs.clear();
    for (const [k, v] of this.docs) shell.docs.set(k, v);
    try {
      return await fn();
    } finally {
      this.browser = S();
      this.docs = new Map(shell.docs);
    }
  }
}

let launches = 0;
const launch = (shipped = false) => import(`${shipped ? shippedEngine.href : "./engine.ts"}?rfs${++launches}`);

const ops = (key) =>
  [...folder.values()]
    .map((f) => JSON.parse(f.payload))
    .flatMap((f) => f.ops ?? Object.entries(f.records ?? {}).map(([k, r]) => ({ k, v: r.v })))
    .filter((op) => op.k === key);
const tombstoned = (key) => ops(key).some((op) => op.v === null);
const offered = (engine) => engine.useSync.getState().remoteProfiles.map((p) => p.name).sort();
const cycle = async (mac, engine, times = 2) => mac.with(async () => {
  for (let i = 0; i < times; i++) await engine.syncNow();
});

async function twoMacsWithWork({ shareWith, shippedB = false } = {}) {
  folder.clear();
  const a = new Mac("A");
  const b = new Mac("B");
  const engineA = await launch();
  const engineB = await launch(shippedB);
  const workA = await a.with(async () => {
    const work = S().createProfile({ name: "Work", ...(shareWith ? { shareWith } : {}) });
    engineA.startSync();
    assert.ok("ok" in (await engineA.turnOnSync("/sync")));
    await engineA.syncNow();
    await engineA.syncNow();
    return work;
  });
  const syncId = await a.with(() => engineA.useSync.getState().profiles[workA].syncId);
  const workB = await b.with(async () => {
    engineB.startSync();
    assert.ok("ok" in (await engineB.enterRecoveryPhrase("/sync", "words")));
    await engineB.syncNow();
    await engineB.syncNow();
    const id = engineB.addRemoteProfile(syncId);
    assert.ok(id, "B adds Work from sync");
    await engineB.syncNow();
    await engineB.syncNow();
    return id;
  });
  return { a, b, engineA, engineB, workA, workB, syncId };
}

test("a profile deleted on every Mac and removed from sync is offered by no Mac, nor one that joins later", async () => {
  const { a, b, engineA, engineB, workA, workB, syncId } = await twoMacsWithWork();
  await a.with(() => S().deleteProfile(workA));
  await b.with(() => S().deleteProfile(workB));
  await cycle(a, engineA);
  await cycle(b, engineB);
  await cycle(a, engineA);
  assert.deepEqual(await a.with(() => offered(engineA)), ["Work"], "before: A still offers the deleted Work");
  assert.deepEqual(await b.with(() => offered(engineB)), ["Work"], "before: B still offers the deleted Work");

  assert.equal(await a.with(() => engineA.removeRemoteProfile(syncId)), true);
  assert.deepEqual(await a.with(() => offered(engineA)), [], "the row goes away on the click");
  await cycle(a, engineA);
  assert.ok(tombstoned(`prof:${syncId}`), "A tombstones prof:");
  await cycle(b, engineB);
  assert.deepEqual(await b.with(() => offered(engineB)), [], "B stops offering Work");

  const c = new Mac("C");
  const engineC = await launch();
  await c.with(async () => {
    engineC.startSync();
    assert.ok("ok" in (await engineC.enterRecoveryPhrase("/sync", "words")));
    await engineC.syncNow();
    await engineC.syncNow();
    assert.deepEqual(offered(engineC), [], "a Mac that joins later never offers Work");
  });
});

test("a Mac that still has the profile publishes it again, with its sharing, and keeps it", async () => {
  const { a, b, engineA, engineB, workA, workB, syncId } = await twoMacsWithWork({ shareWith: "default" });
  await a.with(() => S().deleteProfile(workA));
  await cycle(a, engineA);
  assert.equal(await a.with(() => engineA.removeRemoteProfile(syncId)), true);
  await cycle(a, engineA);
  assert.ok(tombstoned(`prof:${syncId}`));
  assert.ok(!tombstoned(`share:${syncId}`), "share: stays live");

  await cycle(b, engineB);
  await b.with(() => {
    assert.ok(S().profiles[workB], "B keeps its Work");
    assert.equal(engineB.useSync.getState().profiles[workB]?.syncId, syncId, "and its link");
  });
  await cycle(a, engineA);
  const back = await a.with(() => engineA.useSync.getState().remoteProfiles.find((p) => p.syncId === syncId));
  assert.equal(back?.name, "Work", "A offers Work again once B republishes it");
  assert.deepEqual(back?.sharesWith, { name: "Personal", added: false }, "with its sharing");
});

test("a Mac on the last release that still has the profile publishes it again; one without it stops offering it", async () => {
  const { a, b, engineA, engineB, workA, workB, syncId } = await twoMacsWithWork({ shippedB: true });
  assert.equal(engineB.removeRemoteProfile, undefined, "B runs the shipped engine");
  await a.with(() => S().deleteProfile(workA));
  await cycle(a, engineA);
  assert.equal(await a.with(() => engineA.removeRemoteProfile(syncId)), true);
  await cycle(a, engineA);
  await cycle(b, engineB);
  await b.with(() => assert.ok(S().profiles[workB], "the older Mac keeps its Work"));
  await cycle(a, engineA);
  assert.deepEqual(await a.with(() => offered(engineA)), ["Work"], "and publishes it again");

  await b.with(() => S().deleteProfile(workB));
  await cycle(b, engineB);
  await cycle(a, engineA);
  assert.equal(await a.with(() => engineA.removeRemoteProfile(syncId)), true);
  await cycle(a, engineA);
  await cycle(b, engineB);
  assert.deepEqual(await b.with(() => offered(engineB)), [], "an older Mac without it stops offering it");
});

async function turnOn(mac, engine) {
  await mac.with(async () => {
    engine.startSync();
    assert.ok("ok" in (await engine.turnOnSync("/sync")));
    await engine.syncNow();
    await engine.syncNow();
  });
}

async function join(mac, engine, before = () => {}) {
  await mac.with(async () => {
    before();
    engine.startSync();
    assert.ok("ok" in (await engine.enterRecoveryPhrase("/sync", "words")));
    await engine.syncNow();
    await engine.syncNow();
  });
}

const row = (engine, name) => engine.useSync.getState().remoteProfiles.find((p) => p.name === name);

test("Remove from Sync refuses a profile linked here, the default and an unknown one, and takes a profile's dependents with it", async () => {
  folder.clear();
  const a = new Mac("A");
  const b = new Mac("B");
  const engineA = await launch();
  const engineB = await launch();
  const { home, kids, off } = await a.with(() => {
    const home = S().createProfile({ name: "Home" });
    return { home, kids: S().createProfile({ name: "Kids", shareWith: home }), off: S().createProfile({ name: "Off" }) };
  });
  await turnOn(a, engineA);
  const links = await a.with(() => ({ ...engineA.useSync.getState().profiles }));
  await a.with(async () => {
    engineA.setProfileSynced(off, false);
    await engineA.syncNow();
    assert.equal(engineA.removeRemoteProfile(links[home].syncId), false, "Home is on this Mac");
    assert.equal(engineA.removeRemoteProfile(links[off].syncId), false, "so is Off, though it doesn't sync");
    assert.equal(engineA.removeRemoteProfile(links.default.syncId), false, "nor the default");
    assert.equal(engineA.removeRemoteProfile("nothing"), false);
  });

  await join(b, engineB);
  await b.with(() => {
    assert.deepEqual(row(engineB, "Home")?.removal?.names, ["Home", "Kids"], "Kids shares Home's data, so it goes too");
    assert.deepEqual(row(engineB, "Kids")?.removal?.names, ["Kids"]);
    assert.ok(engineB.addRemoteProfile(links[kids].syncId), "adding Kids here adds Home with it");
    assert.equal(row(engineB, "Home"), undefined);
  });
  for (const id of [home, kids, off, "default"]) assert.ok(!tombstoned(`prof:${links[id].syncId}`));

  const c = new Mac("C");
  const engineC = await launch();
  await join(c, engineC);
  await c.with(() => assert.equal(engineC.removeRemoteProfile(links[home].syncId), true));
  await cycle(c, engineC);
  assert.ok(tombstoned(`prof:${links[home].syncId}`) && tombstoned(`prof:${links[kids].syncId}`), "Home and Kids are removed together");
  assert.ok(!tombstoned(`share:${links[kids].syncId}`));
});

test("removing one profile of a sharing cycle removes the whole cycle", async () => {
  folder.clear();
  const a = new Mac("A");
  const b = new Mac("B");
  const c = new Mac("C");
  const engineA = await launch();
  const engineB = await launch();
  const engineC = await launch();
  await a.with(() => S().createProfile({ name: "Beta", shareWith: S().createProfile({ name: "Alpha" }) }));
  await turnOn(a, engineA);
  await join(b, engineB, () => S().createProfile({ name: "Alpha", shareWith: S().createProfile({ name: "Beta" }) }));
  await cycle(a, engineA, 1);
  await cycle(b, engineB, 1);
  await join(c, engineC);
  await c.with(() => {
    assert.deepEqual(row(engineC, "Alpha")?.removal?.names, ["Alpha", "Beta"]);
    assert.equal(engineC.removeRemoteProfile(row(engineC, "Alpha").syncId), true);
    assert.deepEqual(offered(engineC), []);
  });
  await cycle(c, engineC);
  const links = await a.with(() => Object.values(engineA.useSync.getState().profiles).map((l) => l.syncId));
  for (const name of ["Alpha", "Beta"]) {
    const id = await a.with(() => engineA.useSync.getState().profiles[S().profileOrder.find((p) => S().profiles[p].name === name)].syncId);
    assert.ok(links.includes(id) && tombstoned(`prof:${id}`), `${name} is removed with the cycle`);
  }
});

test("a removal is dropped when what was confirmed changes before it runs", async () => {
  for (const change of ["a new dependent", "a rename", "the profile added here"]) {
    folder.clear();
    const a = new Mac("A");
    const b = new Mac("B");
    const engineA = await launch();
    const engineB = await launch();
    const home = await b.with(() => S().createProfile({ name: "Home" }));
    await turnOn(b, engineB);
    await join(a, engineA);
    const syncId = await b.with(() => engineB.useSync.getState().profiles[home].syncId);
    await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId), true));
    if (change === "a new dependent") await b.with(() => S().createProfile({ name: "Kids", shareWith: home }));
    if (change === "a rename") await b.with(() => S().updateProfile(home, { name: "House" }));
    if (change === "the profile added here") await a.with(() => assert.ok(engineA.addRemoteProfile(syncId), "adding it back cancels the removal"));
    await cycle(b, engineB);
    await cycle(a, engineA);
    assert.ok(!tombstoned(`prof:${syncId}`), `${change}: nothing is removed`);
    if (change !== "the profile added here") {
      await a.with(() => assert.ok(row(engineA, change === "a rename" ? "House" : "Home"), `${change}: the row comes back`));
    }
  }
});

test("a removal survives a relaunch, and stopping sync drops it", async () => {
  const first = await twoMacsWithWork();
  await first.a.with(() => S().deleteProfile(first.workA));
  await cycle(first.a, first.engineA);
  await first.a.with(() => assert.equal(first.engineA.removeRemoteProfile(first.syncId), true));
  const relaunched = await launch();
  await first.a.with(async () => {
    relaunched.startSync();
    assert.deepEqual(offered(relaunched), [], "still hidden after a relaunch");
    for (let i = 0; i < 6 && !tombstoned(`prof:${first.syncId}`); i++) await relaunched.syncNow();
  });
  assert.ok(tombstoned(`prof:${first.syncId}`), "the relaunched engine sends the removal");

  const second = await twoMacsWithWork();
  await second.a.with(() => S().deleteProfile(second.workA));
  await cycle(second.a, second.engineA);
  await second.a.with(async () => {
    assert.equal(second.engineA.removeRemoteProfile(second.syncId), true);
    await second.engineA.stopSync();
  });
  await join(second.a, second.engineA);
  await cycle(second.a, second.engineA);
  assert.ok(!tombstoned(`prof:${second.syncId}`), "stopping sync drops the request");
});

const savedRemovals = (mac) => mac.with(() => JSON.parse(shell.docs.get("sync.json") ?? "{}").removing ?? null);

test("a removal waits while the app scope is still downloading, and refuses a stale confirmation", async () => {
  const { a, engineA, workA, syncId } = await twoMacsWithWork();
  await a.with(() => S().deleteProfile(workA));
  await cycle(a, engineA);
  const token = await a.with(() => row(engineA, "Work").removal.token);
  await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId, `${token}x`), false, "a confirmation of something else is refused"));
  pendingFiles = ["f-pending"];
  try {
    await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId, token), true));
    await cycle(a, engineA, 3);
    assert.ok(!tombstoned(`prof:${syncId}`), "nothing goes out while a file is still downloading");
  } finally {
    pendingFiles = [];
  }
  await cycle(a, engineA);
  assert.ok(tombstoned(`prof:${syncId}`));
  assert.equal(await savedRemovals(a), null, "the request is settled once its tombstone is out");
});

test("two Macs removing the same profile both settle", async () => {
  const { a, b, engineA, engineB, workA, workB, syncId } = await twoMacsWithWork();
  await a.with(() => S().deleteProfile(workA));
  await b.with(() => S().deleteProfile(workB));
  await cycle(a, engineA);
  await cycle(b, engineB);
  await cycle(a, engineA);
  await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId), true));
  await b.with(() => assert.equal(engineB.removeRemoteProfile(syncId), true));
  await cycle(a, engineA);
  await cycle(b, engineB);
  await cycle(a, engineA);
  assert.ok(tombstoned(`prof:${syncId}`));
  assert.equal(await savedRemovals(a), null);
  assert.equal(await savedRemovals(b), null);
  assert.deepEqual(await a.with(() => offered(engineA)), []);
  assert.deepEqual(await b.with(() => offered(engineB)), []);
});

test("a read that started before the click doesn't count as the pull after it", async () => {
  folder.clear();
  const a = new Mac("A");
  const b = new Mac("B");
  const engineA = await launch();
  const engineB = await launch();
  const home = await b.with(() => S().createProfile({ name: "Home" }));
  await turnOn(b, engineB);
  await join(a, engineA);
  const syncId = await b.with(() => engineB.useSync.getState().profiles[home].syncId);
  const before = new Set(folder.keys());
  await b.with(() => S().createProfile({ name: "Kids", shareWith: home }));
  await cycle(b, engineB);
  const stash = [...folder].filter(([id]) => !before.has(id));
  for (const [id] of stash) folder.delete(id);

  let reached;
  let release;
  const atRead = new Promise((resolve) => (reached = resolve));
  heldRead = () => new Promise((resolve) => (reached(), (release = resolve)));
  try {
    await a.with(async () => {
      const syncing = engineA.syncNow();
      await atRead;
      heldRead = null;
      assert.equal(engineA.removeRemoteProfile(syncId), true, "Kids isn't known here yet");
      for (const [id, file] of stash) folder.set(id, file);
      release();
      await syncing;
    });
  } finally {
    heldRead = null;
  }
  assert.ok(!tombstoned(`prof:${syncId}`), "the listing read before the click can't authorize it");
  await cycle(a, engineA);
  assert.ok(!tombstoned(`prof:${syncId}`), "the next pull finds Kids, so the request is dropped");
  await a.with(() => assert.deepEqual(row(engineA, "Home")?.removal?.names, ["Home", "Kids"], "and the row offers both"));
});

test("a request disproved while the app scope stays incomplete is still dropped, and its row comes back", async () => {
  folder.clear();
  const a = new Mac("A");
  const b = new Mac("B");
  const engineA = await launch();
  const engineB = await launch();
  const home = await b.with(() => S().createProfile({ name: "Home" }));
  await turnOn(b, engineB);
  await join(a, engineA);
  const syncId = await b.with(() => engineB.useSync.getState().profiles[home].syncId);
  pendingFiles = ["f-never"];
  try {
    await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId), true));
    await b.with(() => S().updateProfile(home, { name: "House" }));
    await cycle(b, engineB);
    await cycle(a, engineA);
    assert.ok(!tombstoned(`prof:${syncId}`));
    await a.with(() => assert.ok(row(engineA, "House"), "the renamed row is back"));
    assert.equal(await savedRemovals(a), null);
  } finally {
    pendingFiles = [];
  }
});

test("a removal is settled only once its tombstone is in the folder", async () => {
  const { a, engineA, workA, syncId } = await twoMacsWithWork();
  await a.with(() => S().deleteProfile(workA));
  await cycle(a, engineA);
  await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId), true));
  shell.heldSaves.fail = true;
  try {
    await a.with(async () => {
      await engineA.syncNow().catch(() => {});
      await engineA.syncNow().catch(() => {});
    });
  } finally {
    shell.heldSaves.fail = false;
  }
  assert.deepEqual((await savedRemovals(a))?.map((r) => r.root), [syncId], "not settled while the batch couldn't be saved");
  await cycle(a, engineA);
  assert.ok(tombstoned(`prof:${syncId}`));
  assert.equal(await savedRemovals(a), null);
});

test("a journal save that fails after a state save replaced the journal list is saved again before the removal settles", async () => {
  const { a, engineA, workA, syncId } = await twoMacsWithWork();
  const shellNative = shell.shellNativeModules.SolaraShell;
  const saveDocument = shellNative.saveDocument;
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const write = native.write;
  let journalSaves = 0;
  let rejected = false;
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-state";
  try {
    await a.with(() => S().deleteProfile(workA));
    await cycle(a, engineA);
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.ok(shell.heldSaves.queue.length, "an older state save is still on its way");
    shellNative.saveDocument = async (name, value) => {
      if (name.startsWith("sync-journal-b-")) {
        journalSaves++;
        if (!rejected) {
          rejected = true;
          shell.heldSaves.queue.shift()();
          for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
          throw new Error("disk full");
        }
      }
      return await saveDocument(name, value);
    };
    native.write = async () => {
      throw new Error("offline");
    };
    await a.with(() => assert.equal(engineA.removeRemoteProfile(syncId), true));
    await cycle(a, engineA, 1);
    assert.ok(await savedRemovals(a));
    await cycle(a, engineA, 1);
    assert.equal(journalSaves, 2, "the failed batch is saved again before anything counts it as saved");
    assert.ok(await savedRemovals(a), "the request stays until its tombstone is in the folder, so a lost journal can't lose it");
    native.write = write;
    await cycle(a, engineA);
    assert.ok(tombstoned(`prof:${syncId}`));
    assert.equal(await savedRemovals(a), null, "and is settled once it is");
  } finally {
    shellNative.saveDocument = saveDocument;
    native.write = write;
    shell.heldSaves.on = false;
    shell.heldSaves.only = null;
    for (const land of shell.heldSaves.queue.splice(0)) land();
  }
});
