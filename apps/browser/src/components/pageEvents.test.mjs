import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const source = read("./pageEvents.ts");
const webViewSource = read("../../../../packages/solaracore/src/WebView.tsx");
const holdSource = read("../lib/nativeEvents.ts");
const pooledSource = read("./pooledPages.ts");
const lifecycleSource = read("../lib/tabLifecycle.ts");
const sleepPolicySource = read("../lib/tabSleepPolicy.ts");
const settle = () => new Promise((resolve) => setImmediate(resolve));
const navigation = (url = "https://a.test/", more = {}) => ({ url, title: url, isLoading: false, canGoBack: true, canGoForward: false, themeColor: null, ...more });

function harness({ owned = true, pooled = false, finishAccepted = true } = {}) {
  const calls = [];
  const page = { wasNewTab: true, newTabShown: null, backToNewTab: false, popups: [], status: "" };
  const state = { profiles: { p: {} }, peeks: {}, tabs: { t: { id: "t", url: "https://a.test/", title: "A", profileId: "p", windowId: "w", muted: true, navigation: { seq: 1, url: "https://a.test/" } }, other: { profileId: "p" } }, live: { t: { isLoading: false, canGoBack: true, discarded: false } }, windows: { w: { id: "w", profileId: "p", tabIds: ["t", "other"], activeTabIds: { p: "t" } } } };
  for (const name of ["updateTab", "updateLive", "navigated", "closeTab", "activate", "setFind", "faviconChanged"]) state[name] = (...args) => {
    calls.push({ name, args });
    if (name === "updateTab") Object.assign(state.tabs.t, args[1]);
    if (name === "updateLive") Object.assign(state.live.t, args[1]);
    if (name === "navigated") { Object.assign(state.tabs.t, args[1]); Object.assign(state.live.t, args[2]); }
  };
  const identity = { tabId: "t", sessionGeneration: "G", registrationGeneration: 1 };
  let authority = identity;
  const current = (candidate) => candidate.tabId === authority.tabId && candidate.sessionGeneration === authority.sessionGeneration && candidate.registrationGeneration === authority.registrationGeneration;
  let preview = null;
  let finishCount = 0;
  let handlers;
  const storeAPI = {
    isPageCurrent: current,
    updatePageContext: (candidate, context) => { calls.push({ name: "context", args: [candidate, context] }); return current(candidate); },
    pageReport: (tabId, report) => {
      calls.push({ name: "pageReport", args: [tabId, report] });
      if (report.type !== "issued") return {};
      const guard = { sessionGeneration: report.generation, navigation: report.navigation, contextRevision: report.contextRevision, modelSerial: 1, startedEarly: false, sameProfileMove: false };
      preview = { actions: [...(report.newTabShownUrl ? [{ type: "clearNewTabShown" }] : []), ...(report.navigation ? [{ type: "load", url: report.navigation.url, userInitiated: false }] : [])], guard };
      return { result: preview };
    },
    finishRNPageIssue: async (tabId, guard) => {
      finishCount++;
      calls.push({ name: "finish", args: [tabId, guard] });
      if (finishAccepted instanceof Error) throw finishAccepted;
      if (!finishAccepted) return { accepted: false };
      for (const action of preview.actions) {
        if (action.type === "clearNewTabShown") { calls.push({ name: "nativeClear", args: [] }); handlers.onPageIssue({ ...identity, accepted: true, clearNewTabShown: true, contextRevision: guard.contextRevision, navigation: guard.navigation }); }
        else calls.push({ name: "nativeLoad", args: [action.url] });
      }
      return { accepted: true };
    },
  };
  const globals = {};
  const modules = {};
  const spy = (name) => (...args) => calls.push({ name, args });
  const noop = () => {};
  const sideEffects = new Proxy({}, { get: (_, name) => spy(String(name)) });
  const webviews = new Map([["t", { loadUrl: spy("jsLoad"), setMuted: spy("setMuted") }]]);
  const useBrowser = Object.assign((selector) => selector(state), { getState: () => state, subscribe: () => noop });
  const mocks = {
    "@solara/core": { toAppUrl: (url) => url.replace(/^chrome:/, "solara:"), toEngineUrl: (url) => url },
    "expo-modules-core": { requireNativeViewManager: () => noop, requireOptionalNativeModule: () => ({ isPageCurrent: (tabId, sessionGeneration, registrationGeneration) => current({ tabId, sessionGeneration, registrationGeneration }) }) },
    react: { forwardRef: (fn) => fn },
    "react/jsx-runtime": { jsx: noop },
    "react-native": {},
    "@solara/store": storeAPI,
    "../store/nativeStore": { nativeOwnsWorkspace: () => owned, nativeTabSleepRunning: () => false },
    "../store/browser": { useBrowser },
    "../store/model": { activeTabId: () => "t", engineProfile: (id) => id, isIncognitoProfile: () => false, navigationTo: (url) => ({ seq: 2, url }) },
    "../store/peek": { peekTabId: () => null },
    zustand: { create: () => (initializer) => {
      const store = require("zustand/vanilla").createStore(initializer);
      return Object.assign((selector) => selector(store.getState()), store);
    } },
    "../store/splits": { splitOf: () => undefined },
    "../lib/native": { isQuitting: () => false },
    "../lib/launchLook": { restoredThemeColor: (_id, _url, color) => color },
    "../lib/earlyNavigate": { takeStartedNavigation: () => false },
    "../lib/pageHandoff": { handoffLoaded: () => false },
    "../lib/webviews": { noteIssued: spy("noteIssued"), notePooledPage: spy("notePooledPage"), webviewRef: () => spy("registerHandle"), webviews },
    "./webviews": { webviews },
    "./layout/pageState": { pageOf: () => page, patchPage: (_id, patch) => { calls.push({ name: "patchPage", args: [patch] }); Object.assign(page, patch); }, setBrowserId: spy("browserId"), setPopover: spy("popover"), usePages: { getState: () => ({ popover: {} }) } },
  };
  function load(name, contents) {
    if (modules[name]) return modules[name];
    const module = { exports: {} };
    modules[name] = module.exports;
    const code = ts.transpileModule(contents, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
    new vm.Script(code, { filename: name }).runInNewContext({ exports: module.exports, module, require: (id) => mocks[id] ?? sideEffects, queueMicrotask, globalThis: globals, console });
    return module.exports;
  }
  const webView = load("WebView", webViewSource);
  mocks["@solara/solaracore"] = { ...webView, releaseProfile: spy("releaseProfile") };
  mocks["./tabSleepPolicy"] = load("tabSleepPolicy", sleepPolicySource);
  const lifecycle = load("tabLifecycle", lifecycleSource);
  mocks["../lib/tabLifecycle"] = lifecycle;
  const events = load("pageEvents", source);
  const session = events.newPageSession("t", "chromium", undefined, null);
  handlers = events.pageEventHandlers(session);
  if (owned) events.observePageIdentity(session, identity, pooled ? "native" : "js");
  const props = { transferKey: "t", acceptStoreReport: (report) => events.acceptPageReport(session, report), onStoreEventHandled: (report) => events.notePageEventHandled(session, report), ...handlers };
  const report = { kind: "reserved", sessionGeneration: "G", registrationGeneration: 1 };
  const emit = (name, payload, disposition = owned ? report : { kind: "fallback" }) => webView.deliverWebViewEvent(props, name, { ...payload, storeReport: disposition });
  const nativeEvents = load("nativeEvents", holdSource);
  const held = [];
  const hold = nativeEvents.createHold({ batch: (run) => run(), schedule: (run) => held.push(run), report: (error) => { throw error; } });
  mocks["./pageEvents"] = events;
  mocks["../lib/nativeEvents"] = nativeEvents;
  globals.__acHoldReport = hold.hold;
  const startPool = () => {
    let listener;
    const pool = { addListener: (_name, callback) => { listener = callback; return { remove: noop }; }, pageCall: async () => undefined };
    const stop = load("pooledPages", pooledSource).startPooledPages(pool);
    return { emit: (event) => listener(event), stop };
  };
  calls.length = 0;
  return { calls, state, page, events, session, handlers, webView, props, identity, report, emit, hold, startPool, lifecycle, webviews, setAuthority: (value) => { authority = value; }, finishes: () => finishCount };
}

const semantics = (calls) => calls.filter(({ name }) => ["updateTab", "updateLive", "navigated", "closeTab"].includes(name));

test("RN reservation skips only fact forwarding", () => {
  const h = harness();
  h.emit("onNavigationChange", navigation());
  h.emit("onMedia", { playing: true, muted: false });
  h.emit("onReady", { browserId: 12, tabId: 34 });
  h.emit("onFavicon", { url: "icon", urls: [] });
  h.emit("onStatus", { text: "status" });
  h.emit("onPasswordPrompt", { origin: "https://a.test/" });
  assert.deepEqual(semantics(h.calls), []);
  for (const name of ["setMuted", "browserId", "faviconChanged", "showPasswordPrompt"]) assert.ok(h.calls.some((call) => call.name === name), name);
  assert.equal(h.page.status, "status");
});

test("RN native facts still issue one load and UI callbacks", async () => {
  const h = harness();
  h.events.followNavigation(h.session, h.state.tabs.t.navigation);
  await settle();
  h.emit("onNavigationChange", navigation("https://b.test/"));
  h.emit("onNavigationChange", navigation("https://c.test/"));
  assert.equal(h.calls.filter(({ name }) => name === "nativeLoad").length, 1);
  assert.equal(h.calls.filter(({ name }) => name === "jsLoad").length, 0);
  assert.ok(h.calls.some(({ name }) => name === "dismissPermissions"));
});

test("pooled native facts issue no JS load or semantic writes", async () => {
  const h = harness({ pooled: true });
  h.events.followNavigation(h.session, h.state.tabs.t.navigation);
  for (const [name, payload] of [["onNavigationChange", navigation()], ["onMedia", { playing: true }], ["onDownloadNavigation", { url: "https://a.test/file", committedUrl: "https://a.test/", skipped: false }], ["onDiscarded", { url: "https://a.test/" }]]) h.events.deliverPageEvent(h.session, name, payload, h.identity);
  await settle();
  assert.deepEqual(semantics(h.calls), []);
  assert.equal(h.calls.filter(({ name }) => ["jsLoad", "finish", "pageReport"].includes(name)).length, 0);
  assert.equal(h.page.backToNewTab, false);
  assert.equal(h.state.live.t.discarded, false);
});

test("delayed A handler cannot revert native B", () => {
  const h = harness();
  h.state.tabs.t.url = "https://b.test/";
  h.state.tabs.t.title = "B";
  h.state.live.t.isLoading = false;
  h.hold.hold(() => h.emit("onNavigationChange", navigation("https://a.test/", { isLoading: true })));
  h.hold.flush();
  assert.equal(h.state.tabs.t.url, "https://b.test/");
  assert.equal(h.state.tabs.t.title, "B");
  assert.equal(h.state.live.t.isLoading, false);
});

test("old generation event cannot affect replacement UI", () => {
  const h = harness();
  const staleEvents = [
    ["onNavigationChange", navigation("https://old.test/")],
    ["onFavicon", { url: "old-icon", urls: [] }],
    ["onMedia", { playing: true, muted: false }],
    ["onReady", { browserId: 99 }],
    ["onPasswordPrompt", { origin: "https://old.test/" }],
    ["onStatus", { text: "old" }],
    ["onDiscarded", { url: "https://old.test/" }],
  ];
  const staleHandlers = staleEvents.map(([name, payload]) => () => h.emit(name, payload));
  for (const invokeOld of staleHandlers) h.hold.hold(invokeOld);
  h.setAuthority({ tabId: "t", sessionGeneration: "H", registrationGeneration: 2 });
  for (const invokeOld of staleHandlers) invokeOld();
  h.hold.flush();
  assert.deepEqual(h.calls, []);
  assert.equal(h.page.status, "");
  assert.equal(h.events.deliverPageEvent(h.session, "onStatus", { text: "old" }, h.identity), false);
  const fresh = { tabId: "t", sessionGeneration: "H", registrationGeneration: 2 };
  h.handlers.onPageCreated({ ...fresh, generation: "H" });
  h.calls.length = 0;
  const freshReport = { kind: "reserved", sessionGeneration: "H", registrationGeneration: 2 };
  h.emit("onStatus", { text: "new" }, freshReport);
  h.emit("onReady", { browserId: 12 }, freshReport);
  h.emit("onFavicon", { url: "fresh-icon", urls: [] }, freshReport);
  h.emit("onPasswordPrompt", { origin: "https://new.test/" }, freshReport);
  h.emit("onMedia", { playing: true, muted: false }, freshReport);
  h.emit("onDiscarded", { url: "https://new.test/" }, freshReport);
  assert.equal(h.page.status, "");
  assert.equal(h.calls.filter(({ name }) => name === "browserId").length, 1);
  assert.equal(h.calls.filter(({ name }) => name === "faviconChanged").length, 1);
  assert.equal(h.calls.filter(({ name }) => name === "showPasswordPrompt").length, 1);
  assert.equal(h.calls.filter(({ name }) => name === "setMuted").length, 2);
  assert.deepEqual(semantics(h.calls), []);
});

test("rejected ready and discarded envelopes drop before scalar conversion", () => {
  const h = harness();
  for (const [name, scalar] of [["onReady", "browserId"], ["onDiscarded", "url"]]) {
    const payload = { storeReport: { kind: "rejected" } };
    Object.defineProperty(payload, scalar, { get() { throw new Error("decoded rejected scalar"); } });
    assert.equal(h.webView.deliverWebViewEvent(h.props, name, payload), false);
  }
  assert.deepEqual(h.calls, []);
});

test("same-session stale registration drops before UI", () => {
  const h = harness();
  h.setAuthority({ ...h.identity, registrationGeneration: 2 });
  assert.equal(h.emit("onStatus", { text: "old registration" }), false);
  assert.equal(h.page.status, "");
});

test("fallback JS facts still work", () => {
  const h = harness({ owned: false });
  h.emit("onNavigationChange", navigation());
  h.emit("onMedia", { playing: true, muted: false });
  assert.ok(h.calls.some(({ name }) => name === "navigated"));
  assert.ok(h.calls.some(({ name }) => name === "updateLive"));
  h.events.followNavigation(h.session, h.state.tabs.t.navigation);
  assert.equal(h.calls.filter(({ name }) => name === "jsLoad").length, 1);
});

test("New Tab same URL clears before RN load", async () => {
  const h = harness();
  h.page.newTabShown = { url: "https://a.test/", title: "A" };
  h.events.publishPageContext("t");
  h.state.tabs.t.navigation = { seq: 2, url: "https://a.test/" };
  h.events.followNavigation(h.session, h.state.tabs.t.navigation);
  await settle();
  const names = h.calls.map(({ name }) => name);
  assert.ok(names.indexOf("context") < names.indexOf("pageReport"));
  assert.ok(names.indexOf("nativeClear") < names.indexOf("nativeLoad"));
  assert.equal(h.page.newTabShown, null);
  assert.equal(h.calls.find(({ name }) => name === "pageReport").args[1].newTabShownUrl, "https://a.test/");
});

test("pooled New Tab same URL ignores delayed context props", () => {
  const h = harness({ pooled: true });
  const oldProps = h.events.currentPageContext("t");
  h.page.newTabShown = { url: "https://a.test/", title: "A" };
  const shown = h.events.publishPageContext("t");
  assert.ok(shown.contextRevision > oldProps.contextRevision);
  assert.equal(shown.navigationSeq, oldProps.navigationSeq);
  assert.equal(h.calls.at(-1).args[1].newTabShownUrl, "https://a.test/");
  h.page.newTabShown = null;
  const hidden = h.events.publishPageContext("t");
  assert.ok(hidden.contextRevision > shown.contextRevision);
  assert.equal(hidden.newTabShownUrl, null);
});

test("delayed native clear A preserves newer overlay B in the same session", () => {
  const h = harness();
  h.page.newTabShown = { url: "https://a.test/", title: "A" };
  const consumed = h.events.publishPageContext("t");
  const issue = { ...h.identity, accepted: true, clearNewTabShown: true, contextRevision: consumed.contextRevision, navigation: { ...h.state.tabs.t.navigation } };
  h.hold.hold(() => h.emit("onPageIssue", issue));
  h.page.newTabShown = { url: "https://b.test/", title: "B" };
  const newer = h.events.publishPageContext("t");
  h.hold.flush();
  assert.equal(h.page.newTabShown.url, "https://b.test/");
  h.handlers.onPageIssue({ ...issue, contextRevision: newer.contextRevision });
  assert.equal(h.page.newTabShown, null);
});

test("native clear requires consumed context and exact navigation", () => {
  for (const navigation of [null, { seq: 2, url: "https://a.test/" }, { seq: 1, url: "https://other.test/" }, { seq: 1, url: "https://a.test/", userInitiated: true }]) {
    const h = harness();
    h.page.newTabShown = { url: "https://a.test/", title: "A" };
    const context = h.events.publishPageContext("t");
    h.handlers.onPageIssue({ ...h.identity, clearNewTabShown: true, contextRevision: context.contextRevision, navigation });
    assert.equal(h.page.newTabShown.url, "https://a.test/");
    h.handlers.onPageIssue({ ...h.identity, clearNewTabShown: true });
    assert.equal(h.page.newTabShown.url, "https://a.test/");
  }
});

test("native clear matches a null navigation without clearing a reopened overlay", () => {
  const h = harness({ pooled: true });
  h.state.tabs.t.navigation = null;
  h.page.newTabShown = { url: "https://a.test/", title: "A" };
  const consumed = h.events.publishPageContext("t");
  const issue = { ...h.identity, clearNewTabShown: true, contextRevision: consumed.contextRevision, navigation: null };
  h.events.deliverPageEvent(h.session, "onPageIssue", issue, h.identity);
  assert.equal(h.page.newTabShown, null);
  h.events.publishPageContext("t");
  h.page.newTabShown = { url: "https://a.test/", title: "A reopened" };
  h.events.deliverPageEvent(h.session, "onPageIssue", issue, h.identity);
  assert.equal(h.page.newTabShown.title, "A reopened");
});

test("sleeping consumers follow native live facts and retain JS fallback", () => {
  const native = harness();
  native.lifecycle.noteDiscarded("t");
  assert.equal(native.lifecycle.useIsSleeping("t"), false);
  native.state.live.t.discarded = true;
  assert.equal(native.lifecycle.useIsSleeping("t"), true);
  native.state.live.t.discarded = false;
  assert.equal(native.lifecycle.useIsSleeping("t"), false);
  const fallback = harness({ owned: false });
  fallback.state.live.t.discarded = true;
  assert.equal(fallback.lifecycle.useIsSleeping("t"), false);
  fallback.lifecycle.noteDiscarded("t");
  assert.equal(fallback.lifecycle.useIsSleeping("t"), true);
});

test("native ready preserves profile release bookkeeping without changing discarded facts", async () => {
  const h = harness();
  h.state.live.t.discarded = true;
  h.lifecycle.noteDiscarded("t");
  h.emit("onReady", { browserId: 12 });
  assert.equal(h.state.live.t.discarded, true);
  assert.equal(h.lifecycle.useLifecycle.getState().discarded.t, true);
  assert.deepEqual(semantics(h.calls), []);
  h.webviews.clear();
  h.state.windows = {};
  h.lifecycle.releaseUnusedProfiles();
  assert.equal(h.calls.filter(({ name, args }) => name === "releaseProfile" && args[0] === "p").length, 1);
  h.lifecycle.releaseUnusedProfiles();
  assert.equal(h.calls.filter(({ name }) => name === "releaseProfile").length, 1);
});

test("failed RN finalization retries once and handles rejection", async () => {
  const h = harness({ finishAccepted: new Error("gone") });
  h.events.followNavigation(h.session, h.state.tabs.t.navigation);
  await settle();
  await settle();
  assert.equal(h.finishes(), 2);
  assert.equal(h.session.following, false);
  assert.equal(h.calls.filter(({ name }) => name === "jsLoad" || name === "nativeClear").length, 0);
});

test("RN context prop setters do not attach before the complete prop batch", () => {
  for (const path of ["../../../../packages/solaracore/ios/CefModule.swift", "../../../../packages/solaracore/ios/WebKitModule.swift"]) {
    const contents = read(path);
    assert.match(contents, /Prop\("pageContext"\).*view\.pageContext = context \?\? \[:\]/);
    assert.match(contents, /func propsDidUpdate\(\) \{\s+propsReady = true\s+syncAttachment\(\)/);
    assert.match(contents, /context: pageContext, previous: attachment/);
    assert.ok(contents.indexOf("attachment = RNPageEventTap.attach") < contents.indexOf("RNPageEventTap.start(attachment:"));
  }
});


test("unowned native store cannot enable the native pool", () => {
  const contents = read("../../../../packages/settings/ios/TabPool/TabPoolHost.swift");
  assert.match(contents, /nonisolated static var available: Bool[^}]+NativeStoreHandle\.opened[^}]+NativeStoreHandle\.ownedWorkspaceAtLaunch/);
});

