import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./Postcard.tsx", import.meta.url).href;
const f = globalThis.postcardHostTest = {};
const fake = source => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const SolaraHostedView = "HostedView"; export const onHostedEvent = (kind, windowId, fn) => { const f = globalThis.postcardHostTest; f.listener = fn; f.subscription = [kind, windowId]; return () => { f.listener = null; }; };`,
  react: `export const useEffect = fn => globalThis.postcardHostTest.effects.push(fn); export const useRef = value => { const f = globalThis.postcardHostTest; return f.refs[f.refIndex++] ??= {current: value}; };`,
  "react-native": `export const StyleSheet = { absoluteFill: { position: "absolute" } }; export const Image = {resolveAssetSource: () => ({uri: "file:///fixture/icon.png"})};`,
  "../../lib/theme": `export const useTheme = () => globalThis.postcardHostTest.theme; export const hex = value => value; export const profileAccent = () => "#448866";`,
  "../../store/hooks": `export const useWindowId = () => "w";`,
  "../../lib/productName": `export const PRODUCT = "Solara";`,
  "../../lib/appIcon": `export const APP_ICON = 1;`,
  "./releaseNotes": `export const releaseNotesPageReceipt = () => globalThis.postcardHostTest.pageReceipt; export const releaseNotesPendingReceipt = () => globalThis.postcardHostTest.pending; export const closeReleaseNotesIfCurrent = (receipt, action) => { const f = globalThis.postcardHostTest; if (receipt === f.pageReceipt) action?.(); };`,
};
const hooks = registerHooks({ resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); } });
const { ReleaseNotesPostcard, ReleaseNotesPage } = await import("./Postcard.tsx");
after(() => { hooks.deregister(); delete globalThis.postcardHostTest; });
const notes = {version: "1.0", date: "September 2026", title: "Hello, Solara", summary: "Summary", items: [{title: "Feature", body: "Body"}]};
function render(kind = "postcard") {
  f.refIndex = 0;
  const props = {notes, tabId: f.tabId, onOpen: () => f.actions.push("open"), onDismiss: () => f.actions.push("dismiss"), onClose: () => f.actions.push("close")};
  const child = kind === "postcard" ? ReleaseNotesPostcard(props) : ReleaseNotesPage(props);
  return child && child.type(child.props);
}
function mount(kind) {
  const host = render(kind);
  f.cleanups = f.effects.map(fn => fn()).filter(fn => typeof fn === "function");
  f.payload = host ? {...JSON.parse(host.props.state), version: notes.version} : null;
  return host;
}
beforeEach(() => {
  f.cleanups?.forEach(fn => fn());
  Object.assign(f, {effects: [], refs: [], refIndex: 0, actions: [], cleanups: [], pending: {version: "1.0", since: 1}, pageReceipt: 1, tabId: "tab", theme: {dark: true, panel: "#222222", panelBorder: "#333333", textPrimary: "#FFFFFF", textSecondary: "#AAAAAA"}});
});

test("postcard draws only its native host with exact notes, theme and tab identity", () => {
  const host = mount("postcard");
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "releaseNotesPostcard");
  assert.deepEqual(f.subscription, ["releaseNotesPostcard", "w"]);
  assert.deepEqual(f.payload.notes, notes);
  assert.equal(f.payload.tabId, "tab");
  assert.equal(f.payload.dark, true);
  assert.equal(f.payload.iconUri, "file:///fixture/icon.png");
  assert.match(f.payload.presentationId, /^postcard-/);
});

test("native open/dismiss retain callbacks and reject unrelated actions", () => {
  mount("postcard");
  f.listener("open", f.payload);
  f.listener("dismiss", f.payload);
  f.listener("close", f.payload);
  assert.deepEqual(f.actions, ["open", "dismiss"]);
});

test("stale version, presentation and replaced pending events cannot retire notes", () => {
  mount("postcard");
  for (const changes of [{version: "2.0"}, {presentationId: "old"}]) f.listener("dismiss", {...f.payload, ...changes});
  f.pending = {version: "1.0", since: 2};
  f.listener("dismiss", f.payload);
  assert.deepEqual(f.actions, []);
});

test("old page close and unmount cleanup cannot close a replacement page", () => {
  const host = mount("page");
  assert.equal(host.props.kind, "releaseNotesPage");
  f.listener("close", f.payload);
  assert.deepEqual(f.actions, ["close"]);
  f.actions = [];
  f.pageReceipt = 2;
  f.listener("close", f.payload);
  f.cleanups.forEach(fn => fn());
  assert.deepEqual(f.actions, []);
  assert.equal(f.listener, null);
});

test("retained callbacks stop after cleanup and a tab replacement cycle", () => {
  mount("postcard");
  const old = f.listener;
  const payload = f.payload;
  f.tabId = "other";
  render();
  f.tabId = "tab";
  render();
  old("open", payload);
  f.cleanups.forEach(fn => fn());
  old("dismiss", payload);
  assert.deepEqual(f.actions, []);
});
