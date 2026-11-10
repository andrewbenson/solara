import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import { inspect } from "node:util";

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
let ids = 0;
let passwordError = null;
const passwordReads = [];
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    newDeviceId: () => `dev${++ids}`,
    deviceName: () => "Test Mac",
    createPhrase: async () => true,
    createChain: async () => {},
    createSync: async () => `dev${++ids}`,
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
      return { files, pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (sealed) => (sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async (profile) => {
      passwordReads.push(profile);
      if (passwordError) {
        const error = passwordError;
        passwordError = null;
        throw error;
      }
      return [];
    },
  },
};

await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const S = () => useBrowser.getState();
const settle = async () => {
  for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
};

test("a password baseline failure logs only its name and code and the remaining adapters keep syncing", async () => {
  S().hydrate({});
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { default: true, [work]: true } });
  const before = await import("./engine.ts?before-baseline-warning");
  before.startSync();
  assert.ok("ok" in (await before.turnOnSync("/sync")));
  await before.syncNow();
  await settle();

  passwordReads.length = 0;
  passwordError = Object.assign(new Error("sensitive-password-sentinel", { cause: new Error("sensitive-cause-sentinel") }), { name: "KeychainError", code: "EKEYCHAIN" });
  const warnings = [];
  const warn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    const restarted = await import("./engine.ts?baseline-warning");
    restarted.startSync();
    await settle();
    assert.equal(passwordReads.length, 2, "the next profile's password baseline is read after the first one throws");
    S().addBookmark({ profileId: "default", url: "https://personal.example/", title: "Personal after baseline" });
    S().addBookmark({ profileId: work, url: "https://work.example/", title: "Work after baseline" });
    S().updateSettings({ appearance: "dark" });
    await restarted.syncNow();
    assert.equal(restarted.useSync.getState().status, "updated");
    const ops = [...folder.values()].flatMap(({ payload }) => JSON.parse(payload).ops ?? []);
    assert.ok(ops.some((op) => op.k.startsWith("bm:") && op.v?.t === "Personal after baseline"));
    assert.ok(ops.some((op) => op.k.startsWith("bm:") && op.v?.t === "Work after baseline"));
    assert.ok(ops.some((op) => op.k === "set:appearance" && op.v?.v === "dark"));
  } finally {
    console.warn = warn;
  }

  assert.equal(warnings.length, 1);
  const logged = inspect(warnings, { depth: null, showHidden: true, customInspect: false, maxArrayLength: null, maxStringLength: null });
  assert.doesNotMatch(logged, /sensitive-password-sentinel|sensitive-cause-sentinel/);
  assert.match(logged, /pw:/);
  assert.match(logged, /KeychainError/);
  assert.match(logged, /EKEYCHAIN/);
});
