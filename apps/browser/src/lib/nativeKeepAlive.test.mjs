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
  const followBrowser = browser.subscribe;
  let browserListeners = 0;
  browser.subscribe = (listener) => { browserListeners++; return followBrowser(listener); };
  const pages = createStore(() => ({ pages: { t: { fullscreen: false, crashed: null, unresponsive: false, mediaAccess: null, permission: null, newTabShown: null } } }));
  const followPages = pages.subscribe;
  let pagesListeners = 0;
  const media = createStore(() => ({ sessions: {}, pipOpen: {}, pip: {}, dismissed: {}, displayRequests: {}, tabShares: {} }));
  const toolbar = createStore(() => ({ scrolledDown: {} }));
  let listeners = 0;
  for (const store of [pages, media, toolbar]) {
    const subscribe = store.subscribe;
    store.subscribe = (listener) => {
      listeners += 1;
      if (store === pages) pagesListeners += 1;
      const stop = subscribe(listener);
      let stopped = false;
      return () => { if (!stopped) { stopped = true; listeners -= 1; stop(); } };
    };
  }
  const timers = [];
  const nativeReads = [];
  const events = load("./keepAliveFeed.ts", {});
  const producer = load("./nativeKeepAlive.ts", {
    "@solara/store": { isPageCurrent: (value) => { nativeReads.push(["current", value.tabId]); return value.sessionGeneration === authority.sessionGeneration && value.registrationGeneration === authority.registrationGeneration; }, nativePageFacts: (id) => { nativeReads.push(["facts", id]); return { generation, protectionKnown }; }, pageReport: (id, report) => sent.push(JSON.parse(JSON.stringify({ id, ...report }))), registerKeepAliveRuntime: () => ++epoch, onTabSleepRunningChanged: (listener) => { runnerListener = listener; return () => {}; } },
    "../components/layout/pageState": { usePages: pages, pageOf: (id) => pages.getState().pages[id], patchPage: (id, patch) => pages.setState((s) => ({ pages: { ...s.pages, [id]: { ...s.pages[id], ...patch } } })) },
    "../components/layout/toolbarAutoHide": { useToolbarAutoHide: toolbar, revealToolbar: (id) => toolbar.setState((s) => ({ scrolledDown: Object.fromEntries(Object.entries(s.scrolledDown).filter(([key]) => key !== id)) })) },
    "../components/media/state": { useMedia: media },
    "../store/browser": { useBrowser: browser },
    "../store/nativeStore": { nativeTabSleepRunning: () => running },
    "../store/pageSession": { hasPage: () => true },
    "./keepAliveFeed": events,
    "./nativeEvents": { applyHeldReports: () => {} },
  }, { queueMicrotask: (run) => jobs.push(run), setTimeout: (run, ms) => { const timer = { run, ms, live: true }; timers.push(timer); return timer; }, clearTimeout: (timer) => { if (timer) timer.live = false; } });
  producer.startNativeKeepAlive();
  const producerListeners = browserListeners;
  followBrowser((s, prev) => producer.keepAliveBrowserChanged(s, prev));
  followPages((s, prev) => producer.keepAlivePagesChanged(s, prev));
  const flush = () => { while (jobs.length) jobs.shift()(); };
  const page = (patch) => pages.setState((s) => ({ pages: { ...s.pages, t: { ...s.pages.t, ...patch } } }));
  const pendingTimers = () => timers.filter((timer) => timer.live);
  const fire = () => { const due = pendingTimers(); for (const timer of due) { timer.live = false; timer.run(); } return due.map((timer) => timer.ms); };
  return { jobs, nativeReads, pagesListeners: () => pagesListeners, listeners: () => listeners, pendingTimers, fire, producerListeners, producer, events, sent, identity, browser, pages, media, toolbar, flush, page, setProtectionKnown: (value) => { protectionKnown = value; }, epoch: () => epoch, setRunning: (value) => { running = value; runnerListener?.(value); }, replace: (next) => { authority = next; generation = next.sessionGeneration; events.keepAliveCreated(next, "rn"); } };
}

test("a tracked tab edit with unchanged keepalive facts performs no native validation", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "pool");
  f.flush();
  assert.deepEqual(f.nativeReads, [["current", "t"], ["facts", "t"]]);
  f.nativeReads.length = 0;
  f.browser.setState((s) => ({ tabs: { ...s.tabs, t: { ...s.tabs.t, title: "new title" } } }));
  f.flush();
  assert.deepEqual(f.nativeReads, []);
  assert.equal(f.sent.length, 1);
});

