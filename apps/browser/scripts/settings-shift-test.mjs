import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { attach, launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `usage: node settings-shift-test.mjs <Debug Solara.app> [--port N] [--attach <data dir>] [--panes a,b] [--keep]

Opens Settings in a hidden instance and switches to every pane, the first one right after the window opens.
For each pane it records every view's frame, every text and every switch's value on the first frame the pane
is on screen and again once it has settled, and fails when anything moved, appeared, disappeared or changed.
Then it checks Settings search: ⌘F focuses the field, typing finds the row, Return opens its pane, scrolls the
row into view and highlights it, Escape clears the field.

The native window (the default) is read through SolaraSettings' dev hooks: devSettingsSwitch captures every NSView's
frame, every text view's text and every switch on the first frame a pane appears and again 1.2 s later, and
devSettings("search") reports the query, results, highlight and the highlighted row's frame against the viewport.
`;

const { values: flags, positionals } = parseArgs({
  allowPositionals: true,
  options: { port: { type: "string" }, attach: { type: "string" }, panes: { type: "string" }, keep: { type: "boolean" }, help: { type: "boolean", short: "h" } },
});
if (flags.help || (!positionals[0] && !flags.attach)) {
  console.log(HELP);
  process.exit(flags.help ? 0 : 2);
}

const PANES = (flags.panes ?? "general,profiles,sync,tabs,appearance,privacy,passwords,autofill,extensions,search,shortcuts,liveFolders,calendar,advanced").split(",");
const SETTLE_MS = 1200;
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);

const scratch = flags.attach ? null : mkdtempSync(join(tmpdir(), "ac-settings-shift-"));
const data = flags.attach ? resolve(flags.attach) : join(scratch, "data");
const importSources = scratch && join(scratch, "import-sources");
const rep = reporter(join(flags.attach ?? scratch, "settings-shift-test.log"), { name: "settings-shift-test" });

function compare({ first, settled }) {
  const problems = [];
  const a = new Map(first.frames);
  const b = new Map(settled.frames);
  for (const [path, frame] of a) {
    if (!b.has(path)) problems.push(`disappeared: ${path}`);
    else if (frame && b.get(path) && frame.some((v, i) => Math.abs(v - b.get(path)[i]) > 0.5)) problems.push(`moved: ${path} ${frame.join(",")} -> ${b.get(path).join(",")}`);
  }
  for (const path of b.keys()) if (!a.has(path)) problems.push(`appeared: ${path}`);
  const ta = new Map(first.texts);
  for (const [path, text] of settled.texts) if (ta.has(path) && ta.get(path) !== text) problems.push(`text changed: ${JSON.stringify(ta.get(path))} -> ${JSON.stringify(text)}`);
  const sa = new Map(first.switches);
  for (const [path, on] of settled.switches) if (sa.has(path) && sa.get(path) !== on) problems.push(`switch changed: ${path} ${sa.get(path)} -> ${on}`);
  return problems;
}

const NATIVE_SWITCH = (pane, from, idleMs) => `
const S = globalThis.expo.modules.SolaraSettings;
ac.openSettings(${JSON.stringify(from)});
return new Promise((r) => setTimeout(r, ${idleMs} + 300)).then(() => S.devSettingsSwitch(${JSON.stringify(pane)})).then((t) => JSON.parse(t));`;

const NATIVE_SEARCH = (query, id, downs = 0) => `
const S = globalThis.expo.modules.SolaraSettings;
const state = () => S.devSettings("search").then((t) => JSON.parse(t));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const until = (test, ms) => { const end = Date.now() + ms; const loop = () => state().then((s) => (test(s) ? s : Date.now() > end ? null : wait(30).then(loop))); return loop(); };
ac.openSettings("general");
let before;
return wait(400)
  .then(state)
  .then((s) => { before = s.focusRequest; return ac.shell.devKeyEquivalent("settings", { key: "f", keyCode: 3, modifiers: ["command"], asKey: true }); })
  .then(() => until((s) => s.focusRequest !== before, 2000))
  .then((focused) => {
    if (!focused) throw new Error("⌘F didn't focus the search field");
    return wait(150).then(() => ac.shell.devTypeKeys("settings", ${JSON.stringify(query)}, 15));
  })
  .then(() => until((s) => s.query === ${JSON.stringify(query)}, 2000))
  .then((typed) => {
    if (!typed) throw new Error("typing didn't reach the search field");
    if (typed.results[${downs}] !== ${JSON.stringify(id)}) throw new Error("result ${downs + 1} is " + typed.results[${downs}] + ", not ${id}");
    const press = (key, keyCode) => ac.shell.devKeyEquivalent("settings", { key, keyCode, modifiers: [], send: true, asKey: true, wait: 30 });
    const downs = Array.from({ length: ${downs} }).reduce((p) => p.then(() => press("\\uF701", 125)), Promise.resolve());
    return downs.then(() => press("\\r", 36)).then(() => until((s) => s.flash === ${JSON.stringify(id)} && s.anchor, 3000)).then((s) => s ? wait(600).then(state).then((later) => ({ results: typed.results, s: later && later.anchor ? later : s })) : { results: typed.results, s });
  })
  .then(({ results, s }) => {
    if (!s) throw new Error("${id} wasn't highlighted");
    return { results, nav: s.pane, frame: s.anchor, viewport: s.viewport };
  });`;

