#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { commandIsBinary, isAlive, launch, listenerPids, processInfo, realPath, reporter, session, sleep, uiGateWatch } from "../../../scripts/lib/instance.mjs";

const LEGS = ["refused", "openFailed", "earlyWindow", "noFolder", "safeMode", "report", "autoSafeMode", "quit", "savesNothingReload", "savesNothingRefused"];
const HELP = `usage: node apps/browser/scripts/store-unavailable-test.mjs <Debug Solara.app> [leg…] [--list] [--keep-data] [--naive-control]

A store that never opens shows the native store-unavailable window, and nothing else, in hidden instances with no JS
(js: "none"). Each leg has its own data folder and its own launch-switch defaults suite (SOLARA_LAUNCH_SWITCHES_DEFAULTS),
deleted with \`defaults delete\` at the end. The window is read and pressed through the Debug probes storeUnavailable.state
and storeUnavailable.press; failures come from session.json {"version":99} or the Debug seam
SOLARA_TEST_STORE_OPEN_FAIL=openFailed|noFolder|safeOpenFailed.

  refused       an unreadable session.json: Report a Bug, Show Data Folder, Open in Safe Mode and Quit; no browser window,
                no React Native, the engine in safe mode; session.json byte-identical afterwards
  openFailed    the same for a failed open; Show Data Folder records the folder and opens no Finder window in a hidden instance
  earlyWindow   a session a normal launch saved (so it names a launchTab), then the openFailed seam with
                SOLARA_TEST_EARLY_WINDOW_IGNORES_HIDDEN=1 (so a hidden instance still decides): no early window,
                no Chrome window
  noFolder      no data folder: no Show Data Folder and no Open in Safe Mode
  safeMode      Open in Safe Mode: the old pid exits, a new pid from the same bundle path listens on the same DevTools port
                (a Debug relaunch passes it on) and opens the store in safe mode ("requested"), since the relaunch
                carries the one-time SOLARA_SAFE_MODE_REQUEST token; the stored token is consumed, and it is quit explicitly
  report        Report a Bug in a hidden instance: the link is recorded, not copied, and carries no full path beyond
                <data folder>; the log names only the scheme and host
  autoSafeMode  two failing launches, then a third without the seam opens in automatic safe mode with no window over it;
                a launch that fails in safe mode does not offer safe mode again and leaves the counter
  quit          Quit exits within 15 s; the store's files are unchanged and the counter is left as it was
  savesNothingReload
                a normal launch with the JS bundle, the native store frozen through eval, then a JS reload: JS saves
                nothing (no "[documents] attempt" line for session.json, downloads.json, launch-look.json, sync*,
                onboarding.json or release-notes.json from the reload through a graceful quit, after real changes,
                with no safe-mode backstop in the shell) and the store-unavailable window shows in its inert context
  savesNothingRefused
                session.json {"version":99} with SOLARA_TEST_START_RN_WHEN_UNAVAILABLE=1, so React Native starts over a
                store that never opened: the same checks from launch through quit

--naive-control inverts the two savesNothing legs: run them against a bundle whose persist.ts lacks the
startPersistence guard, and each must log at least one attempted write, or the run proves nothing.

Run it with SOLARA_NATIVE_WINDOW_LAYOUT unset and =1: there is no browser window, so both must pass.`;

