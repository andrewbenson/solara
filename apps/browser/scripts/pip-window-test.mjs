import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { frontApp, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const positionals = args.filter((arg) => !arg.startsWith("--"));
if (args.includes("--help") || positionals.length !== 2) {
  console.log("usage: METRO_PORT=8106 node pip-window-test.mjs <Debug Solara.app> <output-directory> [--before]");
  process.exit(args.includes("--help") ? 0 : 2);
}
const before = args.includes("--before");
const output = resolve(positionals[1]);
mkdirSync(output, { recursive: true });
const data = mkdtempSync(join(output, "data-"));
const rep = reporter(join(output, "pip-window-test.log"), { name: "pip-window-test" });
const evidence = { mode: before ? "baseline" : "fixed", spaceChange: "in-process notification simulation", accessibility: "AppKit geometry permissions and external AXUIElement setter outcomes are observed when already trusted; the probe never requests permission", frontBefore: frontApp(), snapshots: [], placements: [], externalAX: [] };
const axProbe = join(output, "pip-ax-probe");
const fixture = `<!doctype html><title>PiP window fixture</title><body><canvas id="c" width="640" height="360"></canvas><video id="v" muted playsinline></video><script>
const canvas = document.getElementById("c");
const context = canvas.getContext("2d");
let count = 0;
function paint() {
  context.fillStyle = count++ % 2 ? "#315a85" : "#294b70";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "white";
  context.font = "28px sans-serif";
  context.fillText("PiP placement " + count, 24, 70);
}
paint();
setInterval(paint, 40);
v.srcObject = canvas.captureStream(25);
window.openVideo = async () => { await v.play(); await v.requestPictureInPicture(); return "video opened"; };
window.openDocument = async () => {
  window.pipDocument = await documentPictureInPicture.requestWindow({width: 360, height: 220});
  pipDocument.document.body.textContent = "Document PiP placement fixture";
  return "document opened";
};
</script>`;
const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  response.end(fixture);
});
let app;
let page;
const deadline = async (name, operation, timeout = 10000) => {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    if (!app?.alive) throw new Error("the hidden instance exited");
    last = await operation();
    if (last) return last;
    await sleep(100);
  }
  throw new Error(`${name} timed out after ${timeout} ms; last=${JSON.stringify(last)}`);
};
const snapshots = () => app.eval("return globalThis.expo.modules.SolaraCEF.devPictureInPicture()", { timeout: 5000 });
const action = (value) => app.eval(`return globalThis.expo.modules.SolaraCEF.devPictureInPictureAction(${JSON.stringify(value)})`, { timeout: 5000 });
async function current(kind) {
  return deadline(`${kind} PiP window`, async () => (await snapshots()).find((window) => window.visible && window[kind]));
}
function checkHidden(label, window) {
  const front = frontApp();
  assert.notEqual(front?.pid, app.pid, "Solara became the frontmost application");
  assert.equal(window.alpha, 0, "the test PiP window is visible to the owner");
  assert.equal(window.ignoresMouseEvents, true, "the test PiP window intercepts mouse events");
  evidence.snapshots.push({ label, front, window });
}
function checkSettings(window, top = true) {
  assert.equal(window.allSpaces, true);
  assert.equal(window.fullScreenAuxiliary, true);
  assert.equal(window.level, top ? 3 : 0);
  if (before) return;
  assert.equal(window.canJoinAllApplications, true);
  assert.equal(window.stationary, true);
  assert.equal(window.excludesWindowsMenu, true);
  assert.equal(window.disallowsTiling, true);
  assert.equal(window.role, "AXWindow");
  assert.equal(window.subrole, "AXFloatingWindow");
  assert.equal(typeof window.positionWritable, "boolean");
  assert.equal(typeof window.sizeWritable, "boolean");
}
async function placement(kind) {
  if (before) return { baseline: true, note: "placement hook absent from baseline" };
  const result = JSON.parse(await action(`placement:${kind}`));
  evidence.placements.push({ kind, ...result });
  assert.ok(Array.isArray(result.steps) && result.steps.length > 0, "no native placement checks ran");
  for (const step of result.steps) assert.equal(step.pass, true, `${kind}: ${step.step}: ${JSON.stringify(step)}`);
  assert.equal(typeof result.placedFrame, "string", "native placement omitted its expected frame");
  assert.notEqual(result.chosenScreenID, undefined, "native placement omitted its selected display");
  await sleep(600);
  const settled = await current(kind);
  checkHidden(`${kind}-placement-settled`, settled);
  checkSettings(settled, settled.level !== 0);
  assert.equal(settled.frame, result.placedFrame, `${kind}: PiP moved after lifecycle notifications settled`);
  assert.equal(settled.screenID, result.chosenScreenID, `${kind}: PiP changed displays after lifecycle notifications settled`);
  result.settled = settled;
  const probeRun = spawnSync("timeout", ["15", axProbe, String(app.pid), String(settled.window)], { encoding: "utf8", timeout: 16000 });
  if (probeRun.error) throw probeRun.error;
  const external = JSON.parse(probeRun.stdout);
  evidence.externalAX.push({ kind, ...external });
  assert.equal(probeRun.status, 0, JSON.stringify(external));
  if (external.skipped) rep.record(`${kind} external AX setter observation (level ${settled.level})`, { skip: external.skipped, evidence: external });
  else {
    await sleep(600);
    const afterExternal = await current(kind);
    checkHidden(`${kind}-external-ax-settled`, afterExternal);
    external.after = afterExternal;
    assert.equal(external.trusted, true);
    assert.equal(external.role, "AXWindow");
    assert.equal(external.subrole, "AXFloatingWindow");
    assert.equal(external.positionQueryStatus, 0);
    assert.equal(external.sizeQueryStatus, 0);
    assert.equal(typeof external.positionWritable, "boolean");
    assert.equal(typeof external.sizeWritable, "boolean");
    assert.equal(typeof external.positionWriteStatus, "number");
    assert.equal(typeof external.sizeWriteStatus, "number");
    assert.equal(external.geometryRead, true, "external AX geometry could not be read after attempted writes");
    assert.equal(typeof external.geometryChanged, "boolean");
    assert.equal(external.geometryRestored, true, "the AX probe could not restore the original geometry");
    assert.equal(afterExternal.frame, settled.frame, "the AX probe did not restore the PiP frame");
    assert.equal(afterExternal.screenID, settled.screenID, "the AX probe did not restore the PiP display");
    rep.say(`${kind}: observed external AX setters: ${JSON.stringify(external)}`);
  }
  if (!result.secondDisplay) rep.say(`SKIP ${kind}: second physical display is not connected`);
  return result;
}

