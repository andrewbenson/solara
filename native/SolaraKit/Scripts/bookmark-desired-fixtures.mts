import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { registerHooks, stripTypeScriptTypes } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = process.env.SOLARA_REPO_ROOT ? pathToFileURL(`${process.env.SOLARA_REPO_ROOT}/`) : new URL("../../../", import.meta.url);
const source = new URL("apps/browser/src/", root);
const bridgeURL = new URL("lib/bookmarks.ts", source).href;
registerHooks({
  load(url, context, next) {
    if (url === bridgeURL) {
      const original = readFileSync(new URL(url), "utf8");
      const exports = "\nexport { applyOps, flatFromStore, flatFromEngine, launchTrees, adopt, readTree, pushTree, pushFailed, sendOps, stateOf, engines };\n";
      return { format: "module", source: stripTypeScriptTypes(original + exports), shortCircuit: true };
    }
    return next(url, context);
  },
});
const { useBrowser } = await import(new URL("store/browser.ts", source).href);
const reducer = await import(new URL("store/bookmarks.ts", source).href);
const bridge = await import(bridgeURL);
const { bookmarksAdapter } = await import(new URL("sync/adapters.ts", source).href);
const { syncRedesign } = await import(new URL("sync/redesignSwitch.ts", source).href);
const model = await import(new URL("store/model.ts", source).href);
const stub = await import(new URL("test-native/index.ts", source).href);
const { solaraCoreNativeModules } = await import(new URL("test-native/solaracore.ts", source).href);
const { Clock, emptyScope, syncScope, canonical } = await import(new URL("packages/sync/src/index.ts", root).href);
const S = () => useBrowser.getState();
const clone = (value) => JSON.parse(JSON.stringify(value));
const id = (n) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
const flatRecord = (f) => [...f.nodes].map(([id, n]) => ({ id, ...n, ...(f.children.has(id) ? { children: f.children.get(id) } : {}) }));
const toFlat = (records) => ({ nodes: new Map(records.map(({ id, children, ...n }) => [id, n])), children: new Map(records.filter(n => n.kind === "folder").map(n => [n.id, [...n.children]])) });
const roots = () => [
  { id: "bar@default", kind: "folder", parent: null, title: "Bookmarks Bar", addedAt: 0, children: [] },
  { id: "other@default", kind: "folder", parent: null, title: "Other Bookmarks", addedAt: 0, children: [] },
];
const urlNode = (n, parent = "bar@default", extra = {}) => ({ id: id(n), kind: "url", parent, title: `URL ${n}`, url: `https://e${n}.example/`, addedAt: n, ...extra });
const folder = (n, children = [], parent = "bar@default") => ({ id: id(n), kind: "folder", parent, title: `Folder ${n}`, addedAt: n, children });
function tree(nodes = [], bar = [], other = []) {
  const r = roots();
  r[0].children = bar;
  r[1].children = other;
  return [...r, ...nodes];
}
function document(records) {
  return { nodes: Object.fromEntries(records.map(({ parent, key, ...n }) => [n.id, { ...n, parentId: parent, ...(n.kind === "url" ? { favicon: null } : {}), ...(key ? { syncKey: key } : {}) }])), roots: { default: { bar: "bar@default", other: "other@default" } } };
}
function reset(bookmarks = document(roots()), ready = false) {
  bridge.engines.clear();
  S().hydrate({ bookmarks });
  useBrowser.setState({ bookmarks, bookmarksReady: ready ? { default: true } : {} });
  stub.docs.clear();
  stub.bookmarkDbs.clear();
  stub.bookmarkOpsSent.length = 0;
  model.setSharedDataIds({});
}
function pure(name, before, after, fetched = before) {
  const ops = bridge.bookmarkOps(toFlat(before), toFlat(after), "");
  return { name, engine: "", before, after, ops, fetched, replayed: flatRecord(bridge.applyOps(toFlat(fetched), ops, "")) };
}

