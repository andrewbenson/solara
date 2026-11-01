import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const sourceRoot = join(root, "apps/browser/src");
const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log("node native/SolaraKit/Scripts/page-events-golden.mts [--verify] [--out path]");
  process.exit(0);
}
const out = args.includes("--out") ? resolve(args[args.indexOf("--out") + 1]!) : join(root, "native/SolaraKit/Tests/Fixtures/page-events.json");
const normalize = (x: any): any => JSON.parse(JSON.stringify(x));
const sources: Record<string, string> = {};
const names = ["components/pageEvents", "components/pooledPages", "lib/nativeEvents", "lib/launchLook", "lib/pageHandoff", "lib/webviews", "store/model", "store/tabs"];
for (const name of names) sources[name] = readFileSync(join(sourceRoot, `${name}.ts`), "utf8");

function record(spec: any) {
  let now = 0;
  let sequence = 100;
  const writes: any[] = [];
  const microtasks: (() => void)[] = [];
  const timers = new Map<number, { at: number; callback: () => void }>();
  let timerId = 0;
  const pages: Record<string, any> = {};
  const modules: Record<string, any> = {};
  const started = new Set<number>();
  const globals: any = {};
  const initial = normalize(spec.initial ?? {});
  const idle = { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false, themeColor: null };
  let state: any = { tabs: {}, live: {}, windows: { w: { tabIds: ["t", "other"], activeTabIds: { p: "other" } } }, peeks: {}, ui: {}, windowOrder: [] };
  state.tabs.t = { id: "t", windowId: "w", profileId: "p", url: "", title: "", favicon: null, ...initial.tab };
  state.tabs.other = { id: "other", windowId: "w", profileId: "p", url: "" };
  state.live.t = { ...idle, ...initial.live };
  pages.t = { wasNewTab: false, newTabShown: null, ...initial.page };
  const subscribers: any[] = [];
  const push = (kind: string, value: any) => writes.push(normalize({ kind, ...value }));
  const snapshot = () => ({ tab: state.tabs.t ?? null, live: state.live.t, activeTabId: state.windows[state.tabs.t?.windowId ?? "w"]?.activeTabIds.p });
  const notify = (prev: any) => { for (const callback of subscribers) callback(state, prev); };
  const set = (patch: any) => {
    const prev = state;
    const next = typeof patch === "function" ? patch(state) : patch;
    state = { ...state, ...next };
    const change: any = {};
    if (next.tabs) change.tab = next.tabs.t ?? null;
    if (next.live) change.live = next.live.t ?? null;
    push("write", change);
    notify(prev);
  };
  const browser = { getState: () => state, setState: set, subscribe: (f: any) => { subscribers.push(f); return () => {}; } };
  browser.subscribe(() => push("subscriber", snapshot()));
  const noop = () => {};
  const external = new Proxy({}, { get: () => noop });
  const mocks: Record<string, any> = {
    "store/browser": { useBrowser: browser },
    "store/settings": { DEFAULT_PROFILE_ID: "default" },
    "store/organize": { onUrlChange: () => ({}) },
    "store/splits": { splitOf: () => initial.split ? {} : undefined },
    "lib/earlyNavigate": { takeStartedNavigation: (_: string, seq: number) => started.delete(seq) },
    "lib/tabLifecycle": { noteDiscarded: () => push("lifecycle", { value: "discarded" }), noteReady: () => push("lifecycle", { value: "ready" }), noteGone: noop },
    "components/layout/pageState": { pageOf: (id: string) => pages[id] ?? {}, patchPage: (id: string, patch: any) => { pages[id] = { ...pages[id], ...patch }; }, setBrowserId: noop, setPopover: noop, usePages: { getState: () => ({ popover: {} }) } },
    "lib/favicons": { pageKey: (url: string) => url.replace(/#.*$/, ""), seedFavicons: noop, adoptIconPage: noop, dropOutlivedFavicon: noop },
    "@solara/shell": { readDocument: () => JSON.stringify({ version: 2, themes: spec.themes ?? [], favicons: {} }) },
    "@solara/solaracore": { pooledWebViewHandle: (call: any) => ({ loadUrl: (url: string, options: any) => call("loadUrl", [url, options]), setMuted: (muted: boolean) => call("setMuted", [muted]) }), unwrapPageEvent: (_: string, payload: any) => Array.isArray(payload) ? payload : [payload] },
  };
  const load = (name: string): any => {
    if (mocks[name]) return mocks[name];
    if (modules[name]) return modules[name];
    if (!sources[name]) return external;
    const result = { exports: {} as any };
    modules[name] = result.exports;
    const code = ts.transpileModule(sources[name], { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
    const localRequire = (id: string) => load(id.startsWith(".") ? resolve("/", dirname(name), id).slice(1) : id);
    const context = vm.createContext({ exports: result.exports, require: localRequire, module: result, console, queueMicrotask: (f: any) => microtasks.push(f), setTimeout: (callback: any, delay: number) => { const id = ++timerId; timers.set(id, { at: now + delay, callback }); return id; }, clearTimeout: (id: number) => timers.delete(id), Date, Math, globalThis: globals });
    new vm.Script(code, { filename: `${name}.ts` }).runInContext(context);
    return result.exports;
  };
  const tabs = load("store/tabs").createTabsSlice(set, () => state);
  for (const name of ["updateTab", "updateLive", "navigated"]) state[name] = (...values: any[]) => { push("call", { name, args: values }); return tabs[name](...values); };
  state.closeTab = (id: string) => { push("call", { name: "closeTab", args: [id] }); const prev = state; const { [id]: removed, ...rest } = state.tabs; state = { ...state, tabs: rest }; push("write", { tab: null }); notify(prev); };
  state.activate = (id: string) => push("command", { name: "activate", id });
  const events = load("components/pageEvents");
  const native = load("lib/nativeEvents");
  const hold = native.createHold({ batch: (f: any) => f(), schedule: (f: any) => microtasks.push(f), report: (error: any) => { throw error; } });
  globals.__acHoldReport = hold.hold;
  globals.__acApplyHeldReports = hold.flush;
  const bridge = { __callFunction: (_module: string, _method: string, values: any[]) => values[2](), __invokeCallback: (_id: number, values: any[]) => values[0]() };
  native.holdPageReports(bridge, hold);
  const listeners = new Map<string, any>();
  const emitter = { addListener(name: string, callback: any) { listeners.set(name, callback); }, removeListener(name: string) { listeners.delete(name); } };
  native.afterHeldReports(emitter, hold);
  let listener: any;
  const pool = { addListener: (_: string, f: any) => { listener = f; return { remove: noop }; }, pageCall: (_: string, method: string, values: any[]) => push("handle", { method, args: values }) };
  const webviews = load("lib/webviews");
  webviews.webviews.set("t", { loadUrl: (url: string, options: any) => push("handle", { method: "loadUrl", args: [url, options] }), setMuted: (muted: boolean) => push("handle", { method: "setMuted", args: [muted] }) });
  const engine = spec.engine ?? "chromium";
  let session: any;
  let handlers: any;
  const runMicrotasks = () => { while (microtasks.length) microtasks.shift()!(); };
  if (spec.pooled) {
    load("components/pooledPages").startPooledPages(pool);
    listener({ tabId: "t", name: "onPageCreated", payload: { engine, seq: spec.handoff ?? -1 } });
  } else {
    session = events.newPageSession("t", engine, undefined, spec.handoff == null ? null : { seq: spec.handoff });
    handlers = events.pageEventHandlers(session);
  }
  if (spec.themes) load("lib/launchLook").restoreLaunchLook();
  const report = (step: any) => {
    const payload = step.name === "onNavigationChange" ? { url: "", title: "", isLoading: false, canGoBack: false, canGoForward: false, ...step.payload } : step.payload;
    if (spec.pooled) listener({ tabId: "t", name: step.name, payload });
    else handlers[step.name](...(Array.isArray(payload) ? payload : [payload]));
  };
  for (const step of spec.steps) {
    if (step.op === "report") {
      if (spec.pooled) report(step);
      else bridge.__callFunction("RCTEventEmitter", "receiveEvent", [0, `top${step.name.slice(2)}`, () => report(step)]);
      if (!step.held) bridge.__invokeCallback(0, [noop]);
    } else if (step.op === "flush") { hold.flush(); runMicrotasks(); }
    else if (step.op === "follow") {
      if (step.startedEarly) started.add(state.tabs.t.navigation.seq);
      events.followNavigation(session, state.tabs.t.navigation);
    } else if (step.op === "navigate") {
      bridge.__invokeCallback(0, [() => {
        push("command", { name: "navigate", url: step.url });
        state.updateTab("t", { navigation: { seq: step.seq ?? ++sequence, url: step.url, ...(step.userInitiated ? { userInitiated: true } : {}) } });
        if (!spec.pooled) events.followNavigation(session, state.tabs.t.navigation);
      }]);
    } else if (step.op === "activate" || step.op === "strip") {
      emitter.addListener(step.op, () => {
        push("command", { name: step.op });
        const prev = state;
        const windowId = state.tabs.t?.windowId ?? "w";
        const activeTabId = step.op === "activate" ? "t" : "other";
        state = { ...state, windows: { ...state.windows, [windowId]: { ...state.windows[windowId], activeTabIds: { p: activeTabId } } } };
        push("write", { activeTabId });
        notify(prev);
        push("observe", snapshot());
      });
      listeners.get(step.op)();
    } else if (step.op === "tick") {
      now = step.now;
      for (const [id, timer] of [...timers]) if (timer.at <= now) { timers.delete(id); timer.callback(); }
    } else if (step.op === "move" || step.op === "touch") {
      bridge.__invokeCallback(0, [() => {
        push("command", { name: step.op });
        if (step.op === "touch") state.updateTab("t", { title: step.title });
        else {
          state.windows.w2 = { tabIds: ["t"], activeTabIds: { p: "t" } };
          state.updateTab("t", { windowId: "w2", navigation: { seq: step.seq, url: step.url } });
        }
      }]);
    } else if (step.op === "observe") push("observe", snapshot());
    else throw new Error(`Unknown operation ${step.op}`);
  }
  hold.flush(); runMicrotasks();
  return { ...spec, writes };
}
const nav = (url: string, more: any = {}, held = false) => ({ op: "report", name: "onNavigationChange", payload: { url, title: url, ...more }, held });
const specs = [
  { name: "held report before navigate", initial: { tab: { navigation: { seq: 1, url: "https://old.test/" } } }, steps: [{ op: "follow" }, nav("https://old.test/", { isLoading: true }, true), { op: "navigate", url: "https://new.test/", seq: 2, userInitiated: true }, { op: "flush" }, nav("https://new.test/") ] },
  { name: "loading edges activation strip", steps: [nav("https://a.test/", { isLoading: true }, true), nav("https://a.test/", { isLoading: false }, true), { op: "activate" }, nav("https://b.test/", {}, true), { op: "strip" }, { op: "observe"}] },
  { name: "discard ready", initial: { page: { wasNewTab: true }, live: { playingAudio: true, canGoBack: true } }, steps: [nav("https://a.test/"), { op: "report", name: "onDiscarded", payload: "https://a.test/" }, { op: "report", name: "onReady", payload: [12, 34] }, nav("", { committedInitial: true }), nav("https://a.test/")] },
  { name: "download adopted closes", initial: { tab: { adoptId: "adopt", openerId: "other" } }, steps: [{ op: "report", name: "onDownloadNavigation", payload: { committedUrl: "", skipped: false } }, nav("https://late.test/", { isLoading: true }), { op: "observe" }] },
  { name: "download committed", initial: { tab: { url: "https://download.test/", navigation: { seq: 1, url: "https://download.test/file" } }, live: { isLoading: true } }, steps: [{ op: "report", name: "onDownloadNavigation", payload: { committedUrl: "https://download.test/", skipped: false } }] },
  { name: "download skipped keeps NTP", initial: { tab: { openerId: "other", url: "https://file.test/" }, page: { wasNewTab: true, newTabShown: { url: "https://kept.test/", title: "Kept" } } }, steps: [{ op: "report", name: "onDownloadNavigation", payload: { committedUrl: "", skipped: true } }] },
  { name: "preserved NTP and back", initial: { page: { wasNewTab: true, newTabShown: { url: "https://kept.test/", title: "Kept" } } }, steps: [nav("https://kept.test/", { isLoading: true, themeColor: "#123" }), nav("https://else.test/", { canGoBack: true })] },
  { name: "unsolicited pooled prewarm", pooled: true, steps: [{ op: "flush" }, nav(""), nav("https://adopted.test/"), { op: "flush" }, { op: "observe" }] },
  { name: "pooled handoff changed before follow", pooled: true, handoff: 1, initial: { tab: { navigation: { seq: 1, url: "https://a.test/" } } }, steps: [{ op: "navigate", seq: 2, url: "https://b.test/" }, { op: "flush" }] },
  { name: "pooled unchanged sequence and moved handoff", pooled: true, handoff: 8, initial: { tab: { navigation: { seq: 8, url: "https://a.test/" } } }, steps: [{ op: "flush" }, { op: "touch", title: "Changed" }, { op: "flush" }, { op: "move", seq: 9, url: "https://moved.test/" }, { op: "flush" }, nav("https://moved.test/")] },
  { name: "webkit create early navigation", engine: "webkit", initial: { tab: { navigation: { seq: 1, url: "https://a.test/" } } }, steps: [{ op: "follow" }, { op: "navigate", seq: 2, url: "https://b.test/" }, { op: "report", name: "onLoadError", payload: {} }] },
  { name: "early navigation already started", initial: { tab: { navigation: { seq: 7, url: "https://early.test/" } } }, steps: [{ op: "follow", startedEarly: true }, nav("https://early.test/")] },
  { name: "matching handoff", handoff: 4, initial: { tab: { navigation: { seq: 4, url: "https://handoff.test/" } } }, steps: [{ op: "follow" }, nav("https://handoff.test/")] },
  { name: "blank guard and accessed initial", initial: { tab: { navigation: { seq: 1, url: "https://a.test/" } } }, steps: [{ op: "follow" }, nav("", { committedInitial: true }), nav("https://opener.test/", { committedInitial: true, initialDocumentAccessed: true }), nav("https://a.test/", { themeColor: "#abc" })] },
  { name: "restored theme grace", initial: { tab: { url: "https://a.test/" } }, themes: [{ tab: "t", page: "https://a.test/", color: "#restored" }], steps: [nav("https://a.test/", { isLoading: true }), nav("https://a.test/"), { op: "tick", now: 1499 }, { op: "observe" }, { op: "tick", now: 1500 }, { op: "observe" }, { op: "report", name: "onMedia", payload: { playing: true, muted: false } }] },
];
const fixture = { version: 1, sources: Object.fromEntries(names.map(name => [name, createHash("sha256").update(sources[name]).digest("hex")])), cases: specs.map(record) };
const json = JSON.stringify(fixture, null, 2) + "\n";
if (args.includes("--verify")) {
  if (readFileSync(out, "utf8") !== json) throw new Error("Golden fixture differs");
} else { mkdirSync(dirname(out), { recursive: true }); writeFileSync(out, json); }
console.log(`${fixture.cases.length} cases, ${fixture.cases.reduce((n, c) => n + c.writes.length, 0)} ordered entries: ${out}`);
