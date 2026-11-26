#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg] = process.argv.slice(2);
assert.ok(appArg && scratchArg, "usage: node settings-utilities-test.mjs <Debug app> <scratch directory>");
const appPath = realpathSync(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const bundleId = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim();
assert.equal(bundleId, "network.benson.solara.dev");

const scratchRoot = resolve(scratchArg);
mkdirSync(scratchRoot, { recursive: true });
const scratch = mkdtempSync(join(scratchRoot, "ac-settings-utilities-"));
const data = join(scratch, "data");
const importSources = join(scratch, "import-sources");
mkdirSync(importSources);
const installer = join(scratch, "installer.sh");
const installError = "Settings utility driver installer fixture";
writeFileSync(installer, "printf '%s\\n' 'error Settings utility driver installer fixture'\nexit 1\n");
const rep = reporter(join(scratch, "settings-utilities-test.log"), { name: "settings-utilities-test" });
let app;

const writesSource = (action, args = {}) =>
  `globalThis.expo.modules.SolaraSettings.devSettingsWrites(${JSON.stringify(action)}, ${JSON.stringify(JSON.stringify(args))}).then(JSON.parse)`;
const writes = (action, args) => app.eval(`return ${writesSource(action, args)}`);
const nativeState = () => app.eval("return JSON.parse(expo.modules.SolaraStoreAdapter.snapshot()).data");
const fixtureURL = (name) => `data:text/plain,${name}`;
const actions = [
  ["openURLs", { urls: [fixtureURL("settings-a"), fixtureURL("settings-b")] }, "Open URLs"],
  ["openInNewTab", { url: fixtureURL("extensions") }, "Open in New Tab"],
  ["openInBrowser", { url: fixtureURL("live") }, "Open in Browser"],
  ["openInternalPage", { page: "history" }, "Open Internal Page"],
  ["openImport", {}, "Open Import"],
  ["installCli", {}, "CLI control"],
  ["cliStatus", {}, "CLI control"],
  ["layout", { layout: "top" }, "Tab layout"],
  ["create", { name: "Retired", color: "blue" }, "Create Profile"],
  ["update", { id: "default", name: "Retired" }, "Update Profile"],
  ["reorder", { ids: ["default"] }, "Reorder Profiles"],
];

function assertNewTabs(before, after, window, expectedURLs) {
  assert.equal(after.error, undefined);
  assert.equal(after.direct, true);
  assert.equal(after.opened, true);
  assert.equal(after.windows.length, before.windows.length);
  const priorIds = new Set(before.tabs.flat().map((tab) => tab.id));
  const opened = after.tabs.flat().filter((tab) => !priorIds.has(tab.id));
  assert.deepEqual(opened.map((tab) => tab.url).sort(), [...expectedURLs].sort());
  for (const tab of opened) {
    assert.equal(tab.window, window.id);
    assert.equal(tab.profileId, window.profileId);
  }
  assert.equal(opened.find((tab) => tab.active)?.url, expectedURLs.at(-1));
}

try {
  app = await launch(appPath, {
    data,
    onboarded: true,
    env: {
      SOLARA_CLI_HOME: join(scratch, "cli-home"),
      SOLARA_CLI_BIN_DIR: join(scratch, "cli-bin"),
      SOLARA_CLI_INSTALL_SCRIPT: installer,
      SOLARA_IMPORT_SOURCE_DIR: importSources,
      SOLARA_IMPORT_SAFARI_HOME: importSources,
      SOLARA_IMPORT_DIA_BUNDLE_ID: "invalid.solara.acceptance.no-dia",
    },
  });
  const initial = await app.ready({
    test: `if (!globalThis.expo?.modules?.SolaraSettings?.devSettingsWrites) return false;
      return ${writesSource("snapshot")}.then(state => state.direct && state.focusedWindow && state)`,
  });
  const window = initial.windows.find(({ id }) => id === initial.focusedWindow);
  assert.ok(window && !window.incognito);

  await rep.check("each retired JavaScript route returns a native-only error", async () => {
    for (const [action, args, label] of actions) {
      assert.deepEqual(await writes(action, { ...args, viaJS: true }), { error: `${label} is native only` });
    }
  });

  let workId, sharedId;
  await rep.check("create appends independent and shared profiles in the native workspace", async () => {
    const before = await nativeState();
    const work = await writes("create", { name: "  Settings Work  ", color: "blue" });
    assert.equal(work.direct, true);
    assert.ok(work.id);
    workId = work.id;
    const shared = await writes("create", { name: " ", color: "green", shareWith: workId });
    assert.equal(shared.direct, true);
    assert.ok(shared.id && shared.id !== workId);
    sharedId = shared.id;
    const after = await nativeState();
    assert.deepEqual(after.profileOrder, [...before.profileOrder, workId, sharedId]);
    assert.equal(after.profiles[workId]?.name, "Settings Work");
    assert.equal(after.profiles[workId]?.color, "blue");
    assert.equal(after.profiles[workId]?.dataId ?? null, null);
    assert.equal(after.profiles[sharedId]?.name, `Profile ${before.profileOrder.length + 2}`);
    assert.equal(after.profiles[sharedId]?.color, "green");
    assert.equal(after.profiles[sharedId]?.dataId, workId);
    assert.deepEqual(shared.windows, initial.windows);
    assert.deepEqual(shared.tabs, initial.tabs);
    assert.equal(shared.focusedWindow, initial.focusedWindow);
    assert.equal(after.settings.defaultProfileId, before.settings.defaultProfileId);
  });

  await rep.check("update renames and recolors only the named native profile", async () => {
    assert.ok(workId, "create fixture");
    const before = await nativeState();
    const out = await writes("update", { id: workId, name: "Settings Office", color: "orange" });
    assert.equal(out.direct, true);
    const after = await nativeState();
    assert.deepEqual(after.profileOrder, before.profileOrder);
    assert.deepEqual(after.profiles, {
      ...before.profiles,
      [workId]: { ...before.profiles[workId], name: "Settings Office", color: "orange" },
    });
  });

  await rep.check("reorder moves known profiles and appends the omitted ones in native order", async () => {
    assert.ok(workId && sharedId, "create fixtures");
    const before = await nativeState();
    const out = await writes("reorder", { ids: [sharedId, "missing-profile", workId] });
    assert.equal(out.direct, true);
    const after = await nativeState();
    assert.deepEqual(after.profileOrder, [sharedId, workId, ...before.profileOrder.filter((id) => id !== sharedId && id !== workId)]);
    assert.deepEqual(after.profiles, before.profiles);
    assert.deepEqual(out.windows, initial.windows);
    assert.deepEqual(out.tabs, initial.tabs);
    assert.equal(out.focusedWindow, initial.focusedWindow);
    assert.equal(after.settings.defaultProfileId, before.settings.defaultProfileId);
  });

  for (const [action, args] of actions.slice(0, 3)) {
    await rep.check(`${action} opens tabs in the native window and profile`, async () => {
      const before = await writes("snapshot");
      const out = await writes(action, args);
      assertNewTabs(before, out, window, args.urls ?? [args.url]);
      if (action === "openInBrowser") assert.equal(out.focusedWindow, window.id);
    });
  }

  await rep.check("openInternalPage opens and reuses native History", async () => {
    const before = await writes("snapshot");
    const out = await writes("openInternalPage", { page: "history" });
    const history = out.tabs.flat().find((tab) => tab.window === window.id && tab.active);
    assert.match(history?.url ?? "", /^[a-z][a-z0-9+.-]*:\/\/history$/);
    assertNewTabs(before, out, window, [history.url]);
    const reopened = await writes("openInternalPage", { page: "history" });
    assert.equal(reopened.opened, true);
    assert.equal(reopened.tabs.flat().length, out.tabs.flat().length);
    assert.equal(reopened.tabs.flat().find((tab) => tab.window === window.id && tab.active)?.id, history.id);
  });

  await rep.check("openImport opens the native Import window", async () => {
    const out = await writes("openImport");
    assert.equal(out.direct, true);
    assert.equal(out.importOpen, true);
    const state = await app.eval('return globalThis.expo.modules.SolaraSettings.devImport("state", null)');
    assert.ok(["loading", "choose"].includes(state.step), JSON.stringify(state));
  });

  await rep.check("installCli updates native CLI status with the isolated installer's result", async () => {
    const before = await writes("cliStatus");
    assert.equal(before.direct, true);
    assert.equal(before.cli.installing, false);
    assert.equal(before.cli.error, undefined);
    const started = await writes("installCli");
    assert.equal(started.direct, true);
    assert.equal(started.cli.installing, true);
    const settled = await app.ready({
      timeout: 10000,
      test: `return ${writesSource("cliStatus")}.then(state => !state.cli.installing && state)`,
    });
    assert.equal(settled.cli.error, installError);
  });
  await rep.check("each global tab layout choice updates the expected native windows", async () => {
    const ids = await app.eval(`
      const store = ac.store.getState();
      store.updateSettings({ tabLayout: "sidebar" });
      const explicitTop = store.createWindow({});
      const privateWindow = store.createWindow({ incognito: true });
      const little = store.createWindow({ small: true, url: "data:text/plain,little" });
      const explicitSidebar = store.createWindow({});
      const lastInherited = store.createWindow({});
      const native = expo.modules.SolaraStoreAdapter;
      for (const [id, layout] of [[explicitTop, "top"], [explicitSidebar, "sidebar"]]) {
        const { rev } = JSON.parse(native.snapshot());
        const result = JSON.parse(native.dispatch(JSON.stringify({ name: "setWindowLayout", args: [id, layout] }), rev));
        if (result.error || result.busy) throw new Error(JSON.stringify(result));
      }
      return { explicitTop, privateWindow, little, explicitSidebar, lastInherited };
    `);
    const before = await nativeState();
    assert.equal(before.windows[ids.privateWindow]?.incognito, true);
    assert.equal(before.windows[ids.little]?.kind, "small");
    const overrides = new Map([
      [window.id, null],
      [ids.explicitTop, "top"],
      [ids.privateWindow, null],
      [ids.little, null],
      [ids.explicitSidebar, "sidebar"],
      [ids.lastInherited, null],
    ]);
    const windowOverrides = (state) => new Map(Object.values(state.windows).map((w) => [w.id, w.tabLayout ?? null]));
    assert.deepEqual(windowOverrides(before), overrides);

    for (const layout of ["top", "sidebar"]) {
      assert.equal((await writes("layout", { layout })).direct, true);
      const state = await nativeState();
      assert.equal(state.settings.tabLayout, layout);
      assert.deepEqual(windowOverrides(state), overrides);
      if (process.env.SOLARA_NATIVE_WINDOW_LAYOUT === "1") {
        const expected = [[window.id, layout], [ids.lastInherited, layout], [ids.explicitTop, "top"], [ids.explicitSidebar, "sidebar"]];
        await app.ready({
          timeout: 10000,
          test: `const expected = ${JSON.stringify(expected)};
            const shell = expo.modules.SolaraWindowShell;
            return Promise.all(expected.map(([id]) => shell.describe(id).then(JSON.parse))).then(windows =>
              windows.every((w, i) => w?.nativeLayout && w.layout?.current &&
                Array.isArray(w.topStrip) === (expected[i][1] === "top")));`,
        });
      }
    }
  });
} finally {
  await app?.quit();
}
process.exit(rep.summary() ? 0 : 1);
