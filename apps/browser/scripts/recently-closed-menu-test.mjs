import assert from "node:assert/strict";
import { resolve, join } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appPath, output, mode] = process.argv.slice(2);
assert.ok(appPath && output, "usage: node recently-closed-menu-test.mjs <Debug app> <fresh output directory>");
const layout = process.env.SOLARA_NATIVE_WINDOW_LAYOUT ?? "1";
const archived = { profileId: "default", url: "about:blank#archive", title: "Archived Tab" };
const app = await launch(resolve(appPath), {
  data: join(resolve(output), "data"), fresh: true, keepData: true, onboarded: true,
  env: { SOLARA_NATIVE_WINDOW_LAYOUT: layout },
  session: session({
    tabs: [{ id: "a" }, { id: "b" }],
    settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
    closedTabs: [{ kind: "tab", id: "older", tab: archived, windowId: "w1", index: 0, closedAt: 10 }],
    closedWindows: [{
      kind: "window", id: "archived-window", window: { profileId: "default", sidebarOpen: true },
      tabs: [{ ...archived, active: true }], groups: [], closedAt: 20,
    }],
    closedGroups: [{
      kind: "group", id: "archived-group", group: { id: "group", name: "Archived Group", pinned: false },
      tabs: [archived], windowId: "w1", index: 0, closedAt: 30,
    }],
  }),
  ready: `return !!ac.commandHandlers && !!expo.modules.SolaraApp.devMenuItems &&
    ac.shell.windowIds().then((ids) => ids.includes("w1"));`,
});

const menu = (path = null) => app.eval(`return expo.modules.SolaraApp.devMenuItems("History", ${JSON.stringify(path)});`);
const titles = (rows) => rows.map(({ title }) => title);
async function waitFor(label, read, matches) {
  const deadline = Date.now() + 8000;
  let last;
  do {
    assert.ok(app.alive, "fixture exited");
    last = await read();
    if (matches(last)) return last;
    await sleep(100);
  } while (Date.now() < deadline);
  assert.fail(`${label}: ${JSON.stringify(last)}`);
}

try {
  assert.equal(await app.eval('return expo.modules.SolaraWindowShell.nativeLayout("w1");'), layout === "1");
  const initial = await app.eval("ac.commandHandlers.setEnabled(false); return ac.commandHandlers.stats();");
  const rows = await waitFor("archived rows", menu, (rows) => titles(rows).includes("Archived Group (1 Tab)"));
  assert.deepEqual(titles(rows).slice(3), [
    "Recently Closed", "Window (1 Tab)", "Archived Tab", "-", "Recently Closed Groups", "Archived Group (1 Tab)",
  ]);
  assert.equal(rows.find(({ title }) => title === "Show History…").key, "y");

  const restored = await menu(["Archived Tab"]);
  assert.ok(restored.every(({ error }) => !error));
  await waitFor("restored tab leaves History", menu, (rows) => !titles(rows).includes("Archived Tab"));
  await waitFor("restored tab", () => app.eval("return Object.keys(ac.store.getState().tabs).length;"), (count) => count === 3);

  await app.eval('return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeTab", null);');
  const reclosed = await waitFor("restored page archived again", () => app.eval(`
    const tab = ac.store.getState().closedTabs.find(({ tab }) => tab.url === "about:blank#archive")?.tab;
    return tab ? tab.title || tab.url : null;
  `), Boolean);
  const changed = await waitFor("native close enters History", menu, (rows) => titles(rows).includes(reclosed));
  assert.deepEqual(titles(changed).slice(3, 6), ["Recently Closed", reclosed, "Window (1 Tab)"]);
  assert.equal(changed.find(({ title }) => title === "Show History…").key, "y");
  if (mode !== "--baseline") {
    await app.eval(`
      return expo.modules.SolaraShell.setMenuState({ recentlyClosed: [{ id: "stale", title: "Stale JS Row" }] });
    `);
    assert.deepEqual(titles(await menu()), titles(changed));
  }
  assert.deepEqual(await app.eval("return ac.commandHandlers.stats();"), initial);
  console.log(`PASS History menu hydration, native restore and close, and shortcut retention in layout ${layout}`);
} finally {
  await app.quit();
}
