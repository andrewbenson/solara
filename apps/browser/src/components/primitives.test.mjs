import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./primitives.tsx", import.meta.url).href;
const f = globalThis.faviconHostTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/core": `export const displayHost = value => value.replace("xn--test.invalid", "éxample.invalid");`,
  "@solara/settings": `export const SolaraHostedView = "HostedView"; export const onHostedEvent = (kind,window,callback) => { globalThis.faviconHostTest.listener = callback; return () => {}; };`,
  "@solara/shell": `export const Symbol = "Symbol";`,
  react: `export const memo = fn => fn; export const useState = value => [typeof value === "function" ? value() : value, value => globalThis.faviconHostTest.broken = value]; export const useRef = value => ({current:value}); export const useLayoutEffect = fn => fn();`,
  "react-native": `export const Image = {resolveAssetSource:value=>({uri:"asset:"+value})}, Pressable = "Pressable", View = "View";`,
  "../lib/hoverShift": `export const markHoverProps = value => value;`,
  "../lib/favicons": `export const useAppearanceDark = () => {}; export const useFavicon = (...args) => { globalThis.faviconHostTest.lookup = args; return globalThis.faviconHostTest.resolved; }; export const useFaviconTheme = () => globalThis.faviconHostTest.shape; export const faviconFailed = (...args) => globalThis.faviconHostTest.failed = args;`,
  "../lib/siteIcons": `export const bundledSiteIcon = () => globalThis.faviconHostTest.bundled;`,
  "../lib/theme": `export const useTheme = () => globalThis.faviconHostTest.theme;`,
  "../store/hooks": `export const useWindowId = () => "little";`,
};
const hooks = registerHooks({ resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); } });
const previousRequire = globalThis.require;
globalThis.require = () => 1;
const { Favicon, FaviconFallback, NewTabIcon } = await import("./primitives.tsx");
if (previousRequire === undefined) delete globalThis.require;
else globalThis.require = previousRequire;
after(() => { hooks.deregister(); delete globalThis.faviconHostTest; });
beforeEach(() => Object.assign(f, { theme: { dark: false, textPrimary: "ink", textSecondary: "dim" }, resolved: null, shape: null, bundled: undefined, failed: null, broken: null }));
const native = element => element.type(element.props);

test("fallback initials preserve displayHost and native sizing without RN drawing", () => {
  const host = native(FaviconFallback({ url: "https://www.xn--test.invalid", size: 24 }));
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "favicon");
  assert.equal(host.props.pointerEvents, "none");
  assert.equal(JSON.parse(host.props.state).initial, "É");
  assert.deepEqual(host.props.style, { width: 24, height: 24 });
});

test("bundled fallback and the New Tab mark resolve assets but mount only native views", () => {
  f.bundled = 5;
  let state = JSON.parse(native(FaviconFallback({ url: "https://github.com" })).props.state);
  assert.equal(state.mode, "image");
  assert.equal(state.uri, "asset:5");
  f.theme.dark = true;
  state = JSON.parse(native(NewTabIcon({ size: 16 })).props.state);
  assert.equal(state.mode, "newTab");
  assert.equal(state.dark, true);
});

test("image failure is fenced to its receipt and keeps the existing cache invalidation", () => {
  f.resolved = { uri: "file:///icon.png", profileId: "work" };
  f.shape = { kind: "template", stroke: true };
  const state = JSON.parse(native(Favicon({ url: "https://example.test", favicon: "source", profileId: "work" })).props.state);
  assert.equal(state.tint, "ink");
  f.listener("error", { token: state.token + 1, uri: state.uri });
  assert.equal(f.broken, null);
  f.listener("error", { token: state.token, uri: state.uri });
  assert.equal(f.broken, state.uri);
  assert.deepEqual(f.failed, ["work", state.uri]);
});

test("direct icons keep bypassing the profile cache and do not invalidate its entry", () => {
  const state = JSON.parse(native(Favicon({ url: "https://example.test", favicon: "https://images.test/icon.png", profileId: "work", direct: true })).props.state);
  assert.equal(f.lookup[1], null);
  assert.equal(state.uri, "https://images.test/icon.png");
  f.listener("error", { token: state.token, uri: state.uri });
  assert.equal(f.failed, null);
});
