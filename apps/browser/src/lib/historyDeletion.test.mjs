import assert from "node:assert/strict";
import { test } from "node:test";

const { useBrowser } = await import("../store/browser.ts");
const { migrateHistoryFile, startHistory } = await import("./history.ts");
const stub = await import("../test-native/index.ts");

const S = () => useBrowser.getState();
const now = Date.now();
const row = (url) => ({ url, title: url, favicon: null, visits: 1, lastVisit: now, visitTimes: [now] });
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const read = () => JSON.parse(stub.docs.get("history.json"));
const reset = () => {
  S().hydrate({});
  stub.docs.clear();
  stub.historyDbs.clear();
  stub.heldSaves.fail = false;
};

test("legacy history redacts only confirmed exact aliases and engines, preserving unknown and reserved rows", { timeout: 2000 }, async () => {
  reset();
  const history = Object.fromEntries(["default", "Alias", "alias", "Engine", "engine", "reserved", "unknown"].map((key) => [key, [row(`https://${key}.test/`)]]));
  stub.docs.set("history.json", JSON.stringify({ version: 2, extra: "preserved", history }));
  stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: ["Alias"], deleted: ["Engine"], reserved: ["reserved"] }));
  assert.equal(await migrateHistoryFile(now, { keepMs: 20 }), "moved");
  assert.deepEqual(Object.keys(read().history), ["default", "alias", "engine", "reserved", "unknown"]);
  assert.equal(read().extra, "preserved");
  await delay(30);
});

test("a live default profile keeps its legacy rows when Default's old engine is retired", { timeout: 2000 }, async () => {
  reset();
  const engine = S().createProfile({ name: "Engine" });
  useBrowser.setState((state) => ({ profiles: { ...state.profiles, default: { ...state.profiles.default, dataId: engine } } }));
  stub.docs.set("history.json", JSON.stringify({ history: { default: [row("https://live-default.test/")] } }));
  stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: [], deleted: [""], reserved: [] }));
  assert.equal(await migrateHistoryFile(now, { keepMs: 20 }), "moved");
  assert.deepEqual(Object.keys(read().history), ["default"]);
  assert.equal(stub.chromeHistory(engine).has("https://live-default.test/"), true);
  await delay(30);
});

test("a live profile keeps its legacy rows when a deleted engine shares its id", { timeout: 2000 }, async () => {
  reset();
  const live = S().createProfile({ name: "Live" });
  const other = S().createProfile({ name: "Other" });
  useBrowser.setState((state) => ({ profiles: { ...state.profiles, [live]: { ...state.profiles[live], dataId: other } } }));
  stub.docs.set("history.json", JSON.stringify({ history: { [live]: [row("https://live.test/")] } }));
  stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: [], deleted: [live], reserved: [] }));
  assert.equal(await migrateHistoryFile(now, { keepMs: 20 }), "moved");
  assert.deepEqual(Object.keys(read().history), [live]);
  assert.equal(stub.chromeHistory(other).has("https://live.test/"), true);
  await delay(30);
});

test("a failed legacy redaction leaves the entire source queued for retry and does not migrate or remove it", { timeout: 2000 }, async () => {
  reset();
  const source = JSON.stringify({ history: { default: [row("https://live.test/")], gone: [row("https://gone.test/")] } });
  stub.docs.set("history.json", source);
  stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: ["gone"], deleted: [], reserved: [] }));
  stub.heldSaves.fail = true;
  try {
    assert.equal(await migrateHistoryFile(now, { keepMs: 0 }), "kept");
    assert.equal(stub.docs.get("history.json"), source);
    assert.equal(stub.chromeHistory("").size, 0);
  } finally {
    stub.heldSaves.fail = false;
  }
  assert.equal(await migrateHistoryFile(now, { keepMs: 20 }), "moved");
  assert.deepEqual(Object.keys(read().history), ["default"]);
  await delay(30);
});

