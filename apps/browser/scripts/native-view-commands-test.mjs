import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node apps/browser/scripts/native-view-commands-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const evidence = [];
let app;
let handlerBaseline;
const run = (body) => app.eval(body, { timeout: 2000 });
const nativeState = async () => (await run(`
  const module = expo.modules.SolaraStoreAdapter;
  const status = module.status();
  if (!status.active || status.frozen !== false) throw new Error("native workspace ownership required");
  return JSON.parse(module.snapshot());
`)).data;
const menu = (windowId, command, arg = null) =>
  run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand(${JSON.stringify(windowId)}, ${JSON.stringify(command)}, ${JSON.stringify(arg)});`);
const press = async (key, keyCode, modifiers) => {
  const result = await run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ key, keyCode, modifiers, focus: "window", asKey: true, wait: 30 })});`);
  assert.equal(result.error, undefined, JSON.stringify(result));
  assert.notEqual(result.handledBy, "none", `${key}: shortcut was not handled`);
  return result;
};
const bridge = (command, arg = null, windowId = "w1") =>
  run(`ac.runCommand({ command: ${JSON.stringify(command)}, arg: ${JSON.stringify(arg)}, windowId: ${JSON.stringify(windowId)} }); return true;`);

async function until(label, accept, ms = 12000) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() + 1000 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    last = await nativeState();
    if (await accept(last)) return last;
    await sleep(50);
  }
  evidence.push({ label, failed: true, state: last });
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  throw new Error(`${label}: deadline exceeded`);
}

async function handledNatively(label) {
  await sleep(200);
  const stats = await run("return ac.commandHandlers.stats();");
  assert.equal(stats.enabled, false, `${label}: JS handlers unexpectedly enabled`);
  assert.equal(stats.calls, handlerBaseline.calls, `${label}: JS handler made a decision`);
  assert.equal(stats.blocked, handlerBaseline.blocked, `${label}: command fell through to disabled JS`);
}

function pass(label, details = {}) {
  evidence.push({ label, ...details });
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  console.log(`PASS ${label}`);
}

async function step(label, trigger, accept) {
  const before = await nativeState();
  const result = await trigger();
  const after = await until(label, (state) => accept(before, state));
  await handledNatively(label);
  pass(label);
  return { before, after, result };
}

async function unchanged(label, trigger, accept) {
  const before = await nativeState();
  const result = await trigger();
  await sleep(300);
  const after = await nativeState();
  assert.ok(accept(before, after, result), `${label}: state changed`);
  await handledNatively(label);
  pass(label);
}

const flipped = (key) => (before, after) => after.settings[key] === !before.settings[key];
const active = (s, id = "w1") => s.windows[id]?.activeTabIds[s.windows[id].profileId];

