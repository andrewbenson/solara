#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { registerHooks } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { encodeArgs } from "../../../../packages/store/src/encode.ts";

const HELP = `usage: node scripts/native/replay.mjs [--phase 1a|1b|adapters] [--out <dir>] [--cap <cases per test, 0 for all>] [--plain] [test files...]

Runs the store's *.test.mjs files through the real JS store, recording every call of a command
the Swift core owns in that phase as a case: the state before, the command, the state after,
the clock and the id counter. SolaraStoreTests replays each case through the Swift core and
diffs canonical JSON. Each test file runs in its own process, as node --test runs them.

--phase adapters records the sync adapters of src/sync/adapters.ts and pinned.ts, as the tests in
src/sync and src/sync/redesign drive them, instead: each
extract and apply call with the state before, the adapter's arguments, every lookup it made
(base, known, queued, remote, stamp) and its answer, the values it extracted in order, the
answers ignore and republish gave the merge, what apply was given, the store commands it issued,
its result (the keys an apply wrote as {written: [...]}), redesign: true when the syncRedesign
switch was on, and the state after. Default out for it: native/SolaraKit/Tests/SolaraSyncTests/Adapters.
SolaraSyncTests replays each call through the Swift adapter.`;

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "../..");
const defaultOut = resolve(app, "../../native/SolaraKit/Tests/SolaraStoreTests/Cases");

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  if (at < 0) return fallback;
  const value = args[at + 1];
  args.splice(at, 2);
  return value;
};
const phase = option("--phase", "1a");
const cap = Number(option("--cap", "400"));
const plainOutput = args.includes("--plain");
if (plainOutput) args.splice(args.indexOf("--plain"), 1);
const out = resolve(option("--out", phase === "adapters" ? resolve(app, "../../native/SolaraKit/Tests/SolaraSyncTests/Adapters") : defaultOut));
const child = option("--child", null);
const harvest = option("--harvest", null);


function orchestrate() {
  const files = args.length
    ? args.map((f) => resolve(f))
    : (phase === "adapters" ? ["src/sync", "src/sync/redesign"] : ["src/store", "src/lib", "src/sync"]).flatMap((dir) =>
        readdirSync(join(app, dir)).filter((f) => f.endsWith(".test.mjs")).map((f) => join(app, dir, f)),
      );
  mkdirSync(out, { recursive: true });
  let cases = 0;
  let failed = 0;
  for (const file of files.sort()) {
    const run = spawnSync(process.execPath, ["--no-warnings", "--max-old-space-size=8192", fileURLToPath(import.meta.url), "--child", file, "--phase", phase, "--out", out, "--cap", String(cap), ...(plainOutput ? ["--plain"] : []), ...(harvest ? ["--harvest", resolve(harvest)] : [])], {
      cwd: app,
      encoding: "utf8",
      maxBuffer: 1 << 28,
    });
    const summary = run.stdout.trim().split("\n").at(-1) ?? "";
    const match = /^recorded (\d+)/.exec(summary);
    if (run.status !== 0 || !match) {
      failed++;
      console.error(`${relative(app, file)}: failed\n${run.stderr.split("\n").slice(-15).join("\n")}`);
      continue;
    }
    cases += Number(match[1]);
    if (Number(match[1]) || run.stderr.trim()) console.log(`${relative(app, file)}: ${summary.replace(/^recorded /, "")}`);
    if (run.stderr.trim()) console.log(run.stderr.trim().split("\n").map((l) => `  ${l}`).join("\n"));
  }
  console.log(`${cases} cases from ${files.length - failed} files${failed ? `, ${failed} files failed` : ""}`);
  process.exit(failed ? 1 : 0);
}

const INSTRUMENT = [
  ["/src/store/model.ts", "globalThis.__replayModel = { read: () => ({ launch, counter, navSeq }) };"],
  ["/src/store/organize.ts", "globalThis.__replayOrganize = { read: () => ({ lastPinChoice, remotePinDeletions: Object.fromEntries(remotePinDeletions) }) };"],
  ["/src/store/ui.ts", "globalThis.__replayUi = { read: () => [...endedPrivateDownloads].sort() };"],
  ["/src/store/closingWindows.ts", "globalThis.__replayClosing = { read: () => [...closing].sort() };"],
  ["/src/store/newTabBar.ts", "globalThis.__replayNewTabBar = { read: () => lastTabKeepsWindow };"],
  ["/src/store/tabs.ts", "const __replayDefaultHandoff = pinHandoff; const __replayDefaultOpener = openOutsideTab; globalThis.__replayTabs = { immediateHandoff: () => pinHandoff === __replayDefaultHandoff, defaultOpener: () => openOutsideTab === __replayDefaultOpener };", [
    ['import { resolveInput } from "@solara/core";', 'import { resolveInput as __resolveInput } from "@solara/core";\nconst resolveInput = (input, prefix) => { const out = __resolveInput(input, prefix); globalThis.__replayCalls?.resolve.push([input, prefix, out]); return out; };'],
    ['import { searchUrlPrefix } from "./settings";', 'import { searchUrlPrefix as __searchUrlPrefix } from "./settings";\nconst searchUrlPrefix = (settings) => { const out = __searchUrlPrefix(settings); if (globalThis.__replayCalls) globalThis.__replayCalls.prefix = out; return out; };'],
  ]],
  ["/src/store/syncOrigin.ts", "globalThis.__replayOrderChoices = { read: () => remote };"],
  ["/src/store/pinOrderChoices.ts", "globalThis.__replayNotesOrderChoices = true;"],
  ["/src/sync/redesignSwitch.ts", "globalThis.__replayRedesign = syncRedesign;"],
  ["/src/store/browser.ts", "", [["export const storeTransaction = transactions.transaction;", "export const storeTransaction = (run) => (globalThis.__replayTransaction ? globalThis.__replayTransaction(run, transactions.transaction) : transactions.transaction(run));"]]],
  ["/src/lib/chromeTabs.ts", "globalThis.__replayChromeTabs = { read: () => ({ strips: [...mirror.values()], lastRev, seen: [...seen], inflight: Object.fromEntries(inflight), groups: Object.fromEntries(groups), tried: Object.fromEntries(tried), changedAt: Object.fromEntries(changedAt), madeInFront: Object.fromEntries(madeInFront) }) };\nconst sendTabStripCommand = (command) => { const cmd = __sendTabStripCommand(command); globalThis.__replayCalls?.sent?.push([command, cmd]); return cmd; };\nfunction receive(tx) { return globalThis.__replayCommand ? globalThis.__replayCommand(\"stripTransaction\", [tx], () => __replayReceiveImpl(tx)) : __replayReceiveImpl(tx); }\nfunction project(s) { return globalThis.__replayCommand ? globalThis.__replayCommand(\"projectStrips\", [], () => __replayProjectImpl(s)) : __replayProjectImpl(s); }", [
    ["  sendTabStripCommand,\n", "  sendTabStripCommand as __sendTabStripCommand,\n"],
    ["function receive(tx: TabStripTransaction) {", "function __replayReceiveImpl(tx: TabStripTransaction) {"],
    ["function project(s: BrowserState) {", "function __replayProjectImpl(s: BrowserState) {"],
  ]],
  ["/src/lib/persist.ts", "", [
    ["export function startPersistence() {", "export function startPersistence() {\n  globalThis.__replayPersistStarted = true;"],
    ["    writeDocument(name, json);", "    writeDocument(name, json);\n    globalThis.__replayHarvest?.(name, json);"],
  ]],
];

