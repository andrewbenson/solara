import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { openJournal } from "../sync/editJournal.ts";
import { readLedgerDoc } from "../sync/passwordLedger.ts";

const { transpileModule } = createRequire(import.meta.url)("typescript");
const load = (path, names, context, select = (s) => s) => {
  const source = select(readFileSync(new URL(path, import.meta.url), "utf8"))
    .replace(/^import .*;\n/gm, "").replace(/^export \{.*\} from .*;\n/gm, "").replace(/^export /gm, "");
  return runInNewContext(transpileModule(`${source}\n({${names}})`, { compilerOptions: { target: 9 } }).outputText, { console, Map, Set, Date, Promise, queueMicrotask, setTimeout: () => 0, clearTimeout() {}, ...context });
};
let latchId = 0;
async function shell() {
  const latch = await import(`./persistLatch.ts?writers=${++latchId}`);
  const docs = new Map();
  const calls = [];
  const context = {
    persistenceRefused: latch.persistenceRefused,
    readDocument: (name) => docs.get(name) ?? null,
    readDocumentResult: (name) => docs.has(name) ? { contents: docs.get(name) } : { missing: true },
    writeDocument: (name, text) => { calls.push(`write ${name}`); docs.set(name, text); },
    saveDocument: async (name, text) => { calls.push(`save ${name}`); docs.set(name, text); },
    removeDocument: (name) => { calls.push(`remove ${name}`); docs.delete(name); },
  };
  return { docs, calls, context, refuse: () => latch.refusePersistence("test refusal") };
}

for (const refused of [false, true]) {
  test(`user-document writers with refusal ${refused}`, async () => {
    const h = await shell();
    if (refused) h.refuse();
    const state = { profiles: { default: { id: "default" } } };
    const history = load("./history.ts", "readRedactedLegacy,dropImportedLegacyRows,moveLegacyHistory", {
      ...h.context, nativeSafeMode: () => false, useBrowser: { getState: () => state },
      engineIdOf: () => "", engineProfile: () => "", engineProfileLoaded: () => true,
      isIncognitoProfile: () => false, nativeAddHistoryVisits: async () => {},
    });
    h.docs.set("history.json", JSON.stringify({ history: { gone: [] } }));
    h.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: ["gone"], deleted: [] }));
    await history.readRedactedLegacy();
    h.docs.set("history.json", JSON.stringify({ history: { default: [] } }));
    await history.dropImportedLegacyRows(new Map([["default", "[]"]]));
    h.docs.set("history.json", JSON.stringify({ history: {} }));
    await history.moveLegacyHistory(1000, 0);
    const favicons = load("./favicons.ts", "removeLegacyFiles", { ...h.context, nativeSafeMode: () => false }, (s) => s.slice(s.indexOf("function removeLegacyFiles("), s.indexOf("export function startFavicons(")));
    h.docs.set("favicons-default.json", "{}");
    favicons.removeLegacyFiles(state);
    const extensions = load("../sync/extensions.ts", "stateOf,extensionsAdapterFor", {
      ...h.context, engineCall: async () => ({ intents: [{ id: "x", kind: "installed" }] }),
      extensionsAdapter: (adapter) => adapter, engineProfile: () => "",
    });
    await extensions.stateOf("");
    extensions.extensionsAdapterFor("default").settleIntents({ x: 1 });
    const ledger = load("../sync/ledgerPasswords.ts", "migrateLedger,writeLedgers", { ...h.context, readLedgerDoc });
    const doc = { v: 2, profiles: {} };
    assert.equal(ledger.writeLedgers(doc, ""), !refused);
    h.docs.set("sync-pw-ledger.json", JSON.stringify({ v: 1, profiles: {} }));
    await ledger.migrateLedger(async () => JSON.stringify(doc));
    const journal = load("../sync/journalHost.ts", "editJournal", {
      ...h.context, openJournal, GEN_DOC: "sync-edits.gen", syncRedesign: { on: true },
      nativeStoreActive: () => false, nativeSyncAnchorSupported: () => false,
    });
    h.docs.set("sync-edits.json", JSON.stringify({ v: 1, g: 1, newest: null, entries: {} }));
    const j = journal.editJournal();
    j.record("app", "set:a", { v: 1, h: "000000001.0000.dev", seen: null });
    j.clear("app", "set:a", "000000001.0000.dev");
    j.inStepAt(2, {});
    if (refused) assert.deepEqual(h.calls, []);
    else {
      for (const call of ["save history.json", "remove history.json", "remove favicons-default.json", "write sync-extensions.json", "write sync-pw-ledger.json", "write sync-edits.json", "write sync-edits.gen"]) assert.ok(h.calls.includes(call), call);
      assert.equal(h.calls.filter((c) => c === "save history.json").length, 2);
      assert.equal(h.calls.filter((c) => c === "write sync-pw-ledger.json").length, 2);
      assert.equal(h.calls.filter((c) => c === "write sync-edits.gen").length, 4);
    }
  });
}