async function checkArcThemePicker(ac) {
  const probe = (choose) => ac(`
    return globalThis.expo.modules.SolaraSettings.devSettingsWrites("arcThemeChoices", ${JSON.stringify(JSON.stringify({ id: "default", choose }))}).then(JSON.parse);
  `);
  const waitForChoices = async (test) => {
    const deadline = Date.now() + 8000;
    let last;
    do {
      last = await probe();
      if (Array.isArray(last.choices) && test(last.choices)) return last.choices;
      await sleep(100);
    } while (Date.now() < deadline);
    throw new Error(`Profile theme picker did not load the expected Arc choices: ${JSON.stringify(last)}`);
  };

  await ac('ac.openSettings("profiles", "default"); return true;');
  assert.deepEqual(await waitForChoices(() => true), [], "unavailable Arc discovery");
  await ac('ac.openSettings("general"); return true;');
  await untilSnapshot("settings general before reopening the profile", (state) =>
    state.windows.some((w) => w.kind === "settings" && w.settings?.search?.pane === "general"));

  const theme = (name) => JSON.parse(readFileSync(new URL(`../../../packages/import/fixtures/arc-themes/${name}.json`, import.meta.url), "utf8"));
  const spec = join(scratch, "arc-theme-fixture.json");
  writeFileSync(spec, JSON.stringify({
    browser: "arc",
    spaces: [
      { id: "z", name: "Research", profile: "Profile 2", emoji: "🔬", theme: theme("basic-appearance") },
      { id: "b", name: "Studio", theme: theme("single-orange") },
      { id: "a", name: "Review", profile: "Profile 2", theme: theme("single-orange") },
      { id: "invalid", name: "Invalid", theme: {} },
      { id: "missing", name: "No Theme" },
    ],
  }));
  const fixture = fileURLToPath(new URL("../../../packages/settings/scripts/sidebar-fixture.py", import.meta.url));
  execFileSync("python3", [fixture, spec, importSources], { timeout: 10000 });
  const sidebar = join(importSources, "Arc", "StorableSidebar.json");
  const original = readFileSync(sidebar);

  await ac('ac.openSettings("profiles", "default"); return true;');
  assert.deepEqual(await waitForChoices((choices) => choices.length > 0), [
    { id: "z", name: "Research", emoji: "🔬" },
    { id: "a", name: "Review", emoji: null },
    { id: "b", name: "Studio", emoji: null },
  ]);
  const { theme: applied } = await probe("z");
  assert.equal(applied.mode, "auto");
  assert.equal(applied.translucency, 0);
  assert.deepEqual(applied.stops[0].color, { r: 0.86, g: 0.9, b: 0.97, a: 1 });
  assert.deepEqual(applied.dark.stops[0].color, { r: 0.08, g: 0.1, b: 0.16, a: 1 });
  assert.deepEqual(readFileSync(sidebar), original, "Arc sidebar file is unchanged");
}

