#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { evidenceFiles, findLeaks, phraseFor, readEvidenceFile, secretNeedles } from "./lib/pairing-scan.mjs";
import { identity } from "../../../scripts/lib/identity.mjs";
import { launch, reporter, screenLocked, sleep } from "../../../scripts/lib/instance.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log("usage: node pairing-e2e.mjs [<Debug .dev Solara.app>] [<work dir>] [--only=<case,...>] [--keep] [--require-all]\n\nTwo hidden instances share one scratch sync folder: onboarding's sync discovery and pairing, end to end. Runs on the Hill Studio with METRO_PORT set to your own Metro. A case whose probes the build lacks is skipped; --require-all fails the run on any skip, which sign-off and release use. The synthetic mailbox isolation cases run while locked without arming T; comparison cases need an unlocked screen. Snapshots prove responsiveness; this build has no sync-health snapshot field. A hidden instance can't authenticate the owner, so the cases that need a real Allow run up to it, check it is refused, and end in an owner check: listed at the end, never a skip or a failure. Mismatched codes, an expired request and a cancel that can't be recorded are covered by the native pairing unit tests, not here.");
  process.exit(0);
}
const positional = args.filter((a) => !a.startsWith("--"));
const APP = path.resolve(positional[0] ?? `${repo}/apps/browser/build-sync/Build/Products/Debug/${identity("FULL_PRODUCT_NAME")}`);
const WORK = path.resolve(positional[1] ?? `${process.env.TMPDIR ?? "/tmp"}/ac-pairing-e2e`);
const only = args.find((a) => a.startsWith("--only="))?.slice(7).split(",");
const keep = args.includes("--keep");
const requireAll = args.includes("--require-all");

fs.rmSync(WORK, { recursive: true, force: true });
fs.mkdirSync(WORK, { recursive: true });
const report = reporter(`${WORK}/pairing-e2e.log`, { name: "pairing e2e" });
const note = report.log;
const running = new Set();
const evidence = new Map();
let localNames;
let words;

function caseEvidence(name) {
  if (!evidence.has(name)) evidence.set(name, { folder: null, instances: new Set(), needles: [], keyFiles: new Map() });
  return evidence.get(name);
}

