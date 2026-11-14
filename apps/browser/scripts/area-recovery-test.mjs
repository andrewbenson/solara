import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = "node apps/browser/scripts/area-recovery-test.mjs <Debug Solara.app> <scratch dir>";
const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) { console.log(HELP); process.exit(0); }
assert.equal(args.length, 2, HELP);
const appPath = resolve(args[0]);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const scratch = resolve(args[1]);
const data = join(scratch, "data");
const captures = join(scratch, "captures");
mkdirSync(captures, { recursive: true });
const rep = reporter(join(scratch, "area-recovery-test.log"), { name: "area-recovery-test" });
process.env.AC_UITEST_WAIT ??= "0";
let app;
let launching;
let failed = false;
let cleanup;
let deadline;
const clean = () => cleanup ??= (async () => {
  const owned = app ?? await launching?.catch(() => null);
  if (owned) await owned.quit({ graceful: false });
})();
const stop = async (code, reason) => {
  console.error(reason);
  try { await Promise.race([clean(), sleep(20_000).then(() => { throw new Error("cleanup deadline"); })]); }
  finally { clearTimeout(deadline); process.exit(code); }
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) process.once(signal, () => void stop(code, `area-recovery-test received ${signal}`));
deadline = setTimeout(() => void stop(1, "area-recovery-test exceeded 100 seconds"), 100_000);
const run = body => app.eval(body, { timeout: 5000 });
const drive = action => run(`return globalThis.expo.modules.SolaraHosted.devAreaRecovery("w1", ${JSON.stringify(action)}).then(JSON.parse);`);
const until = async (name, sample, accept, ms = 7000) => {
  const end = Date.now() + ms;
  let last;
  do {
    assert.ok(app.stillOwned(), `instance exited while waiting for ${name}`);
    last = await sample();
    if (accept(last)) return last;
    await sleep(80);
  } while (Date.now() < end);
  throw new Error(`${name}: ${JSON.stringify(last)}`);
};
const check = async (name, body) => { if (!await rep.check(name, body)) throw new Error(`stopping after ${name}`); };
try {
  launching = launch(appPath, { data, ready: false, startTimeout: 20_000, fresh: true, onboarded: true, probe: true, files: { "bench-offline": "" }, session: session({ profiles: ["Personal"], windows: [{ id: "w1", profileId: "default", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } }], tabs: [{ id: "a", windowId: "w1", url: "about:blank", title: "Recovery fixture" }], settings: { appearance: "dark", searchSuggestions: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false } }) });
  app = await launching;
  await app.ready({ timeout: 20_000, test: "return !!globalThis.acAreaRecovery && !!globalThis.expo.modules.SolaraHosted.devAreaRecovery;" });
  for (const [area, plain, action] of [["window", false, "Space"], ["window", true, "press"], ["window", false, "Return"], ["window", true, "Enter"], ["sidebar", false, "press"], ["sidebar", true, "Return"]]) {
    await check(`${area} ${plain ? "plain" : "themed"} exhausted recovery reloads through ${action}`, async () => {
      await until(`${area} boundary mounted`, () => run("return globalThis.acAreaRecovery.boundaries();"), value => value.some(boundary => boundary.area === area && boundary.windowId === "w1"));
      assert.equal(await run(`return globalThis.acAreaRecovery.fail(${JSON.stringify(area)}, "w1", ${plain});`), 1);
      const state = await until("native exhausted recovery", () => drive("state"), value => value.found && value.plain === plain);
      const boundaries = await run("return globalThis.acAreaRecovery.boundaries();");
      assert.equal(boundaries.find(boundary => boundary.area === area && boundary.windowId === "w1").retries, 2);
      assert.equal(state.label, "Reload");
      assert.equal(state.role, "AXButton");
      assert.equal(state.canFocus, true);
      assert.equal(state.firstMouse, true);
      assert.equal(state.fill, area === "window");
      assert.equal(state.detail, plain ? "" : "Forced area recovery fixture\n\nAreaRecoveryFixture");
      const name = `${area}-${plain ? "plain" : "themed"}-${action}`;
      assert.equal(await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(join(captures, `${name}.png`))});`), true);
      writeFileSync(join(captures, `${name}.json`), JSON.stringify({ state, boundaries }, null, 2));
      assert.equal((await drive(action)).accepted, true);
      await until("recovered window", () => drive("state"), value => !value.found);
      const after = await run("return globalThis.acAreaRecovery.boundaries();");
      const boundary = after.find(boundary => boundary.area === area && boundary.windowId === "w1");
      assert.equal(boundary.failed, false);
      assert.equal(boundary.retries, 0);
      return { state, boundary };
    });
  }
  await check("quiet pane retries exhaust without drawing a recovery row", async () => {
    const before = await until("quiet pane boundary mounted", () => run("return globalThis.acAreaRecovery.boundaries();"), value => value.some(boundary => boundary.area === "pane" && boundary.quiet));
    const pane = before.find(boundary => boundary.area === "pane" && boundary.quiet);
    assert.ok(await run(`return globalThis.acAreaRecovery.fail("pane", ${JSON.stringify(pane.windowId)});`) > 0);
    const exhausted = await until("quiet retries exhausted", () => run("return globalThis.acAreaRecovery.boundaries();"), value => value.some(boundary => boundary.area === "pane" && boundary.quiet && boundary.failed && boundary.retries === 2));
    assert.equal((await drive("state")).found, false);
    assert.equal(await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(join(captures, "quiet-pane.png"))});`), true);
    assert.ok(await run(`return globalThis.acAreaRecovery.recover("pane", ${JSON.stringify(pane.windowId)});`) > 0);
    await until("quiet pane restored", () => run("return globalThis.acAreaRecovery.boundaries();"), value => value.some(boundary => boundary.area === "pane" && boundary.quiet && !boundary.failed && boundary.retries === 0));
    return exhausted;
  });
  await check("only forced fixture errors were recorded", async () => {
    const errors = readFileSync(join(data, "js-errors.log"), "utf8");
    assert.match(errors, /Forced area recovery fixture/);
    const entries = errors.split(/(?=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z (?:render|error|fatal))/).filter(Boolean);
    for (const entry of entries) assert.match(entry, /Forced area recovery (?:fixture|theme failure)/);
    writeFileSync(join(scratch, "expected-fixture-errors.log"), errors);
    writeFileSync(join(data, "js-errors.log"), "");
    return { entries: entries.length };
  });
} catch (error) {
  failed = true;
  rep.record("area-recovery-test aborted", { error });
} finally {
  try { await clean(); } catch (error) { failed = true; rep.record("cleanup", { error }); }
  clearTimeout(deadline);
}
console.log(`evidence: ${scratch}`);
process.exitCode = failed ? 1 : 0;