export async function generateBookmarkDesiredFixtures() {
  const oldRandom = Math.random;
  const oldNow = Date.now;
  let randomWord = 0;
  let now = 1700000000000;
  Math.random = () => (++randomWord) / 0x1_0000_0000;
  Date.now = () => now;
  try {
    const pureRecords = [
      pure("add-folder-breadth-first", tree(), tree([folder(1, [id(2)]), urlNode(2, id(1)), urlNode(3)], [id(1), id(3)])),
      pure("update-move-remove", tree([folder(1, [id(2)]), urlNode(2, id(1)), urlNode(3)], [id(1), id(3)]), tree([folder(1), urlNode(2, "other@default", { title: "Renamed", url: "https://changed.example/" })], [id(1)], [id(2)])),
      pure("same-parent-reorder", tree([urlNode(1), urlNode(2), urlNode(3)], [id(1), id(2), id(3)]), tree([urlNode(1), urlNode(2), urlNode(3)], [id(3), id(1), id(2)])),
      pure("remove-folder-top-only", tree([folder(1, [id(2)]), urlNode(2, id(1)), urlNode(3)], [id(1), id(3)]), tree()),
      pure("invalid-url-skips-valid-suffix-continues", tree(), tree([urlNode(1, "bar@default", { url: "invalid" }), urlNode(2)], [id(1), id(2)])),
      pure("exact-unicode-update", tree([urlNode(1, "bar@default", { title: "é", url: "https://é.example/" })], [id(1)]), tree([urlNode(1, "bar@default", { title: "e\u0301", url: "https://e\u0301.example/" })], [id(1)])),
      pure("astral-exact-update", tree([urlNode(1, "bar@default", { title: "😀", url: "https://x.example/😀" })], [id(1)]), tree([urlNode(1, "bar@default", { title: "😁", url: "https://x.example/😁" })], [id(1)])),
      pure("unpaired-surrogate-exact-update", tree([urlNode(1, "bar@default", { title: "\ud800", url: "https://x.example/\ud800" })], [id(1)]), tree([urlNode(1, "bar@default", { title: "\ud801", url: "https://x.example/\ud801" })], [id(1)])),
      pure("cache-edit-replay", tree([urlNode(1)], [id(1)]), tree([urlNode(1), urlNode(2)], [id(1), id(2)]), tree([urlNode(3)], [id(3)])),
      pure("structural-move-break", tree([folder(1), folder(2, [id(3)]), folder(3, [], id(2)), urlNode(4)], [id(1), id(2), id(4)]), tree([folder(1, [id(3)]), folder(3, [], id(1))], [id(1)]), tree([folder(1, [], id(3)), folder(2, [id(3)]), folder(3, [id(1)], id(2)), urlNode(4)], [id(2), id(4)])),
      pure("partial-delete-valid-suffix-resurrected", tree([urlNode(1), urlNode(2), urlNode(3)], [id(1), id(2), id(3)]), tree(), tree([urlNode(3)], [id(3)])),
    ];
    const rawReplay = [
      { name: "fractional-replay-index-truncates", before: tree([urlNode(1), urlNode(2)], [id(1), id(2)]), ops: [{ op: "move", id: id(2), parent: "bar", index: 0.9 }] },
      { name: "negative-replay-index-clamps-zero", before: tree([urlNode(1), urlNode(2)], [id(1), id(2)]), ops: [{ op: "move", id: id(2), parent: "bar", index: -1 }] },
      { name: "ifAbsent-keeps-existing", before: tree([urlNode(1)], [id(1)]), ops: [{ op: "add", id: id(1), parent: "other", index: 0, k: "u", t: "Ignored", u: "https://changed.example/", a: 0, ifAbsent: true }] },
      { name: "invalid-update-keeps-url", before: tree([urlNode(1)], [id(1)]), ops: [{ op: "update", id: id(1), t: "Title changes", u: "invalid" }] },
      { name: "missing-parent-breaks-valid-suffix", before: tree([urlNode(1)], [id(1)]), ops: [{ op: "move", id: id(1), parent: "missing", index: 0 }, { op: "remove", id: id(1) }] },
      { name: "missing-child-detach-splice-minus-one", before: tree([urlNode(1), urlNode(2)], [id(1)]), ops: [{ op: "move", id: id(2), parent: "other", index: 0 }] },
      { name: "root-update-breaks-valid-suffix", before: tree([urlNode(1)], [id(1)]), ops: [{ op: "update", id: "bar@default", t: "Ignored" }, { op: "remove", id: id(1) }] },
      { name: "existing-add-retains-id-date-key", before: tree([urlNode(1, "bar@default", { key: "old-key" })], [id(1)]), ops: [{ op: "add", id: id(1), parent: "other", index: 99, k: "f", t: "Changed", a: 999, key: "new-key" }] },
      { name: "missing-remove-breaks-valid-suffix", before: tree([urlNode(1)], [id(1)]), ops: [{ op: "remove", id: id(99) }, { op: "remove", id: id(1) }] },
    ].map(r => ({ ...r, engine: "", replayed: flatRecord(bridge.applyOps(toFlat(r.before), r.ops, "")) }));
    const reducerRecords = [];
    function scenario(name, before, run) {
      reset(before);
      randomWord = 0;
      const commands = [];
      const results = [];
      const steps = [];
      const call = (method, ...args) => {
        commands.push({ method, args: clone(args) });
        const result = S()[method](...args);
        results.push(result === undefined ? null : clone(result));
        steps.push({ command: clone(commands.at(-1)), result: clone(results.at(-1)), after: clone(S().bookmarks), now, allocationCount: randomWord / 4 });
        return result;
      };
      run(call);
      const ids = Array.from({ length: randomWord / 4 }, (_, i) => {
        const first = (i * 4 + 1).toString(16).padStart(8, "0");
        const second = (i * 4 + 2).toString(16).padStart(8, "0");
        const third = (i * 4 + 3).toString(16).padStart(8, "0");
        const fourth = (i * 4 + 4).toString(16).padStart(8, "0");
        const hex = first + second + third + fourth;
        return `${hex.slice(0,8)}-${hex.slice(8,12)}-4${hex.slice(13,16)}-8${hex.slice(17,20)}-${hex.slice(20)}`;
      });
      reducerRecords.push({ name, before, commands, allocatedIds: ids, now, after: clone(S().bookmarks), results, steps: steps.map(({ allocationCount, ...step }) => ({ ...step, allocatedIds: ids.slice(0, allocationCount) })) });
    }
    scenario("all-mutations-and-undo", document(roots()), call => {
      const a = call("addBookmark", { profileId: "default", title: "A", url: "https://a.example/", favicon: "icon", index: -10 });
      const f = call("addBookmarkFolder", { profileId: "default", title: "Folder", index: -1 });
      call("updateBookmark", a, { title: "Renamed", url: "https://b.example/", favicon: null });
      call("moveBookmark", a, f, -1);
      call("addBookmarkTree", "default", [{ title: "Imported", addedAt: 0, children: [{ title: "Child", url: "https://import.example/", addedAt: 0 }] }], f, 99);
      const removed = call("removeBookmarks", [f, a]);
      call("restoreBookmarks", removed);
      call("removeBookmark", a);
      call("toggleBookmark", "default", { url: "https://toggle.example/", title: "Toggle", favicon: null });
    });
    scenario("negative-index-and-boundaries", document(tree([urlNode(1), urlNode(2), urlNode(3)], [id(1), id(2), id(3)])), call => {
      call("moveBookmark", id(3), "bar@default", -1);
      call("addBookmark", { profileId: "default", title: "Negative", url: "x:y", index: -2 });
      call("moveBookmark", id(1), "bar@default", -99);
      call("moveBookmark", id(2), "bar@default", 99);
      call("removeBookmark", "bar@default");
    });
    scenario("duplicate-bulk-remove-and-restore", document(tree([urlNode(1), urlNode(2)], [id(1), id(2)])), call => {
      const removed = call("removeBookmarks", [id(1), id(1)]);
      call("restoreBookmarks", removed);
    });
    scenario("fractional-index-truncates-toward-zero", document(tree([urlNode(1), urlNode(2), urlNode(3)], [id(1), id(2), id(3)])), call => {
      call("moveBookmark", id(3), "bar@default", -1.9);
      call("addBookmark", { profileId: "default", title: "Fractional", url: "x:y", index: 1.9 });
      call("moveBookmark", id(1), "bar@default", 0.9);
      call("addBookmarkTree", "default", [{ title: "Tree fractional", children: [] }], "bar@default", -1.9);
    });
    scenario("toggle-all-exact-duplicates", document(tree([urlNode(1, "bar@default", { url: "https://é.example/" }), urlNode(2, "other@default", { url: "https://é.example/" }), urlNode(3, "bar@default", { url: "https://e\u0301.example/" })], [id(1), id(3)], [id(2)])), call => {
      call("toggleBookmark", "default", { url: "https://é.example/", title: "Duplicate", favicon: null });
      call("toggleBookmark", "default", { url: "", title: "Empty", favicon: null });
    });
    scenario("cycle-and-invalid-parent", document(tree([folder(1, [id(2)]), folder(2, [], id(1)), urlNode(3)], [id(1), id(3)])), call => {
      call("moveBookmark", id(1), id(2), 0);
      call("moveBookmark", id(3), "missing", 0);
      call("updateBookmark", id(1), { url: "ignored", title: "Folder updated" });
    });
    scenario("restore-missing-parent-keeps-descendant-orphan", document(tree([folder(1, [id(2)]), folder(2, [id(3)], id(1)), urlNode(3, id(2))], [id(1)])), call => {
      const removed = call("removeBookmarks", [id(2)]);
      call("removeBookmark", id(1));
      call("restoreBookmarks", removed);
    });
    reset(document(tree([urlNode(1)], [id(1)])), true);
    model.setSharedDataIds({ alias: "default" });
    const sharedId = S().addBookmark({ profileId: "alias", title: "Shared", url: "https://shared.example/" });
    const aliases = { sharedId, roots: clone(S().bookmarks.roots), mappings: ["default", "alias", "incognito:w@alias"].map(profile => ({ profile, engine: model.engineProfile(profile), privateSession: model.privateSession(profile) })) };
    const legacy = ["bm-old", "é", "e\u0301", "\ud800", id(1)].map(key => ({ key, id: reducer.bookmarkUuidFor(key) }));
    const wireModes = {};
    const originalRedesign = syncRedesign.on;
    try {
      for (const mode of ["off", "on"]) {
        syncRedesign.on = mode === "on";
        now = 1700000000000;
        wireModes[mode] = await wireRecords(() => now, value => { now = value; });
      }
    } finally { syncRedesign.on = originalRedesign; }
    const wire = wireModes.off;
    const traces = await serviceRecords();
    traces.partialBatch = await partialBatchRecord();
    traces.keptMigrationLaunch = await keptMigrationLaunchRecord();
    const membershipDocument = document(tree([urlNode(1, "bar@default", { url: "https://é.example/" }), urlNode(2, "other@default", { url: "https://é.example/" }), urlNode(3, "bar@default", { url: "https://e\u0301.example/" }), urlNode(4, "bar@default", { url: "https://x.example/\ud800" })], [id(1), id(3), id(4)], [id(2)]));
    const membership = ["https://é.example/", "https://e\u0301.example/", "https://É.example/", "https://é.example", "", "https://x.example/\ud800", "https://x.example/�"].map(url => ({ url, ids: reducer.bookmarksByUrl(membershipDocument, "default").get(url) ?? [], member: reducer.isBookmarked(membershipDocument, "default", url) }));
    return { version: 1, providers: { randomWords: "incrementing UInt32 starting at 1, grouped in fours", creationNow: 1700000000000, device: "oracle-A" }, pure: pureRecords, replay: rawReplay, reducer: reducerRecords, legacy, aliases, membershipDocument, membership, wire, wireModes, traces };
  } finally {
    Math.random = oldRandom;
    Date.now = oldNow;
  }
}