test("refusal after asynchronous ledger migration and history import blocks the eventual shell call", async () => {
  const h = await shell();
  const ledger = load("../sync/ledgerPasswords.ts", "migrateLedger", { ...h.context, readLedgerDoc });
  h.docs.set("sync-pw-ledger.json", JSON.stringify({ v: 1, profiles: {} }));
  await ledger.migrateLedger(async () => { h.refuse(); return JSON.stringify({ v: 2, profiles: {} }); });
  assert.deepEqual(h.calls, []);
  const g = await shell();
  const history = load("./history.ts", "moveLegacyHistory", {
    ...g.context, nativeSafeMode: () => false, useBrowser: { getState: () => ({ profiles: { default: { id: "default" } } }) },
    engineIdOf: () => "", engineProfile: () => "", engineProfileLoaded: () => true, isIncognitoProfile: () => false,
    nativeAddHistoryVisits: async () => { g.refuse(); },
  });
  g.docs.set("history.json", JSON.stringify({ history: { default: [{ url: "https://a.test", lastVisit: 1 }] } }));
  await history.moveLegacyHistory(1000, 0);
  assert.deepEqual(g.calls, []);
});

for (const refused of [false, true]) test(`legacy retention removal with refusal ${refused} after scheduling`, async () => {
  const h = await shell();
  const timers = [];
  const history = load("./history.ts", "moveLegacyHistory", {
    ...h.context, setTimeout: (fn) => (timers.push(fn), 1), nativeSafeMode: () => false,
    useBrowser: { getState: () => ({ profiles: {} }) }, engineProfile: () => "", isIncognitoProfile: () => false,
  });
  h.docs.set("history.json", JSON.stringify({ history: {} }));
  await history.moveLegacyHistory(1000, 1);
  assert.equal(timers.length, 1);
  if (refused) h.refuse();
  await timers[0]();
  await new Promise(setImmediate);
  assert.deepEqual(h.calls, refused ? [] : ["remove history.json"]);
});

const engineSource = readFileSync(new URL("../sync/engine.ts", import.meta.url), "utf8");
const engineBoundaries = engineSource.slice(engineSource.indexOf("const writeDocument ="), engineSource.indexOf("const listDocuments ="));
function engineWriters(h, context = {}, extra = "", names = "writeDocument,saveDocument,removeDocument") {
  return load("../sync/engine.ts", names, {
    ...h.context, localName: (name) => name,
    writeStoredDocument: h.context.writeDocument, saveStoredDocument: h.context.saveDocument,
    removeStoredDocument: h.context.removeDocument, ...context,
  }, () => engineBoundaries + extra);
}

for (const refused of [false, true]) test(`engine shell boundaries with refusal ${refused}`, async () => {
  const h = await shell();
  if (refused) h.refuse();
  const engine = engineWriters(h);
  engine.writeDocument("sync.json", "{}");
  assert.equal(await engine.saveDocument("sync-state.nns", "sealed"), refused ? false : undefined);
  engine.removeDocument("sync-old.nns");
  assert.deepEqual(h.calls, refused ? [] : ["write sync.json", "save sync-state.nns", "remove sync-old.nns"]);
});

for (const refused of [false, true]) test(`engine batch seal pending with refusal ${refused}`, async () => {
  const h = await shell();
  let finishSeal;
  const sealed = new Promise((resolve) => { finishSeal = resolve; });
  const engine = engineWriters(h, {
    journal: {}, sealLocal: () => sealed, batchPart: () => "part", batchName: () => "sync-batch.nns",
  }, engineSource.slice(engineSource.indexOf("const persistJournal ="), engineSource.indexOf("function dropBatches(")), "persistJournal");
  const pending = engine.persistJournal("scope")([{ device: "device", seq: 1 }]);
  if (refused) h.refuse();
  finishSeal("sealed");
  await pending;
  assert.deepEqual(h.calls, refused ? [] : ["save sync-batch.nns"]);
});

