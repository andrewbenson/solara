#!/usr/bin/env node
import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import { fork } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { deflateRawSync } from "node:zlib";

const HELP = `usage: node scripts/native/engineScenario.mjs [--out <dir>] [--runs <n>] [--steps <n>] [--seed <n>]
       node scripts/native/engineScenario.mjs --oracle <n> [--steps <n>] [--seed <n>]

Runs sync engine scenarios through the real engine.ts, the JS store and every JS adapter, over fake
natives (a shared in-memory sync folder, sealing as "sealed:<text>", documents in memory, timers that
only fire when a step fires them). A second Mac runs in a child process with its own module memory and
reaches the folder through the parent, so the folder holds what two real Macs would leave in it.

Each scenario's trace is per step: the native calls this Mac made in order (folder reads, writes and
removes with their answers, chain status, device ids, phrases, unlock, forget, deviceName,
readPasswords, the extension probe), each sync.json and journal-before-write save, and each UI publish;
then at the step's end, drained, the documents (sync.json and the plaintext of the sealed state and
journal), the store's state, the bookmark tree, the history lists, the engine's memory and its pending
timers. Writes of the sealed state and later journal rewrites happen on a detached chain in JS, so they
are left out of the ordered calls and compared at step ends instead. Every folder write also records
whether the journal on disk already held its batch.

SolaraSyncTests replays the scripts through the Swift engine, answering native calls from the trace.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Scenarios (engine.json.deflate).

--oracle <n> runs n convergence scenarios from --seed instead, each in its own process: both Macs
edit, crash, lose or roll back their state, go locked, fail writes and see the newest folder files
only as pending or damaged for up to nine minutes, at random, then settle. Both
must end with the same data; for every key, the value that wins is the latest choice by its stamp,
counting a write that carries a real edit or a position repair as a choice of its whole record, and
excusing only edits that never reached the folder before their Mac lost its state, that the same
Mac replaced or reverted before sending, or saved passwords changed while a rebuilding Mac couldn't
read them yet. No seq may carry two different batches, and once a Mac has saved since its launch,
its saved state and deltas must replay to the last state it wrote whenever it's idle. ORACLE_KEY=<url,
setting or prof:> prints one key's edits, writes and losses; ORACLE_ENGINE=<file> runs another
engine.ts; ORACLE_TRACE=1 keeps every step's full trace; ORACLE_STRICT=1 stops counting a position
repair as a choice; ORACLE_REDESIGN=1 runs with the syncRedesign switch on, over a Login Data with its
own sync mark; ORACLE_STATE_FILES=1 also damages the newest state delta or journal batch file.`;

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args[at + 1];
};
const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "../..");
const out = resolve(option("--out", join(app, "../../native/SolaraKit/Tests/SolaraSyncTests/Scenarios")));
const runs = Number(option("--runs", "40"));
const stepsPerRun = Number(option("--steps", "45"));
const firstSeed = Number(option("--seed", "1"));
const role = option("--role", "parent");
const oracleRuns = Number(option("--oracle", "0"));
const repairsAreChoices = !process.env.ORACLE_STRICT;

const START = 1_793_000_000_000;
const HIDDEN_AT_MOST_MS = 9 * 60_000;

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const plain = (v) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

