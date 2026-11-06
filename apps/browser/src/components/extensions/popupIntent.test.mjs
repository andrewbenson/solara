import assert from "node:assert/strict";
import { test } from "node:test";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "../../lib/actions" && context.parentURL?.endsWith("/components/extensions/state.ts"))
      return { url: "data:text/javascript,export const openWindow = () => {};", shortCircuit: true };
    return next(specifier, context);
  },
});

const shown = [];
const closed = [];
globalThis.acTestNativeModules = {
  SolaraToolbar: {
    showExtensionPopup: async (json) => { shown.push(JSON.parse(json)); return true; },
    closeExtensionPopup: async (windowId) => { closed.push(windowId); },
  },
};

const native = await import("../../test-native/index.ts");
const { useBrowser } = await import("../../store/browser.ts");
const liveBrowserSubscribers = new Set();
const subscribeBrowser = useBrowser.subscribe;
useBrowser.subscribe = (listener) => {
  const unsubscribe = subscribeBrowser(listener);
  const handle = {};
  liveBrowserSubscribers.add(handle);
  return () => { liveBrowserSubscribers.delete(handle); unsubscribe(); };
};
const { usePages } = await import("../layout/pageState.ts");
const { webviews } = await import("../../lib/webviews.ts");
const { useExtensions } = await import("./store.ts");
const { activateExtension, closeExtensionPopup, extensionPopupChanged, openActionPopup } = await import("./state.ts");

const EXT = { id: "ext", name: "Ext", enabled: true, pinned: true, hasAction: true, incognito: false, popup: "popup.html" };
const ANCHOR = { x: 700, y: 20, width: 24, height: 24 };
const S = () => useBrowser.getState();

function setup() {
  closeExtensionPopup();
  useExtensions.setState({ popup: null });
  S().hydrate({});
  const windowId = S().createWindow({ url: "a.com" });
  const tabId = S().windows[windowId].tabIds[0];
  usePages.setState({ browsers: { 1: tabId } });
  useExtensions.setState({ lists: { "": [EXT] }, actions: {}, popup: null });
  webviews.clear();
  shown.length = 0;
  closed.length = 0;
  return { windowId, tabId };
}

function delayedAction(tabId) {
  let answer;
  webviews.set(tabId, { executeExtensionAction: () => new Promise((resolve) => { answer = resolve; }) });
  return () => answer("popup");
}

test("a second click while the extension action is pending keeps the popup closed", async () => {
  const { windowId, tabId } = setup();
  const answer = delayedAction(tabId);
  const opening = activateExtension(windowId, EXT, ANCHOR, { popup: "chrome-extension://ext/popup.html" });
  await activateExtension(windowId, EXT, ANCHOR);
  answer();
  await opening;
  assert.equal(shown.length, 0);
  assert.deepEqual(closed, [null]);
});

test("a tab switch and return cannot revive an earlier popup action", async () => {
  const { windowId, tabId } = setup();
  const other = S().newTab(windowId, { url: "b.com", background: true });
  const answer = delayedAction(tabId);
  const opening = activateExtension(windowId, EXT, ANCHOR, { popup: "chrome-extension://ext/popup.html" });
  S().activate(other);
  S().activate(tabId);
  answer();
  await opening;
  assert.equal(shown.length, 0);
  assert.deepEqual(closed, [windowId]);
});

test("closing while action.openPopup resolves prevents a late native show", async () => {
  const { windowId } = setup();
  let answer;
  native.extensionAnswers.actionStates = () => new Promise((resolve) => { answer = resolve; });
  const opening = openActionPopup(windowId, EXT.id, ANCHOR, 1);
  closeExtensionPopup(windowId);
  answer({ ext: { popup: "chrome-extension://ext/popup.html" } });
  await opening;
  assert.equal(shown.length, 0);
});

test("native owns visibility while JS sends the popup intent and dismissal", async () => {
  const { windowId, tabId } = setup();
  await activateExtension(windowId, EXT, ANCHOR);
  assert.deepEqual(shown, [{ extensionId: "ext", popupUrl: "chrome-extension://ext/popup.html", profile: "", tabId, windowId, anchor: ANCHOR, requiresActive: false }]);
  assert.equal(useExtensions.getState().popup, null);
  extensionPopupChanged({ windowId, extensionId: "ext", tabId });
  S().navigate(tabId, "c.com");
  assert.deepEqual(closed, [windowId]);
  extensionPopupChanged({ windowId, extensionId: null });
  assert.equal(useExtensions.getState().popup, null);
});

test("replacing a tab with equal navigation keeps its extension popup open", async () => {
  const { windowId, tabId } = setup();
  await activateExtension(windowId, EXT, ANCHOR);
  extensionPopupChanged({ windowId, extensionId: "ext", tabId });
  useBrowser.setState((s) => ({ tabs: { ...s.tabs, [tabId]: {
    ...s.tabs[tabId],
    title: "Updated title",
    favicon: "https://a.com/icon.png",
    navigation: { ...s.tabs[tabId].navigation },
  } } }));
  assert.deepEqual(closed, []);
  assert.deepEqual(useExtensions.getState().popup, { windowId, extensionId: "ext", tabId });
});

test("a new navigation sequence at the same URL dismisses its extension popup", () => {
  const { windowId, tabId } = setup();
  extensionPopupChanged({ windowId, extensionId: "ext", tabId });
  useBrowser.setState((s) => ({ tabs: { ...s.tabs, [tabId]: {
    ...s.tabs[tabId],
    navigation: { ...s.tabs[tabId].navigation, seq: s.tabs[tabId].navigation.seq + 1 },
  } } }));
  assert.deepEqual(closed, [windowId]);
});