for (const refused of [false, true]) test(`engine queued pairing write with refusal ${refused}`, async () => {
  const h = await shell();
  let finishQueue;
  const queue = new Promise((resolve) => { finishQueue = resolve; });
  const engine = engineWriters(h, {
    DOC: "sync.json", savedJson: null, pairingWrites: queue, generation: 1, newerFormat: false, doc: {}, loaded: false,
    PAIRING_RECOVERY: "recovery", withPairingPreferences: (next) => next, readDocument: h.context.readDocument,
  }, engineSource.slice(engineSource.indexOf("async function writePairingDoc("), engineSource.indexOf("async function checkpointPairing(")), "writePairingDoc");
  const pending = engine.writePairingDoc({ profiles: {}, types: {} }, 1);
  if (refused) h.refuse();
  finishQueue();
  if (refused) await assert.rejects(pending, /recovery/);
  else await pending;
  assert.deepEqual(h.calls, refused ? [] : ["save sync.json"]);
});

for (const refused of [false, true]) test(`engine bootstrap seal pending with refusal ${refused}`, async () => {
  const h = await shell();
  let finishSeal;
  const sealed = new Promise((resolve) => { finishSeal = resolve; });
  const engine = engineWriters(h, {
    doc: { installation: "installed" }, generation: 1, PAIRING_RECOVERY: "recovery",
    sealLocal: () => sealed, deadline: (work) => work, readDocument: h.context.readDocument,
    digest: () => "digest", writePairingDoc: async () => {}, pairingReplica: null,
  }, engineSource.slice(engineSource.indexOf("async function checkpointPairing("), engineSource.indexOf("function resetRuntime(")), "checkpointPairing");
  const pending = engine.checkpointPairing("ready", { transaction: "tx", generation: 1, revision: 0 }, 1);
  if (refused) h.refuse();
  finishSeal("sealed");
  if (refused) await assert.rejects(pending, /recovery/);
  else await pending;
  assert.deepEqual(h.calls, refused ? [] : ["save sync-bootstrap-tx-1.nns"]);
});

for (const refused of [false, true]) test(`engine state seal pending with refusal ${refused}`, async () => {
  const h = await shell();
  let finishSeal;
  const sealed = new Promise((resolve) => { finishSeal = resolve; });
  const engine = engineWriters(h, {
    metadataLoaded: true, pushBookmarkSyncLinks() {}, newerFormat: false, syncHeld: h.context.persistenceRefused,
    doc: { v: 1, enabled: true, scopes: {}, deviceId: "device" }, savedJson: "{\"v\":1,\"enabled\":true,\"deviceId\":\"device\",\"seqs\":{}}",
    loaded: true, sealing: null, written: null, stateGeneration: null, highestGeneration: 0,
    deltaOf: () => ({ whole: false }), writtenOf: () => ({}), stateEra: 0, newEpoch: () => "epoch", STATE: "sync-state.nns",
    sealLocal: () => sealed, stateCleared: false, compactNext: false, compactedAt: 0,
    deltasWritten: {}, removeAll() {}, DELTA_PREFIX: "sync-delta-", pruneJournal() {},
  }, engineSource.slice(engineSource.indexOf("function save() {"), engineSource.indexOf("function publishUi(")) + "\nconst pendingSave = () => sealing;", "save,pendingSave");
  engine.save();
  const pending = engine.pendingSave();
  if (refused) h.refuse();
  finishSeal("sealed");
  await pending;
  assert.deepEqual(h.calls, refused ? [] : ["save sync-state.nns"]);
});

test("a pairing write refused by the latch publishes no stalled recovery error", async () => {
  const h = await shell();
  const published = [];
  const engine = engineWriters(h, { publishUi: (ui) => published.push(ui), errorText: (error) => String(error?.message ?? error) },
    engineSource.slice(engineSource.indexOf("const publishStalled ="), engineSource.indexOf("const syncHeld = () =>")), "publishStalled");
  engine.publishStalled(new Error("recovery"));
  assert.equal(JSON.stringify(published), JSON.stringify([{ status: "stalled", error: "recovery" }]));
  h.refuse();
  engine.publishStalled(new Error("recovery"));
  assert.equal(JSON.stringify(published), JSON.stringify([{ status: "stalled", error: "recovery" }]));
});
