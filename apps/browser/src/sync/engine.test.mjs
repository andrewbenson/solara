import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
let onWrite = null;
let ids = 0;
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
    unlock: async () => true,
    forget: async () => {},
    chainStatus: async () => "ok",
    write: async (_folder, scope, payload) => {
      const id = `f${folder.size + 1}`;
      folder.set(id, { scope, payload });
      onWrite?.(JSON.parse(payload));
      return id;
    },
    read: async (_folder, scope, known) => {
      const here = [...folder].filter(([, f]) => f.scope === scope);
      const files = here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload }));
      return { files, pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (sealed) => (sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async () => null,
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const S = () => useBrowser.getState();
const reset = () => (S().hydrate({}), useBrowser.setState({ bookmarksReady: { default: true } }));

test("a crash after a batch lands: after the restart it's sent again as it was, and the next batch gets a new seq", async () => {
  reset();
  const first = await import("./engine.ts?first");
  first.startSync();
  assert.ok("ok" in (await first.turnOnSync("/sync")));
  S().addBookmark({ profileId: "default", url: "https://one.example/", title: "One" });
  await first.syncNow();

  let disk = null;
  onWrite = (file) => {
    if (!disk && file.ops?.some((op) => op.v?.t === "Two")) disk = new Map(shell.docs);
  };
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await first.syncNow();
  onWrite = null;
  assert.ok(disk);
  shell.docs.clear();
  for (const [name, contents] of disk) shell.docs.set(name, contents);

  const second = await import("./engine.ts?second");
  second.startSync();
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
  S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
  await second.syncNow();

  const batches = new Map();
  for (const { scope, payload } of folder.values()) {
    const file = JSON.parse(payload);
    if (file.kind !== "log") continue;
    const key = `${scope} ${file.device} ${file.seq}`;
    assert.equal(batches.get(key) ?? payload, payload, `${key} was published twice with different changes`);
    batches.set(key, payload);
  }
  const three = [...folder.values()].map((f) => JSON.parse(f.payload)).find((f) => f.ops?.some((op) => op.v?.t === "Three"));
  assert.deepEqual(three.ops.map((op) => op.v?.t), ["Three"], "only what's new");
  assert.equal(shell.docs.get("sync-journal.nns"), "", "the journal is emptied once the saved state has its batches");
  assert.deepEqual([...shell.docs.keys()].filter((name) => name.startsWith("sync-journal-b-")), [], "and so are the batch files");
});

test("a batch is published only once the journal holding it is on disk", async () => {
  reset();
  shell.docs.clear();
  const engine = await import("./engine.ts?held");
  engine.startSync();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  const published = () => [...folder.values()].map((f) => JSON.parse(f.payload)).filter((f) => f.ops?.some((op) => op.v?.t === "Held"));

  shell.heldSaves.on = true;
  S().addBookmark({ profileId: "default", url: "https://held.example/", title: "Held" });
  const syncing = engine.syncNow();
  for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(published().length, 0, "nothing goes out while the journal save is still pending");
  assert.ok(shell.heldSaves.queue.length > 0, "the journal save is waiting");

  shell.heldSaves.on = false;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await syncing;
  assert.equal(published().length, 1, "published once the journal landed");
});

async function journalSaveRejectedOnce(name, { replaceList }) {
  reset();
  shell.docs.clear();
  const engine = await import(`./engine.ts?${name}`);
  engine.startSync();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  const native = shell.shellNativeModules.SolaraShell;
  const saveDocument = native.saveDocument;
  const published = () => [...folder.values()].map((f) => JSON.parse(f.payload)).filter((f) => f.ops?.some((op) => op.v?.t === name));
  let batchSaves = 0;
  if (replaceList) {
    shell.heldSaves.on = true;
    shell.heldSaves.only = "sync-state";
    S().addBookmark({ profileId: "default", url: "https://before.example/", title: "Before" });
    await engine.syncNow();
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.ok(shell.heldSaves.queue.length, "an older state save is still on its way");
  }
  native.saveDocument = async (doc, value) => {
    if (doc.startsWith("sync-journal-b-") && value.includes(name) && ++batchSaves === 1) {
      if (replaceList) {
        shell.heldSaves.queue.shift()();
        for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
      }
      throw new Error("disk full");
    }
    return await saveDocument(doc, value);
  };
  try {
    S().addBookmark({ profileId: "default", url: `https://${name.toLowerCase()}.example/`, title: name });
    await engine.syncNow().catch(() => {});
    assert.equal(published().length, 0, "nothing goes out while its journal save failed");
    await engine.syncNow().catch(() => {});
    assert.equal(batchSaves, 2, "the retry saves the batch again instead of taking it as saved");
    assert.equal(published().length, 1);
  } finally {
    native.saveDocument = saveDocument;
    shell.heldSaves.on = false;
    shell.heldSaves.only = null;
    for (const land of shell.heldSaves.queue.splice(0)) land();
  }
}

test("a batch whose journal save failed is saved again before it's published", async () => {
  await journalSaveRejectedOnce("Rejected", { replaceList: false });
});

test("a batch whose journal save failed after a state save replaced the journal list is saved again too", async () => {
  await journalSaveRejectedOnce("Replaced", { replaceList: true });
});
