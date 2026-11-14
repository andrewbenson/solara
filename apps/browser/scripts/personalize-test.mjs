import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = "node apps/browser/scripts/personalize-test.mjs <Debug Solara.app> [--keep-data]";
const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) { console.log(HELP); process.exit(0); }
const appArg = args.find(value => !value.startsWith("--"));
assert.ok(appArg && args.every(value => !value.startsWith("--") || value === "--keep-data"), HELP);
const appPath = resolve(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
process.env.AC_UITEST_WAIT ??= "0";
if (args.includes("--keep-data")) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-personalize-"));
const data = join(scratch, "data");
const captures = join(scratch, "captures");
mkdirSync(captures);
const rep = reporter(join(scratch, "personalize-test.log"), { name: "personalize-test" });
let app;
let launching;
let failed = false;
let stopping = false;
let cleanup;
let deadline;
const clean = () => cleanup ??= (async () => {
  const teardownDeadline = setTimeout(() => {
    rep.record("cleanup deadline", { error: new Error("personalize-test cleanup exceeded 45 seconds") });
    process.exit(1);
  }, 45_000);
  try {
    const owned = app ?? await launching?.catch(() => null);
    if (owned) await owned.quit({ graceful: false });
  } finally {
    clearTimeout(teardownDeadline);
    clearTimeout(deadline);
  }
})();
const stop = async (code, reason) => {
  stopping = true;
  failed = true;
  process.exitCode = code;
  console.error(reason);
  try { await clean(); } catch (error) { rep.record("cleanup", { error }); }
  process.exit(code);
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
  process.once(signal, () => void stop(code, `personalize-test received ${signal}`));
}
deadline = setTimeout(() => void stop(1, "personalize-test exceeded 110 seconds"), 110_000);
const run = (body) => {
  assert.ok(!stopping, "test is stopping");
  return app.eval(body, { timeout: 5000 });
};
const drive = (windowId, action = "state", argument = null) => run(`return globalThis.expo.modules.SolaraHosted.devPersonalize(${JSON.stringify(windowId)}, ${JSON.stringify(action)}, ${JSON.stringify(argument)}).then(JSON.parse);`);
const until = async (name, sample, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  do {
    if (!app.stillOwned()) throw new Error(`instance exited while waiting for ${name}`);
    last = await sample();
    if (accept(last)) return last;
    await sleep(80);
  } while (Date.now() < end);
  throw new Error(`${name}: ${JSON.stringify(last)}`);
};
const check = async (name, body) => { if (!await rep.check(name, body)) throw new Error(`stopping after ${name}`); };
const capture = async (name, windowId = "w1") => {
  const path = join(captures, `${name}.png`);
  assert.equal(await run(`return ac.shell.devSnapshotWindow(${JSON.stringify(windowId)}, ${JSON.stringify(path)});`), true);
  writeFileSync(join(captures, `${name}.json`), JSON.stringify(await drive(windowId), null, 2));
  return path;
};
try {
  launching = launch(appPath, { data, ready: false, startTimeout: 20_000, fresh: true, onboarded: true, probe: true, files: { "bench-offline": "" }, session: session({
    profiles: ["Personal", "Work"],
    windows: [
      { id: "w1", profileId: "default", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } },
      { id: "w2", profileId: "work", frame: [100, 100, 1100, 800], activeTabIds: { work: "b" } },
    ],
    tabs: [{ id: "a", windowId: "w1", url: "", title: "" }, { id: "b", windowId: "w2", url: "", title: "" }],
    settings: { appearance: "dark", newTabOpens: "page", addressBar: "toolbar", searchSuggestions: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
  }), env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_NEWTAB: "1" } });
  app = await launching;
  assert.ok(!stopping, "launch interrupted");
  await app.ready({ timeout: 20_000, test: "return !!globalThis.expo.modules.SolaraHosted.devPersonalize && !!ac.store.getState().windows.w2;" });
  await until("first host mounted", () => drive("w1"), value => value?.button?.length === 4);
  await check("the native control opens by Space after explicit keyboard focus", async () => {
    const before = await app.snapshot();
    assert.equal((await drive("w1")).open, false);
    await capture("closed");
    await drive("w1", "key", "Personalize|Space");
    const state = await until("panel open", () => drive("w1"), value => value.open && value.panel);
    assert.ok(state.controls.some(control => control.label === "Sidebar"));
    assert.ok(state.controls.some(control => control.label === "Classic"));
    await sleep(500);
    await capture("open-dark");
    return { responderBefore: before.windows.find(window => window.id === "w1")?.firstResponder, panel: state.panel };
  });
  await check("theme and layout choices use their existing actions and keep the panel open", async () => {
    const other = await run('return ac.store.getState().profiles.work.color;');
    await drive("w1", "press", "Blue");
    await until("profile blue", () => run('return ac.store.getState().profiles.default.color;'), value => value === "blue");
    const initial = (await drive("w1")).layout;
    const next = initial === "sidebar" ? "top" : "sidebar";
    await drive("w1", "key", `${next === "top" ? "Classic" : "Sidebar"}|Return`);
    await until("layout applied", () => drive("w1"), value => value.layout === next && value.open);
    const before = await run('return ac.store.getState().windows.w1.tabLayout;');
    await drive("w1", "press", next === "top" ? "Classic" : "Sidebar");
    assert.equal(await run('return ac.store.getState().windows.w1.tabLayout;'), before);
    assert.equal(await run('return ac.store.getState().profiles.work.color;'), other);
    await capture("chosen-dark");
    return { color: "blue", layout: next, otherColor: other };
  });
  await check("Return and VoiceOver press toggle the panel, only one window stays open", async () => {
    await drive("w1", "key", "Personalize|Return");
    await until("closed by Return", () => drive("w1"), value => !value.open);
    await drive("w1", "press", "Personalize");
    await until("opened by AX", () => drive("w1"), value => value.open);
    await drive("w2", "press", "Personalize");
    await until("other window open", () => drive("w2"), value => value.open);
    assert.equal((await drive("w1")).open, false);
    await drive("w2", "close");
    await until("other panel dismissed", () => drive("w2"), value => !value.open);
    return true;
  });
  await check("light appearance updates the native panel and unmount never reopens it", async () => {
    await run('ac.store.getState().updateSettings({ appearance: "light" }); return true;');
    await drive("w1", "press", "Personalize");
    await until("light panel open", () => drive("w1"), value => value.open && value.dark === false);
    await sleep(500);
    await capture("open-light");
    await run('ac.store.getState().navigate("a", "about:blank"); return true;');
    await until("host removed", () => drive("w1"), value => !value || value.active === false || value.found === false);
    await run('return ac.store.getState().newTab("w1");');
    await until("closed host remounted", () => drive("w1"), value => value?.button && value.open === false);
    return true;
  });
} catch (error) {
  failed = true;
  rep.record("personalize-test aborted", { error });
} finally {
  try { await clean(); } catch (error) { failed = true; rep.record("cleanup", { error }); }
  clearTimeout(deadline);
}
console.log(`evidence: ${scratch}`);
process.exitCode = failed ? 1 : 0;