const args = process.argv.slice(2);
if (args.includes("--list")) {
  console.log(LEGS.join("\n"));
  process.exit(0);
}
if (args.includes("--help") || !args.find((a) => !a.startsWith("--"))) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const [appArg, ...picked] = args.filter((a) => !a.startsWith("--"));
const appPath = resolve(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
for (const leg of picked) assert.ok(LEGS.includes(leg), `unknown leg ${leg} (--list)`);
const legs = picked.length ? picked : LEGS;
const naiveControl = args.includes("--naive-control");
const scratch = mkdtempSync(join(tmpdir(), "ac-store-unavailable-"));
const rep = reporter(join(scratch, "store-unavailable-test.log"), { name: "store-unavailable-test" });
const q = JSON.stringify;
const suites = [];
const running = new Set();

const STORE_FILES = ["session.json", "solara.sqlite", "solara.sqlite-wal", "solara.sqlite-shm", "solara.sqlite.importing", "downloads.json", "session.json.pre-native"];
const storeFiles = (data) => Object.fromEntries(STORE_FILES.map((name) => {
  const file = join(data, name);
  return [name, existsSync(file) ? createHash("sha256").update(readFileSync(file)).digest("hex") : null];
}));
const suiteFor = (leg) => {
  const suite = `solara-store-unavailable-test-${process.pid}-${Date.now()}-${leg}`;
  suites.push(suite);
  return suite;
};
const defaultsRead = (suite, key) => {
  const r = spawnSync("defaults", ["read", suite, key], { encoding: "utf8", timeout: 5000 });
  return r.status === 0 ? r.stdout.trim() : null;
};

const start = async (data, { suite, seam, env = {}, files, fresh = false, js = "none", ready = false } = {}) => {
  const app = await launch(appPath, {
    data, fresh, onboarded: true, js, ready, files,
    env: { ...(suite ? { SOLARA_LAUNCH_SWITCHES_DEFAULTS: suite } : {}), ...(seam ? { SOLARA_TEST_STORE_OPEN_FAIL: seam } : {}), ...env },
  });
  running.add(app);
  rep.log(`launched pid ${app.pid} on ${data}${seam ? ` with ${seam}` : ""}${suite ? `, suite ${suite}` : ""}`);
  return app;
};
const stop = async (app) => {
  const how = await app.quit();
  running.delete(app);
  return how;
};

const readState = (app, timeout = 10000) => app.probe("storeUnavailable.state", {}, { timeout });
const settled = async (app, ms = 60000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await readState(app, Math.max(1000, Math.min(15000, deadline - Date.now())));
      if (last.shown || last.storeOpened) return last;
    } catch (e) {
      if (/exited/.test(e.message)) throw e;
      last = e.message;
    }
    await sleep(200);
  }
  throw new Error(`neither the window nor the store came up within ${ms / 1000} s: ${q(last)}`);
};
const press = (app, button) => app.probe("storeUnavailable.press", { button }, { timeout: 15000 });
const exited = async (pid, ms) => {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (!isAlive(pid)) return true;
  return !isAlive(pid);
};

const onlyTheWindow = (state) => {
  assert.equal(state.shown, true, `the window shows: ${q(state)}`);
  assert.equal(state.storeOpened, false, "the store never opened");
  assert.equal(state.reactNativeStarted, false, "React Native never started");
  assert.equal(state.chromeWindows, 0, `no Chrome window: ${q(state)}`);
  assert.deepEqual(state.otherWindows, [], "no other visible window");
  assert.equal(state.engineSafeMode, true, "the engine runs in safe mode under the window");
  assert.equal(state.isKey, false, "a hidden instance never makes the window key");
};

const leg = (name, fn) => legs.includes(name) ? rep.check(name, fn) : null;

const PROTECTED = /\[documents\] attempt (write|remove) (session\.json|downloads\.json|launch-look\.json|sync\S*|onboarding\.json|release-notes\.json)/g;
const attemptsIn = (text) => [...text.matchAll(PROTECTED)].map((m) => `${m[1]} ${m[2]}`);
const makeChanges = async (app) => {
  const made = await app.eval(`const st = ac.store.getState(); const w = Object.keys(st.windows)[0] ?? st.createWindow({});
    const tabsBefore = Object.keys(ac.store.getState().tabs).length; const appearance = st.settings.appearance === "dark" ? "light" : "dark";
    st.newTab(w, { url: "data:text/html,<title>lost</title>lost" }); st.updateSettings({ appearance });
    const after = ac.store.getState();
    return new Promise((r) => setTimeout(() => r({ tabs: Object.keys(after.tabs).length - tabsBefore, appearance: after.settings.appearance === appearance }), 2500));`, { timeout: 20000 });
  assert.ok(made.tabs >= 1 && made.appearance, `the session took a new tab and an appearance change: ${q(made)}`);
  return true;
};
const judgeAttempts = (attempts, what) => {
  rep.log(`${what}: ${attempts.length} protected attempt(s) ${q(attempts)}`);
  if (naiveControl) assert.ok(attempts.length > 0, `the naive control must attempt a protected write (${what}), or this run proves nothing`);
  else assert.deepEqual(attempts, [], `no protected write or removal is attempted (${what})`);
};
const awaitSavesNothing = async (app, since) => {
  for (const end = Date.now() + 20000; Date.now() < end; await sleep(200)) {
    assert.ok(app.alive, "the instance is still running");
    if (/saves nothing/.test(app.output().slice(since))) return;
  }
  if (!naiveControl) throw new Error("JS never logged that it saves nothing");
};

