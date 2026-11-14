#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = "node apps/browser/scripts/group-panel-test.mjs <Debug Solara.app> <scratch dir> [--shell=0|1]";
const args = process.argv.slice(2);
if (args.includes("--help")) { console.log(HELP); process.exit(0); }
const positional = args.filter(arg => !arg.startsWith("--"));
assert.equal(positional.length, 2, HELP);
const appPath = resolve(positional[0]);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const scratch = resolve(positional[1]);
const shell = args.includes("--shell=1");
mkdirSync(scratch, { recursive: true });
const rep = reporter(join(scratch, "group-panel-test.log"), { name: "group-panel-test" });
process.env.AC_UITEST_WAIT ??= "120";
let app;
let launching;
let cleanup;
const clean = () => cleanup ??= (async () => { const owned = app ?? await launching?.catch(() => null); if (owned) await owned.quit(); })();
const stop = async code => { try { await Promise.race([clean(), sleep(20_000)]); } finally { process.exit(code); } };
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) process.once(signal, () => void stop(code));
const deadline = setTimeout(() => { console.error("group-panel-test exceeded 540 seconds"); void stop(1); }, 540_000);
const run = body => app.eval(body, { timeout: 8000 });
const until = async (name, sample, accept, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  do {
    assert.ok(app.stillOwned(), `instance exited waiting for ${name}`);
    last = await sample();
    if (accept(last)) return last;
    await sleep(60);
  } while (Date.now() < end);
  throw new Error(`${name}: ${JSON.stringify(last)}`);
};
const state = () => run(shell ? 'return globalThis.expo.modules.SolaraHosted.sidebarHoverCard("w1").then(JSON.parse);' : 'return globalThis.expo.modules.SolaraHosted.devGroupPanel("w1", "state", null).then(JSON.parse);');
const capture = async name => {
  assert.equal(await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(join(scratch, `${name}.png`))});`), true);
  writeFileSync(join(scratch, `${name}.json`), JSON.stringify(await state(), null, 2));
};
const check = async (name, body) => { assert.ok(await rep.check(name, body), name); };
try {
  launching = launch(appPath, { data: join(scratch, "data"), startTimeout: 20_000, fresh: true, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: shell ? "1" : "0" }, files: { "bench-offline": "" },
    session: session({ profiles: ["Personal"], windows: [{ id: "w1", profileId: "default", frame: [80, 80, 1100, 800], tabIds: ["a", "b", "c"], activeTabIds: { default: "a" } }],
      tabs: [{ id: "a", url: "about:blank", title: "Alpha", lastActiveAt: 1730000000000 }, { id: "b", url: "about:blank", title: "Bravo", lastActiveAt: 1729999940000 }, { id: "c", url: "about:blank", title: "Charlie", lastActiveAt: 1729999880000 }],
      settings: { appearance: "dark", searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } }) });
  app = await launching;
  await app.ready({ timeout: 20_000, test: 'return !!ac.store && !!globalThis.expo.modules.SolaraHosted.devGroupPanel;' });
  await run('const s = ac.store.getState(); const group = s.createGroup(["a", "b", "c"], { name: "Group" }); ac.store.getState().updateGroup(group, { collapsed: true }); globalThis.groupFixtureId = group; return true;');
  const show = () => run('ac.sidebarRows.setSidebarUi({ hover: { kind: "group", id: groupFixtureId, windowId: "w1", anchor: { x: 8, y: 160, width: 184, height: 34 } } }); return true;');
  await check(`shell ${shell ? "on" : "off"} draws a native group card with no RN body`, async () => {
    await show();
    const current = await until("native group", state, value => value && (shell ? value.phase === "shown" && value.kind === "group" : value.found));
    assert.deepEqual([...current.rows].sort(), ["a", "b", "c"]);
    assert.equal(current.frame[2], 264);
    assert.ok(Math.abs(current.frame[3] - 194.5) <= 0.5);
    assert.equal(await run('return acPerf.findFibers("PanelRow", 10).length;'), 0);
    if (!shell) { assert.equal(current.searchLabel, "Search Tabs"); assert.equal(current.firstMouse, false); }
    await capture("all");
    if (!shell) {
      for (const [name, query] of [["filtered", "Bravo"], ["empty", "Missing"]]) {
        await run(`return globalThis.expo.modules.SolaraHosted.devGroupPanel("w1", "query", ${JSON.stringify(query)});`);
        await capture(name);
      }
      await run('return globalThis.expo.modules.SolaraHosted.devGroupPanel("w1", "query", "");');
    }
  });
  await check("pointer entry focuses search, typing filters, and Return chooses the matching tab", async () => {
    const [x, y, width] = (await state()).frame;
    await run(`return ac.shell.devSetPointer("w1", { x: ${x + width / 2}, y: ${y + 20} });`);
    await until("search focus", state, value => value.typingInCard);
    await run('return ac.shell.devTypeKeys("w1", "Bravo", 10);');
    const filtered = await until("one matching row", state, value => Object.keys(value.buttons ?? {}).length === 1);
    assert.deepEqual(Object.keys(filtered.buttons), ["Bravo"]);
    if (shell) await capture("filtered");
    await run(`return ac.shell.devTypeKeys("w1", ${JSON.stringify("\r")}, 10);`);
    await until("selected tab", () => run('return ac.store.getState().windows.w1.activeTabIds.default;'), value => value === "b");
    await until("closed after choose", () => run('return ac.sidebarRows.useSidebarUi.getState().hover;'), value => value === null);
  });
  await check("a native row action selects its tab", async () => {
    await run('return ac.shell.devSetPointer("w1", { x: 900, y: 600 });');
    await until("previous group finished closing", state, value => shell ? value?.phase === "hidden" : !value?.found);
    await run('ac.sidebarHover.dismissHover(); const group = ac.store.getState().createGroup(["a", "b", "c"], { name: "Another group" }); ac.store.getState().updateGroup(group, { collapsed: true }); globalThis.groupFixtureId = group; ac.sidebarHover.holdHover(true); return true;');
    await show();
    await until("reopened group", state, value => value && (shell ? value.phase === "shown" : value.found));
    if (shell) {
      const [x, y, width, height] = (await state()).buttons.Charlie;
      await run(`return ac.shell.devClick("w1", { x: ${x + width / 2}, y: ${y + height / 2} });`);
    } else {
      await run('return globalThis.expo.modules.SolaraHosted.devGroupPanel("w1", "press", "Charlie");');
    }
    await until("Charlie selected", () => run('return ac.store.getState().windows.w1.activeTabIds.default;'), value => value === "c");
  });
} finally {
  clearTimeout(deadline);
  await clean();
}
assert.ok(rep.results.every(result => result.ok));