test("pooled reload seeds the native context revision clock", () => {
  const h = harness({ pooled: true });
  h.events.observePageIdentity(h.session, h.identity, "native", 40);
  const context = h.events.publishPageContext("t");
  assert.equal(context.contextRevision, 41);
  assert.equal(h.calls.at(-1).args[1].contextRevision, 41);
});

test("owned pooled events cannot fall back to missing identity", () => {
  const h = harness({ pooled: true });
  const pool = h.startPool();
  const created = { ...h.identity, generation: "G", contextRevision: 3, name: "onPageCreated", payload: { engine: "chromium", seq: 1 } };
  pool.emit(created);
  h.calls.length = 0;
  pool.emit({ tabId: "t", name: "onPageCreated", payload: { engine: "chromium", seq: 1 } });
  pool.emit({ tabId: "t", name: "onPageGone", payload: {} });
  assert.deepEqual(h.calls, []);
  pool.emit({ ...created, name: "onStatus", payload: { text: "current" } });
  h.hold.flush();
  assert.equal(h.page.status, "current");
  pool.stop();
});

test("every refused pooled page call is logged with its command and code", async () => {
  const h = harness({ pooled: true });
  const warnings = [];
  const warn = console.warn;
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    const refusals = { showDevTools: { code: "ERR_NO_PAGE", message: "The pooled page registration is no longer current" }, evaluate: { code: "ERR_PAGE_VALUE", message: "Invalid page arguments" } };
    const handle = h.webView.pooledWebViewHandle(async (method) => {
      if (refusals[method]) throw Object.assign(new Error(refusals[method].message), refusals[method]);
      return "ok";
    });
    assert.equal(await handle.showDevTools(), undefined);
    await assert.rejects(handle.evaluate("1"), { code: "ERR_PAGE_VALUE" });
    assert.equal(await handle.executeJavaScript("1"), "ok");
    assert.deepEqual(warnings, [
      "[pool] showDevTools refused: ERR_NO_PAGE (The pooled page registration is no longer current)",
      "[pool] evaluate refused: ERR_PAGE_VALUE (Invalid page arguments)",
    ]);
  } finally {
    console.warn = warn;
  }
});
test("sleep eligibility forwards the optional pin waiver as its first boolean argument", async () => {
  const h = harness();
  const calls = [];
  const handle = h.webView.pooledWebViewHandle(async (method, args) => {
    calls.push([method, [...args]]);
    return "refused";
  });
  assert.equal(await handle.sleepIfEligible(), "refused");
  assert.equal(await handle.sleepIfEligible({ waivingPinned: true }), "refused");
  assert.deepEqual(calls, [["sleepIfEligible", [false]], ["sleepIfEligible", [true]]]);
});


