import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appPath, scratchPath] = process.argv.slice(2);
if (!appPath || !scratchPath) {
  console.error("usage: node little-extension-popup-test.mjs <Debug app> <scratch directory>");
  process.exit(2);
}
const scratch = resolve(scratchPath);
mkdirSync(scratch, { recursive: true });
const fixturePath = join(scratch, "extension");
mkdirSync(fixturePath, { recursive: true });
writeFileSync(join(fixturePath, "manifest.json"), JSON.stringify({ manifest_version: 3, name: "Little popup fixture", version: "1.0", action: { default_popup: "popup.html" }, background: { service_worker: "worker.js" } }));
writeFileSync(join(fixturePath, "worker.js"), "chrome.runtime.onInstalled.addListener(() => {});");
writeFileSync(join(fixturePath, "popup.html"), '<!doctype html><title>Little popup fixture</title><body style="margin:0;width:200px;height:80px;background:white"><button id="press">Press</button><script src="popup.js"></script></body>');
writeFileSync(join(fixturePath, "popup.js"), "document.getElementById('press').addEventListener('click',()=>{document.body.dataset.pressed='yes'});");
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<title>Little popup page</title><body style="background:white">${req.url}</body>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}`;
const rep = reporter(join(scratch, "results.log"), { name: "little-extension-popup" });
let app;
let little;
let extensionId;
const run = (body) => app.eval(body, { timeout: 10000 });
const until = async (name, test, timeout = 10000) => {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    assert.ok(app.alive, `${name}: app exited`);
    last = await test();
    if (last) return last;
    await sleep(100);
  }
  throw new Error(`${name}: deadline; ${JSON.stringify(last)}`);
};
const popup = (windowId) => run(`return globalThis.expo.modules.SolaraToolbar.devExtensionPopup(${JSON.stringify(windowId)}).then(JSON.parse)`);
const act = (number, action) => run(`return globalThis.expo.modules.SolaraCEF.devWindow(${number}, ${JSON.stringify(action)})`);
const click = async (number, x, y) => {
  for (const kind of ["moved", "down", "up"]) {
    await act(number, `mouse:${kind}:${Math.round(x)},${Math.round(y)}`);
    await sleep(40);
  }
};
const closed = (id) => until("popup fully released", async () => {
  const info = await popup(id);
  return !info.frame && info.liveViews === 0 && !(await app.targets()).some((target) => target.url.includes(`${extensionId}/popup.html`));
});
const open = async (windowId, tabId) => {
  await run(`return globalThis.expo.modules.SolaraToolbar.extensionCommand(JSON.stringify({ command: "openExtension", windowId: ${JSON.stringify(windowId)}, id: ${JSON.stringify(extensionId)}, tabId: ${JSON.stringify(tabId)} })).then(() => true)`);
  const info = await until("native popup appeared", async () => {
    const value = await popup(windowId);
    return value.frame?.[2] > 100 && value.appeared ? value : null;
  });
  assert.equal(info.extensionId, extensionId);
  assert.equal(info.tabId, tabId);
  assert.ok(Math.abs(info.frame[2] - 201) <= 0.5);
  assert.ok(Math.abs(info.frame[3] - 81) <= 0.5);
  return info;
};
const capture = async (id, label, info) => {
  await sleep(200);
  const path = join(scratch, `${label}.png`);
  assert.equal(await run(`return ac.shell.devSnapshotWindow(${JSON.stringify(id)}, ${JSON.stringify(path)})`), true);
  writeFileSync(join(scratch, `${label}.json`), JSON.stringify(info, null, 2));
  const page = await app.page(`${extensionId}/popup.html`);
  try {
    const picture = await page.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
    writeFileSync(join(scratch, `${label}-page.png`), Buffer.from(picture.data, "base64"));
  } finally { page.close(); }
};
const createLittle = async () => {
  const before = await run("return globalThis.expo.modules.SolaraCEF.chromeWindows().then(ws => ws.map(w => w.window))");
  const id = await run(`return ac.store.getState().createWindow({ small:true, url:${JSON.stringify(`${url}/little`)} })`);
  const tabId = await until("Little page loaded", async () => run(`const s=ac.store.getState(); const id=s.windows[${JSON.stringify(id)}]?.tabIds[0]; return id && s.tabs[id]?.title === 'Little popup page' && !s.live[id]?.isLoading ? id : null`));
  const number = await until("Little native window", async () => run(`return globalThis.expo.modules.SolaraCEF.chromeWindows().then(ws=>ws.find(w=>!${JSON.stringify(before)}.includes(w.window) && w.visible)?.window)`));
  await act(number, "fakeActiveClicks");
  return { id, tabId, number };
};
try {
  app = await launch(resolve(appPath), {
    data: join(scratch, "data"), fresh: true, onboarded: true, probe: true,
    session: session({ windows: [{ id: "main", frame: [80, 80, 900, 640], activeTabIds: { default: "main-tab" } }], tabs: [{ id: "main-tab", url: `${url}/main`, title: "Little popup page" }], settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false, tabLayout: "top" } }),
    ready: "return !!ac.store.getState().windows.main",
  });
  await rep.check("fixture", async () => {
    const installed = await run(`return globalThis.expo.modules.SolaraExtensions.install(${JSON.stringify(fixturePath)}, '')`);
    extensionId = installed.id;
    assert.ok(extensionId, JSON.stringify(installed));
    await run("return ac.extensions.refreshExtensions('')");
    little = await createLittle();
    return little;
  });
  await rep.check("matched-native-frames-and-hit", async () => {
    const main = await open("main", "main-tab");
    await capture("main", "main-popup", main);
    await run("ac.extensions.closeExtensionPopup(); return true");
    await closed("main");
    const info = await open(little.id, little.tabId);
    assert.ok(Math.abs(info.anchor[0] - (info.window[0] - 34)) <= 0.5);
    assert.deepEqual(info.anchor.slice(1), [5, 28, 28]);
    const [x, y, width, height] = info.frame;
    assert.ok(x >= 8 && y >= 8 && x + width <= info.window[0] - 7.5 && y + height <= info.window[1] - 7.5);
    const hit = String(await act(little.number, `hit:${x + 20},${y + 12}`));
    assert.ok(hit.includes("RenderWidgetHostViewCocoa"), hit);
    await capture(little.id, "little-popup", info);
    const page = await app.page(`${extensionId}/popup.html`);
    try {
      await click(little.number, x + 20, y + 12);
      assert.equal(await page.eval("document.body.dataset.pressed"), "yes");
    } finally { page.close(); }
    return { main: main.frame, little: info.frame, hit };
  });
  await rep.check("live-window-resize-keeps-the-anchor", async () => {
    const source = await app.pageTarget(`${url}/little`);
    assert.ok(source);
    const browser = await app.browser();
    const samples = [];
    let original;
    let before;
    try {
      original = await browser.send("Browser.getWindowForTarget", { targetId: source.id });
      before = await popup(little.id);
      await browser.send("Browser.setWindowBounds", { windowId: original.windowId, bounds: { width: original.bounds.width + 100, height: original.bounds.height + 60 } });
      const resized = await until("native popup follows resized Little window", async () => {
        const info = await popup(little.id);
        samples.push(info);
        if (!info.frame || Math.abs(info.window[0] - before.window[0] - 100) > 0.5 || Math.abs(info.window[1] - before.window[1] - 60) > 0.5) return null;
        const [x, y, width, height] = info.frame;
        const [ax, ay, aw, ah] = info.anchor;
        const expectedX = Math.max(8, Math.min(ax + aw - width, info.window[0] - 8 - width));
        const expectedY = Math.max(8, Math.min(ay + ah + 6, info.window[1] - 8 - height));
        if (Math.abs(ax - info.window[0] + 34) > 0.5 || Math.abs(x - expectedX) > 0.5 || Math.abs(y - expectedY) > 0.5) return null;
        assert.deepEqual(info.frame.slice(2), before.frame.slice(2));
        assert.deepEqual(info.anchor.slice(1), [5, 28, 28]);
        return info;
      });
      await capture(little.id, "little-popup-resized", resized);
      return { before: before.window, resized: resized.window, rightInset: resized.window[0] - resized.frame[0] - resized.frame[2] };
    } finally {
      writeFileSync(join(scratch, "little-popup-resize-samples.json"), JSON.stringify({ original, before, samples }, null, 2));
      try {
        if (original && before) {
          await browser.send("Browser.setWindowBounds", { windowId: original.windowId, bounds: { width: original.bounds.width, height: original.bounds.height } });
          await until("Little window restored", async () => Math.abs((await popup(little.id)).window[0] - before.window[0]) <= 0.5);
        }
      } finally { browser.close(); }
    }
  });
  await rep.check("size-and-page-dismissal", async () => {
    const page = await app.page(`${extensionId}/popup.html`);
    try {
      for (const [width, height] of [[420, 230], [60, 30]]) {
        await page.eval(`document.body.style.width='${width}px';document.body.style.height='${height}px';true`);
        await until("popup follows preferred size", async () => {
          const info = await popup(little.id);
          return info.frame && Math.abs(info.frame[2] - width - 1) <= 0.5 && Math.abs(info.frame[3] - height - 1) <= 0.5;
        });
      }
    } finally { page.close(); }
    await click(little.number, 150, 300);
    await closed(little.id);
    assert.equal((await popup(little.id)).focusedTabId, little.tabId);
    return true;
  });
  await rep.check("toggle-and-navigation", async () => {
    await open(little.id, little.tabId);
    await run(`return globalThis.expo.modules.SolaraToolbar.extensionCommand(JSON.stringify({ command: "openExtension", windowId: ${JSON.stringify(little.id)}, id: ${JSON.stringify(extensionId)}, tabId: ${JSON.stringify(little.tabId)} })).then(() => true)`);
    await closed(little.id);
    await open(little.id, little.tabId);
    await run(`ac.store.getState().navigate(${JSON.stringify(little.tabId)}, ${JSON.stringify(`${url}/navigated`)}); return true`);
    await closed(little.id);
    await until("navigated Little page", async () => run(`return !ac.store.getState().live[${JSON.stringify(little.tabId)}]?.isLoading`));
    return true;
  });
  await rep.check("escape-keeps-little-open", async () => {
    await open(little.id, little.tabId);
    const page = await app.page(`${extensionId}/popup.html`);
    try {
      for (const type of ["rawKeyDown", "keyUp"]) await page.send("Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53 }).catch(() => null);
    } finally { page.close(); }
    await closed(little.id);
    assert.ok(await run(`return !!ac.store.getState().windows[${JSON.stringify(little.id)}]`));
    return true;
  });
  await rep.check("inactive-api-refused", async () => {
    await act(little.number, "fakeAppActive:0");
    try {
      await run(`return globalThis.expo.modules.SolaraToolbar.extensionCommand(JSON.stringify({ command: "openExtension", windowId: ${JSON.stringify(little.id)}, id: ${JSON.stringify(extensionId)}, tabId: ${JSON.stringify(little.tabId)}, requiresActive: true })).then(() => true)`);
      assert.equal((await popup(little.id)).extensionId, null);
      await closed(little.id);
      await open(little.id, little.tabId);
      await run("ac.extensions.closeExtensionPopup(); return true");
      await closed(little.id);
    } finally { await act(little.number, "fakeAppActive:1"); }
    return true;
  });
  await rep.check("bar-first-click-dismisses-then-expands-the-source", async () => {
    const info = await open(little.id, little.tabId);
    await click(little.number, info.window[0] - 20, 19);
    await closed(little.id);
    assert.ok(await run(`return !!ac.store.getState().windows[${JSON.stringify(little.id)}]`), "the first chrome click should only dismiss the popup");
    await click(little.number, info.window[0] - 20, 19);
    await until("Open in Solara moves the source", async () => run(`const s=ac.store.getState();return !s.windows[${JSON.stringify(little.id)}] && s.tabs[${JSON.stringify(little.tabId)}]?.windowId === 'main'`));
    return true;
  });
  await rep.check("closing-little-releases-popup", async () => {
    little = await createLittle();
    await open(little.id, little.tabId);
    await run(`ac.store.getState().closeWindow(${JSON.stringify(little.id)}); return true`);
    await closed(little.id);
    return true;
  });
} finally {
  if (app) await app.quit();
  await new Promise((done) => server.close(done));
}
process.exitCode = rep.summary() ? 0 : 1;
