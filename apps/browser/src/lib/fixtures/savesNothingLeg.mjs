import { registerHooks } from "node:module";

const reactNativeFake = new URL("../../test-native/reactNative.ts", import.meta.url).href;
const reactNative = `data:text/javascript,${encodeURIComponent(`export * from ${JSON.stringify(reactNativeFake)}; export const unstable_batchedUpdates = (run) => run();`)}`;
registerHooks({ resolve: (specifier, context, next) => (specifier === "react-native" ? { url: reactNative, shortCircuit: true } : next(specifier, context)) });

const [state, message = "present"] = process.argv.slice(2);

const data = { settings: { searchEngine: "duckduckgo", chosen: ["searchEngine"], inferred: [] }, downloads: [] };
const store = (status, snapshot = () => JSON.stringify({ rev: 1, data })) => ({
  status,
  snapshot,
  dispatch: (_json, sinceRev) => JSON.stringify({ rev: Math.max(1, sinceRev), patches: [] }),
  catchUp: () => JSON.stringify({ rev: 1, patches: [] }),
  flush: () => "saved",
  freeze: () => ((globalThis.acTestFreezes = (globalThis.acTestFreezes ?? 0) + 1), true),
  addListener: () => ({ remove() {} }),
});

const stores = {
  inactive: () => store(() => ({ active: false, reason: "couldn't lock the data folder: busy" })),
  refused: () => store(() => ({ active: false, reason: "the native store refused to import: session.json could not be parsed", refusedSession: "/data/session.json" })),
  safeRefused: () => store(() => ({ active: false, safeMode: "option", refusedSession: "/data/session.json", reason: "no usable database" })),
  frozen: () => store(() => ({ active: true, frozen: true })),
  nullSnapshot: () => store(() => ({ active: true }), () => null),
  snapshotThrows: () => store(() => ({ active: true }), () => "{ not json"),
  statusThrows: () => store(() => { throw new Error("the bridge isn't ready"); }),
  handoff: () => store(() => ({ active: false, reason: "another instance (pid 1) is using this data folder", handedOff: true })),
  owned: () => store(() => ({ active: true })),
  noModule: () => null,
};

const made = stores[state]?.();
if (made === undefined) throw new Error(`unknown state ${state}`);
const sync = { newDeviceId: () => "dev1", deviceName: () => "Test Mac", forget: async () => {}, chainStatus: async () => "ok", deleteChain: async () => {} };
globalThis.acTestNativeModules = made ? { SolaraStoreAdapter: made, SolaraSyncAdapter: sync } : { SolaraSyncAdapter: sync };
globalThis.acTestAlerts = [];
globalThis.acTestPresentStoreUnavailable = {
  present: () => true,
  refuses: () => false,
  throws: () => { throw new Error("no window"); },
  missing: undefined,
}[message];
const presented = [];
if (globalThis.acTestPresentStoreUnavailable && message === "present") {
  const show = globalThis.acTestPresentStoreUnavailable;
  globalThis.acTestPresentStoreUnavailable = (detail) => (presented.push(detail), show(detail));
}

const shell = await import("../../test-native/index.ts");
const session = JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] });
const downloads = JSON.stringify({ version: 2, downloads: [] });
shell.docs.set("session.json", session);
shell.docs.set("downloads.json", downloads);
const { useBrowser } = await import("../../store/browser.ts");
const { flushPersistence, resumePersistence, startPersistence } = await import("../persist.ts");
const { persistenceRefused } = await import("../persistLatch.ts");
const errors = [];
const error = console.error;
console.error = (...args) => errors.push(args.map(String).join(" "));
const warn = console.warn;
console.warn = () => {};
const readsBefore = shell.documentReads.length;
const changesBefore = shell.documentChanges.length;
let started = null;
try {
  startPersistence();
} catch (caught) {
  started = String(caught);
}
const readsAtStart = shell.documentReads.slice(readsBefore);
const change = () => {
  try {
    const s = useBrowser.getState();
    s.createWindow({ url: "https://lost.example/" });
    s.updateSettings({ appearance: s.settings.appearance === "dark" ? "light" : "dark" });
    s.upsertDownload({ id: `d${Date.now()}`, url: "https://e/", state: "complete", profile: "" });
  } catch {}
};
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
change();
await wait(1000);
flushPersistence({ final: true });
resumePersistence();
change();
await wait(1000);
flushPersistence({ final: true });
console.error = error;
console.warn = warn;

const { liveCommand } = await import("../../live/command.ts").catch(() => import("@solara/settings"));
const live = await liveCommand("updateFolder", { folderId: "f", patch: {} }).then(() => "ran", (caught) => String(caught));
const onboarding = await import("../../components/onboarding/state.ts");
const windowId = useBrowser.getState().createWindow({});
onboarding.startOnboarding(windowId);
const onboardingStarted = onboarding.useOnboarding.getState().windowId === windowId;

let syncState = null;
if (persistenceRefused()) {
  const { useSync, startSync } = await import("../../sync/engine.ts");
  startSync();
  await wait(10);
  syncState = { status: useSync.getState().status, error: useSync.getState().error ?? null };
}

process.stdout.write(JSON.stringify({
  started,
  readsAtStart,
  changes: shell.documentChanges.slice(changesBefore),
  session: shell.docs.get("session.json") === session,
  downloads: shell.docs.get("downloads.json") === downloads,
  launchLook: shell.docs.has("launch-look.json"),
  latch: persistenceRefused(),
  sync: syncState,
  errors,
  presented,
  alerts: globalThis.acTestAlerts.length,
  freezes: globalThis.acTestFreezes ?? 0,
  live,
  onboardingStarted,
}));
process.exit(0);