try {
  app = await launch(appPath, {
    data: join(output, "data"), fresh: true, onboarded: true, probe: true, keepData: true,
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: process.env.SOLARA_NATIVE_WINDOW_LAYOUT ?? "1" },
    session: session({
      windows: [{ id: "w1", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } }],
      tabs: [{ id: "a", url: "about:blank#a", title: "A" }, { id: "b", url: "about:blank#b", title: "B" }],
      settings: { bookmarksBar: "newTab", sleepInactiveTabs: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
    }),
    ready: "return !!ac.commandHandlers && !!ac.runCommand && !!ac.shell.devKeyEquivalent && !!globalThis.acPerf && !!expo.modules.SolaraApp.devWorkspaceMenuCommand && !!ac.store.getState().windows.w1;",
  });
  const probe = await menu("w1", "noSuchCommand");
  assert.equal(probe?.debug, true, "devWorkspaceMenuCommand did nothing: this driver needs a Debug build (the hook is compiled out of Release)");
  handlerBaseline = await run("const baseline = ac.commandHandlers.stats(); ac.commandHandlers.setEnabled(false); return baseline;");

  const viewRows = () => run('return expo.modules.SolaraApp.devMenuItems("View", null);');
  const viewRow = async (title) => (await viewRows()).find((row) => row.title === title);
  await until("View title and checkmarks are read from the native settings", async (state) => {
    const fullUrl = await viewRow("Show Full URL");
    const appearance = await viewRow("Appearance");
    return fullUrl?.checked === state.settings.showFullUrl &&
      appearance?.items.some((row) => row.checked === true && row.title === "Automatic");
  });
  pass("View checkmarks match native settings");

  for (const [command, key] of [
    ["toggleFullUrl", "showFullUrl"],
    ["toggleOpenLinksInLittleSolara", "openLinksInLittleSolara"],
    ["toggleJavaScriptFromAppleEvents", "allowJavaScriptFromAppleEvents"],
  ]) {
    await step(`${command} flips ${key}`, () => menu("w1", command), flipped(key));
    await step(`${command} flips ${key} back`, () => menu("w1", command), flipped(key));
  }

  for (const [mode, name] of [["dark", "NSAppearanceNameDarkAqua"], ["light", "NSAppearanceNameAqua"], ["auto", "auto"]]) {
    const { result } = await step(`setAppearance ${mode}`, () => menu("w1", "setAppearance", mode), (_, s) => s.settings.appearance === mode);
    assert.equal(result.appearance, name, `setAppearance ${mode}: Swift applied ${name} before the JS mirror could`);
    const checked = (await viewRow("Appearance"))?.items.filter((row) => row.checked).map((row) => row.title);
    assert.deepEqual(checked, [{ dark: "Dark", light: "Light", auto: "Automatic" }[mode]]);
  }
  await step("setAppearance dark again", () => menu("w1", "setAppearance", "dark"), (_, s) => s.settings.appearance === "dark");
  await unchanged("setAppearance with an invalid mode changes nothing", () => menu("w1", "setAppearance", "sepia"),
    (b, a, result) => a.settings.appearance === "dark" && b.settings.appearance === "dark" && result.appearance === "NSAppearanceNameDarkAqua");
  await step("setAppearance auto again", () => menu("w1", "setAppearance", "auto"), (_, s) => s.settings.appearance === "auto");

  await step("toggleAddressBar", () => menu("w1", "toggleAddressBar"), (b, a) => a.settings.addressBar !== b.settings.addressBar);
  await step("toggleAddressBar back", () => menu("w1", "toggleAddressBar"), (b, a) => a.settings.addressBar !== b.settings.addressBar);

  await step("toggleBookmarksBar on a page turns it on", () => menu("w1", "toggleBookmarksBar"), (_, a) => a.settings.bookmarksBar === "always");
  await step("toggleBookmarksBar turns it off", () => menu("w1", "toggleBookmarksBar"), (_, a) => a.settings.bookmarksBar === "never");
  await step("setBookmarksBar always", () => menu("w1", "setBookmarksBar", "always"), (_, a) => a.settings.bookmarksBar === "always");
  await unchanged("setBookmarksBar with an invalid mode changes nothing", () => menu("w1", "setBookmarksBar", "sometimes"),
    (b, a) => b.settings.bookmarksBar === "always" && a.settings.bookmarksBar === "always");
  await step("setBookmarksBar newTab", () => menu("w1", "setBookmarksBar", "newTab"), (_, a) => a.settings.bookmarksBar === "newTab");

  const downloadsOpen = () => run("return ac.store.getState().windowUi.w1?.downloadsOpen === true;");
  for (const [want, trigger, how] of [[true, () => menu("w1", "downloads"), "menu command"], [false, () => press("j", 38, ["command", "shift"]), "a real ⇧⌘J menu key"]]) {
    const label = `downloads ${want ? "opens" : "closes"} through ${how}`;
    await trigger();
    const deadline = Date.now() + 12000;
    while ((await downloadsOpen()) !== want) {
      assert.ok(Date.now() < deadline, `${label}: deadline exceeded`);
      await sleep(50);
    }
    await handledNatively(label);
    pass(label);
  }

  const layout = (s) => s.windows.w1.tabLayout ?? s.settings.tabLayout;
  await step("toggleTabLayout", () => menu("w1", "toggleTabLayout"), (b, a) => layout(a) !== layout(b));
  await step("toggleTabLayout back", () => menu("w1", "toggleTabLayout"), (b, a) => layout(a) !== layout(b));

  const sidebar = (s, id = "w1") => s.windows[id]?.sidebarOpen;
  await step("toggleSidebar through a real ⌘S menu key", () => press("s", 1, ["command"]), (b, a) => sidebar(a) !== sidebar(b));
  await step("toggleSidebar through the JS bridge", () => bridge("toggleSidebar"), (b, a) => sidebar(a) !== sidebar(b));
  await step("toggleFullUrl through the JS bridge", () => bridge("toggleFullUrl"), flipped("showFullUrl"));
  await step("toggleSidebar from the Settings window acts on the focused browser window", () => menu("settings", "toggleSidebar"), (b, a) => sidebar(a) !== sidebar(b));

  await run('ac.store.getState().createSplit(["a", "b"]); return true;');
  await until("split made", (s) => Object.values(s.splits ?? {}).some((v) => v.tabIds.includes("a") && v.tabIds.includes("b")));
  const panes = await step("focusNextPane moves to the other pane", () => menu("w1", "focusNextPane"), (b, a) => active(a) !== active(b) && ["a", "b"].includes(active(a)));
  await step("focusPreviousPane moves back", () => menu("w1", "focusPreviousPane"), (_, a) => active(a) === active(panes.before));

  const small = await run('return ac.store.getState().createWindow({ url: "about:blank#small", small: true });');
  await until("Little Solara window", (s) => s.windows[small]?.kind === "small");
  await step("toggleSidebar from Little Solara goes to its main window and focuses it", () => menu(small, "toggleSidebar"),
    (b, a) => sidebar(a) !== sidebar(b) && a.ui.focusedWindowId === "w1");

  await menu(small, "closeWindow");
  await until("Little Solara closed", (s) => !s.windows[small]);
  await run('ac.store.getState().closeWindow("w1"); return true;');
  await until("every browser window closed", (s) => Object.keys(s.windows).length === 0);
  await step("with no window, toggleFullUrl still flips the setting", () => menu("", "toggleFullUrl"), flipped("showFullUrl"));
  await unchanged("with no window, toggleSidebar is handled natively and does nothing", () => menu("", "toggleSidebar"),
    (b, a) => Object.keys(a.windows).length === 0 && JSON.stringify(a.settings) === JSON.stringify(b.settings));

  writeFileSync(join(output, "result.json"), JSON.stringify({ passed: true, checks: evidence.map((e) => e.label) }, null, 2));
  console.log(`${evidence.length}/${evidence.length} passed`);
} finally {
  if (app) await app.quit();
}
