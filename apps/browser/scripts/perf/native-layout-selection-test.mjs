import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const bench = args.includes("--bench");
const geometryOnly = args.includes("--geometry-only");
const [appArg, outputArg] = args.filter(value => !["--bench", "--geometry-only"].includes(value));
assert.ok(appArg && outputArg, "usage: node native-layout-selection-test.mjs <trace-enabled dev app> <fresh output directory> [--bench] [--geometry-only]");
const output = resolve(outputArg);
mkdirSync(output, { recursive: true });
const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html" });
  response.end(`<!doctype html><title>${request.url}</title><body style="background:#246;color:white">${request.url}</body>`);
});
await new Promise(done => server.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${server.address().port}`;
const evidence = { checks: [], samples: [] };
let app;
const connections = [];
let sequence = 0;
async function run(body) {
  if (!bench) return app.eval(body, { timeout: 10000 });
  const id = `selection-${process.pid}-${++sequence}`;
  writeFileSync(join(output, "data", "bench-cmd.js"), `// ${id}\n${body}`);
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    assert.ok(app.alive, "bench command: instance exited");
    let value;
    try { value = JSON.parse(readFileSync(join(output, "data", "bench-result.json"), "utf8")); } catch {}
    if (value?.id === id) {
      assert.equal(value.error, undefined, `bench command: ${value.error}`);
      return value.result;
    }
    await sleep(25);
  }
  throw new Error(`bench command deadline: ${body.slice(0, 80)}`);
}
const read = () => run('return JSON.parse(globalThis.expo.modules.SolaraWindowShell.layoutTrace(true));');
async function until(label, readValue, accepts) {
  const deadline = Date.now() + 20000;
  let last;
  while (Date.now() < deadline) {
    assert.ok(app.alive, `${label}: instance exited`);
    last = await readValue();
    if (accepts(last)) return last;
    await sleep(50);
  }
  throw new Error(`${label}: deadline; last ${JSON.stringify(last)}`);
}
try {
  app = await launch(resolve(appArg), {
    data: join(output, "data"), onboarded: true, keepData: true,
    session: session({
      windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
      tabs: ["a", "b", "c"].map(id => ({ id, url: `${base}/${id}`, title: id })),
      settings: { sleepInactiveTabs: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
    }),
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: "1", SOLARA_LAYOUT_TRACE: "1", SOLARA_LAYOUT_STACKS: process.env.SOLARA_LAYOUT_STACKS ?? "0" },
    ...(bench ? { js: "none", ready: false } : {
      ready: 'return !!ac.store.getState().windows.w1 && typeof globalThis.expo.modules.SolaraWindowShell?.layoutTrace === "function";',
    }),
  });
  if (bench) {
    await until("bench channel boot", async () => {
      try { return JSON.parse(readFileSync(join(output, "data", "bench-boot.json"), "utf8")); } catch { return null; }
    }, Boolean);
    assert.equal(await run('return !!ac.store.getState().windows.w1 && typeof globalThis.expo.modules.SolaraWindowShell?.layoutTrace === "function";'), true);
  }
  for (const id of ["a", "b", "c", "b"]) {
    await run(`globalThis.expo.modules.SolaraWindowShell.layoutTrace(true);ac.store.getState().activate(${JSON.stringify(id)});return true;`);
    const connection = await app.page(target => target.url === `${base}/${id}`, { timeout: 20000 });
    connections.push(connection);
    await connection.eval('document.readyState === "complete"');
    const events = [];
    await until(`${id} native navigation surface`, async () => { events.push(...await read()); return events; },
      rows => rows.some(row => row.stage === "navigationPlace" && row.detail === `w1 ${id}`));
    evidence.samples.push({ selected: id, events });
  }
  await sleep(500);
  await read();
  await run('ac.store.getState().updateTab("b",{title:"selected page changed"});return true;');
  const events = [];
  await until("selected-page commit projection", async () => { events.push(...await read()); return events; },
    rows => rows.some(row => row.stage === "navigationPlace" && row.detail === "w1 b") && rows.some(row => row.stage === "layout" && row.phase === "end"));
  await sleep(250);
  events.push(...await read());
  evidence.samples.push({ selected: "b", events });
  const placed = [...new Set(events.filter(row => row.stage === "navigationPlace").map(row => row.detail))].sort();
  if (!geometryOnly) {
    assert.deepEqual(placed, ["w1 b"], "a selected-page commit must not reconfigure retained hidden navigation surfaces");
    evidence.checks.push("selected-page commits place only visible navigation surfaces");
    console.log("PASS selected-page commits place only visible navigation surfaces");
    await run('return Promise.all(Array.from({length:3},()=>globalThis.expo.modules.SolaraSettings.publish("pane.overlays",JSON.stringify({windows:{w1:{}}}))));');
    const repeated = [];
    await until("same-revision feature relayouts", async () => { repeated.push(...await read()); return repeated; },
      rows => rows.filter(row => row.stage === "navigationPlace" && row.detail === "w1 b").length >= 3);
    events.push(...repeated);
    const configured = events.filter(row => row.stage === "navigationConfigure");
    assert.ok(configured.length > 0, "a committed revision configures its selected navigation surface");
    assert.ok(configured.every(row => row.detail.startsWith("w1 b ")), "hidden navigation surfaces retain their configuration");
    const configurations = configured.map(row => row.detail);
    assert.equal(new Set(configurations).size, configurations.length, "a navigation surface configures once per store and presentation revision");
    evidence.checks.push("navigation configuration is cached by committed and presentation revision");
    console.log("PASS navigation configuration is cached by committed and presentation revision");
  }
  function endpointCheck(shell) {
    const layout = shell.layout;
    const expectedHeader = layout.sidebarHeader;
    const actualHeader = layout.actual?.sidebarHeader;
    const ignoredEmptyEndpoints = [];
    if (expectedHeader?.length === 4 && actualHeader?.length === 4
      && expectedHeader[3] === 0 && actualHeader[3] === 0
      && expectedHeader[0] === actualHeader[0] && expectedHeader[2] === actualHeader[2]
      && (layout.errors.sidebarHeader ?? 0) > 0) {
      ignoredEmptyEndpoints.push({ name: "sidebarHeader", expected: expectedHeader, actual: actualHeader, error: layout.errors.sidebarHeader });
    }
    const ignored = new Set(ignoredEmptyEndpoints.map(endpoint => endpoint.name));
    const maxError = Math.max(0, ...Object.entries(layout.errors).filter(([name]) => !ignored.has(name)).map(([, error]) => error));
    const missing = (layout.missing ?? []).filter(name => {
      if (/^(page|pane|viewport):/.test(name) || name === "sidebarHeader") return true;
      const expected = layout[name];
      return !expected || expected[2] > 0 && expected[3] > 0;
    });
    return { maxError, missing, ignoredEmptyEndpoints };
  }
  async function geometry(label, accepts = () => true) {
    let lastShell;
    let shell;
    try {
      shell = await until(label, async () => {
        lastShell = await run('return globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse);');
        return lastShell;
      }, value => value?.nativeLayout && value.layout?.current && accepts(value.layout) && endpointCheck(value).maxError <= 0.5
        && endpointCheck(value).missing.length === 0
        && Object.entries(value.split?.leaves ?? {}).every(([id, leaf]) => {
          const overlay = value.split?.overlays?.[id];
          return !overlay || overlay.hidden || leaf.window.every((number, index) => Math.abs(number - overlay.window[index]) <= 0.5);
        }));
    } catch (error) {
      evidence.samples.push({ label, failed: true, shell: lastShell });
      throw error;
    }
    const checked = endpointCheck(shell);
    for (const endpoint of checked.ignoredEmptyEndpoints) {
      assert.equal(endpoint.expected[3], 0, `${label}: excluded header has no expected height`);
      assert.equal(endpoint.actual[3], 0, `${label}: excluded header has no actual height`);
      assert.equal(endpoint.expected[0], endpoint.actual[0], `${label}: excluded header differs only in its vertical origin`);
      assert.equal(endpoint.expected[2], endpoint.actual[2], `${label}: excluded header width matches`);
    }
    assert.ok(checked.maxError <= 0.5, `${label}: active native endpoints ${JSON.stringify(shell.layout.errors)}`);
    assert.deepEqual(checked.missing, [], `${label}: required native endpoints exist`);
    for (const [id, leaf] of Object.entries(shell.split?.leaves ?? {})) {
      const overlay = shell.split?.overlays?.[id];
      if (!overlay || overlay.hidden) continue;
      assert.ok(leaf.window.every((value, index) => Math.abs(value - overlay.window[index]) <= 0.5), `${label}: ${id} page and overlay align`);
    }
    evidence.samples.push({ label, shell, ignoredEmptyEndpoints: checked.ignoredEmptyEndpoints });
    evidence.checks.push(label);
    console.log(`PASS ${label}`);
  }
  await geometry("equivalent selected-page placement", layout => layout.selectedTabId === "b");
  await run('ac.store.getState().setWindowSidebar("w1",{sidebarWidth:260});return true;');
  await geometry("sidebar resize keeps page toolbar and overlay aligned", layout => layout.sidebar?.[2] === 260);
  await run('ac.store.getState().setWindowSidebar("w1",{sidebarIconsOnly:true});return true;');
  await geometry("rail toolbar moves onto the window frame", layout => layout.sidebar?.[2] < 100);
  await run('ac.store.getState().activate("c");return true;');
  await geometry("rail tab switch places the replacement toolbar", layout => layout.selectedTabId === "c");
  await run('const s=ac.store.getState();s.setWindowSidebar("w1",{sidebarIconsOnly:false});s.createSplit(["a","b"]);s.activate("a");return true;');
  await geometry("split page and overlay placement", layout => layout.panes.a && layout.panes.b);
  await run('ac.store.getState().activate("b");return true;');
  await geometry("split selection keeps both page placements", layout => layout.selectedTabId === "b" && layout.panes.a && layout.panes.b);
  await run('ac.store.getState().toggleTabLayout("w1");return true;');
  await geometry("top tabs keep split toolbar and overlay placement", layout => layout.topTabs);
  await run('const s=ac.store.getState();s.toggleTabLayout("w1");s.removeTabFromSplit("b");s.activate("c");return true;');
  await geometry("return from split restores the incoming toolbar", layout => !layout.topTabs && layout.selectedTabId === "c" && Object.keys(layout.panes).length === 1);
} finally {
  writeFileSync(join(output, "result.json"), JSON.stringify(evidence, null, 2));
  for (const connection of connections) connection.close();
  await app?.quit();
  await new Promise(done => server.close(done));
}
