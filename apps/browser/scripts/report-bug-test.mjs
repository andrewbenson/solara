import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg, ...rest] = process.argv.slice(2);
assert.ok(appArg && outputArg && rest.length === 0, "usage: node apps/browser/scripts/report-bug-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use a scratch Debug app");
const output = resolve(outputArg);
mkdirSync(output, { recursive: false });
const rep = reporter(join(output, "report-bug.log"), { name: "report-bug" });
const plist = (key) => execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print ${key}`, join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim();
const bundleId = plist("CFBundleIdentifier");
assert.equal(bundleId, "network.benson.solara.dev", "a Debug build of the dev identity");
const executable = plist("CFBundleExecutable");
const repo = plist("ACReleaseRepo");
const version = plist("CFBundleShortVersionString");
const build = plist("CFBundleVersion");
const model = execFileSync("/usr/sbin/sysctl", ["-n", "hw.model"], { encoding: "utf8", timeout: 5000 }).trim();
const productVersion = execFileSync("/usr/bin/sw_vers", ["-productVersion"], { encoding: "utf8", timeout: 5000 }).trim();
const macOS = [...productVersion.split("."), "0", "0"].slice(0, 3).join(".");
const issueBase = `https://github.com/${repo}/issues/new?`;
const secretPage = "https://secret-page.example/private-path";
const secretTitle = "Private Tab Title 7731";
const home = process.env.HOME;
let app;
let stopped = false;
const stop = async (code) => {
  stopped = true;
  if (app) await app.quit({ graceful: false }).catch(() => {});
  process.exit(code);
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) process.once(signal, () => void stop(code));
const budget = setTimeout(() => { rep.record("eight-minute run budget", { error: new Error("deadline exceeded") }); void stop(1); }, 480000);

const run = (source, timeout = 3000) => {
  assert.ok(!stopped && app?.stillOwned(), "owned instance exited");
  return app.eval(source, { timeout });
};
const until = async (name, read, accept = Boolean, timeout = 15000) => {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() + 1000 < end) {
    assert.ok(app?.stillOwned(), `${name}: owned instance exited`);
    last = await read();
    if (accept(last)) return last;
    await sleep(60);
  }
  throw new Error(`${name}: deadline exceeded: ${JSON.stringify(last)?.slice(0, 2000)}`);
};
const bug = (action, argument = null) => run(`return globalThis.expo.modules.SolaraSettings.devBugReport(${JSON.stringify(action)}, ${JSON.stringify(argument)}).then(JSON.parse);`);
const tabs = () => run(`const s = ac.store.getState(); return { order: [...(s.windows.w1?.tabIds ?? [])], active: s.windows.w1 ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null,
  urls: Object.fromEntries(Object.values(s.tabs).map((t) => [t.id, t.url])), windows: Object.fromEntries(Object.entries(s.windows).map(([id, w]) => [id, { small: w.kind === "small", tabIds: [...w.tabIds] }])) };`);
const query = (url) => Object.fromEntries(new URL(url).searchParams.entries());
const check = async (name, fn) => {
  if (!await rep.check(name, fn)) throw new Error(`stopping after ${name}`);
};

function expectIssue(url, { layout = "Sidebar", crash = false } = {}) {
  assert.ok(url?.startsWith(issueBase), `issue URL: ${url}`);
  assert.ok(url.length <= 7500, `URL is ${url.length} long`);
  const fields = query(url);
  const want = { template: "bug.yml", version: build && build !== version ? `${version} (${build})` : version, macos: macOS, mac: model, layout };
  for (const [key, value] of Object.entries(want)) assert.equal(fields[key], value, `${key} field`);
  assert.deepEqual(Object.keys(fields).sort(), [...Object.keys(want), ...(crash ? ["crash"] : [])].sort(), "only the form's fields");
  for (const leak of [secretPage, "secret-page", secretTitle, home]) assert.ok(!decodeURIComponent(url).includes(leak), `${leak} stays out of the link`);
  return fields;
}