try {
  await leg("refused", async () => {
    const data = join(scratch, "refused");
    const before = '{"version":99}';
    const app = await start(data, { fresh: true, suite: suiteFor("refused"), files: { "session.json": before } });
    const state = await settled(app);
    rep.log(q(state));
    onlyTheWindow(state);
    assert.equal(state.cause, "refused");
    assert.equal(state.errorType, "ImportRefused");
    assert.deepEqual(state.buttons, ["report", "showFolder", "safeMode", "quit"]);
    await stop(app);
    assert.equal(readFileSync(join(data, "session.json"), "utf8"), before, "session.json is byte-identical");
  });

  await leg("openFailed", async () => {
    const data = join(scratch, "openFailed");
    const app = await start(data, { fresh: true, suite: suiteFor("openFailed"), seam: "openFailed" });
    const state = await settled(app);
    rep.log(q(state));
    onlyTheWindow(state);
    assert.equal(state.cause, "openFailed");
    assert.equal(state.errorType, "StoreOpenTestFailure");
    assert.equal(state.offersSafeMode, true);
    assert.deepEqual(state.buttons, ["report", "showFolder", "safeMode", "quit"]);
    const shown = await press(app, "showFolder");
    assert.equal(realPath(shown.revealedFolder ?? ""), realPath(data), `the folder it would show: ${q(shown)}`);
    assert.match(app.output(), /not showing the data folder in Finder/);
    assert.ok(app.alive, "Show Data Folder keeps the window up");
    await stop(app);
  });

  await leg("earlyWindow", async () => {
    const data = join(scratch, "earlyWindow");
    const first = await start(data, { fresh: true, js: "pinned", ready: "return Object.keys(ac.store.getState().windows).length > 0" });
    await first.eval(`const st = ac.store.getState(); const w = Object.keys(st.windows)[0];
      st.newTab(w, { url: "data:text/html,<title>early</title>early" }); return new Promise((r) => setTimeout(r, 2500));`, { timeout: 15000 });
    await stop(first);
    const saved = JSON.parse(readFileSync(join(data, "session.json"), "utf8"));
    rep.log(`saved session: launchTab ${q(saved.launchTab ?? null)}, focusedWindowId ${q(saved.focusedWindowId ?? null)}, launchBackdrop ${q(saved.launchBackdrop ?? null)}`);
    assert.ok(saved.focusedWindowId, "the normal launch saved a focused window");
    if (!saved.launchTab) {
      const rows = (table) => Array.isArray(table) ? table : Object.values(table ?? {});
      const focused = rows(saved.windows).find((w) => w.id === saved.focusedWindowId);
      const tabId = focused?.activeTabIds?.[focused.profileId] ?? focused?.tabIds?.at(-1);
      const tab = rows(saved.tabs).find((t) => t.id === tabId);
      assert.ok(tab, `a tab in the focused window to name as the launchTab: ${q(focused)}`);
      saved.launchTab = { id: tab.id, url: tab.url, profile: tab.profileId === "default" ? "" : tab.profileId };
      writeFileSync(join(data, "session.json"), JSON.stringify(saved));
      rep.log(`named the launchTab: ${q(saved.launchTab)}`);
    }
    assert.ok(saved.launchTab?.id, "the saved session names a launchTab");
    const savedBefore = storeFiles(data);
    const app = await start(data, { seam: "openFailed", env: { SOLARA_TEST_EARLY_WINDOW_IGNORES_HIDDEN: "1" } });
    const state = await settled(app);
    rep.log(q(state));
    onlyTheWindow(state);
    await sleep(2000);
    const later = await readState(app);
    assert.equal(later.chromeWindows, 0, `still no Chrome window: ${q(later)}`);
    assert.deepEqual(later.otherWindows, [], "still no other window");
    await stop(app);
    assert.deepEqual(storeFiles(data), savedBefore, "the saved session and database are untouched");
  });

  await leg("noFolder", async () => {
    const data = join(scratch, "noFolder");
    const app = await start(data, { fresh: true, suite: suiteFor("noFolder"), seam: "noFolder" });
    const state = await settled(app);
    rep.log(q(state));
    onlyTheWindow(state);
    assert.equal(state.errorType, "NoDataFolder");
    assert.equal(state.offersSafeMode, false);
    assert.deepEqual(state.buttons, ["report", "quit"], "no Show Data Folder and no Open in Safe Mode without a folder");
    await stop(app);
  });

  await leg("safeMode", async () => {
    const data = join(scratch, "safeMode");
    const suite = suiteFor("safeMode");
    const app = await start(data, { fresh: true, suite, seam: "openFailed" });
    const state = await settled(app);
    onlyTheWindow(state);
    assert.ok(state.buttons.includes("safeMode"), q(state.buttons));
    const oldPid = app.pid;
    const port = app.port;
    const pressed = await press(app, "safeMode");
    assert.equal(pressed.pid, oldPid);
    assert.ok(await exited(oldPid, 20000), `the old pid ${oldPid} exits`);
    running.delete(app);
    let pid = null;
    let info = null;
    for (const end = Date.now() + 60000; !pid && Date.now() < end; await sleep(200)) {
      const listeners = listenerPids(port).filter((p) => p !== oldPid);
      if (listeners.length > 1) throw new Error(`port ${port} has ${listeners.length} listeners: ${listeners.join(", ")}`);
      if (listeners.length === 1) {
        info = processInfo(listeners[0]);
        if (info && commandIsBinary(info.command, app.binary)) pid = listeners[0];
      }
    }
    assert.ok(pid, `a relaunched pid on DevTools port ${port}`);
    rep.log(`relaunched: pid ${pid} (${info.command})`);
    uiGateWatch(pid, data);
    Object.assign(app, { pid, started: info.started });
    running.add(app);
    const relaunched = await settled(app);
    rep.log(q(relaunched));
    assert.equal(relaunched.pid, pid);
    assert.equal(relaunched.bundlePath, state.bundlePath, "the same bundle path, never another install");
    assert.equal(relaunched.storeOpened, true, "the store opens");
    assert.equal(relaunched.shown, false, "no unavailable window");
    assert.equal(relaunched.safeMode, true);
    assert.equal(relaunched.safeModeReason, "requested");
    assert.equal(defaultsRead(suite, "SolaraLaunchSwitchSafeModeRequested"), null, "the stored token is consumed");
    const how = await stop(app);
    assert.equal(how.how, "quit", `the relaunched instance quits: ${q(how)}`);
  });

  await leg("report", async () => {
    const data = join(scratch, "report");
    const app = await start(data, { fresh: true, suite: suiteFor("report"), seam: "openFailed" });
    await settled(app);
    const state = await press(app, "report");
    rep.log(q({ ...state, lastReport: state.lastReport ? `${state.lastReport.length} chars` : null }));
    assert.equal(typeof state.lastReport, "string", "a report link");
    assert.equal(state.reportCopied, false, "a hidden instance never touches the pasteboard");
    const link = new URL(state.lastReport);
    assert.equal(`${link.protocol}//${link.host}`, "https://github.com");
    const crash = link.searchParams.get("crash") ?? "";
    rep.log(`crash field:\n${crash}`);
    assert.match(crash, /Cause: openFailed/);
    assert.match(crash, /Error: StoreOpenTestFailure/);
    assert.match(crash, /<data folder>\/solara\.sqlite/);
    assert.doesNotMatch(crash, /second line/, "only the first line of the message");
    const decoded = decodeURIComponent(state.lastReport);
    for (const leak of [data, realPath(data), homedir(), tmpdir(), realPath(tmpdir())])
      assert.ok(!decoded.includes(leak), `the link has no ${leak}`);
    assert.doesNotMatch(decoded, /\/Users\/(?!<user>)/, "no user folder");
    assert.doesNotMatch(decoded, /\/var\/folders|\/private\//, "no temporary folder");
    const log = app.output();
    assert.match(log, /report link ready for https:\/\/github\.com/);
    assert.ok(!log.includes("crash="), "the log never has the link's query");
    assert.match(log, /not copying the report link/);
    await stop(app);
  });

  await leg("autoSafeMode", async () => {
    const data = join(scratch, "autoSafeMode");
    const suite = suiteFor("autoSafeMode");
    for (const [n, fresh] of [[1, true], [2, false]]) {
      const app = await start(data, { fresh, suite, seam: "openFailed" });
      onlyTheWindow(await settled(app));
      await stop(app);
      assert.equal(defaultsRead(suite, "SolaraLaunchSwitchFailedLaunches"), String(n), `failing launch ${n} counts and the window doesn't clear it`);
    }
    const third = await start(data, { suite });
    const opened = await settled(third);
    rep.log(q(opened));
    assert.equal(opened.storeOpened, true, "the third launch opens the store");
    assert.equal(opened.shown, false, "no unavailable window over it");
    assert.equal(opened.safeMode, true);
    assert.equal(opened.safeModeReason, "failedLaunches");
    await stop(third);
    assert.equal(defaultsRead(suite, "SolaraLaunchSwitchFailedLaunches"), null, "a launch that opened clears the counter on quit");
    const failedSafe = await start(data, { suite, seam: "safeOpenFailed", env: { SOLARA_LAUNCH_SWITCHES_OPTION: "1" } });
    const state = await settled(failedSafe);
    rep.log(q(state));
    onlyTheWindow(state);
    assert.equal(state.launchWasSafeMode, true);
    assert.ok(!state.buttons.includes("safeMode"), `no second offer of safe mode: ${q(state.buttons)}`);
    await stop(failedSafe);
    assert.equal(defaultsRead(suite, "SolaraLaunchSwitchFailedLaunches"), "2", "Quit after a failed safe-mode launch leaves the counter");
  });

  await leg("quit", async () => {
    const data = join(scratch, "quit");
    const suite = suiteFor("quit");
    const files = { "session.json": session({ tabs: [{ id: "t1", url: "data:text/html,quit" }] }) };
    const app = await start(data, { fresh: true, suite, seam: "openFailed", files });
    await settled(app);
    const before = storeFiles(data);
    const pid = app.pid;
    const pressed = await press(app, "quit");
    assert.equal(pressed.pressed, "quit");
    const t0 = Date.now();
    assert.ok(await exited(pid, 15000), "Quit exits within 15 s");
    rep.log(`exited in ${Date.now() - t0} ms`);
    running.delete(app);
    assert.ok(app.exited, "nothing is left running");
    assert.deepEqual(storeFiles(data), before, "the store's files are unchanged");
    assert.equal(defaultsRead(suite, "SolaraLaunchSwitchFailedLaunches"), "1", "Quit leaves the failed launch counted");
  });
  await leg("savesNothingReload", async () => {
    const data = join(scratch, "savesNothingReload");
    const app = await start(data, { fresh: true, suite: suiteFor("savesNothingReload"), js: "pinned", ready: "return Object.keys(ac.store.getState().windows).length > 0" });
    await makeChanges(app);
    assert.equal(await app.eval("return globalThis.expo.modules.SolaraStoreAdapter.freeze();"), true, "the native store froze");
    const since = app.output().length;
    await app.eval("globalThis.__savesNothingMarker = true; ac.reload(); return true;");
    let reloaded = false;
    for (const end = Date.now() + 20000; !reloaded && Date.now() < end; await sleep(100)) {
      assert.ok(app.alive, "the reload exited the instance");
      reloaded = await app.eval("return globalThis.__savesNothingMarker === undefined && !!globalThis.ac?.store;", { timeout: 1000 }).catch(() => false);
    }
    assert.ok(reloaded, "the reload replaced the JavaScript runtime");
    await awaitSavesNothing(app, since);
    if (!naiveControl) {
      const state = await readState(app);
      rep.log(q(state));
      assert.equal(state.shown, true, "the store-unavailable window shows over the reloaded session");
      assert.equal(state.context, "inert");
      assert.deepEqual(state.buttons, ["report", "showFolder", "quit"], "no Open in Safe Mode in a running session");
      assert.equal(state.engineSafeMode, false, "no safe-mode backstop in the shell for this leg");
    }
    await makeChanges(app);
    const how = await stop(app);
    assert.equal(how.how, "quit", `a graceful quit: ${q(how)}`);
    judgeAttempts(attemptsIn(app.output().slice(since)), "from the reload through quit");
  });

  await leg("savesNothingRefused", async () => {
    const data = join(scratch, "savesNothingRefused");
    const before = '{"version":99}';
    const app = await start(data, {
      fresh: true, suite: suiteFor("savesNothingRefused"), files: { "session.json": before },
      js: "pinned", ready: "return !!globalThis.ac?.store", env: { SOLARA_TEST_START_RN_WHEN_UNAVAILABLE: "1" },
    });
    await awaitSavesNothing(app, 0);
    if (!naiveControl) {
      const state = await readState(app);
      rep.log(q(state));
      assert.equal(state.reactNativeStarted, true, "the seam started React Native");
      assert.equal(state.storeOpened, false);
      assert.equal(state.context, "inert");
    }
    assert.equal(await makeChanges(app), true, "the session took real changes");
    const how = await stop(app);
    assert.equal(how.how, "quit", `a graceful quit: ${q(how)}`);
    judgeAttempts(attemptsIn(app.output()), "from launch through quit");
    if (!naiveControl) assert.equal(readFileSync(join(data, "session.json"), "utf8"), before, "session.json is byte-identical");
  });
} finally {
  for (const app of [...running]) {
    try { await app.quit(); } catch (e) { process.stderr.write(`couldn't quit pid ${app.pid}: ${e.message}\n`); }
  }
  for (const suite of suites) spawnSync("defaults", ["delete", suite], { stdio: "ignore", timeout: 5000 });
}
process.exit(rep.summary() ? 0 : 1);
