import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const { createStore } = require("zustand/vanilla");
function load(name, modules, globals = {}) {
  const source = readFileSync(new URL(name, import.meta.url), "utf8");
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  new vm.Script(code).runInNewContext({ module, exports: module.exports, require: (id) => modules[id], ...globals });
  return module.exports;
}
function fixture(running = true) {
  const jobs = [];
  const sent = [];
  const identity = { tabId: "t", sessionGeneration: "G", registrationGeneration: 1 };
  let authority = identity;
  let generation = "G";
  let protectionKnown = true;
  let epoch = 0;
  let runnerListener = null;
  const browser = createStore(() => ({ tabs: { t: { id: "t", profileId: "p", windowId: "w" } }, live: {} }));
  const pages = createStore(() => ({ pages: { t: { fullscreen: false, crashed: null, unresponsive: false, mediaAccess: null, permission: null, newTabShown: null } } }));
  const media = createStore(() => ({ sessions: {}, pipOpen: {}, pip: {}, dismissed: {}, displayRequests: {}, tabShares: {} }));
  const toolbar = createStore(() => ({ scrolledDown: {} }));
  const events = load("./keepAliveFeed.ts", {});
  const producer = load("./nativeKeepAlive.ts", {
    "@solara/store": { isPageCurrent: (value) => value.sessionGeneration === authority.sessionGeneration && value.registrationGeneration === authority.registrationGeneration, nativePageFacts: () => ({ generation, protectionKnown }), pageReport: (id, report) => sent.push(JSON.parse(JSON.stringify({ id, ...report }))), registerKeepAliveRuntime: () => ++epoch, onTabSleepRunningChanged: (listener) => { runnerListener = listener; return () => {}; } },
    "../components/layout/pageState": { usePages: pages, pageOf: (id) => pages.getState().pages[id], patchPage: (id, patch) => pages.setState((s) => ({ pages: { ...s.pages, [id]: { ...s.pages[id], ...patch } } })) },
    "../components/layout/toolbarAutoHide": { useToolbarAutoHide: toolbar, revealToolbar: (id) => toolbar.setState((s) => ({ scrolledDown: Object.fromEntries(Object.entries(s.scrolledDown).filter(([key]) => key !== id)) })) },
    "../components/media/state": { useMedia: media },
    "../store/browser": { useBrowser: browser },
    "../store/nativeStore": { nativeTabSleepRunning: () => running },
    "../store/pageSession": { hasPage: () => true },
    "./keepAliveFeed": events,
    "./nativeEvents": { applyHeldReports: () => {} },
  }, { queueMicrotask: (run) => jobs.push(run) });
  producer.startNativeKeepAlive();
  const flush = () => { while (jobs.length) jobs.shift()(); };
  const page = (patch) => pages.setState((s) => ({ pages: { ...s.pages, t: { ...s.pages.t, ...patch } } }));
  return { producer, events, sent, identity, browser, pages, media, toolbar, flush, page, setProtectionKnown: (value) => { protectionKnown = value; }, epoch: () => epoch, setRunning: (value) => { running = value; runnerListener?.(value); }, replace: (next) => { authority = next; generation = next.sessionGeneration; events.keepAliveCreated(next, "rn"); } };
}

test("page and media subscriptions produce every typed keep fact and handled watermark", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  f.page({ permission: {}, fullscreen: true, crashed: {}, unresponsive: true, newTabShown: {} });
  f.media.setState({ sessions: { t: { playbackState: "paused" } }, pipOpen: { t: "video" }, displayRequests: { t: {} }, tabShares: { other: { capturedTabId: "t" } } });
  f.toolbar.setState({ scrolledDown: { t: true } });
  f.events.keepAliveHandled(f.identity, 4);
  f.flush();
  assert.deepEqual(f.sent.at(-1).keep, { capturing: true, newTabShown: true, pip: true, displayRequest: true, media: "present" });
  assert.deepEqual(f.sent.at(-1).reveal, { fullscreen: true, crashed: true, unresponsive: true, scrolledDown: true, sharing: true });
  assert.equal(f.sent.at(-1).handled, 4);
  f.media.setState({ sessions: { t: { playbackState: "playing" } } });
  f.flush();
  assert.equal(f.sent.at(-1).keep.media, "playing");
});

test("a shared-data profile move preserves every surviving session protection", () => {
  const f = fixture();
  f.browser.setState({ tabs: { t: { ...f.browser.getState().tabs.t, pinned: true } } });
  f.events.keepAliveCreated(f.identity, "pool");
  const displayRequest = { requestId: "pending-picker" };
  f.page({ mediaAccess: { microphone: true }, newTabShown: { url: "https://forward.test" } });
  f.media.setState({ sessions: { t: { playbackState: "paused" } }, pipOpen: { t: "video" }, displayRequests: { t: displayRequest }, tabShares: { other: { capturedTabId: "t" } } });
  f.events.keepAliveHandled(f.identity, 8);
  f.flush();
  f.browser.setState({ tabs: { t: { id: "t", pinned: true, profileId: "shared-data-profile", windowId: "w2" } } });
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent.at(-1).generation, "G");
  assert.equal(f.sent.at(-1).epoch, 1);
  assert.equal(f.sent.at(-1).handled, 8);
  assert.deepEqual(f.sent.at(-1).keep, { capturing: true, newTabShown: true, pip: true, displayRequest: true, media: "present" });
  assert.equal(f.sent.at(-1).reveal.sharing, true);
  assert.equal(f.media.getState().displayRequests.t, displayRequest);
});

