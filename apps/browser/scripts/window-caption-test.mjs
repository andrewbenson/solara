import assert from "node:assert/strict";
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const { values, positionals } = parseArgs({ allowPositionals: true, options: { out: { type: "string" } } });
if (positionals.length !== 1 || !values.out) {
  console.error("usage: node apps/browser/scripts/window-caption-test.mjs <Debug Solara.app> --out <fresh scratch directory>");
  process.exit(2);
}
const appPath = resolve(positionals[0]);
const out = resolve(values.out);
mkdirSync(out, { recursive: true });

async function firstActualChrome(app, windowId, topTabs, icons) {
  const deadline = Date.now() + 15000;
  let last;
  while (Date.now() < deadline) {
    assert.ok(app.alive, `${windowId}: owned instance exited`);
    last = await app.eval(`return expo.modules.SolaraWindowShell.describe(${JSON.stringify(windowId)}).then(JSON.parse);`, { timeout: 1000 });
    const row = topTabs ? last?.layout?.actual?.topStrip : last?.layout?.actual?.["button:sidebar"];
    const hasPage = !icons || Object.keys(last?.layout?.actual ?? {}).some(key => key.startsWith("page:"));
    if (row?.[2] > 0 && row?.[3] > 0 && last.trafficLights?.length === 3 && hasPage) return { state: last, row };
    await sleep(25);
  }
  assert.fail(`${windowId}: no actual native chrome before deadline: ${JSON.stringify(last)}`);
}

function assertCentered({ state, row }, name, icons) {
  assert.equal(state.layout.windowFullscreen, false, `${name}: opened window stays windowed`);
  const wantedY = row[1] + row[3] / 2;
  if (icons) {
    assert.equal(wantedY, 16, `${name}: compact icon toolbar centre`);
    const pages = Object.entries(state.layout.actual).filter(([key]) => key.startsWith("page:"));
    assert.ok(pages.length, `${name}: actual page exists`);
    for (const [, page] of pages) assert.equal(page[1], 32, `${name}: compact icon page begins at 32 pt`);
  }
  for (const light of state.trafficLights) {
    assert.equal(light.hidden, false, `${name}: actual standard button is visible`);
    assert.ok(light.rect?.[2] > 0 && light.rect?.[3] > 0, `${name}: actual standard button has bounds`);
    const foundY = light.rect[1] + light.rect[3] / 2;
    assert.ok(Math.abs(foundY - wantedY) <= 0.5,
      `${name}: actual standard-button centre ${foundY} equals actual chrome centre ${wantedY}: ${JSON.stringify(state.trafficLights)}`);
  }
  console.log(`PASS ${name}: actual lights share the first chrome centre ${wantedY}`);
}

for (const mode of ["sidebar", "icons", "top"]) {
  const topTabs = mode === "top";
  const fixture = session({
    windows: [{ id: "w1", activeTabIds: { default: "a" } }],
    tabs: [{ id: "a", url: "data:text/html,<title>Caption</title>" }],
    settings: { tabLayout: topTabs ? "top" : "sidebar", sidebarIconsOnly: mode === "icons", hideToolbarWhileScrolling: false,
      warnBeforeClosingWindow: false, warnBeforeQuitting: false },
  });
  let app;
  try {
    app = await launch(appPath, { data: join(out, mode, "data"), session: fixture, onboarded: true, probe: true,
      ready: "return !!ac.store.getState().windows.w1;" });
    assertCentered(await firstActualChrome(app, "w1", topTabs, mode === "icons"), `${mode}: restored window before resize or fullscreen`, mode === "icons");
    const before = await app.eval("return ac.store.getState().windowOrder;");
    await app.eval('return expo.modules.SolaraApp.devMenuCommand("newWindow",null);');
    const deadline = Date.now() + 10000;
    let newId;
    while (Date.now() < deadline) {
      assert.ok(app.alive, `${mode}: owned instance exited while opening a window`);
      newId = await app.eval(`return ac.store.getState().windowOrder.find(id=>!${JSON.stringify(before)}.includes(id));`, { timeout: 1000 });
      if (newId) break;
      await sleep(25);
    }
    assert.ok(newId, `${mode}: new window exists before deadline`);
    assertCentered(await firstActualChrome(app, newId, topTabs, mode === "icons"), `${mode}: new window before resize or fullscreen`, mode === "icons");
  } finally {
    if (app) await app.quit();
  }
}
