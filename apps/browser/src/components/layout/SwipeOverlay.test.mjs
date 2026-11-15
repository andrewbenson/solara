import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = readFileSync(new URL("./SwipeOverlay.tsx", import.meta.url), "utf8");
const motion = await import("./swipeMotion.ts");
const plain = (value) => JSON.parse(JSON.stringify(value));

function harness(inShell = false, nativeLayout = false) {
  const h = { messages: [], navigation: [], effects: [], timers: new Map(), nextTimer: 0, time: 0, cells: [], cursor: 0, history: [{ title: "Two", url: "https://two.invalid", key: "two", offset: -1 }, { title: "One", url: "https://one.invalid", key: "one", offset: -2 }] };
  const state = { tabs: { a: { profileId: "work" } }, history: { work: [{ url: "https://two.invalid", favicon: "two.png" }] } };
  const useBrowser = Object.assign((fn) => fn(state), { getState: () => state });
  const cell = (initial) => {
    const index = h.cursor++;
    if (!(index in h.cells)) h.cells[index] = typeof initial === "function" ? initial() : initial;
    return [h.cells[index], (next) => { h.cells[index] = typeof next === "function" ? next(h.cells[index]) : next; }];
  };
  class Value {
    constructor(value) { this.value = value; }
    stopAnimation() {}
    setValue(value) { this.value = value; }
    interpolate() { return this; }
  }
  const animation = { start(done) { done?.({ finished: true }); } };
  const animated = { Value, View: "AnimatedView", add() {}, multiply() {}, spring() { return animation; }, timing() { return animation; }, parallel() { return animation; } };
  const mocks = {
    react: { memo: (fn) => fn, useState: cell, useRef: (value) => cell(() => ({ current: value }))[0], useEffect: (fn) => h.effects.push(fn), useMemo: (fn) => fn() },
    "react/jsx-runtime": { Fragment: "Fragment", jsx: (type, props) => ({ type, props }), jsxs: (type, props) => ({ type, props }) },
    "react-native": { Animated: animated, Easing: { bezier() {}, in() {}, ease() {} }, Image: { resolveAssetSource: () => ({ uri: "fixture://mark" }) }, StyleSheet: { absoluteFill: { position: "absolute" } }, View: "View", Text: "Text" },
    "@solara/solaracore": { SwipeArea: "SwipeArea", swipeHaptic() {} },
    "@solara/settings": { SolaraHostedView: "HostedView", windowShellActive: () => inShell, windowNativeLayout: () => nativeLayout, sendPaneSwipe: (...args) => h.messages.push(args) },
    "@solara/shell": { Surface: "Surface", Symbol: "Symbol", VisualEffect: "VisualEffect" },
    "../../lib/theme": { useTheme: () => ({ dark: false, textPrimary: "#111111", textSecondary: "#777777" }) },
    "../../store/browser": { useBrowser },
    "../primitives": { Favicon: "Favicon", NewTabIcon: "NewTabIcon", NEW_TAB_MARK: 42 },
    "./HistoryPopover": { HistoryPopover: "HistoryPopover" },
    "./history": { useHistoryAvailability: () => ({ back: true, forward: true }), historyItems: () => h.historyPromise ?? Promise.resolve(h.history), goBack: (tab) => h.navigation.push(["back", tab]), goForward: (tab) => h.navigation.push(["forward", tab]), goToHistoryItem: (...args) => h.navigation.push(["item", ...args]) },
    "./swipeMotion": motion,
    "./nativeLayoutFeed": { NativeLayoutFeed: class {}, useNativeLayoutFeed() {} },
    "./pageState": { usePage: (tabId, select) => select({ newTabShown: null, backToNewTab: false, engineBack: null }) },
  };
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  const clock = {
    setTimeout(fn, delay) { const id = ++h.nextTimer; h.timers.set(id, { fn, at: h.time + delay }); return id; },
    clearTimeout(id) { h.timers.delete(id); },
  };
  new vm.Script(code).runInNewContext({ exports: module.exports, module, require: (id) => mocks[id] ?? {}, __DEV__: false, ...clock });
  h.render = (nativeAllowed = true) => { h.cursor = 0; const element = module.exports.SwipeOverlay({ tabId: "a", windowId: "little", nativeAllowed }); return element.type(element.props); };
  h.swipe = (phase, distance = 0, dy = 0) => h.render().props.children[0].props.onSwipe({ phase, direction: "back", distance, dy });
  h.layout = () => h.render().props.children[0].props.onLayout({ nativeEvent: { layout: { width: 800, height: 600 } } });
  h.advance = async (milliseconds) => {
    h.time += milliseconds;
    for (const [id, entry] of h.timers) if (entry.at <= h.time) { h.timers.delete(id); entry.fn(); }
    await new Promise((resolve) => setImmediate(resolve));
  };
  return h;
}