test("RN acknowledges the native event stamp after its UI facts handler", () => {
  const h = harness();
  h.emit("onMediaAccess", { camera: true, microphone: false, screen: false }, { ...h.report, eventSeq: 7 });
  const patched = h.calls.findIndex((call) => call.name === "patchPage");
  const handled = h.calls.findIndex((call) => call.name === "keepAliveHandled");
  assert.ok(patched >= 0);
  assert.ok(handled > patched);
  assert.equal(h.calls[handled].args[1], 7);
  const count = h.calls.filter((call) => call.name === "keepAliveHandled").length;
  h.emit("onMediaAccess", { camera: false, microphone: false, screen: false }, { ...h.report, registrationGeneration: 99, eventSeq: 8 });
  assert.equal(h.calls.filter((call) => call.name === "keepAliveHandled").length, count);
});

test("pooled created acknowledges its own stamp and requests a complete feed", () => {
  const h = harness({ pooled: true });
  const pool = h.startPool();
  pool.emit({ ...h.identity, name: "onPageCreated", payload: { engine: "chromium", seq: 1 }, eventSeq: 12 });
  const created = h.calls.findIndex((call) => call.name === "keepAliveCreated");
  const handled = h.calls.findIndex((call) => call.name === "keepAliveHandled");
  assert.ok(created >= 0);
  assert.ok(handled > created);
  assert.equal(h.calls[handled].args[1], 12);
  pool.stop();
});