const RECORDED_ADAPTERS = new Map([
  ["settingsAdapter", []],
  ["profilesAdapter", ["read"]],
  ["profileThemesAdapter", ["read", "themeRecords", "callback"]],
  ["sharedDataAdapter", ["read"]],
  ["deviceAdapter", ["plain", "read", "plain"]],
  ["deviceTabsAdapter", ["plain", "plain", "read", "plain"]],
  ["developerModeAdapter", ["plain"]],
  ["pinnedAdapter", ["plain"]],
  ["pinnedOrderAdapter", ["plain"]],
  ["pinnedRowsAdapter", ["plain"]],
  ["groupLooksAdapter", ["plain"]],
  ["pinnedHomesAdapter", ["plain"]],
  ["tileFoldersAdapter", ["plain"]],
  ["bookmarksAdapter", ["plain"]],
  ["historyAdapter", ["plain"]],
  ["passwordsAdapter", ["plain", "read", "host"]],
]);
const HOSTED_ADAPTERS = new Set(["bookmarksAdapter", "historyAdapter", "passwordsAdapter"]);

const HOST_IMPORTS = [
  ['import { deletePassword, savePassword } from "@solara/solaracore";', "@solara/solaracore", [["deletePassword", "deletePassword"], ["savePassword", "savePassword"]]],
  ['import { nativeAddHistoryVisits, nativeDeleteHistoryUrls } from "@solara/settings";', "@solara/settings", [["nativeAddHistoryVisits", "addHistoryVisits"], ["nativeDeleteHistoryUrls", "deleteHistoryUrls"]]],
];

