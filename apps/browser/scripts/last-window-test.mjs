import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const checks = ["red close button", "Shift Command W", "File Close Window", "background reopen and activation refusal", "Dock delegate and activation callback ordering", "window menu and scripting exclusion", "live page and workspace identity", "Command N creates a distinct window", "private close", "two windows keep only the last", "rapid close preserves the last live workspace in both request orders", "hidden Chrome beforeunload quit cancellation and background-tab adoption", "simulated update termination and relaunch", "hidden Apple-event quit and relaunch under both restore preferences"];
const args = process.argv.slice(2);
if (args.includes("--list")) {
  checks.forEach((check) => console.log(check));
  process.exit(0);
}
const appPath = args.find((arg) => !arg.startsWith("--"));
if (!appPath || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error("usage: node apps/browser/scripts/last-window-test.mjs <Debug Solara.app> [--keep-data] | --list");
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "solara-last-window-"));
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<title>${req.url}</title><input id="draft"><script>window.nonce=crypto.randomUUID();window.unloads=0;addEventListener("beforeunload",()=>window.unloads++);</script>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const pageURL = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
let app;
let passed = false;
const run = (body) => app.eval(body, { timeout: 8000 });
const lifecycle = (action = "inventory", foreground = false) => run(`return expo.modules.SolaraApp.devWindowLifecycle(${JSON.stringify(action)},${foreground});`);
const state = () => run(`const s=ac.store.getState(); const w=s.windows.w1; return {window:w&&{id:w.id,profileId:w.profileId,tabIds:w.tabIds,activeTabIds:w.activeTabIds,sidebarOpen:w.sidebarOpen,keptOnClose:w.keptOnClose},tabs:Object.fromEntries(Object.entries(s.tabs).filter(([,t])=>t.windowId==="w1").map(([id,t])=>[id,{id:t.id,windowId:t.windowId,profileId:t.profileId,url:t.url,pinned:t.pinned}])),groups:Object.fromEntries(Object.entries(s.groups).filter(([,g])=>g.windowId==="w1")),splits:Object.fromEntries(Object.entries(s.splits).filter(([,g])=>g.windowId==="w1")),selection:s.selection.w1,closedWindows:s.closedWindows,parkedPins:s.parkedPins};`);
const withoutMarker = (value) => {
  const copy = structuredClone(value);
  delete copy.window.keptOnClose;
  return copy;
};
async function until(label, accept, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    assert.ok(app.alive, `${label}: app exited`);
    const value = await accept();
    if (value) return value;
    await sleep(100);
  }
  throw new Error(`${label}: deadline exceeded`);
}
const nativeWindow = (id) => lifecycle().then((inventory) => inventory.windows.find((w) => w.id === id));
const waitVisible = (id, visible) => until(`${id} visible=${visible}`, async () => (await nativeWindow(id))?.visible === visible);
const newWindow = async (privateWindow = false) => {
  const before = await run("return ac.store.getState().windowOrder;");
  if (privateWindow) await run('return expo.modules.SolaraApp.devMenuCommand("newIncognitoWindow",null);');
  else assert.equal(await run('return expo.modules.SolaraApp.devPostKey("w1","menu:n",45,["command"]);'), true);
  const id = await until("new store window", () => run(`return ac.store.getState().windowOrder.find(id=>!${JSON.stringify(before)}.includes(id));`));
  await waitVisible(id, true);
  return id;
};
const closeNative = async (id, action = "close-button") => {
  const window = await nativeWindow(id);
  assert.ok(window, `missing ${id}`);
  await run(`return expo.modules.SolaraCEF.devWindow(${window.number},${JSON.stringify(action)});`);
};
const closed = async (id) => until(`${id} physically closed`, async () => !await nativeWindow(id) && await run(`return !ac.store.getState().windows[${JSON.stringify(id)}];`));
const pass = (name) => console.log(`PASS ${name}`);
const monitorExit = async (pid) => {
  const source = `import json,os,select,sys
queue=select.kqueue()
queue.control([select.kevent(int(sys.argv[1]),filter=select.KQ_FILTER_PROC,flags=select.KQ_EV_ADD|select.KQ_EV_ONESHOT,fflags=select.KQ_NOTE_EXIT|0x04000000)],0,0)
print("READY",flush=True)
events=queue.control(None,1,15)
if not events:
    raise TimeoutError("process did not exit within 15 seconds")
event=events[0]
print(json.dumps({"flags":event.fflags,"raw":event.data,"code":os.waitstatus_to_exitcode(event.data)}),flush=True)
`;
  const helper = spawn("python3", ["-u", "-c", source, String(pid)], { stdio: ["ignore", "pipe", "pipe"], timeout: 18000 });
  let output = "", errors = "";
  const ended = new Promise((resolve) => helper.once("exit", (code, signal) => resolve({ code, signal })));
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { helper.kill(); reject(new Error("exit monitor did not register within 3 seconds")); }, 3000);
    const fail = (error) => { clearTimeout(timer); reject(error); };
    helper.once("error", fail);
    helper.once("exit", (code) => { if (!output.includes("READY\n")) fail(new Error(`exit monitor failed (${code}): ${errors}`)); });
    helper.stderr.on("data", (data) => { errors += data; });
    helper.stdout.on("data", (data) => {
      output += data;
      if (output.includes("READY\n")) { clearTimeout(timer); resolve(); }
    });
  });
  return async () => {
    const status = await ended;
    assert.equal(status.code, 0, `exit monitor: ${errors || status.signal}`);
    const exit = JSON.parse(output.trim().split("\n").at(-1));
    assert.ok((exit.flags & 0x04000000) !== 0, "kernel did not provide NOTE_EXITSTATUS");
    assert.equal(exit.raw, 0, "app did not exit with raw wait status 0");
    assert.equal(exit.code, 0, "app did not exit 0");
    return exit;
  };
};
try {
  for (const restoreSession of [true, false]) {
    const data = join(scratch, `restore-${restoreSession}`);
    const fixture = session({
      windows: [{ id: "w1", activeTabIds: { default: "a" } }],
      tabs: ["a", "b", "pin"].map((id) => ({ id, url: pageURL(id), pinned: id === "pin" })),
      groups: [{ id: "g", windowId: "w1", profileId: "default", name: "Reading", icon: null, color: null, collapsed: false, pinned: false, tabIds: ["a", "b"], createdAt: 0 }],
      splits: [{ id: "sp", windowId: "w1", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5] }],
      settings: { restoreSession: true, sleepInactiveTabs: false, warnBeforeClosingWindow: true, warnBeforeQuitting: false },
    });
    app = await launch(resolve(appPath), { data, fresh: true, session: fixture, onboarded: true, probe: true, keepData: true, ready: "return !!ac.store.getState().windows.w1" });
    const page = await app.page(pageURL("a"));
    await until("fixture document ready", () => page.eval('!!document.querySelector("#draft") && typeof window.nonce==="string"').catch(() => false));
    await until("loaded split pages", () => run('return ["a","b"].every(id=>!ac.store.getState().live[id]?.isLoading);'));
    const targetId = (await app.pageTarget(pageURL("a"))).id;
    const nonce = await page.eval('document.querySelector("#draft").value="unsent draft";document.querySelector("#draft").focus();document.querySelector("#draft").setSelectionRange(2,7);window.nonce');
    await run('ac.store.getState().setSelection("w1",["a","b"]);globalThis.__lastWindowWarnings=[];globalThis.__lastWindowRequests=[];expo.modules.SolaraShell.confirm=(options)=>{__lastWindowWarnings.push(options);return Promise.resolve({confirmed:false,suppressed:false});};ac.shell.onWindowEvent(e=>{if(e.type==="closeRequest")__lastWindowRequests.push(e.id);});return true;');
    const original = await nativeWindow("w1");
    if (!original.excluded) assert.equal((await lifecycle()).windowsMenu.includes(original.number), true, "visible window must appear in the Window menu before hiding");
    assert.equal((await lifecycle()).scriptingCount, 1);
    const verifyLive = async () => {
      assert.equal((await app.pageTarget(pageURL("a")))?.id, targetId);
      assert.deepEqual(await page.eval('[window.nonce,document.querySelector("#draft").value,window.unloads,document.activeElement.id,document.querySelector("#draft").selectionStart,document.querySelector("#draft").selectionEnd]'), [nonce, "unsent draft", 0, "draft", 2, 7]);
    };
    const verifyHidden = async (before) => {
      await until("retained marker", async () => (await state()).window?.keptOnClose === true);
      await waitVisible("w1", false);
      await sleep(250);
      assert.equal((await nativeWindow("w1")).visible, false);
      assert.deepEqual(withoutMarker(await state()), withoutMarker(before));
      assert.deepEqual(await run("return __lastWindowWarnings;"), []);
      assert.deepEqual(await run("return __lastWindowRequests;"), []);
      const inventory = await lifecycle();
      const hidden = inventory.windows.find((w) => w.id === "w1");
      assert.equal(hidden.number, original.number);
      assert.equal(hidden.excluded, true);
      assert.equal(inventory.windowsMenu.includes(original.number), false);
      assert.equal(inventory.scriptingCount, 0);
      assert.equal(app.windows().includes(original.number), false);
      await verifyLive();
    };
    const verifyShown = async (before) => {
      await waitVisible("w1", true);
      await until("cleared marker", async () => !(await state()).window?.keptOnClose);
      const shown = await nativeWindow("w1");
      assert.equal(shown.number, original.number);
      assert.deepEqual(shown.frame, original.frame);
      assert.equal(shown.excluded, original.excluded);
      assert.equal(shown.collection, original.collection);
      assert.deepEqual(withoutMarker(await state()), withoutMarker(before));
      await verifyLive();
    };
    for (const [index, trigger] of ["red close button", "Shift Command W", "File Close Window"].entries()) {
      const before = await state();
      if (index === 0) await closeNative("w1");
      if (index === 1) await run('return ac.shell.devKeyEquivalent("w1",{key:"w",keyCode:13,modifiers:["command","shift"],focus:"window"});');
      if (index === 2) await run('return expo.modules.SolaraApp.devMenuItems("File",["Close Window"]);');
      await verifyHidden(before);
      await lifecycle("activation");
      await lifecycle("dock");
      await waitVisible("w1", false);
      assert.equal(await run("return ac.store.getState().windowOrder.length;"), 1);
      if (index % 2 === 0) {
        await lifecycle("activation", true);
        await lifecycle("dock", true);
      } else {
        await lifecycle("dock", true);
        await lifecycle("activation", true);
      }
      await lifecycle("dock", true);
      await verifyShown(before);
      assert.equal(await run("return ac.store.getState().windowOrder.length;"), 1);
      pass(`${trigger}; same page/workspace; guarded background and scoped native callbacks, restoreSession=${restoreSession}`);
    }
    await run('ac.store.getState().updateSettings({warnBeforeClosingWindow:false});return true;');
    const beforeNew = await state();
    await closeNative("w1");
    await verifyHidden(beforeNew);
    const second = await newWindow();
    assert.notEqual(second, "w1");
    assert.notEqual((await nativeWindow(second)).number, original.number);
    assert.equal((await state()).window.keptOnClose, true);
    await closeNative(second);
    await closed(second);
    await waitVisible("w1", false);
    pass(`Command N creates a distinct window and closing it leaves retained w1 hidden, restoreSession=${restoreSession}`);
    await lifecycle("dock", true);
    const privateId = await newWindow(true);
    assert.equal(await run(`return ac.store.getState().windows[${JSON.stringify(privateId)}].incognito;`), true);
    await closeNative(privateId);
    await closed(privateId);
    assert.equal((await lifecycle()).retained, null);
    pass(`private windows physically close, restoreSession=${restoreSession}`);
    const other = await newWindow();
    await closeNative(other);
    await closed(other);
    assert.equal((await state()).window.keptOnClose, undefined);
    await waitVisible("w1", true);
    await closeNative("w1");
    await waitVisible("w1", false);
    assert.equal((await state()).window.keptOnClose, true);
    pass(`with two windows only the last is retained, restoreSession=${restoreSession}`);
    await lifecycle("dock", true);
    const rapid = await newWindow();
    const rapidNumber = (await nativeWindow(rapid)).number;
    await run(`return expo.modules.SolaraCEF.devWindow(${rapidNumber},"close-button").then(()=>new Promise(resolve=>setTimeout(resolve,100))).then(()=>expo.modules.SolaraCEF.devWindow(${original.number},"close-button"));`);
    await closed(rapid);
    await waitVisible("w1", false);
    assert.equal((await state()).window.keptOnClose, true);
    assert.equal((await nativeWindow("w1")).number, original.number);
    assert.equal((await state()).closedWindows.some((window) => window.id === "w1"), false);
    await verifyLive();
    pass(`rapid close preserves the last live workspace, restoreSession=${restoreSession}`);
    const cancelledBefore = await state();
    const dialogs = [];
    let acceptDialog = false;
    await page.send("Page.enable");
    const stopDialogs = page.on("Page.javascriptDialogOpening", (dialog) => {
      dialogs.push(dialog.type);
      void page.send("Page.handleJavaScriptDialog", { accept: acceptDialog }).catch(() => {});
    });
    await run('globalThis.__lastWindowQuitPhase="idle";globalThis.__lastWindowActivationTrace=[];globalThis.__lastWindowTraceSubscriptions=[ac.shell.onAppEvent(e=>{if(e.type==="willQuit"||e.type==="quitCancelled"){__lastWindowQuitPhase=e.type;__lastWindowActivationTrace.push({event:e.type,kept:!!ac.store.getState().windows.w1?.keptOnClose});}}),expo.modules.SolaraTabPool.addListener("onPageEvent",e=>{if(e.name==="onActivateRequest")__lastWindowActivationTrace.push({event:e.name,payload:e.payload,quitPhase:__lastWindowQuitPhase,kept:!!ac.store.getState().windows.w1?.keptOnClose});})];return true;');
    try {
      await page.eval('window.lastWindowBeforeUnload=(event)=>{event.preventDefault();event.returnValue="";};addEventListener("beforeunload",window.lastWindowBeforeUnload);true', { userGesture: true });
      assert.equal(await run('return expo.modules.SolaraApp.devPostKey("w1","menu:q",12,["command"]);'), true);
      await until("hidden page beforeunload dialog", () => dialogs.includes("beforeunload"));
      await sleep(1000);
      assert.ok(app.alive, "cancelled quit terminated the app");
      console.log(`TRACE hidden quit activation, restoreSession=${restoreSession}: ${JSON.stringify(await run("return __lastWindowActivationTrace;"))}`);
      assert.deepEqual(await state(), cancelledBefore, `cancelled-quit native inventory: ${JSON.stringify(await lifecycle())}`);
      assert.equal((await lifecycle()).retained, "w1");
      assert.equal((await nativeWindow("w1")).visible, false);
      assert.equal((await app.pageTarget(pageURL("a")))?.id, targetId);
      assert.deepEqual(await page.eval('[window.nonce,document.querySelector("#draft").value]'), [nonce, "unsent draft"]);
      assert.equal(await run("return ac.store.getState().windowOrder.length;"), 1);
      const backgroundURL = pageURL("chrome-background");
      const link = await page.eval(`const link=document.createElement("a");link.href=${JSON.stringify(backgroundURL)};link.textContent="Background tab";document.body.append(link);const box=link.getBoundingClientRect();({x:box.x+box.width/2,y:box.y+box.height/2});`);
      for (const type of ["mousePressed", "mouseReleased"]) await page.send("Input.dispatchMouseEvent", { type, x: link.x, y: link.y, button: "left", clickCount: 1, modifiers: 4 });
      const backgroundId = await until("Chrome-origin background tab", () => run(`return Object.values(ac.store.getState().tabs).find(tab=>tab.url===${JSON.stringify(backgroundURL)})?.id;`));
      await sleep(500);
      assert.equal(await run(`return ac.store.getState().tabs[${JSON.stringify(backgroundId)}].windowId;`), "w1");
      assert.deepEqual(await run("return ac.store.getState().windowOrder;"), ["w1"]);
      assert.deepEqual((await lifecycle()).windows.map((window) => [window.id, window.number, window.visible]), [["w1", original.number, false]]);
      assert.equal((await lifecycle()).retained, "w1");
      assert.deepEqual((await state()).window.activeTabIds, cancelledBefore.window.activeTabIds);
      assert.equal((await app.pageTarget(pageURL("a")))?.id, targetId);
      assert.deepEqual(await page.eval('[window.nonce,document.querySelector("#draft").value]'), [nonce, "unsent draft"]);
      pass(`hidden Chrome beforeunload cancellation and Chrome background-tab adoption preserve window identity and visibility, restoreSession=${restoreSession}`);
    } finally {
      acceptDialog = true;
      if (app.alive) await page.eval('removeEventListener("beforeunload",window.lastWindowBeforeUnload);delete window.lastWindowBeforeUnload;true').catch(() => {});
      stopDialogs();
      if (app.alive) await run("__lastWindowTraceSubscriptions.forEach(subscription=>subscription.remove());return true;").catch(() => {});
    }
    await run(`ac.store.getState().updateSettings({restoreSession:${restoreSession}});return true;`);
    const expected = await state();
    const observedExit = await monitorExit(app.pid);
    const quitStart = Date.now();
    const quit = await app.quit({ timeout: 14000 });
    assert.equal(quit.how, "quit", "Apple-event quit must finish without a signal fallback");
    assert.ok(Date.now() - quitStart < 15000, "Apple-event quit exceeded 15 seconds");
    const quitMs = Date.now() - quitStart;
    await observedExit();
    app = null;
    const document = JSON.parse(readFileSync(join(data, "session.json"), "utf8"));
    assert.equal(document.windows.find((w) => w.id === "w1")?.keptOnClose, true);
    assert.equal(document.closedWindows.some((w) => w.id === "w1"), false);
    app = await launch(resolve(appPath), { data, onboarded: true, probe: true, keepData: true, ready: "return !!ac.store.getState().windows.w1" });
    const restored = await state();
    assert.deepEqual(restored.window.tabIds, expected.window.tabIds);
    assert.deepEqual(restored.window.activeTabIds, expected.window.activeTabIds);
    assert.deepEqual(restored.tabs, expected.tabs);
    assert.deepEqual(restored.groups, expected.groups);
    assert.deepEqual(restored.splits, expected.splits);
    assert.ok(!restored.window.keptOnClose);
    await waitVisible("w1", true);
    pass(`hidden Apple-event quit (exit 0, ${quitMs}ms) and visible workspace relaunch, restoreSession=${restoreSession}`);
    await closeNative("w1");
    await waitVisible("w1", false);
    await until("retained marker before simulated update", async () => (await state()).window.keptOnClose === true);
    const beforeUpdate = await state();
    await run('return expo.modules.SolaraApp.devSimulatePendingUpdate("9.9.9","quit");');
    const updateExit = await monitorExit(app.pid);
    const updateStart = Date.now();
    await run('setTimeout(()=>expo.modules.SolaraApp.installPendingUpdate(),100);return true;');
    await updateExit();
    assert.ok(Date.now() - updateStart < 15000, "simulated update quit exceeded 15 seconds");
    await app.quit();
    app = null;
    const updateDocument = JSON.parse(readFileSync(join(data, "session.json"), "utf8"));
    assert.equal(updateDocument.windows.find((window) => window.id === "w1")?.keptOnClose, true);
    app = await launch(resolve(appPath), { data, onboarded: true, probe: true, keepData: true, ready: "return !!ac.store.getState().windows.w1" });
    const afterUpdate = await state();
    assert.deepEqual(afterUpdate.window.tabIds, beforeUpdate.window.tabIds);
    assert.deepEqual(afterUpdate.window.activeTabIds, beforeUpdate.window.activeTabIds);
    assert.deepEqual(afterUpdate.tabs, beforeUpdate.tabs);
    assert.deepEqual(afterUpdate.groups, beforeUpdate.groups);
    assert.deepEqual(afterUpdate.splits, beforeUpdate.splits);
    assert.ok(!afterUpdate.window.keptOnClose);
    await waitVisible("w1", true);
    await app.quit();
    app = null;
    pass(`simulated update termination (exit 0) and visible retained-workspace relaunch, restoreSession=${restoreSession}`);
  }
  const reverseData = join(scratch, "rapid-reverse");
  app = await launch(resolve(appPath), { data: reverseData, fresh: true, onboarded: true, probe: true, keepData: true, session: session({
    windows: [{ id: "w1" }, { id: "w2" }],
    tabs: [{ id: "first", windowId: "w1", url: pageURL("rapid-first") }, { id: "last", windowId: "w2", url: pageURL("rapid-last") }],
    settings: { restoreSession: true, sleepInactiveTabs: false, warnBeforeClosingWindow: false, warnBeforeQuitting: false },
  }), ready: "return !!ac.store.getState().windows.w2" });
  await waitVisible("w1", true);
  await waitVisible("w2", true);
  const reversePage = await app.page(pageURL("rapid-last"));
  await until("reverse fixture document ready", () => reversePage.eval('typeof window.nonce==="string"').catch(() => false));
  const reverseNonce = await reversePage.eval("window.nonce");
  const reverseTarget = (await app.pageTarget(pageURL("rapid-last"))).id;
  const reverseWindow = await nativeWindow("w2");
  const firstWindow = await nativeWindow("w1");
  await run(`return expo.modules.SolaraCEF.devWindow(${firstWindow.number},"close-button").then(()=>new Promise(resolve=>setTimeout(resolve,100))).then(()=>expo.modules.SolaraCEF.devWindow(${reverseWindow.number},"close-button"));`);
  await closed("w1");
  await waitVisible("w2", false);
  assert.equal((await lifecycle()).retained, "w2");
  assert.equal((await nativeWindow("w2")).number, reverseWindow.number);
  assert.deepEqual(await run(`const s=ac.store.getState();return {order:s.windowOrder,tabs:s.windows.w2.tabIds,kept:s.windows.w2.keptOnClose,closed:s.closedWindows.some(window=>window.id==="w2")};`), { order: ["w2"], tabs: ["last"], kept: true, closed: false });
  assert.equal((await app.pageTarget(pageURL("rapid-last"))).id, reverseTarget);
  assert.deepEqual(await reversePage.eval("[window.nonce,window.unloads]"), [reverseNonce, 0]);
  await app.quit();
  app = null;
  pass("rapid close in reverse request order retains the second original window and its live page");
  passed = true;
  console.log("Lifecycle callback tests invoke the actual delegate/notification with a scoped foreground retention decision; the app stays background-only. Actual Dock clicks, Cmd Tab, Mission Control, multi-display Spaces and a staged Sparkle install/handoff remain owner checks; update termination uses the existing simulated pending-update hook.");
} finally {
  await app?.quit();
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
  if (passed && !args.includes("--keep-data")) rmSync(scratch, { recursive: true, force: true });
  else console.log(`Evidence: ${scratch}`);
}