async function environment(prefix, sharedFolderOps) {
  let foldersInFlight = 0;
  const folderOps = async (op, a) => {
    foldersInFlight++;
    try {
      return await sharedFolderOps(op, a);
    } finally {
      foldersInFlight--;
    }
  };
  let now = START;
  Date.now = () => now;
  Math.random = mulberry32(prefix === "o" ? 0xbeef : 0x5eed);
  globalThis.__DEV__ = false;
  const pendingTimers = [];
  let timerIds = 0;
  let calls = null;
  globalThis.setTimeout = (fn, delay = 0, ...rest) => {
    const id = ++timerIds;
    if (delay === 100 || delay === 250) setImmediate(() => fn(...rest));
    else {
      pendingTimers.push({ id, delay, fn: () => fn(...rest) });
      calls?.push({ timer: delay });
    }
    return id;
  };
  globalThis.clearTimeout = (id) => {
    const at = pendingTimers.findIndex((t) => t.id === id);
    if (at < 0) return;
    calls?.push({ cancel: pendingTimers[at].delay });
    pendingTimers.splice(at, 1);
  };
  const heldNatives = new Set();
  const nativeGates = [];
  const gate = async (name) => {
    if (heldNatives.has(name)) await new Promise((resolve) => nativeGates.push(resolve));
  };
  const modes = { chain: "ok", unlock: true, phrase: true, creation: true, passwordsNull: false };
  let deviceIds = 0;
  const recordCall = (n, a, r) => calls?.push(r === undefined ? { n, a: plain(a) } : { n, a: plain(a), r: plain(r) });
  const shellFake = { docs: null, journalHolds: null };
  const native = {
    newDeviceId: () => {
      const id = `${prefix}dev${++deviceIds}`;
      recordCall("newDeviceId", [], id);
      return id;
    },
    deviceName: () => {
      const name = prefix === "o" ? "Other Mac" : "This Mac";
      recordCall("deviceName", [], name);
      return name;
    },
    createSync: async (folder, inspectionID) => {
      await gate("createSync");
      if (!modes.creation) {
        recordCall("createSync", [folder, inspectionID], { error: "creation refused" });
        throw new Error("creation refused");
      }
      if (!modes.phrase) {
        recordCall("createSync", [folder, inspectionID], null);
        return null;
      }
      const account = `${prefix}dev${++deviceIds}`;
      await folderOps("createChain", []);
      recordCall("createSync", [folder, inspectionID], account);
      return account;
    },
    enterPhrase: async (account, text, folder) => {
      await gate("enterPhrase");
      const result = modes.phrase ? { ok: true } : { error: "mismatch" };
      recordCall("enterPhrase", [account, text, folder], result);
      return result;
    },
    unlock: async (account) => (await gate("unlock"), recordCall("unlock", [account], modes.unlock), modes.unlock),
    forget: async (account) => (await gate("forget"), void recordCall("forget", [account])),
    chainStatus: async (folder) => (await gate("chainStatus"), recordCall("chainStatus", [folder], modes.chain), modes.chain),
    deleteChain: async (folder) => {
      await folderOps("deleteChain", []);
      recordCall("deleteChain", [folder]);
    },
    write: async (folder, scope, payload) => {
      await gate("write");
      const file = JSON.parse(payload);
      const held = shellFake.journalHolds(scope, file);
      const id = await folderOps("write", [scope, payload]);
      calls?.push({ n: "write", a: [folder, scope, payload], r: id, journaled: held });
      return id;
    },
    read: async (folder, scope, known) => {
      await gate("read");
      const listing = await folderOps("read", [scope, known]);
      recordCall("read", [folder, scope, known], listing);
      return listing;
    },
    remove: async (folder, scope, ids) => {
      await folderOps("remove", [scope, ids]);
      recordCall("remove", [folder, scope, ids]);
    },
    sealLocal: async (text) => (await gate("sealLocal"), `sealed:${text}`),
    openLocal: async (sealed) => (await gate("openLocal"), sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async (profile) => {
      const logins = modes.passwordsNull ? null : [...(shellFake.logins?.() ?? [])];
      recordCall("readPasswords", [profile], logins);
      return logins;
    },
    folderInfo: async () => ({ path: "/sync", defaultPath: "/sync", iCloudAvailable: false, inICloud: false, exists: true, writable: true, hasSyncData: true }),
    chooseFolder: async () => null,
  };
  globalThis.acTestNativeModules = { SolaraSyncAdapter: native };
  await import(pathToFileURL(join(app, "src/test-loader.mjs")).href);
  registerHooks({
    load(url, context, next) {
      const loaded = next(url, context);
      if (loaded.source == null) return loaded;
      let source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
      if (url.includes("/src/sync/engine.ts")) {
        if (process.env.ORACLE_ENGINE) source = readFileSync(process.env.ORACLE_ENGINE, "utf8");
        source = source.replace(
          "if (profiles.length && (await probeExtensionSync(profiles[0]!))) watchExtensionIntents(profiles);",
          "if (profiles.length && (await globalThis.__traceProbe(profiles[0]!, () => probeExtensionSync(profiles[0]!)))) watchExtensionIntents(profiles);",
        );
        source = source.replace("  useBrowser.subscribe((s, prev) => {", "  globalThis.__engineUnsubscribe = useBrowser.subscribe((s, prev) => {");
        if (source.includes("writtenOf(scopes)")) {
          const anchors = [
            ["  const snapshot = writtenOf(scopes);", "  const snapshot = writtenOf(scopes);\n  const oracleFull = JSON.stringify(scopes);"],
            ["          written = snapshot;", "          written = snapshot;\n          globalThis.__stateWritten = oracleFull;\n          globalThis.__freezeWritten(snapshot);"],
          ];
          for (const [anchor, replacement] of anchors) {
            if (!source.includes(anchor)) throw new Error(`the replay oracle's anchor is gone from engine.ts: ${anchor.trim()}`);
            source = source.replace(anchor, replacement);
          }
        }
        source += `\nglobalThis.__engineMemory = () => ({ loaded, doc, savedJson, stateGeneration: typeof stateGeneration === "undefined" ? null : stateGeneration, written: typeof written !== "undefined" && !!written, compactNext: typeof compactNext !== "undefined" && compactNext, journal, forcePasswords, running, again, sealing: !!sealing, passwords: Object.fromEntries([...passwordAdapters].map(([k, a]) => [k, a.__replayMemory?.() ?? null])), extensions: [...extensionAdapters.keys()] });\nglobalThis.__engineUi = useSync;\nglobalThis.__engineBaselines = () => baselines;\n`;
      } else if (url.endsWith("/src/sync/adapters.ts")) {
        source = source.replace('  return {\n    prefix: "pw:",', '  return {\n    __replayMemory: () => ({ lastRead, quietUntil, created: [...created] }),\n    prefix: "pw:",');
      } else if (url.endsWith("/src/store/model.ts")) {
        source += "\nglobalThis.__modelMemory = { read: () => ({ launch, counter, navSeq }) };\n";
      } else if (url.endsWith("/src/sync/pinned.ts")) {
        source += "\nglobalThis.__pinnedMemory = { read: () => Object.fromEntries([...localFolders].map(([k, v]) => [k, [...v].sort()])) };\n";
      } else {
        return loaded;
      }
      return { ...loaded, source };
    },
  });
  const deepFreeze = (value) => {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
      for (const inner of Object.values(value)) deepFreeze(inner);
    }
  };
  globalThis.__freezeWritten = (snapshot) => {
    for (const { maps } of snapshot.values()) for (const map of [maps.records, maps.files]) for (const value of Object.values(map)) deepFreeze(value);
  };
  globalThis.__traceProbe = async (profile, run) => {
    const answer = await run();
    recordCall("probeExtensionSync", [profile], answer);
    return answer;
  };
  const shell = await import(pathToFileURL(join(app, "src/test-native/index.ts")).href);
  shell.current.device = prefix || "local";
  shell.passwordStores.set(shell.current.device, new Map());
  shellFake.logins = () => [...shell.passwordStores.get(shell.current.device).values()];
  if (process.env.ORACLE_REDESIGN) {
    const marks = new WeakMap();
    const loginData = () => shell.passwordStores.get(shell.current.device);
    const { withSealedPasswords } = await import(pathToFileURL(join(app, "src/sync/redesign/fakeSeal.mjs")).href);
    withSealedPasswords(native, () => shell.solaraCoreNativeModules.SolaraCEF, () => marks.get(loginData()) ?? null);
    globalThis.acTestEngineCall = (name, _profile, args) => {
      if (name !== "ac_passwords_mark") return undefined;
      marks.set(loginData(), args.value);
      return { ok: true };
    };
    (await import(pathToFileURL(join(app, "src/sync/redesignSwitch.ts")).href)).syncRedesign.on = true;
  }
  const disk = new Map();
  const staged = new Map();
  const landing = [];
  const retrying = [];
  const docMode = { hold: false, fail: false };
  let generation = 0;
  const stage = (name, contents, done) => {
    const old = staged.get(name);
    const mine = ++generation;
    staged.set(name, { generation: mine, contents, waiters: [...(old?.waiters ?? []), ...(done ? [done] : [])] });
    landing.push([name, mine]);
    if (name === "sync.json") calls?.push({ doc: name, contents });
    else if (process.env.ENGINE_DOC_EVENTS) calls?.push({ staged: name, generation: mine, contents: contents.slice(0, 400), waiter: !!done });
  };
  const landOne = ([name, mine]) => {
    const save = staged.get(name);
    if (!save || save.generation !== mine) return;
    const waiters = save.waiters;
    if (docMode.fail) {
      save.waiters = [];
      retrying.push([name, mine]);
      for (const done of waiters) done(new Error("disk full"));
      return;
    }
    disk.set(name, save.contents);
    staged.delete(name);
    if (process.env.ENGINE_DOC_EVENTS) calls?.push({ landed: name, generation: mine, waiters: waiters.length });
    for (const done of waiters) done(null);
  };
  const landAll = () => {
    if (!docMode.fail) landing.push(...retrying.splice(0));
    while (landing.length) landOne(landing.shift());
  };
  const shellModule = shell.shellNativeModules.SolaraShell;
  shellModule.readDocument = (name) => staged.get(name)?.contents ?? disk.get(name) ?? null;
  shellModule.writeDocument = (name, contents) => stage(name, contents, null);
  shellModule.saveDocument = (name, contents) => new Promise((resolve, reject) => stage(name, contents, (error) => (error ? reject(error) : resolve())));
  shellModule.removeDocument = (name) => {
    staged.delete(name);
    disk.delete(name);
  };
  shellModule.listDocuments = (prefix) => [...new Set([...disk.keys(), ...staged.keys()])].filter((name) => name.startsWith(prefix)).sort();
  shellFake.journalHolds = (scope, file) => {
    if (file.kind !== "log") return null;
    const holds = (list) => (list ?? []).some((f) => f.device === file.device && f.seq === file.seq);
    const opened = (name) => {
      const text = disk.get(name);
      if (!text?.startsWith("sealed:")) return null;
      try {
        return JSON.parse(text.slice(7));
      } catch {
        return null;
      }
    };
    const batches = [...disk.keys()].filter((name) => name.startsWith("sync-journal-b-")).flatMap((name) => opened(name)?.journal?.[scope] ?? []);
    const state = (() => {
      try {
        return sealedState(disk);
      } catch {
        return null;
      }
    })();
    return holds(opened("sync-journal.nns")?.journal?.[scope]) || holds(batches) || holds(state?.[scope]?.journal);
  };
  const { sealedState } = await import(pathToFileURL(join(app, "src/sync/sealedState.mjs")).href);
  const { useBrowser } = await import(pathToFileURL(join(app, "src/store/browser.ts")).href);
  const { encodeArgs } = await import(pathToFileURL(join(app, "../../packages/store/src/encode.ts")).href);
  const S = () => useBrowser.getState();
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true }, historyReady: { default: true }, history: { default: [] } });
  S().createWindow();

  let engine = null;
  let launches = 0;
  let stepEdits = [];
  const edited = (kind, key, value, from, unseen = false) => stepEdits.push({ kind, key, value, from, ...(unseen ? { unseen } : {}) });
  const unseenByRebuild = (prefix) => {
    const memory = globalThis.__engineMemory?.();
    const link = memory?.doc?.profiles?.default;
    const scope = link && `p:${link.syncId}`;
    const state = scope && memory.doc.scopes?.[scope];
    return !!state?.rebuild && !state.rebuild.settled?.includes(prefix) && !globalThis.__engineBaselines?.().get(scope)?.has(prefix);
  };
  const inFlight = [];
  let unsubscribe = null;
  const launch = async () => {
    unsubscribe?.();
    globalThis.__engineUnsubscribe?.();
    globalThis.__engineUnsubscribe = null;
    pendingTimers.splice(0);
    inFlight.splice(0);
    heldNatives.clear();
    nativeGates.splice(0);
    engine = await import(`${pathToFileURL(join(app, "src/sync/engine.ts")).href}?${prefix}${++launches}`);
    const ui = globalThis.__engineUi;
    unsubscribe = ui.subscribe((state) => calls?.push({ publish: plain(state) }));
  };
  await launch();

  const drain = async () => {
    for (let idle = 0, i = 0; idle < 400 && i < 400_000; i++) {
      idle = foldersInFlight > 0 ? 0 : idle + 1;
      if (!docMode.hold) landAll();
      await new Promise((r) => setImmediate(r));
    }
  };

  const command = (name, ...callArgs) => {
    const result = S()[name](...callArgs);
    calls?.push({ store: { name, args: plain(encodeArgs(name, callArgs)) } });
    return result;
  };
  const jsOnly = () => calls?.push({ host: plain({ bookmarks: S().bookmarks, history: S().history, historyReady: S().historyReady, bookmarksReady: S().bookmarksReady }) });

  const remoteProfiles = () => globalThis.__engineUi.getState().remoteProfiles;
  const profileIds = () => S().profileOrder;

  async function runStep(step) {
    const pick = (list, i) => (list.length ? list[Math.abs(i ?? 0) % list.length] : undefined);
    switch (step.op) {
      case "start":
        engine.startSync();
        break;
      case "turnOn":
        inFlight.push(engine.turnOnSync(step.folder));
        break;
      case "join":
        inFlight.push(engine.enterRecoveryPhrase(step.folder, step.phrase));
        break;
      case "syncNow":
        inFlight.push(engine.syncNow());
        break;
      case "fire": {
        const due = pendingTimers.splice(0);
        for (const t of due) t.fn();
        break;
      }
      case "stop":
        inFlight.push(engine.stopSync({ deleteData: !!step.deleteData }));
        break;
      case "type":
        engine.setTypeSynced(step.type, step.value);
        break;
      case "profileSynced": {
        const id = pick(profileIds(), step.profile);
        if (id) engine.setProfileSynced(id, step.value);
        break;
      }
      case "addRemote": {
        const remote = pick(remoteProfiles(), step.pick);
        if (remote) engine.addRemoteProfile(remote.syncId);
        break;
      }
      case "adoptTheme": {
        const id = pick(profileIds(), step.profile);
        if (id) engine.adoptProfileTheme(id);
        break;
      }
      case "relaunch":
        if (!docMode.fail) for (const [name, save] of staged) disk.set(name, save.contents);
        staged.clear();
        landing.splice(0);
        retrying.splice(0);
        await launch();
        break;
      case "snapshot":
        globalThis.__snapshot = new Map(disk);
        break;
      case "crash":
        staged.clear();
        landing.splice(0);
        retrying.splice(0);
        if (step.snapshot && globalThis.__snapshot) {
          disk.clear();
          for (const [k, v] of globalThis.__snapshot) disk.set(k, v);
        }
        await launch();
        break;
      case "damage": {
        if (step.how === "newer") {
          const text = staged.get(step.doc)?.contents ?? disk.get(step.doc);
          if (!text?.startsWith("sealed:")) break;
          let parsed;
          try {
            parsed = JSON.parse(text.slice(7));
          } catch {
            break;
          }
          for (const scope of Object.values(parsed)) if (scope && typeof scope === "object") delete scope.seen, (scope.newerField = { added: true });
          staged.delete(step.doc);
          disk.set(step.doc, `sealed:${JSON.stringify(parsed)}`);
          break;
        }
        const damaged = { drop: null, corrupt: "sealed:{\"app\":", foreign: "sealed-elsewhere:{}", malformed: 'sealed:{"journal":{"app":[{"v":1,"kind":"log","device":"x","seq":1}]}}' }[step.how];
        const doc = step.doc.endsWith("-") ? [...new Set([...disk.keys(), ...staged.keys()])].filter((name) => name.startsWith(step.doc)).sort().at(-1) : step.doc;
        if (!doc) break;
        staged.delete(doc);
        if (damaged === null) disk.delete(doc);
        else disk.set(doc, damaged);
        break;
      }
      case "holdNative":
        for (const name of step.names) heldNatives.add(name);
        break;
      case "releaseNative":
        heldNatives.clear();
        for (const release of nativeGates.splice(0)) release();
        break;
      case "mode":
        modes[step.key] = step.value;
        break;
      case "hold":
        docMode.hold = step.value;
        break;
      case "failDocs":
        docMode.fail = step.value;
        break;
      case "land":
        landAll();
        break;
      case "advance":
        now += step.ms;
        break;
      case "bookmark": {
        const profileId = pick(profileIds(), step.profile) ?? "default";
        if (!S().bookmarksReady[profileId]) break;
        S().addBookmark({ profileId, url: step.url, title: step.title });
        if (profileId === "default") edited("bm-exists", step.url, true), edited("bm-title", step.url, step.title), edited("bm-parent", step.url, "bar");
        jsOnly();
        break;
      }
      case "renameBookmark":
      case "moveBookmark":
      case "deleteBookmark": {
        const node = pick(bookmarkNodes(), step.pick);
        if (!node || !S().bookmarksReady.default) break;
        if (step.op === "renameBookmark") {
          if (node.title === step.title) break;
          S().updateBookmark(node.id, { title: step.title });
          edited("bm-title", node.url, step.title, node.title);
        } else if (step.op === "moveBookmark") {
          if (node.parent === step.to) break;
          const roots = S().bookmarks.roots.default;
          S().moveBookmark(node.id, step.to === "bar" ? roots.bar : roots.other);
          edited("bm-parent", node.url, step.to, node.parent);
        } else S().removeBookmark(node.id), edited("bm-exists", node.url, false, true);
        jsOnly();
        break;
      }
      case "password": {
        const logins = shell.passwordStores.get(shell.current.device);
        if (logins.get(`${step.origin}\n${step.user}`)?.password === step.password) break;
        logins.set(`${step.origin}\n${step.user}`, { origin: `${step.origin}/`, url: step.origin, username: step.user, password: step.password, created: now });
        edited("pw", `${step.origin}\n${step.user}`, step.password, undefined, unseenByRebuild("pw:"));
        break;
      }
      case "ready":
        useBrowser.setState({ [step.store === "bookmarks" ? "bookmarksReady" : "historyReady"]: step.value ? { default: true } : {} });
        break;
      case "unpin": {
        const tab = pick(Object.values(S().tabs).filter((t) => t.pinned && t.profileId === "default"), step.pick);
        if (!tab) break;
        command("togglePin", tab.id);
        edited("pinned", tab.pinnedUrl ?? tab.url, false);
        break;
      }
      case "save":
        engine.setTypeSynced("history", true);
        break;
      case "visit": {
        const profileId = pick(profileIds(), step.profile) ?? "default";
        const list = [...(S().history[profileId] ?? [])].filter((e) => e.url !== step.url);
        list.unshift({ url: step.url, title: step.title, favicon: null, visits: step.visits ?? 1, lastVisit: now, visitTimes: [now] });
        useBrowser.setState({ history: { ...S().history, [profileId]: list } });
        if (profileId === "default") edited("history", step.url, true);
        jsOnly();
        break;
      }
      case "createProfile": {
        const id = command("createProfile", { name: step.name, color: step.color ?? "blue", icon: null, ...(step.share ? { shareWith: "default" } : {}) });
        useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [id]: true } });
        jsOnly();
        break;
      }
      case "rename": {
        const id = pick(profileIds(), step.profile);
        if (!id || S().profiles[id]?.name === step.name) break;
        const was = S().profiles[id]?.name;
        command("updateProfile", id, { name: step.name });
        if (id === "default") edited("name", "default", step.name, was);
        break;
      }
      case "theme": {
        const id = pick(profileIds(), step.profile);
        if (id) command("updateProfile", id, { theme: step.theme });
        break;
      }
      case "settings":
        for (const [key, value] of Object.entries(step.patch)) if (!S().settings.chosen?.includes(key) || JSON.stringify(S().settings[key]) !== JSON.stringify(value)) edited("setting", key, value, S().settings[key]);
        command("updateSettings", step.patch);
        break;
      case "recover": {
        const status = globalThis.__engineUi.getState().status;
        if (status === "locked") inFlight.push(engine.enterRecoveryPhrase("/sync", "abandon ability"));
        break;
      }
      case "pin": {
        const w = S().windowOrder[0];
        if (!w) break;
        const tab = command("newTab", w, { url: step.url });
        command("togglePin", tab);
        if (S().tabs[tab]?.profileId === "default") edited("pinned", step.url, true);
        break;
      }
      case "deleteProfile": {
        const id = pick(profileIds().filter((p) => p !== "default"), step.profile);
        if (id) command("deleteProfile", id);
        break;
      }
      default:
        throw new Error(`unknown step ${step.op}`);
    }
  }

  const sorted = (map) =>
    Object.fromEntries(
      [...map]
        .filter(([name]) => name.startsWith("sync"))
        .sort(([a], [b]) => (a < b ? -1 : 1))
        .map(([name, value]) => [name, typeof value === "string" ? value : value.contents]),
    );
  const snapshotDocs = () => ({ disk: sorted(disk), staged: sorted(staged) });
  const canonical = (value) =>
    Array.isArray(value) ? value.map(canonical) : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().filter((k) => value[k] !== undefined).map((k) => [k, canonical(value[k])])) : value;
  const replayDiffers = (memory) => {
    if (!memory.loaded || !memory.doc.enabled || memory.running || memory.sealing || docMode.fail || docMode.hold || retrying.length || !memory.stateGeneration || !memory.written || memory.compactNext) return null;
    const view = new Map(disk);
    for (const [name, save] of staged) view.set(name, save.contents);
    let replayed;
    try {
      replayed = JSON.stringify(canonical(sealedState(view)));
    } catch (error) {
      return `the saved state doesn't replay: ${error.message}`;
    }
    if (!globalThis.__stateWritten) return null;
    const held = JSON.stringify(canonical(JSON.parse(globalThis.__stateWritten)));
    if (replayed === held) return null;
    const a = JSON.parse(replayed);
    const b = JSON.parse(held);
    const where = [...new Set([...Object.keys(a), ...Object.keys(b)])].flatMap((scope) =>
      [...new Set([...Object.keys(a[scope] ?? {}), ...Object.keys(b[scope] ?? {})])].filter((k) => JSON.stringify(a[scope]?.[k]) !== JSON.stringify(b[scope]?.[k])).map((k) => `${scope}.${k}`),
    );
    return `the replayed state differs from the last state written at ${where.join(", ")}`;
  };

  const boundary = () => {
    const s = S();
    return plain({
      docs: snapshotDocs(),
      state: projectState(s),
      host: { bookmarks: s.bookmarks, history: s.history, historyReady: s.historyReady, bookmarksReady: s.bookmarksReady },
      memory: globalThis.__engineMemory(),
      model: globalThis.__modelMemory.read(),
      tileFolders: globalThis.__pinnedMemory?.read() ?? {},
      timers: pendingTimers.map((t) => t.delay),
      held: landing.length + retrying.length,
      heldNatives: nativeGates.length,
      inFlight: inFlight.length,
    });
  };

  function bookmarkNodes() {
    const s = S();
    const roots = s.bookmarks.roots.default;
    const out = [];
    const walk = (id, parent) => {
      const node = s.bookmarks.nodes[id];
      if (!node) return;
      if (node.kind === "url") out.push({ id, url: node.url, title: node.title, parent });
      else node.children.forEach((child) => walk(child, parent));
    };
    if (roots) {
      walk(roots.bar, "bar");
      walk(roots.other, "other");
    }
    return out.sort((a, z) => (a.url < z.url ? -1 : a.url > z.url ? 1 : 0));
  }
  const report = () => {
    const s = S();
    const logins = shell.passwordStores.get(shell.current.device) ?? new Map();
    return plain({
      status: globalThis.__engineUi.getState().status,
      bookmarks: Object.fromEntries(bookmarkNodes().map((n) => [n.url, { title: n.title, parent: n.parent }])),
      settings: Object.fromEntries(["searchEngine", "tabLayout", "warnBeforeQuitting", "appearance"].map((k) => [k, s.settings[k]])),
      name: s.profiles.default?.name,
      passwords: Object.fromEntries([...logins].sort(([a], [z]) => (a < z ? -1 : 1)).map(([k, l]) => [k, l.password])),
      history: (s.history.default ?? []).map((e) => e.url).sort(),
      pinned: [...new Set(Object.values(s.tabs).filter((t) => t.pinned && t.profileId === "default").map((t) => t.pinnedUrl ?? t.url))].sort(),
    });
  };

  return {
    report,
    init: () =>
      plain({ state: projectState(S()), model: globalThis.__modelMemory.read(), host: { bookmarks: S().bookmarks, history: S().history, historyReady: S().historyReady, bookmarksReady: S().bookmarksReady } }),
    async step(step) {
      calls = [];
      stepEdits = [];
      if (step.now !== undefined) now = step.now;
      const loadedBefore = globalThis.__engineMemory().loaded;
      await runStep(step);
      await drain();
      const memory = globalThis.__engineMemory();
      void loadedBefore;
      for (const p of [...inFlight]) {
        const settled = await Promise.race([p.then(() => true, () => true), new Promise((r) => setImmediate(() => r(false)))]);
        if (settled) inFlight.splice(inFlight.indexOf(p), 1);
      }
      const made = calls;
      calls = null;
      return { calls: made, after: boundary(), edits: stepEdits, replay: step.op === "damage" ? null : replayDiffers(memory) };
    },
  };
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