function instrumentAdapters(source) {
  const appended = [];
  for (const [line, module, natives] of HOST_IMPORTS) {
    if (!source.includes(line)) continue;
    source = source.replace(
      line,
      `import { ${natives.map(([n]) => `${n} as __replay_${n}`).join(", ")} } from "${module}";\n${natives.map(([n, host]) => `const ${n} = (...args) => globalThis.__replayHost("${host}", args, () => __replay_${n}(...args));`).join("\n")}`,
    );
  }
  source = source.replace("async (p) => SyncNative?.readPasswords(p)", 'async (p) => globalThis.__replayHost("readLogins", [p], () => SyncNative?.readPasswords(p))');
  source = source.replace("await new Promise((r) => setTimeout(r, 250));", 'await globalThis.__replayHost("sleep", [250], () => new Promise((r) => setTimeout(r, 250)));');
  source = source.replace('  return {\n    prefix: "pw:",', '  return {\n    __replayMemory: () => ({ lastRead, quietUntil, created: [...created] }),\n    prefix: "pw:",');
  source = source.replace(/^export function (\w+Adapter)\(/gm, (_, name) => {
    appended.push(`export function ${name}(...args) { return globalThis.__replayAdapter("${name}", args, (given) => __replay_${name}(...given)); }`);
    return `function __replay_${name}(`;
  });
  source = source.replace(/^export const (\w+Adapter): Adapter = /gm, (_, name) => {
    appended.push(`export const ${name} = globalThis.__replayLazyAdapter("${name}", __replay_${name});`);
    return `const __replay_${name}: Adapter = `;
  });
  return `${source}\n${appended.join("\n")}\n`;
}

const textOrNone = (v) => v === undefined || v === null || typeof v === "string";
function wronglyTyped(s) {
  const tabBad = (t) => !!t && (typeof t.url !== "string" || typeof t.title !== "string" || !textOrNone(t.customTitle) || !textOrNone(t.customIcon) || !textOrNone(t.pinnedUrl));
  const groupBad = (g) => !!g && (typeof g.name !== "string" || !textOrNone(g.color) || !textOrNone(g.icon));
  return (
    Object.values(s.tabs ?? {}).some(tabBad) ||
    Object.values(s.groups ?? {}).some(groupBad) ||
    Object.values(s.parkedPins ?? {}).some((p) => (p?.tabs ?? []).some(tabBad) || (p?.groups ?? []).some(groupBad)) ||
    Object.values(s.profiles ?? {}).some((p) => typeof p.name !== "string" || typeof p.color !== "string" || !textOrNone(p.icon))
  );
}

function readMemory() {
  const model = globalThis.__replayModel?.read() ?? {};
  const organize = globalThis.__replayOrganize?.read() ?? {};
  return {
    launch: model.launch,
    counter: model.counter,
    navSeq: model.navSeq,
    lastPinChoice: organize.lastPinChoice ?? 0,
    remotePinDeletions: organize.remotePinDeletions ?? {},
    endedPrivateDownloads: globalThis.__replayUi?.read() ?? [],
    closingWindows: globalThis.__replayClosing?.read() ?? [],
    lastTabKeepsWindow: globalThis.__replayNewTabBar?.read() ?? false,
    fromSyncDepth: globalThis.__replayOrderChoices?.read() ?? 0,
    ...(globalThis.__replayChromeTabs ? { chromeTabs: plain(globalThis.__replayChromeTabs.read()) } : {}),
    ...tileFolderMemory(),
  };
}

function tileFolderMemory() {
  const folders = globalThis.__replayLocalFolders?.() ?? {};
  return Object.keys(folders).length ? { tileFolders: folders } : {};
}

function readConfig() {
  const listeners = ["forgetClosedPrivateWindows", "settleNesting", "livePinTable", "settlePeeks", "mirror"];
  if (globalThis.__replayNotesOrderChoices) listeners.push("noteOrderChoices");
  if (globalThis.__replayPersistStarted) listeners.push("forgetClosedIncognito");
  return { handOffPinsImmediately: globalThis.__replayTabs?.immediateHandoff() ?? true, listeners };
}

function outsideStore(stack) {
  const frames = stack.split("\n").slice(2);
  for (const frame of frames) {
    if (frame.includes("replay.mjs")) return false;
    if (((frame.includes("/src/store/") || frame.includes("/src/lib/persist.ts") || frame.includes("/src/lib/chromeTabs.ts")) && !frame.includes(".test.mjs")) || frame.includes("node_modules") || frame.includes("node:") || !frame.includes("/")) continue;
    return true;
  }
  return false;
}

function bridgeArgs(name, args) {
  return { args: encodeArgs(name, args) };
}

const PRESENT_UNDEFINED = ["favicon", "customTitle", "customIcon", "pinnedUrl", "openerId", "icon", "color"];
const presentUndefined = (o) => !!o && typeof o === "object" && PRESENT_UNDEFINED.some((k) => k in o && o[k] === undefined);
function undefinedInState(s) {
  const snapshots = [
    ...Object.values(s.tabs ?? {}),
    ...Object.values(s.groups ?? {}),
    ...(s.closedTabs ?? []).flatMap((c) => [c.tab, c.group, ...(c.parents ?? [])]),
    ...(s.cleanedTabs ?? []).flatMap((c) => [c.tab, c.group, ...(c.parents ?? [])]),
    ...(s.closedWindows ?? []).flatMap((c) => [...c.tabs, ...c.groups]),
    ...[...(s.closedGroups ?? []), ...(s.deletedGroups ?? [])].flatMap((c) => [...c.tabs, c.group, ...(c.nested ?? [])]),
    ...Object.values(s.parkedPins ?? {}).flatMap((p) => [...p.tabs, ...p.groups]),
  ];
  return snapshots.some(presentUndefined);
}

const undefinedKeyIn = (object) => !!object && typeof object === "object" && Object.values(object).some((v) => v === undefined);

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hasUndefinedKey(value, seen = new Set()) {
  if (!value || typeof value !== "object" || seen.has(value)) return false;
  seen.add(value);
  return Object.entries(value).some(([, v]) => v === undefined || hasUndefinedKey(v, seen));
}

const TABLE_KEYS = new Set(["profiles", "windows", "tabs", "groups", "splits", "peeks", "parkedPins", "pinChoices", "pinSync", "privateCleanedTabs", "privateSiteMutes"]);

function stateDelta(from, to) {
  const out = {};
  for (const key of new Set([...Object.keys(from), ...Object.keys(to)])) {
    const a = from[key];
    const b = to[key];
    if (JSON.stringify(a) === JSON.stringify(b)) continue;
    if (TABLE_KEYS.has(key) && a && b && typeof a === "object" && typeof b === "object") {
      const set = {};
      const remove = [];
      for (const id of Object.keys(b)) if (JSON.stringify(a[id]) !== JSON.stringify(b[id])) set[id] = b[id];
      for (const id of Object.keys(a)) if (!(id in b)) remove.push(id);
      const order = Object.keys(b);
      const naive = [...Object.keys(a).filter((id) => id in b), ...Object.keys(b).filter((id) => !(id in a))];
      out[key] = { $table: { set, remove, ...(order.join("\u0000") !== naive.join("\u0000") ? { order } : {}) } };
    } else {
      out[key] = b === undefined ? { $absent: true } : b;
    }
  }
  return out;
}

function encodeDeltas(cases) {
  let last = null;
  let lastTest = null;
  return cases.map((c) => {
    const { before, after, ...rest } = c;
    const chained = lastTest === c.test && last;
    const encoded = { ...rest, ...(chained ? { beforeDelta: stateDelta(last, before) } : { before }), afterDelta: stateDelta(before, after) };
    last = after;
    lastTest = c.test;
    return encoded;
  });
}

function plain(value) {
  return value === undefined ? null : JSON.parse(JSON.stringify(value));
}

async function record(file) {
  let clock = Date.UTC(2026, 9, 26, 12);
  let frozen = null;
  const stubNow = () => frozen ?? (clock += 1);
  Date.now = stubNow;
  Math.random = mulberry32(0x5eed);
  globalThis.__DEV__ = false;

  const tests = [];
  const hooks = { beforeEach: [], afterEach: [] };
  const realTest = await import("node:test");
  globalThis.__replayNodeTest = {
    test: Object.assign((name, options, fn) => tests.push({ name, fn: fn ?? options, skip: typeof options === "object" && options?.skip }), {
      skip: (name) => tests.push({ name, skip: true }),
      only: (name, options, fn) => tests.push({ name, fn: fn ?? options }),
      todo: (name) => tests.push({ name, skip: true }),
    }),
    beforeEach: (fn) => hooks.beforeEach.push(fn),
    afterEach: (fn) => hooks.afterEach.push(fn),
    mock: realTest.mock,
  };
  const fakeUrl = `data:text/javascript,const t = globalThis.__replayNodeTest; export const test = t.test, it = t.test, beforeEach = t.beforeEach, afterEach = t.afterEach, mock = t.mock; export default t.test;`;
  registerHooks({
    resolve(specifier, context, next) {
      if (specifier === "node:test" && !context.parentURL?.startsWith("data:")) return { url: fakeUrl, shortCircuit: true };
      return next(specifier, context);
    },
  });
  await import(pathToFileURL(join(app, "src/test-loader.mjs")).href);
  let adapterHook = null;
  globalThis.__replayAdapter = (name, args, build) => (adapterHook ? adapterHook(name, args, build) : build(args));
  let hostLog = null;
  globalThis.__replayHost = (name, args, run) => {
    const log = hostLog;
    if (!log) return run();
    const entry = { n: name, a: plain(args) };
    log.push(entry);
    const answer = run();
    if (answer && typeof answer.then === "function") return answer.then((v) => (v !== undefined && (entry.r = plain(v)), v));
    if (answer !== undefined) entry.r = plain(answer);
    return answer;
  };
  globalThis.__replayLazyAdapter = (name, raw) => {
    let wrapped = null;
    const live = () => (wrapped ??= adapterHook ? adapterHook(name, [], () => raw) : null) ?? raw;
    return { ...raw, extract: (...given) => live().extract(...given), apply: (...given) => live().apply(...given) };
  };
  registerHooks({
    load(url, context, next) {
      const loaded = next(url, context);
      if (phase === "adapters" && (url.endsWith("/src/sync/adapters.ts") || url.endsWith("/src/sync/pinned.ts")) && loaded.source != null) {
        const text = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
        const exposed = url.endsWith("/src/sync/pinned.ts")
          ? "\nglobalThis.__replayLocalFolders = () => Object.fromEntries([...localFolders].map(([profileId, ids]) => [profileId, [...ids]]));\n"
          : "";
        return { ...loaded, source: instrumentAdapters(text) + exposed };
      }
      const rule = INSTRUMENT.find(([suffix]) => url.endsWith(suffix));
      if (!rule || loaded.source == null) return loaded;
      let source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
      for (const [from, to] of rule[2] ?? []) source = source.replace(from, to);
      return { ...loaded, source: `${source}\n${rule[1]}\n` };
    },
  });
  await import(pathToFileURL(file).href);

  const spec = await phases(phase);
  if (harvest) {
    const written = new Map();
    let serial = 0;
    globalThis.__replayHarvest = (name, json) => {
      written.set(name, json);
      if (name !== "session.json") return;
      const dir = join(harvest, `${relative(join(app, "src"), file).replace(/\.test\.mjs$/, "").replaceAll("/", "__")}__${String(++serial).padStart(3, "0")}`);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "session.json"), json);
      if (written.has("downloads.json")) writeFileSync(join(dir, "downloads.json"), written.get("downloads.json"));
    };
  }
  const RealURL = globalThis.URL;
  globalThis.URL = class extends RealURL {
    constructor(input, base) {
      try {
        super(input, base);
        if (globalThis.__replayCalls && base === undefined) globalThis.__replayCalls.urls[String(input)] = { protocol: this.protocol, host: this.host, hostname: this.hostname };
      } catch (error) {
        if (globalThis.__replayCalls && base === undefined) globalThis.__replayCalls.urls[String(input)] = null;
        throw error;
      }
    }
  };
  const { useBrowser } = await import(pathToFileURL(join(app, "src/store/browser.ts")).href);
  const model = await import(pathToFileURL(join(app, "src/store/model.ts")).href);
  const probe = () => {
    const [, launch, counter] = /^probe-([0-9a-z]+)-([0-9a-z]+)$/.exec(model.newId("probe"));
    return { launch, counter: parseInt(counter, 36) };
  };

  let cases = [];
  let current = null;
  let depth = 0;
  let foreign = false;
  let batch = null;
  const memory = { endedPrivateDownloads: new Set() };
  const WRAPPED = Symbol("replay");
  let adapterCall = null;

  const wrap = (state) => {
    const patch = {};
    for (const name of spec.commands) {
      const original = state[name];
      if (typeof original !== "function" || original[WRAPPED]) continue;
      const wrapped = function (...callArgs) {
        if (spec.adapters) {
          const into = batch ?? adapterCall?.commands;
          if (into && depth === 0) {
            const command = spec.command(name, callArgs, useBrowser.getState(), model);
            if (command?.lossy) adapterCall.lossy = command.lossy;
            if (adapterCall && hasUndefinedKey(callArgs)) adapterCall.lossy = "a command argument has a key set to undefined, which JSON cannot carry";
            if (command) delete command.lossy;
            into.push(command);
          }
          depth++;
          try {
            return original.apply(this, callArgs);
          } finally {
            depth--;
          }
        }
        if (depth > 0 && current && outsideStore(new Error().stack ?? "")) foreign = true;
        if (batch && depth === 0) {
          batch.push(spec.command(name, callArgs, useBrowser.getState(), model));
          depth++;
          try {
            return original.apply(this, callArgs);
          } finally {
            depth--;
          }
        }
        if (depth > 0 || !current) {
          depth++;
          try {
            return original.apply(this, callArgs);
          } finally {
            depth--;
          }
        }
        const before = useBrowser.getState();
        const testNow = Date.now === stubNow ? null : Date.now;
        const now = testNow ? testNow() : stubNow();
        frozen = now;
        if (testNow) Date.now = () => now;
        const ids = spec.probes ? probe() : null;
        const memoryBefore = spec.probes ? { endedPrivateDownloads: [...memory.endedPrivateDownloads].sort() } : readMemory();
        const config = readConfig();
        const command = spec.command(name, callArgs, before, model);
        foreign = false;
        globalThis.__replayCalls = { urls: {}, resolve: [], prefix: null };
        depth++;
        let result;
        let threw = null;
        try {
          result = original.apply(this, callArgs);
        } catch (error) {
          threw = error;
        } finally {
          depth--;
          frozen = null;
          if (testNow) Date.now = testNow;
        }
        const after = useBrowser.getState();
        const calls = globalThis.__replayCalls;
        globalThis.__replayCalls = null;
        spec.noteMemory?.(name, callArgs, before, after, memory, model);
        if (command && !threw) {
          const lossyArgs = command.lossy;
          delete command.lossy;
          cases.push({
            test: current,
            now,
            ...(ids ? { ids } : {}),
            memory: memoryBefore,
            before: (spec.before ?? spec.project)(before, model),
            command,
            after: spec.project(after, model),
            ...(spec.probes && hasUndefinedKey(callArgs) ? { lossy: "an argument has a key set to undefined, which JSON cannot carry" } : {}),
            ...(lossyArgs ? { lossy: "an argument has a nested key set to undefined, which JSON cannot carry" } : {}),
            ...(!spec.probes && undefinedInState(before) ? { lossy: "the state before holds a key set to undefined, which JSON cannot carry" } : {}),
            ...(foreign ? { foreign: "code outside the store changed state during this command" } : {}),
            ...(spec.probes ? {} : { config, web: calls }),
            ...(result !== undefined && spec.recordsResult && (!spec.returning || spec.returning.has(name)) ? { result: plain(result) } : {}),
            ...(spec.extra ? spec.extra(name, callArgs, before, after, model) : {}),
          });
        }
        if (threw) throw threw;
        return result;
      };
      wrapped[WRAPPED] = true;
      patch[name] = wrapped;
    }
    return patch;
  };
  globalThis.__replayCommand = (name, args, run, bridged = false) => {
    if (spec.adapters) {
      if (adapterCall && depth === 0 && !batch) adapterCall.commands.push({ name, args: bridged ? args : plain(args) });
      depth++;
      try {
        return run();
      } finally {
        depth--;
      }
    }
    if (depth > 0 || !current || batch || !spec.engineCommands) return run();
    const before = useBrowser.getState();
    const now = stubNow();
    frozen = now;
    const memoryBefore = readMemory();
    const config = readConfig();
    foreign = false;
    globalThis.__replayCalls = { urls: {}, resolve: [], prefix: null, sent: [] };
    depth++;
    let threw = null;
    let result;
    try {
      result = run();
    } catch (error) {
      threw = error;
    } finally {
      depth--;
      frozen = null;
    }
    const calls = globalThis.__replayCalls;
    globalThis.__replayCalls = null;
    const after = useBrowser.getState();
    if (!threw) {
      const { sent, ...web } = calls;
      cases.push({
        test: current,
        now,
        memory: memoryBefore,
        before: spec.before(before, model),
        command: { name, args: bridged ? args : plain(args) },
        after: spec.project(after, model),
        config,
        web,
        sent,
        memoryAfter: { chromeTabs: plain(globalThis.__replayChromeTabs?.read() ?? null) },
        ...(foreign ? { foreign: "code outside the store changed state during this command" } : {}),
      });
    }
    if (threw) throw threw;
    return result;
  };
  globalThis.__replayTransaction = (run, real) => {
    if (spec.adapters) {
      if (!adapterCall || depth > 0 || batch) return real(run);
      batch = [];
      try {
        return real(run);
      } finally {
        const commands = batch;
        batch = null;
        if (commands.length) adapterCall.commands.push({ name: "$batch", commands });
      }
    }
    if (depth > 0 || !current || batch || !spec.batches) return real(run);
    const before = useBrowser.getState();
    const now = stubNow();
    frozen = now;
    const memoryBefore = readMemory();
    const config = readConfig();
    foreign = false;
    globalThis.__replayCalls = { urls: {}, resolve: [], prefix: null };
    batch = [];
    let threw = null;
    try {
      real(run);
    } catch (error) {
      threw = error;
    }
    const commands = batch;
    batch = null;
    frozen = null;
    const calls = globalThis.__replayCalls;
    globalThis.__replayCalls = null;
    const after = useBrowser.getState();
    if (!threw && commands.length) {
      const lossy = commands.some((c) => c.lossy);
      for (const c of commands) delete c.lossy;
      cases.push({
        test: current,
        now,
        memory: memoryBefore,
        before: spec.before(before, model),
        command: { name: "$batch", commands },
        after: spec.project(after, model),
        config,
        web: calls,
        ...(lossy ? { lossy: "an argument has a nested key set to undefined, which JSON cannot carry" } : {}),
        ...(foreign ? { foreign: "code outside the store changed state during this command" } : {}),
      });
    }
    if (threw) throw threw;
  };
  const rawSetState = useBrowser.setState;
  const SLICES = new Set(["profiles", "profileOrder", "orphanedProfileData", "windows", "windowOrder", "tabs", "groups", "splits", "peeks", "closedTabs", "closedWindows", "closedGroups", "deletedGroups", "cleanedTabs", "privateCleanedTabs", "privateSiteMutes", "parkedPins", "pinChoices", "pinSync", "downloads", "settings", "ui"]);
  const portedLater = (stack) => {
    const frame = stack.split("\n").slice(2).find((f) => f.includes("/src/"));
    return !!frame && /\/src\/(sync|components\/import|components\/onboarding)\//.test(frame) && !frame.includes(".test.mjs");
  };
  useBrowser.setState = (partial, replace) => {
    const stack = new Error().stack ?? "";
    if (depth > 0 && current && outsideStore(stack)) foreign = true;
    if (depth === 0 && current && !batch && spec.applyState && !replace && portedLater(stack)) {
      const value = typeof partial === "function" ? partial(useBrowser.getState()) : partial;
      const slices = Object.keys(value ?? {}).filter((k) => SLICES.has(k));
      if (slices.length) {
        const fromSync = (globalThis.__replayOrderChoices?.read() ?? 0) > 0;
        const projected = {};
        for (const k of slices) projected[k] = k === "ui" ? plain({ focusedWindowId: value.ui.focusedWindowId, focusOrder: value.ui.focusOrder, lastProfileId: value.ui.lastProfileId }) : plain(value[k]);
        return globalThis.__replayCommand("applyState", [projected, { fromSync }], () => rawSetState(value, replace), true);
      }
      return rawSetState(value, replace);
    }
    rawSetState(partial, replace);
    const rewrap = wrap(useBrowser.getState());
    if (Object.keys(rewrap).length) rawSetState(rewrap);
  };
  rawSetState(wrap(useBrowser.getState()));

  const settle = (value, then, fail) => {
    if (value && typeof value.then === "function") return value.then((v) => (then(v), v), (error) => (fail(), Promise.reject(error)));
    then(value);
    return value;
  };
  const seenCalls = new Set();
  const keptPerTest = new Map();
  if (spec.adapters) {
    adapterHook = (name, args, build) => {
      const kinds = RECORDED_ADAPTERS.get(name);
      if (!kinds) return build(args);
      let callbacks = null;
      const given = args.map((a, i) =>
        kinds[i] === "callback" && typeof a === "function"
          ? (...x) => (callbacks?.push(plain(x)), a(...x))
          : kinds[i] === "host" && typeof a === "function"
            ? (...x) => globalThis.__replayHost("readLogins", x, () => a(...x))
            : a,
      );
      const hosted = HOSTED_ADAPTERS.has(name);
      const profileOf = () => (typeof args[0] === "string" ? args[0] : "default");
      const hostState = () => {
        const s = useBrowser.getState();
        const p = profileOf();
        if (name === "passwordsAdapter") return { engine: model.engineProfile(p) };
        if (name === "bookmarksAdapter") return plain({ engine: model.engineProfile(p), bookmarks: s.bookmarks, bookmarksReady: !!s.bookmarksReady?.[p] });
        return plain({
          engine: model.engineProfile(p),
          history: s.history?.[p] ?? null,
          historyReady: !!s.historyReady?.[p],
          ...(typeof s.historyFloor?.[p] === "number" && Number.isFinite(s.historyFloor[p]) ? { historyFloor: s.historyFloor[p] } : {}),
        });
      };
      let lastExtract = null;
      const adapter = build(given);
      const describe = () =>
        args.map((a, i) => {
          const kind = kinds[i] ?? "plain";
          if (kind === "read") return { read: plain(a()) };
          if (kind === "themeRecords") {
            const records = a();
            return { read: records ? plain(Object.fromEntries(Object.entries(records).filter(([k]) => k.startsWith("pth:")))) : null };
          }
          if (kind === "callback") return { callback: typeof a === "function" };
          if (kind === "host") return { host: typeof a === "function" };
          return plain(a);
        });
      const begin = (kind) => {
        const testNow = Date.now === stubNow ? null : Date.now;
        const now = testNow ? testNow() : stubNow();
        frozen = now;
        const c = {
          test: current,
          now,
          memory: readMemory(),
          config: readConfig(),
          adapter: { name, args: describe() },
          call: kind,
          before: spec.before(useBrowser.getState(), model),
          lookups: [],
          commands: [],
          callbacks: [],
          ...(hosted ? { host: hostState(), hostCalls: [] } : {}),
          ...(adapter.__replayMemory ? { adapterMemory: plain(adapter.__replayMemory()) } : {}),
        };
        hostLog = c.hostCalls ?? null;
        c.restore = () => {
          frozen = null;
          if (testNow) Date.now = testNow;
        };
        if (testNow) Date.now = () => now;
        globalThis.__replayCalls = { urls: {}, resolve: [], prefix: null, sent: [] };
        adapterCall = c;
        callbacks = c.callbacks;
        return c;
      };
      const end = (c, ok) => {
        c.restore();
        delete c.restore;
        hostLog = null;
        if (hosted) c.hostAfter = hostState();
        if (adapter.__replayMemory) c.adapterMemoryAfter = plain(adapter.__replayMemory());
        const { sent: _sent, ...web } = globalThis.__replayCalls ?? {};
        c.web = web;
        globalThis.__replayCalls = null;
        adapterCall = null;
        callbacks = null;
        c.after = spec.project(useBrowser.getState(), model);
        c.memoryAfter = readMemory();
        if (c.call === "apply" && wronglyTyped(c.after)) c.lossy = "the state after holds a field of the wrong type, which a typed store cannot carry";
        if (!ok || !c.test) return;
        const { test: _t, now: _n, ...rest } = c;
        const digest = createHash("sha1").update(JSON.stringify(rest)).digest("hex");
        if (seenCalls.has(digest)) return;
        seenCalls.add(digest);
        const n = keptPerTest.get(c.test) ?? 0;
        keptPerTest.set(c.test, n + 1);
        if (cap && n >= cap && n % 8 !== 0) return;
        cases.push(c);
      };
      const logged = (c, kind, fn) =>
        typeof fn === "function"
          ? (key) => {
              const answer = fn(key);
              c.lookups.push(answer === undefined ? [kind, key] : [kind, key, plain(answer)]);
              return answer;
            }
          : fn;
      return {
        ...adapter,
        ...(typeof adapter.editedAt === "function"
          ? {
              editedAt: (value) => {
                const answer = adapter.editedAt(value);
                lastExtract?.editedAt?.push(answer === undefined ? [plain(value)] : [plain(value), plain(answer)]);
                return answer;
              },
            }
          : {}),
        extract: (base, queued, at, known, remote, stamp, downloading, agreedKeys, unapplied) => {
          const c = begin("extract");
          c.at = at ?? null;
          if (typeof unapplied === "function") c.unappliedGiven = true;
          let result;
          try {
            result = adapter.extract(logged(c, "base", base), logged(c, "queued", queued), at, logged(c, "known", known), logged(c, "remote", remote ?? (() => undefined)), logged(c, "stamp", stamp), downloading, agreedKeys, logged(c, "unapplied", unapplied));
          } catch (error) {
            end(c, false);
            throw error;
          }
          const asked = (kind, fn) => (typeof fn === "function" ? (key) => {
            const answer = fn(key);
            c.asked.push([kind, key, answer]);
            return answer;
          } : fn);
          const wrapExtraction = (r) => {
            if (!r) return r;
            return {
              ...r,
              ignore: asked("ignore", r.ignore),
              republish: asked("republish", r.republish),
              published: typeof r.published === "function" ? (keys) => {
                c.published = [...keys];
                const before = plain(useBrowser.getState().pinChoices ?? null);
                const out = r.published(keys);
                c.publishedChoices = { before, after: plain(useBrowser.getState().pinChoices ?? null) };
                return out;
              } : r.published,
            };
          };
          let shown = null;
          const outcome = settle(
            result,
            (r) => {
              c.values = r ? [...r.values].map(([k, v]) => (v === undefined ? [k] : [k, plain(v)])) : null;
              c.asked = [];
              c.editedAt = [];
              lastExtract = c;
              end(c, true);
              shown = wrapExtraction(r);
            },
            () => end(c, false),
          );
          return outcome && typeof outcome.then === "function" ? outcome.then(() => shown) : shown;
        },
        apply: (visible, changed, base, records) => {
          const c = begin("apply");
          c.visible = [...visible].map(([k, v]) => [k, plain(v)]);
          c.changed = [...changed];
          c.records = records ? { now: records.now, horizon: records.horizon, joined: !!records.joined } : null;
          if (globalThis.__replayRedesign?.on) c.redesign = true;
          let result;
          try {
            result = adapter.apply(visible, changed, logged(c, "base", base), records ? { ...records, known: logged(c, "recordKnown", records.known) } : records);
          } catch (error) {
            end(c, false);
            throw error;
          }
          return settle(
            result,
            (r) => {
              c.result = r === undefined ? null : r instanceof Set ? { written: [...r] } : plain(r);
              end(c, true);
            },
            () => end(c, false),
          );
        },
      };
    };
  }

  let failures = 0;
  for (const t of tests) {
    if (t.skip || !t.fn) continue;
    current = t.name;
    try {
      for (const fn of hooks.beforeEach) await fn();
      await t.fn({ name: t.name, mock: realTest.mock, test: () => {}, after: () => {}, skip: () => {}, diagnostic: () => {} });
      for (const fn of hooks.afterEach) await fn();
    } catch (error) {
      failures++;
      console.error(`test failed under replay, its cases dropped: ${t.name}: ${error?.message ?? error}`);
      cases = cases.filter((c) => c.test !== t.name);
    }
    current = null;
  }
  if (spec.timeless) {
    const seen = new Set();
    cases = cases.filter((c) => {
      const { test: _t, now: _n, ids: _i, ...rest } = c;
      const key = JSON.stringify(rest);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }
  const perTest = new Map();
  for (const c of cases) perTest.set(c.test, (perTest.get(c.test) ?? 0) + 1);
  const huge = new Set(cases.filter((c) => Object.keys(c.before?.tabs ?? {}).length > 1000).map((c) => c.test));
  const seenPerTest = new Map();
  cases = cases.filter((c) => {
    const total = perTest.get(c.test);
    const n = seenPerTest.get(c.test) ?? 0;
    seenPerTest.set(c.test, n + 1);
    const limit = huge.has(c.test) ? Math.min(cap || 10, 10) : cap;
    return !limit || total <= limit || n % Math.ceil(total / limit) === 0;
  });
  if (spec.deltas) cases = encodeDeltas(cases);
  mkdirSync(out, { recursive: true });
  const inSrc = !relative(join(app, "src"), file).startsWith("..");
  const name = (inSrc ? relative(join(app, "src"), file) : relative(join(app, "scripts"), file)).replace(/\.test\.mjs$/, "").replaceAll("/", "__");
  const target = join(out, `${phase}__${name}.json`);
  const document = JSON.stringify({ phase, file: relative(app, file), cases }) + "\n";
  if (cases.length && spec.deltas && !plainOutput) writeFileSync(`${target}.deflate`, deflateRawSync(Buffer.from(document), { level: 9 }));
  else if (cases.length) writeFileSync(target, document);
  else if (existsSync(target)) writeFileSync(target, JSON.stringify({ phase, file: relative(app, file), cases: [] }) + "\n");
  else if (existsSync(`${target}.deflate`)) writeFileSync(`${target}.deflate`, deflateRawSync(Buffer.from(JSON.stringify({ phase, file: relative(app, file), cases: [] }))));
  console.log(`recorded ${cases.length} cases${failures ? `, ${failures} tests failed under replay` : ""}`);
  process.exit(0);
}

function projectState(s) {
  return plain({
    profiles: s.profiles,
    profileOrder: s.profileOrder,
    orphanedProfileData: s.orphanedProfileData,
    windows: s.windows,
    windowOrder: s.windowOrder,
    tabs: s.tabs,
    groups: s.groups,
    splits: s.splits,
    peeks: s.peeks,
    closedTabs: s.closedTabs,
    closedWindows: s.closedWindows,
    closedGroups: s.closedGroups,
    deletedGroups: s.deletedGroups,
    cleanedTabs: s.cleanedTabs,
    privateCleanedTabs: s.privateCleanedTabs,
    privateSiteMutes: s.privateSiteMutes,
    parkedPins: s.parkedPins,
    pinChoices: s.pinChoices,
    pinSync: s.pinSync,
    downloads: s.downloads,
    settings: s.settings,
    ui: { focusedWindowId: s.ui.focusedWindowId, focusOrder: s.ui.focusOrder, lastProfileId: s.ui.lastProfileId },
  });
}

function projectCaches(s) {
  return plain({
    historyHints: Object.fromEntries(Object.entries(s.history ?? {}).map(([p, list]) => [p, list.map((h) => ({ url: h.url, title: h.title, favicon: h.favicon }))])),
    playingAudio: Object.keys(s.live ?? {}).filter((id) => s.live[id]?.playingAudio),
  });
}

async function phases(name) {
  const ui = await import(pathToFileURL(join(app, "src/store/ui.ts")).href);
  const privateSessionOpen = (s, session, model) =>
    Object.values(s.windows).some((w) => w.incognito && model.privateSession(w.profileId) === session);
  const specs = {
    "1a": {
      timeless: true,
      probes: true,
      commands: ["updateSettings", "upsertDownload", "removeDownload", "clearDownloads", "forgetDownloads", "hydrate"],
      project: (s) => ({ settings: plain(s.settings), downloads: plain(s.downloads) }),
      command(name, callArgs, s, model) {
        switch (name) {
          case "updateSettings":
            return { name, args: [plain(callArgs[0]), { fromSync: !!callArgs[1]?.fromSync }] };
          case "upsertDownload": {
            const d = callArgs[0];
            const session = ui.downloadSession(d);
            const focused = s.ui.focusedWindowId;
            const context = {};
            if (session !== null) context.privateSession = { open: privateSessionOpen(s, session, model) };
            if (focused && ui.downloadVisibleIn(d, s.windows[focused])) context.focusedWindowShowing = focused;
            return { name, args: [plain(d), context] };
          }
          case "removeDownload":
            return { name, args: [callArgs[0]] };
          case "clearDownloads": {
            const windowId = callArgs[0];
            const visibleIds = windowId === undefined ? null : s.downloads.filter((d) => ui.downloadVisibleIn(d, s.windows[windowId])).map((d) => d.id);
            return { name, args: [{ visibleIds }] };
          }
          case "forgetDownloads": {
            const session = model.privateSession(callArgs[0]);
            const gone = (d) => (session !== null ? ui.downloadSession(d) === session : d.profile === callArgs[0]);
            return { name, args: [{ ids: s.downloads.filter(gone).map((d) => d.id), privateSession: session !== null }] };
          }
          case "hydrate":
            return { name, args: [{ settings: plain(callArgs[0]?.settings) }] };
        }
        return null;
      },
      extra: (name, callArgs, before, after) => (name === "hydrate" ? { profileOrder: plain(after.profileOrder), downloadsGiven: callArgs[0]?.downloads !== undefined } : {}),
      noteMemory(name, callArgs, before, after, memory, model) {
        if (name === "upsertDownload") {
          const d = callArgs[0];
          const exists = before.downloads.some((x) => x.id === d.id);
          const session = ui.downloadSession(d);
          if (!exists && session !== null && (!privateSessionOpen(before, session, model) || memory.endedPrivateDownloads.has(d.id))) {
            memory.endedPrivateDownloads.add(d.id);
          }
        }
        if (name === "forgetDownloads") {
          const session = model.privateSession(callArgs[0]);
          if (session !== null) for (const d of before.downloads) if (ui.downloadSession(d) === session) memory.endedPrivateDownloads.add(d.id);
        }
      },
    },
    "1b": {
      deltas: true,
      batches: true,
      engineCommands: true,
      applyState: true,
      commands: [
        "newTab", "closeTab", "closeTabs", "activate", "handOffPin", "activateIndex", "cycle", "navigate", "updateTab", "navigated", "faviconChanged",
        "duplicateTab", "togglePin", "moveTab", "moveTabBy", "createWindow", "closeWindow", "setWindowFrame", "setWindowFullScreen", "toggleSidebar",
        "switchProfile", "moveTabsToWindow", "moveTabToProfile", "mergeAllWindows", "reopenClosed", "reopenClosedTab", "reopenClosedWindow",
        "restoreClosed", "createProfile", "updateProfile", "deleteProfile", "reorderProfiles", "setDefaultProfile", "profileDataDeleted",
        "createGroup", "updateGroup", "addTabsToGroup", "removeTabsFromGroup", "ungroup", "newNestedGroup", "closeGroup", "deleteGroup",
        "placeTabs", "dropTabs", "pinTabs", "returnToPinnedUrl", "setPinnedUrl", "setMuted", "setSiteMuted", "groupTabs", "groupOnto", "moveGroup",
        "duplicateGroup", "newTabInGroup", "cleanUpTabs", "restoreCleaned", "clearUnpinnedTabs", "undoClearTabs",
        "removeClosedPin", "closeAbandonedNewTabs", "createSplit", "openSplitPane", "replaceSplitPane", "removeTabFromSplit", "separateSplit",
        "updateSplit", "flipSplit", "toggleSplitOrientation", "movePane", "focusPane", "toggleTabLayout", "openPeek", "closePeek", "peekToTab",
        "updateSettings", "setFocusedWindow", "upsertDownload", "removeDownload", "clearDownloads", "forgetDownloads", "hydrate",
      ],
      recordsResult: true,
      returning: new Set([
        "newTab", "duplicateTab", "createWindow", "moveTabsToWindow", "createProfile", "createGroup", "newNestedGroup", "dropTabs", "groupTabs", "groupOnto",
        "duplicateGroup", "newTabInGroup", "cleanUpTabs", "clearUnpinnedTabs", "removeClosedPin", "createSplit", "openSplitPane", "openPeek", "peekToTab",
      ]),
      project: (s) => projectState(s),
      before: (s) => ({ ...projectState(s), caches: projectCaches(s) }),
      command(name, callArgs) {
        if (name === "updateTab" || name === "navigated") callArgs = callArgs.slice(0, 2);
        if (name === "hydrate") {
          const { history: _h, bookmarks: _b, ...data } = callArgs[0] ?? {};
          callArgs = [data];
        }
        const { args } = bridgeArgs(name, callArgs);
        const lossy = (name === "updateSettings" && undefinedKeyIn(callArgs[0])) || (name === "hydrate" && undefinedKeyIn(callArgs[0]?.settings));
        return { name, args, ...(lossy ? { lossy } : {}) };
      },
      extra: () => (globalThis.__replayTabs && !globalThis.__replayTabs.defaultOpener() ? { precheck: "an app URL opener is installed, which JS checks before dispatch" } : {}),
    },
  };
  specs.adapters = { ...specs["1b"], adapters: true, batches: false, engineCommands: false };
  if (!specs[name]) throw new Error(`unknown phase ${name}`);
  return specs[name];
}

if (child) await record(child);
else orchestrate();