test("Little Solara mounts the existing native capsule without RN drawing", () => {
  const h = harness();
  const children = h.render().props.children;
  const host = children.find((child) => child?.props?.kind === "swipeCapsule");
  assert.ok(host);
  assert.equal(host.props.windowId, "little");
  assert.deepEqual(JSON.parse(host.props.state), { tabId: "a", newTabMark: "fixture://mark" });
  assert.equal(host.props.pointerEvents, "none");
  assert.ok(children.every((child) => !child || ["SwipeArea", "HostedView", "View"].includes(child.type)));
});

test("swipes send native show, threshold and offset mapping on small windows", () => {
  const h = harness();
  h.layout();
  h.swipe("began");
  h.swipe("changed", 100);
  const messages = plain(h.messages);
  assert.equal(messages[0][0], "little");
  assert.equal(messages[0][1], "a");
  assert.deepEqual(messages[0][2], { op: "show", direction: "back", theme: { dark: false, textPrimary: "#111111", textSecondary: "#777777" }, profileId: "work", newTabMark: "fixture://mark" });
  assert.ok(messages.some(([, , message]) => message.op === "confirm" && message.confirmed));
  assert.ok(messages.some(([, , message]) => message.op === "move" && message.x === motion.capsuleOffset(100 / 75, 82)));
});

test("the destination list waits 300ms, preserves favicons and ends on its selected item", async () => {
  const h = harness();
  h.layout();
  h.swipe("began");
  h.swipe("changed", 100);
  await h.advance(299);
  assert.equal(h.messages.some(([, , message]) => message.op === "list"), false);
  await h.advance(1);
  const message = h.messages.find(([, , value]) => value.op === "list")?.[2];
  assert.ok(message);
  assert.deepEqual(plain(message.items), h.history.map((item) => ({ title: item.title, url: item.url, favicon: item.key === "two" ? "two.png" : null, newTab: false })));
  assert.equal(h.render().props.children[0].props.allowsVerticalMotion, true);
  h.swipe("changed", 100, 75);
  h.swipe("ended", 100, 75);
  assert.deepEqual(plain(h.navigation), [["item", "a", h.history[1]]]);
});

test("cancelling prevents a late list and discrete swipes preserve the 120ms dismiss delay", async () => {
  const h = harness();
  h.layout();
  h.swipe("began");
  h.swipe("changed", 100);
  h.swipe("cancelled", 100);
  await h.advance(400);
  assert.deepEqual(h.navigation, []);
  assert.equal(h.messages.some(([, , value]) => value.op === "list"), false);
  h.swipe("swipe");
  assert.deepEqual(plain(h.navigation), [["back", "a"]]);
  assert.deepEqual(plain(h.messages.at(-1)[2]), { op: "dismiss", delay: 0.12 });
});

test("browser shell uses its native overlay container without a second hosted capsule", () => {
  const h = harness(true);
  const children = h.render().props.children;
  assert.equal(children.some((child) => child?.props?.kind === "swipeCapsule"), false);
  assert.ok(children.some((child) => child?.type === "View"));
});

test("an unmounted gesture cannot deliver a delayed destination list to its replacement", async () => {
  const h = harness();
  let resolveHistory;
  h.historyPromise = new Promise((resolve) => { resolveHistory = resolve; });
  h.layout();
  h.swipe("began");
  h.swipe("changed", 100);
  await h.advance(300);
  h.effects[0]()();
  resolveHistory(h.history);
  await h.advance(1);
  assert.equal(h.messages.some(([, , message]) => message.op === "list"), false);
  assert.deepEqual(plain(h.messages.at(-1)[2]), { op: "dismiss", delay: 0 });
});


test("native layout keeps only a headless history compatibility feed", () => {
  const h = harness(true, true);
  assert.equal(h.render(), null);
  assert.deepEqual(h.messages, []);
  assert.deepEqual(h.navigation, []);
});