const THEME = { stops: [{ x: 0.2, y: 0.3, color: { r: 0.3, g: 0.75, b: 0.45, a: 1 } }], intensity: 0.8, mode: "auto", grain: 0.4, texture: "grain", translucency: 1, angle: 30 };

export function randomScript(seed, steps) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const n = () => Math.floor(rand() * 4);
  const script = { name: `random ${seed}`, steps: [] };
  const push = (mac, step) => script.steps.push({ mac, ...step });
  push("local", { op: "start" });
  push("other", { op: "start" });
  if (rand() < 0.5) {
    push("local", { op: "turnOn", folder: "/sync" });
    push("other", { op: "join", folder: "/sync", phrase: "abandon ability" });
  } else {
    push("other", { op: "turnOn", folder: "/sync" });
    push("local", { op: "join", folder: "/sync", phrase: "abandon ability" });
  }
  for (let i = 0; i < steps; i++) {
    const mac = rand() < 0.65 ? "local" : "other";
    const r = rand();
    if (r < 0.2) push(mac, { op: pick(["syncNow", "fire", "fire"]) });
    else if (r < 0.3) push(mac, { op: "bookmark", profile: n(), url: pick(["https://a.com/", "https://b.org/x", "https://c.net/"]), title: pick(["A", "B", "Ünï"]) });
    else if (r < 0.36) push(mac, { op: "visit", profile: n(), url: pick(["https://a.com/", "https://h.org/"]), title: "Visited" });
    else if (r < 0.42) push(mac, { op: "createProfile", name: pick(["Work", "School", "Ünï"]), share: rand() < 0.3 });
    else if (r < 0.47) push(mac, { op: "rename", profile: n(), name: pick(["Renamed", "Other", "Work"]) });
    else if (r < 0.5) push(mac, { op: "theme", profile: n(), theme: rand() < 0.3 ? null : { ...THEME, angle: Math.floor(rand() * 360) } });
    else if (r < 0.55) push(mac, { op: "settings", patch: pick([{ searchEngine: "duckduckgo" }, { tabLayout: "topbar" }, { warnBeforeQuitting: false }, { appearance: "dark" }]) });
    else if (r < 0.6) push(mac, { op: "pin", url: pick(["https://p.com/", "https://q.com/"]) });
    else if (r < 0.63) push(mac, { op: "addRemote", pick: n() });
    else if (r < 0.65) push(mac, { op: "profileSynced", profile: n(), value: rand() < 0.5 });
    else if (r < 0.67) push(mac, { op: "type", type: pick(["bookmarks", "history", "tabs", "pinned", "passwords", "extensions", "settings"]), value: rand() < 0.5 });
    else if (r < 0.69) push(mac, { op: "adoptTheme", profile: n() });
    else if (r < 0.71) push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.73) push(mac, { op: "snapshot" });
    else if (r < 0.745) push(mac, { op: "crash", snapshot: rand() < 0.4 }), push(mac, { op: "start" });
    else if (r < 0.76) push(mac, { op: "mode", key: "chain", value: pick(["ok", "ok", "unavailable", "missing"]) });
    else if (r < 0.77) push(mac, { op: "mode", key: "unlock", value: rand() < 0.6 });
    else if (r < 0.79) push(mac, { op: "hold", value: rand() < 0.5 });
    else if (r < 0.81) push(mac, { op: "land" });
    else if (r < 0.83) push(mac, { op: "deleteProfile", profile: n() });
    else if (r < 0.845) push(mac, { op: "stop", deleteData: rand() < 0.3 });
    else if (r < 0.86) push(mac, { op: pick(["turnOn", "join"]), folder: "/sync", phrase: "abandon ability" });
    else if (r < 0.9) push(mac, { op: "holdNative", names: [pick(["read", "write", "chainStatus", "unlock", "sealLocal", "openLocal", "forget", "createSync", "enterPhrase"])] });
    else if (r < 0.93) push(mac, { op: "releaseNative" });
    else if (r < 0.945) {
      const doc = pick(["sync-state.nns", "sync-journal.nns"]);
      push(mac, { op: "damage", doc, how: pick(doc === "sync-state.nns" ? ["drop", "corrupt", "foreign", "malformed", "newer"] : ["drop", "corrupt", "foreign", "malformed"]) }), push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    } else if (r < 0.955) push(mac, { op: "failDocs", value: rand() < 0.5 });
    else push(mac, { op: "advance", ms: pick([1000, 60_000, 3_600_000, 91 * 86_400_000]) });
  }
  for (const mac of ["local", "other"]) {
    push(mac, { op: "mode", key: "chain", value: "ok" });
    push(mac, { op: "mode", key: "unlock", value: true });
    push(mac, { op: "hold", value: false });
    push(mac, { op: "failDocs", value: false });
    push(mac, { op: "releaseNative" });
    push(mac, { op: "land" });
  }
  for (let round = 0; round < 3; round++) for (const mac of ["local", "other"]) push(mac, { op: "syncNow" });
  return script;
}