let app;
const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await app.snapshot().catch((e) => ({ error: e.message }));
    if (!last.error && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
async function checkProfileDeletion(ac) {
  const settings = (action, args) => ac(
    `return globalThis.expo.modules.SolaraSettings.devSettingsWrites(${JSON.stringify(action)}, ${JSON.stringify(JSON.stringify(args))}).then(JSON.parse);`,
  );
  const { id } = await settings("create", { name: "Settings deletion fixture" });
  assert.ok(id, "fixture profile created");
  await ac(`
    const s = ac.store.getState();
    s.switchProfile(s.windowOrder[0], ${JSON.stringify(id)});
    return globalThis.expo.modules.SolaraSettings.navigate("profiles", ${JSON.stringify(id)}, null).then(() => true);
  `);
  const canceled = await settings("delete", { id, confirmed: false });
  assert.equal(canceled.direct, true);
  assert.equal(canceled.deleted, false);
  assert.equal(canceled.settingsProfile, id);
  assert.ok(canceled.windows.some((window) => window.profileId === id), "the canceled profile is still shown");
  const deleted = await settings("delete", { id, confirmed: true });
  assert.equal(deleted.deleted, true);
  assert.equal(deleted.settingsProfile, null);
  assert.ok(!deleted.profileOrder.includes(id) && deleted.profileOrder.includes("default"));
  assert.ok(deleted.windows.every((window) => window.profileId !== id), "no window shows the deleted profile");
  const last = await settings("delete", { id: "default", confirmed: true });
  assert.equal(last.deleted, false);
  assert.deepEqual(last.profileOrder, ["default"]);
}

try {
  app = flags.attach
    ? attach(data)
    : await launch(resolve(positionals[0]), {
        data, port: flags.port, onboarded: true, ready: "return !!ac.openSettings",
        env: { SOLARA_IMPORT_SOURCE_DIR: importSources },
      });
  const ac = (body) => app.eval(body, { timeout: 60000 });
  await new Promise((r) => setTimeout(r, 6000));

  await ac(`
    const cef = globalThis.expo.modules.SolaraCEF;
    return Promise.all([
      cef.setZoom("", "example.com", 1.25),
      cef.setSiteSetting("", "https://example.com", "notifications", "block"),
    ]).then(() => true, (e) => String(e));
  `);

  let from = "general";
  for (const [i, pane] of PANES.entries()) {
    const source = pane === from ? (pane === "general" ? "tabs" : "general") : from;
    await rep.check(`${pane}${i === 0 ? " (right after opening)" : ""}`, async () => {
      const result = await ac(NATIVE_SWITCH(pane, source, i === 0 ? 0 : 500));
      if (result.error) throw new Error(result.error);
      const problems = compare(result);
      if (problems.length) throw new Error([`${problems.length} changes after the first frame (shown ${result.shownAfter} ms after the click)`, ...problems.slice(0, 15)].join("\n"));
      const snapshot = await untilSnapshot(`native settings ${pane}`, (state) => state.windows.some((w) => w.kind === "settings" && w.settings?.layout?.pane === pane));
      const layout = snapshot.windows.find((w) => w.kind === "settings")?.settings.layout;
      if (layout.firstViewCount !== result.first.frames.length || layout.settledViewCount !== result.settled.frames.length ||
        layout.firstSwitchCount !== result.first.switches.length || layout.settledSwitchCount !== result.settled.switches.length) throw new Error(`native settings layout ${JSON.stringify(layout)}`);
      return `${result.first.frames.length} views, ${result.first.switches.length} switches, shown after ${result.shownAfter} ms, nothing changed`;
    });
    from = pane;
  }

  for (const [query, id, downs] of [["cookies", "privacy.blockCookieBanners", 0], ["dark", "appearance.theme", 0], ["licenses", "advanced.licenses", 0], ["password", "passwords.offerToSave", 1], ["peek", "tabs.peekModifier", 0], ["clean up", "tabs.cleanUp", 0]]) {
    await rep.check(`search "${query}"${downs ? ` ↓×${downs}` : ""} opens ${id}`, async () => {
      const out = await ac(NATIVE_SEARCH(query, id, downs));
      const [, y, , h] = out.frame;
      if (out.nav !== id.split(".")[0]) throw new Error(`opened ${out.nav}`);
      const [top, bottom] = [out.viewport[1], out.viewport[1] + out.viewport[3]];
      if (!(y >= top && y + h <= bottom)) throw new Error(`row isn't in view: y ${y}, height ${h}, view ${top}–${bottom}`);
      const snapshot = await untilSnapshot(`native settings row ${id}`, (state) => state.windows.some((w) => w.kind === "settings" && w.settings?.search?.flash === id && w.settings.search.anchor));
      const search = snapshot.windows.find((w) => w.kind === "settings")?.settings.search;
      if (search.query !== query || search.pane !== out.nav || search.results.length !== out.results.length ||
        search.results.some((value, index) => value !== out.results[index]) || !near(search.anchor, out.frame) || !near(search.viewport, out.viewport))
        throw new Error(`native settings search ${JSON.stringify(search)} vs ${JSON.stringify(out)}`);
      const cleared = await ac(`return ac.shell.devKeyEquivalent("settings", { key: "\\u001b", keyCode: 53, modifiers: [], send: true, asKey: true, wait: 30 })
        .then(() => new Promise((r) => setTimeout(r, 200)))
        .then(() => globalThis.expo.modules.SolaraSettings.devSettings("search"))
        .then((text) => JSON.parse(text).query === "");`);
      if (!cleared) throw new Error("Escape didn't clear the field");
      await untilSnapshot("native settings search cleared", (state) => state.windows.some((w) => w.kind === "settings" && w.settings?.search?.query === ""));
      return `${out.results.length} results, row at y ${y}`;
    });
  }
  if (importSources && PANES.includes("profiles")) {
    await rep.check("Profiles theme picker loads and applies Arc choices", () => checkArcThemePicker(ac));
    await rep.check("Profile deletion requires confirmation and preserves the last profile", () => checkProfileDeletion(ac));
  }
} catch (error) {
  rep.record("setup", { error });
} finally {
  if (!flags.attach && !flags.keep) await app?.quit();
}
const passed = rep.summary();
if (!flags.attach && !flags.keep) rmSync(scratch, { recursive: true, force: true });
process.exit(passed ? 0 : 1);
