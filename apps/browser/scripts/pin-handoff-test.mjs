import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((arg) => !arg.startsWith("--"));
if (!appArg || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error("usage: node pin-handoff-test.mjs <Debug Solara.app> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pin-handoff-"));
const rep = reporter(join(scratch, "pin-handoff-test.log"), { name: "pin-handoff-test" });
const server = createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/html" });
  response.end('<!doctype html><title>PIN</title><body style="background:#acd;font:36px sans-serif">Shared page<input value="kept"></body>');
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}/pin`;
let app;
let page;
const until = async (name, body, milliseconds = 12000) => {
  const deadline = Date.now() + milliseconds;
  let last;
  while (Date.now() < deadline) {
    assert.ok(app.alive, "the owned app is alive");
    last = await app.eval(body, { timeout: 1500 });
    if (last) return last;
    await sleep(100);
  }
  throw new Error(`${name}: never matched (${JSON.stringify(last)})`);
};
const overlays = 'globalThis.expo.modules.SolaraMedia.describePaneOverlays("w1").then(JSON.parse)';
try {
  for (const appearance of ["light", "dark"]) {
    await rep.check(`${appearance}-handoff`, async () => {
      app = await launch(resolve(appArg), {
        data: join(scratch, appearance), fresh: true, onboarded: true, probe: true,
        session: session({
          windows: [{ id: "w1", activeTabIds: { default: "a" } }],
          tabs: [{ id: "a", url, title: "PIN" }],
          settings: { appearance, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
        }),
      });
      await until("page ready", 'return ac.store.getState().tabs.a?.title === "PIN" && !!ac.webviews.get("a");');
      page = await app.page("/pin");
      await page.eval('globalThis.pinHandoffMarker = "same-document"; true');
      const originalTarget = await app.pageTarget("/pin");
      const number = await app.eval('return globalThis.expo.modules.SolaraCEF.chromeWindows().then(windows => windows.find(window => window.visible)?.window);');
      assert.ok(number, "the source window has a native number");
      await app.eval('ac.store.getState().pinTabs(["a"], true); return true;');
      const target = await app.eval('return ac.store.getState().createWindow({ url: "about:blank" });');
      const copy = await until("mirrored copy", `return Object.values(ac.store.getState().tabs).find(tab => tab.windowId === ${JSON.stringify(target)} && tab.pinned && (tab.pinKey ?? tab.id) === "a")?.id;`);
      await app.eval(`ac.store.getState().activate(${JSON.stringify(copy)}); return true;`);
      const frozen = await until("page handed to the target window", 'const state = ac.store.getState(); return state.tabs.a?.windowId !== "w1" && Object.values(state.tabs).find(tab => tab.windowId === "w1" && tab.pageIn === "a")?.id;');
      const cover = await until("native frozen cover", `return ${overlays}.then(value => { const cover = value?.tabs?.[${JSON.stringify(frozen)}]?.frozenPage; return cover?.hasImage ? cover : null; });`);
      assert.equal(cover.dark, appearance === "dark", "the native wash uses the window appearance");
      assert.ok(cover.frame[2] > 0 && cover.frame[3] > 0, "the native cover fills a real page area");
      const rnDrawing = await app.eval('const fibers = acPerf.findFibers("FrozenPage", 20); return fibers.some(fiber => { const pending = [fiber.child]; while (pending.length) { const node = pending.pop(); if (!node) continue; const name = node.elementType?.displayName ?? node.elementType?.name ?? node.elementType; if (["Image", "ImageBackground", "Pressable"].includes(name)) return true; pending.push(node.child, node.sibling); } return false; });');
      assert.equal(rnDrawing, false, "the frozen adapter mounts no React drawing");
      assert.equal((await app.pageTarget("/pin"))?.id, originalTarget.id, "handoff retains the Chrome target");
      assert.deepEqual(await page.eval('[globalThis.pinHandoffMarker, document.querySelector("input").value]'), ["same-document", "kept"], "the shared page retains its document");
      await sleep(250);
      const image = join(scratch, `${appearance}.png`);
      assert.ok(await app.eval(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(image)});`, { timeout: 5000 }), "in-process frozen snapshot succeeds");
      const snapshot = await app.snapshot();
      assert.ok(snapshot.consistent && snapshot.tabs.some((tab) => tab.id === "a" && tab.windowId === target), "the native snapshot confirms the live page moved");
      const point = [cover.frame[0] + cover.frame[2] / 2, cover.frame[1] + cover.frame[3] / 2];
      const hit = await app.eval(`globalThis.pinHandoffEvents = []; globalThis.expo.modules.SolaraHosted.addListener("onHostedEvent", event => { if (event.kind === "frozenPage") globalThis.pinHandoffEvents.push(event); }); return globalThis.expo.modules.SolaraCEF.devWindow(${number}, ${JSON.stringify(`hit:${point.join(",")}`)});`);
      writeFileSync(join(scratch, `${appearance}-before-click.json`), JSON.stringify({ frozen, copy, cover, number, point, hit }, null, 2));
      assert.match(hit, /FrozenPageView/, "the real window hit must reach the native frozen cover");
      await app.eval(`const C = globalThis.expo.modules.SolaraCEF; const point = ${JSON.stringify(point)}; const settle = () => new Promise(done => setTimeout(done, 30)); return ac.shell.devSetPointer("w1", { x: point[0], y: point[1] }).then(() => C.devWindow(${number}, "mouse:moved:" + point.join(","))).then(settle).then(() => C.devWindow(${number}, "mouse:down:" + point.join(","))).then(settle).then(() => C.devWindow(${number}, "mouse:up:" + point.join(","))).then(() => true);`);
      await sleep(250);
      const clicked = await app.eval('return { events: globalThis.pinHandoffEvents, tabs: Object.values(ac.store.getState().tabs).map(tab => ({ id: tab.id, windowId: tab.windowId, pageIn: tab.pageIn })), adapters: acPerf.findFibers("FrozenPage", 20).map(fiber => { const states = []; for (let hook = fiber.memoizedState; hook; hook = hook.next) { const current = hook.memoizedState?.current; if (current?.copyId) states.push({ token: current.token, windowId: current.windowId, tabId: current.tabId, copyId: current.copyId, frozen: current.frozen, uriLength: current.uri?.length }); } return { props: fiber.memoizedProps, states }; }) };');
      writeFileSync(join(scratch, `${appearance}-after-click.json`), JSON.stringify(clicked, null, 2));
      await until("click returns the shared page to the source window", 'return ac.store.getState().tabs.a?.windowId === "w1";');
      await until("native cover goes away", `return ${overlays}.then(value => !Object.values(value?.tabs ?? {}).some(tab => tab.frozenPage) || null);`);
      assert.equal((await app.pageTarget("/pin"))?.id, originalTarget.id, "pullback retains the Chrome target");
      assert.deepEqual(await page.eval('[globalThis.pinHandoffMarker, document.querySelector("input").value]'), ["same-document", "kept"], "pullback retains the same document");
      writeFileSync(join(scratch, `${appearance}.json`), JSON.stringify({ target, copy, frozen, cover, snapshot, returned: await app.snapshot() }, null, 2));
      page.close();
      page = null;
      await app.quit();
      app = null;
      return { image, copy, frozen, target: originalTarget.id, frame: cover.frame };
    });
    page?.close();
    page = null;
    await app?.quit();
    app = null;
  }
} catch (error) {
  rep.record("run", { error });
} finally {
  page?.close();
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((result) => !result.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed; ${rep.logFile}`);
process.exit(failed.length ? 1 : 0);
