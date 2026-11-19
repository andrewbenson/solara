import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
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
    const presentation = last?.layout?.presentation;
    const settled = last?.layout?.current === true && presentation?.railProgress === null
      && Math.abs(presentation.sidebarWidth - last.layout.sidebarWidth) <= 0.5;
    if (settled && row?.[2] > 0 && row?.[3] > 0 && last.trafficLights?.length === 3 && hasPage) return { state: last, row };
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
  const centres = state.trafficLights.map(light => light.rect[0] + light.rect[2] / 2);
  for (const light of state.trafficLights) {
    assert.equal(light.rect[2], 14, `${name}: standard button width`);
    assert.equal(light.rect[3], 14, `${name}: standard button height`);
  }
  assert.equal(centres[1] - centres[0], 23, `${name}: close to minimize pitch`);
  assert.equal(centres[2] - centres[1], 23, `${name}: minimize to zoom pitch`);
  console.log(`PASS ${name}: actual lights share the first chrome centre ${wantedY}`);
}

async function assertFullscreenIsland(app, mode) {
  const inventory = await app.eval('return expo.modules.SolaraApp.devWindowLifecycle("inventory",false);');
  const number = inventory.windows.find(window => window.id === "w1")?.number;
  assert.ok(Number.isInteger(number), `${mode}: actual Chrome window exists`);
  const act = action => app.eval(`return expo.modules.SolaraCEF.devWindow(${number},${JSON.stringify(action)});`);
  const read = () => app.eval('return expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse);', { timeout: 1000 });
  const reveal = progress => app.eval(`return expo.modules.SolaraWindowShell.devCaptionIsland("w1",${progress},0).then(JSON.parse);`);
  const samples = [];
  try {
    await act("fakeFullScreen:1:0");
    const deadline = Date.now() + 10000;
    let state;
    while (Date.now() < deadline) {
      assert.ok(app.alive, `${mode}: owned instance exited entering fullscreen`);
      state = await read();
      if (state?.layout?.windowFullscreen) break;
      await sleep(25);
    }
    assert.equal(state?.layout?.windowFullscreen, true, `${mode}: acted Spaces fullscreen settled`);
    for (const appearance of ["light", "dark"]) {
      await app.eval(`ac.store.getState().updateSettings({appearance:${JSON.stringify(appearance)}});return true;`);
      const end = await reveal(1);
      assert.ok(end && !end.error, `${mode}: production fullscreen island exists`);
      assert.equal(end.windowFullscreen, true);
      assert.deepEqual(end.enabled, [true, false, true], `${mode}: system minimize is disabled in fullscreen`);
      assert.deepEqual([end.frame.width, end.frame.height, end.radius], [80, 33, 16.5]);
      assert.deepEqual(end.buttonFrames, [10, 33, 56].map(x => ({ x, y: 9.5, width: 14, height: 14 })));
      assert.equal(end.alpha, 1, `${mode}: revealed island is opaque as a view`);
      assert.ok(end.borderWidth > 0 && end.borderWidth <= 1, `${mode}: single physical pixel rim`);
      assert.equal(end.fill.length, 4);
      assert.equal(end.rim.length, 4);
      for (const [index, value] of end.fill.entries()) {
        assert.ok(Math.abs(value - [34 / 255, 52 / 255, 72 / 255, 0.9][index]) < 0.0001);
      }
      for (const [index, value] of end.rim.entries()) {
        assert.ok(Math.abs(value - [57 / 255, 74 / 255, 93 / 255, 1][index]) < 0.0001);
      }
      for (const progress of [0, 0.25, 0.5, 1, 0.75, 0.25, 0]) {
        const sample = await reveal(progress);
        samples.push({ appearance, progress, ...sample });
        assert.equal(sample.hidden, progress === 0);
        assert.equal(sample.alpha, 1, `${mode}: slide never fades the capsule`);
        const offset = -(end.frame.y + end.frame.height) * (1 - progress);
        assert.ok(Math.abs(sample.slideOffset - offset) < 0.001, `${mode}: slide endpoint at ${progress}`);
        if (progress > 0) assert.ok(Math.abs(sample.frame.y - end.frame.y - offset) < 0.001,
          `${mode}: capsule follows the reveal progress at ${progress}`);
      }
    }
    console.log(`PASS ${mode}: fullscreen capsule geometry, slide and disabled minimize`);
  } finally {
    writeFileSync(join(out, `${mode}-island.json`), JSON.stringify(samples, null, 2));
    await act("fakeFullScreen:0:0");
  }
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
    await assertFullscreenIsland(app, mode);
  } finally {
    if (app) await app.quit();
  }
}