test("changing one page's protection avoids native reads for unchanged tracked pages", () => {
  const f = fixture();
  f.browser.setState((s) => ({ tabs: { ...s.tabs, other: { id: "other", profileId: "p", windowId: "w" } } }));
  f.pages.setState((s) => ({ pages: { ...s.pages, other: { ...s.pages.t } } }));
  f.events.keepAliveCreated(f.identity, "pool");
  f.events.keepAliveCreated({ ...f.identity, tabId: "other" }, "pool");
  f.flush();
  assert.equal(f.sent.length, 2);
  f.nativeReads.length = 0;
  f.page({ permission: { kind: "camera" } });
  f.events.keepAliveHandled(f.identity, 8);
  f.flush();
  assert.deepEqual(f.nativeReads, [["current", "t"], ["facts", "t"]]);
  assert.equal(f.sent.length, 3);
  assert.equal(f.sent.at(-1).id, "t");
  assert.equal(f.sent.at(-1).keep.capturing, true);
  assert.equal(f.sent.at(-1).handled, 8);
});

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

test("the feed adds no browser-store listener and follows the store through tab lifecycle's", () => {
  const f = fixture();
  assert.equal(f.producerListeners, 0);
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  f.browser.setState({ tabs: { t: { id: "t", profileId: "p", windowId: "w2" } } });
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent.at(-1).generation, "G");
});

test("the feed adds no pages-store listener and follows the store through the extension bridge's", () => {
  for (const running of [true, false]) {
    const f = fixture(running);
    assert.equal(f.pagesListeners(), 0);
    f.events.keepAliveCreated(f.identity, "rn");
    f.flush();
    assert.equal(f.pagesListeners(), 0);
    if (!running) f.setRunning(true);
    f.flush();
    assert.equal(f.pagesListeners(), 0);
    const before = f.sent.length;
    f.page({ permission: {} });
    assert.equal(f.jobs.length, 1);
    f.flush();
    assert.equal(f.sent.length, before + 1);
    assert.equal(f.sent.at(-1).keep.capturing, true);
    f.browser.setState({ tabs: {} });
    f.flush();
    assert.equal(f.pagesListeners(), 0);
  }
});

test("updates for untracked tabs or untracked fields queue no flush", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  const before = f.sent.length;
  f.browser.setState((s) => ({ tabs: { ...s.tabs, other: { id: "other", profileId: "p", windowId: "w" } }, live: { ...s.live, other: { discarded: true } } }));
  f.pages.setState((s) => ({ pages: { ...s.pages, other: { fullscreen: true }, t: { ...s.pages.t, title: "renamed" } } }));
  f.media.setState({ sessions: { other: { playbackState: "playing" } }, pipOpen: { other: "video" } });
  f.toolbar.setState({ scrolledDown: { other: true } });
  assert.equal(f.jobs.length, 0);
  f.flush();
  assert.equal(f.sent.length, before);
});

test("each tracked keep and reveal input queues one flush and reaches native", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  const inputs = [
    [() => f.page({ mediaAccess: {} }), (r) => r.keep.capturing],
    [() => f.page({ newTabShown: {} }), (r) => r.keep.newTabShown],
    [() => f.page({ fullscreen: true }), (r) => r.reveal.fullscreen],
    [() => f.page({ crashed: {} }), (r) => r.reveal.crashed],
    [() => f.page({ unresponsive: true }), (r) => r.reveal.unresponsive],
    [() => f.media.setState({ sessions: { t: { playbackState: "playing" } } }), (r) => r.keep.media === "playing"],
    [() => f.media.setState({ pipOpen: { t: "video" } }), (r) => r.keep.pip],
    [() => f.media.setState({ displayRequests: { t: {} } }), (r) => r.keep.displayRequest],
    [() => f.media.setState({ tabShares: { other: { capturedTabId: "t" } } }), (r) => r.reveal.sharing],
    [() => f.toolbar.setState({ scrolledDown: { t: true } }), (r) => r.reveal.scrolledDown],
  ];
  for (const [change, holds] of inputs) {
    change();
    assert.equal(f.jobs.length, 1);
    f.flush();
    assert.ok(holds(f.sent.at(-1)), String(change));
  }
});