async function wireRecords(getNow, setNow) {
  reset(document(roots()));
  const state = emptyScope();
  const adapter = bookmarksAdapter("default");
  const files = new Map();
  const writes = [];
  const cycles = [];
  const clock = new Clock("oracle-A", null, getNow);
  const enginePushes = [];
  const engineState = Object.assign(bridge.stateOf(""), { shadow: toFlat(roots()), shown: null, busy: false, needRead: false, needPush: false, failedPushes: 0, retryTimer: null, retryPending: false });
  async function failPush() {
    const cef = solaraCoreNativeModules.SolaraCEF;
    const originalCall = cef.engineCall;
    const originalTimeout = globalThis.setTimeout;
    const originalWarn = console.warn;
    const ops = [];
    const schedules = [];
    cef.engineCall = async (name, profile, json) => {
      if (name === "ac_bookmarks_apply") {
        ops.push(...JSON.parse(json).ops);
        throw new Error("oracle push refused");
      }
      return originalCall(name, profile, json);
    };
    globalThis.setTimeout = (fn, ms) => { schedules.push(ms); return 0; };
    console.warn = () => {};
    try {
      await bridge.pushTree("", engineState);
      enginePushes.push({ ops, schedules, failedPushes: engineState.failedPushes, needRead: engineState.needRead, retryPending: engineState.retryPending, ready: !!S().bookmarksReady.default, desired: clone(S().bookmarks), shadow: flatRecord(engineState.shadow) });
    } finally {
      cef.engineCall = originalCall;
      globalThis.setTimeout = originalTimeout;
      console.warn = originalWarn;
    }
  }
  const transport = {
    write: async (scope, payload) => { const key = `f${files.size + 1}`; files.set(key, { scope, payload }); writes.push(payload); return key; },
    read: async (scope, known) => ({ files: [...files].filter(([k,f]) => f.scope === scope && !known.includes(k)).map(([id,f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: [...files.keys()] }),
    remove: async (_scope, ids) => ids.forEach(k => files.delete(k)),
  };
  async function cycle(name, options = {}) {
    const count = writes.length;
    const extraction = adapter.extract(k => state.records[k]?.v);
    const entries = extraction ? [...extraction.values] : null;
    const result = await syncScope({ scope: "p", state, transport, adapters: [adapter], clock, device: "oracle-A", options: { compactInterval: 1e15, ...options } });
    cycles.push({ name, ready: !!S().bookmarksReady.default, entries, canonical: entries?.map(([k,v]) => [k, canonical(v)]) ?? null, result, payloads: writes.slice(count), records: clone(state.records), base: clone(state.base), seq: state.seq, desired: clone(S().bookmarks) });
  }
  await cycle("launch-unready");
  useBrowser.setState({ bookmarksReady: { default: true } });
  await cycle("fetched-empty");
  const key = "legacy-é";
  const legacyID = reducer.bookmarkUuidFor(key);
  const nodes = tree([folder(1, [legacyID, id(2)]), urlNode(2, id(1), { url: "https://e\u0301.example/", addedAt: 0 }), { ...urlNode(3, id(1), { url: "https://é.example/", addedAt: 0 }), id: legacyID, key }], [id(1)]);
  useBrowser.setState({ bookmarks: document(nodes) });
  await failPush();
  await cycle("desired-pending-push-error");
  await cycle("same-value-idle");
  adapter.apply(new Map(adapter.extract(k => state.records[k]?.v).values));
  await cycle("same-value-reapply");
  const current = new Map([...adapter.extract(k => state.records[k]?.v).values]);
  current.set(`bm:${id(2)}`, { ...current.get(`bm:${id(2)}`), t: "Remote while push fails" });
  current.set("bm:tie-a", { k: "u", p: "bar", t: "Tie A", u: "x:a", a: 0, pos: "U" });
  current.set("bm:tie-b", { k: "u", p: "bar", t: "Tie B", u: "x:b", a: 0, pos: "U" });
  const remoteClock = new Clock("oracle-B", clock.last, getNow);
  const ops = [...current].map(([k,v]) => ({ k, h: remoteClock.tick(), v }));
  const remotePayload = JSON.stringify({ v: 1, kind: "log", device: "oracle-B", seq: 1, at: getNow(), ops });
  files.set("remote-1", { scope: "p", payload: remotePayload });
  await cycle("remote-replacement-pending");
  await failPush();
  await cycle("remote-position-repair");
  await cycle("remote-idle-no-echo");
  const removed = S().removeBookmarks([id(1)]);
  await cycle("folder-delete-tombstones");
  S().restoreBookmarks(removed);
  await cycle("undo-keeps-id-date");
  await cycle("undo-idle");
  const visible = new Map([
    ["bm:cycle-a", { k: "f", p: "cycle-b", t: "Cycle A", a: 0, pos: "U" }],
    ["bm:cycle-b", { k: "f", p: "cycle-a", t: "Cycle B", a: 0, pos: "U" }],
    ["bm:orphan", { k: "u", p: "gone", t: "Orphan", u: "x:y", a: 0, pos: "U" }],
  ]);
  adapter.apply(visible);
  await cycle("orphan-cycle-repair");
  const partialBatch = await partialBatchRecord();
  await cycle("partial-delete-resurrected");
  await cycle("partial-delete-idle");
  model.setSharedDataIds({ alias: "default" });
  reducer.ensureRoots(S().bookmarks, "alias");
  useBrowser.setState({ bookmarks: { ...S().bookmarks, roots: { ...S().bookmarks.roots, alias: S().bookmarks.roots.default } }, bookmarksReady: { default: true, alias: true } });
  const sharedEntries = [...bookmarksAdapter("alias").extract(k => state.records[k]?.v).values];
  setNow(getNow() + 1000);
  await cycle("snapshot", { compactAfterFiles: 1, compactInterval: 0 });
  await cycle("snapshot-idle");
  return { cycles, remotePayload, sharedEntries, enginePushes, partialBatch };
}

async function serviceRecords() {
  reset();
  const timers = [];
  const realSetTimeout = globalThis.setTimeout;
  const cef = solaraCoreNativeModules.SolaraCEF;
  const engineCall = cef.engineCall;
  const calls = [];
  const failure = Object.assign(bridge.stateOf(""), { shadow: toFlat(roots()), shown: null, busy: false, needRead: false, needPush: false, failedPushes: 0, retryTimer: null, retryPending: false });
  globalThis.setTimeout = (fn, ms) => { timers.push(ms); return 0; };
  const schedules = [];
  for (let i = 0; i < 9; i++) {
    failure.retryPending = false;
    bridge.pushFailed("", failure);
    schedules.push({ failedPushes: failure.failedPushes, needRead: failure.needRead, retryPending: failure.retryPending, nextDelay: timers.at(-1) ?? null });
  }
  globalThis.setTimeout = realSetTimeout;
  const cached = document(tree([urlNode(1)], [id(1)]));
  stub.docs.set("bookmarks-cache.json", JSON.stringify({ version: 1, trees: { "": Object.values(cached.nodes) } }));
  const launched = bridge.launchTrees();
  bridge.adopt("", launched[""], { ready: false });
  const beforeRead = { desired: clone(S().bookmarks), ready: clone(S().bookmarksReady) };
  S().addBookmark({ profileId: "default", title: "Cache edit", url: "https://cache-edit.example/" });
  const pending = Object.assign(bridge.stateOf(""), { ...failure, shadow: null, shown: launched[""], failedPushes: 0, retryPending: false });
  cef.engineCall = async (name, profile, json) => {
    if (name === "ac_bookmarks_apply") calls.push(JSON.parse(json).ops);
    return engineCall(name, profile, json);
  };
  try {
    await bridge.readTree("", pending);
    const afterRead = { desired: clone(S().bookmarks), ready: clone(S().bookmarksReady), shadow: flatRecord(pending.shadow), calls: clone(calls) };
    useBrowser.setState({ bookmarksReady: { default: true } });
    cef.engineCall = async (name, profile, json) => {
      if (name === "ac_bookmarks_apply") throw new Error("oracle push refused");
      return engineCall(name, profile, json);
    };
    const originalWarn = console.warn;
    console.warn = () => {};
    let sendError;
    let migration;
    try {
      sendError = await bridge.sendOps("", [{ op: "remove", id: id(99) }]);
      stub.docs.set("bookmarks.json", JSON.stringify({ bookmarks: cached }));
      migration = await bridge.migrateBookmarksFile({ keepMs: 0 });
    } finally { console.warn = originalWarn; }
    return { schedules, cacheEdit: { beforeRead, afterRead }, error: { accepted: sendError, desired: clone(S().bookmarks), ready: clone(S().bookmarksReady) }, migration: { result: migration, keptFile: stub.docs.has("bookmarks.json") } };
  } finally {
    cef.engineCall = engineCall;
    globalThis.setTimeout = realSetTimeout;
  }
}

export const bookmarkDesiredFixtureURL = new URL("../Tests/SolaraEngineTests/Fixtures/bookmark-desired.json", import.meta.url);
export const serializeBookmarkDesiredFixtures = value => JSON.stringify(value, null, 2) + "\n";
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const bytes = serializeBookmarkDesiredFixtures(await generateBookmarkDesiredFixtures());
  if (process.argv.includes("--verify")) {
    assert.equal(readFileSync(bookmarkDesiredFixtureURL, "utf8"), bytes, "bookmark desired fixture differs; regenerate with the same IDs, clocks and unchanged sources");
    console.log("bookmark-desired.json is byte-identical");
  } else {
    writeFileSync(bookmarkDesiredFixtureURL, bytes);
    console.log(fileURLToPath(bookmarkDesiredFixtureURL));
  }
}

async function partialBatchRecord() {
  const before = tree([urlNode(1), urlNode(2), urlNode(3)], [id(1), id(2), id(3)]);
  reset(document(before), true);
  await bridge.sendOps("", bridge.bookmarkOps(toFlat(roots()), toFlat(before), ""));
  const db = stub.chromeBookmarks("");
  db.get("bar").children = db.get("bar").children.filter(child => child !== id(2));
  db.delete(id(2));
  useBrowser.setState({ bookmarks: document(roots()) });
  const pending = Object.assign(bridge.stateOf(""), { shadow: toFlat(before), shown: null, busy: false, needRead: false, needPush: false, failedPushes: 0, retryTimer: null, retryPending: false });
  const cef = solaraCoreNativeModules.SolaraCEF;
  const originalCall = cef.engineCall;
  const originalTimeout = globalThis.setTimeout;
  const schedules = [];
  const batches = [];
  const checkpoints = [];
  cef.engineCall = async (name, profile, json) => {
    const result = await originalCall(name, profile, json);
    if (name === "ac_bookmarks_apply") batches.push({ ops: JSON.parse(json).ops, result: JSON.parse(result) });
    return result;
  };
  globalThis.setTimeout = (fn, ms) => { schedules.push(ms); return 0; };
  const checkpoint = name => checkpoints.push({ name, desired: clone(S().bookmarks), shadow: flatRecord(pending.shadow), ready: clone(S().bookmarksReady), failedPushes: pending.failedPushes, needRead: pending.needRead, retryPending: pending.retryPending });
  try {
    await bridge.pushTree("", pending);
    checkpoint("partial-push");
    await bridge.readTree("", pending);
    checkpoint("reread-breaks-at-missing-prefix");
    await bridge.readTree("", pending);
    checkpoint("retry-pending-read");
    return { batches, schedules, checkpoints, desiredTitles: Object.values(S().bookmarks.nodes).filter(n => n.kind === "url").map(n => n.title), actualTitles: [...db.values()].filter(n => n.k === "u").map(n => n.t) };
  } finally {
    cef.engineCall = originalCall;
    globalThis.setTimeout = originalTimeout;
  }
}

async function keptMigrationLaunchRecord() {
  reset();
  const legacy = document(tree([urlNode(1)], [id(1)]));
  stub.docs.set("bookmarks.json", JSON.stringify({ bookmarks: legacy }));
  const cef = solaraCoreNativeModules.SolaraCEF;
  const originalCall = cef.engineCall;
  const originalWarn = console.warn;
  const attempts = [];
  cef.engineCall = async (name, profile, json) => {
    if (name === "ac_bookmarks_apply") {
      attempts.push(JSON.parse(json).ops);
      throw new Error("oracle migration refused");
    }
    return originalCall(name, profile, json);
  };
  console.warn = () => {};
  const stop = bridge.startBookmarks();
  const before = { desired: clone(S().bookmarks), ready: clone(S().bookmarksReady) };
  try {
    await bridge.reloadBookmarks();
    await Promise.resolve();
    await bridge.reloadBookmarks();
    return { before, after: { desired: clone(S().bookmarks), ready: clone(S().bookmarksReady) }, attempts, keptFile: stub.docs.has("bookmarks.json") };
  } finally {
    stop();
    cef.engineCall = originalCall;
    console.warn = originalWarn;
  }
}
