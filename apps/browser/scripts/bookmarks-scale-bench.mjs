#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { loadavg } from "node:os";
import { fileURLToPath } from "node:url";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
if (args.includes("--help")) {
  console.log("timeout 600 scripts/agent/locked perflab -- scripts/agent/locked uitest -- node apps/browser/scripts/bookmarks-scale-bench.mjs --app <Release Solara.app> --out <scratch> [--debug] [--sample] [--self-test]");
  process.exit(0);
}
const drafts = (n, prefix) => Array.from({ length: n }, (_, i) => ({ title: `${prefix} ${String(i).padStart(5, "0")}`, url: `https://bookmark-fixture.invalid/${prefix}/${i}` }));
const html = (n) => `<!DOCTYPE NETSCAPE-Bookmark-file-1><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8"><TITLE>Bookmarks</TITLE><H1>Bookmarks</H1><DL><p><DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3><DL><p>${drafts(n, "import").map((node) => `<DT><A HREF="${node.url}">${node.title}</A>`).join("\n")}</DL><p></DL><p>`;
if (args.includes("--self-test")) {
  assert.equal((html(2500).match(/<A HREF=/g) ?? []).length, 2500);
  assert.equal(new Set(drafts(5000, "scale").map((row) => row.url)).size, 5000);
  console.log("bookmarks-scale-bench fixture self-test passed");
  process.exit(0);
}
const appPath = resolve(option("--app", ""));
const out = resolve(option("--out", ""));
assert.ok(option("--app") && option("--out"), "--app and --out are required");
assert.ok(!appPath.startsWith("/Applications/"), "only an isolated build is allowed");
mkdirSync(out, { recursive: true });
const data = join(out, "data");
assert.ok(!existsSync(data), "--out must have no existing data directory");
const tools = join(out, "tools");
mkdirSync(tools, { recursive: true });
const dylib = join(tools, "acframes.dylib");
execFileSync("clang", ["-dynamiclib", "-fobjc-arc", "-framework", "AppKit", "-framework", "QuartzCore", "-arch", "arm64", join(here, "perf/acframes.m"), "-o", dylib], { timeout: 120000, stdio: "inherit" });
execFileSync("codesign", ["--force", "--sign", "-", dylib], { timeout: 30000, stdio: "inherit" });
const marker = join(tools, "acmark.dylib");
execFileSync("clang", ["-dynamiclib", "-fobjc-arc", "-framework", "AppKit", "-framework", "QuartzCore", "-arch", "arm64", join(here, "perf/acmark.m"), "-o", marker], { timeout: 120000, stdio: "inherit" });
execFileSync("codesign", ["--force", "--sign", "-", marker], { timeout: 30000, stdio: "inherit" });
const acperf = join(tools, "acperf");
execFileSync("swiftc", ["-O", "-module-cache-path", join(tools, "modules"), join(here, "perf/acperf.swift"), "-o", acperf], { timeout: 120000, stdio: "inherit" });
const importFile = join(out, "Bookmarks.html");
writeFileSync(importFile, html(2500));
const result = { version: 1, app: appPath, date: new Date().toISOString(), loadStart: loadavg(), display: JSON.parse(execFileSync(acperf, ["display"], { timeout: 10000, encoding: "utf8" })), operations: {}, measurements: "in-process command start to native model/layout observation; main/JS run-loop busy intervals from acframes; menu includes NSMenu construction; paint requires an awake display" };
const fixture = session({ windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }], tabs: [{ id: "a", title: "Fixture A", url: "about:blank" }, { id: "b", title: "Fixture B", url: "about:blank" }], settings: { bookmarksBar: "always", searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } });
let app;
let activeSampler;
let sequence = 0;
const save = () => writeFileSync(join(out, "results.json"), JSON.stringify(result, null, 2));
const stopSampler = async () => {
  const sampler = activeSampler;
  activeSampler = null;
  if (!sampler || sampler.exitCode !== null || sampler.signalCode !== null) return;
  const exited = new Promise((done) => sampler.once("exit", done));
  sampler.kill("SIGINT");
  await Promise.race([exited, sleep(3000)]);
  if (sampler.exitCode === null && sampler.signalCode === null) sampler.kill("SIGKILL");
};
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, async () => {
  if (stopping) return;
  stopping = true;
  result.error = `interrupted by ${signal}`;
  save();
  await stopSampler();
  try { if (app) await app.quit(); } finally { process.exit(128 + (signal === "SIGINT" ? 2 : 15)); }
});
const evaluate = (body, timeout = 30000) => app.eval(`const S = () => ac.store.getState(); const H = globalThis.expo.modules.SolaraHosted; const P = globalThis.expo.modules.SolaraPages; const C = globalThis.expo.modules.SolaraCEF; const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms)); const bar = (operation = "state", value = null) => H.bookmarkScale("w1", operation, value).then(JSON.parse); const page = (operation = "state", value = null) => P.bookmarkScale(operation, value).then(JSON.parse); const until = (read, accept, timeout = 20000) => { const end = performance.now() + timeout; const poll = () => Promise.resolve(read()).then((value) => { if (accept(value)) return value; if (performance.now() > end) throw new Error("native observation timed out: " + JSON.stringify(value)); return pause(2).then(poll); }); return poll(); }; ${body}`, { timeout });
const probe = async (op, extra = {}) => {
  const id = `bm-${++sequence}`;
  writeFileSync(join(data, "bench-frames-cmd.json"), JSON.stringify({ id, op, ...extra }));
  const path = join(data, "bench-frames-result.json");
  for (const deadline = Date.now() + 15000; Date.now() < deadline; await sleep(5)) {
    assert.ok(app.alive, "benchmark app exited");
    try { const response = JSON.parse(readFileSync(path, "utf8")); if (response.id === id) { assert.ok(response.ok, JSON.stringify(response)); return response; } } catch (error) { if (error.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error; }
  }
  throw new Error(`frame probe ${op} timed out`);
};
const memory = () => {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid="], { timeout: 5000, encoding: "utf8" }).trim().split("\n").map((line) => line.trim().split(/\s+/).map(Number));
  const pids = new Set([app.pid]);
  for (let changed = true; changed;) { changed = false; for (const [pid, parent] of rows) if (pids.has(parent) && !pids.has(pid)) { pids.add(pid); changed = true; } }
  const usage = execFileSync(acperf, ["rusage", ...[...pids].map(String)], { timeout: 10000, encoding: "utf8" }).trim().split("\n").filter(Boolean).map(JSON.parse);
  return { browserMB: (usage.find((row) => row.pid === app.pid)?.footprint ?? 0) / 1048576, processTreeMB: usage.reduce((sum, row) => sum + row.footprint, 0) / 1048576, processes: usage.length };
};
const measured = async (name, body) => {
  console.log(`begin ${name}`);
  await probe("stalls", { action: "begin", scenario: name });
  if (args.includes("--sample")) activeSampler = spawn("sample", [String(app.pid), "20", "1", "-file", join(out, `${name.replace(/[^a-z0-9]+/gi, "-")}.sample.txt`)], { stdio: "ignore" });
  try {
    const value = await evaluate(body, 120000);
    await sleep(80);
    const stalls = (await probe("stalls", { action: "end" })).window;
    result.operations[name] = { ...value, stalls };
    save();
    console.log(JSON.stringify({ name, ...value, mainWorstMs: stalls.main.worstMs, jsWorstMs: stalls.js.worstMs }));
    return value;
  } catch (error) {
    const stalls = await probe("stalls", { action: "end" }).then((response) => response.window).catch(() => null);
    result.operations[name] = { error: error.stack ?? String(error), stalls };
    save();
    throw error;
  } finally { await stopSampler(); }
};
const start = async (seed = false) => {
  app = await launch(appPath, { data, ...(seed ? { session: fixture, onboarded: true } : {}), keepData: true, probe: true, js: args.includes("--debug") ? "pinned" : "none", metroPort: 8104, env: { AC_BENCH_BOOKMARKS: "1", AC_BENCH_FRAMES: "1", AC_BENCH_STALLS: "1", DYLD_INSERT_LIBRARIES: `${dylib}:${marker}` }, switches: "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1", ready: "return !!ac.store.getState().windows.w1 && ac.store.getState().bookmarksReady.default === true;" });
  await evaluate('return C.chromeWindows().then((windows) => C.devWindow(windows.find((window) => window.hasRoot).window, "fakeActiveClicks"));');
  (result.probes ??= []).push(await probe("info"));
};
try {
  await start(true);
  await evaluate("return typeof H.bookmarkScale === 'function' && typeof P.bookmarkScale === 'function';").then((ok) => assert.ok(ok, "matching benchmark hooks required"));
  await measured("import-2500", `const started = performance.now(); return ac.pages.importModule().importBookmarksHTML(${JSON.stringify(importFile)}).then((root) => ac.pages.importBookmarks("default", root, "Scale fixture")).then((count) => until(() => bar(), (state) => state && state.items >= 2500).then((state) => ({ ms: performance.now() - started, imported: count, bar: state })));`);
  result.importMemory = memory(); save();
  await evaluate(`const roots = S().bookmarks.roots.default; return ac.bookmarks.removeBookmarks("default", [...S().bookmarks.nodes[roots.bar].children, ...S().bookmarks.nodes[roots.other].children]).then(() => ac.bookmarks.addBookmarkTree("default", [...${JSON.stringify(drafts(300, "bar"))}, {title: "Large folder", children: ${JSON.stringify(drafts(3000, "page"))}}, {title: "Other folder", children: ${JSON.stringify(drafts(1700, "other"))}}], roots.bar)).then(() => { const state = S(); const ids = state.bookmarks.nodes[roots.bar].children; globalThis.bookmarkScaleIds = { roots, first: ids[0], folder: ids[300], other: ids[301] }; return bookmarkScaleIds; });`, 120000);
  result.seedMemory = memory(); save();
  await evaluate('return until(() => globalThis.expo.modules.SolaraSettings.bookmarkWriterSnapshot("default").ready, (ready) => ready, 60000).then(() => pause(1000));', 90000);
  await app.quit(); app = null;
  const launched = Date.now();
  await start();
  result.launchBar = await evaluate('return until(() => bar(), (state) => state && state.items >= 302).then((state) => ({ observedAt: Date.now(), bar: state }));');
  result.launchBar.ms = result.launchBar.observedAt - launched;
  const marks = readFileSync(join(data, "bench-marks.jsonl"), "utf8").trim().split("\n").flatMap((line) => { try { return [JSON.parse(line)]; } catch { return []; } });
  const content = marks.find((mark) => mark.content >= launched);
  const committed = content && marks.find((mark) => mark.committed >= content.content && mark.window === content.window);
  result.launchBar.contentCommittedMs = committed ? committed.committed - launched : null;
  result.launchBar.shownMs = null;
  const launchRecords = readFileSync(join(data, "bench-frames.jsonl"), "utf8").trim().split("\n").flatMap((line) => { try { return [JSON.parse(line)]; } catch { return []; } }).filter((row) => row.k === "r" && row.a >= launched && row.a <= result.launchBar.observedAt);
  result.launchBar.stalls = Object.fromEntries(["m", "j"].map((thread) => [thread === "m" ? "main" : "js", { worstMs: Math.max(0, ...launchRecords.filter((row) => row.th === thread).map((row) => row.d)), observations: launchRecords.filter((row) => row.th === thread).length }]));
  await evaluate(`const roots = S().bookmarks.roots.default; const ids = S().bookmarks.nodes[roots.bar].children; globalThis.bookmarkScaleIds = { roots, first: ids[0], folder: ids[300], other: ids[301] }; return true;`);
  await measured("bar-switch", 'return bar().then((before) => { const started = performance.now(); S().activate("b"); return until(() => bar(), (state) => state?.selectedTabId === "b" && state.selectionSequence > before.selectionSequence).then((state) => ({ ms: performance.now() - started, bar: state })); });');
  await measured("bar-resize", 'const started = performance.now(); return bar("resize", "1000").then(() => bar("resize", "1280")).then((state) => ({ ms: performance.now() - started, bar: state }));');
  await measured("overflow-menu", 'return bar("menu", "overflow").then((menu) => ({ ms: menu.elapsedMs, menu }));');
  await measured("page-open", 'const started = performance.now(); ac.pages.openInternalPage("bookmarks", "w1"); return until(() => page(), (state) => state !== null).then(() => page("folder", bookmarkScaleIds.folder)).then(() => until(() => page(), (state) => state?.count === 3000 && state.firstMaterialized)).then((state) => ({ ms: performance.now() - started, page: state }));');
  await measured("page-scroll", 'const started = performance.now(); let bottom; return page("scroll", "50000").then(() => until(() => page(), (state) => state?.scrollY > 10000 && state.visibleIds.length > 0 && !state.visibleIds.includes(state.first))).then((state) => { bottom = state.scrollY; return page("scroll", "0"); }).then(() => until(() => page(), (state) => state?.scrollY < 1 && state.firstMaterialized)).then((state) => ({ ms: performance.now() - started, bottom, page: state }));');
  await measured("page-search", 'const started = performance.now(); return page("query", "page 02999").then(() => until(() => page(), (state) => state?.count === 1 && state.firstMaterialized)).then((state) => ({ ms: performance.now() - started, page: state }));');
  await evaluate('return page("query", "").then(() => page("folder", bookmarkScaleIds.roots.bar));');
  await measured("edit-add-5000", 'const started = performance.now(); return ac.bookmarks.addBookmark({profileId:"default", title:"Scale added", url:"https://bookmark-fixture.invalid/added", parentId:bookmarkScaleIds.roots.bar, index:0}).then((id) => { bookmarkScaleIds.added=id; return until(() => Promise.all([bar(), page("state",id)]), ([barState,pageState]) => barState?.firstId === id && pageState?.item?.id === id).then(([barState,pageState]) => ({ms:performance.now()-started,bar:barState,page:pageState})); });');
  await measured("edit-rename-5000", 'const started = performance.now(); return ac.bookmarks.updateBookmark("default",bookmarkScaleIds.added,{title:"Scale renamed"}).then(() => until(() => Promise.all([bar(),page("state",bookmarkScaleIds.added)]), ([barState,pageState]) => barState?.firstTitle === "Scale renamed" && pageState?.item?.title === "Scale renamed")).then(([barState,pageState]) => ({ms:performance.now()-started,bar:barState,page:pageState}));');
  await measured("edit-move-5000", 'const started = performance.now(); return ac.bookmarks.moveBookmark("default",bookmarkScaleIds.added,bookmarkScaleIds.folder,0).then(() => until(() => Promise.all([bar(),page("state",bookmarkScaleIds.added)]), ([barState,pageState]) => barState?.firstId !== bookmarkScaleIds.added && pageState?.item?.parentId === bookmarkScaleIds.folder)).then(([barState,pageState]) => ({ms:performance.now()-started,bar:barState,page:pageState}));');
  await evaluate('return until(() => page(), (state) => state?.folder === bookmarkScaleIds.roots.bar && state.firstMaterialized && !state.visibleIds.includes(bookmarkScaleIds.added)).then(() => page("folder",bookmarkScaleIds.folder)).then(() => until(() => page(), (state) => { const expected = S().bookmarks.nodes[bookmarkScaleIds.folder].children.slice(0,3); const old = new Set(S().bookmarks.nodes[bookmarkScaleIds.roots.bar].children); return state?.folder === bookmarkScaleIds.folder && state.first === expected[0] && state.firstMaterialized && expected.every((id) => state.frames.some((row) => row.label === "bookmark:" + id)) && state.visibleIds.every((id) => !old.has(id)); }));');
  try {
    await measured("page-drag-one", 'return page().then((state) => { const frames = state.frames.filter((row) => row.label.startsWith("bookmark:")).sort((a,b) => a.y-b.y); if(frames.length<3) throw new Error("drag needs three materialized rows"); const from=frames.find((row)=>row.label==="bookmark:"+state.first),to=frames.filter((row)=>row.label!=="bookmark:"+state.first)[1],first=state.first; if(!from||!to) throw new Error("drag needs the first row and two destination rows"); const started=performance.now(); return C.chromeWindows().then((windows) => C.devWindow(windows.find((window)=>window.hasRoot).window,"drag:"+(from.x+120)+","+(from.y+from.height/2)+";"+(to.x+120)+","+(to.y+to.height*0.8))).then(()=>until(()=>page(),(next)=>next?.first!==first)).then((next)=>({ms:performance.now()-started,page:next})); });');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
  await measured("page-select-all", 'const started=performance.now(); return page("selectAll").then(() => page()).then((state) => ({ms:performance.now()-started,page:state}));');
  await measured("page-delete-many", 'const started=performance.now(); return page("delete").then(() => until(() => page(),(state)=>state?.count===0)).then((state)=>({ms:performance.now()-started,page:state}));');
  result.finalMemory = memory();
  result.loadEnd = loadavg();
  result.targetFailures = Object.entries(result.operations).flatMap(([name, row]) => [
    ...(row.error ? [`${name}: ${row.error}`] : []),
    ...(row.stalls?.main.worstMs > 100 ? [`${name}: main stall ${row.stalls.main.worstMs.toFixed(2)} ms > 100`] : []),
    ...((name === "page-open" || name === "overflow-menu") && row.ms >= 300 ? [`${name}: ${row.ms.toFixed(2)} ms >= 300`] : []),
    ...(name.startsWith("edit-") && row.ms >= 50 ? [`${name}: ${row.ms.toFixed(2)} ms >= 50`] : []),
  ]);
  if (result.launchBar.stalls.main.worstMs > 100) result.targetFailures.push(`bar launch: main stall ${result.launchBar.stalls.main.worstMs.toFixed(2)} ms > 100`);
  save();
  if (args.includes("--check") && result.targetFailures.length) { console.error(result.targetFailures.join("\n")); process.exitCode = 1; }
} catch (error) {
  result.error = error.stack ?? String(error); save(); throw error;
} finally { await stopSampler(); if (app) await app.quit(); }
