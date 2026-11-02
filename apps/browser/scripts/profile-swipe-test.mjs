import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { appendFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { inflateSync } from "node:zlib";
import { launch, listenerPids, parsePort, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
if (args.includes("--self-test")) {
  const module = fileURLToPath(new URL("../../../scripts/lib/instance.mjs", import.meta.url));
  process.exit(spawnSync(process.execPath, [module, "--self-test"], { stdio: "inherit" }).status ?? 1);
}
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error("usage: node profile-swipe-test.mjs <Debug Solara.app> [--port=<DevTools port>] [--keep-data] [--stale-window] [--only=<case name substring>] [--bundle-port=<Metro port>] | --self-test");
  process.exit(2);
}
const app = resolve(appArg);
const bundlePort = args.find((a) => a.startsWith("--bundle-port="))?.split("=")[1];
if (bundlePort) assert.match(bundlePort, /^\d{2,5}$/);
const portArg = args.find((a) => a.startsWith("--port="))?.slice("--port=".length);
let port;
try { port = portArg && parsePort(portArg); } catch (error) {
  console.error(`--port: ${error.message}`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const stale = args.includes("--stale-window");
const only = args.find((a) => a.startsWith("--only="))?.slice("--only=".length).toLowerCase();
let matched = 0;
const scratch = mkdtempSync(join(tmpdir(), "ac-profile-swipe-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "profile-swipe.log"), { name: "profile-swipe-test" });
const evidence = { app, data, stale, cases: [] };
let owned;
function ownedDeath() {
  if (!owned || !owned.exited) return null;
  evidence.death ??= { pid: owned.pid, detectedAt: new Date().toISOString(), alive: false,
    portListeners: (() => { try { return listenerPids(owned.port); } catch (e) { return String(e); } })() };
  return Object.assign(new Error(`owned app pid ${owned.pid} died`), { appDied: true });
}
function assertOwnedAlive() {
  const death = ownedDeath();
  if (death) throw death;
}
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  if (req.url.startsWith("/history")) return res.end(`<!doctype html><title>${req.url}</title><h1>${req.url}</h1>`);
  res.end('<!doctype html><title>Swipe scroll fixture</title><body style="margin:0"><div style="width:2600px;height:4000px;background:linear-gradient(120deg,#ffd9dd,#addbff)">Native scroll fixture</div>');
});

const tab = (id, profileId) => ({ id, profileId, url: "solara://newtab", title: "New Tab" });
const fixture = session({ profiles: ["Personal", "Work"], tabs: [tab("t1", "default"), tab("t2", "work")] });

const ac = async (body, timeout = 15000) => {
  const result = await owned.eval(`return Promise.resolve((function(ac) {${body}\n})(ac)).then(value => {
    const negativeZeroPaths = [];
    const visit = (current, path) => {
      if (Object.is(current, -0)) negativeZeroPaths.push(path);
      else if (current && typeof current === "object") {
        for (const key of Object.keys(current)) visit(current[key], [...path, key]);
      }
    };
    visit(value, []);
    return { value: value ?? null, negativeZeroPaths };
  });`, { timeout });
  let value = result.value;
  for (const path of result.negativeZeroPaths) {
    if (!path.length) value = -0;
    else {
      const parent = path.slice(0, -1).reduce((current, key) => current[key], value);
      parent[path.at(-1)] = -0;
    }
  }
  return value;
};
const snapshotFields = ["windows.profileId", "windows.pager", "windows.profilePager", "windows.selectedTabId",
  "root.chromeWindows", "root.profileOrder", "tabs.url", "root.haptics"];
const untilSnapshot = async (what, accept, ms = 2500, options = {}) => {
  const end = Date.now() + Math.min(ms, 2500);
  let last;
  const remaining = () => {
    const timeout = end - Date.now();
    assert.ok(timeout > 0, `${what}: cross-check deadline`);
    return timeout;
  };
  const requestBudget = () => {
    const timeout = remaining();
    assert.ok(timeout >= 1000, `${what}: minimum request budget`);
    return timeout;
  };
  while (Date.now() < end) {
    assertOwnedAlive();
    last = await owned.snapshot({ fields: snapshotFields, ...options }, { timeout: requestBudget() });
    if (Date.now() >= end) break;
    if (last.consistent && await accept(last, requestBudget) && Date.now() < end) return last;
    if (Date.now() < end) await sleep(Math.min(25, remaining()));
  }
  throw new Error(`${what}: native snapshot did not match (${JSON.stringify(last)})`);
};
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
const crossValue = async (what, read, value, options = {}, ms = 2500) => {
  const snapshot = await untilSnapshot(what, (snapshot) => same(read(snapshot), value), ms, options);
  assert.deepEqual(read(snapshot), value, what);
};
const crossRead = async (what, read, current, options = {}, ms = 2500) => {
  let js;
  await untilSnapshot(what, async (snapshot, remaining) => {
    js = await current(remaining());
    return same(read(snapshot), js);
  }, ms, options);
  return js;
};
const profile = () => ac('return ac.store.getState().windows.w1.profileId;');
const crossProfile = () => crossRead("selected profile", (snapshot) => snapshot.windows.find((window) => window.id === "w1")?.profileId,
  (timeout) => ac('return ac.store.getState().windows.w1.profileId;', timeout));
const crossAck = () => crossRead("native selection acknowledgment", (snapshot) => snapshot.windows.find((window) => window.id === "w1")?.profilePager?.ack,
  (timeout) => ac('return globalThis.expo.modules.SolaraProfilePager.describe("w1").then(value => JSON.parse(value).ack);', timeout));
const crossOrder = () => crossRead("native profile order", (snapshot) => snapshot.profileOrder,
  (timeout) => ac('return ac.store.getState().profileOrder;', timeout));
const crossFixture = () => crossRead("native scroll fixture selection", (snapshot) => {
  const window = snapshot.windows.find((window) => window.id === "w1");
  return { profileId: window?.profileId, activeTabId: window?.selectedTabId };
}, (timeout) => ac('const window=ac.store.getState().windows.w1; return {profileId:window.profileId,activeTabId:window.activeTabIds.default};', timeout));
let pendingSimulations = [];
let parityChecked = false;
const saveSimulation = (result) => {
  pendingSimulations.push(result);
  assert.ok(pendingSimulations.length <= 8, "deferred swipe traces fit native history");
  return result;
};
const pagerFields = ["profileId", "count", "selected", "position", "phase", "selectionSequence", "areas", "propAck"];
const pagerValues = (value) => Object.fromEntries(pagerFields.filter((key) => value?.[key] !== undefined).map((key) => [key, value[key]]));
const crossPager = async () => {
  let js;
  const snapshot = await untilSnapshot("native pager state", async (snapshot, remaining) => {
    js = await ac('return globalThis.expo.modules.SolaraSwipe.devPagerState("w1");', remaining());
    assert.ok(js, "retained JS pager state");
    const native = snapshot.windows.find((window) => window.id === "w1")?.pager;
    return !!native && pagerFields.every((key) => js[key] === undefined || (key === "position" ? Math.abs(native[key] - js[key]) <= 0.003 : native[key] === js[key]));
  });
  const native = snapshot.windows.find((window) => window.id === "w1").pager;
  for (const [key, value] of Object.entries(pagerValues(js))) {
    if (key === "position") assert.ok(Math.abs(native.position - value) <= 0.003, "native pager position");
    else assert.deepEqual(native[key], value, `native pager ${key}`);
  }
  return js;
};
const traceValues = (result) => ({ startNs: result.startNs ?? null, where: result.where,
  events: (result.events ?? []).slice(0, 128).map((event) => ({
    ...Object.fromEntries(["phase", "time", "atMs", "lateMs", "swallowed", "monitorSwallowed", "state"].filter((key) => event[key] !== undefined).map((key) => [key, event[key]])),
    ...(event.error !== undefined ? { error: String(event.error).slice(0, 512) } : {}),
  })),
  acks: (result.acks ?? []).filter((ack) => ["begin", "emit", "hitRouting", "reject"].includes(ack.diag)).slice(0, 256).map((ack) => ({
    ...Object.fromEntries(["diag", "phase", "velocity", "window", "fallback", "reason"].filter((key) => ack[key] !== undefined).map((key) => [key, ack[key]])),
    ...Object.fromEntries(["raw", "hit"].filter((key) => Array.isArray(ack[key])).map((key) => [key, ack[key].slice(0, 16).map((entry) => ({ class: entry.class ?? null }))])),
    ...(Array.isArray(ack.targets) ? { targets: ack.targets.slice(0, 16).map((entry) => ({ miss: typeof entry.miss === "string" ? entry.miss.slice(0, 512) : null })) } : {}),
  })) });
const crossSimulation = async (result) => {
  const end = Date.now() + 9000;
  const snapshot = async (options = {}) => {
    assertOwnedAlive();
    assert.ok(end - Date.now() >= 1000, "swipe event trace cross-check deadline");
    const value = await owned.snapshot({ fields: ["root.swipeSimulation"], ...options }, { timeout: 1000 });
    assert.ok(Date.now() < end, "swipe event trace cross-check deadline");
    assert.ok(value.consistent, "consistent swipe event trace snapshot");
    return value.swipeSimulation;
  };
  const expected = traceValues(result);
  assert.match(expected.startNs, /^[0-9]{1,32}$/, "saved swipe startNs");
  const completed = (await snapshot()).completedTraces;
  assert.ok(Array.isArray(completed) && completed.length <= 8, "bounded completed swipe metadata");
  const matches = completed.filter((trace) => trace.startNs === expected.startNs);
  assert.equal(matches.length, 1, "saved swipe trace must be retained and unambiguous");
  const identity = matches[0];
  assert.ok(Number.isSafeInteger(identity.sequence) && identity.sequence > 0, "completed swipe sequence");
  assert.match(identity.completedNs, /^[0-9]{1,32}$/, "completed swipe timestamp");
  const pageCount = Math.max(1, Math.ceil(Math.max(expected.events.length, expected.acks.length) / 8));
  for (let page = 0; page < pageCount; page++) {
    const simulation = await snapshot({ swipeTracePage: page,
      swipeTraceStartNs: identity.startNs, swipeTraceSequence: identity.sequence });
    assert.equal(simulation.traceAbsent, false, "pinned swipe trace is retained");
    const matches = simulation.completedTraces.filter((trace) => trace.startNs === identity.startNs);
    assert.equal(matches.length, 1, "pinned swipe trace remains unambiguous");
    assert.deepEqual(matches[0], identity, "pinned swipe metadata is immutable");
    const trace = simulation.trace;
    assert.ok(trace, "pinned swipe trace page exists");
    assert.equal(trace.startNs, identity.startNs, "pinned swipe startNs");
    assert.equal(trace.sequence, identity.sequence, "pinned swipe sequence");
    assert.equal(trace.completedNs, identity.completedNs, "pinned swipe completion");
    assert.deepEqual(trace, {
      ...expected, sequence: identity.sequence, completedNs: identity.completedNs,
      page, pageCount, eventCount: expected.events.length, ackCount: expected.acks.length,
      events: expected.events.slice(page * 8, page * 8 + 8), acks: expected.acks.slice(page * 8, page * 8 + 8),
    }, `native swipe event trace page ${page}`);
  }
  return result;
};
async function waitProfile(expected) {
  for (let start = Date.now(); Date.now() - start < 1800;) {
    if (await profile() === expected) return;
    await sleep(25);
  }
  assert.equal(await profile(), expected, "profile should switch within 1.8s");
}
async function reset() {
  await ac('ac.store.getState().switchProfile("w1", "default"); return true;');
  await waitProfile("default");
  await sleep(250);
}
const windows = () => ac('return globalThis.expo.modules.SolaraCEF.chromeWindows();');
const crossWindows = async () => {
  let js;
  await crossRead("native Chrome windows", (snapshot) => snapshot.chromeWindows, async (timeout) => {
    js = await ac('return globalThis.expo.modules.SolaraCEF.chromeWindows();', timeout);
    const fields = ["window", "hasRoot", "profile", "group", "visible"];
    return js.map((window) => Object.fromEntries(fields.filter((key) => window[key] !== undefined).map((key) => [key, window[key]])));
  });
  return js;
};
async function nativeWindow() {
  const all = await windows();
  return all.find((w) => w.hasRoot && w.profile === "" && w.group) ?? all.find((w) => w.hasRoot);
}
const action = (window, act) => ac(`return globalThis.expo.modules.SolaraCEF.devWindow(${window}, ${JSON.stringify(act)});`);
const gesture = (sign, wobble = false, drift = false) => [
  { phase: "began", dx: wobble ? sign : 0, dy: wobble ? 5 : 0 },
  { phase: "changed", dx: 18 * sign, dy: 1 },
  ...(drift ? [{ phase: "changed", dx: 0, dy: 50 }] : []),
  { phase: "changed", dx: 22 * sign, dy: 0 },
  { phase: "changed", dx: 22 * sign, dy: 0 },
  { phase: "ended", dx: 0, dy: 0 },
].map((step, index) => ({ ...step, atMs: index * 16, timestampMs: index * 16 }));
function flick(sign) {
  const swipe = gesture(sign);
  const end = swipe.at(-1).atMs;
  const momentum = [["momentumBegan", 20], ["momentum", 14], ["momentum", 8], ["momentum", 3], ["momentumEnded", 0]]
    .map(([phase, dx], i) => ({ phase, dx: dx * sign, dy: 0, atMs: end + 8 * (i + 1), timestampMs: end + 8 * (i + 1) }));
  return [...swipe, ...momentum].map((step) => ({ ...step, dispatch: "app" }));
}
function fixtureFidelity(steps, result) {
  const start = Number(result?.startNs) / 1e9;
  const events = (result?.events ?? []).filter((e) => !e.error);
  const decodedMs = events.map((e) => (e.time - start) * 1000);
  const intendedMs = steps.map((s) => s.timestampMs);
  const ended = (result?.acks ?? []).find((a) => a.diag === "emit" && a.phase === "ended");
  const errors = [];
  if (events.length !== steps.length) errors.push(`events ${events.length}, steps ${steps.length}`);
  intendedMs.forEach((ms, i) => {
    if (!(Math.abs((decodedMs[i] ?? NaN) - ms) <= 0.1)) errors.push(`step ${i} timestamp ${decodedMs[i]}ms, requested ${ms}ms`);
  });
  if (!ended) errors.push("no ended emit");
  else if (!(Math.abs(ended.velocity) >= 5)) errors.push(`ended velocity ${ended.velocity}`);
  return { intendedMs, decodedMs, endedVelocity: ended?.velocity ?? null,
    maxLateMs: Math.max(0, ...events.map((e) => e.lateMs ?? 0)), errors };
}
const simulate = async (steps, source) => saveSimulation(await ac(source
  ? `return globalThis.expo.modules.SolaraSwipe.devSimulate(120, 400, ${source}, ${JSON.stringify(steps)}, true);`
  : `return globalThis.acSwipe.sidebar("w1").devSimulate(${JSON.stringify(steps)}, {ignorePreference:true});`));
function alternatingGestures(count, gapMs = 112) {
  return Array.from({ length: count }, (_, n) => gesture(n % 2 ? 1 : -1).map((step) => ({
    ...step, atMs: step.atMs + n * gapMs, timestampMs: step.timestampMs + n * gapMs,
  }))).flat();
}
const PAGER_DEBUG = 'globalThis.expo.modules.SolaraProfilePager.describe("w1").then(JSON.parse)';
async function nativeBatch(steps, blockedMs = 0) {
  const js = await ac(`
    const simulation=globalThis.acSwipe.sidebar("w1").devSimulate(${JSON.stringify(steps)}, {ignorePreference:true});
    if (${blockedMs}) setTimeout(()=>{
      const until=performance.now()+${blockedMs}; while(performance.now()<until){}
    },20);
    return simulation.then(result=>new Promise(resolve=>setTimeout(()=>{
      globalThis.expo.modules.SolaraSwipe.devPagerState("w1").then(state=>${PAGER_DEBUG}.then(pager=>resolve({result,state,
        profile:ac.store.getState().windows.w1.profileId,pager})));
    },650)));
  `, 15000);
  saveSimulation(js.result);
  return js;
}
async function crossCase() {
  for (const simulation of pendingSimulations.splice(0)) await crossSimulation(simulation);
  await crossPager();
  await crossProfile();
  await crossWindows();
  await crossAck();
  await crossOrder();
  parityChecked = true;
}
async function test(name, fn) {
  if (only && !name.toLowerCase().includes(only)) return;
  matched++;
  pendingSimulations = [];
  parityChecked = false;
  let fatal = null;
  await rep.check(name, async () => {
    const result = await fn();
    if (!parityChecked) await crossCase();
    evidence.cases.push({ name, passed: true, result });
  }, {
    async onFail(error) {
      const death = error.appDied ? error : ownedDeath();
      const failed = { name, passed: false, error: String(error), ...(error.evidence ? { evidence: error.evidence } : {}) };
      evidence.cases.push(failed);
      if (!death) failed.windows = await windows().catch((e) => ({ error: String(e) }));
      if (error.evidence) rep.log("evidence:", JSON.stringify(error.evidence));
      fatal = death ?? ownedDeath();
      if (fatal) failed.appDeath = evidence.death;
    },
  });
  if (fatal) throw Object.assign(fatal, { reported: true });
}

function readPng(path) {
  const input = readFileSync(path);
  assert.deepEqual(input.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  let width = 0, height = 0, channels = 0;
  const chunks = [];
  for (let offset = 8; offset + 12 <= input.length;) {
    const length = input.readUInt32BE(offset);
    assert.ok(length <= input.length - offset - 12);
    const type = input.toString("ascii", offset + 4, offset + 8);
    if (type === "IHDR") {
      assert.equal(length, 13);
      width = input.readUInt32BE(offset + 8);
      height = input.readUInt32BE(offset + 12);
      channels = { 2: 3, 6: 4 }[input[offset + 17]];
      assert.equal(input[offset + 16], 8);
      assert.ok(channels);
      assert.deepEqual([...input.subarray(offset + 18, offset + 21)], [0, 0, 0]);
      assert.ok(width > 0 && height > 0 && width * height <= 16_777_216);
    } else if (type === "IDAT") chunks.push(input.subarray(offset + 8, offset + 8 + length));
    offset += 12 + length;
  }
  assert.ok(channels);
  const stride = width * channels;
  const raw = inflateSync(Buffer.concat(chunks), { maxOutputLength: (stride + 1) * height });
  assert.equal(raw.length, (stride + 1) * height);
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    assert.ok(filter <= 4);
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? pixels[y * stride + x - channels] : 0;
      const b = y ? pixels[(y - 1) * stride + x] : 0;
      const c = x >= channels && y ? pixels[(y - 1) * stride + x - channels] : 0;
      const predictor = a + b - c;
      const pa = Math.abs(predictor - a), pb = Math.abs(predictor - b), pc = Math.abs(predictor - c);
      const predicted = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      pixels[y * stride + x] = (raw[y * (stride + 1) + x + 1] + predicted) & 255;
    }
  }
  const rgba = Buffer.alloc(width * height * 4, 255);
  for (let pixel = 0; pixel < width * height; pixel++) {
    for (let channel = 0; channel < channels; channel++) rgba[pixel * 4 + channel] = pixels[pixel * channels + channel];
  }
  return { width, height, rgba };
}

async function pageEval(expression) {
  const page = await owned.page("/scroll-fixture", { timeout: 0 }).catch(() => null);
  assert.ok(page, "scroll fixture should have a CDP target");
  try {
    return await page.eval(expression, { timeout: 3000 });
  } finally { page.close(); }
}

let stage = "launch";
try {
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  owned = await launch(app, {
    data, port, session: fixture,
    switches: "--disable-backgrounding-occluded-windows",
    ...(bundlePort ? { js: `127.0.0.1:${bundlePort}` } : {}),
    ready: 'return !!globalThis.acPager?.("w1") && !!globalThis.acSwipe;',
  });
  await ac(`
    const at = (x, y) => () => ({ devSimulate: (steps) => Promise.resolve(globalThis.expo.modules.SolaraCEF.chromeWindows())
      .then((all) => (all.find((w) => w.hasRoot && w.profile === "" && w.group) ?? all.find((w) => w.hasRoot)).window)
      .then((n) => globalThis.expo.modules.SolaraSwipe.devSimulate(x, y, n, steps, true)) });
    const strip = at(700, 22);
    globalThis.acSwipe.sidebar = at(120, 400);
    globalThis.acSwipe.strip = () => ac.store.getState().settings.tabLayout === "top" ? strip() : null;
    return true;
  `);
  evidence.owner = { pid: owned.pid, port: owned.port, binary: owned.binary, started: owned.started, js: owned.js };
  appendFileSync(rep.logFile, `instance pid ${owned.pid}, DevTools port ${owned.port}, data ${data}\n`);
  if (bundlePort) {
    evidence.liveUpdatesDisabled = await ac(`
      const entry=[...globalThis.__r.getModules()].find(([,m])=>m.verboseName?.endsWith("/Libraries/Utilities/HMRClient.js"));
      if (!entry) throw new Error("HMR client missing");
      globalThis.__r(entry[0]).default.disable();
      return true;
    `);
  }
  stage = "the cases";

  await sleep(1000);

  await test("rapid forward/reverse profile swipes", async () => {
    await reset();
    const results = [];
    const fidelity = [];
    for (let i = 0; i < 6; i++) {
      const expected = i % 2 ? "default" : "work";
      try {
        const steps = gesture(i % 2 ? 1 : -1);
        const result = await simulate(steps);
        results.push(result);
        fidelity.push(fixtureFidelity(steps, result));
        if (fidelity.at(-1).errors.length) throw new Error(`fixture fidelity: ${fidelity.at(-1).errors.join("; ")}`);
        await waitProfile(expected);
      } catch (error) {
        error.evidence = { iteration: i, expected, results, fidelity,
          profile: await profile().catch(() => null),
          pager: await ac('return globalThis.acPager("w1").debug();').catch(() => null) };
        throw error;
      }
    }
    return { results, fidelity };
  });
  await test("small vertical start wobble keeps horizontal intent", async () => {
    await reset();
    const result = await simulate(gesture(-1, true));
    await waitProfile("work");
    return result;
  });
  await test("vertical drift after horizontal lock keeps profile swipe", async () => {
    await reset();
    const result = await simulate(gesture(-1, false, true));
    await waitProfile("work");
    return result;
  });
  await test("vertical sidebar scrolling stays native", async () => {
    await reset();
    const result = await simulate([{ phase: "began", dy: 5 }, { phase: "changed", dy: 16 },
      { phase: "changed", dy: 20 }, { phase: "ended" }]);
    assert.equal(await profile(), "default");
    assert.ok(result.events.every((e) => !e.swallowed), "vertical events must reach the scroll view");
    return result;
  });
  await test("cancelled swipe and momentum do not switch profiles", async () => {
    await reset();
    const steps = gesture(-1);
    steps[steps.length - 1].phase = "cancelled";
    steps.push({ phase: "momentumBegan", dx: -25 }, { phase: "momentum", dx: -30 }, { phase: "momentumEnded" });
    const result = await simulate(steps);
    await sleep(350);
    assert.equal(await profile(), "default");
    const next = await simulate(gesture(-1));
    await waitProfile("work");
    return { result, next };
  });
  await test("a new native drag interrupts the current settle synchronously", async () => {
    await reset();
    const result = await nativeBatch(alternatingGestures(2));
    assert.equal(result.profile, "default");
    assert.equal(result.state.selected, 0);
    assert.equal(result.state.phase, "idle");
    assert.ok(result.pager.ack >= result.state.selectionSequence, "latest selection must be acknowledged");
    return result;
  });
  await test("twelve native reversals keep the latest profile and stable coordinates", async () => {
    await reset();
    const result = await nativeBatch(alternatingGestures(12));
    assert.equal(result.profile, "default");
    assert.equal(result.state.selected, 0);
    assert.ok(Math.abs(result.state.position) < 0.003);
    assert.equal(result.state.phase, "idle");
    return result;
  });
  await test("queued selection events cannot rewind a native reversal while JS is blocked", async () => {
    await reset();
    const result = await nativeBatch(alternatingGestures(3), 700);
    assert.equal(result.profile, "work");
    assert.equal(result.state.selected, 1);
    assert.equal(result.state.phase, "idle");
    assert.ok(result.pager.ack >= result.state.selectionSequence, "latest selection must be acknowledged");
    return result;
  });
  await test("rapid profile shortcuts count every queued press", async () => {
    await reset();
    await ac('ac.runCommand({command:"nextProfile",windowId:"w1"}); ac.runCommand({command:"nextProfile",windowId:"w1"}); ac.runCommand({command:"nextProfile",windowId:"w1"}); return true;');
    await waitProfile("work");
    await sleep(450);
    const result = await ac('return globalThis.expo.modules.SolaraSwipe.devPagerState("w1");');
    assert.equal(result.profileId, "work");
    assert.equal(result.selected, 1);
    assert.equal(result.phase, "idle");
    return result;
  });
  await test("external profile selection interrupts a native drag without a late rewind", async () => {
    await reset();
    const steps=gesture(-1).map((s)=>({...s, atMs:s.atMs*3, timestampMs:s.timestampMs*3}));
    const result = await ac(`
      const simulation=globalThis.acSwipe.sidebar("w1").devSimulate(${JSON.stringify(steps)},{ignorePreference:true});
      setTimeout(()=>ac.store.getState().switchProfile("w1","work"),40);
      setTimeout(()=>ac.store.getState().switchProfile("w1","default"),56);
      return simulation.then(native=>new Promise(resolve=>setTimeout(()=>{
        globalThis.expo.modules.SolaraSwipe.devPagerState("w1").then(state=>resolve({native,state,
          profile:ac.store.getState().windows.w1.profileId}));
      },650)));
    `);
    saveSimulation(result.native);
    assert.equal(result.profile,"default");
    assert.equal(result.state.profileId,"default");
    assert.equal(result.state.phase,"idle");
    return result;
  });
  await test("latest profile dot cancels an in-flight native selection", async () => {
    await reset();
    await simulate(gesture(-1));
    await ac('const p=globalThis.acPager("w1"); p.switchTo("default"); p.switchTo("work"); return true;');
    await waitProfile("work");
    await sleep(650);
    const result = await ac('return globalThis.expo.modules.SolaraSwipe.devPagerState("w1");');
    assert.equal(result.selected, 1);
    assert.equal(result.phase, "idle");
    assert.ok(Math.abs(result.position - 1) < 0.003);
    return result;
  });
  await test("new gesture recovers after a missing end", async () => {
    await reset();
    const incomplete = await simulate(gesture(-1).slice(0, -1));
    const next = await simulate(gesture(-1));
    await waitProfile("work");
    return { incomplete, next };
  });
  for (const surface of ["sidebar", "strip"]) {
    await test(`a ${surface} swipe's momentum stays with it, so a third swipe at the same point switches`, async () => {
      await reset();
      if (surface === "strip") await ac('ac.store.getState().updateSettings({ tabLayout: "top" }); return true;');
      try {
        for (let start = Date.now(); Date.now() - start < 3000 && !(await ac(`return !!globalThis.acSwipe.${surface}("w1");`));) await sleep(50);
        await sleep(250);
        const results = [];
        for (const [sign, expected] of [[-1, "work"], [1, "default"], [-1, "work"]]) {
          const result = await ac(`return globalThis.acSwipe.${surface}("w1").devSimulate(${JSON.stringify(flick(sign))}, {ignorePreference:true});`, 15000);
          saveSimulation(result);
          results.push(result);
          const leaked = (result.events ?? []).filter((e) => e.phase.startsWith("momentum") && e.monitorSwallowed !== true);
          try {
            assert.ok(result.events?.length, "the flick should be delivered");
            assert.equal(leaked.length, 0, "a profile swipe's momentum must not reach AppKit's scroll views");
            await waitProfile(expected);
          } catch (error) {
            error.evidence = { swipe: results.length, results };
            throw error;
          }
        }
        await crossCase();
        return results.map((r) => r.events.map((e) => [e.phase, e.monitorSwallowed]));
      } finally {
        if (surface === "strip") await ac('ac.store.getState().updateSettings({ tabLayout: "sidebar" }); return true;');
        for (let start = Date.now(); Date.now() - start < 3000 && !(await ac('return !!globalThis.acSwipe.sidebar("w1");'));) await sleep(50);
      }
    });
  }

  if (stale) {
    await test("stale ordinary window cannot redirect into an overlapping logical window", async () => {
      await reset();
      const source = (await nativeWindow()).window;
      const first = await simulate(gesture(-1), source);
      await waitProfile("work");
      const otherId = await ac('return ac.store.getState().createWindow({profileId:"default", frame:[80,80,1280,800]});');
      try {
        await sleep(500);
        const all = await windows();
        assert.equal(all.find((w) => w.window === source)?.profile, "work", "the source window should show the swiped-to profile");
        const other = all.find((w) => w.hasRoot && w.window !== source);
        assert.ok(other, "second logical window should exist");
        assert.equal(other.profile, "", "the second logical window should show the default profile");
        assert.equal(await action(other.window, "ns:front"), "visible=1", "overlapping logical window should be ordered front");
        const reverse = await simulate(gesture(1), source);
        assert.equal(reverse.acks.find((a) => a.diag === "begin")?.window, source, "recognition should run in the source window");
        await waitProfile("default");
        assert.equal(await ac(`return ac.store.getState().windows[${JSON.stringify(otherId)}].profileId;`), "default");
        await crossRead("other logical window profile", (snapshot) => snapshot.windows.find((window) => window.id === otherId)?.profileId,
          (timeout) => ac(`return ac.store.getState().windows[${JSON.stringify(otherId)}].profileId;`, timeout));
        await crossCase();
        return { source, first, reverse, other: other.window };
      } finally {
        await ac(`ac.store.getState().closeWindow(${JSON.stringify(otherId)}); return true;`);
      }
    });
    await test("visible full-screen host accepts an immediate reverse through its moved root", async () => {
      await reset();
      const source = (await nativeWindow()).window;
      await action(source, "fakeFullScreen:1");
      try {
        const first = await simulate(gesture(-1), source);
        await waitProfile("work");
        const during = (await windows()).find((w) => w.window === source);
        assert.equal(during.visible, true, "old full-screen host must remain visible for this regression");
        const reverse = await simulate(gesture(1), source);
        await waitProfile("default");
        await crossCase();
        return { source, during, first, reverse };
      } finally {
        await action(source, "fakeFullScreen:0");
      }
    });
  }
  await test("web page horizontal and vertical scrolling retain renderer ownership", async () => {
    await reset();
    const url = `http://127.0.0.1:${server.address().port}/scroll-fixture`;
    const fixtureState = await ac(`
      ac.store.getState().activate("t1");
      ac.store.getState().navigate("t1", ${JSON.stringify(url)});
      const w = ac.store.getState().windows.w1;
      return { profileId: w.profileId, activeTabId: w.activeTabIds.default };
    `);
    try {
      assert.equal(fixtureState.profileId, "default", "the fixture's profile must be active");
      assert.equal(fixtureState.activeTabId, "t1", "the fixture tab must own the visible pane");
    } catch (error) { error.evidence = { fixtureState }; throw error; }
    let loaded = false;
    for (let i = 0; i < 30 && !loaded; i++) {
      try { loaded = await pageEval('document.readyState === "complete"'); } catch { assertOwnedAlive(); }
      if (!loaded) await sleep(100);
    }
    assert.ok(loaded, "local scroll fixture must load");
    await pageEval("window.scrollTo(400,400); true");
    await sleep(100);
    const before = await pageEval("({x:scrollX,y:scrollY,url:location.href})");
    const webState = await ac(`return {
      window: ac.store.getState().windows.w1,
      pager: globalThis.acPager("w1").debug(),
      pane: !!globalThis.acSwipe.pane("t1")
    };`);
    if (!webState.pane) {
      const error = new Error("loaded web fixture has no visible t1 swipe pane");
      error.evidence = { fixtureState, webState, windows: await windows(), before };
      throw error;
    }
    const horizontal = await ac(`return globalThis.acSwipe.pane("t1").devSimulate(${JSON.stringify(gesture(-1))}, {ignorePreference:true});`);
    await sleep(250);
    const afterHorizontal = await pageEval("({x:scrollX,y:scrollY,url:location.href})");
    assert.ok(afterHorizontal.x > before.x, "horizontal page scroll must still move web content");
    assert.equal(afterHorizontal.url, before.url, "horizontal scrolling must not navigate history");
    const vertical = await ac('return globalThis.acSwipe.pane("t1").devSimulate([{phase:"began"},{phase:"changed",dy:-18},{phase:"changed",dy:-24},{phase:"ended"}], {ignorePreference:true});');
    await sleep(250);
    const afterVertical = await pageEval("({x:scrollX,y:scrollY,url:location.href})");
    assert.ok(afterVertical.y > afterHorizontal.y, "vertical page scroll must still move web content");
    assert.equal(await profile(), "default");
    saveSimulation(horizontal);
    saveSimulation(vertical);
    await crossFixture();
    return { before, afterHorizontal, afterVertical, horizontal, vertical };
  });
  const routing = (result) => result.acks.find((a) => a.diag === "hitRouting");
  const flagged = (steps, flags) => steps.map((s) => ({ ...s, ...flags }));
  await test("a renderer hit outside its own frame falls back to the sidebar pager", async () => {
    await reset();
    assert.ok(await pageEval("!!document.body"), "the web fixture renderer must exist");
    const legacy = await simulate(flagged(gesture(-1), { wrongRendererHit: true, legacyHitRouting: true }));
    await sleep(600);
    const legacyProfile = await profile();
    const legacyBegin = legacy.acks.find((a) => a.diag === "begin");
    evidence.baselineRendererHit = { profile: legacyProfile, raw: routing(legacy)?.raw?.[0]?.class,
      misses: legacyBegin?.targets?.map((t) => t.miss), reject: legacy.acks.find((a) => a.diag === "reject")?.reason };
    assert.equal(routing(legacy)?.raw?.[0]?.class, "RenderWidgetHostViewCocoa", "injection should hit the real renderer");
    assert.equal(legacyProfile, "default", "legacy hit routing should reject the misrouted renderer hit");
    const fixed = await simulate(flagged(gesture(-1), { wrongRendererHit: true }));
    await waitProfile("work");
    assert.equal(routing(fixed)?.fallback, true, "the pager should take the gesture through the fallback");
    const begin = fixed.acks.find((a) => a.diag === "begin");
    assert.ok(begin.hit.every((h) => h.class !== "RenderWidgetHostViewCocoa"), "the effective hit must not be the renderer");
    return { legacy, fixed };
  });
  await test("a real web hit inside the renderer keeps page ownership", async () => {
    await reset();
    const source = (await nativeWindow()).window;
    const result = await ac(`return globalThis.expo.modules.SolaraSwipe.devSimulate(700, 400, ${source}, ${JSON.stringify(gesture(-1))}, true);`);
    await sleep(600);
    saveSimulation(result);
    assert.equal(routing(result)?.raw?.[0]?.class, "RenderWidgetHostViewCocoa", "the point should hit the page renderer");
    assert.equal(routing(result)?.fallback, false, "a hit inside the renderer must not fall back");
    assert.equal(await profile(), "default", "a web-page swipe must not switch profiles");
    return result;
  });
  await test("a native sidebar hit does not use the renderer fallback", async () => {
    await reset();
    const result = await simulate(gesture(-1));
    await waitProfile("work");
    assert.notEqual(routing(result)?.raw?.[0]?.class, "RenderWidgetHostViewCocoa");
    assert.equal(routing(result)?.fallback, false, "an ordinary sidebar hit should match directly");
    return result;
  });
  await test("a tracked swipe right after a discrete swipe goes back too", async () => {
    await reset();
    const base = `http://127.0.0.1:${server.address().port}/history`;
    const url = () => ac('return ac.store.getState().tabs.t1.url;');
    const crossUrl = () => crossRead("native fixture navigation", (snapshot) => snapshot.tabs.find((tab) => tab.id === "t1")?.url,
      (timeout) => ac('return ac.store.getState().tabs.t1.url;', timeout));
    async function waitUrl(expected, ms) {
      for (let start = Date.now(); Date.now() - start < ms && (await url()) !== expected;) await sleep(50);
      return url();
    }
    await ac('ac.store.getState().activate("t1"); return true;');
    for (const n of [1, 2, 3]) {
      await ac(`ac.store.getState().navigate("t1", ${JSON.stringify(base + n)}); return true;`);
      assert.equal(await waitUrl(base + n, 5000), base + n);
      await crossValue("native fixture navigation", (snapshot) => snapshot.tabs.find((tab) => tab.id === "t1")?.url, base + n);
      await crossUrl();
    }
    await sleep(500);
    const steps = [{ phase: "swipe", dx: 3, atMs: 0 }, { phase: "began", dx: 0, dy: 0, atMs: 50, timestampMs: 50 }];
    for (let at = 66; at <= 258; at += 16) steps.push({ phase: "changed", dx: 10, dy: 0, atMs: at, timestampMs: at });
    steps.push({ phase: "ended", dx: 0, dy: 0, atMs: 274, timestampMs: 274 });
    const result = await ac(`return globalThis.acSwipe.pane("t1").devSimulate(${JSON.stringify(steps)}, {ignorePreference:true});`);
    assert.equal(await waitUrl(base + 1, 3000), base + 1, "both swipes should go back");
    saveSimulation(result);
    await crossValue("native back-navigation URL", (snapshot) => snapshot.tabs.find((tab) => tab.id === "t1")?.url, base + 1);
    await crossUrl();
    return { events: result.events?.map((e) => [e.phase, e.swallowed ?? e.state]) };
  });
  await test("reordering profiles preserves a native selection queued behind blocked JS", async () => {
    await reset();
    try {
      const result = await ac(`
        const simulation=globalThis.acSwipe.sidebar("w1").devSimulate(${JSON.stringify(gesture(-1))}, {ignorePreference:true});
        setTimeout(()=>{
          const until=performance.now()+180; while(performance.now()<until){}
          ac.store.getState().reorderProfiles(["work","default"]);
        },20);
        return simulation.then(native=>new Promise(resolve=>setTimeout(()=>{
          globalThis.expo.modules.SolaraSwipe.devPagerState("w1").then(state=>resolve({native,state,
            profile:ac.store.getState().windows.w1.profileId,order:ac.store.getState().profileOrder}));
        },650)));
      `);
      saveSimulation(result.native);
      assert.equal(result.profile, "work");
      assert.equal(result.state.profileId, "work");
      assert.equal(result.state.selected, 0);
      assert.ok(Math.abs(result.state.position) < 0.003);
      await crossCase();
      return result;
    } finally {
      await ac('ac.store.getState().reorderProfiles(["default","work"]); return true;');
    }
  });
  await test("removing the other profile keeps the remaining sidebar at its origin", async () => {
    await ac('ac.store.getState().switchProfile("w1","work"); return true;');
    await waitProfile("work");
    await sleep(350);
    await ac('ac.store.getState().deleteProfile("default"); return true;');
    await sleep(350);
    const result = await ac('return globalThis.expo.modules.SolaraSwipe.devPagerState("w1");');
    assert.equal(await profile(), "work");
    assert.equal(result.count, 1);
    assert.equal(result.selected, 0);
    assert.ok(Math.abs(result.position) < 0.003);
    assert.equal(result.phase, "idle");
    assert.ok(result.areas >= 1);
    return result;
  });
  await rep.check("hidden profile gestures perform no haptics", async () => {
    const snapshot = await owned.snapshot({ fields: ["root.haptics"] }, { timeout: 2500 });
    assert.equal(snapshot.consistent, true);
    evidence.haptics = snapshot.haptics;
    assert.equal(snapshot.haptics.performed, 0);
    return snapshot.haptics;
  });
  stage = "the snapshot";
  const captureEnd = Date.now() + 2500;
  const captureRemaining = () => {
    const remaining = captureEnd - Date.now();
    assert.ok(remaining > 0, "window capture cross-check deadline");
    return remaining;
  };
  const captureBudget = () => {
    const timeout = captureRemaining();
    assert.ok(timeout >= 1000, "window capture minimum request budget");
    return timeout;
  };
  let nativeImage, jsImage;
  do {
    assertOwnedAlive();
    if (evidence.nativeSnapshot) rmSync(join(data, evidence.nativeSnapshot.artifact), { force: true });
    const nativeCapture = await owned.probe("view.capture", { windowId: "w1" }, { timeout: captureBudget() });
    assert.equal(nativeCapture.consistent, true);
    assert.ok(nativeCapture.width > 0 && nativeCapture.height > 0 && nativeCapture.scale > 0);
    evidence.nativeSnapshot = nativeCapture;
    assert.match(nativeCapture.artifact, /^\.solara-probe-window-[0-9a-f-]{36}\.png$/);
    const path = join(data, "profile-swipe.png");
    rmSync(path, { force: true });
    evidence.snapshot = { path,
      saved: await ac(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(join(data, "profile-swipe.png"))});`, captureBudget()) };
    assert.equal(evidence.snapshot.saved, true, "retained JS window capture saved");
    nativeImage = readPng(join(data, nativeCapture.artifact));
    jsImage = readPng(evidence.snapshot.path);
    assert.equal(nativeImage.width, nativeCapture.width);
    assert.equal(nativeImage.height, nativeCapture.height);
    if (same(nativeImage, jsImage) || Date.now() >= captureEnd) break;
    await sleep(Math.min(25, captureRemaining()));
  } while (Date.now() < captureEnd);
  assert.ok(Date.now() < captureEnd, "window capture cross-check deadline");
  assert.deepEqual(nativeImage, jsImage, "native and retained JS window capture dimensions and RGBA pixels");
} catch (error) {
  evidence.error = String(error);
  if (!error.reported) rep.record(`stopped at ${stage}`, { error });
} finally {
  if (only && !matched && !evidence.error) {
    evidence.error = `--only=${only} matched no test`;
    rep.record(`--only=${only}`, { error: "matched no test" });
  }
  if (owned) {
    try { evidence.cleanup = await owned.quit(); } catch (error) { evidence.cleanup = { error: String(error) }; }
  }
  writeFileSync(join(scratch, "profile-swipe-results.json"), JSON.stringify(evidence, null, 2));
  server.close();
  const failed = evidence.error || evidence.cases.some((c) => !c.passed) || rep.failed.length > 0;
  if (!keep && !failed) {
    rmSync(data, { recursive: true, force: true });
    rmSync(join(scratch, "profile-swipe-results.json"), { force: true });
  } else appendFileSync(rep.logFile, `evidence: ${join(scratch, "profile-swipe-results.json")}\n`);
  process.exitCode = rep.summary() && !failed ? 0 : 1;
}
