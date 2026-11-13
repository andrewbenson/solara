#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, renameSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `usage: node config-files-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]

Config files (~/.config/solara/config.json and themes/<name>.json), pointed at a scratch folder with SOLARA_CONFIG_DIR.
Checks, in one hidden instance: the file's settings and theme apply at launch; a keybinding saved by rename applies live
to the store and the menu bar; Settings reports each file value as set by the file; a broken save keeps the last good
config, reports file, line and key once in Settings and as one notification, and the next good save recovers; deleting
the file brings back the instance's own values; and a relaunch without the file shows nothing from it was saved.
`;

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
if (!appArg || resolve(appArg).startsWith("/Applications/") || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error(HELP);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-config-files-"));
const configDir = join(scratch, "config");
const data = join(scratch, "data");
mkdirSync(join(configDir, "themes"), { recursive: true });
const rep = reporter(join(scratch, "config-files-test.log"), { name: "config-files-test" });

const ocean = { colors: ["#3366FF", "#00CCAA"], angle: 90, grain: 0.25 };
const saveByRename = (name, value) => {
  const target = join(configDir, name);
  const temp = join(configDir, `.${name.replace("/", "-")}.tmp`);
  writeFileSync(temp, typeof value === "string" ? value : JSON.stringify(value, null, 2));
  renameSync(temp, target);
};
writeFileSync(join(configDir, "themes/ocean.json"), JSON.stringify(ocean));
writeFileSync(join(configDir, "config.json"), JSON.stringify({ settings: { showFullUrl: true, sidebarWidth: 250 }, theme: "ocean" }, null, 2));

const until = async (what, test, ms = 6000) => {
  const end = Date.now() + ms;
  let last;
  for (;;) {
    last = await test();
    if (last) return last;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
};

let app;
try {
  app = await launch(resolve(appArg), {
    data, onboarded: true, ready: "return !!ac.store && !!ac.openSettings", env: { SOLARA_CONFIG_DIR: configDir },
  });
  const run = (body) => app.eval(body, { timeout: 15000 });
  const json = async (body) => JSON.parse(await run(body));
  const settings = () => json(`return JSON.stringify(ac.store.getState().settings)`);
  const config = (keys = "") => json(`return globalThis.expo.modules.SolaraSettings.devSettings("configFiles", ${JSON.stringify(keys)})`);

  await rep.check("the instance reads only the scratch config folder", async () => {
    const state = await config();
    assert.equal(state.dir, resolve(configDir));
    assert.deepEqual(state.problems, []);
  });

  await rep.check("settings and the theme from the file apply at launch", async () => {
    const s = await settings();
    assert.equal(s.showFullUrl, true);
    assert.equal(s.sidebarWidth, 250);
    const theme = await json(`return JSON.stringify(ac.store.getState().profiles.default.theme ?? null)`);
    assert.equal(theme?.stops?.length, 2);
    assert.equal(theme?.angle, 90);
    assert.equal(theme?.grain, 0.25);
    const state = await config();
    assert.deepEqual(state.fileThemes, { default: "ocean" });
    assert.deepEqual([...state.fileKeys].sort(), ["showFullUrl", "sidebarWidth"]);
  });

  const list = await json(`return globalThis.expo.modules.SolaraSystem.menuShortcuts().then((l) => JSON.stringify(l))`);
  const target = list.find((item) => item.remappable && item.defaultKey && !item.id.startsWith("system:") && item.id !== "std:terminate:");
  assert.ok(target, "a remappable menu shortcut exists");
  rep.note?.(`keybinding target: ${target.id} (${target.title})`);

  await rep.check("a keybinding saved by rename applies live to the store and the menu bar", async () => {
    saveByRename("config.json", {
      settings: { showFullUrl: true, sidebarWidth: 250, appearance: "dark" },
      keybindings: { [target.id]: "ctrl+alt+shift+j" },
      theme: "ocean",
    });
    await until("the keybinding in the store", async () => {
      const s = await settings();
      return JSON.stringify(s.shortcuts?.[target.id]) === JSON.stringify(["j", "control", "option", "shift"]) && s.appearance === "dark";
    });
    await until("the menu bar's shortcut", async () => {
      const now = await json(`return globalThis.expo.modules.SolaraSystem.menuShortcuts().then((l) => JSON.stringify(l))`);
      const item = now.find((i) => i.id === target.id);
      return item?.key === "j" && ["control", "option", "shift"].every((m) => item.modifiers.includes(m));
    });
  });

  await rep.check("Settings shows each file value as set by the file", async () => {
    await run(`ac.openSettings("tabs"); return true`);
    await sleep(1200);
    const state = await config(`showFullUrl,sidebarWidth,appearance,warnBeforeQuitting,shortcut:${target.id},theme:default`);
    const source = resolve(configDir) + "/config.json";
    assert.ok(state.uiSources.showFullUrl?.endsWith("config.json"), JSON.stringify(state.uiSources));
    assert.ok(state.uiSources.appearance?.endsWith("config.json"));
    assert.equal(state.uiSources.warnBeforeQuitting, null);
    assert.ok(state.uiSources[`shortcut:${target.id}`]?.endsWith("config.json"));
    assert.ok(state.uiSources["theme:default"]?.includes("themes/ocean.json"));
    assert.ok(state.source === source || state.source.endsWith("/config/config.json"), state.source);
    await run(`return globalThis.expo.modules.SolaraSettings.devSettingsSwitch("tabs")`);
    const shown = await config();
    rep.note?.(`file notes in the Tabs pane: ${shown.settingsNotes.length}`);
  });

  await rep.check("Settings refuses to change a file value and keeps the user's own beneath", async () => {
    await run(`ac.store.getState().updateSettings({ showFullUrl: false, warnBeforeQuitting: false }); return true`);
    const s = await settings();
    assert.equal(s.showFullUrl, true);
    assert.equal(s.warnBeforeQuitting, false);
  });

  await rep.check("a broken save keeps the last good config and reports file, line and key once", async () => {
    const before = (await config()).notifications.length;
    saveByRename("config.json", '{\n  "settings": {\n    "showFullUrl": false,\n    "sidebarWidth": "wide"\n  }\n}\n');
    const state = await until("the problem", async () => {
      const c = await config();
      return c.problems.length ? c : null;
    });
    assert.match(state.problems[0], /config\.json, line 4: settings\.sidebarWidth: expected a number from 140 to 600/);
    assert.equal(state.notifications.length, before + 1);
    assert.match(state.notifications.at(-1), /couldn't use .*config\.json/);
    const s = await settings();
    assert.equal(s.showFullUrl, true);
    assert.equal(s.sidebarWidth, 250);
    assert.equal(s.appearance, "dark");
    await sleep(700);
    assert.equal((await config()).notifications.length, before + 1, "one notification per broken save");
  });

  await rep.check("the next good save recovers and applies", async () => {
    saveByRename("config.json", { settings: { sidebarWidth: 300 }, keybindings: { [target.id]: "ctrl+alt+shift+k" } });
    await until("recovery", async () => {
      const c = await config();
      const s = await settings();
      return c.problems.length === 0 && s.sidebarWidth === 300 && s.shortcuts?.[target.id]?.[0] === "k";
    });
    const s = await settings();
    assert.equal(s.showFullUrl, false, "showFullUrl left the file: the user's own value (false) is back");
    assert.notEqual(s.appearance, "dark");
    const theme = await json(`return JSON.stringify(ac.store.getState().profiles.default.theme ?? null)`);
    assert.notEqual(theme?.angle, 90, "the file stopped naming a theme");
  });

  await rep.check("deleting the file brings back the instance's own values", async () => {
    unlinkSync(join(configDir, "config.json"));
    await until("the file's values to go", async () => (await config()).fileKeys.length === 0);
    const s = await settings();
    assert.equal(s.sidebarWidth, 190);
    assert.equal(s.shortcuts?.[target.id], undefined);
  });

  saveByRename("config.json", { settings: { showFullUrl: true, sidebarWidth: 410 } });
  await until("a last file value", async () => (await settings()).sidebarWidth === 410);
  await app.quit();
  app = null;

  await rep.check("a relaunch without the file shows nothing from it was saved", async () => {
    unlinkSync(join(configDir, "config.json"));
    app = await launch(resolve(appArg), {
      data, onboarded: true, ready: "return !!ac.store", env: { SOLARA_CONFIG_DIR: configDir },
    });
    const s = JSON.parse(await app.eval(`return JSON.stringify(ac.store.getState().settings)`, { timeout: 15000 }));
    assert.equal(s.sidebarWidth, 190);
    assert.equal(s.showFullUrl, false);
    assert.equal(s.warnBeforeQuitting, false);
  });
} finally {
  await app?.quit();
}

const ok = rep.summary();
if (!keep) rmSync(scratch, { recursive: true, force: true });
process.exit(ok ? 0 : 1);