try {
  if (!before) execFileSync("timeout", ["30", "clang", "-fobjc-arc", "-fmodules", `-fmodules-cache-path=${join(output, "clang-module-cache")}`, "-framework", "AppKit", "-framework", "ApplicationServices", join(dirname(fileURLToPath(import.meta.url)), "pip-ax-probe.m"), "-o", axProbe], { encoding: "utf8", timeout: 31000 });
  await new Promise((accept, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", accept);
  });
  const url = `http://127.0.0.1:${server.address().port}/pip-window`;
  app = await launch(resolve(positionals[0]), {
    data, keepData: true, metroPort: Number(process.env.METRO_PORT ?? 8106), js: "live", onboarded: true, probe: true,
    session: session({ windows: [{ id: "w-pip" }], tabs: [{ id: "t-pip", url }] }),
    env: { SOLARA_ACCEPT_EXTERNAL_URLS: "1" }, ready: { timeout: 90000 },
  });
  page = await app.page(url);
  await deadline("canvas video metadata", () => page.eval("typeof openVideo === 'function' && v.readyState >= 2"));
  await rep.check("video PiP window settings and hidden focus guard", async () => {
    assert.equal(await page.eval("openVideo()", { userGesture: true }), "video opened");
    await current("video");
    await action("keepOnTop:1");
    const window = await current("video");
    checkHidden("video-on", window);
    checkSettings(window);
    return window;
  });
  if (before) rep.record("video PiP lifecycle placement", { skip: "the baseline has no placement hook" });
  else await rep.check("video PiP keeps its chosen display through simulated lifecycle notifications", () => placement("video"));
  await rep.check("Keep Window on Top off and on preserves PiP policy", async () => {
    await action("keepOnTop:0");
    const off = await deadline("normal PiP level", async () => { const value = await current("video"); return value.level === 0 && value; });
    checkHidden("video-off", off);
    checkSettings(off, false);
    await placement("video");
    await action("keepOnTop:1");
    const on = await deadline("floating PiP level", async () => { const value = await current("video"); return value.level === 3 && value; });
    checkHidden("video-restored", on);
    checkSettings(on);
    return { off, on };
  });
  await page.eval("document.pictureInPictureElement ? document.exitPictureInPicture() : true");
  await deadline("video PiP closed", async () => !(await snapshots()).some((window) => window.visible && window.video));
  await rep.check("document PiP window settings and hidden focus guard", async () => {
    assert.equal(await page.eval("openDocument()", { userGesture: true }), "document opened");
    const window = await current("document");
    checkHidden("document", window);
    checkSettings(window);
    return window;
  });
  if (before) rep.record("document PiP lifecycle placement", { skip: "the baseline has no placement hook" });
  else await rep.check("document PiP keeps its chosen display through simulated lifecycle notifications", () => placement("document"));
  await page.eval("window.pipDocument?.close(); true");
  await deadline("document PiP closed", async () => !(await snapshots()).some((window) => window.visible && window.document));
  await rep.check("hidden instance never becomes the frontmost application", async () => {
    evidence.frontAfter = frontApp();
    assert.notEqual(evidence.frontAfter?.pid, app.pid);
    return { pid: app.pid, front: evidence.frontAfter };
  });
} catch (error) {
  rep.record("PiP driver", { error });
} finally {
  page?.close();
  if (app) {
    try {
      evidence.quit = await app.quit({ timeout: 10000 });
      assert.ok(app.exited, "the hidden instance did not exit");
    } catch (error) {
      rep.record("hidden instance cleanup", { error });
    }
  }
  if (server.listening) await new Promise((accept) => { server.closeAllConnections(); server.close(accept); });
  evidence.results = rep.results;
  writeFileSync(join(output, "pip-window-results.json"), `${JSON.stringify(evidence, null, 2)}\n`);
}
const failures = rep.results.filter((result) => !result.ok);
const skipped = rep.results.filter((result) => result.skipped).length;
rep.say(`${rep.results.length - failures.length - skipped} passed, ${failures.length} failed, ${skipped} skipped; evidence: ${join(output, "pip-window-results.json")}`);
process.exit(failures.length ? 1 : 0);
