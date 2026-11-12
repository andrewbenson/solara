import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { attach, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg, ...options] = process.argv.slice(2);
if (!appArg || !scratchArg) {
  console.error("usage: node tab-number-hints-test.mjs <Debug Solara.app> <scratch directory> [--attach] [--fixture-only]");
  process.exit(2);
}
const scratch = resolve(scratchArg);
const data = join(scratch, "data");
const output = join(scratch, "snapshots");
mkdirSync(output, { recursive: true });
const names = ["tile", "row", "group-a", "group-b", "split-a", "split-b", "list1", "list2", "list3", "list4", "list5", "list6", "list7", "last"];
const fixture = session({
  settings: { sidebarWidth: 260, appearance: "light", warnBeforeQuitting: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, showTabNumberHints: true },
  windows: [{ id: "w1", frame: [80, 80, 1700, 1000], activeTabIds: { default: "list1" } }],
  tabs: names.map((id) => ({ id, title: id, customTitle: id, url: "about:blank", pinned: ["tile", "row"].includes(id), pinnedAsRow: id === "row", lastActiveAt: id === "split-b" ? 50 : 1 })),
  groups: [{ id: "group", name: "Numbered group", windowId: "w1", profileId: "default", collapsed: false, pinned: true, tabIds: ["group-a", "group-b"], createdAt: 1 }],
  splits: [{ id: "split", windowId: "w1", tabIds: ["split-a", "split-b"], orientation: "horizontal", sizes: [0.5, 0.5] }],
});
const fixturePath = join(scratch, "session.json");
writeFileSync(fixturePath, JSON.stringify(fixture));
if (options.includes("--fixture-only")) {
  console.log(fixturePath);
  process.exit(0);
}
const rep = reporter(join(scratch, "tab-number-hints-test.log"), { name: "tab-number-hints-test" });
let app;
let launched = false;
const ac = (body, timeout = 15000) => app.eval(body, { timeout });
const seam = (action, modifiers = 0, id = "w1") => ac(`return globalThis.expo.modules.SolaraShell.devTabNumberHints(${JSON.stringify(id)}, ${JSON.stringify(action)}, ${modifiers});`);
const views = (id = "w1") => ac(`return globalThis.expo.modules.SolaraHosted.devTabNumberHintViews(${JSON.stringify(id)}).then(JSON.parse);`);
const shown = async (id = "w1") => (await views(id)).filter((v) => v.visible);
const begin = async (id = "w1") => {
  await seam("begin", 0, id);
  return seam("flags", 1048576, id);
};
const show = async (id = "w1") => {
  const armed = await begin(id);
  assert.equal(armed.pending, true, JSON.stringify(armed));
  await sleep(1250);
  assert.equal((await seam("state", 0, id)).visible, true);
};
const capture = async (name, id = "w1") => {
  const path = join(output, `${name}.png`);
  assert.equal(await ac(`return ac.shell.devSnapshotWindow(${JSON.stringify(id)}, ${JSON.stringify(path)});`, 19000), true);
  const rows = await views(id);
  writeFileSync(join(output, `${name}.json`), JSON.stringify(rows, null, 2));
  return rows;
};
const hidden = async (id = "w1") => {
  await sleep(180);
  assert.equal((await seam("state", 0, id)).visible, false);
  assert.deepEqual(await shown(id), []);
};
const settings = async (value) => {
  await seam("end");
  await ac(`ac.store.getState().updateSettings(${JSON.stringify(value)}); return true;`);
  await sleep(800);
};
const labelsMatch = (rows, unbound = [], remapped = {}, concealed = []) => {
  const expected = Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`selectTab:${i + 1}`, `⌘${i + 1}`]).concat([["selectLastTab", "⌘9"]]));
  Object.assign(expected, remapped);
  for (const action of [...unbound, ...concealed]) delete expected[action];
  const visible = rows.filter((r) => r.visible);
  for (const [action, label] of Object.entries(expected)) {
    const matches = visible.filter((r) => r.actions.includes(action));
    assert.ok(matches.length > 0, `no visible ${action}: ${JSON.stringify(rows)}`);
    assert.ok(matches.every((r) => r.label === label), `${action}: ${JSON.stringify(matches)}`);
  }
  for (const action of unbound) assert.ok(!visible.some((r) => r.actions.includes(action)), `${action} remained visible`);
  for (const row of visible) {
    assert.equal(row.opacity, 1);
    assert.equal(row.presentationOpacity, 1);
    assert.ok(row.frame[2] > 0 && row.frame[3] > 0);
  }
};
try {
  if (!options.includes("--attach")) {
    const args = ["120", "scripts/agent/ac", "launch", resolve(appArg), "--data", data, "--session", fixturePath, "--onboarded", "--as", process.env.AC_LOCKED_AS ?? "th33"];
    if (process.env.METRO_PORT) args.push("--js", `127.0.0.1:${process.env.METRO_PORT}`);
    for (const value of ["SOLARA_NATIVE_SHELL=1", "SOLARA_NATIVE_TOP_STRIP=1", "SOLARA_NATIVE_SIDEBAR=1"]) args.push("--env", value);
    launched = true;
    const launch = spawnSync("timeout", args, { encoding: "utf8", timeout: 125000 });
    assert.equal(launch.status, 0, launch.stdout + launch.stderr);
  }
  app = attach(data);
  await sleep(3500);
  await rep.check("before 1 s: no hints; after 1 s: tiles, rows, group, split, list and final ⌘9", async () => {
    await seam("end");
    await hidden();
    await capture("before-hold-rest");
    const earlyPath = join(output, "before-one-second.png");
    const early = await ac(`const S = globalThis.expo.modules.SolaraShell, H = globalThis.expo.modules.SolaraHosted;
      let start = 0;
      return S.devTabNumberHints("w1", "begin", 0)
        .then(() => S.devTabNumberHints("w1", "flags", 1048576))
        .then(() => { start = performance.now(); return new Promise(resolve => setTimeout(resolve, 650)); })
        .then(() => Promise.all([S.devTabNumberHints("w1", "state", 0), H.devTabNumberHintViews("w1")]))
        .then(values => {
          const sampled = { state: values[0], rows: JSON.parse(values[1]), elapsed: performance.now() - start };
          const captureStart = performance.now() - start;
          return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(earlyPath)})
            .then(saved => ({ ...sampled, saved, captureStart }));
        });`, 19000);
    assert.equal(early.saved, true, JSON.stringify(early));
    assert.equal(early.state.visible, false, JSON.stringify(early));
    assert.deepEqual(early.rows.filter((r) => r.visible), []);
    assert.ok(early.elapsed < 1000, JSON.stringify(early));
    assert.ok(early.captureStart < 1000, JSON.stringify(early));
    writeFileSync(join(output, "before-one-second.json"), JSON.stringify(early.rows, null, 2));
    writeFileSync(join(output, "before-one-second-timing.json"), JSON.stringify({ sampled: early.elapsed, captureStart: early.captureStart, saved: early.saved }, null, 2));
    await sleep(650);
    assert.equal((await seam("state")).visible, true);
    const rows = await capture("sidebar-hints");
    labelsMatch(rows);
    assert.ok(rows.some((r) => r.visible && r.compact && r.actions.includes("selectTab:1")));
    const keys = ["tile:tile", "t:row", "t:group-a", "t:group-b", "s:split", "t:list1", "t:list2", "t:list3"];
    for (const [index, key] of keys.entries()) assert.ok(rows.some((r) => r.visible && r.actions.includes(`selectTab:${index + 1}`) && r.rowKey === key), `${key}: ${JSON.stringify(rows)}`);
    assert.ok(rows.some((r) => r.visible && r.actions.includes("selectLastTab") && r.rowKey === "t:last"));
    return { visible: rows.filter((r) => r.visible), earlyElapsed: early.elapsed, earlyCaptureStart: early.captureStart, lateElapsed: ">=1300 ms", beforeSnapshot: "during the timed hold after the 650 ms sample" };
  });
  await rep.check("dark sidebar keycap snapshot", async () => {
    await settings({ appearance: "dark" });
    await show();
    labelsMatch(await capture("sidebar-hints-dark"));
    await settings({ appearance: "light" });
  });
  await rep.check("Command 1–9 preserve numbered selection in JS and native state", async () => {
    await seam("end");
    const selections = [];
    const codes = [18, 19, 20, 21, 23, 22, 26, 28, 25];
    const expected = ["tile", "row", "group-a", "group-b", "split-b", "list1", "list2", "list3", "last"];
    const selected = async (number, tabId) => {
      const press = await ac(`return ac.shell.devKeyEquivalent("w1", { key: "${number}", keyCode: ${codes[number - 1]}, modifiers: ["command"], focus: "window", wait: 0 });`);
      const deadline = Date.now() + 4000;
      let js;
      let native;
      do {
        js = await ac(`const s = ac.store.getState(), w = s.windows.w1; return w.activeTabIds[w.profileId];`);
        native = await app.snapshot({ windowId: "w1", fields: ["windows.selectedTabId"] });
        if (native.consistent && js === tabId && native.windows.find((w) => w.id === "w1")?.selectedTabId === tabId) break;
        await sleep(40);
      } while (Date.now() < deadline);
      assert.equal(js, tabId, `Command ${number} JS selection`);
      assert.equal(native.consistent, true);
      assert.equal(native.windows.find((w) => w.id === "w1")?.selectedTabId, tabId, `Command ${number} native selection`);
      selections.push({ number, tabId, press });
    };
    for (const [index, id] of expected.entries()) await selected(index + 1, id);
    await ac(`ac.store.getState().activate("split-a"); return true;`);
    await selected(5, "split-a");
    await ac(`ac.store.getState().activate("list1"); return true;`);
    writeFileSync(join(scratch, "numbered-selection.json"), JSON.stringify(selections, null, 2));
    return selections;
  });
  await rep.check("release hides", async () => {
    await show();
    await seam("flags", 0);
    await hidden();
    await capture("released");
  });
  for (const action of ["key", "click", "deactivate", "resignKey", "capsLock", "queuedCancellation"]) {
    await rep.check(`${action} cancels pending hold and blocks rearm`, async () => {
      await begin();
      await sleep(150);
      await seam(action, action === "capsLock" ? 1114112 : 0);
      await sleep(1150);
      await hidden();
      await seam("flags", 1048576);
      await sleep(1100);
      await hidden();
    });
    if (action !== "queuedCancellation") await rep.check(`${action} cancels visible hints`, async () => {
      await show();
      await seam(action, action === "capsLock" ? 1114112 : 0);
      await hidden();
      await capture(`cancelled-${action}`);
    });
  }
  await rep.check("latched Caps Lock permits Command alone and release hides", async () => {
    await seam("begin");
    const armed = await seam("flags", 1114112);
    assert.equal(armed.pending, true, JSON.stringify(armed));
    await sleep(1250);
    assert.equal((await seam("state")).visible, true);
    labelsMatch(await capture("caps-lock-hints"));
    await seam("flags", 65536);
    await hidden();
    await capture("caps-lock-released");
  });
  await rep.check("another modifier cancels until Command release", async () => {
    await begin();
    await seam("flags", 1179648);
    await seam("flags", 1048576);
    await sleep(1200);
    await hidden();
  });
  await rep.check("remapped and unbound applied menu bindings", async () => {
    await settings({ shortcuts: { "selectTab:2": ["r", "control", "option", "command"], "selectTab:3": [] } });
    await show();
    const state = await seam("state");
    assert.equal(state.bindings["selectTab:2"], "⌃⌥⌘R");
    assert.equal(state.bindings["selectTab:3"], undefined);
    labelsMatch(await capture("remapped-unbound"), ["selectTab:3"], { "selectTab:2": "⌃⌥⌘R" });
  });
  await rep.check("icons-only rail hints", async () => {
    await settings({ shortcuts: {}, sidebarIconsOnly: true });
    await show();
    const rows = await capture("icons-only-hints");
    labelsMatch(rows, [], {}, ["selectTab:3", "selectTab:4"]);
    const state = await seam("state");
    assert.equal(state.bindings["selectTab:3"], "⌘3");
    assert.equal(state.bindings["selectTab:4"], "⌘4");
    assert.ok(!rows.some((r) => r.visible && r.actions.some((a) => ["selectTab:3", "selectTab:4"].includes(a))));
    assert.ok(rows.filter((r) => r.visible).every((r) => r.compact));
  });
  await rep.check("native top-strip hints", async () => {
    await settings({ sidebarIconsOnly: false, tabLayout: "top" });
    await show();
    const rows = await capture("top-strip-hints");
    labelsMatch(rows);
    assert.ok(rows.some((r) => r.visible && r.ancestors.some((a) => /Strip/.test(a))));
  });
  await rep.check("setting suppresses hints", async () => {
    await settings({ tabLayout: "sidebar", showTabNumberHints: false });
    const out = await begin();
    assert.equal(out.pending, false);
    await sleep(1150);
    await hidden();
  });
  await rep.check("Little Solara has no hints", async () => {
    await settings({ showTabNumberHints: true });
    const id = await ac(`const s = ac.store.getState(); s.createWindow({ small: true, url: "about:blank" }); return Object.values(ac.store.getState().windows).find(w => w.kind === "small")?.id;`);
    assert.ok(id);
    await sleep(700);
    const out = await begin(id);
    assert.equal(out.eligible, false);
    assert.equal(out.pending, false);
    await sleep(1150);
    await hidden(id);
    await capture("little-solara-no-hints", id);
    await seam("end", 0, id);
    await ac(`ac.store.getState().closeWindow(${JSON.stringify(id)}); return true;`);
  });
  writeFileSync(join(scratch, "tab-number-hints-results.json"), JSON.stringify(rep.results, null, 2));
} finally {
  if (app?.alive) await seam("end").catch(() => {});
  if (launched) {
    const quit = spawnSync("timeout", ["30", "scripts/agent/ac", "quit", data], { encoding: "utf8", timeout: 35000 });
    if (quit.status !== 0) rep.record("quit hidden instance", { error: new Error(quit.stdout + quit.stderr) });
  }
}
process.exitCode = rep.summary() ? 0 : 1;
