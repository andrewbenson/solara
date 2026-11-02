import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, test } from "node:test";

const appURL = new URL("./appIntegration.ts", import.meta.url).href;
const f = globalThis.appIntegrationTest = {
  state: { live: {} }, subscriptions: [], loading: [], native: [], startup: [], help: [], notifications: [], offers: [],
};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `
    const f = globalThis.appIntegrationTest;
    export const hostedKinds = () => ["onboarding"];
    export const nativeAppIntegrationCommand = async (command, windowId) => {
      f.native.push([command, windowId]);
      await new Promise((resolve) => { f.resolveNative = resolve; });
    };
    export const onAppIntegrationPresentation = (fn) => { f.presentation = fn; };
    export const startNativeAppStartup = async (options) => {
      f.options = options;
      return await new Promise((resolve) => { f.resolveStartup = resolve; });
    };
    export const completeNativeAppStartup = async () => { f.startup.push("complete"); };
    export const nativeAppIntegrationFirstWindow = async (active) => { f.offers.push(active); };
    export const nativeAppIntegrationNotification = async (response) => { f.notifications.push(response); };
  `,
  "@solara/shell": `
    const f = globalThis.appIntegrationTest;
    export const onNotificationResponse = (fn) => { f.notification = fn; };
    export const setScriptLoading = async (ids) => { f.loading.push(ids); };
  `,
  "../components/onboarding/state": `
    const f = globalThis.appIntegrationTest;
    export const startOnboarding = (id) => { f.help.push(["onboarding", id]); };
    export const resumeOnboarding = (saved) => { f.startup.push(["resume", saved]); f.active = true; };
    export const useOnboarding = { getState: () => ({ windowId: f.active ? "w" : null }) };
  `,
  "../components/onboarding/tour/state": `export const startToolTour = async (id) => { globalThis.appIntegrationTest.help.push(["tool", id]); };`,
  "../components/ntp/releaseNotes": `
    export const releaseNotesVersions = () => ["1.0"];
    export const applyPendingReleaseNotes = (pending) => { globalThis.appIntegrationTest.startup.push(["pending", pending]); };
  `,
  "../store/browser": `export const useBrowser = { getState: () => globalThis.appIntegrationTest.state, subscribe: (fn) => { globalThis.appIntegrationTest.subscriptions.push(fn); } };`,
  "../store/model": `export const resolveWindowId = () => "w";`,
  "../store/nativeStore": `export const nativeSafeMode = () => true;`,
  "./persistLatch": `export const persistenceRefused = () => true;`,
  "./actions": `export const openUrls = (urls, id) => { globalThis.appIntegrationTest.help.push(["urls", urls, id]); };`,
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === appURL && specifier in sources) return fake(sources[specifier]);
    return next(specifier, context);
  },
});
globalThis.__DEV__ = true;
const integration = await import("./appIntegration.ts");
after(() => { hooks.deregister(); delete globalThis.appIntegrationTest; delete globalThis.__DEV__; });

test("native launch guards and presentation finish before the first-window offer", async () => {
  integration.startScriptLoading();
  integration.startAppIntegrationPresentation();
  integration.startAppIntegrationPresentation();
  assert.equal("startAppIntegration" in integration, false);
  assert.deepEqual(f.options, { development: true, persistenceRefused: true, safeMode: true, hostedOnboarding: true, releaseNotesVersions: ["1.0"] });
  assert.deepEqual(f.loading, [[]]);
  assert.equal(f.subscriptions.length, 1);
  const offered = integration.offerNativeDefaultBrowserAfterFirstWindow();
  await Promise.resolve();
  assert.deepEqual(f.offers, []);
  f.resolveStartup({ pendingJSON: '{"version":"1.0","since":1}', onboarding: "resume", savedJSON: '{"startedAt":1,"step":"tabs"}' });
  await offered;
  assert.deepEqual(f.startup, [["pending", { version: "1.0", since: 1 }], ["resume", { startedAt: 1, step: "tabs" }], "complete"]);
  assert.deepEqual(f.offers, [true]);
});

test("native presentation retains onboarding, tour and unowned URL effects", () => {
  f.presentation({ action: "showOnboarding", windowId: "w" });
  f.presentation({ action: "toolTour", windowId: "w" });
  f.presentation({ action: "openURL", windowId: "w", url: "https://example.com" });
  assert.deepEqual(f.help, [["onboarding", "w"], ["tool", "w"], ["urls", ["https://example.com"], "w"]]);
});

test("generic Hub responses reach Swift", () => {
  const click = { id: "other", action: "click", tabId: "t", windowId: "w" };
  f.notification(click);
  assert.deepEqual(f.notifications, [click]);
});

test("loading coalesces for 100 ms, reads the latest live state, and deduplicates", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const change = (live) => {
    const prev = f.state;
    f.state = { ...prev, live };
    f.subscriptions[0](f.state, prev);
  };
  change({ a: { isLoading: true } });
  t.mock.timers.tick(50);
  change({ a: { isLoading: true }, b: { isLoading: false } });
  t.mock.timers.tick(49);
  assert.deepEqual(f.loading, [[]]);
  t.mock.timers.tick(1);
  assert.deepEqual(f.loading, [[], ["a"]]);
  change({ a: { isLoading: true }, b: { isLoading: false } });
  t.mock.timers.tick(100);
  assert.deepEqual(f.loading, [[], ["a"]]);
  change({});
  t.mock.timers.tick(100);
  assert.deepEqual(f.loading, [[], ["a"], []]);
});

test("the feedback export awaits Swift for check-in callers", async () => {
  let finished = false;
  const pending = integration.sendFeedback("w").then(() => { finished = true; });
  assert.deepEqual(f.native, [["sendFeedback", "w"]]);
  await Promise.resolve();
  assert.equal(finished, false);
  f.resolveNative();
  await pending;
  assert.equal(finished, true);
});