test("discard and session replacement clear old transient facts before a full feed", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  f.page({ mediaAccess: { microphone: true }, permission: {} });
  f.media.setState({ sessions: { t: { playbackState: "playing" } }, pipOpen: { t: "video" }, displayRequests: { t: {} }, tabShares: { other: { capturedTabId: "t" } } });
  f.browser.setState({ live: { t: { discarded: true } } });
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.deepEqual(Object.keys(f.media.getState().tabShares), []);
  f.browser.setState({ live: {} });
  f.flush();
  assert.deepEqual(f.sent.at(-1).keep, { capturing: false, newTabShown: false, pip: false, displayRequest: false, media: "none" });
  f.page({ mediaAccess: { microphone: true } });
  f.replace({ ...f.identity, sessionGeneration: "new", registrationGeneration: 2 });
  f.flush();
  assert.equal(f.sent.at(-1).generation, "new");
  assert.equal(f.sent.at(-1).keep.capturing, false);
  assert.equal(f.epoch(), 2);
});

test("registration replacement and close clear the retired page's transient facts", () => {
  for (const transition of ["registration", "close"]) {
    const f = fixture();
    f.events.keepAliveCreated(f.identity, "rn");
    f.flush();
    f.page({ mediaAccess: { microphone: true }, permission: {}, newTabShown: {} });
    f.media.setState({ sessions: { t: { playbackState: "paused" } }, pipOpen: { t: "video" }, displayRequests: { t: {} }, tabShares: { other: { capturedTabId: "t" } } });
    if (transition === "registration") f.replace({ ...f.identity, registrationGeneration: 2 });
    else f.browser.setState({ tabs: {} });
    f.flush();
    assert.equal(f.pages.getState().pages.t.mediaAccess, null, transition);
    assert.equal(f.pages.getState().pages.t.permission, null, transition);
    assert.equal(f.pages.getState().pages.t.newTabShown, null, transition);
    assert.deepEqual(Object.keys(f.media.getState().sessions), [], transition);
    assert.deepEqual(Object.keys(f.media.getState().pipOpen), [], transition);
    assert.deepEqual(Object.keys(f.media.getState().displayRequests), [], transition);
    assert.deepEqual(Object.keys(f.media.getState().tabShares), [], transition);
    if (transition === "close") assert.equal(f.sent.length, 1);
    else assert.deepEqual(f.sent.at(-1).keep, { capturing: false, newTabShown: false, pip: false, displayRequest: false, media: "none" });
  }
});

test("closed and cross-profile pages cannot send queued old facts", () => {
  for (const close of [true, false]) {
    const f = fixture();
    f.events.keepAliveCreated(f.identity, "pool");
    f.flush();
    f.page({ mediaAccess: { microphone: true } });
    if (close) f.browser.setState({ tabs: {} });
    else {
      f.replace({ ...f.identity, sessionGeneration: "other", registrationGeneration: 2 });
      f.browser.setState({ tabs: { t: { id: "t", profileId: "other", windowId: "w2" } } });
    }
    f.flush();
    assert.equal(f.sent.filter((report) => report.generation === "G").length, 1);
  }
});

test("runner off creates no epoch, subscribes to no facts and emits no feed", () => {
  const f = fixture(false);
  f.events.keepAliveCreated(f.identity, "rn");
  f.page({ mediaAccess: {} });
  f.flush();
  assert.equal(f.epoch(), 0);
  assert.equal(f.sent.length, 0);
});

test("reload survivors cannot publish empty facts after a later stamped status event", () => {
  const f = fixture();
  f.setProtectionKnown(false);
  f.events.keepAliveCreated(f.identity, "pool");
  f.flush();
  f.events.keepAliveHandled(f.identity, 9);
  f.flush();
  assert.equal(f.sent.length, 0);
  f.events.keepAliveCreated(f.identity, "pool");
  f.events.keepAliveHandled(f.identity, 10);
  f.flush();
  assert.equal(f.sent.length, 0);
  f.setProtectionKnown(true);
  f.replace({ ...f.identity, sessionGeneration: "next", registrationGeneration: 2 });
  f.events.keepAliveHandled({ ...f.identity, sessionGeneration: "next", registrationGeneration: 2 }, 1);
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.equal(f.sent[0].generation, "next");
  assert.equal(f.sent[0].handled, 1);
});

test("a runner that turns on after launch starts the feed, and turning it off stops sending", () => {
  const f = fixture(false);
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  assert.equal(f.sent.length, 0);
  f.setRunning(true);
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  assert.equal(f.epoch(), 1);
  assert.equal(f.sent.length, 1);
  f.setRunning(false);
  f.page({ mediaAccess: {} });
  f.flush();
  assert.equal(f.sent.length, 1);
  f.setRunning(true);
  f.flush();
  assert.equal(f.epoch(), 2);
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent[1].keep.capturing, true);
});

test("cold-launch pages publish protective facts held before feed registration", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "pool");
  f.media.setState({ sessions: { t: { playbackState: "paused" } } });
  f.events.keepAliveHandled(f.identity, 8);
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.equal(f.sent[0].keep.media, "present");
  assert.equal(f.sent[0].handled, 8);
});
