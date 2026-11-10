import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { registerHooks, stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const preBootstrapEngineBlob = "36cb59fea3495124c6c3e993d5512b0842c2fab8";
const preBootstrapEngine = execFileSync("git", ["cat-file", "blob", preBootstrapEngineBlob], {
  cwd: fileURLToPath(new URL(".", import.meta.url)),
  encoding: "utf8",
  maxBuffer: 1 << 24,
});
const fixture = new URL("./engine-pre-bootstrap.ts", import.meta.url);
const engineLocation = new URL("./engine.ts", import.meta.url).href;
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(fixture.href)) return { url: specifier, format: "module", shortCircuit: true };
    if (context.parentURL?.startsWith(fixture.href)) return next(specifier, { ...context, parentURL: engineLocation });
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url.startsWith(fixture.href)) return { format: "module", source: stripTypeScriptTypes(preBootstrapEngine), shortCircuit: true };
    return next(url, context);
  },
});

let timers = 0;
globalThis.setTimeout = () => (timers++, 0);
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
const calls = [];
const accounts = new Map([["joining-device", "native-only-root"]]);
let ids = 0;
const called = (name, result) => (calls.push(name), result);
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    async createSync(folder) {
      const account = this.newDeviceId();
      if (!(await this.createPhrase(account))) return null;
      await this.createChain(folder);
      return account;
    },
    newDeviceId: () => called("allocate", `allocated-${++ids}`),
    deviceName: () => "Joining Mac",
    createPhrase: async () => called("createPhrase", true),
    enterPhrase: async () => called("enterPhrase", { ok: true }),
    createChain: async () => called("createChain"),
    unlock: async () => called("unlock", true),
    forget: async (account) => (accounts.delete(account), called("forget")),
    chainStatus: async () => called("chainStatus", "ok"),
    write: async (_path, scope, payload) => {
      const id = `file-${++ids}`;
      folder.set(id, { scope, payload });
      return called("publish", id);
    },
    read: async (_path, scope, known) => {
      const here = [...folder].filter(([, file]) => file.scope === scope);
      return called("read", { files: here.filter(([id]) => !known.includes(id)).map(([id, file]) => ({ id, payload: file.payload })), pending: [], damaged: [], present: here.map(([id]) => id) });
    },
    remove: async (_path, _scope, list) => (list.forEach((id) => folder.delete(id)), called("remove")),
    deleteChain: async () => (folder.clear(), called("deleteChain")),
    sealLocal: async (text) => called("seal", `sealed:${text}`),
    openLocal: async (text) => called("open", text.startsWith("sealed:") ? text.slice(7) : null),
    readPasswords: async () => called("readPasswords", []),
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const settle = async () => {
  for (let i = 0; i < 40; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = () => import(`${fixture.href}?launch=${++launches}`);

const document = (phase, v = 2) => ({
  v,
  enabled: phase !== "prepared" && phase !== "key-saved" && phase !== "stopped",
  folder: "/selected-sync",
  deviceId: "joining-device",
  clock: null,
  types: { bookmarks: true, history: false, tabs: true, pinned: true, passwords: false, extensions: false, settings: true },
  profiles: {},
  lastSyncedAt: null,
  setupAt: 1,
  joining: phase !== "ready" && phase !== "onboarding-completed" && phase !== "stopped",
  joinTransaction: "a".repeat(64),
  bootstrap: { phase, transaction: "a".repeat(64), generation: 7, stopGeneration: 2, cid: "selected-cid", folderIdentity: "selected-folder" },
});

function reset() {
  useBrowser.getState().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  shell.docs.clear();
  shell.documentWrites.length = 0;
  folder.clear();
  calls.length = 0;
  timers = 0;
  accounts.clear();
  accounts.set("joining-device", "native-only-root");
}

for (const phase of ["prepared", "key-saved", "awaiting-profile", "binding-persisted", "applying", "ready", "onboarding-completed", "stopped", "unknown-phase", null]) {
  test(`the pre-bootstrap reader refuses local v2 ${phase ?? "missing bootstrap"} before any sync side effect`, async () => {
    reset();
    const saved = document(phase);
    if (phase === null) delete saved.bootstrap;
    shell.docs.set("sync.json", JSON.stringify(saved));
    shell.docs.set("pairing-install-marker", JSON.stringify({ transaction: saved.joinTransaction, phase, generation: 7 }));
    shell.docs.set("sync-journal.nns", "preserved-batch-journal");
    shell.docs.set("sync-journal-b-old-1.nns", "preserved-batch");
    shell.docs.set("sync-state.nns", "preserved-local-replica");
    const docsBefore = new Map(shell.docs);
    const accountsBefore = new Map(accounts);
    const engine = await launch();
    calls.length = 0;
    timers = 0;
    engine.startSync();
    await settle();
    assert.equal(engine.useSync.getState().status, "unavailable");
    assert.match(engine.useSync.getState().error, /newer version/);
    await engine.syncNow();
    assert.ok("error" in await engine.turnOnSync("/replacement"));
    assert.ok("error" in await engine.enterRecoveryPhrase("/replacement", "untrusted words"));
    await engine.stopSync({ deleteData: true });
    engine.setTypeSynced("history", true);
    engine.setProfileSynced("default", true);
    engine.adoptProfileTheme("default");
    assert.equal(engine.addRemoteProfile("invented-profile"), null);
    await settle();
    assert.deepEqual(calls, [], "no unlock, allocation, publication, read, compaction, reset or Keychain mutation");
    assert.equal(timers, 0, "no startup or explicit-action scheduling");
    assert.deepEqual(shell.documentWrites, [], "no unacknowledged overwrite");
    assert.deepEqual(new Map(shell.docs), docsBefore, "document, install marker, journals and replica remain byte-identical");
    assert.deepEqual(accounts, accountsBefore);
    assert.equal(folder.size, 0);
  });
}

test("the pre-bootstrap v1 reader ignores added transaction fields and a device-only file permits premature joining clearance, allocation and publication", async () => {
  reset();
  shell.docs.set("sync.json", JSON.stringify(document("awaiting-profile", 1)));
  folder.set("trusted-device-only", {
    scope: "app",
    payload: JSON.stringify({ v: 1, kind: "log", device: "trusted-device", seq: 1, at: 1, ops: [{ k: "dev:trusted-device", h: "000000001.0000.trusted-device", v: { n: "Trusted Mac" } }] }),
  });
  const engine = await launch();
  engine.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await engine.syncNow();
  await settle();
  const saved = JSON.parse(shell.docs.get("sync.json"));
  assert.equal(saved.v, 1);
  assert.equal(saved.bootstrap.phase, "awaiting-profile", "the extra field is retained without enforcing its meaning");
  assert.equal(saved.joining, false, "another writer alone clears joining");
  assert.match(saved.profiles.default.syncId, /^allocated-/, "missing remote default mints an unrelated ID");
  assert.ok(calls.includes("unlock"));
  assert.ok(calls.includes("allocate"));
  assert.ok(calls.includes("publish"));
  assert.ok(timers > 0);
  const publishedOps = [...folder.values()].flatMap(({ payload }) => JSON.parse(payload).ops ?? []);
  assert.ok(publishedOps.some((op) => op.k === "dev:joining-device"), "the pending Mac publishes its name");
});
