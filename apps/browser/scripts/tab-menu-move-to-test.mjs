import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node apps/browser/scripts/tab-menu-move-to-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const evidence = [];
const results = [];
let app;
const save = () => writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
const run = (body, timeout = 4000) => app.eval(body, { timeout });
async function until(label, read, ms = 10000) {
  const deadline = Date.now() + ms;
  while (Date.now() + 300 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    const value = await read();
    if (value) return value;
    await sleep(60);
  }
  throw new Error(`${label}: deadline exceeded`);
}
async function check(name, fn) {
  try {
    const details = await fn();
    evidence.push({ name, passed: true, details });
    results.push(true);
    console.log(`PASS ${name}`);
  } catch (error) {
    evidence.push({ name, passed: false, error: String(error?.stack ?? error) });
    results.push(false);
    console.log(`FAIL ${name}: ${error?.message ?? error}`);
  }
  save();
}
async function tabMenu(windowId, tabId, choice = null) {
  const armed = await run(`return expo.modules.SolaraShell.devContextMenu("arm", ${JSON.stringify(choice)});`);
  assert.equal(armed.error, undefined, JSON.stringify(armed));
  await run(`expo.modules.SolaraSettings.emit("onSettingsCall", { id: 2147483000, name: "sidebar.action", args: ${JSON.stringify(JSON.stringify([windowId, "tabMenu", tabId, {}]))} }); return true;`);
  return until("native menu model", async () => {
    const model = await run('return expo.modules.SolaraShell.devContextMenu("read", null);');
    return Array.isArray(model.items) ? model : null;
  });
}
const picture = (items, depth = 0) => items.flatMap((row) => {
  const pad = "  ".repeat(depth);
  if (row.separator) return [`${pad}────────────`];
  const mark = row.checked ? "✓ " : "  ";
  const line = `${pad}${mark}${row.title}${row.children ? " ›" : ""}${row.enabled ? "" : "  (disabled)"}${row.id ? `  [${row.id}]` : ""}`;
  return [line, ...(row.children ? picture(row.children, depth + 1) : [])];
});
const moveTo = (model) => model.items.find((row) => row.title === "Move to")?.children;
const shape = (rows) => rows.map((row) => row.separator ? "—" : row.title);

try {
  app = await launch(appPath, {
    data: join(output, "data"), fresh: true, onboarded: true, probe: true,
    session: session({
      profiles: ["Personal", "Work", "School"],
      windows: [{ id: "w1", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } }],
      tabs: [{ id: "a", url: "about:blank#a", title: "A" }, { id: "b", url: "about:blank#b", title: "B" }],
      settings: { warnBeforeMovingTabsToProfile: false, warnBeforeClosingWindow: false },
    }),
    ready: "return !!ac.store && !!expo.modules.SolaraShell.devContextMenu && !!expo.modules.SolaraSettings.emit;",
  });
  const state = await run("const s = ac.store.getState(); return { order: s.profileOrder, names: s.profileOrder.map((id) => s.profiles[id].name), own: s.tabs.b.profileId };");

  await check("Move to lists the profiles directly, the tab's own checked and disabled, then New Profile and Window", async () => {
    const model = await tabMenu("w1", "b");
    const rows = moveTo(model);
    assert.ok(rows, "Move to submenu present");
    writeFileSync(join(output, "move-to-menu.txt"), `${picture(model.items).join("\n")}\n`);
    assert.ok(!rows.some((row) => row.title === "Profile"), "no Profile level");
    const firstProfile = rows.findIndex((row) => row.id === `profile:${state.order[0]}`);
    assert.ok(firstProfile > 0 && rows[firstProfile - 1].separator, "a separator before the profiles");
    const profiles = rows.slice(firstProfile, firstProfile + state.order.length);
    assert.deepEqual(profiles.map((row) => [row.id, row.title, row.checked, row.enabled]),
      state.order.map((id, index) => [`profile:${id}`, state.names[index], id === state.own, id !== state.own]));
    assert.deepEqual(shape(rows.slice(firstProfile + state.order.length)), ["New Profile…", "—", "Window"]);
    assert.equal(rows.at(-1).enabled, true);
    return { shape: shape(rows), picture: picture(model.items) };
  });

  await check("Choosing a profile from Move to still moves the tab", async () => {
    const target = state.order.find((id) => id !== state.own);
    const model = await tabMenu("w1", "b", `profile:${target}`);
    assert.equal(model.accepted, true, JSON.stringify(model));
    const moved = await until("tab moved", async () => {
      const s = await run("const s = ac.store.getState(); return Object.values(s.tabs).filter((t) => t.title === 'B' || t.url === 'about:blank#b').map((t) => t.profileId);");
      return s.includes(target) ? s : null;
    });
    return { target, moved };
  });

  await check("In incognito Move to has no profile items and no separator for them", async () => {
    const before = await run("return ac.store.getState().windowOrder;");
    await run('return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "newIncognitoWindow", null);');
    const found = await until("incognito window", async () => {
      const s = await run("const s = ac.store.getState(); return { order: s.windowOrder, windows: s.windows };");
      const id = s.order.find((id) => !before.includes(id) && s.windows[id]?.incognito);
      return id && s.windows[id].tabIds.length ? { id, tabId: s.windows[id].tabIds[0] } : null;
    });
    const model = await tabMenu(found.id, found.tabId);
    const rows = moveTo(model);
    writeFileSync(join(output, "move-to-menu-incognito.txt"), `${picture(model.items).join("\n")}\n`);
    assert.ok(rows, "Move to submenu present");
    assert.ok(!rows.some((row) => row.id?.startsWith("profile:") || row.title === "Profile"), "no profile items");
    assert.equal(rows.at(-1).title, "Window");
    assert.equal(rows.at(-1).enabled, false, "Window keeps its incognito rule");
    for (let index = 1; index < rows.length; index++) assert.ok(!(rows[index].separator && rows[index - 1].separator), "no doubled separator");
    return { shape: shape(rows), picture: picture(model.items) };
  });
} catch (error) {
  evidence.push({ name: "run", passed: false, error: String(error?.stack ?? error) });
  results.push(false);
  console.log(`FAIL run: ${error?.message ?? error}`);
  save();
} finally {
  if (app) await app.quit().catch(() => {});
}
const passed = results.filter(Boolean).length;
console.log(`${passed}/${results.length} passed. Evidence: ${join(output, "evidence.json")}`);
process.exit(passed === results.length && results.length > 0 ? 0 : 1);
