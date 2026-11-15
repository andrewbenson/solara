import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";
import { validateWindowContract } from "./perf/native-work.mjs";

const appPath = process.argv[2];
if (!appPath) throw new Error("usage: node native-layout-test.mjs <Debug app>");
const scratch = mkdtempSync(join(tmpdir(), "ac-native-layout-"));
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }],
  settings: { warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false, sleepInactiveTabs: false },
});
const app = await launch(resolve(appPath), { data: join(scratch, "data"), session: fixture, onboarded: true, probe: true,
  env: { SOLARA_NATIVE_WINDOW_LAYOUT: "1" }, ready: "return !!ac.store.getState().windows.w1" });
const samples = [];
const registrations = () => app.eval('return globalThis.expo.modules.SolaraTabPool.livePages().then(pages => pages.map(({tabId,sessionGeneration,registrationGeneration}) => ({tabId,sessionGeneration,registrationGeneration})).sort((a,b)=>a.tabId.localeCompare(b.tabId)));');
const browserIdentities = () => app.eval('return globalThis.expo.modules.SolaraTabPool.livePages().then(pages=>pages.filter(page=>["a","b"].includes(page.tabId)).map(page=>({tabId:page.tabId,browserId:page.ready?.browserId??null})).sort((a,b)=>a.tabId.localeCompare(b.tabId)));');
const read = () => app.eval('return globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse);');
async function settled() {
  const end = Date.now() + 10000;
  let shell;
  while (Date.now() < end) {
    assert.ok(app.alive, "instance exited");
    shell = await read();
    if (shell?.nativeLayout && shell.nativeLayoutChrome && shell.layout?.current) return shell;
    await sleep(100);
  }
  samples.push(shell);
  throw new Error("native layout did not settle");
}
function verify(shell, baseline) {
  assert.equal(shell.layoutControllerSubscriptions, 1);
  assert.equal(shell.nativeLayoutChrome.childStoreSubscriptions, 0);
  assert.equal(shell.nativeLayoutChrome.stopped, false);
  for (const key of ["sidebarRegistry", "stripRegistry", "peekRegistry"]) assert.equal(shell.nativeLayoutChrome[key], true, key);
  if (baseline) for (const key of ["owner", "column", "dockedStrip", "floatingStrip", "generation"]) assert.equal(shell.nativeLayoutChrome[key], baseline.nativeLayoutChrome[key], key);
  samples.push(shell);
}
try {
  const before = await settled();
  verify(before);
  assert.equal(before.nativeLayoutChrome.sidebarRealized, true);
  assert.equal(before.nativeLayoutChrome.dockedStripRealized, false);
  assert.equal(before.nativeLayoutChrome.floatingStripRealized, false);
  const work = await app.eval('return globalThis.expo.modules.SolaraWindowShell.nativeWork(false).then(JSON.parse);');
  assert.ok(work.groups.filter(group => group.kind.startsWith("strip.")).every(group => group.created === 0 && group.live === 0), "hidden strips create no row trees");
  const snapshot = await app.snapshot({ windowId: "w1", fields: ["windows.shell", "windows.tabIds"] });
  let pages = validateWindowContract(snapshot.windows.find((window) => window.id === "w1").shell.contract).pageIdentities;
  assert.ok(pages.some((page) => page.tabId === "a"));
  let pageRegistrations = await registrations();
  assert.ok(pageRegistrations.some((page) => page.tabId === "a" && page.registrationGeneration > 0));
  const splitId = await app.eval('const s=ac.store.getState(); const id=s.createSplit(["a","b"]); s.activate("a"); return id;');
  const splitDeadline = Date.now() + 10000;
  let splitReady = false;
  while (Date.now() < splitDeadline) {
    assert.ok(app.alive, "split creation exited");
    const split = (await read())?.split;
    splitReady = ["a", "b"].every(id => split?.leaves?.[id] && split?.overlays?.[id] && !split.overlays[id].hidden);
    if (splitReady) break;
    await sleep(100);
  }
  assert.equal(splitReady, true, "both split pane slots install");
  const browserDeadline = Date.now() + 10000;
  let splitBrowsers;
  while (Date.now() < browserDeadline) {
    assert.ok(app.alive, "waiting for split browser identities exited");
    splitBrowsers = await browserIdentities();
    if (splitBrowsers.length === 2 && splitBrowsers.every(page => page.browserId !== null)) break;
    await sleep(100);
  }
  assert.ok(splitBrowsers?.length === 2 && splitBrowsers.every(page => page.browserId !== null), "both WebContents are registered");
  const splitRegistrations = await registrations();
  const splitIdentity = await app.snapshot({ windowId: "w1", fields: ["windows.shell"] });
  const splitPages = splitIdentity.windows.find(window => window.id === "w1").shell.contract.pageIdentities;
  assert.deepEqual(splitPages.map(page => page.tabId).sort(), ["a", "b"]);
  assert.deepEqual(splitRegistrations.map(page => page.tabId).sort(), ["a", "b"]);
  assert.deepEqual(splitPages.filter(page => pages.some(initial => initial.tabId === page.tabId)), pages);
  assert.deepEqual(splitRegistrations.filter(page => pageRegistrations.some(initial => initial.tabId === page.tabId)), pageRegistrations);
  for (const sizes of [[0.35, 0.65], [0.6, 0.4], [0.5, 0.5]]) {
    await app.eval(`const s=ac.store.getState(); s.updateSplit(${JSON.stringify(splitId)},{sizes:${JSON.stringify(sizes)}}); s.toggleSplitOrientation(${JSON.stringify(splitId)}); return true;`);
    await sleep(700);
    const shell = await settled();
    verify(shell, before);
    for (const id of ["a", "b"]) {
      assert.equal(shell.split.overlays[id].hidden, false);
      const page = shell.split.leaves[id].window;
      const overlay = shell.split.overlays[id].window;
      assert.ok(page.every((value, index) => Math.abs(value - overlay[index]) <= 0.5), `${id} page and overlay endpoints`);
    }
    assert.deepEqual(await registrations(), splitRegistrations);
    assert.deepEqual(await browserIdentities(), splitBrowsers);
    const sample = await app.snapshot({ windowId: "w1", fields: ["windows.shell"] });
    assert.deepEqual(sample.windows.find(window => window.id === "w1").shell.contract.pageIdentities, splitPages);
  }
  await app.eval(`ac.store.getState().separateSplit(${JSON.stringify(splitId)}); ac.store.getState().activate("a"); return true;`);
  await sleep(700);
  assert.deepEqual(await registrations(), splitRegistrations);
  assert.deepEqual(await browserIdentities(), splitBrowsers);
  pages = splitPages;
  pageRegistrations = splitRegistrations;
  const paneMounts = await app.eval('return Object.fromEntries(["TabWebView","LegacyContentCard","TabPane","WindowToolbar","NativeContentGuests"].map(name=>[name,acPerf.findFibers(name,10).length]));');
  assert.deepEqual(paneMounts, { TabWebView: 0, LegacyContentCard: 0, TabPane: 0, WindowToolbar: 0, NativeContentGuests: 1 });
  for (const changes of [{ sidebarIconsOnly: true }, { tabLayout: "top" }, { tabLayout: "sidebar", sidebarIconsOnly: false, addressBar: "sidebar" }, { addressBar: "toolbar" }]) {
    await app.eval(`ac.store.getState().updateSettings(${JSON.stringify(changes)}); return true;`);
    await sleep(700);
    verify(await settled(), before);
    const next = await app.snapshot({ windowId: "w1", fields: ["windows.shell"] });
    assert.deepEqual(next.windows.find((window) => window.id === "w1").shell.contract.pageIdentities, pages);
  }
  await app.eval('ac.store.getState().updateSettings({tabLayout:"top"}); ac.store.getState().toggleSidebar("w1"); return true;');
  await sleep(700);
  await app.eval('return globalThis.expo.modules.SolaraTopStrip.peekShow("w1");');
  await sleep(400);
  const floating = await settled();
  verify(floating, before);
  assert.equal(floating.nativeLayoutChrome.floatingStripRealized, true);
  await app.eval('return globalThis.expo.modules.SolaraTopStrip.peekHide("w1");');
  await sleep(600);
  await app.eval('ac.store.getState().toggleSidebar("w1"); ac.store.getState().updateSettings({tabLayout:"sidebar"}); return true;');
  await sleep(700);
  const mounts = await app.eval("return acPerf.read().mounts;");
  for (const name of ["Sidebar", "DockedLayout", "TopTabStrip", "NativeStripPeek"]) assert.equal(mounts[name] ?? 0, 0, name);
  await app.eval("globalThis.__layoutReloadMarker = true; ac.reload(); return true;");
  const reloadDeadline = Date.now() + 15000;
  let reloadedRuntime = false;
  while (Date.now() < reloadDeadline) {
    assert.ok(app.alive, "reload exited");
    reloadedRuntime = await app.eval("return globalThis.__layoutReloadMarker === undefined;", { timeout: 1000 }).catch(() => false);
    if (reloadedRuntime) break;
    await sleep(100);
  }
  assert.equal(reloadedRuntime, true, "reload replaces the JavaScript runtime");
  verify(await settled(), before);
  const reloaded = await app.snapshot({ windowId: "w1", fields: ["windows.shell"] });
  assert.deepEqual(reloaded.windows.find((window) => window.id === "w1").shell.contract.pageIdentities, pages);
  assert.deepEqual(await registrations(), pageRegistrations);
  for (const kind of ["sidebar", "sidebar.shell", "topStrip", "topStripFloating", "topStripPeek", "topStripControls", "topStripGlow"]) {
    const attempt = await app.eval(`return globalThis.expo.modules.SolaraHosted.devHost(${JSON.stringify(kind)},"w1",true);`);
    assert.equal(attempt.mounted, "false", kind);
    verify(await settled(), before);
    await app.eval(`return globalThis.expo.modules.SolaraHosted.devHost(${JSON.stringify(kind)},"w1",false);`);
  }
  await app.eval('return globalThis.expo.modules.SolaraSettings.publish("sidebar.shell",JSON.stringify({windows:{w1:{state:"{}",top:9999,header:9999,bottom:9999,clip:true}}}));');
  verify(await settled(), before);
  const inventory = await app.eval('return globalThis.expo.modules.SolaraApp.devWindowLifecycle("inventory",false);');
  const number = inventory.windows.find((window) => window.id === "w1").number;
  await app.eval(`return globalThis.expo.modules.SolaraCEF.devWindow(${number},"close-button");`);
  await sleep(500);
  assert.equal(await app.eval('return ac.store.getState().windows.w1.keptOnClose;'), true);
  verify(await settled(), before);
  await app.eval('return globalThis.expo.modules.SolaraApp.devWindowLifecycle("dock",true);');
  await sleep(500);
  verify(await settled(), before);
  const reopened = await app.eval('return globalThis.expo.modules.SolaraApp.devWindowLifecycle("inventory",false);');
  assert.equal(reopened.windows.find((window) => window.id === "w1").visible, true);
  const after = await app.snapshot({ windowId: "w1", fields: ["windows.shell"] });
  assert.deepEqual(after.windows.find((window) => window.id === "w1").shell.contract.pageIdentities, pages);
  assert.deepEqual(await registrations(), pageRegistrations);
  const second = await app.eval('return ac.store.getState().createWindow({background:true,url:"about:blank"});');
  const openedDeadline = Date.now() + 10000;
  let secondWindow;
  while (Date.now() < openedDeadline) {
    assert.ok(app.alive, "opening second window exited");
    const inventory = await app.eval('return globalThis.expo.modules.SolaraApp.devWindowLifecycle("inventory",false);');
    secondWindow = inventory.windows.find(window => window.id === second);
    if (secondWindow) break;
    await sleep(100);
  }
  assert.ok(secondWindow, "second window opens");
  const secondGeneration = await app.eval(`return globalThis.expo.modules.SolaraWindowShell.nativeLayoutGeneration(${JSON.stringify(second)});`);
  assert.ok(secondGeneration > 0);
  await app.eval(`return globalThis.expo.modules.SolaraCEF.devWindow(${secondWindow.number},"close-button");`);
  const closedDeadline = Date.now() + 10000;
  let ended = false;
  while (Date.now() < closedDeadline) {
    assert.ok(app.alive, "closing second window exited");
    ended = await app.eval(`return !ac.store.getState().windows[${JSON.stringify(second)}] && globalThis.expo.modules.SolaraWindowShell.nativeLayoutGeneration(${JSON.stringify(second)}) === 0;`);
    if (ended) break;
    await sleep(100);
  }
  assert.equal(ended, true, "actual close retires its owner");
  await app.eval(`return globalThis.expo.modules.SolaraSettings.publish("sidebar.nativeFeed",JSON.stringify({windows:{[${JSON.stringify(second)}]:{generation:${secondGeneration},state:"{}"}}}));`);
  const closedWork = await app.eval('return globalThis.expo.modules.SolaraWindowShell.nativeWork(false).then(JSON.parse);');
  assert.equal(closedWork.hosts.some(host => host.windowId === second), false, "late feed cannot revive a closed owner");
  verify(await settled(), before);
  assert.deepEqual(await registrations(), pageRegistrations);
  console.log("PASS native owner/subscriptions, stable chrome and page identities, factory fences, retained last window");
} finally {
  writeFileSync(join(scratch, "samples.json"), JSON.stringify(samples, null, 2));
  await app.quit();
  console.log(`evidence: ${scratch}`);
}