test("a throwing UI handler marks the session protective before a later event can acknowledge it", () => {
  const h = harness();
  h.state.updateTab = () => { throw new Error("UI failure"); };
  assert.throws(() => h.emit("onZoom", { zoom: 1.5 }, { ...h.report, eventSeq: 5 }), /UI failure/);
  assert.equal(h.calls.filter((call) => call.name === "keepAliveFailed").length, 1);
  assert.equal(h.calls.filter((call) => call.name === "keepAliveHandled").length, 0);
});


test("a replacement identity begins its feed session before an early media event updates UI facts", () => {
  const h = harness();
  const next = { ...h.identity, sessionGeneration: "next", registrationGeneration: 2 };
  h.setAuthority(next);
  h.calls.length = 0;
  h.emit("onMediaAccess", { camera: true, microphone: false, screen: false }, { kind: "reserved", sessionGeneration: "next", registrationGeneration: 2, eventSeq: 1 });
  const created = h.calls.findIndex((call) => call.name === "keepAliveCreated");
  const patched = h.calls.findIndex((call) => call.name === "patchPage");
  assert.ok(created >= 0);
  assert.ok(patched > created);
  assert.equal(h.page.mediaAccess.camera, true);
  h.emit("onPageCreated", { ...next, generation: "next" }, { kind: "reserved", sessionGeneration: "next", registrationGeneration: 2 });
  assert.equal(h.page.mediaAccess.camera, true);
  assert.equal(h.calls.filter((call) => call.name === "keepAliveCreated").length, 2);
});


test("a same-identity pool created resend preserves handled feed authority", () => {
  const h = harness({ pooled: true });
  const pool = h.startPool();
  const created = { ...h.identity, name: "onPageCreated", payload: { engine: "chromium", seq: 1 } };
  pool.emit(created);
  h.calls.length = 0;
  pool.emit(created);
  assert.equal(h.calls.filter((call) => call.name === "keepAliveGone").length, 0);
  assert.ok(h.calls.some((call) => call.name === "keepAliveCreated"));
  pool.stop();
});
