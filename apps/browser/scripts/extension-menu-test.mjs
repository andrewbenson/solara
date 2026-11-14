import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg] = process.argv.slice(2);
if (!appArg || !scratchArg || resolve(appArg).startsWith("/Applications/")) throw new Error("usage: node extension-menu-test.mjs <Debug app> <scratch>");
const scratch = resolve(scratchArg);
mkdirSync(scratch, { recursive: true });
const rep = reporter(join(scratch, "extension-menu-test.log"), { name: "extension-menu-test" });
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1200, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "Blank" }],
  settings: { tabLayout: "top", addressBar: "toolbar", searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});
const helpers = `
const E = ac.extensions;
const S = () => ac.store.getState();
const X = globalThis.expo.modules.SolaraExtensions;
const T = globalThis.expo.modules.SolaraToolbar;
const C = globalThis.expo.modules.SolaraCEF;
const D = globalThis.expo.modules.SolaraShell;
const ext = (id) => E.useExtensions.getState().lists[""]?.find((item) => item.id === id);
`;
let app;
const installed = [];
const run = (body, timeout = 10000) => app.eval(`${helpers}\n${body}`, { timeout });
const until = async (name, body, accept = Boolean, timeout = 8000) => {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error(`${name}: app exited`);
    last = await run(body);
    if (accept(last)) return last;
    await sleep(80);
  }
  throw new Error(`${name}: timed out ${JSON.stringify(last)}`);
};
const menuRead = () => run('return D.devContextMenu("read", null);');
const menuArm = (choice = null) => run(`return D.devContextMenu("arm", ${JSON.stringify(choice)});`);
const menuWait = () => until("native menu model", 'return D.devContextMenu("read", null);', (value) => Array.isArray(value.items));
const rows = (value) => value.items.map((row) => row.separator ? "separator" : `${row.id}:${row.title}:${row.enabled}`);
let windowNumber;
const act = (action) => run(`return C.devWindow(${windowNumber}, ${JSON.stringify(action)});`);
const toolbar = () => run('return T.devToolbar("w1", "a").then(JSON.parse);');
const nativeButton = async (id) => until(`native ${id}`, 'return T.devToolbar("w1", "a").then(JSON.parse);', (value) => value.extensions?.some((item) => item.id === id)).then((value) => value.extensions.find((item) => item.id === id));
const click = async (button, right = false) => {
  const [x, y, w, h] = button.frame;
  const point = [Math.round(x + w / 2), Math.round(y + h / 2)];
  const hit = String(await act(`hit:${point.join(",")}`));
  assert.match(hit, /ToolbarButtonView/, `native extension hit ${hit}`);
  await act(`click:${point.join(",")}${right ? ",right" : ""}`);
};
const context = async (id, choice = null) => {
  await menuArm(choice);
  await click(await nativeButton(`ext:${id}`), true);
  const model = await menuWait();
  assert.equal(model.accepted, true, `native menu accepts ${choice}`);
  return model;
};
try {
  app = await launch(resolve(appArg), { data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    ready: 'return !!ac.store.getState().windows.w1 && !!ac.extensions;' });
  assert.equal(await run('return typeof D.devContextMenu;'), "function", "Debug native menu seam exists");
  windowNumber = await until("browser window", 'return C.chromeWindows().then((windows) => windows.find((window) => window.hasRoot && window.visible)?.window ?? null);');
  await act("fakeActiveClicks");
  for (let index = 0; index < 4; index++) {
    const directory = join(scratch, `fixture-${index}`);
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "manifest.json"), JSON.stringify({ manifest_version: 3, name: `Menu Fixture ${index}`, version: "1.0", action: { default_popup: "popup.html" }, options_page: "options.html", side_panel: { default_path: "panel.html" }, permissions: ["sidePanel"] }));
    for (const name of ["popup", "options", "panel"]) writeFileSync(join(directory, `${name}.html`), `<title>${name}</title><body style="margin:0;width:180px;height:80px">${name}</body>`);
    const result = await run(`return X.install(${JSON.stringify(directory)}, "");`);
    assert.ok(result?.id && !result.error, JSON.stringify(result));
    installed.push(result.id);
  }
  await run('return E.refreshExtensions("").then(() => true);');
  for (const id of installed) await run(`return E.setPinned("", ${JSON.stringify(id)}, true).then(() => true);`);
  const id = installed[0];
  await rep.check("native-context-model", async () => {
    const model = await context(id);
    assert.deepEqual(model.items.map((item) => item.separator ? "separator" : item.id), ["name", "separator", "options", "sidePanel", "pin", "enable", "separator", "remove", "manage"]);
    assert.equal(model.items[0].enabled, false);
    assert.equal(model.items.find((item) => item.id === "pin").title, "Unpin from Toolbar");
    assert.equal(model.items.find((item) => item.id === "pin").image, true);
    const shot = join(scratch, "native-extension-toolbar.png");
    assert.equal(await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shot)});`, 20000), true);
    return { rows: rows(model), capture: shot };
  });
  await rep.check("disabled-native-choice-refused", async () => {
    await menuArm("name");
    await click(await nativeButton(`ext:${id}`), true);
    const model = await menuWait();
    assert.equal(model.accepted, false);
    return { accepted: model.accepted };
  });
  await rep.check("context-unpin-and-repin", async () => {
    await context(id, "pin");
    await until("unpinned", `return ext(${JSON.stringify(id)})?.pinned === false;`);
    await menuArm("pin");
    await run(`E.showExtensionMenu("w1", ext(${JSON.stringify(id)})); return true;`);
    assert.equal((await menuWait()).accepted, true);
    await until("repinned", `return ext(${JSON.stringify(id)})?.pinned === true;`);
    return { pinned: true };
  });
  await rep.check("context-side-panel-toggle", async () => {
    await context(id, "sidePanel");
    await until("side panel", `return E.useExtensions.getState().sidePanels.w1?.extensionId === ${JSON.stringify(id)};`);
    const model = await context(id, "sidePanel");
    assert.equal(model.items.find((item) => item.id === "sidePanel").title, "Close Side Panel");
    await until("side panel closed", 'return !E.useExtensions.getState().sidePanels.w1;');
    return { toggled: true };
  });
  await rep.check("context-options", async () => {
    await context(id, "options");
    const opened = await until("options tab", `return Object.values(S().tabs).find((tab) => tab.url?.includes(${JSON.stringify(`${id}/options.html`)}))?.id ?? null;`);
    await run(`S().closeTab(${JSON.stringify(opened)}); S().activate("a"); return true;`);
    return { opened };
  });
  await rep.check("context-enable-toggle", async () => {
    await context(id, "enable");
    await until("disabled extension", `return ext(${JSON.stringify(id)})?.enabled === false;`);
    await menuArm("enable");
    await run(`E.showExtensionMenu("w1", ext(${JSON.stringify(id)})); return true;`);
    const model = await menuWait();
    assert.equal(model.items.find((item) => item.id === "enable").title, "Turn On");
    await until("enabled extension", `return ext(${JSON.stringify(id)})?.enabled === true;`);
    return { enabled: true };
  });
  await rep.check("native-overflow-menu-and-pin-sheet", async () => {
    await run('S().updateSettings({ addressBar: "sidebar", tabLayout: "sidebar" }); return true;');
    const sidebar = await until("sidebar overflow", 'return globalThis.expo.modules.SolaraSidebarAddressBar.sample("w1").then((json) => json ? JSON.parse(json) : null);', (value) => value?.["field.sample"]?.buttons?.some((item) => item.id === "ext-overflow"));
    const overflow = sidebar["field.sample"].buttons.find((item) => item.id === "ext-overflow");
    const [fx, fy] = sidebar.field;
    const [bx, by, bw, bh] = overflow.frame;
    const button = { frame: [sidebar.frame[0] + fx + bx, sidebar.frame[1] + fy + by, bw, bh] };
    await menuArm();
    await click(button);
    const model = await menuWait();
    assert.deepEqual(model.items.filter((item) => item.id?.startsWith("open:")).map((item) => item.id).sort(), installed.map((value) => `open:${value}`).sort());
    assert.deepEqual(model.items.slice(-3).map((item) => item.id), ["pin", "manage", "add"]);
    await menuArm("pin");
    await click(button);
    assert.equal((await menuWait()).accepted, true);
    await until("native pin sheet requested", 'return E.useExtensions.getState().pinDialog?.windowId === "w1";');
    await run('E.useExtensions.setState({ pinDialog: null }); return true;');
    return { rows: rows(model), point: button.frame };
  });
  await rep.check("native-snapshot-consistent", async () => {
    const state = await app.snapshot();
    assert.equal(state.consistent, true);
    writeFileSync(join(scratch, "native-snapshot.json"), JSON.stringify(state, null, 2));
    return { consistent: true, windows: state.windows.length };
  });
} finally {
  if (app) {
    await run('return D.devContextMenu("clear", null);').catch(() => null);
    await run('E.closeExtensionPopup(); E.closeSidePanel("w1"); E.useExtensions.setState({ pinDialog: null }); return true;').catch(() => null);
    for (const id of installed) await run(`return X.uninstall(${JSON.stringify(id)}, "");`).catch(() => null);
    await app.quit();
  }
}
process.exitCode = rep.summary() ? 0 : 1;
