import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const appPath = process.argv[2];
if (!appPath) throw new Error("usage: node private-fullscreen-close-test.mjs <Debug Solara.app>");
const scratch = mkdtempSync(join(tmpdir(), "ac-private-fullscreen-close-"));
const rep = reporter(join(scratch, "private-fullscreen-close-test.log"), { name: "private-fullscreen-close-test" });
const fixture = session({
  windows: [{ id: "w1" }],
  tabs: [{ id: "anchor", url: "about:blank#anchor" }],
  settings: { tabLayout: "sidebar", warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const app = await launch(resolve(appPath), {
  data: join(scratch, "data"), session: fixture, onboarded: true, probe: true,
  env: { SOLARA_TRACE_VISIBILITY: "1", SOLARA_FAKE_FULLSCREEN_MS: "350" },
});

const run = (body) => app.eval(`
  const C = globalThis.expo.modules.SolaraCEF;
  const state = () => ac.store.getState();
  ${body}
`);
const act = (number, action) => run(`return C.devWindow(${number}, ${JSON.stringify(action)});`);
const chrome = () => run("return C.chromeWindows();");
const cgWindows = () => JSON.parse(execFileSync("osascript", ["-l", "JavaScript", "-e", `
  ObjC.import("CoreGraphics");
  JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)))
    .filter(w => w.kCGWindowOwnerPID === ${app.pid})
    .map(({ kCGWindowNumber, kCGWindowIsOnscreen, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds }) =>
      ({ kCGWindowNumber, kCGWindowIsOnscreen, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds })));
`], { timeout: 20000, encoding: "utf8" }));
const pressClose = (id) => run(`return ac.shell.devKeyEquivalent(${JSON.stringify(id)}, { key: "w", keyCode: 13, modifiers: ["command"], focus: "window" });`);
const until = async (label, read, ms = 8000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const value = await read();
    if (value) return value;
    await sleep(80);
  }
  throw new Error(`${label} timed out`);
};

async function open(incognito) {
  const ids = await run("return Object.keys(state().windows);");
  await run(`ac.runCommand({ command: "${incognito ? "newIncognitoWindow" : "newWindow"}", arg: null, windowId: "w1" }); return true;`);
  const model = await until("new single-tab window", () => run(`
    return Object.values(state().windows).find(w => !${JSON.stringify(ids)}.includes(w.id) &&
      !!w.incognito === ${incognito} && w.tabIds.length === 1) ?? null;
  `));
  const window = await until("mounted window", async () => {
    const win = (await app.snapshot({ windowId: model.id })).windows.find((w) => w.id === model.id);
    return win?.visible && win.chromeWindowNumber ? win : null;
  });
  return { id: model.id, tab: model.tabIds[0], number: window.chromeWindowNumber };
}

async function closeButton({ id, tab, number }) {
  const row = await until("sidebar row", () => run(`return ac.sidebarRows.measureRow(${JSON.stringify(id)}, ${JSON.stringify(tab)});`));
  const y = Math.round(row.y + row.height / 2);
  const x = Math.round(row.x + row.width - 17);
  await run(`return ac.shell.devSetPointer(${JSON.stringify(id)}, { x: ${Math.round(row.x + 30)}, y: ${y} });`);
  await sleep(350);
  await run(`return ac.shell.devSetPointer(${JSON.stringify(id)}, { x: ${x}, y: ${y} });`);
  await sleep(150);
  await act(number, `mouse:down:${x},${y}`);
  await sleep(70);
  await act(number, `mouse:up:${x},${y}`);
}

async function checkClose(incognito, fullScreen, button) {
  const target = await open(incognito);
  const { id, number } = target;
  const fullScreenState = async () => JSON.parse(await act(number, "fullScreen"));
  assert.equal((await fullScreenState()).fullScreen, false, "new window inherited full screen");
  if (fullScreen) {
    const entered = JSON.parse(await act(number, "fakeFullScreen:1"));
    assert.equal(entered.acted, true);
    assert.equal(entered.chromeCounts, true);
  }
  const survivors = (await chrome()).filter((w) => w.window !== number && w.hasRoot);
  const before = {
    chrome: (await chrome()).find((w) => w.window === number),
    app: (await app.snapshot({ windowId: id })).windows[0]?.visible,
    cgWindows: cgWindows(),
    fullScreen: await fullScreenState(),
  };
  const logStart = readFileSync(app.log, "utf8").length;
  if (button) await closeButton(target);
  else await pressClose(id);
  await until("close removed the workspace and Chrome window", async () => {
    const removed = await run(`return !state().windows[${JSON.stringify(id)}];`);
    return removed && !(await chrome()).some((w) => w.window === number);
  });
  await until("close released the AppKit window", async () => (await act(number, "fullScreen")) === "");
  const remaining = (await chrome()).filter((w) => w.hasRoot);
  const trace = readFileSync(app.log, "utf8").slice(logStart).split("\n").filter((line) => line.includes(`window ${number} acted `));
  const after = cgWindows();
  rep.log(JSON.stringify({ id, number, before, remaining, cgWindows: after, trace }));
  assert.ok(!after.some((w) => w.kCGWindowNumber === number), "window server still tracks the closed window");
  assert.deepEqual(remaining.map((w) => [w.window, w.visible]), survivors.map((w) => [w.window, w.visible]));
  assert.equal(trace.some((line) => line.includes("didExitFullScreen")), fullScreen, "full screen did not exit before close");
}

try {
  await rep.check("windowed-private-cmd-w", () => checkClose(true, false, false));
  await rep.check("fullscreen-private-cmd-w", () => checkClose(true, true, false));
  await rep.check("fullscreen-private-close-button", () => checkClose(true, true, true));
  await rep.check("fullscreen-normal-cmd-w", () => checkClose(false, true, false));
  await rep.check("next-window-opens-windowed", () => checkClose(true, false, false));
  process.exitCode = rep.summary() ? 0 : 1;
} finally {
  await app.quit();
}