export const namedScripts = () => [
  {
    name: "turn on, edit, sync both ways",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://one.example/", title: "One" },
      { mac: "local", op: "syncNow" },
      { mac: "other", op: "start" },
      { mac: "other", op: "join", folder: "/sync", phrase: "abandon ability" },
      { mac: "other", op: "syncNow" },
      { mac: "other", op: "bookmark", profile: 0, url: "https://two.example/", title: "Two" },
      { mac: "other", op: "syncNow" },
      { mac: "local", op: "fire" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "a crash after a batch lands is sent again as it was",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://one.example/", title: "One" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "snapshot" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://two.example/", title: "Two" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "crash", snapshot: true },
      { mac: "local", op: "start" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://three.example/", title: "Three" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "a held journal save holds the batch back",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "hold", value: true },
      { mac: "local", op: "bookmark", profile: 0, url: "https://held.example/", title: "Held" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "hold", value: false },
      { mac: "local", op: "land" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "locked, then the phrase, then reset from elsewhere",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "mode", key: "unlock", value: false },
      { mac: "local", op: "relaunch" },
      { mac: "local", op: "start" },
      { mac: "local", op: "join", folder: "/sync", phrase: "abandon ability" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "mode", key: "chain", value: "missing" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "mode", key: "chain", value: "ok" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "profiles: remote ones are added, shared data follows, themes pair",
    steps: [
      { mac: "other", op: "start" },
      { mac: "other", op: "createProfile", name: "Work" },
      { mac: "other", op: "createProfile", name: "Shared", share: true },
      { mac: "other", op: "theme", profile: 1, theme: THEME },
      { mac: "other", op: "turnOn", folder: "/sync" },
      { mac: "other", op: "syncNow" },
      { mac: "local", op: "start" },
      { mac: "local", op: "createProfile", name: "Work" },
      { mac: "local", op: "join", folder: "/sync", phrase: "abandon ability" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "addRemote", pick: 0 },
      { mac: "local", op: "addRemote", pick: 0 },
      { mac: "local", op: "fire" },
      { mac: "local", op: "adoptTheme", profile: 1 },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "profileSynced", profile: 1, value: false },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "stop", deleteData: false },
    ],
  },
];

function inChild(roleName, message) {
  return new Promise((resolve, reject) => {
    const child = fork(fileURLToPath(import.meta.url), ["--role", roleName], { execArgv: ["--no-warnings", "--max-old-space-size=4096"], cwd: app, stdio: ["ignore", "inherit", "inherit", "ipc"] });
    const deadline = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${roleName} hung for 60 s`));
    }, 60_000);
    child.once("message", (reply) => {
      clearTimeout(deadline);
      child.kill();
      resolve(reply);
    });
    child.once("exit", (code) => code && reject(new Error(`${roleName} exited with ${code}`)));
    child.send(message);
  });
}

async function parent() {
  if (oracleRuns) return oracle();
  const scripts = [...namedScripts(), ...Array.from({ length: runs }, (_, i) => randomScript(firstSeed + i, stepsPerRun))];
  const cases = [];
  let crashed = 0;
  for (const script of scripts) {
    try {
      cases.push((await inChild("local", { script })).trace);
    } catch (error) {
      crashed++;
      console.error(`${script.name}: ${error.message}`);
    }
  }
  if (crashed) console.error(`${crashed} scenarios crashed`);
  mkdirSync(out, { recursive: true });
  const text = JSON.stringify({ cases });
  writeFileSync(join(out, "engine.json.deflate"), deflateRawSync(Buffer.from(text), { level: 9 }));
  const steps = cases.reduce((n, c) => n + c.steps.length, 0);
  const writes = cases.reduce((n, c) => n + c.steps.reduce((m, s) => m + (s.calls ?? []).filter((x) => x.n === "write").length, 0), 0);
  const unjournaled = cases.reduce((n, c) => n + c.steps.reduce((m, s) => m + (s.calls ?? []).filter((x) => x.n === "write" && x.journaled === false).length, 0), 0);
  console.log(`${cases.length} scenarios, ${steps} steps, ${writes} folder writes (${unjournaled} before their journal), ${(text.length / 1e6).toFixed(1)} MB`);
  process.exit(0);
}

async function oracle() {
  let failed = 0;
  for (let i = 0; i < oracleRuns; i++) {
    const script = oracleScript(firstSeed + i, stepsPerRun);
    let verdict;
    try {
      verdict = (await inChild("local", { script })).trace.oracle;
    } catch (error) {
      verdict = [`crashed: ${error.message}`];
    }
    if (verdict.length) {
      failed++;
      if (failed <= 8) console.log(`${script.name}: ${verdict.slice(0, process.env.ORACLE_KEY ? 999 : 3).join("; ")}`);
    }
  }
  console.log(`oracle: ${oracleRuns - failed} of ${oracleRuns} scenarios converge with every kept edit and no seq reused`);
  process.exit(failed ? 1 : 0);
}

async function runScenario(script) {
  const folder = new Map();
  let counter = 0;
  const published = new Map();
  const reused = [];
  const replays = [];
  const history = { at: 0, edits: [], losses: [], writes: [], removed: [], nows: script.steps.map((step, i) => step.now ?? script.steps.slice(0, i).findLast((s) => s.now !== undefined)?.now ?? 0) };
  const hidden = { local: new Map(), other: new Map() };
  const folderOps = async (op, a, mac = "local") => {
    switch (op) {
      case "write": {
        const [scope, payload] = a;
        const file = JSON.parse(payload);
        history.writes.push({ at: history.at, mac: String(file.device).startsWith("o") ? "other" : "local", ops: file.ops ?? Object.entries(file.records ?? {}).map(([k, r]) => ({ k, h: r.h, v: r.v })) });
        if (file.kind === "log") {
          const key = `${scope} ${file.device} ${file.seq}`;
          const ops = JSON.stringify(file.ops);
          if (published.has(key) && published.get(key) !== ops) reused.push(key);
          published.set(key, ops);
        }
        const id = `f${++counter}`;
        folder.set(id, { scope, payload });
        return id;
      }
      case "read": {
        const [scope, known] = a;
        const here = [...folder].filter(([, f]) => f.scope === scope);
        const now = history.nows[history.at - 1] ?? 0;
        const away = (id) => {
          const entry = hidden[mac].get(id);
          return entry && now - entry.since < HIDDEN_AT_MOST_MS ? entry.as : undefined;
        };
        return {
          files: here.filter(([id]) => !known.includes(id) && !away(id)).map(([id, f]) => ({ id, payload: f.payload })),
          pending: here.filter(([id]) => away(id) === "pending").map(([id]) => id),
          damaged: here.filter(([id]) => away(id) === "damaged").map(([id]) => ({ id, age: 0 })),
          present: here.map(([id]) => id),
        };
      }
      case "remove":
        if (process.env.ORACLE_KEY) history.removed.push(...a[1].filter((id) => folder.get(id)?.payload.includes(process.env.ORACLE_KEY)).map((id) => ({ at: history.at, id, payload: folder.get(id).payload.slice(0, 300) })));
        for (const id of a[1]) folder.delete(id);
        return null;
      case "deleteChain":
        folder.clear();
        return null;
      default:
        return null;
    }
  };
  const child = fork(fileURLToPath(import.meta.url), ["--role", "other"], { execArgv: ["--no-warnings"], cwd: app, stdio: ["ignore", "ignore", "inherit", "ipc"] });
  child.once("exit", (code) => code && process.exit(3));
  const waiting = new Map();
  let ids = 0;
  child.on("message", async (message) => {
    if (message.folder) child.send({ reply: message.id, value: await folderOps(message.folder, message.args, "other") });
    else if (message.done !== undefined) waiting.get(message.done)?.(message);
  });
  const ask = (payload) =>
    new Promise((resolve) => {
      const id = ++ids;
      waiting.set(id, resolve);
      child.send({ id, ...payload });
    });
  await ask({ ready: true });
  const local = await environment("", folderOps);
  const trace = { name: script.name, script, init: local.init(), steps: [] };
  const LOSSES = new Set(["relaunch", "crash", "damage"]);
  for (const step of script.steps) {
    history.at++;
    if (LOSSES.has(step.op)) history.losses.push({ at: history.at, mac: step.mac });
    let edits = [];
    if (step.op === "hide" || step.op === "reveal") {
      if (step.op === "reveal") hidden[step.mac].clear();
      else for (const id of [...folder.keys()].slice(-step.count)) hidden[step.mac].set(id, { as: step.as, since: history.nows[history.at - 1] ?? 0 });
      trace.steps.push({ op: step.op, hidden: [...hidden[step.mac]] });
    } else if (step.mac === "other") {
      const reply = await ask({ step });
      edits = reply.edits ?? [];
      if (reply.replay) replays.push(`other at step ${history.at}: ${reply.replay}`);
      trace.steps.push({ other: true, error: reply.error ?? null, folder: [...folder.keys()], ...(reply.result ? { after: reply.result.after, calls: reply.result.calls } : {}) });
    } else {
      try {
        const result = await local.step(step);
        edits = result.edits ?? [];
        if (result.replay) replays.push(`local at step ${history.at}: ${result.replay}`);
        if (!script.oracle) delete result.edits;
        trace.steps.push(script.oracle && !process.env.ORACLE_TRACE ? { op: step.op } : result);
      } catch (error) {
        trace.steps.push({ error: String(error?.message ?? error) });
      }
    }
    for (const edit of edits) history.edits.push({ ...edit, at: history.at, mac: step.mac });
  }
  if (script.oracle) trace.oracle = [...replays.slice(0, 3), ...oracleVerdict(local.report(), (await ask({ report: true })).report, reused, history)];
  child.kill();
  return trace;
}

function oracleVerdict(local, other, reused, history) {
  const problems = reused.map((key) => `seq ${key} carried two different batches`);
  for (const mac of [local, other]) if (mac.status !== "updated") problems.push(`a Mac ended ${mac.status}`);
  for (const field of ["bookmarks", "settings", "name", "passwords", "history", "pinned"])
    if (JSON.stringify(local[field]) !== JSON.stringify(other[field])) problems.push(`${field} differ: ${JSON.stringify(local[field])} vs ${JSON.stringify(other[field])}`);
  const bmKeys = new Map();
  for (const write of history.writes) for (const op of write.ops) if (op.k.startsWith("bm:") && op.v?.u) bmKeys.set(op.v.u, op.k);
  const pinKeys = new Map();
  for (const write of history.writes) for (const op of write.ops) if (op.k.startsWith("pin:t:") && op.v?.u) pinKeys.set(op.v.u, op.k);
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const carries = (edit, op) => {
    switch (edit.kind) {
      case "setting":
        return op.k === `set:${edit.key}` && same(op.v?.v, edit.value);
      case "name":
        return op.k.startsWith("prof:") && op.v?.d && op.v.n === edit.value;
      case "bm-exists":
        return edit.value ? op.k.startsWith("bm:") && op.v?.u === edit.key : op.k === bmKeys.get(edit.key) && op.v === null;
      case "bm-title":
        return op.k.startsWith("bm:") && op.v?.u === edit.key && op.v.t === edit.value;
      case "bm-parent":
        return op.k.startsWith("bm:") && op.v?.u === edit.key && op.v.p === edit.value;
      case "pw":
        return op.k === `pw:${edit.key}` && op.v?.p === edit.value;
      case "history":
        return op.k === `h:${edit.key}`;
      case "pinned":
        return edit.value ? op.k.startsWith("pin:t:") && op.v?.u === edit.key : op.k === pinKeys.get(edit.key) && op.v === null;
      default:
        return false;
    }
  };
  const ordered = [...history.writes].sort((a, z) => a.at - z.at);
  const carrier = (edit) => {
    if ("carrier" in edit) return edit.carrier;
    for (const w of ordered) if (w.mac === edit.mac && w.at >= edit.at) for (const op of w.ops) if (carries(edit, op)) return (edit.carrier = op);
    return (edit.carrier = null);
  };
  const reached = (edit) => carrier(edit) !== null;
  const lost = (edit) => !reached(edit) && history.losses.some((l) => l.mac === edit.mac && l.at > edit.at);
  const touches = (edit, op) => {
    switch (edit.kind) {
      case "setting":
        return op.k === `set:${edit.key}`;
      case "name":
        return op.k.startsWith("prof:") && !!op.v?.d;
      case "pw":
        return op.k === `pw:${edit.key}`;
      case "history":
        return op.k === `h:${edit.key}`;
      case "pinned":
        return op.v?.u === edit.key || op.k === pinKeys.get(edit.key);
      default:
        return op.v?.u === edit.key || op.k === bmKeys.get(edit.key);
    }
  };
  const sentBetween = (edit, from, to) => ordered.some((w) => w.mac === edit.mac && w.at >= from && w.at < to && w.ops.some((op) => touches(edit, op)));
  const unsent = (edit) => {
    if (reached(edit) || lost(edit)) return false;
    const mine = history.edits.filter((e) => e.mac === edit.mac && e.kind === edit.kind && e.key === edit.key && !sentBetween(edit, Math.min(e.at, edit.at), Math.max(e.at, edit.at)));
    return mine.some((e) => e.at > edit.at) || mine.some((e) => e.at <= edit.at && !reached(e) && e.from !== undefined && same(e.from, edit.value));
  };
  const exempt = (edit) => lost(edit) || unsent(edit) || (edit.unseen && !reached(edit));
  const stamp = (h) => [parseInt(h.split(".")[0], 36), h];
  const when = (edit) => (reached(edit) ? stamp(carrier(edit).h) : [history.nows[edit.at - 1] ?? 0, ""]);
  const later = (a, z) => {
    const [ta, ha] = when(a);
    const [tz, hz] = when(z);
    return ta !== tz ? ta > tz : ha !== hz ? ha > hz : a.at >= z.at;
  };
  const wholeRecord = (w, op) => [
    { at: w.at, mac: w.mac, kind: "bm-exists", key: op.v.u, value: true, carrier: op },
    { at: w.at, mac: w.mac, kind: "bm-title", key: op.v.u, value: op.v.t, carrier: op },
    { at: w.at, mac: w.mac, kind: "bm-parent", key: op.v.u, value: op.v.p, carrier: op },
  ];
  const shown = new Map();
  const implied = [];
  for (const w of ordered)
    for (const op of w.ops) {
      const pin = op.k.startsWith("pin:t:");
      if (!(op.k.startsWith("bm:") || pin) || !op.v?.u) continue;
      const earlier = shown.get(op.k) ?? [];
      const repair = earlier.some((before) => before.pos !== op.v.pos && same({ ...before, pos: op.v.pos }, op.v));
      shown.set(op.k, [...earlier, op.v]);
      if (pin) {
        if (repair && repairsAreChoices) implied.push({ at: w.at, mac: w.mac, kind: "pinned", key: op.v.u, value: true, carrier: op });
        continue;
      }
      const choice = history.edits.some((e) => e.mac === w.mac && e.key === op.v.u && e.kind.startsWith("bm-") && carrier(e) === op);
      if ((repair && repairsAreChoices) || choice) implied.push(...wholeRecord(w, op));
    }
  const groups = new Map();
  for (const edit of [...history.edits, ...implied].sort((a, z) => a.at - z.at)) {
    const id = `${edit.kind} ${edit.key}`;
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(edit);
  }
  const finalOf = (report, kind, key) => {
    const bm = report.bookmarks[key];
    switch (kind) {
      case "setting":
        return report.settings[key];
      case "name":
        return report.name;
      case "bm-exists":
        return !!bm;
      case "bm-title":
        return bm?.title;
      case "bm-parent":
        return bm?.parent;
      case "pw":
        return report.passwords[key];
      case "history":
        return report.history.includes(key);
      case "pinned":
        return report.pinned.includes(key);
    }
  };
  for (const [id, edits] of groups) {
    const [kind, ...rest] = id.split(" ");
    const key = rest.join(" ");
    if ((kind === "bm-title" || kind === "bm-parent") && !local.bookmarks[key]) continue;
    const kept = edits.filter((e) => !exempt(e));
    if (!kept.length) continue;
    const last = kept.reduce((latest, e) => (later(e, latest) ? e : latest));
    const allowed = [last.value, ...edits.filter((e) => e.at > last.at && exempt(e)).map((e) => e.value)].map((v) => JSON.stringify(v));
    const got = finalOf(local, kind, key);
    if (!allowed.includes(JSON.stringify(got))) problems.push(`${id} ended ${JSON.stringify(got)}; the latest kept choice was ${JSON.stringify(last.value)} (${last.mac}, step ${last.at})`);
  }
  if (process.env.ORACLE_KEY) {
    const url = process.env.ORACLE_KEY;
    const k = bmKeys.get(url) ?? pinKeys.get(url) ?? `set:${url}`;
    const lines = [
      ...history.edits.filter((e) => e.key === url || (url === "prof:" && e.kind === "name")).map((e) => ({ at: e.at, mac: e.mac, edit: e.kind, value: e.value })),
      ...history.writes.flatMap((w) => w.ops.filter((op) => op.k === k || op.v?.u === url || op.k.startsWith(url)).map((op) => ({ at: w.at, mac: w.mac, write: op.k, h: op.h, v: op.v }))),
      ...history.losses.map((l) => ({ at: l.at, mac: l.mac, loss: true })),
      ...history.removed.map((r) => ({ at: r.at, removed: r.id, payload: r.payload })),
    ].sort((a, z) => a.at - z.at);
    problems.push(...lines.map((line) => JSON.stringify(line)));
  }
  return problems;
}

const DAMAGED_DOCS = process.env.ORACLE_STATE_FILES ? ["sync-state.nns", "sync-journal.nns", "sync-state-d-", "sync-journal-b-"] : ["sync-state.nns", "sync-journal.nns"];

export function oracleScript(seed, steps) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const script = { name: `oracle ${seed}`, oracle: true, steps: [] };
  let clock = START;
  const push = (mac, step) => script.steps.push({ mac, ...step, now: (clock += 1000) });
  push("local", { op: "start" });
  push("other", { op: "start" });
  const [first, second] = rand() < 0.5 ? ["local", "other"] : ["other", "local"];
  push(first, { op: "turnOn", folder: "/sync" });
  push(first, { op: "syncNow" });
  push(second, { op: "join", folder: "/sync", phrase: "abandon ability" });
  push(second, { op: "syncNow" });
  let made = 0;
  const origins = ["https://a.example", "https://b.example", "https://c.example"];
  for (let i = 0; i < steps; i++) {
    const mac = rand() < 0.55 ? "local" : "other";
    const r = rand();
    if (r < 0.2) push(mac, { op: pick(["syncNow", "fire", "fire"]) });
    else if (r < 0.29) push(mac, { op: "bookmark", profile: 0, url: `https://${mac[0]}${++made}.example/`, title: pick(["A", "B", "Ünï"]) });
    else if (r < 0.33) push(mac, { op: "renameBookmark", pick: Math.floor(rand() * 8), title: pick(["Renamed", "Again", "Ünï 2"]) });
    else if (r < 0.36) push(mac, { op: "moveBookmark", pick: Math.floor(rand() * 8), to: pick(["bar", "other"]) });
    else if (r < 0.38) push(mac, { op: "deleteBookmark", pick: Math.floor(rand() * 8) });
    else if (r < 0.43) push(mac, { op: "settings", patch: pick([{ searchEngine: pick(["duckduckgo", "bing", "google"]) }, { tabLayout: pick(["topbar", "sidebar"]) }, { warnBeforeQuitting: rand() < 0.5 }, { appearance: pick(["dark", "light"]) }]) });
    else if (r < 0.46) push(mac, { op: "rename", profile: 0, name: pick(["Personal", "Home", "Mine"]) });
    else if (r < 0.49) push(mac, { op: "password", origin: pick(origins), user: pick(["me", "you"]), password: pick(["p1", "p2", "p3"]) });
    else if (r < 0.51) push(mac, { op: "visit", profile: 0, url: `https://h${++made}.example/`, title: "Visited" });
    else if (r < 0.53) push(mac, { op: "pin", url: `https://pin${++made}.example/` });
    else if (r < 0.545) push(mac, { op: "unpin", pick: Math.floor(rand() * 4) });
    else if (r < 0.565) push(mac, { op: "ready", store: pick(["bookmarks", "history"]), value: rand() < 0.5 });
    else if (r < 0.575) push(mac, { op: "mode", key: "passwordsNull", value: rand() < 0.5 });
    else if (r < 0.59) push(mac, { op: "save" });
    else if (r < 0.62) push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.645) push(mac, { op: "snapshot" });
    else if (r < 0.675) push(mac, { op: "crash", snapshot: rand() < 0.4 }), push(mac, { op: "start" });
    else if (r < 0.7) push(mac, { op: "damage", doc: pick(DAMAGED_DOCS), how: pick(["drop", "corrupt", "foreign", "malformed"]) }), push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.715) push(mac, { op: "damage", doc: "sync-state.nns", how: "newer" }), push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.75) push(mac, { op: "holdNative", names: [pick(["read", "write", "chainStatus", "unlock", "sealLocal", "openLocal"])] });
    else if (r < 0.785) push(mac, { op: "releaseNative" });
    else if (r < 0.81) push(mac, { op: "hold", value: rand() < 0.5 });
    else if (r < 0.835) push(mac, { op: "land" });
    else if (r < 0.85) push(mac, { op: "failDocs", value: rand() < 0.4 });
    else if (r < 0.87) push(mac, { op: "mode", key: "chain", value: pick(["ok", "ok", "unavailable"]) });
    else if (r < 0.885) push(mac, { op: "mode", key: "unlock", value: rand() < 0.7 });
    else if (r < 0.9) push(mac, rand() < 0.6 ? { op: "hide", count: 1 + Math.floor(rand() * 3), as: rand() < 0.7 ? "pending" : "damaged" } : { op: "reveal" });
    else clock += pick([1000, 60_000, 3_600_000]);
  }
  for (const mac of ["local", "other"]) {
    for (const step of [
      { op: "mode", key: "chain", value: "ok" },
      { op: "mode", key: "unlock", value: true },
      { op: "mode", key: "passwordsNull", value: false },
      { op: "ready", store: "bookmarks", value: true },
      { op: "ready", store: "history", value: true },
      { op: "failDocs", value: false },
      { op: "hold", value: false },
      { op: "releaseNative" },
      { op: "land" },
      { op: "recover" },
      { op: "reveal" },
    ])
      push(mac, step);
  }
  for (let round = 0; round < 5; round++) {
    if (round === 2) clock += 60_000;
    for (const mac of ["local", "other"]) push(mac, { op: "syncNow" }), push(mac, { op: "fire" });
  }
  return script;
}

async function other() {
  let ids = 0;
  const waiting = new Map();
  let env = null;
  const folderOps = (op, a) =>
    new Promise((resolve) => {
      const id = ++ids;
      waiting.set(id, resolve);
      process.send({ folder: op, args: a, id });
    });
  process.on("message", async (message) => {
    if (message.reply !== undefined) {
      waiting.get(message.reply)?.(message.value);
      waiting.delete(message.reply);
      return;
    }
    if (message.ready) {
      env = await environment("o", folderOps);
      process.send({ done: message.id });
      return;
    }
    if (message.report) {
      process.send({ done: message.id, report: env.report() });
      return;
    }
    try {
      const result = await env.step(message.step);
      process.send({ done: message.id, edits: result.edits, replay: result.replay, ...(process.env.ORACLE_TRACE ? { result } : {}) });
    } catch (error) {
      process.send({ done: message.id, error: String(error?.message ?? error) });
    }
  });
}

if (role === "other") await other();
else if (role === "local") process.once("message", async ({ script }) => process.send({ trace: await runScenario(script) }));
else if (process.argv[1] === fileURLToPath(import.meta.url)) await parent();
