import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = (path) => readFileSync(new URL(`../../../../${path}`, import.meta.url), "utf8");
const body = (text, signature) => {
  const start = text.indexOf(signature);
  assert.ok(start >= 0, signature);
  const opening = text.indexOf("{", start);
  let depth = 1;
  let end = opening + 1;
  while (depth && end < text.length) {
    if (text[end] === "{") depth++;
    if (text[end] === "}") depth--;
    end++;
  }
  return text.slice(opening + 1, end - 1);
};

test("host refuses tab-history mutations before engine dispatch in safe mode", () => {
  const text = source("packages/solaracore/ios/SolaraCoreEngineBridge.mm");
  const policy = body(text, "bool RefusesSafeModeCall(");
  assert.match(policy, /^\s*if \(!SolaraCoreHost.safeMode\) return false;/);
  const refused = new Set([...policy.matchAll(/@"(ac_[^"]+)"/g)].map((match) => match[1]));
  for (const name of ["ac_tab_restore_tag", "ac_tab_restore_take", "ac_tab_restore_load", "ac_favicons_set", "ac_extensions_sync_state", "ac_extensions_sync_apply"]) {
    assert.ok(refused.has(name), name);
  }
  assert.equal(refused.has("ac_tab_history_generation"), false);
  for (const signature of ["+ (void)call:", "+ (void)callWithSecret:"]) {
    const call = body(text, signature);
    const guard = call.indexOf("if (RefusesSafeModeCall(name))");
    assert.ok(guard >= 0 && guard < call.indexOf("Symbol(name.UTF8String)"), signature);
  }
  assert.match(body(body(text, "+ (void)callWithSecret:"), "if (RefusesSafeModeCall(name))"), /^\s*wipe\(\);/);
});

test("host leaves saved-history reads available and falls back to opening a tab when restore is refused", () => {
  const text = source("packages/solaracore/ios/SolaraCoreWebView.mm");
  assert.equal(body(text, "static SolaraCoreTab *RestoreSavedHistory(").includes("safeMode"), false);
  const ensure = body(text, "- (void)ensureTab {");
  assert.equal(ensure.includes("safeMode"), false);
  assert.ok(ensure.includes("RestoreSavedHistory("));
  const consume = ensure.slice(ensure.indexOf('call:@"ac_tab_restore_take"'), ensure.indexOf("const BOOL userInitiated"));
  assert.ok(consume.includes('if (!tab) tab = [now.coreWindow openTab:url profile:profile foreground:NO];'));
  assert.ok(consume.includes('if (tab) [later attach:tab];'));
});

let status = { active: false };
globalThis.acTestNativeModules = { SolaraStoreAdapter: { status: () => status } };
const { useBrowser } = await import("../store/browser.ts");
const { nativeOwnsWorkspace, nativeSafeMode, startNativeStore, withApplier } = await import("../store/nativeStore.ts");

test("a safe-mode launch with an open store leaves tabs to Swift, and a frozen one owns nothing", () => {
  for (const safeMode of ["option", "failedLaunches"]) {
    status = { active: true, frozen: false, safeMode };
    startNativeStore();
    assert.equal(nativeSafeMode(), true);
    assert.equal(nativeOwnsWorkspace(), true);
    status = { active: true, frozen: true, safeMode };
    startNativeStore();
    assert.equal(nativeSafeMode(), true);
    assert.equal(nativeOwnsWorkspace(), false);
  }
  status = { active: false };
  startNativeStore();
});

test("safe in-memory tabs open, navigate, and reopen with the same URL requests as normal tabs", () => {
  for (const safeMode of [null, "option", "failedLaunches"]) {
    status = { active: false, safeMode };
    startNativeStore();
    assert.equal(nativeSafeMode(), safeMode !== null);
    const state = () => useBrowser.getState();
    withApplier(() => state().hydrate({}));
    const window = state().createWindow({ url: "https://kept.example" });
    const tab = state().newTab(window, { url: "https://first.example" });
    state().navigate(tab, "https://next.example");
    assert.equal(state().tabs[tab].navigation.url, "https://next.example");
    state().updateTab(tab, { url: "https://next.example" });
    state().closeTab(tab);
    assert.equal(state().tabs[tab], undefined);
    state().reopenClosed(window);
    const reopened = state().windows[window].activeTabIds.default;
    assert.equal(state().tabs[reopened].url, "https://next.example");
    assert.equal(state().tabs[reopened].adoptId, `restore:${tab}`);
    assert.equal(state().windows[window].tabIds.length, 2);
  }
});

test("launch rekey precedes the locked safe decision and host startup", () => {
  const text = source("apps/browser/macos/Solara-macOS/main.swift");
  const ordered = [
    "SafeStorageRekeyRun.runAtLaunch(",
    "NativeStore.launchAtStartup()",
    "SolaraCoreHost.safeMode = NativeStore.safeMode",
    "SolaraCoreHost.run(",
  ];
  let previous = -1;
  for (const step of ordered) {
    const position = text.indexOf(step);
    assert.ok(position >= 0, step);
    assert.equal(position, text.lastIndexOf(step), `${step} appears exactly once`);
    assert.ok(position > previous, `${step} follows the previous startup step`);
    previous = position;
  }
  const launch = body(source("packages/store/ios/NativeStore.swift"), "public static func launchAtStartup()");
  const lock = launch.indexOf("FolderLock.acquire");
  const count = launch.indexOf("LaunchSwitches.countLaunch()");
  const open = launch.indexOf("Launcher.openSafe");
  assert.ok(lock >= 0, "acquires the folder lock");
  assert.ok(count > lock, "counts the launch after acquiring the folder lock");
  assert.ok(open > count, "opens safely after counting the launch");
});
