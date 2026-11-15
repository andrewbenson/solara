import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node native-layout-default-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8" }).trim(), "network.benson.solara.dev");
for (const key of ["SOLARA_NATIVE_WINDOW_LAYOUT", "SOLARA_NATIVE_SHELL", "SOLARA_SHELL_PANES", "SOLARA_NATIVE_PAGES_POOL", "SOLARA_SHELL_MAIN_TOP", "SOLARA_NATIVE_TOP_STRIP", "SOLARA_TAB_POOL", "SOLARA_NATIVE_SCOPE"]) {
  assert.equal(process.env[key], undefined, `default acceptance requires no ${key} override`);
}
mkdirSync(output, { recursive: true });
let app;
try {
  app = await launch(appPath, {
    data: join(output, "data"), fresh: true, onboarded: true, probe: true, keepData: true,
    session: session({ windows: [{ id: "w1", activeTabIds: { default: "a" } }], tabs: [{ id: "a", url: "about:blank", title: "Default layout" }] }),
    ready: 'return !!globalThis.acPerf && globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse).then(s=>s?.nativeLayout && s.layout?.current);',
  });
  const inspect = () => app.eval(`
    const W = globalThis.expo.modules.SolaraWindowShell;
    const shell = JSON.parse(await W.describe("w1"));
    const forbidden = ["LegacyWindow", "LegacyContentCard", "DockedLayout", "TopTabStrip", "TopStripPeek", "TabPane", "TabWebView", "EngineWebView", "LegacySwipeOverlay", "SwipeArea"];
    const mounted = Object.fromEntries(forbidden.map(name=>[name,acPerf.findFibers(name,2000).length]));
    const blockers = JSON.parse(await W.devReactBlockers("w1",24));
    return { shell, mounted, blockers };
  `);
  const evidence = [];
  for (const layout of ["sidebar", "top"]) {
    await app.eval(`ac.store.getState().updateSettings({tabLayout:${JSON.stringify(layout)}});return true;`);
    const deadline = Date.now() + 10000;
    let value;
    let native;
    let ready = false;
    while (Date.now() < deadline) {
      assert.ok(app.alive, "owned instance exited during layout projection");
      value = await inspect();
      native = await app.snapshot({ windowId: "w1" }, { timeout: 1000 });
      ready = value.shell.layout?.current && Array.isArray(value.shell.topStrip) === (layout === "top")
        && native.consistent && Object.values(value.mounted).every(count => count === 0) && value.blockers.length === 0;
      if (ready) break;
      await sleep(50);
    }
    assert.ok(ready, `layout did not settle before the deadline: ${JSON.stringify(value)}`);
    evidence.push({ layout, ...value, native });
    assert.equal(value.shell.nativeLayout, true);
    assert.equal(Array.isArray(value.shell.topStrip), layout === "top", "requested native layout is applied");
    assert.equal(value.shell.legacyLayoutReason, null);
    assert.equal(value.shell.layoutControllerSubscriptions, 1);
    assert.equal(value.shell.layout.maxError <= 0.5, true);
    assert.deepEqual(Object.values(value.mounted), Array(Object.keys(value.mounted).length).fill(0));
    assert.deepEqual(value.blockers, [], "no empty RN pointer blocker on the default path");
    const contract = native.windows.find(window => window.id === "w1")?.shell?.contract;
    assert.ok(contract, "native ownership probe is required");
    assert.equal(contract.nativeLayout, true);
    assert.equal(contract.ownerCount, 1);
    assert.equal(contract.hostCounts.WindowLayoutController, 1);
    assert.equal(contract.legacyLayoutStoreSubscriptions, 0);
    assert.equal(contract.childStoreSubscriptions, 0);
    assert.ok(contract.pageIdentities.some(page => page.tabId === "a"), "default page is owned by the native pool");
  }
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  console.log("PASS default native owner, pooled page, no RN layout/gesture hosts or empty pointer blockers");
} finally {
  if (app) await app.quit();
}