function macNames() {
  if (!localNames) {
    let name;
    try { name = execFileSync("/usr/sbin/scutil", ["--get", "ComputerName"], { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"] }).trim(); }
    catch { throw new Error("the local Mac name could not be read for privacy checks"); }
    assert.ok(name, "the local Mac name is available for privacy checks");
    localNames = secretNeedles("local Mac name", name);
  }
  return localNames;
}

function scanFiles(root, needles, keyFiles = new Map(), bounds) {
  const { files, skipped } = evidenceFiles(root, bounds);
  const leaks = [];
  for (const file of files) {
    const expected = keyFiles.get(path.resolve(root, file.relative));
    if (expected) assert.ok(file.bytes.equals(expected), "an expected root-key artifact changed");
    const applicable = expected ? needles.filter((n) => n.label !== "root key" || !n.bytes.equals(expected)) : needles;
    for (const label of findLeaks(file.bytes, applicable)) leaks.push(`${label}: ${path.relative(WORK, path.join(root, file.relative))}`);
  }
  if (leaks.length) throw new Error(`privacy leak\n${leaks.join("\n")}`);
  return { scanned: files.reduce((sum, file) => sum + file.bytes.length, 0), skipped };
}

const engineCaches = new Set(["Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "GraphiteDawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "component_crx_cache", "extensions_crx_cache"]);
const engineCache = (relative) => /^[^/]+\/[TJ]\/Chromium\//.test(relative) && engineCaches.has(path.basename(relative));
const mib = (bytes) => `${(bytes / 1048576).toFixed(1)} MiB`;

function privacy(name) {
  const state = caseEvidence(name);
  const needles = [...macNames(), ...state.needles];
  if (state.folder) scanFiles(state.folder, needles);
  for (const data of state.instances) {
    for (const log of ["app.out.log", "dev-console.log", "js-errors.log", "ui-gate-violation.log"]) {
      const file = path.join(data, log);
      if (!fs.existsSync(file)) continue;
      const info = fs.lstatSync(file);
      assert.ok(info.isFile() && !info.isSymbolicLink() && info.nlink === 1, "a diagnostic log must be a regular file");
      const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
      try {
        const opened = fs.fstatSync(fd);
        assert.ok(opened.isFile() && opened.nlink === 1 && opened.ino === info.ino && opened.dev === info.dev, "a diagnostic log changed while opening");
        assert.ok(opened.size <= 64 * 1024 * 1024, "diagnostic log byte bound exceeded");
        const leaks = findLeaks(readEvidenceFile(fd, opened.size), needles);
        if (leaks.length) throw new Error(`privacy leak\n${leaks.map((label) => `${label}: ${path.relative(WORK, file)}`).join("\n")}`);
      } finally { fs.closeSync(fd); }
    }
    const durable = path.join(data, "Application Support", "sync-pairing");
    if (fs.existsSync(durable)) scanFiles(durable, needles);
  }
}

function rememberRoot(name, data) {
  const doc = syncDocument(data);
  assert.match(doc.deviceId ?? "", /^[a-z2-7]{25}[aeimquy4]$/, "T has a canonical device ID");
  const keyFile = path.join(data, `sync-key-${doc.deviceId}`);
  const info = fs.lstatSync(keyFile);
  assert.ok(info.isFile() && !info.isSymbolicLink() && info.nlink === 1 && info.size === 32, "T has a regular 32-byte root key");
  const fd = fs.openSync(keyFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  let key;
  try {
    const opened = fs.fstatSync(fd);
    assert.ok(opened.isFile() && opened.nlink === 1 && opened.ino === info.ino && opened.dev === info.dev && opened.size === 32, "T's root key changed while opening");
    key = readEvidenceFile(fd, 32);
  } finally { fs.closeSync(fd); }
  assert.ok(key.length === 32, "T's root key has the expected size");
  if (!words) words = [...fs.readFileSync(path.join(repo, "packages/sync/ios/Core/Wordlist.swift"), "utf8").matchAll(/"([a-z]+)"/g)].map((m) => m[1]);
  const state = caseEvidence(name);
  state.keyFiles.set(keyFile, key);
  state.needles.push(...secretNeedles("root key", key), ...secretNeedles("phrase", phraseFor(key, words)));
  return { keyFile, key };
}

function syncDocument(data) {
  const file = path.join(data, "sync.json");
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
}

function chainTag() {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  const bytes = crypto.randomBytes(16);
  let bits = 0;
  let buffer = 0;
  let out = "";
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += alphabet[(buffer >> (bits - 5)) & 31];
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  return out + alphabet[(buffer << (5 - bits)) & 31];
}

function folderWith(name, chains) {
  const folder = path.join(WORK, name, "folder");
  caseEvidence(name).folder = folder;
  fs.mkdirSync(folder, { recursive: true });
  for (let i = 0; i < chains; i++) fs.mkdirSync(path.join(folder, chainTag()));
  return folder;
}

async function joiningMac(name, folder, env = {}) {
  const app = await launch(APP, {
    data: path.join(WORK, name, "J"),
    keepData: true,
    env: { SOLARA_ONBOARDING: "1", SOLARA_SYNC_DEFAULT_FOLDER: folder, ...env },
  });
  running.add(app);
  caseEvidence(name).instances.add(app.data);
  note(`${name} J: pid ${app.pid}, DevTools ${app.port}`);
  return app;
}

async function onboarding(app) {
  const read = (await app.snapshot()).onboarding ?? {};
  return { ...(read.state ?? {}), syncRoute: read.probeSyncRoute, candidates: read.probeSyncCandidates, code: read.probeSyncCode };
}

class Skip extends Error {}

async function needs(app, ...commands) {
  const { capabilities = [] } = await app.probe("probe.hello");
  const missing = commands.filter((c) => !capabilities.includes(c));
  if (missing.length) throw new Skip(`this build has no ${missing.join(", ")} probe`);
}

async function trustedMac(name, folder, env = {}, commands = ["pairing.trusted.arm", "pairing.trusted.select", "pairing.trusted.decide"]) {
  const app = await launch(APP, {
    data: path.join(WORK, name, "T"),
    onboarded: true,
    keepData: true,
    env: { SOLARA_SYNC_DEFAULT_FOLDER: folder, ...env },
  });
  running.add(app);
  caseEvidence(name).instances.add(app.data);
  note(`${name} T: pid ${app.pid}, DevTools ${app.port}`);
  await needs(app, "sync.enable", "pairing.trusted.state", "state.snapshot", ...commands);
  await until("T enables sync through its Settings bridge", (remaining) => app.probe("sync.enable", {}, { timeout: Math.min(60000, remaining) }), (s) => s.enabled === true);
  const chains = await until("T's chain in the folder", async () => fs.readdirSync(folder).filter((n) => /^[a-z2-7]{26}$/.test(n)), (c) => c.length === 1);
  const root = rememberRoot(name, app.data);
  return { app, cid: chains[0], ...root };
}

const trustedState = (app) => app.probe("pairing.trusted.state");

async function until(what, read, accept, ms = 60000) {
  assert.ok(ms > 0 && ms < 600000, "wait deadline must be under ten minutes");
  const end = Date.now() + ms;
  while (Date.now() < end) {
    for (const app of running) assert.ok(app.alive, `${what}: an instance exited`);
    let timer;
    const last = await Promise.race([
      Promise.resolve().then(() => read(end - Date.now())),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${what}: deadline`)), end - Date.now()); }),
    ]).finally(() => clearTimeout(timer));
    if (accept(last)) return last;
    await sleep(Math.min(250, Math.max(0, end - Date.now())));
  }
  throw new Error(`${what}: not reached within ${ms} ms`);
}

const route = (app, ...routes) => until(`J's route ${routes.join(" or ")}`, () => onboarding(app), (s) => routes.includes(s.syncRoute));
const phase = (app, ...phases) => until(`T's phase ${phases.join(" or ")}`, () => trustedState(app), (s) => phases.includes(s.phase));

class OwnerCheck extends Error {}

async function allowIsAnOwnerCheck(trusted, name, ownerSteps) {
  const refusal = await trusted.probe("pairing.trusted.decide", { decision: "allow" }).then(
    () => assert.fail("a hidden instance allowed the request"),
    (error) => error,
  );
  assert.equal(refusal.code, "unsupported", `Allow is refused, never prompted (${refusal.message})`);
  assert.equal((await trustedState(trusted)).phase, "comparing", "a refused Allow leaves T comparing");
  leftNoCompletion(name);
  throw new OwnerCheck(ownerSteps);
}

async function act(app, action, extra = {}) {
  const result = await app.probe("onboarding.sync", { action, ...extra });
  note(`J ${action} -> ${result.syncRoute}`);
  return result;
}

function onboardingDocument(name) {
  const file = path.join(WORK, name, "J", "onboarding.json");
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
}

async function syncOn(app) {
  return syncDocument(app.data);
}

function needsUnlockedScreen() {
  assert.equal(screenLocked(), false, "pairing refuses while the screen is locked (PairingServices' lock gate), so this case needs an unlocked screen");
}

async function pairToComparing(name, { jEnv = {}, tEnv = {} } = {}) {
  needsUnlockedScreen();
  const folder = folderWith(name, 0);
  const trusted = await trustedMac(name, folder, tEnv);
  const joining = await joiningMac(name, folder, jEnv);
  await needs(joining, "onboarding.sync");
  const found = await settledRoute(joining);
  assert.equal(found.syncRoute, "found", "J finds the trusted Mac's chain");
  assert.equal(found.candidates, 1);
  await act(joining, "pair");
  await route(joining, "joining.waiting");
  const armed = await trusted.app.probe("pairing.trusted.arm");
  if (armed.armed !== true) {
    const { phase, eligible, markerVerified } = await trustedState(trusted.app);
    assert.fail(`T arms one exchange (refusal ${armed.refusal}; phase ${phase}, eligible ${eligible}, markerVerified ${markerVerified})`);
  }
  await until("J's request on T", () => trustedState(trusted.app), (s) => s.requests === 1);
  await trusted.app.probe("pairing.trusted.select");
  const t = await phase(trusted.app, "comparing");
  assert.ok(typeof t.code === "string" && t.code.length > 0, "T exposes its comparison code");
  assert.ok(typeof t.claimedName === "string" && t.claimedName.length > 0, "T exposes its claimed name");
  caseEvidence(name).needles.push(...secretNeedles("SAS", t.code), ...secretNeedles("claimed name", t.claimedName));
  const j = await route(joining, "joining.comparing");
  assert.ok(typeof j.code === "string" && j.code.length > 0, "J exposes its comparison code");
  caseEvidence(name).needles.push(...secretNeedles("SAS", j.code));
  privacy(name);
  return { folder, trusted, joining, codesMatch: !!t.code && t.code === j.code, claimedName: t.claimedName };
}

const leftNoCompletion = (name) => {
  const doc = onboardingDocument(name);
  assert.equal(doc.joinedCompletionToken ?? null, null, "no joined completion is recorded");
  assert.notEqual(doc.joinedEnteredBrowser, true);
};

async function settledRoute(app, ms = 60000) {
  return until("J's discovery settles", () => onboarding(app), (s) => s.active && s.syncRoute && s.syncRoute !== "discovering", ms);
}

async function stop(app) {
  const write = process.stderr.write;
  let diagnostics = false;
  process.stderr.write = (chunk, encoding, callback) => {
    diagnostics = true;
    if (typeof encoding === "function") encoding();
    else if (typeof callback === "function") callback();
    return true;
  };
  try {
    await app.quit();
    running.delete(app);
  } finally {
    process.stderr.write = write;
    if (diagnostics) note(`teardown diagnostics retained under ${path.relative(WORK, app.data)}`);
  }
}

function tagBytes(tag) {
  assert.match(tag, /^[a-z2-7]{25}[aeimquy4]$/);
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  const bits = [...tag].map((character) => alphabet.indexOf(character).toString(2).padStart(5, "0")).join("");
  return Buffer.from(bits.slice(0, 128).match(/.{8}/g).map((part) => parseInt(part, 2)));
}

function integer(value, bytes) {
  const out = Buffer.alloc(bytes);
  if (bytes === 8) out.writeBigUInt64BE(BigInt(value));
  else out.writeUIntBE(value, 0, bytes);
  return out;
}

const wireString = (value) => Buffer.concat([integer(Buffer.byteLength(value), 2), Buffer.from(value)]);
const frame = (label, ...args) => Buffer.concat([wireString(`solara-pair/v2/${label}`), integer(args.length, 4), ...args.flatMap((arg) => [integer(arg.length, 4), arg])]);
const digest = (bytes) => crypto.createHash("sha256").update(bytes).digest();

function requestFixture(cid, now = Date.now()) {
  const { publicKey } = crypto.generateKeyPairSync("x25519");
  const rid = crypto.randomBytes(16);
  const nameCommitment = digest(frame("J name", wireString("Pairing E2E Synthetic Peer"), crypto.randomBytes(32)));
  const body = Buffer.concat([crypto.randomBytes(16), Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url"), wireString("New Mac"), integer(now, 8), integer(now + 300000, 8), nameCommitment]);
  const core = Buffer.concat([Buffer.from("SPJ2"), Buffer.from([2, 1, 0, 0]), integer(body.length, 4), tagBytes(cid), rid, Buffer.alloc(16), body]);
  const wire = Buffer.concat([core, digest(frame("J commitment", core, crypto.randomBytes(32)))]);
  wire.writeUInt32BE(wire.length - 60, 8);
  assert.equal(wire.length, 197, "the synthetic request matches PairingMailbox's fixed size");
  return { rid, wire };
}

function putRequest(state, fixture, wire = fixture.wire) {
  const directory = path.join(state.namespace, state.trusted.cid, fixture.rid.toString("hex"));
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, "request.spj");
  fs.writeFileSync(file, wire, { mode: 0o600 });
  return directory;
}

function chainFiles(state) {
  return new Map(evidenceFiles(path.join(state.folder, state.trusted.cid)).files.map((file) => [file.relative, digest(file.bytes)]));
}

function mailboxFiles(state) {
  return fs.existsSync(state.namespace) ? evidenceFiles(state.namespace) : { files: [], links: [] };
}

async function mailboxCase(name) {
  const folder = folderWith(name, 0);
  const trusted = await trustedMac(name, folder, {}, []);
  const joining = await joiningMac(name, folder);
  await needs(joining, "state.snapshot");
  const found = await settledRoute(joining);
  assert.equal(found.syncRoute, "found");
  assert.equal(found.candidates, 1);
  const state = { name, folder, trusted, joining, namespace: path.join(folder, "Solara Pairing v2"), injected: new Map() };
  state.baseline = await until("T publishes its initial chain", async () => chainFiles(state), (files) => files.size > 0);
  state.deviceId = syncDocument(trusted.app.data).deviceId;
  note(`${name}: unarmed isolation; snapshots check responsiveness, sync health is not exposed`);
  await mailboxUnchanged(state);
  return state;
}

async function mailboxUnchanged(state) {
  const { trusted, joining, name } = state;
  const t = await trustedState(trusted.app);
  assert.equal(t.armed, false, "T stays unarmed");
  assert.equal(t.phase, "idle", "T never enters a pairing exchange");
  const snapshot = await trusted.app.snapshot();
  assert.equal(snapshot.schema, 1, "T answers native snapshots");
  assert.equal(snapshot.consistent, true, "T answers a consistent native snapshot");
  const doc = syncDocument(trusted.app.data);
  assert.equal(doc.enabled, true, "T stays enabled on disk");
  assert.equal(doc.deviceId, state.deviceId, "T keeps its device identity");
  assert.notEqual(doc.joining, true, "T does not start a join");
  assert.ok(!doc.installation && !doc.joinTransaction, "T has no pairing installation");
  assert.ok(fs.readFileSync(trusted.keyFile).equals(trusted.key), "T keeps its root key");
  const current = chainFiles(state);
  for (const [file, hash] of state.baseline) assert.ok(current.get(file)?.equals(hash), `T's original chain bytes are unchanged: ${file}`);
  assert.deepEqual(fs.readdirSync(state.folder).filter((entry) => /^[a-z2-7]{26}$/.test(entry)), [trusted.cid], "no additional chain is created");
  const j = await onboarding(joining);
  assert.equal(j.syncRoute, "found", "J stays at anonymous discovery");
  assert.notEqual(syncDocument(joining.data).enabled, true, "J stays disabled");
  assert.ok(!syncDocument(joining.data).installation && !syncDocument(joining.data).joinTransaction, "J has no pairing installation");
  assert.ok(!fs.readdirSync(joining.data).some((entry) => entry.startsWith("sync-key-")), "J has no root key");
  for (const data of [trusted.app.data, joining.data]) {
    assert.ok(!fs.existsSync(path.join(data, "Application Support/sync-pairing/host-installation.json")), "neither Mac records a pairing installation");
    const file = path.join(data, "onboarding.json");
    const saved = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
    assert.ok(!saved.joinedCompletionToken && saved.joinedEnteredBrowser !== true, "neither Mac records a joined completion");
  }
  leftNoCompletion(name);
  for (const file of mailboxFiles(state).files) {
    if (!/(?:^|\/)[0-9a-f]{32}\.(?:offer|reveal|t-name|approval|t-terminal)\.spj$/.test(file.relative)) continue;
    assert.ok(state.injected.get(file.relative)?.equals(digest(file.bytes)), "unarmed T emits no pairing response");
  }
}

async function observeMailbox(state, ms = 11000) {
  const end = Date.now() + ms;
  await until("unarmed mailbox stays isolated", async () => {
    await mailboxUnchanged(state);
    return Date.now() >= end;
  }, Boolean, ms + 60000);
}

function putMailboxFile(state, file, wire) {
  fs.writeFileSync(file, wire, { mode: 0o600 });
  state.injected.set(path.relative(state.namespace, file), digest(wire));
}

function replayFiles(state, directory, fixture) {
  for (const [kind, size] of [["approval", 1160], ["confirm", 124]]) {
    const wire = Buffer.from(fixture[kind], "hex");
    assert.equal(wire.length, size, "the public P1 fixture matches main's wire size");
    const file = path.join(directory, `${wire.subarray(44, 60).toString("hex")}.${kind}.spj`);
    putMailboxFile(state, file, wire);
  }
}

const cases = {
  async syntheticRequestTamperStaysIsolated() {
    const state = await mailboxCase("tamper");
    const fixture = requestFixture(state.trusted.cid);
    putRequest(state, fixture);
    await observeMailbox(state);
    for (const offset of [76, 110, 133, 165]) {
      const changed = Buffer.from(fixture.wire);
      changed[offset] ^= 1;
      putRequest(state, fixture, changed);
      await observeMailbox(state);
    }
  },
  async partialRequestThenCompletedStaysIsolated() {
    const state = await mailboxCase("partial");
    const fixture = requestFixture(state.trusted.cid);
    putRequest(state, fixture, fixture.wire.subarray(0, 90));
    await observeMailbox(state);
    putRequest(state, fixture);
    await observeMailbox(state);
  },
  async foreignAndStaleReplayStaysIsolated() {
    const state = await mailboxCase("replay");
    const fixture = JSON.parse(fs.readFileSync(path.join(repo, "packages/sync/tests/fixtures/pairing-p1.json"), "utf8"));
    const stale = putRequest(state, requestFixture(state.trusted.cid, Date.now() - 600000));
    replayFiles(state, stale, fixture);
    replayFiles(state, putRequest(state, requestFixture(state.trusted.cid)), fixture);
    await observeMailbox(state);
    await stop(state.joining);
    await stop(state.trusted.app);
    state.joining = await joiningMac(state.name, state.folder);
    const found = await settledRoute(state.joining);
    assert.equal(found.syncRoute, "found");
    const app = await launch(APP, { data: state.trusted.app.data, keepData: true, env: { SOLARA_SYNC_DEFAULT_FOLDER: state.folder } });
    running.add(app);
    state.trusted.app = app;
    await needs(app, "state.snapshot", "pairing.trusted.state");
    await observeMailbox(state);
  },
  async mailboxFloodStaysIsolated() {
    const state = await mailboxCase("flood");
    const sentinel = path.join(state.folder, "outside-pairing.txt");
    const sentinelBytes = crypto.randomBytes(64);
    fs.writeFileSync(sentinel, sentinelBytes);
    for (let i = 0; i < 300; i++) putRequest(state, requestFixture(state.trusted.cid));
    const directory = putRequest(state, requestFixture(state.trusted.cid));
    putMailboxFile(state, path.join(directory, `${crypto.randomBytes(16).toString("hex")}.offer.spj`), Buffer.alloc(8193, 0x5a));
    putMailboxFile(state, path.join(directory, `${crypto.randomBytes(16).toString("hex")}.confirm.spj`), Buffer.from("SPJ2"));
    fs.symlinkSync(sentinel, path.join(directory, `${crypto.randomBytes(16).toString("hex")}.reveal.spj`));
    await observeMailbox(state);
    assert.ok(fs.lstatSync(sentinel).isFile() && fs.readFileSync(sentinel).equals(sentinelBytes), "the sentinel outside the pairing namespace survives unchanged");
  },
  async emptyFolderContinuesSetup() {
    const app = await joiningMac("empty", folderWith("empty", 0));
    const state = await settledRoute(app);
    assert.equal(state.active, true, "onboarding is on screen");
    assert.equal(state.syncRoute, "setup", "an empty folder continues fresh setup");
    assert.equal(state.step, "intro", "fresh setup starts at the intro card");
    await stop(app);
  },
  async missingFolderContinuesSetup() {
    const app = await joiningMac("missing", path.join(WORK, "missing", "nothing-here"));
    const state = await settledRoute(app);
    assert.equal(state.syncRoute, "setup", "a missing folder is empty, not an error");
    assert.ok(!fs.existsSync(path.join(WORK, "missing", "nothing-here")), "discovery never creates the folder");
    await stop(app);
  },
  async oneChainLeadsWithPairing() {
    const app = await joiningMac("one", folderWith("one", 1));
    const state = await settledRoute(app);
    assert.equal(state.syncRoute, "found", "a chain in the folder leads with pairing");
    assert.equal(state.candidates, 1);
    await stop(app);
  },
  async twoChainsNeedAChoice() {
    const app = await joiningMac("two", folderWith("two", 2));
    const state = await settledRoute(app);
    assert.equal(state.syncRoute, "found");
    assert.equal(state.candidates, 2, "both chains are offered, none is guessed");
    await stop(app);
  },
  async unreadableFolderIsPermissionDenied() {
    const folder = folderWith("denied", 1);
    fs.chmodSync(folder, 0o000);
    try {
      const app = await joiningMac("denied", folder);
      const state = await settledRoute(app);
      assert.equal(state.syncRoute, "discoveryIssue.permissionDenied");
      await stop(app);
    } finally {
      fs.chmodSync(folder, 0o755);
    }
  },
  async malformedEntriesAreNotChains() {
    const folder = folderWith("malformed", 0);
    fs.mkdirSync(path.join(folder, "Not A Chain"));
    fs.mkdirSync(path.join(folder, "a".repeat(25)));
    fs.writeFileSync(path.join(folder, chainTag()), "a file, not a directory");
    const app = await joiningMac("malformed", folder);
    const state = await settledRoute(app);
    assert.equal(state.syncRoute, "setup", "only real tag-shaped directories are chains");
    await stop(app);
  },
  async theJoiningProbeDrivesOnboarding() {
    const folder = folderWith("drive", 2);
    const joining = await joiningMac("drive", folder);
    await needs(joining, "onboarding.sync");
    assert.equal((await settledRoute(joining)).candidates, 2);
    const [first] = fs.readdirSync(folder).sort();
    assert.equal((await act(joining, "choose", { cid: first })).syncRoute, "found");
    await assert.rejects(joining.probe("onboarding.sync", { action: "choose", cid: "a".repeat(26) }), /notReady/, "an unknown chain can't be chosen");
    await assert.rejects(joining.probe("onboarding.sync", { action: "fly" }), /notReady/);
    await act(joining, "pair");
    const paired = await until("J leaves found", () => onboarding(joining), (s) => s.syncRoute?.startsWith("joining."));
    if (paired.syncRoute !== "joining.failed.invalidPeer") assert.equal((await act(joining, "cancel")).syncRoute, "found");
  },
  async pairingJoinsTheTrustedMacsSync() {
    const { trusted, joining, codesMatch } = await pairToComparing("pair");
    assert.ok(codesMatch, "both Macs show the same code");
    await allowIsAnOwnerCheck(trusted.app, "pair",
      "Allow on the trusted Mac with the owner's password or Touch ID: the joining Mac goes approved, downloading, then joined; it records its joined completion, skips import, has sync on with the trusted Mac's chain, and Continue enters the browser.");
  },
  async denyEndsTheJoin() {
    const { trusted, joining } = await pairToComparing("deny");
    assert.equal((await trusted.app.probe("pairing.trusted.decide", { decision: "deny" })).accepted, true);
    await route(joining, "joining.failed.denied", "joining.failed.expired");
    leftNoCompletion("deny");
    assert.notEqual((await syncOn(joining)).enabled, true, "sync stays off for J");
  },
  async notMeEndsTheExchange() {
    const { trusted, joining } = await pairToComparing("notme");
    assert.equal((await trusted.app.probe("pairing.trusted.decide", { decision: "notMe" })).accepted, true);
    await phase(trusted.app, "ended", "denied");
    assert.equal((await trusted.app.probe("pairing.trusted.decide", { decision: "allow" })).accepted, false, "a dismissed request can't be allowed after");
    leftNoCompletion("notme");
    await stop(joining);
  },
  async cancelWhileComparingReturnsToFound() {
    const { trusted, joining } = await pairToComparing("cancel");
    const cancelled = await act(joining, "cancel");
    assert.equal(cancelled.syncRoute, "found", "J returns to the found route");
    await phase(trusted.app, "ended", "denied", "expired");
    assert.equal((await trusted.app.probe("pairing.trusted.decide", { decision: "allow" })).accepted, false, "T can't allow a cancelled request");
    leftNoCompletion("cancel");
    assert.ok((await onboarding(joining)).code === undefined, "the code is gone after cancel");
  },
  async aCrashAfterCommitResumesAtLaunch() {
    const { trusted, joining, codesMatch } = await pairToComparing("crash");
    assert.ok(codesMatch);
    await allowIsAnOwnerCheck(trusted.app, "crash",
      "Allow on the trusted Mac with the owner's password or Touch ID, then force-quit the joining Mac once it shows approved or downloading: relaunched, it resumes the committed join, reaches joined, records its completion and syncs the trusted Mac's chain.");
  },
};

const ownerChecks = [];
try {
  for (const [name, run] of Object.entries(cases)) {
    if (only && !only.includes(name)) continue;
    const started = Date.now();
    const previous = new Set(evidence.keys());
    let failure;
    try { await run(); } catch (error) { failure = error; }
    for (const key of evidence.keys()) {
      if (previous.has(key)) continue;
      try { privacy(key); } catch (error) { failure = error; }
    }
    for (const app of [...running]) {
      try { await stop(app); } catch (error) { failure = error; }
    }
    for (const key of evidence.keys()) {
      if (previous.has(key)) continue;
      try { privacy(key); } catch (error) { failure = error; }
    }
    if (failure instanceof OwnerCheck) {
      report.record(name, { ms: Date.now() - started, evidence: "up to Allow" });
      ownerChecks.push({ name, steps: failure.message });
    } else if (failure instanceof Skip) report.record(name, { skip: failure.message });
    else report.record(name, { ms: Date.now() - started, error: failure });
  }
} finally {
  for (const app of [...running]) await stop(app).catch(() => {});
  try {
    const states = [...evidence.values()];
    const { scanned, skipped } = scanFiles(WORK, [...macNames(), ...states.flatMap((state) => state.needles)], new Map(states.flatMap((state) => [...state.keyFiles])), { entries: 262144, bytes: 1024 * 1024 * 1024, skipDirectory: engineCache });
    const skippedBytes = skipped.reduce((sum, entry) => sum + entry.bytes, 0);
    report.say(`finalPrivacyScan: scanned ${mib(scanned)}; skipped ${skipped.length} engine cache directories, ${mib(skippedBytes)}`);
    report.record("finalPrivacyScan");
  } catch (error) { report.record("finalPrivacyScan", { error }); }
}
if (ownerChecks.length) {
  report.say(`owner checks (${ownerChecks.length}): these passed up to Allow, which a hidden instance can't give; the owner runs the rest by hand`);
  for (const { name, steps } of ownerChecks) report.say(`  OWNER ${name}: ${steps}`);
}
const skips = report.results.filter((r) => r.skipped);
if (requireAll && skips.length) report.say(`--require-all: ${skips.length} skipped (${skips.map((r) => r.name).join(", ")})`);
const passed = report.summary() && !(requireAll && skips.length);
if (!keep && report.disposable) fs.rmSync(WORK, { recursive: true, force: true });
process.exit(passed ? 0 : 1);