test("deleting a profile during a legacy chunk retires captured later chunks and redacts its source", { timeout: 2000 }, async () => {
  reset();
  const profile = S().createProfile({ name: "Legacy" });
  const history = { [profile]: Array.from({ length: 501 }, (_, index) => row(`https://gone.test/${index}`)), default: [row("https://live.test/")] };
  stub.docs.set("history.json", JSON.stringify({ history }));
  const native = stub.solaraCoreNativeModules.SolaraCEF;
  const original = native.engineCall;
  let release;
  let entered;
  const gate = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { entered = resolve; });
  const writes = [];
  native.engineCall = async (name, engine, args) => {
    if (name === "ac_history_add" && engine === profile) {
      writes.push(JSON.parse(args).pages);
      if (writes.length === 1) { entered(); await gate; }
    }
    return original(name, engine, args);
  };
  try {
    const moving = migrateHistoryFile(now, { keepMs: 20 });
    await started;
    stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: [profile], deleted: [profile], reserved: [] }));
    useBrowser.setState((state) => ({ profiles: Object.fromEntries(Object.entries(state.profiles).filter(([id]) => id !== profile)), profileOrder: state.profileOrder.filter((id) => id !== profile) }));
    release();
    await moving;
    assert.equal(writes.length, 1);
    assert.deepEqual(Object.keys(read().history), ["default"]);
  } finally {
    release();
    native.engineCall = original;
  }
  await delay(30);
});

test("deleting an alias keeps a surviving sharer's legacy rows on their common engine", { timeout: 2000 }, async () => {
  reset();
  const engine = S().createProfile({ name: "Engine" });
  const alias = S().createProfile({ name: "Sharer", shareWith: engine });
  stub.docs.set("history.json", JSON.stringify({ history: { [engine]: [row("https://removed.test/")], [alias]: [row("https://shared.test/")] } }));
  stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: [engine], deleted: [], reserved: [] }));
  useBrowser.setState((state) => ({ profiles: Object.fromEntries(Object.entries(state.profiles).filter(([id]) => id !== engine)), profileOrder: state.profileOrder.filter((id) => id !== engine) }));
  assert.equal(await migrateHistoryFile(now, { keepMs: 20 }), "moved");
  assert.deepEqual(Object.keys(read().history), [alias]);
  assert.equal(stub.chromeHistory(engine).has("https://shared.test/"), true);
  assert.equal(stub.chromeHistory(engine).has("https://removed.test/"), false);
  await delay(30);
});


test("confirmed deletion redaction retries while migration is waiting for its first window", { timeout: 5000 }, async () => {
  reset();
  const profile = S().createProfile({ name: "Queued legacy" });
  const source = JSON.stringify({ history: { default: [row("https://live.test/")], [profile]: [row("https://gone.test/")] } });
  stub.docs.set("history.json", source);
  const stop = startHistory();
  stub.heldSaves.fail = true;
  try {
    stub.docs.set("profile-data-tombstones.json", JSON.stringify({ aliases: [profile], deleted: [profile], reserved: [] }));
    useBrowser.setState((state) => ({ profiles: Object.fromEntries(Object.entries(state.profiles).filter(([id]) => id !== profile)), profileOrder: state.profileOrder.filter((id) => id !== profile) }));
    await delay(20);
    assert.equal(stub.docs.get("history.json"), source);
    stub.heldSaves.fail = false;
    const deadline = Date.now() + 3000;
    while (read().history[profile] && Date.now() < deadline) await delay(5);
    assert.deepEqual(Object.keys(read().history), ["default"]);
    assert.equal(stub.chromeHistory("").size, 0);
  } finally {
    stub.heldSaves.fail = false;
    stop();
  }
});

test("a migration's delayed removal cannot delete a later legacy source", { timeout: 2000 }, async () => {
  reset();
  stub.docs.set("history.json", JSON.stringify({ history: { default: [row("https://before.test/")] } }));
  assert.equal(await migrateHistoryFile(now, { keepMs: 20 }), "moved");
  const replacement = JSON.stringify({ history: { default: [row("https://after.test/")] } });
  stub.docs.set("history.json", replacement);
  await delay(30);
  assert.equal(stub.docs.get("history.json"), replacement);
});

test("a source replaced during native migration remains queued with its unimported rows", { timeout: 2000 }, async () => {
  reset();
  stub.docs.set("history.json", JSON.stringify({ history: { default: [row("https://before.test/")] } }));
  const native = stub.solaraCoreNativeModules.SolaraCEF;
  const original = native.engineCall;
  let release;
  let entered;
  const gate = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { entered = resolve; });
  native.engineCall = async (name, engine, args) => {
    if (name === "ac_history_add") { entered(); await gate; }
    return original(name, engine, args);
  };
  const replacement = JSON.stringify({ history: { default: [row("https://unimported.test/")] } });
  try {
    const moving = migrateHistoryFile(now, { keepMs: 20 });
    await started;
    stub.docs.set("history.json", replacement);
    release();
    assert.equal(await moving, "kept");
    await delay(30);
    assert.equal(stub.docs.get("history.json"), replacement);
    assert.equal(stub.chromeHistory("").has("https://unimported.test/"), false);
  } finally {
    release();
    native.engineCall = original;
  }
});
