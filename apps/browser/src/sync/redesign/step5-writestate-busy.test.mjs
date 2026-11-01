import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const idle = { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false, themeColor: null, discarded: false };
const nativeTab = { id: "t-native", windowId: "w-native", profileId: "default", url: "https://native.test/", title: "Native", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const fake = {
  rev: 0,
  held: false,
  live: { "t-native": { ...idle } },
  tabs: { "t-native": nativeTab },
  pages: {},
  status: () => ({ active: true, scope: "everything" }),
  snapshot() { return JSON.stringify({ rev: this.rev, data: { tabs: this.tabs, live: this.live } }); },
  dispatch(json) {
    const parsed = JSON.parse(json);
    const token = !Array.isArray(parsed) && !!parsed.fromSync;
    const commands = [].concat(parsed.commands ?? parsed);
    if (token && this.held && commands.some((c) => c.name === "applyState")) return JSON.stringify({ rev: this.rev, patches: [], busy: true });
    const patches = [];
    for (const { name, args } of commands) {
      if (name === "beginTransaction") this.held = true;
      if (name === "endTransaction") this.held = false;
      if (name === "pageReport") {
        const [id, report] = args;
        if (!this.tabs[id]) continue;
        if (report.type === "created") this.pages[id] = report.generation;
        if (report.type === "media" && this.pages[id] === report.generation) {
          this.live = { ...this.live, [id]: { ...this.live[id], playingAudio: report.playing } };
          patches.push({ rev: ++this.rev, live: { upsert: [{ id, ...this.live[id] }], remove: [] } });
        }
      }
      if (name === "applyState") {
        assert.equal("live" in args[0], false, "live never enters applyState");
        if (args[0].tabs) {
          const remove = Object.keys(this.tabs).filter((id) => !args[0].tabs[id]);
          this.tabs = args[0].tabs;
          patches.push({ rev: ++this.rev, tabs: { upsert: Object.values(this.tabs), remove } });
        }
      }
    }
    return JSON.stringify({ rev: this.rev, patches });
  },
  catchUp() { return JSON.stringify({ rev: this.rev, patches: [] }); },
  flush: () => "saved",
  freeze: () => true,
  useSyncOrigins: () => true,
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { ...globalThis.acTestNativeModules, SolaraStoreAdapter: fake };

const { useBrowser } = await import("../../store/browser.ts");
const nativeStore = await import("../../store/nativeStore.ts");
const { fromSync } = await import("../../store/pinOrderChoices.ts");

function start() {
  assert.ok(nativeStore.startNativeStore().active);
  assert.ok(nativeStore.nativeOwnsWorkspace());
  nativeStore.hydrateFromNative(useBrowser);
  nativeStore.attachReplica(useBrowser);
  nativeStore.nativeWrite({ name: "pageReport", args: ["t-native", { type: "created", generation: "g", engine: "chromium", navigationSeq: null, contextRevision: 0, wasNewTab: false, newTabShownUrl: null }] });
  nativeStore.nativeWrite({ name: "pageReport", args: ["t-native", { type: "media", generation: "g", playing: true }] });
  assert.equal(useBrowser.getState().live["t-native"].playingAudio, true);
}

const proposal = () => ({ history: { ...useBrowser.getState().history, proposed: [{ url: "https://sync.test/", title: "Sync", visitedAt: 1 }] }, tabs: { ...useBrowser.getState().tabs, "t-sync": { ...nativeTab, id: "t-sync" } } });
test("WRITE-busy: busy mixed tabs and history exposes neither proposal and keeps native live", fixedBy("step 5"), () => {
  start();
  const before = useBrowser.getState();
  const seen = [];
  const stop = useBrowser.subscribe((s) => seen.push({ tabs: s.tabs, history: s.history, live: s.live }));
  fake.held = true;
  try {
    assert.throws(() => fromSync(() => nativeStore.writeState(useBrowser, proposal())), nativeStore.NativeStoreBusy);
    assert.equal(useBrowser.getState().history, before.history);
    assert.equal(useBrowser.getState().tabs, before.tabs);
    assert.equal(useBrowser.getState().live, before.live);
    assert.ok(seen.every((s) => s.tabs === before.tabs && s.history === before.history && s.live === before.live));
  } finally { stop(); fake.held = false; }
});

test("WRITE-order: local history follows accepted native tabs", fixedBy("step 5"), () => {
  start();
  const order = [];
  const dispatch = fake.dispatch;
  fake.dispatch = function (json) {
    const parsed = JSON.parse(json);
    const commands = [].concat(parsed.commands ?? parsed);
    const reply = dispatch.call(this, json);
    if (commands.some((c) => c.name === "applyState")) order.push("applyState");
    return reply;
  };
  const live = useBrowser.getState().live;
  const stop = useBrowser.subscribe((s, prev) => {
    if (s.tabs !== prev.tabs) order.push("tabs");
    if (s.history !== prev.history) {
      order.push("history");
      assert.ok(s.tabs["t-sync"], "local history has accepted native tabs");
    }
  });
  try {
    fromSync(() => nativeStore.writeState(useBrowser, proposal()));
    assert.ok(order.indexOf("history") > order.indexOf("tabs"), order.join(", "));
    assert.ok(order.indexOf("tabs") > order.indexOf("applyState"), order.join(", "));
    assert.equal(useBrowser.getState().live, live);
  } finally { stop(); fake.dispatch = dispatch; }
});
