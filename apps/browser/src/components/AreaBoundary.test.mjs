import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";
import { transformFileSync } from "@babel/core";

const componentURL = new URL("./AreaBoundary.tsx", import.meta.url).href;
const fixture = globalThis.areaRecoveryTest = {};
globalThis.__DEV__ = true;
const fake = source => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const SolaraHostedView = "HostedView"; export const onHostedEvent = (kind, windowId, listener) => { globalThis.areaRecoveryTest.listener = listener; return () => { globalThis.areaRecoveryTest.stopped = true; }; };`,
  react: `export class Component { constructor(props) { this.props = props; } setState(value) { Object.assign(this.state, typeof value === "function" ? value(this.state) : value); } } export const Fragment = "Fragment"; export const useEffect = fn => { globalThis.areaRecoveryTest.cleanup = fn(); }; export const useState = initial => [typeof initial === "function" ? initial() : initial === false ? true : initial, next => globalThis.areaRecoveryTest.height = next];`,
  "../lib/jsErrors": `export const recordJsError = (...args) => globalThis.areaRecoveryTest.errors.push(args);`,
  "../lib/theme": `export const ThemeScope = "ThemeScope"; export const useTheme = () => { if (globalThis.areaRecoveryTest.themeError) throw new Error("theme unavailable"); return globalThis.areaRecoveryTest.theme; };`,
  "../store/hooks": `export const WindowContext = { Provider: "WindowContext" };`,
};
const hooks = registerHooks({ resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); } });
const { AreaBoundary, AreaErrorRow, NativeAreaRecovery, PlainFallback } = await import("./AreaBoundary.tsx");
after(() => { hooks.deregister(); delete globalThis.areaRecoveryTest; delete globalThis.acAreaRecovery; globalThis.__DEV__ = false; });
beforeEach(() => Object.assign(fixture, { theme: { textPrimary: "ink", textSecondary: "dim" }, themeError: false, errors: [], reloads: 0, stopped: false, height: null }));

test("the recovery adapter compiles with the app's Babel configuration", () => {
  const result = transformFileSync(new URL("./AreaBoundary.tsx", import.meta.url).pathname, { configFile: new URL("../../babel.config.js", import.meta.url).pathname });
  assert.ok(result.code.includes("areaRecovery"));
});

test("area boundaries preserve children and suppress quiet or retrying recovery", () => {
  const boundary = new AreaBoundary({ area: "sidebar", windowId: "w1", children: "child" });
  assert.equal(boundary.render().props.children, "child");
  boundary.state.error = new Error("failed");
  assert.equal(boundary.render(), null);
  boundary.state.retries = 2;
  const recovery = boundary.render();
  assert.equal(recovery.type, PlainFallback);
  assert.equal(recovery.props.windowId, "w1");
  assert.equal(recovery.props.fill, false);
  boundary.props.quiet = true;
  assert.equal(boundary.render(), null);
});

test("sidebar recovery retains its inherited window identity", () => {
  const boundary = new AreaBoundary({ area: "sidebar", children: "child" });
  boundary.context = "w2";
  boundary.state.error = new Error("failed");
  boundary.state.retries = 2;
  assert.equal(boundary.render().props.windowId, "w2");
});

test("native recovery receives the same theme, detail, text layout and Reload action", () => {
  const error = new Error("failure");
  const row = AreaErrorRow({ fill: true, windowId: "w1", detail: error, onReload: () => fixture.reloads++ });
  assert.equal(row.type, NativeAreaRecovery);
  assert.equal(row.props.textPrimary, "ink");
  assert.equal(row.props.textSecondary, "dim");
  const host = NativeAreaRecovery(row.props);
  const state = JSON.parse(host.props.state);
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "areaRecovery");
  assert.deepEqual(host.props.style, { flex: 1 });
  assert.equal(state.fill, true);
  assert.match(state.detail, /^failure\n\nError: failure/);
  fixture.listener("reload", { recoveryId: "stale" });
  assert.equal(fixture.reloads, 0);
  fixture.listener("reload", { recoveryId: state.recoveryId });
  assert.equal(fixture.reloads, 1);
  fixture.listener("height", { recoveryId: state.recoveryId, height: 70 });
  assert.equal(fixture.height, 70);
  fixture.listener("height", { recoveryId: state.recoveryId, height: Infinity });
  assert.equal(fixture.height, 70);
  fixture.cleanup();
  assert.equal(fixture.stopped, true);
});

test("the plain fallback is native and independent of the failing theme", () => {
  fixture.themeError = true;
  const fallback = new PlainFallback({ fill: false, windowId: "w1", children: "row", onReload() {} });
  assert.equal(fallback.render(), "row");
  fallback.state.failed = true;
  const row = fallback.render();
  assert.equal(row.type, NativeAreaRecovery);
  assert.equal(row.props.plain, true);
  assert.equal(row.props.textPrimary, "#8e8e93");
  const host = NativeAreaRecovery(row.props);
  assert.deepEqual(host.props.style, { height: 38 });
  assert.equal(JSON.parse(host.props.state).detail, undefined);
});

test("the Debug failure fixture enters the real retry path and Reload removes the fixture", () => {
  const boundary = new AreaBoundary({ area: "sidebar", windowId: "w1", children: "child" });
  boundary.componentDidMount();
  assert.equal(globalThis.acAreaRecovery.fail("sidebar", "w1"), 1);
  const thrown = boundary.render().props.children;
  assert.throws(() => thrown.type(thrown.props), /Forced area recovery fixture/);
  boundary.state.error = new Error("failed");
  boundary.state.retries = 2;
  boundary.render().props.onReload();
  assert.equal(boundary.state.retries, 0);
  assert.equal(boundary.render().props.children, "child");
  boundary.componentWillUnmount();
  assert.equal(globalThis.acAreaRecovery.fail("sidebar", "w1"), 0);
});