async function openedTab(name, before, trigger, windowId = "w1") {
  await trigger();
  const after = await until(name, tabs, (t) => {
    const added = t.windows[windowId]?.tabIds.filter((id) => !before.windows[windowId]?.tabIds.includes(id)) ?? [];
    return added.length === 1 && t.urls[added[0]]?.startsWith(issueBase);
  });
  const added = after.windows[windowId].tabIds.find((id) => !before.windows[windowId].tabIds.includes(id));
  if (windowId === "w1") assert.equal(after.active, added, "the report opens as the window's active tab");
  return after.urls[added];
}

function ips(dir, name, { id = bundleId, time = null, bugType = "309" } = {}) {
  const header = { app_name: executable, timestamp: "2026-11-19 09:15:02.00 -0800", app_version: version, build_version: build, bug_type: bugType, bundleID: id, name: executable };
  const body = {
    procPath: `${home}/Fixture/${executable}.app/Contents/MacOS/${executable}`,
    exception: { type: "EXC_BAD_ACCESS", signal: "SIGSEGV", subtype: "KERN_INVALID_ADDRESS at 0x10" },
    asi: { CoreFoundation: [`Terminating on ${secretPage} titled ${secretTitle}`] },
    faultingThread: 0,
    threads: [{ triggered: true, queue: "com.apple.main-thread", name: secretTitle, frames: Array.from({ length: 20 }, (_, i) => ({ imageOffset: 4096 + i, imageIndex: i % 2, symbol: i === 1 ? `load(${secretPage})` : `fixtureFrame${i}`, symbolLocation: i })) }],
    usedImages: [
      { name: executable, path: `${home}/Fixture/${executable}.app/Contents/MacOS/${executable}`, uuid: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9" },
      { name: "libobjc.A.dylib", path: "/usr/lib/libobjc.A.dylib", uuid: "FFFFFFFF-0000-1111-2222-333333333333" },
    ],
  };
  const path = join(dir, name);
  writeFileSync(path, `${JSON.stringify(header)}\n${JSON.stringify(body, null, 2)}`);
  if (time) utimesSync(path, time, time);
  return path;
}

const nativeEnv = { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_OMNIBOX: "1", SOLARA_NATIVE_NEWTAB: "1" };
const fixtureSession = session({
  windows: [{ id: "w1", activeTabIds: { default: "a" }, frame: [80, 80, 1280, 860] }],
  tabs: [{ id: "a", url: secretPage, title: secretTitle }, { id: "b", url: "about:blank#b", title: "B" }],
  settings: { newTabOpens: "commandBar", commandBarPlacement: "centred", addressBar: "toolbar", searchSuggestions: false, sleepInactiveTabs: false,
    warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeClosingTabs: false },
});
const start = (data, env, { fresh = true } = {}) => launch(appPath, {
  data, fresh, keepData: true, onboarded: true, probe: true, env: { ...nativeEnv, ...env },
  ...(fresh ? { session: fixtureSession } : {}),
  files: { "bench-offline": "1" },
  ready: "return !!globalThis.acPerf && !!ac.store.getState().windows.w1 && !!globalThis.expo?.modules?.SolaraSettings?.devBugReport;",
});
const quit = async () => { if (app) await app.quit(); app = null; };

const bar = () => run("return globalThis.__nativeActionBar.driverState().then(JSON.parse);", 1000);
const acquirePanel = async () => {
  await until("panel native field attached", () => run(`
    const f = acPerf.findFibers("NativeOmniboxBar", 200).find(f => f.memoizedProps.variant === "panel" && !f.memoizedProps.idle);
    if (!f) return false;
    for (let h = f.memoizedState; h; h = h.next) {
      const handle = h.memoizedState?.current;
      if (typeof handle?.driverState === "function") { globalThis.__nativeActionBar = handle; return true; }
    }
    return false;
  `));
  await run("return globalThis.__nativeActionBar.focus().then(() => true);");
  return until("panel native ownership", bar, (s) => s.variant === "panel" && s.focused && s.fieldAttached && s.nativeActions === true);
};

try {
  const quiet = join(output, "reports-first-run");
  mkdirSync(quiet);
  ips(quiet, `${executable}-2026-11-18-090000.ips`);
  app = await start(join(output, "data-a"), { SOLARA_DEV_CRASH_REPORTS_DIR: quiet });

  await check("first run seeds the last-seen mark and never prompts for an old report", async () => {
    const state = await until("crash check ran", () => bug("state"), (s) => s.checked);
    await sleep(2500);
    const later = await bug("state");
    assert.equal(later.prompt.shown, false, "no prompt");
    assert.ok(existsSync(join(quiet, ".solara-crash-seen")), "mark written");
    assert.equal(state.lastOpened, null);
  });

  await check("Help › Report a Bug… opens the filled-in form in a new foreground tab", async () => {
    const help = await run('return expo.modules.SolaraApp.devMenuItems("Help", null);');
    const item = help.find((i) => i.title === "Report a Bug…");
    assert.ok(item && item.enabled && !item.hidden && item.key === "", `menu item: ${JSON.stringify(item)}`);
    const before = await tabs();
    const url = await openedTab("menu report tab", before, () => run('return expo.modules.SolaraApp.devMenuItems("Help", ["Report a Bug…"]);'));
    expectIssue(url);
  });

  await check("the command bar's Report a Bug row opens the same form", async () => {
    await run('const s = ac.store.getState(); s.activate("a"); s.openPanel("w1", ""); return true;');
    await acquirePanel();
    await run(`return globalThis.__nativeActionBar.clear().then(() => globalThis.__nativeActionBar.type("Report a Bug")).then(() => true);`);
    const value = await until("reportBug row", bar, (s) => s.items.some((row) => row.kind === "action" && row.id === "reportBug"));
    const index = value.items.findIndex((row) => row.kind === "action" && row.id === "reportBug");
    assert.equal(value.items[index].title, "Report a Bug");
    await run('return globalThis.__nativeActionBar.key("PageUp", {}).then(() => true);');
    for (let row = 0; row < index; row++) await run('return globalThis.__nativeActionBar.key("ArrowDown", {}).then(() => true);');
    await until("reportBug selected", bar, (s) => s.items[s.selected]?.id === "reportBug");
    const before = await tabs();
    const url = await openedTab("command bar report tab", before, () => run('return ac.shell.devTypeKeys("w1", "\\r", 5);'));
    expectIssue(url);
  });

  await check("the layout field follows the window's tab layout", async () => {
    await run('ac.store.getState().updateSettings({ tabLayout: "top" }); return true;');
    const top = await until("top layout", () => bug("url", "w1"), (r) => r.url && query(r.url).layout === "Top tabs");
    expectIssue(top.url, { layout: "Top tabs" });
    await run('ac.store.getState().updateSettings({ tabLayout: "sidebar" }); return true;');
    await until("sidebar layout", () => bug("url", "w1"), (r) => r.url && query(r.url).layout === "Sidebar");
  });

  await check("from Little Solara the report opens in its main window", async () => {
    const small = await run('return ac.store.getState().createWindow({ url: "about:blank#small", small: true });');
    await until("small window", tabs, (t) => t.windows[small]?.small);
    const before = await tabs();
    const url = await openedTab("routed report tab", before, () => run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand(${JSON.stringify(small)}, "reportBug", null);`));
    expectIssue(url);
    const after = await tabs();
    assert.deepEqual(after.windows[small].tabIds, before.windows[small].tabIds, "Little Solara gets no tab");
  });
  await quit();

  const reports = join(output, "reports");
  mkdirSync(reports);
  const ours = ips(reports, `${executable}-2026-11-19-091502.ips`);
  ips(reports, `${executable} Helper (Renderer)-2026-11-19-091503.ips`, { id: `${bundleId}.helper.renderer` });
  ips(reports, "Mail-2026-11-19-091504.ips", { id: "com.apple.mail" });
  ips(reports, `${executable}_2026-11-19-091505_Mac.cpu_resource.diag.ips`, { bugType: "202", time: Date.now() / 1000 + 2 });
  const crashed = join(output, "data-b");
  app = await start(crashed, { SOLARA_DEV_CRASH_REPORTS_DIR: reports, SOLARA_DEV_CRASH_SEEN: "0" });

  await check("after a crash the prompt asks once, over the window, without taking focus", async () => {
    const state = await until("prompt shown", () => bug("state"), (s) => s.prompt.shown);
    assert.equal(state.prompt.message, `${plist("CFBundleName")} quit unexpectedly last time. Report it?`);
    assert.deepEqual(state.prompt.buttons, ["Not Now", "Report"]);
    assert.equal(state.prompt.isKey, false, "the prompt is not the key window");
    assert.equal(state.prompt.becomesKeyOnlyIfNeeded, true, "the prompt takes the keyboard only when the user asks for it");
    assert.equal(state.prompt.label, state.prompt.message, "VoiceOver reads the question");
    const [x, y, w, h] = state.prompt.frame;
    const [px, py, pw, ph] = state.prompt.parentFrame;
    assert.ok(x >= px && y >= py && x + w <= px + pw && y + h <= py + ph, "inside its window");
    const shot = await bug("snapshot", join(output, "crash-prompt.png"));
    assert.equal(shot.written, true, "prompt snapshot written");
    await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(join(output, "crash-prompt-window.png"))});`, 10000).catch(() => false);
  });

  await check("Report fills the crash field and shows the report in Finder", async () => {
    const before = await tabs();
    const keyBefore = (await bug("state")).keyWindowNumber;
    const url = await openedTab("crash report tab", before, async () => assert.equal((await bug("click", "report")).clicked, true));
    const fields = expectIssue(url, { crash: true });
    const crash = fields.crash;
    assert.ok(crash.startsWith("Exception: EXC_BAD_ACCESS (SIGSEGV)\nQueue: com.apple.main-thread\n"), crash);
    assert.ok(crash.includes(`Binary: ${executable} ${version}${build && build !== version ? ` (${build})` : ""} UUID 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9`), crash);
    assert.ok(crash.includes(`0  ${executable}  fixtureFrame0 + 0`), crash);
    assert.ok(crash.includes(`14  ${executable}  fixtureFrame14 + 14`) && crash.includes("13  libobjc.A.dylib  fixtureFrame13 + 13"), crash);
    assert.ok(!crash.includes("fixtureFrame15"), "top 15 frames only");
    for (const leak of ["Terminating", "KERN_INVALID_ADDRESS", "secret-page", secretTitle, home]) assert.ok(!crash.includes(leak), `${leak} stays out`);
    const state = await bug("state");
    assert.equal(state.answered, "report");
    assert.equal(state.revealed, ours, "the .ips to drag onto the issue");
    assert.equal(state.prompt.shown, false);
    assert.equal(keyBefore === -1 || state.keyWindowNumber === keyBefore || state.keyWindowNumber === -1, true, "one click, and the key window stays");
  });
  await quit();

  await check("the same crash never prompts again", async () => {
    app = await start(crashed, { SOLARA_DEV_CRASH_REPORTS_DIR: reports }, { fresh: false });
    await until("crash check ran", () => bug("state"), (s) => s.checked);
    await sleep(3000);
    assert.equal((await bug("state")).prompt.shown, false);
    await quit();
  });

  await check("Not Now dismisses a newer crash's prompt and opens nothing", async () => {
    const later = Date.now() / 1000 + 5;
    ips(reports, `${executable}-2026-11-19-101502.ips`, { time: later });
    app = await start(crashed, { SOLARA_DEV_CRASH_REPORTS_DIR: reports }, { fresh: false });
    await until("prompt shown", () => bug("state"), (s) => s.prompt.shown);
    const before = await tabs();
    assert.equal((await bug("click", "notNow")).clicked, true);
    const state = await until("prompt dismissed", () => bug("state"), (s) => !s.prompt.shown);
    assert.equal(state.answered, "notNow");
    assert.equal(state.revealed, null);
    await sleep(1000);
    assert.deepEqual((await tabs()).order, before.order, "no tab opened");
    await quit();
  });

  await check("closing its window takes the prompt away", async () => {
    ips(reports, `${executable}-2026-11-19-111502.ips`, { time: Date.now() / 1000 + 10 });
    app = await start(crashed, { SOLARA_DEV_CRASH_REPORTS_DIR: reports }, { fresh: false });
    await until("prompt shown", () => bug("state"), (s) => s.prompt.shown);
    const other = await run('return ac.store.getState().createWindow({ url: "about:blank#other" });');
    await until("second window", tabs, (t) => !!t.windows[other]);
    await run('return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeWindow", null);');
    const state = await until("prompt close receipt", () => bug("state"), (s) => !s.prompt.shown && s.answered === "closed");
    assert.equal(state.lastOpened, null, "closing answers nothing");
    await quit();
  });
  const quietReports = join(output, "reports-minimized");
  mkdirSync(quietReports);
  ips(quietReports, `${executable}_2026-11-19-090000_Mac.diskwrites_resource.diag.ips`, { bugType: "145" });
  const mark = () => Number(readFileSync(join(quietReports, ".solara-crash-seen"), "utf8"));
  const minimized = join(output, "data-m");

  await check("a resource diagnostic never prompts", async () => {
    app = await start(minimized, { SOLARA_DEV_CRASH_REPORTS_DIR: quietReports, SOLARA_DEV_CRASH_SEEN: "0" });
    await until("crash check ran", () => bug("state"), (s) => s.checked);
    await until("mark advanced past the diagnostic", async () => existsSync(join(quietReports, ".solara-crash-seen")) && mark() > 0, Boolean);
    await sleep(2000);
    const state = await bug("state");
    assert.equal(state.prompt.shown, false);
    assert.equal(state.pending, false);
  });

  await check("with its window minimized the prompt waits, keeps the crash unseen, and shows when the window comes back", async () => {
    const before = mark();
    await bug("minimize", "w1");
    await sleep(1500);
    ips(quietReports, `${executable}-2026-11-19-121502.ips`, { time: Date.now() / 1000 + 5 });
    await bug("recheck");
    await until("crash found", () => bug("state"), (s) => s.pending);
    await sleep(3000);
    let state = await bug("state");
    assert.equal(state.prompt.shown, false, "no prompt over a minimized window");
    assert.equal(mark(), before, "the crash is not marked seen while it waits");
    await bug("deminiaturize", "w1");
    state = await until("prompt after the window comes back", () => bug("state"), (s) => s.prompt.shown);
    assert.equal(state.pending, false);
    assert.ok(mark() > before, "marked seen once shown");
    assert.equal((await bug("click", "notNow")).clicked, true);
  });

  await check("a crash still waiting at quit prompts at the next launch", async () => {
    await bug("minimize", "w1");
    await sleep(1500);
    const before = mark();
    ips(quietReports, `${executable}-2026-11-19-131502.ips`, { time: Date.now() / 1000 + 10 });
    await bug("recheck");
    await until("crash found", () => bug("state"), (s) => s.pending);
    await quit();
    assert.equal(mark(), before, "quitting while it waits keeps it unseen");
    app = await start(minimized, { SOLARA_DEV_CRASH_REPORTS_DIR: quietReports }, { fresh: false });
    await until("prompt on the next launch", () => bug("state"), (s) => s.prompt.shown);
    assert.ok(mark() > before);
    assert.equal((await bug("click", "notNow")).clicked, true);
    await quit();
  });
  if (!rep.summary()) process.exitCode = 1;
} catch (error) {
  rep.record("run", { error });
  rep.summary();
  process.exitCode = 1;
} finally {
  clearTimeout(budget);
  if (app) await app.quit({ graceful: false }).catch(() => {});
}