test("Little Solara does not request an extension popup", async () => {
  const { windowId } = setup();
  useBrowser.setState((s) => ({ windows: { ...s.windows, [windowId]: { ...s.windows[windowId], kind: "small" } } }));
  await activateExtension(windowId, EXT, ANCHOR);
  await openActionPopup(windowId, EXT.id, ANCHOR, 1);
  assert.equal(shown.length, 0);
});

for (const reason of ["replacement", "dismissal"]) {
  test(`an earlier popup's native close event with reason ${reason} ${reason === "replacement" ? "preserves" : "cancels"} the next action`, async () => {
    const { windowId, tabId } = setup();
    extensionPopupChanged({ windowId, extensionId: "previous", tabId });
    let answer;
    native.extensionAnswers.actionStates = () => new Promise((resolve) => { answer = resolve; });
    const opening = openActionPopup(windowId, EXT.id, ANCHOR, 1);
    extensionPopupChanged({ windowId, extensionId: null, reason });
    assert.equal(useExtensions.getState().popup, null);
    answer({ ext: { popup: "chrome-extension://ext/popup.html" } });
    await opening;
    assert.equal(shown.length, reason === "replacement" ? 1 : 0);
    if (reason === "replacement") assert.equal(shown[0].extensionId, "ext");
  });
}

test("an openPopup event from a tab switched away before handling cannot open over the new tab", async () => {
  const { windowId } = setup();
  S().newTab(windowId, { url: "b.com" });
  native.extensionAnswers.actionStates = () => ({ ext: { popup: "chrome-extension://ext/popup.html" } });
  await openActionPopup(windowId, EXT.id, ANCHOR, 1);
  assert.equal(shown.length, 0);
});

test("an openPopup reply cannot open after its source tab switches away", async () => {
  const { windowId } = setup();
  let answer;
  native.extensionAnswers.actionStates = () => new Promise((resolve) => { answer = resolve; });
  const opening = openActionPopup(windowId, EXT.id, ANCHOR, 1);
  S().newTab(windowId, { url: "b.com" });
  answer({ ext: { popup: "chrome-extension://ext/popup.html" } });
  await opening;
  assert.equal(shown.length, 0);
});

test("an extension's own openPopup asks native to require an active app and key window", async () => {
  const { windowId } = setup();
  native.extensionAnswers.actionStates = async () => ({ ext: { popup: "chrome-extension://ext/popup.html" } });
  await openActionPopup(windowId, EXT.id, ANCHOR, 1);
  assert.equal(shown.length, 1);
  assert.equal(shown[0].requiresActive, true);
});

test("another window's native dismissal keeps a pending popup request", async () => {
  const { windowId } = setup();
  const otherWindowId = S().createWindow({ url: "b.com" });
  let answer;
  native.extensionAnswers.actionStates = () => new Promise((resolve) => { answer = resolve; });
  const opening = openActionPopup(windowId, EXT.id, ANCHOR, 1);
  extensionPopupChanged({ windowId: otherWindowId, extensionId: null, reason: "dismissal" });
  answer({ ext: { popup: "chrome-extension://ext/popup.html" } });
  await opening;
  assert.equal(shown.length, 1);
});

for (const source of ["missing", "otherWindow", "inactive"]) {
  test(`an openPopup event with ${source} source does not replace a valid pending request`, async () => {
    const { windowId } = setup();
    const otherWindowId = S().createWindow({ url: "b.com" });
    const otherTabId = S().windows[otherWindowId].tabIds[0];
    const inactiveTabId = S().newTab(windowId, { url: "c.com", background: true });
    usePages.setState((p) => ({ browsers: { ...p.browsers, 2: otherTabId, 3: inactiveTabId } }));
    let answer;
    native.extensionAnswers.actionStates = () => new Promise((resolve) => { answer = resolve; });
    const opening = openActionPopup(windowId, EXT.id, ANCHOR, 1);
    native.extensionAnswers.actionStates = () => ({ stale: { popup: "chrome-extension://stale/popup.html" } });
    await openActionPopup(windowId, "stale", ANCHOR, { missing: 99, otherWindow: 2, inactive: 3 }[source]);
    answer({ ext: { popup: "chrome-extension://ext/popup.html" } });
    await opening;
    assert.equal(shown.length, 1);
    assert.equal(shown[0].extensionId, "ext");
  });
}

test("a rejected extension action does not swallow the next popup click", async () => {
  const { windowId, tabId } = setup();
  webviews.set(tabId, { executeExtensionAction: async () => { throw new Error("page closed"); } });
  await assert.rejects(activateExtension(windowId, EXT, ANCHOR), /page closed/);
  webviews.clear();
  await activateExtension(windowId, EXT, ANCHOR);
  assert.equal(shown.length, 1);
});

test("the popup's tab watch subscribes to the browser store only while a popup is pending or shown", async () => {
  const { windowId, tabId } = setup();
  const idle = liveBrowserSubscribers.size;
  const answer = delayedAction(tabId);
  const opening = activateExtension(windowId, EXT, ANCHOR, { popup: "chrome-extension://ext/popup.html" });
  assert.equal(liveBrowserSubscribers.size, idle + 1);
  answer();
  await opening;
  extensionPopupChanged({ windowId, extensionId: "ext", tabId });
  assert.equal(liveBrowserSubscribers.size, idle + 1);
  S().navigate(tabId, "c.com");
  assert.deepEqual(closed, [windowId]);
  extensionPopupChanged({ windowId, extensionId: null });
  assert.equal(liveBrowserSubscribers.size, idle);
  S().navigate(tabId, "d.com");
  assert.deepEqual(closed, [windowId]);
});
