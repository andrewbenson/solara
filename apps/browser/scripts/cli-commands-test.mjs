import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { frontApp, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((arg) => !arg.startsWith("--"));
if (!appArg) {
  console.error("usage: node cli-commands-test.mjs <Solara.dev app> --scratch=/absolute/path [--python=/path/to/python] [--bundle=/absolute/main.jsbundle] [--keep-data]\n\nExercises terminal inventories, filters, find/history, background open and explicit unsupported-action refusals in a hidden token-control fixture.");
  process.exit(2);
}
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const python = args.find((arg) => arg.startsWith("--python="))?.slice(9) || "python3";
const scratchRoot = args.find((arg) => arg.startsWith("--scratch="))?.slice(10);
assert.ok(scratchRoot && isAbsolute(scratchRoot), "--scratch must be an absolute path");
const bundlePath = args.find((arg) => arg.startsWith("--bundle="))?.slice(9);
assert.ok(bundlePath === undefined || isAbsolute(bundlePath), "--bundle must be an absolute path");
const bundledJs = bundlePath === undefined ? null : readFileSync(bundlePath);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(resolve(appArg), "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
const release = existsSync(join(resolve(appArg), "Contents/Resources/main.jsbundle"));
mkdirSync(scratchRoot, { recursive: true });
const scratch = mkdtempSync(join(scratchRoot, "cli-commands-"));
const data = join(scratch, "data");
const keep = args.includes("--keep-data");
process.env.TMPDIR = scratch;
if (keep) process.env.AC_KEEP_DATA = "1";
const rep = reporter(join(scratch, "cli-commands-test.log"), { name: "cli-commands-test" });
const execute = promisify(execFile);
const deadline = Date.now() + 480_000;
let app;
const server = createServer((req, res) => {
  const path = new URL(req.url, "http://fixture.test").pathname;
  if (bundledJs && ["/status", "/index.bundle"].includes(path)) {
    res.writeHead(200, { "content-type": path === "/status" ? "text/plain" : "application/javascript" });
    res.end(path === "/status" ? "packager-status:running" : bundledJs);
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
  res.end(`<!doctype html><title>CLI fixture ${path.slice(1)}</title><link rel="icon" href="data:,"><h1>CLI fixture ${path.slice(1)}</h1>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  profiles: ["Personal", "Work"],
  windows: [{ id: "w1", activeTabIds: { default: "a" } }, { id: "w2", profileId: "work", activeTabIds: { work: "work-tab" } }, { id: "w3", activeTabIds: { default: "z" } }],
  tabs: [
    { id: "a", url: url("alpha"), title: "CLI fixture alpha" },
    { id: "duplicate", url: url("alpha"), title: "CLI fixture duplicate" },
    { id: "pin", url: url("pinned"), pinned: true, pinnedUrl: url("pinned"), title: "CLI fixture pinned" },
    { id: "work-tab", windowId: "w2", profileId: "work", url: url("work"), title: "CLI fixture work" },
    { id: "z", windowId: "w3", url: url("third"), title: "CLI fixture third" },
  ],
  settings: { cliControl: true },
});
const invoke = async (words, { json = true, code = 0 } = {}) => {
  assert.ok(!app || app.alive, "Solara instance exited");
  const remaining = deadline - Date.now();
  assert.ok(remaining > 0, "CLI e2e exceeded its eight-minute deadline");
  let result;
  try {
    result = await execute(python, ["-B", "-m", "solara_cli", ...words, "--data-dir", data, ...(json ? ["--json"] : [])], {
      cwd: root,
      env: { ...process.env, PYTHONPATH: join(root, "apps/cli"), PYTHONDONTWRITEBYTECODE: "1", SOLARA_CDP_URL: "", SOLARA_DATA_DIR: data, TMPDIR: scratch },
      timeout: Math.min(20_000, remaining),
      maxBuffer: 4 * 1024 * 1024,
    });
    result.code = 0;
  } catch (error) { result = error; }
  assert.equal(result.code, code, `${words.join(" ")}: ${result.stderr || result.message || result.stdout}`);
  if (code !== 0) {
    assert.equal(result.stdout, "", "refusal wrote a success result");
    assert.ok(result.stderr.trim(), "refusal must explain its reason");
    assert.doesNotMatch(result.stderr, /Traceback|KeyError|AttributeError/);
    return result.stderr;
  }
  assert.equal(result.stderr, "", words.join(" "));
  return json ? JSON.parse(result.stdout) : result.stdout;
};
const poll = async (read, accepts, what, milliseconds = 10_000) => {
  const end = Math.min(deadline, Date.now() + milliseconds);
  let last;
  while (Date.now() < end) {
    assert.ok(app.alive, "Solara instance exited");
    last = await read();
    if (accepts(last)) return last;
    await sleep(150);
  }
  throw new Error(`${what} did not settle: ${JSON.stringify(last)}`);
};
const state = () => app.eval('const s = ac.store.getState(); return { windows: Object.values(s.windows).map(({ id, profileId, tabIds, activeTabIds }) => ({ id, profileId, tabIds, activeTabIds })), tabs: Object.values(s.tabs).map(({ id, windowId, profileId, url, muted, pinned, customTitle, unloaded }) => ({ id, windowId, profileId, url, muted, pinned, customTitle, unloaded })), groups: s.groups };');
try {
  app = await launch(resolve(appArg), { data, control: true, session: fixture, onboarded: true, keepData: true, probe: true, metroPort: Number(process.env.METRO_PORT ?? 8081), ...(release && !bundledJs ? { js: "none" } : {}), ...(bundledJs ? { js: `127.0.0.1:${server.address().port}` } : {}), env: { TMPDIR: scratch } });
  rep.log(`instance pid ${app.pid}; data ${data}`);
  await rep.check("inventories return canonical sidebar IDs and filter profiles/windows", async () => {
    const profiles = await invoke(["profiles"]);
    assert.deepEqual(new Set(profiles.map((row) => row.id)), new Set(["default", "work"]));
    const windows = await invoke(["windows", "--profile", "Work"]);
    assert.deepEqual(windows.map((row) => row.id), ["w2"]);
    const rows = await invoke(["tabs"]);
    for (const row of fixture.tabs) assert.ok(rows.some((actual) => actual.id === row.id));
    assert.ok(rows.every((row) => typeof row.id === "string"));
    const thirdWindow = await invoke(["tabs", "--window", "w3"]);
    assert.ok(thirdWindow.some((row) => row.id === "z"));
    assert.ok(thirdWindow.every((row) => row.windowId === "w3"));
    const workTabs = await invoke(["tabs", "--profile", "work"]);
    assert.ok(workTabs.some((row) => row.id === "work-tab"));
    assert.ok(workTabs.every((row) => row.profileId === "work"));
    const grouped = await invoke(["group", "create", "CLI group", "--tabs", "a", "duplicate"]);
    assert.deepEqual(new Set((await invoke(["tabs", "--group", grouped.id, "--window", "w1"])).map((row) => row.id)), new Set(["a", "duplicate"]));
    assert.match(await invoke(["tabs", "--group", "missing"], { code: 1 }), /missing|ambiguous|group/i);
    for (const flag of ["--awake", "--asleep"]) assert.match(await invoke(["tabs", flag], { code: 1 }), /requires|mapping|canonical/i);
    const memory = await invoke(["tabs", "--memory"]);
    assert.ok(memory.some((row) => row.url === url("alpha") && row.targetId));
    assert.match(await invoke(["tabs"], { json: false }), /a|alpha/);
  });
  await rep.check("find combines selected sources and history respects profiles", async () => {
    const tabs = await invoke(["find", "alpha", "--tabs"]);
    assert.ok(tabs.some((row) => row.id === "a"));
    assert.ok(tabs.every((row) => row.source === "tab"));
    const pins = await invoke(["find", "pinned", "--pins"]);
    assert.ok(pins.some((row) => row.url === url("pinned") && row.source === "pin"));
    const history = await poll(() => invoke(["history", "--days", "1", "--limit", "500"]), (rows) => rows.some((row) => row.profile === "Personal" && row.url === url("alpha")) && rows.some((row) => row.profile === "Work" && row.url === url("work")), "fixture history", 45_000);
    assert.ok(history.length <= 500);
    const scoped = await invoke(["history", "work", "--profile", "Work", "--limit", "500"]);
    assert.ok(scoped.length && scoped.every((row) => row.profile === "Work"));
    const domains = await invoke(["history", "--domains", "--profile", "work"]);
    assert.ok(domains.some((row) => row.domain === "127.0.0.1" && row.visits > 0));
    const found = await invoke(["find", "work", "--history", "--profile", "Work"]);
    assert.ok(found.length && found.every((row) => row.source === "history" && row.profile === "Work"));
  });
  await rep.check("background open succeeds and unsupported destinations are refused", async () => {
    const selection = () => app.eval('const s = ac.store.getState(); return { focusedWindowId: s.focusedWindowId, windows: Object.values(s.windows).map(({ id, profileId, activeTabIds }) => ({ id, profileId, activeTabIds })) };');
    const selectedBefore = await selection();
    const opened = await invoke(["open", url("opened")]);
    assert.equal(typeof opened.targetId, "string");
    assert.equal(opened.background, true);
    await poll(() => invoke(["tabs"]), (rows) => rows.some((row) => row.url === url("opened")), "opened canonical tab");
    assert.deepEqual(await selection(), selectedBefore, "background open changed the selected tab or profile");
    assert.notEqual(frontApp()?.pid, app.pid, "hidden instance became frontmost");
    const before = await state();
    for (const flags of [["--profile", "Work"], ["--window", "w3"]]) {
      assert.match(await invoke(["open", url("forbidden"), ...flags], { code: 1 }), /unsupported|cannot|unavailable|support|select/i);
      assert.deepEqual(await state(), before);
    }
  });
  await rep.check("canonical actions fail clearly when the app lacks a safe target join", async () => {
    for (const action of ["activate", "close", "reload", "duplicate", "mute", "sleep"]) {
      const before = await state();
      const error = await invoke(["tab", action, "a"], { code: 1 });
      assert.match(error, /requires|unsupported|cannot|unavailable|support|mapping|target|join|focus/i);
      assert.deepEqual(await state(), before, `${action} refusal mutated sidebar state`);
    }
  });
  await rep.check("bulk cleanup previews are inert and unsafe apply is refused", async () => {
    const before = await state();
    const preview = await invoke(["tab", "close-duplicates", "--window", "w3", "--dry-run"]);
    assert.equal(preview.dryRun, true);
    assert.deepEqual(await state(), before);
    assert.deepEqual(preview.ids, []);
    assert.match(await invoke(["tab", "close-duplicates", "--dry-run"], { code: 1 }), /requires|unsupported|mapping|target|join/i);
    assert.match(await invoke(["tab", "close-duplicates"], { code: 1 }), /requires|unsupported|cannot|unavailable|support|mapping|target|join|focus/i);
    assert.deepEqual(await state(), before);
    assert.match(await invoke(["tab", "sleep-idle", "--minutes", "30"], { code: 1 }), /requires|unsupported|cannot|unavailable|support|idle/i);
    assert.deepEqual(await state(), before);
  });
  await rep.check("private profile/window/tab IDs stay absent from convenience listings", async () => {
    const privateState = await app.eval(`const s = ac.store.getState(); const windowId = s.createWindow({ incognito: true, profileId: "default", url: ${JSON.stringify(url("private"))} }); const w = ac.store.getState().windows[windowId]; return { windowId, profileId: w.profileId, tabId: w.tabIds[0] };`);
    assert.ok(privateState.tabId);
    assert.ok(!(await invoke(["profiles"])).some((row) => row.id === privateState.profileId));
    assert.ok(!(await invoke(["windows"])).some((row) => row.id === privateState.windowId));
    assert.ok(!(await invoke(["tabs"])).some((row) => row.id === privateState.tabId));
    assert.ok(!(await invoke(["find", "private", "--tabs"])).some((row) => row.url === url("private")));
  });
  await rep.check("Settings revocation prevents all convenience reads and actions", async () => {
    await app.eval('ac.store.getState().updateSettings({ cliControl: false }); return true;');
    await poll(async () => existsSync(join(data, "Chromium", "SolaraControl.json")), (exists) => !exists, "control file removal", 5000);
    for (const words of [["profiles"], ["windows"], ["tabs"], ["find", "alpha"], ["history"], ["open", url("forbidden")], ["tab", "close", "a"]]) {
      await invoke(words, { code: 2 });
    }
  });
} finally {
  try { await app?.quit(); }
  finally {
    server.closeAllConnections();
    await new Promise((done) => server.close(done));
  }
  if (!keep && !rep.failed.length) rmSync(data, { recursive: true, force: true });
  rep.say(`scratch: ${scratch}`);
}
process.exit(rep.summary() ? 0 : 1);
