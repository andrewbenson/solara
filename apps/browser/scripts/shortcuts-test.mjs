import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { isAlive, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { shortcutPage } from "../../../scripts/lib/fixture-html.mjs";

const [appArg, part, port] = process.argv.slice(2);
const appPath = appArg && resolve(appArg);
if (!appPath || !["matrix", "presses", "precedence"].includes(part)) {
  console.error("usage: node shortcuts-test.mjs <Debug Solara.app> matrix|presses|precedence [cdpPort]");
  process.exit(2);
}
const startedAt = Date.now();
const scratch = mkdtempSync(join(tmpdir(), "ac-shortcuts-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "shortcuts-test.log"), { name: `shortcuts-test ${part}` });

const server = createServer((req, res) => {
  const name = new URL(req.url, "http://x").search.slice(1) || "page";
  res.writeHead(200, { "content-type": "text/html" });
  if (name === "autofocus") return res.end(`<!doctype html><title>autofocus</title><textarea id=t autofocus style="position:fixed;left:20px;top:120px;width:300px;height:60px"></textarea><script>document.getElementById("t").focus()</script>`);
  res.end(shortcutPage(name));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pages = `http://127.0.0.1:${server.address().port}`;

const tab = (id, pinned) => ({ id, url: `${pages}/?${id}`, title: id, pinned, pinnedUrl: pinned ? `${pages}/?${id}` : null });
const ids = ["pin1", "pin2", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9"];

let app = null;
const finish = async (code) => {
  await app?.quit();
  server.close();
  rmSync(data, { recursive: true, force: true });
  process.exit(code);
};
process.on("uncaughtException", (error) => {
  console.error(error);
  finish(1);
});
process.on("unhandledRejection", (error) => {
  console.error(error);
  finish(1);
});
app = await launch(appPath, {
  data, port,
  session: session({
    profiles: [{ id: "default", name: "Personal", color: "plum" }, { id: "p-work", name: "Work", color: "blue" }],
    windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t3" } }],
    tabs: ids.map((id) => tab(id, id.startsWith("pin"))),
  }),
  switches: "--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-features=PMProcessPriorityPolicy",
  ready: "return !!ac.shell.devKeyEquivalent",
});
rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
const SHORTCUT_FIELDS = [
  "windows.profileId", "windows.selectedTabId", "windows.tabIds", "windows.panelOpen", "windows.sidebarOpen",
  "windows.shortcuts", "windows.shortcutTable", "windows.shortcutFields", "windows.firstResponder", "windows.omnibox",
  "tabs.url", "tabs.find",
];
const untilSnapshot = async (what, accept, ms = 5000, args = {}) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot({ windowId: "w1", shortcuts: true, fields: SHORTCUT_FIELDS, ...args });
    if (last.consistent && accept(last)) return last;
    await sleep(50);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};
const nativeWindow = (snapshot, id = "w1") => snapshot.windows.find((w) => w.id === id);
const nativeState = async (expected, id = "w1") => {
  const s = await untilSnapshot("native shortcut window state", (s) => {
    const w = nativeWindow(s, id);
    return w && w.profileId === expected.profile && w.selectedTabId === expected.active && w.tabIds.length === expected.tabs && w.panelOpen === expected.panel;
  });
  const w = nativeWindow(s, id);
  assert.deepEqual({ profile: w.profileId, active: w.selectedTabId, tabs: w.tabIds.length, panel: w.panelOpen }, expected);
  return s;
};
const hello = await app.probe("probe.hello");
assert.ok(hello.capabilities.includes("state.snapshot"));
const firstSnapshot = await untilSnapshot("native shortcut table", (s) => nativeWindow(s)?.shortcutTable.length > 0, 5000, { shortcutTable: ["Quit"] });
for (const field of ["windows.shortcuts", "windows.shortcutTable", "snapshot.fields", "windows.panelOpen", "windows.sidebarOpen", "windows.activeTabIds", "tabs.find"]) assert.ok(firstSnapshot.capabilities.available.includes(field), field);
const fullShortcutSnapshotFits = async (when) => {
  const bytes = Buffer.byteLength(JSON.stringify(await app.snapshot({ shortcuts: true })));
  assert.ok(bytes < 65536, `${when}: a full {shortcuts: true} snapshot is ${bytes} bytes, over the 64 KiB reply cap`);
};
await fullShortcutSnapshotFits("at launch");

await sleep(3000);

const ac = (body, timeout = 60000) => app.eval(body, { timeout }).catch(async (error) => {
  error.message += `\n${body}`;
  if (/timed out/.test(error.message) && app.alive) error.message += `\n${await diagnoseHang()}`;
  throw error;
});
const pagesHost = new URL(pages).hostname;
await ac(`const off = { on: [], off: [${JSON.stringify(pagesHost)}], reload: "reload" };
  ac.store.getState().updateSettings({ developerMode: { default: off, "p-work": off }, warnBeforeQuitting: false }); return 1;`);
async function diagnoseHang() {
  let pending = "?", landed = "?";
  try { pending = readFileSync(join(data, "dev-eval.js"), "utf8").split("\n")[0]; } catch {}
  try { landed = readFileSync(join(data, "dev-eval-result.json"), "utf8").slice(0, 60); } catch {}
  const sampleFile = join(scratch, "hang-sample.txt");
  spawnSync("sample", [String(app.pid), "2", "-mayDie", "-file", sampleFile], { timeout: 15000 });
  const js = await app.eval("return Math.round(performance.now() / 1000)", { timeout: 3000 })
    .then((up) => `the JS thread answers (JS context up ${up} s, test up ${Math.round((Date.now() - startedAt) / 1000)} s)`, () => "the JS thread doesn't answer either");
  try { copyFileSync(join(data, "app.out.log"), join(scratch, "app.out.log")); } catch {}
  const main = await app.eval("return globalThis.expo.modules.SolaraApp.devFocusHandoffTrace().then(() => 1)", { timeout: 3000 })
    .then(() => "the main thread answers", () => "the main thread doesn't answer");
  const presses = await app.eval("return globalThis.expo.modules.SolaraApp.devKeyEquivalentTrace()", { timeout: 3000 }).catch(() => []);
  const seen = await app.eval("return (globalThis.__devEvalLog ?? []).join(' | ')", { timeout: 3000 }).catch(() => null);
  const proxy = app.js?.pid ? (isAlive(app.js.pid) ? `Metro proxy ${app.js.pid} alive` : `Metro proxy ${app.js.pid} gone`) : "no Metro proxy";
  return `hang: ${js}; ${main}; ${proxy}; pending eval ${pending}, result file ${landed}, JS evals: ${seen}; native presses: ${presses.slice(-6).join(" / ")}; main-thread sample in ${sampleFile} (kept: ${scratch})`;
}
async function cdp(urlPart, expression) {
  if (!(await app.pageTarget(urlPart))) return undefined;
  const page = await app.page(urlPart);
  try {
    return await page.eval(expression, { timeout: 3000 });
  } catch {
    return undefined;
  } finally {
    page.close();
  }
}

const state = async () => {
  const value = await ac(`const s = ac.store.getState(), w = s.windows.w1;
    return { profile: w.profileId, active: w.activeTabIds[w.profileId], tabs: w.tabIds.length, panel: !!s.windowUi.w1?.panel.open };`);
  await nativeState(value);
  return value;
};
const activeUrl = async () => {
  const value = await ac(`const s = ac.store.getState(), w = s.windows.w1; return w ? s.tabs[w.activeTabIds[w.profileId]]?.url ?? "" : "no window w1";`);
  const s = await untilSnapshot("native selected tab URL", (s) => s.tabs.find((t) => t.id === nativeWindow(s)?.selectedTabId)?.url === (value === "" ? null : value));
  assert.equal(s.tabs.find((t) => t.id === nativeWindow(s).selectedTabId).url, value === "" ? null : value);
  return value;
};
const press = async (key, options) => {
  const terminates = key.key.toLowerCase() === "q" && key.modifiers.includes("command") && !options?.dry;
  if (terminates) {
    const native = await untilSnapshot("native registered quit shortcut", (s) => nativeWindow(s)?.shortcutTable.some((item) => item.key.toLowerCase() === "q" && /^Quit/.test(item.title)), 5000, { shortcutTable: ["Quit"] });
    assert.ok(nativeWindow(native).shortcutTable.some((item) => item.key.toLowerCase() === "q" && /^Quit/.test(item.title)));
  }
  const r = await ac(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ ...key, ...options })});`);
  if (terminates) return r;
  const s = await untilSnapshot("native shortcut dispatch result", (s) => isDeepStrictEqual(nativeWindow(s)?.shortcuts.press, r), 5000, { shortcutTable: (r.matched ?? []).map((item) => item.title) });
  const native = nativeWindow(s).shortcuts;
  assert.deepEqual(native.press, r);
  for (const item of r.matched ?? []) {
    assert.ok(nativeWindow(s).shortcutTable.some((entry) => entry.title === item.title && entry.command === item.command && (entry.arg ?? undefined) === item.arg), JSON.stringify(item));
  }
  return r;
};

const F = (code) => String.fromCharCode(code);
const K = (key, keyCode, ...modifiers) => ({ key, keyCode, modifiers });
const cmd = (key, keyCode, ...more) => K(key, keyCode, "command", ...more);

const devToolsOwn = new Set([
  "⌘O", "⌘P", "⇧⌘C", "⌘F", "⌥⌘F", "⌘G", "⇧⌘G", "⌘R", "⇧⌘R", "⌘0", "⌘+", "⌘=", "⌘-", "⌥⌘C", "⌘[", "⌘]",
  "⌃⇧⇟", "⌃⇧⇞", "⌘↩", "⌥⌘B", "⇧⌘M",
]);
const shortcuts = [
  ["⌘,", cmd(",", 43), { command: "openSettings" }, "⌘,"],
  ["⌘Q", cmd("q", 12), { title: /^Quit/ }, "⌘Q", "window-only"],
  ["⌘H", cmd("h", 4), { title: /^Hide / }, "⌘H", "window-only"],
  ["⌘T", cmd("t", 17), { command: "newTab" }, "⌘T"],
  ["⌥⌘T", cmd("t", 17, "option"), { command: "newTabInGroup" }, "⌥⌘T"],
  ["⌘N", cmd("n", 45), { command: "newWindow" }, "⌘N"],
  ["⇧⌘N", cmd("N", 45, "shift"), { command: "newIncognitoWindow" }, "⇧⌘N"],
  ["⇧⌘T", cmd("T", 17, "shift"), { command: "reopenClosedTab" }, "⇧⌘T"],
  ["⌘L", cmd("l", 37), { command: "focusCommandBar" }, "⌘L"],
  ["⌃F5", K(F(0xf708), 96, "control", "function"), { command: "focusCommandBar" }, "(Chrome's)"],
  ["⌘O", cmd("o", 31), { command: "openFile" }, "(Chrome's)"],
  ["⇧⌘W", cmd("W", 13, "shift"), { title: "Close Window" }, "⇧⌘W", "window-only"],
  ["⌘W", cmd("w", 13), { command: "closeTab" }, "⌘W"],
  ["⇧⌘K", cmd("K", 40, "shift"), { command: "closeAllTabs" }, "⇧⌘K"],
  ["⌥⌘K", cmd("k", 40, "option"), { command: "cleanUpTabs" }, "⌥⌘K"],
  ["⌘P", cmd("p", 35), { command: "print" }, "⌘P"],
  ["⌥⌘P", cmd("p", 35, "option"), { command: "printWithSystemDialog" }, "(Chrome's)"],
  ["⇧⌘I", cmd("I", 34, "shift"), { command: "emailPageLocation" }, "(Chrome's)"],
  ["⌘Z", cmd("z", 6), { title: "Undo" }, "⌘Z"],
  ["⇧⌘Z", cmd("Z", 6, "shift"), { title: "Redo" }, "⇧⌘Z"],
  ["⌘X", cmd("x", 7), { title: "Cut" }, "⌘X", "clipboard"],
  ["⌘C", cmd("c", 8), { title: "Copy" }, "⌘C", "clipboard"],
  ["⇧⌘C", cmd("C", 8, "shift"), { command: "copyUrl" }, "⇧⌘C"],
  ["⌥⇧⌘C", cmd("C", 8, "shift", "option"), { command: "copyUrlAsMarkdown" }, "⌥⇧⌘C"],
  ["⌘V", cmd("v", 9), { title: "Paste" }, "⌘V", "clipboard"],
  ["⇧⌘V", cmd("V", 9, "shift"), { title: "Paste and Match Style" }, "⇧⌘V", "clipboard"],
  ["⌘A", cmd("a", 0), { title: "Select All" }, "⌘A"],
  ["⌘F", cmd("f", 3), { command: "findInPage" }, "⌘F"],
  ["⌥⌘F", cmd("f", 3, "option"), { command: "findAndReplace" }, "⌥⌘F"],
  ["⌘G", cmd("g", 5), { command: "findNext" }, "⌘G"],
  ["⇧⌘G", cmd("G", 5, "shift"), { command: "findPrevious" }, "⇧⌘G"],
  ["⌘J", cmd("j", 38), { command: "jumpToSelection" }, "⌘J"],
  ["⌘E", cmd("e", 14), { command: "useSelectionForFind" }, "⌘E is Chat (no AI)"],
  ["⌘:", cmd(":", 41, "shift"), { title: "Show Spelling and Grammar" }, "⌘:", "window-only"],
  ["⌘;", cmd(";", 41), { title: "Check Document Now" }, "⌘;", "window-only"],
  ["⌘.", cmd(".", 47), { command: "stop" }, "(Chrome's)"],
  ["⌘R", cmd("r", 15), { command: "reload" }, "⌘R"],
  ["⇧⌘R", cmd("R", 15, "shift"), { command: "forceReload" }, "⇧⌘R"],
  ["⇧⌘S", cmd("S", 1, "shift"), { command: "toggleTabLayout" }, "⇧⌘S"],
  ["⌘S", cmd("s", 1), { command: "toggleSidebar" }, "⌘S", "page-field"],
  ["⇧⌘L", cmd("L", 37, "shift"), { command: "toggleSidebar" }, "(Chrome's)", "page-field"],
  ["⇧⌘F", cmd("F", 3, "shift"), { command: "toggleSidebar" }, "(Chrome's)", "page-field"],
  ["⌥⌘N", cmd("n", 45, "option"), { command: "newLittleSolara" }, "Arc's Little Arc"],
  ["⌃⇧=", K("+", 24, "control", "shift"), { command: "openSplitPane" }, "⌃⇧="],
  ["⌃⇧]", K("}", 30, "control", "shift"), { command: "focusNextPane" }, "⌃⇧]"],
  ["⌃⇧[", K("{", 33, "control", "shift"), { command: "focusPreviousPane" }, "⌃⇧["],
  ["⇧⌘B", cmd("B", 11, "shift"), { command: "toggleBookmarksBar" }, "⇧⌘B"],
  ["⌘0", cmd("0", 29), { command: "zoomReset" }, "⌘0"],
  ["⌘+", cmd("+", 24, "shift"), { command: "zoomIn" }, "⌘+"],
  ["⌘=", cmd("=", 24), { command: "zoomIn" }, "⌘= (alternate)"],
  ["⌘-", cmd("-", 27), { command: "zoomOut" }, "⌘-"],
  ["🌐F", K("f", 3, "function"), { title: "Enter Full Screen" }, "🌐F", "window-only"],
  ["⌃⌘F", cmd("f", 3, "control"), { title: "Enter Full Screen" }, "(Chrome's)", "window-only"],
  ["F7", K(F(0xf70a), 98, "function"), { command: "caretBrowsing" }, "(Chrome's)"],
  ["⌥⌘U", cmd("u", 32, "option"), { command: "viewSource" }, "⌥⌘U"],
  ["⌥⌘I", cmd("i", 34, "option"), { command: "devTools" }, "⌥⌘I"],
  ["⌥⌘C", cmd("c", 8, "option"), { command: "inspectElements" }, "⌥⌘C"],
  ["⌥⌘J", cmd("j", 38, "option"), { command: "javaScriptConsole" }, "⌥⌘J"],
  ["F12", K(F(0xf70f), 111, "function"), { command: "toggleDevTools" }, "F12"],
  ["⌘[", cmd("[", 33), { command: "back" }, "⌘["],
  ["⌘]", cmd("]", 30), { command: "forward" }, "⌘]"],
  ["⌘←", cmd(F(0xf702), 123, "function"), { command: "back" }, "⌘←", "not-field"],
  ["⌘→", cmd(F(0xf703), 124, "function"), { command: "forward" }, "⌘→", "not-field"],
  ["⇧⌘]", cmd("}", 30, "shift"), { command: "nextTab" }, "⇧⌘]"],
  ["⇧⌘[", cmd("{", 33, "shift"), { command: "previousTab" }, "⇧⌘["],
  ["⌥⌘→", cmd(F(0xf703), 124, "option", "function"), { command: "nextProfile" }, "(Chrome's next tab)"],
  ["⌥⌘←", cmd(F(0xf702), 123, "option", "function"), { command: "previousProfile" }, "(Chrome's previous tab)"],
  ["⌃⇟", K(F(0xf72d), 121, "control", "function"), { command: "nextTab" }, "(Chrome's)"],
  ["⌃⇞", K(F(0xf72c), 116, "control", "function"), { command: "previousTab" }, "(Chrome's)"],
  ["⌥⌘↓", cmd(F(0xf701), 125, "option", "function"), { command: "nextTab" }, "⌥⌘↓ (alternate)"],
  ["⌥⌘↑", cmd(F(0xf700), 126, "option", "function"), { command: "previousTab" }, "⌥⌘↑ (alternate)"],
  ["⌃⇧⇟", K(F(0xf72d), 121, "control", "shift", "function"), { command: "moveTabDown" }, "(Chrome's)"],
  ["⌃⇧⇞", K(F(0xf72c), 116, "control", "shift", "function"), { command: "moveTabUp" }, "(Chrome's)"],
  ["⇧⌘A", cmd("A", 0, "shift"), { command: "searchTabs" }, "⇧⌘A"],
  ["⌃Tab", K("\t", 48, "control"), { command: "tabSwitcher", arg: "forward" }, "⌃Tab"],
  ["⌃⇧Tab", K("\u0019", 48, "control", "shift"), { command: "tabSwitcher", arg: "backward" }, "⌃⇧Tab"],
  ["⌘↩", cmd("\r", 36), { command: "returnToPinnedUrl" }, "⌘↩", "not-field"],
  ...[1, 2, 3, 4, 5, 6, 7, 8].map((n) => [`⌘${n}`, cmd(`${n}`, [18, 19, 20, 21, 23, 22, 26, 28][n - 1]), { command: "selectTab", arg: `${n}` }, `⌘${n} (Chromium)`]),
  ["⌘9", cmd("9", 25), { command: "selectLastTab" }, "⌘9 (Chromium)"],
  ["⌃⌘N", cmd("n", 45, "control"), { command: "newGroupWithTabs" }, "⌃⌘N"],
  ["⌃⌘P", cmd("p", 35, "control"), { command: "newGroupWithTabs" }, "(Chrome's)"],
  ["⌃⌘C", cmd("c", 8, "control"), { command: "newTabInGroup" }, "(Chrome's)"],
  ["⌃⌘W", cmd("w", 13, "control"), { command: "closeTabGroup" }, "(Chrome's)"],
  ["⌘D", cmd("d", 2), { command: "togglePinnedRow" }, "⌘D (Arc's)"],
  ["⇧⌘D", cmd("D", 2, "shift"), { command: "bookmarkAllTabs" }, "(Chrome's)", "devtools-own"],
  ["⌥⇧⌘D", cmd("D", 2, "option", "shift"), { command: "bookmarkPage" }, "(Dia's ⌘D)"],
  ["⌥⌘B", cmd("b", 11, "option"), { command: "manageBookmarks" }, "⌥⌘B"],
  ["⌘Y", cmd("y", 16), { command: "showHistory" }, "⌘Y"],
  ["⇧⌘⌫", cmd(F(0x7f), 51, "shift"), { command: "clearBrowsingData" }, "⇧⌘⌫", "page-field"],
  ["⌘M", cmd("m", 46), { title: "Minimize" }, "⌘M", "window-only"],
  ["⌥⌘M", cmd("m", 46, "option"), { title: "Minimize All" }, "⌥⌘M", "window-only"],
  ["⇧⌘J", cmd("J", 38, "shift"), { command: "downloads" }, "⇧⌘J"],
  ["⌥⌘L", cmd("l", 37, "option"), { command: "downloads" }, "(Chrome's)"],
  ["⇧⌘M", cmd("M", 46, "shift"), { command: "openProfileMenu" }, "(Chrome's)"],
  ["⌥⇧⌘I", cmd("I", 34, "shift", "option"), { command: "sendFeedback" }, "(Chrome's)"],
  ["⌃1", K("1", 18, "control"), { command: "switchProfile", arg: "default" }, "⌃1"],
  ["⌃2", K("2", 19, "control"), { command: "switchProfile", arg: "p-work" }, "⌃2"],
];

const same = (f, expect) =>
  expect.command
    ? f.command === expect.command && (expect.arg === undefined || f.arg === expect.arg)
    : expect.title instanceof RegExp ? expect.title.test(f.title) : f.title === expect.title;
function verdict(r, expect) {
  if (r.error) return "FAIL";
  const fired = r.fired ?? [], matched = r.matched ?? [];
  if (expect === null) return fired.length ? "FAIL" : "ok";
  if (fired.some((f) => same(f, expect))) return "ok";
  if (!fired.length && matched.some((m) => same(m, expect) && !m.enabled)) return "off";
  return "FAIL";
}
const describe = (r) =>
  r.error ??
  `${r.handledBy}${r.fired?.length ? ` → ${r.fired.map((f) => (f.command ? `${f.command}${f.arg ? `:${f.arg}` : ""}` : f.title)).join(", ")}` : ""}` +
    (r.matched?.length ? ` (matched ${r.matched.map((m) => `${m.command ?? m.title}${m.enabled ? "" : " disabled"}`).join(", ")})` : "");

async function showPage(name) {
  await ac(`ac.store.getState().activate("${name}");`);
  for (let i = 0; i < 40; i++) {
    if ((await cdp(`?${name}`, "document.readyState")) === "complete") return;
    await sleep(250);
  }
}
const focuses = {
  sidebar: { press: { focus: "window" } },
  page: { press: { focus: "page", asKey: true, wait: 800 }, before: () => cdp("?t3", "document.activeElement.blur(), true") },
  field: { press: { focus: "page", asKey: true, wait: 800 }, before: () => cdp("?t3", "document.getElementById('f').focus(), true") },
  commandBar: {
    press: { asKey: true },
    before: async () => {
      if ((await state()).panel) return;
      await ac(`ac.runCommand({ command: "focusCommandBar", arg: null, windowId: "w1" });`);
      await sleep(400);
    },
    teardown: () => ac(`ac.store.getState().closePanel("w1");`),
  },
  heroBar: {
    press: { asKey: true },
    setup: async () => {
      await ac(`ac.runCommand({ command: "newTab", arg: null, windowId: "w1" });`);
      await sleep(1500);
    },
    teardown: async () => {
      await ac(`const s = ac.store.getState(); for (const t of Object.values(s.tabs)) if (t.windowId === "w1" && !t.url) s.closeTab(t.id);`);
      await showPage("t3");
    },
  },
  devTools: {
    press: { focus: "devtools", asKey: true, wait: 800 },
    setup: async () => {
      await ac(`ac.runCommand({ command: "devTools", arg: null, windowId: "w1" });`);
      await sleep(3000);
    },
    teardown: () => ac(`ac.runCommand({ command: "toggleDevTools", arg: null, windowId: "w1" });`),
  },
};

let since = Date.now();
function recordFocus(focusName, late) {
  const lines = [];
  for (const [name] of shortcuts) {
    const r = results.get(name)[focusName];
    if (r && r.result !== "ok") lines.push(`${r.result.padEnd(4)}  ${name} with the focus in ${focusName}: ${r.detail} (first responder ${r.responder})`);
  }
  for (const l of [...lines.filter((l) => l.startsWith("FAIL")), ...lines.filter((l) => !l.startsWith("FAIL"))]) rep.log(l);
  const failed = shortcuts.filter(([name]) => results.get(name)[focusName]?.result === "FAIL").map(([name]) => name);
  const errors = [
    ...(failed.length ? [`${failed.length} failed: ${failed.join(" ")}`] : []),
    ...(late.length ? [`${late.length} came back from the page after their wait and were dropped, so their verdicts are unknown: ${late.join(", ")}`] : []),
  ];
  if (late.length) failures++;
  rep.record(`every shortcut with the focus in ${focusName}`, { ms: Date.now() - since, error: errors.length ? errors.join("; ") : null });
  since = Date.now();
}
const results = new Map(shortcuts.map(([name]) => [name, {}]));
let failures = 0;
await showPage("t3");
const onlyFocuses = process.env.SHORTCUTS_FOCUSES?.split(",").filter(Boolean);
if (part === "matrix") {
  for (const [focusName, focus] of Object.entries(focuses)) {
    if (onlyFocuses && !onlyFocuses.includes(focusName)) continue;
    await focus.setup?.();
    const late = [];
    for (const [name, key, expect, , only] of shortcuts) {
      if (focusName !== "sidebar" && (only === "window-only" || only === "clipboard")) continue;
      const inField =
        (only === "not-field" && (focusName === "field" || focusName === "commandBar" || focusName === "heroBar" || focusName === "devTools")) ||
        (only === "page-field" && (focusName === "field" || focusName === "devTools")) ||
        ((only === "devtools-own" || devToolsOwn.has(name)) && focusName === "devTools");
      await focus.before?.();
      const r = await press(key, { ...focus.press, dry: true });
      late.push(...(r.lateBounces ?? []));
      const result = verdict(r, inField ? null : expect);
      if (result === "FAIL") failures++;
      results.get(name)[focusName] = { result, detail: describe(r), responder: r.firstResponder };
    }
    await sleep(1000);
    const lateBounces = await ac(`return globalThis.expo.modules.SolaraApp.devKeyEquivalentLateBounces();`);
    const nativeBounces = await untilSnapshot("native late key bounces", (s) => isDeepStrictEqual(nativeWindow(s)?.shortcuts.lateBounces, lateBounces));
    assert.deepEqual(nativeWindow(nativeBounces).shortcuts.lateBounces, lateBounces);
    late.push(...lateBounces);
    await focus.teardown?.();
    recordFocus(focusName, late);
  }
  const cols = Object.keys(focuses);
  rep.log(`\n${"shortcut".padEnd(8)} ${"Dia".padEnd(26)} ${cols.map((c) => c.padEnd(10)).join(" ")}`);
  for (const [name, , , dia] of shortcuts) {
    const row = results.get(name);
    rep.log(`${name.padEnd(8)} ${dia.padEnd(26)} ${cols.map((c) => (row[c]?.result ?? "—").padEnd(10)).join(" ")}`);
  }
  await fullShortcutSnapshotFits("after the matrix");
  await finish(rep.summary() && !failures ? 0 : 1);
}

const check = (name, ok, detail) => {
  rep.record(name, { ms: Date.now() - since, error: ok ? null : detail || "failed", evidence: ok && detail ? detail : undefined });
  if (!ok) failures++;
  since = Date.now();
};
await ac(`globalThis.selections = []; ac.store.subscribe((s, p) => { const w = s.windows.w1, a = w?.activeTabIds[w.profileId];
  if (a !== p.windows.w1?.activeTabIds[p.windows.w1.profileId]) globalThis.selections.push(a); }); return 1;`);
const real = async (label, key, focus, expectUrl) => {
  await ac(`globalThis.selections.length = 0; return 1;`);
  const r = await press(key, focus);
  await sleep(300);
  const url = await activeUrl();
  const ok = url.endsWith(`?${expectUrl}`);
  const selected = ok ? [] : await ac(`return globalThis.selections;`);
  check(`${label}: selects ${expectUrl}`, ok, ok ? url : `${url}; ${describe(r)}, first responder ${r.firstResponder}, selected ${selected.join(" → ")}`);
};
const sidebar = { focus: "window" };
const page = { focus: "page", asKey: true, wait: 800, settle: 500 };
const menuLive = async () => {
  await ac(`ac.store.getState().setFocusedWindow("w1"); return 1;`);
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const r = await press(cmd("1", 18), { focus: "window", dry: true });
    if (r.matched?.some((m) => m.command === "selectTab" && m.enabled)) return true;
    await sleep(100);
  }
  return false;
};
check("the window's menu is live before the real presses", await menuLive(), "Select Tab 1 stayed disabled: the menu state has no focused window");
if (part === "precedence") {
  const doubleClickMs = (() => {
    const value = Number.parseFloat(spawnSync("defaults", ["read", "-g", "com.apple.mouse.doubleClick"], { encoding: "utf8" }).stdout);
    return Number.isFinite(value) && value > 0 ? value * 1000 : 500;
  })();
  const gap = Math.min(120, Math.floor(doubleClickMs / 3));
  rep.log(`double-click interval ${doubleClickMs} ms; a quick second press comes ${gap} ms after the first`);
  const sheet = `(() => {
    window.__keys = [];
    window.__consumes = true;
    if (!document.getElementById("grid")) {
      const grid = Object.assign(document.createElement("div"), { id: "grid", contentEditable: "true", textContent: "A1" });
      grid.style.cssText = "position:fixed;left:20px;top:200px;width:300px;height:80px;outline:1px solid #888";
      document.body.append(grid);
      addEventListener("keydown", (e) => {
        if (!e.metaKey && !e.ctrlKey) return;
        window.__keys.push((e.ctrlKey ? "⌃" : "") + (e.altKey ? "⌥" : "") + (e.shiftKey ? "⇧" : "") + (e.metaKey ? "⌘" : "") + e.key);
        if (window.__consumes) e.preventDefault();
      }, true);
    }
    const grid = document.getElementById("grid");
    grid.focus();
    getSelection().selectAllChildren(grid);
    return document.activeElement === grid;
  })()`;
  const windowAction = (action) => ac(`const f = ac.store.getState().windows.w1.frame, C = globalThis.expo.modules.SolaraCEF;
    return C.chromeWindows().then((ws) => ws.filter((w) => w.hasRoot).find((w) => {
      const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }))
      .then((w) => C.devWindow(w.window, ${JSON.stringify(action)}));`);
  await windowAction("fakeActiveClicks");
  const choose = async (chosen) => {
    await ac(`ac.store.getState().updateSettings({ shortcutPrecedence: ${JSON.stringify(chosen)} }); return 1;`);
    await sleep(400);
  };
  const observe = async () => {
    const keys = (await cdp("?t3", "window.__keys.join(' ')")) ?? "(no page)";
    const s = await ac(`const s = ac.store.getState(), w = s.windows.w1, a = w.activeTabIds[w.profileId];
      return { profile: w.profileId, active: a, find: !!s.find[a]?.open, sidebar: w.sidebarOpen, panel: !!s.windowUi.w1?.panel.open };`);
    return { keys, ...s };
  };
  const ready = async (consumes) => {
    await ac(`const s = ac.store.getState(), w = s.windows.w1;
      if (w.profileId !== "default") ac.runCommand({ command: "switchProfile", arg: "default", windowId: "w1" });
      if (!w.sidebarOpen) s.toggleSidebar("w1");
      s.closePanel("w1"); s.setFind("t3", { open: false }); s.setFind("t4", { open: false }); s.activate("t3"); return 1;`);
    await sleep(600);
    await ac(`return ac.shell.devClick("w1", { in: "page", x: 60, y: 240, wait: 150 });`);
    const inGrid = await cdp("?t3", sheet);
    if (!consumes) await cdp("?t3", "(window.__consumes = false, true)");
    await sleep(doubleClickMs + 100);
    const responder = String(await windowAction("responder"));
    return inGrid === true && responder.startsWith("RenderWidgetHostViewCocoa") ? true : `grid ${inGrid}, first responder ${responder}`;
  };
  const at = (key, keyCode, modifiers, after = 0) => ({ key, keyCode, modifiers, after });
  const once = (key, keyCode, modifiers) => [at(key, keyCode, modifiers)];
  const twice = (key, keyCode, modifiers) => [at(key, keyCode, modifiers), at(key, keyCode, modifiers, gap)];
  const run = async (label, presses, accept, { consumes = true } = {}) => {
    const focused = await ready(consumes);
    const before = await observe();
    const times = await ac(`return globalThis.expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify(presses)});`);
    await sleep(1200);
    const after = await observe();
    const apart = times.length > 1 ? `, ${(times[1] - times[0]).toFixed(0)} ms apart` : "";
    check(label, focused === true && accept(after, before), `${JSON.stringify(before)} → ${JSON.stringify(after)}${apart}, page focus: ${focused}`);
  };
  const ARROW = ["command", "option", "function"];
  const down = (n) => (n === 2 ? twice : once)(F(0xf701), 125, ARROW);
  const right = (n = 1) => (n === 2 ? twice : once)(F(0xf703), 124, ARROW);
  const cmdKey = (key, code, n = 1) => (n === 2 ? twice : once)(key, code, ["command"]);
  const pageGot = (after, ...keys) => after.keys === keys.join(" ");

  await choose({});
  await run("⌥⌘↓ in a page that takes it selects the next tab, before the page", down(1), (a) => a.active === "t4" && pageGot(a));
  await run("⌥⌘→ in a page that takes it switches to the next profile, before the page", right(), (a) => a.profile === "p-work" && pageGot(a));
  await run("⌘1 in a page that takes it selects the first tab, before the page", cmdKey("1", 18), (a) => a.active === "pin1" && pageGot(a));
  await run("⇧⌘] in a page that takes it selects the next tab, before the page", once("}", 30, ["command", "shift"]), (a) => a.active === "t4" && pageGot(a));
  await run("one ⌘F in a page that takes it stays with the page", cmdKey("f", 3), (a) => !a.find && pageGot(a, "⌘f"));
  await run("two quick ⌘F in a page that takes it open Find on the second", cmdKey("f", 3, 2), (a) => a.find && pageGot(a, "⌘f"));
  await run("two quick ⌘L in a page that takes it open the command bar on the second", cmdKey("l", 37, 2), (a) => a.panel && pageGot(a, "⌘l"));
  await run("one ⌘S in a page that takes it stays with the page", cmdKey("s", 1), (a, b) => a.sidebar === b.sidebar && pageGot(a, "⌘s"));
  await run("two quick ⌘S in a page that takes it toggle the sidebar once", cmdKey("s", 1, 2), (a, b) => a.sidebar !== b.sidebar && pageGot(a, "⌘s"));
  await run("a single ⌘L in a page's editor that doesn't take it opens the command bar", cmdKey("l", 37), (a) => a.panel && pageGot(a, "⌘l"), { consumes: false });
  await run("a single ⌘F in a page's editor that doesn't take it opens Find", cmdKey("f", 3), (a) => a.find && pageGot(a, "⌘f"), { consumes: false });
  await run("one ⌘S in a page's editor that doesn't take it still stays with the page", cmdKey("s", 1), (a, b) => a.sidebar === b.sidebar && pageGot(a, "⌘s"), { consumes: false });

  await choose({ nextTab: "website", closeTab: "website", newWindow: "both" });
  await run("Next Tab stays Prefer Solara whatever is chosen: ⌥⌘↓ selects the next tab before the page", down(1), (a) => a.active === "t4" && pageGot(a));
  await choose({ nextProfile: "website" });
  await run("Prefer Website: ⌥⌘→ goes to a page that takes it, and the profile stays", right(), (a) => a.profile === "default" && pageGot(a, "⌥⌘ArrowRight"));
  await run("Prefer Website: ⌥⌘→ in a page that doesn't take it still switches the profile", right(), (a) => a.profile === "p-work" && pageGot(a, "⌥⌘ArrowRight"), { consumes: false });
  await run("Prefer Website: two quick ⌥⌘→ both go to the page", right(2), (a) => a.profile === "default" && pageGot(a, "⌥⌘ArrowRight", "⌥⌘ArrowRight"));
  await choose({ findInPage: "solara" });
  await run("Prefer Solara: ⌘F opens Find before a page that takes it", cmdKey("f", 3), (a) => a.find && pageGot(a));
  await choose({ nextProfile: "both" });
  await run("Use Both: one ⌥⌘→ goes to a page that takes it", right(), (a) => a.profile === "default" && pageGot(a, "⌥⌘ArrowRight"));
  await run("Use Both: two quick ⌥⌘→ switch the profile on the second", right(2), (a) => a.profile === "p-work" && pageGot(a, "⌥⌘ArrowRight"));
  await choose({ toggleSidebar: "website" });
  await run("Prefer Website: ⌘S in a page's editor that doesn't take it toggles the sidebar", cmdKey("s", 1), (a, b) => a.sidebar !== b.sidebar && pageGot(a, "⌘s"), { consumes: false });

  await choose({ nextTab: "website", nextProfile: "website", findInPage: "solara" });
  {
    const listed = await ac(`return ac.shell.menuShortcuts().then((items) => Object.fromEntries(items.filter((i) => ["nextTab", "nextProfile", "selectTab:1", "findInPage", "reload", "std:copy:"].includes(i.id)).map((i) => [i.id, [i.precedence, i.defaultPrecedence, i.precedenceFixed]])));`);
    const expected = {
      nextTab: ["solara", "solara", true], nextProfile: ["website", "solara", false], "selectTab:1": ["solara", "solara", false],
      findInPage: ["solara", "both", false], reload: ["website", "website", false], "std:copy:": ["website", "website", false],
    };
    check("the menu tells Settings each shortcut's precedence and its default", isDeepStrictEqual(listed, expected), JSON.stringify(listed));
  }
  await choose({});
  await finish(rep.summary() && !failures ? 0 : 1);
}

await real("⌘1 in the sidebar", cmd("1", 18), sidebar, "pin1");
await real("⌘2 in the sidebar", cmd("2", 19), sidebar, "pin2");
await real("⌘9 in the sidebar", cmd("9", 25), sidebar, "t9");
await real("⌘5 in the sidebar", cmd("5", 23), sidebar, "t3");
await showPage("t3");
await sleep(2000);
await real("⌘1 in a page", cmd("1", 18), page, "pin1");
await showPage("t3");
await cdp("?t3", "document.getElementById('f').focus(), true");
await real("⌘9 in a page's text field", cmd("9", 25), page, "t9");
await showPage("t3");
await cdp("?t3", "document.getElementById('f').focus(), true");
await real("⌘4 in a page's text field", cmd("4", 21), page, "t2");
await ac(`ac.runCommand({ command: "focusCommandBar", arg: null, windowId: "w1" });`);
await sleep(600);
await real("⌘2 in the command bar", cmd("2", 19), { asKey: true }, "pin2");
check("…and the command bar closes", !(await state()).panel, "");
{
  await ac(`ac.runCommand({ command: "newTab", arg: null, windowId: "w1" });`);
  await sleep(1500);
  const typed = await ac(`return ac.shell.devTypeKeys("key", "abc", 30).then(() => new Promise((r) => setTimeout(r, 400)))
    .then(() => ac.omnibox.get("w1:hero")?.state().typed ?? null);`);
  check("⌘T puts the keyboard focus in the New Tab bar", typed === "abc", `the bar holds ${JSON.stringify(typed)}`);
  await real("⌘2 in the New Tab bar", cmd("2", 19), { asKey: true }, "pin2");
  await ac(`const s = ac.store.getState(); for (const t of Object.values(s.tabs)) if (t.windowId === "w1" && !t.url) s.closeTab(t.id);`);
}
await real("⇧⌘] (Next Tab)", cmd("}", 30, "shift"), sidebar, "t1");
await real("⇧⌘[ (Previous Tab)", cmd("{", 33, "shift"), sidebar, "pin2");
await real("⌥⌘↓ (Next Tab)", cmd(F(0xf701), 125, "option", "function"), sidebar, "t1");
await real("⌃⇟ (Next Tab)", K(F(0xf72d), 121, "control", "function"), sidebar, "t2");
{
  const before = (await state()).profile;
  await press(cmd(F(0xf703), 124, "option", "function"), sidebar);
  await sleep(800);
  const next = (await state()).profile;
  check("⌥⌘→ switches to the next profile", next !== before, `${before} → ${next}`);
  await press(cmd(F(0xf702), 123, "option", "function"), sidebar);
  await sleep(800);
  const back = await state();
  check("⌥⌘← switches back to the previous profile, on the same tab", back.profile === before && (await activeUrl()).endsWith("?t2"), `${next} → ${back.profile}`);
}
await showPage("t3");
await sleep(2000);
{
  const next = await ac(`const s = ac.store.getState(), w = s.windows.w1, ids = w.tabIds.filter((id) => s.tabs[id].profileId === w.profileId);
    return ids[ids.indexOf("t3") + 1];`);
  const before = await activeUrl();
  const r = await press(cmd("}", 30, "shift"), page);
  await sleep(300);
  const now = await ac(`const s = ac.store.getState(), w = s.windows.w1; return w.activeTabIds[w.profileId];`);
  check("⇧⌘] in a page selects the next tab", before.endsWith("?t3") && now === next, `${next} expected, ${now} selected; ${describe(r)}`);
}

let s = await state();
await press(cmd("t", 17), sidebar);
await sleep(400);
let after = await state();
check("⌘T opens a tab and selects it", after.tabs === s.tabs + 1 && (await activeUrl()) === "", `${s.tabs} → ${after.tabs} tabs`);
await ac(`const s = ac.store.getState(), w = s.windows.w1; s.navigate(w.activeTabIds[w.profileId], "${pages}/?closed");`);
await sleep(1500);
await press(cmd("w", 13), sidebar);
await sleep(400);
check("⌘W closes it", (await state()).tabs === s.tabs, `${(await state()).tabs} tabs`);
await sleep(1000);
await press(cmd("T", 17, "shift"), sidebar);
await sleep(400);
check("⇧⌘T reopens it", (await state()).tabs === s.tabs + 1, `${(await state()).tabs} tabs`);
await press(K("2", 19, "control"), sidebar);
await sleep(600);
check("⌃2 switches the window to the second profile", (await state()).profile === "p-work", (await state()).profile);
await press(K("1", 18, "control"), sidebar);
await sleep(600);
check("⌃1 switches back", (await state()).profile === "default", (await state()).profile);
await showPage("t3");
await press(cmd("l", 37), sidebar);
await sleep(400);
check("⌘L opens the command bar", (await state()).panel, "");
await ac(`ac.store.getState().closePanel("w1");`);
await showPage("t3");
await sleep(2000);
await cdp("?t3", "(f => (f.value = 'hello field', f.focus(), f.setSelectionRange(0, 0), true))(document.getElementById('f'))");
await press(cmd("a", 0), page);
const selection = await cdp("?t3", "(f => [f.selectionStart, f.selectionEnd, f.value.length].join())(document.getElementById('f'))");
check("⌘A selects all of a page's text field", selection === "0,11,11", selection);

const devWindow = async (action) => {
  const result = await ac(`const f = ac.store.getState().windows.w1.frame, C = globalThis.expo.modules.SolaraCEF;
    return C.chromeWindows().then((ws) => ws.filter((w) => w.hasRoot).find((w) => {
      const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }))
      .then((w) => C.devWindow(w.window, ${JSON.stringify(action)}));`);
  if (action === "responder") {
    const role = result.split(" ")[0];
    const native = await untilSnapshot("native first responder", (s) => (nativeWindow(s)?.firstResponder ?? "nil") === role);
    assert.equal(nativeWindow(native).firstResponder ?? "nil", role);
  }
  return result;
};
const postKeys = async (presses) => {
  const times = await ac(`return globalThis.expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify(presses)});`);
  const native = await untilSnapshot("native posted key timestamps", (s) => isDeepStrictEqual(nativeWindow(s)?.shortcuts.postTimes, times));
  assert.deepEqual(nativeWindow(native).shortcuts.postTimes, times);
  return times;
};
const keyPress = (key, keyCode, after = 0, modifiers = ["command"]) => ({ key, keyCode, modifiers, after });
const post = (key, keyCode, modifiers = ["command"]) => ac(`return globalThis.expo.modules.SolaraApp.devPostKey("w1", ${JSON.stringify(key)}, ${keyCode}, ${JSON.stringify(modifiers)});`);
const clipboard = {
  set: (text) => ac(`globalThis.nativeModuleProxy.Clipboard.setString(${JSON.stringify(text)}); return 1;`),
  get: () => ac(`return globalThis.nativeModuleProxy.Clipboard.getString();`),
};
const busyJsOnce = (ms) => ac(`const off = ac.store.subscribe(() => { off(); const t = Date.now(); while (Date.now() - t < ${ms}); }); return 1;`);
const fieldInAx = async (text) => {
  const value = (await devWindow("ax")).split("\n").some((l) => /AXTextField|AXTextArea/.test(l) && l.includes(text));
  const native = await untilSnapshot("native shortcut destination text field", (s) => nativeWindow(s)?.shortcutFields.some((f) => `${f.role}: ${f.label} | ${f.value}`.includes(text)) === value);
  assert.equal(nativeWindow(native).shortcutFields.some((f) => `${f.role}: ${f.label} | ${f.value}`.includes(text)), value);
  return value;
};
const barValue = async () => {
  const value = await ac(`const bar = ac.omnibox.get("w1:panel") ?? ac.omnibox.get("w1:sidebar"); return String(bar?.state().value ?? "");`);
  const s = await app.snapshot({ windowId: "w1", shortcuts: true, fields: SHORTCUT_FIELDS });
  const bar = nativeWindow(s)?.omnibox;
  const native = await untilSnapshot("native command bar text", (s) => {
    const w = nativeWindow(s);
    return bar ? w?.omnibox?.value === value : w?.shortcutFields.some((f) => f.value === value);
  });
  if (bar) assert.equal(nativeWindow(native).omnibox.value, value);
  else assert.ok(nativeWindow(native).shortcutFields.some((f) => f.value === value));
  return value;
};
const pageField = (expr) => cdp("?t3", `(f => ${expr})(document.getElementById('f'))`);
await devWindow("fakeActiveClicks");
const resetToPageField = async (value, selection) => {
  await ac(`const s = ac.store.getState(), w = s.windows.w1; s.closePanel("w1");
    for (const id of w.tabIds) if (!${JSON.stringify(ids)}.includes(id)) s.closeTab(id);
    s.setFind("t3", { open: false }); s.activate("t3"); return 1;`);
  await sleep(500);
  await ac(`return ac.shell.devClick("w1", { in: "page", x: 60, y: 135, wait: 150 });`);
  await pageField(`(f.value = ${JSON.stringify(value)}, f.focus(), f.setSelectionRange(${selection[0]}, ${selection[1]}), true)`);
  await sleep(100);
};
const sidebarOpen = async () => {
  const value = await ac(`return ac.store.getState().windows.w1.sidebarOpen;`);
  const s = await untilSnapshot("native sidebar visibility", (s) => nativeWindow(s)?.sidebarOpen === value);
  assert.equal(nativeWindow(s).sidebarOpen, value);
  return value;
};
for (const [label, presses, toggles] of [
  ["one ⌘S in a page's text field stays with the page", [keyPress("s", 1)], 0],
  ["two quick ⌘S in a page's text field toggle the sidebar once", [keyPress("s", 1), keyPress("s", 1, 150)], 1],
]) {
  await resetToPageField("", [0, 0]);
  const before = await sidebarOpen();
  await postKeys(presses);
  await sleep(1200);
  const now = await sidebarOpen();
  check(label, (now !== before) === (toggles === 1), `sidebar ${before} → ${now}`);
  if (now !== before) await ac(`ac.store.getState().toggleSidebar("w1"); return 1;`);
}
const handoffs = [
  ["⌘T", "t", 17],
  ["⌘L", "l", 37],
  ["⌘F", "f", 3],
];
let token = 0;
for (const busy of [0, 120]) {
  for (const [name, key, code] of handoffs) {
    for (const gap of [0, 20, 40, 80]) {
      const label = `${name} then +${gap} ms${busy ? `, JS busy ${busy} ms` : ""}`;
      const pasted = `paste-${++token}`;
      await resetToPageField("", [0, 0]);
      await clipboard.set(pasted);
      if (busy) await busyJsOnce(busy);
      const postedAt = await postKeys([keyPress(key, code), keyPress("v", 9, gap)]);
      await sleep(900);
      const inPage = await pageField("f.value");
      const inHero = name === "⌘T" && await ac(`return String(ac.omnibox.get("w1:hero")?.state().value ?? "").includes(${JSON.stringify(pasted)});`);
      const inDestination = inHero || (name === "⌘L" ? (await barValue()).includes(pasted) : await fieldInAx(pasted));
      if (inHero) {
        const nativeHero = await untilSnapshot("native new tab destination field", (s) => nativeWindow(s)?.shortcutFields.some((f) => String(f.value).includes(pasted)));
        assert.ok(nativeWindow(nativeHero).shortcutFields.some((f) => String(f.value).includes(pasted)));
      }
      const held = postedAt[1] - postedAt[0];
      check(`${label} ⌘V pastes into the new field, not the page`, inDestination && !String(inPage).includes(pasted) && held >= gap - 1 && held < gap + 30,
        `page "${inPage}", destination ${inDestination}, keys ${held.toFixed(1)} ms apart`);

      await resetToPageField("page-text", [0, 9]);
      await clipboard.set(`sentinel-${token}`);
      if (busy) await busyJsOnce(busy);
      await postKeys([keyPress(key, code), keyPress("c", 8, gap), keyPress("x", 7), keyPress("a", 0)]);
      await sleep(900);
      const copied = await clipboard.get();
      const page = await pageField("[f.value, f.selectionStart, f.selectionEnd].join()");
      const untouched = key === "f" ? page.startsWith("page-text,") : page === "page-text,0,9";
      check(`${label} ⌘C ⌘X ⌘A stay out of the page`, copied !== "page-text" && untouched, `clipboard "${copied}", page field ${page}`);
    }
  }
}
for (let run = 1; run <= 5; run++) {
  const pasted = `race-${run}`;
  await resetToPageField("", [0, 0]);
  await clipboard.set(pasted);
  await busyJsOnce(60);
  await postKeys([keyPress("f", 3), keyPress("l", 37), keyPress("v", 9)]);
  await sleep(1500);
  const bar = await barValue();
  const panelOpen = (await state()).panel;
  const findQuery = await ac(`return ac.store.getState().find.t3?.query ?? "";`);
  const nativeFind = await untilSnapshot("native find query", (s) => s.tabs.find((t) => t.id === "t3")?.find.query === findQuery);
  assert.equal(nativeFind.tabs.find((t) => t.id === "t3").find.query, findQuery);
  check(`⌘F ⌘L ⌘V back to back (run ${run}): the paste goes to the command bar`,
    panelOpen && bar.includes(pasted) && !findQuery.includes(pasted) && (await pageField("f.value")) === "", `panel ${panelOpen}, bar "${bar}", find "${findQuery}"`);
}
for (const busy of [0, 120]) {
  for (const gap of [0, 30, 60]) {
    await resetToPageField("", [0, 0]);
    if (busy) await busyJsOnce(busy);
    const typed = [["q", 12], ["w", 13], ["e", 14], ["r", 15]].map(([k, code], i) => keyPress(k, code, i ? 15 : gap, []));
    await postKeys([keyPress("l", 37), ...typed]);
    await sleep(1200);
    const bar = await barValue();
    const inPage = await pageField("f.value");
    const beforeGate = gap === 0 && bar === "wer" && inPage === "q";
    check(`⌘L then typing at +${gap} ms${busy ? `, JS busy ${busy} ms` : ""}: the letters land in the bar, in order`, (bar === "qwer" && inPage === "") || beforeGate,
      `bar "${bar}", page "${inPage}"`);
  }
}
{
  await resetToPageField("", [0, 0]);
  const made = await ac(`return ac.store.getState().createWindow({ url: ${JSON.stringify(`${pages}/?t3`)} });`);
  let bar = null;
  if (made) {
    await ac(`return globalThis.expo.modules.SolaraApp.devPostKeys(${JSON.stringify(made)}, ${JSON.stringify([keyPress("l", 37), keyPress("q", 12, 300, []), keyPress("w", 13, 15, [])])});`);
    await sleep(1200);
    bar = await ac(`const b = ac.omnibox.get(${JSON.stringify(`${made}:panel`)}) ?? ac.omnibox.get(${JSON.stringify(`${made}:sidebar`)}); return b ? String(b.state().value ?? "") : null;`);
    const nativeBar = await untilSnapshot("native new-window command bar", (s) => {
      const w = nativeWindow(s, made);
      return w?.omnibox?.value === bar || w?.shortcutFields.some((f) => f.value === bar);
    }, 5000, { windowId: made });
    const w = nativeWindow(nativeBar, made);
    assert.ok(w.omnibox?.value === bar || w.shortcutFields.some((f) => f.value === bar));
    await ac(`ac.store.getState().closeWindow(${JSON.stringify(made)}); return 1;`);
    await sleep(800);
  }
  check("a new window with a page, ⌘L at once, then typing: the letters land in its bar", bar === "qw", `window ${made}, bar ${JSON.stringify(bar)}`);
}
{
  await resetToPageField("", [0, 0]);
  await clipboard.set("ordered");
  await postKeys([keyPress("l", 37), keyPress("v", 9), keyPress("q", 12, 0, [])]);
  await sleep(1200);
  const bar = await barValue();
  const inPage = await pageField("f.value");
  check("⌘L ⌘V q back to back: the paste lands in the bar and keeps its place before q", (bar === "orderedq" && inPage === "") || (bar === "ordered" && inPage === "q"),
    `bar "${bar}", page "${inPage}"`);
}
{
  await resetToPageField("", [0, 0]);
  await clipboard.set("after-return");
  await busyJsOnce(150);
  await postKeys([keyPress("l", 37), keyPress("\r", 36, 20, []), keyPress("v", 9, 20)]);
  await sleep(2000);
  const trace = await ac(`return globalThis.expo.modules.SolaraApp.devFocusHandoffTrace();`);
  const nativeTrace = await untilSnapshot("native focus handoff trace", (s) => isDeepStrictEqual(nativeWindow(s)?.shortcuts.focusTrace, trace), 5000, { shortcutTrace: true, fields: ["windows.shortcuts"] });
  assert.deepEqual(nativeWindow(nativeTrace).shortcuts.focusTrace, trace);
  const replayAt = trace.findLastIndex((l) => / replay /.test(l));
  const dropped = replayAt >= 0 && trace.slice(replayAt).some((l) => / drop /.test(l));
  const inPage = await pageField("f.value");
  check("⌘L Return ⌘V while the bar mounts: Return commits, the paste after it is dropped, not sent to the old field", dropped && !String(inPage).includes("after-return"),
    `page "${inPage}", trace ${trace.slice(-6).join(" / ")}`);
  await showPage("t3");
}
{
  await resetToPageField("", [0, 0]);
  await clipboard.set("first");
  await cdp("?t3", "(window.slowShortcuts ??= addEventListener('keydown', (e) => { if (e.metaKey) { const t = performance.now(); while (performance.now() - t < 200); } }, true), true)");
  await postKeys([keyPress("f", 3), keyPress("v", 9), keyPress("q", 12, 300, [])]);
  await sleep(1500);
  const query = await ac(`return ac.store.getState().find.t3?.query ?? "";`);
  const nativeFind = await untilSnapshot("native find query", (s) => s.tabs.find((t) => t.id === "t3")?.find.query === query);
  assert.equal(nativeFind.tabs.find((t) => t.id === "t3").find.query, query);
  const inPage = await pageField("f.value");
  const ordered = query === "firstq" || query === "q" || (query === "first" && inPage === "q");
  check("⌘F ⌘V, then q while the page answers late: the paste never lands after q", ordered && !query.startsWith("q" + "first"), `find "${query}", page "${inPage}"`);
  await cdp("?t3", "location.reload(), true");
  await sleep(1500);
}
{
  await resetToPageField("", [0, 0]);
  await cdp("?t3", "(window.qUps = 0, document.getElementById('f').addEventListener('keyup', (e) => e.key === 'q' && window.qUps++), true)");
  await postKeys([keyPress("l", 37), { ...keyPress("q", 12, 30, []), phase: "down" }]);
  await sleep(100);
  await ac(`return ac.shell.devClick("w1", { in: "page", x: 60, y: 135, wait: 100 });`);
  await postKeys([{ ...keyPress("q", 12, 0, []), phase: "up" }]);
  await sleep(500);
  const ups = await cdp("?t3", "window.qUps");
  await postKeys([keyPress("z", 6, 0, [])]);
  await sleep(300);
  const typed = await pageField("f.value");
  check("⌘L, q held, a click into the page, q released: the page never sees the lone keyUp, and typing goes on", ups === 0 && typed.endsWith("z"), `q keyups ${ups}, field "${typed}"`);
}
{
  await resetToPageField("", [0, 0]);
  await cdp("?t3", "(window.nextUps = 0, window.nextDowns = 0, document.getElementById('f').addEventListener('keyup', (e) => e.key === 'q' && window.nextUps++), document.getElementById('f').addEventListener('keydown', (e) => e.key === 'q' && window.nextDowns++), true)");
  await postKeys([keyPress("l", 37), { ...keyPress("q", 12, 30, []), phase: "down" }]);
  await sleep(100);
  await ac(`return ac.shell.devClick("w1", { in: "page", x: 60, y: 135, wait: 100 });`);
  await postKeys([keyPress("q", 12, 0, [])]);
  await sleep(400);
  const [downs, ups] = [await cdp("?t3", "window.nextDowns"), await cdp("?t3", "window.nextUps")];
  check("a key whose release was never seen doesn't swallow the keyUp of its next ordinary press", downs === 1 && ups === 1, `q keydowns ${downs}, keyups ${ups}`);
}
const countPastes = () => Promise.all(ids.map((id) => cdp(`?${id}`, "(window.pastes ??= (addEventListener('paste', () => window.pastes.n++, true), { n: 0 })).n = 0, true")));
const pastesIn = (id) => cdp(`?${id}`, "window.pastes?.n ?? 0");
const pastesElsewhere = async (except) => (await Promise.all(ids.filter((id) => id !== except).map(pastesIn))).reduce((a, n) => a + (n ?? 0), 0);
const activeId = async () => {
  const value = await ac(`const s = ac.store.getState(), w = s.windows.w1; return w.activeTabIds[w.profileId];`);
  const s = await untilSnapshot("native active tab", (s) => nativeWindow(s)?.selectedTabId === value);
  assert.equal(nativeWindow(s).selectedTabId, value);
  return value;
};
const handoffEnds = [
  ["⌘L ⌘W before the bar mounts", [keyPress("l", 37), keyPress("w", 13, 30), keyPress("v", 9, 30)], 150, 0],
  ["⌘L, the bar shown, ⌘W", [keyPress("l", 37), keyPress("w", 13, 300), keyPress("v", 9, 30)], 0, 1],
  ["⌘F, Find shown, Esc", [keyPress("f", 3), keyPress("\u001b", 53, 300, []), keyPress("v", 9, 30)], 0, 1],
  ["⌘T ⌘W", [keyPress("t", 17), keyPress("w", 13), keyPress("v", 9, 30)], 0, 1],
  ["⌘L, ⌘W at 300 ms, JS busy 450 ms", [keyPress("l", 37), keyPress("w", 13, 300), keyPress("v", 9, 30)], 450, 0],
  ["⌘L ⌘V, JS busy 500 ms", [keyPress("l", 37), keyPress("v", 9)], 500, 0],
];
for (const [name, keys, busy, firstExpected] of handoffEnds) {
  await resetToPageField("", [0, 0]);
  await countPastes();
  await clipboard.set(`ended-${name.replace(/\W+/g, "")}`);
  if (busy) await busyJsOnce(busy);
  await postKeys(keys);
  await sleep(1200);
  await ac(`const s = ac.store.getState(); if (s.windowUi.w1?.panel.open) s.closePanel("w1"); return 1;`);
  if (name.startsWith("⌘L ⌘V")) await ac(`return ac.shell.devClick("w1", { in: "page", x: 60, y: 135, wait: 150 });`);
  const active = await activeId();
  const first = await pastesIn(active);
  const strays = await pastesElsewhere(active);
  await postKeys([keyPress("v", 9)]);
  await sleep(600);
  const second = await pastesIn(active);
  const responder = await devWindow("responder");
  const trace = first === firstExpected ? "" : `; trace ${(await ac(`return globalThis.expo.modules.SolaraApp.devFocusHandoffTrace();`)).slice(-8).join(" / ")}`;
  check(`${name} then ⌘V: ${firstExpected ? "pastes once into the page that has the focus" : "dropped with a beep, nowhere else"}; the next ⌘V pastes`,
    first === firstExpected && strays === 0 && second === firstExpected + 1 && responder.startsWith("RenderWidgetHostViewCocoa"),
    `active ${active}, pastes ${first} then ${second}, elsewhere ${strays}, first responder ${responder}${trace}`);
}
{
  await resetToPageField("", [0, 0]);
  await countPastes();
  await clipboard.set("fresh-after-return");
  await postKeys([keyPress("l", 37)]);
  await sleep(700);
  await ac(`const d = ac.omnibox.get("w1:panel") ?? ac.omnibox.get("w1:sidebar"); return d ? Promise.resolve(d.type(${JSON.stringify(`${pages}/?t3#after-return`)})).then(() => new Promise((r) => setTimeout(r, 400))).then(() => 1) : 0;`);
  await postKeys([keyPress("\r", 36, 0, []), keyPress("v", 9, 150)]);
  await sleep(900);
  const trace = await ac(`return globalThis.expo.modules.SolaraApp.devFocusHandoffTrace();`);
  const nativeTrace = await untilSnapshot("native focus handoff trace", (s) => isDeepStrictEqual(nativeWindow(s)?.shortcuts.focusTrace, trace), 5000, { shortcutTrace: true, fields: ["windows.shortcuts"] });
  assert.deepEqual(nativeWindow(nativeTrace).shortcuts.focusTrace, trace);
  const after = trace.slice(trace.findLastIndex((l) => / claim /.test(l)) + 1);
  const forwarded = after.some((l) => / forward paste/.test(l)), dropped = after.some((l) => / drop /.test(l));
  check("⌘L, a URL, Return, then a fresh ⌘V 150 ms later: the paste goes on to the page, not dropped", forwarded && !dropped, `trace ${after.join(" / ")}`);
}
{
  await resetToPageField("", [0, 0]);
  await clipboard.set("landed-after-return");
  await postKeys([keyPress("l", 37)]);
  await sleep(700);
  await ac(`const d = ac.omnibox.get("w1:panel") ?? ac.omnibox.get("w1:sidebar"); return d ? Promise.resolve(d.type(${JSON.stringify(`${pages}/?autofocus`)})).then(() => new Promise((r) => setTimeout(r, 400))).then(() => 1) : 0;`);
  await postKeys([keyPress("\r", 36, 0, []), keyPress("v", 9, 150)]);
  await sleep(1200);
  const landed = await cdp("?autofocus", `document.getElementById("t").value`);
  check("⌘L, a URL to a page that focuses a textarea, Return, then ⌘V 150 ms later: the textarea holds the paste", landed === "landed-after-return", `textarea ${JSON.stringify(landed)}`);
  await cdp("?autofocus", "(history.back(), true)");
  await sleep(1000);
}
await resetToPageField("", [0, 0]);
await countPastes();
await devWindow("responder");
await ac(`ac.shell.devKeyEquivalent("w1", { key: "x", keyCode: 7, modifiers: [], focus: "window", dry: true, wait: 0 }); return 1;`);
await postKeys([keyPress("v", 9)]);
await ac(`ac.store.getState().activate("t4"); return 1;`);
await sleep(1000);
check("⌘V with nothing focused, then another tab shown: nothing is pasted", (await pastesElsewhere("none")) === 0, `pastes ${await pastesElsewhere("none")}`);
await resetToPageField("", [0, 0]);
await clipboard.set("after-escape");
await post("l", 37);
await sleep(500);
const barBeforeEscape = await barValue();
const responderBeforeEscape = await devWindow("responder");
await post("\u001b", 53, []);
await sleep(500);
const responder = await devWindow("responder");
const closedByEscape = !(await ac(`return ac.store.getState().windowUi.w1.panel.open;`));
const nativeClosed = await untilSnapshot("native Escape closes panel", (s) => nativeWindow(s)?.panelOpen === !closedByEscape);
assert.equal(nativeWindow(nativeClosed).panelOpen, !closedByEscape);
await post("v", 9);
await sleep(600);
const afterEscape = await pageField("f.value");
check("Escape out of the command bar gives the page its focus back",
  barBeforeEscape.includes("?t3") && !responderBeforeEscape.startsWith("RenderWidgetHostViewCocoa") && closedByEscape && responder.startsWith("RenderWidgetHostViewCocoa") && afterEscape === "after-escape",
  `bar "${barBeforeEscape}" with ${responderBeforeEscape.split(" ")[0]}, closed ${closedByEscape}, first responder ${responder}, page field "${afterEscape}"`);
await resetToPageField("", [0, 0]);

for (const where of ["the find field", "the page"]) {
  await resetToPageField("", [0, 0]);
  await ac(`const s = ac.store.getState(), id = s.newTab("w1"); s.navigate(id, "${pages}/?findclose"); s.closePanel("w1"); s.activate(id); return 1;`);
  await sleep(1500);
  await ac(`return ac.shell.devClick("w1", { in: "page", x: 200, y: 300, wait: 150 });`);
  const findState = async () => {
    const value = await ac(`const s = ac.store.getState(), w = s.windows.w1, a = w.activeTabIds[w.profileId];
      return { tabs: w.tabIds.length, active: a, url: s.tabs[a]?.url ?? "", find: !!s.find[a]?.open };`);
    const s = await untilSnapshot("native find/tab state", (s) => {
      const w = nativeWindow(s), t = s.tabs.find((t) => t.id === w?.selectedTabId);
      return w?.tabIds.length === value.tabs && t?.id === value.active && t.url === (value.url === "" ? null : value.url) && t.find.open === value.find;
    });
    const w = nativeWindow(s), t = s.tabs.find((t) => t.id === w.selectedTabId);
    assert.deepEqual({ tabs: w.tabIds.length, active: t.id, url: t.url, find: t.find.open }, { ...value, url: value.url === "" ? null : value.url });
    return value;
  };
  const before = await findState();
  await postKeys([keyPress("f", 3), ...[..."hello"].map((c) => keyPress(c, 0, 30, []))]);
  await sleep(800);
  if (where === "the page") await ac(`return ac.shell.devClick("w1", { in: "page", x: 200, y: 300, wait: 150 });`);
  const opened = await findState();
  await postKeys([keyPress("w", 13)]);
  await sleep(800);
  const after = await findState();
  check(`⌘W with the find bar open and the focus in ${where} closes the tab in one press, and the next tab has no find bar`,
    opened.find && after.tabs === before.tabs - 1 && !after.find, `before ${JSON.stringify(before)}, open ${opened.find}, after ${JSON.stringify(after)}`);
  await postKeys([keyPress("T", 17, 0, ["command", "shift"])]);
  await sleep(1500);
  const reopened = await findState();
  check(`…and ⇧⌘T brings it back without its find bar (${where})`, reopened.url === before.url && !reopened.find, JSON.stringify(reopened));
}
{
  await resetToPageField("", [0, 0]);
  await postKeys([keyPress("f", 3), ...[..."hello"].map((c) => keyPress(c, 0, 30, [])), keyPress("\u001b", 53, 300, [])]);
  await sleep(800);
  const after = await ac(`const s = ac.store.getState(), w = s.windows.w1, a = w.activeTabIds[w.profileId]; return { active: a, find: !!s.find[a]?.open };`);
  check("Esc closes only the find bar", after.active === "t3" && !after.find, JSON.stringify(after));
  const native = await untilSnapshot("native Escape closes find", (s) => nativeWindow(s)?.selectedTabId === after.active && s.tabs.find((t) => t.id === after.active)?.find.open === after.find);
  assert.equal(native.tabs.find((t) => t.id === after.active).find.open, after.find);
}
await fullShortcutSnapshotFits("after the presses");
await press(cmd("q", 12), { focus: "window", wait: 0 });
let quit = false;
for (let i = 0; i < 150 && !quit; i++) {
  await sleep(100);
  quit = app.exited;
}
check("⌘Q quits", quit, quit ? "" : "still running after 15 s");

finish(rep.summary() && !failures ? 0 : 1);