test("a tracked tab's move and discard still reach the feed", () => {
  const f = fixture();
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  const before = f.sent.length;
  f.browser.setState((s) => ({ tabs: { ...s.tabs, t: { ...s.tabs.t, windowId: "w2" } } }));
  assert.equal(f.jobs.length, 1);
  f.flush();
  assert.equal(f.sent.length, before + 1);
  f.browser.setState((s) => ({ live: { ...s.live, t: { discarded: true } } }));
  assert.equal(f.jobs.length, 1);
});

test("protection that becomes known without any store update reaches native on the pending retry, and the retry stops", () => {
  const f = fixture();
  f.setProtectionKnown(false);
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  assert.equal(f.sent.length, 0);
  assert.deepEqual(f.pendingTimers().map((timer) => timer.ms), [1000]);
  assert.deepEqual(f.fire(), [1000]);
  f.flush();
  assert.equal(f.sent.length, 0);
  assert.deepEqual(f.pendingTimers().map((timer) => timer.ms), [2000]);
  f.setProtectionKnown(true);
  f.fire();
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.equal(f.pendingTimers().length, 0);
});

test("a retry backed off behind a stale page restarts at one second for a new page", () => {
  const f = fixture();
  f.setProtectionKnown(false);
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  for (let i = 0; i < 6; i++) { f.fire(); f.flush(); }
  assert.deepEqual(f.pendingTimers().map((timer) => timer.ms), [30000]);
  f.replace({ tabId: "t", sessionGeneration: "G2", registrationGeneration: 1 });
  f.flush();
  assert.deepEqual(f.pendingTimers().map((timer) => timer.ms), [1000]);
});

test("no listeners before the first page, and none after the last page closes", () => {
  const f = fixture();
  f.flush();
  assert.equal(f.listeners(), 0);
  f.browser.setState((s) => ({ live: { ...s.live, x: {} } }));
  assert.equal(f.jobs.length, 0);
  f.events.keepAliveCreated(f.identity, "rn");
  assert.equal(f.listeners(), 2);
  f.flush();
  f.browser.setState({ tabs: {} });
  assert.equal(f.listeners(), 0);
  f.flush();
  f.pages.setState({ pages: {} });
  f.media.setState({ sessions: { t: { playbackState: "playing" } } });
  assert.equal(f.jobs.length, 0);
});

test("a protect flip on a tracked tab queues its flush in the same turn, ahead of later noise, and the flush carries the protection", () => {
  const protects = [
    [() => f.page({ mediaAccess: { camera: true } }), (r) => r.keep.capturing],
    [() => f.page({ permission: {} }), (r) => r.keep.capturing],
    [() => f.page({ newTabShown: {} }), (r) => r.keep.newTabShown],
    [() => f.media.setState({ sessions: { t: { playbackState: "playing" } } }), (r) => r.keep.media === "playing"],
    [() => f.media.setState({ sessions: { t: { playbackState: "paused" } } }), (r) => r.keep.media === "present"],
    [() => f.media.setState({ pipOpen: { t: "video" } }), (r) => r.keep.pip],
    [() => f.media.setState({ displayRequests: { t: {} } }), (r) => r.keep.displayRequest],
  ];
  let f;
  for (const [flip, protects_] of protects) {
    f = fixture();
    f.events.keepAliveCreated(f.identity, "rn");
    f.events.keepAliveHandled(f.identity, 3);
    f.flush();
    const handled = f.sent.at(-1).handled;
    flip();
    assert.equal(f.jobs.length, 1, String(flip));
    f.browser.setState((s) => ({ tabs: { ...s.tabs, other: { id: "other", profileId: "p", windowId: "w" } } }));
    f.toolbar.setState({ scrolledDown: { other: true } });
    assert.equal(f.jobs.length, 1, String(flip));
    f.flush();
    const report = f.sent.at(-1);
    assert.ok(protects_(report), String(flip));
    assert.ok(report.handled >= handled);
  }
});

test("a page that stays pending settles at the slowest retry, and turning the runner off stops the retry", () => {
  const f = fixture();
  f.setProtectionKnown(false);
  f.events.keepAliveCreated(f.identity, "rn");
  f.flush();
  const delays = [];
  for (let i = 0; i < 8; i++) { delays.push(...f.fire()); f.flush(); }
  assert.deepEqual(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
  f.setRunning(false);
  f.flush();
  assert.equal(f.pendingTimers().length, 0);
});
