import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { appendFileSync, chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, request as httpRequest } from "node:http";
import { createServer as createNetServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { joinWouldExtend, parseFront, prune, readState, suppressedLog, waitingOthers } from "./ui-guard.mjs";

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const here = fileURLToPath(import.meta.url);

export const freePort = () => new Promise((resolve) => {
  const probe = createNetServer();
  probe.listen(0, "127.0.0.1", () => {
    const { port } = probe.address();
    probe.close(() => resolve(port));
  });
});
export function parsePort(value) {
  const n = Number(value);
  if (!/^\d+$/.test(String(value)) || n < 1 || n > 65535) throw new Error(`a port is an integer 1..65535, got ${value}`);
  return n;
}
const pidList = (text) => [...new Set(text.split(/\s+/).filter(Boolean).map(Number))].filter((n) => Number.isInteger(n) && n > 0);
const folded = (path) => path.normalize("NFC").toLowerCase();
export const commandIsBinary = (command, binary) => folded(command) === folded(binary) || folded(command).startsWith(`${folded(binary)} `);
export function listenerPids(port) {
  const r = spawnSync("lsof", ["-nP", "-t", `-iTCP:${port}`, "-sTCP:LISTEN"], { encoding: "utf8", timeout: 5000 });
  if (r.error || r.status > 1) throw new Error(`lsof failed for port ${port}: ${r.error ?? r.stderr}`);
  return pidList(r.stdout);
}
export function parseProcessLine(line) {
  const m = /^\s*(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.*\S)\s*$/.exec(line);
  return m ? { started: m[1], command: m[2] } : null;
}
export function processInfo(pid) {
  const r = spawnSync("ps", ["-ww", "-p", String(pid), "-o", "lstart=", "-o", "command="], { encoding: "utf8", timeout: 5000 });
  return r.status === 0 ? parseProcessLine(r.stdout) : null;
}
export function binaryPids(binary) {
  const r = spawnSync("ps", ["-ww", "-ax", "-o", "pid=", "-o", "command="], { encoding: "utf8", timeout: 5000, maxBuffer: 64 << 20 });
  if (r.status !== 0) throw new Error(`ps failed: ${r.stderr}`);
  return new Set(r.stdout.split("\n").map((l) => /^\s*(\d+)\s+(.*)$/.exec(l))
    .filter((m) => m && commandIsBinary(m[2], binary)).map((m) => Number(m[1])));
}
export function ownedCandidate(listeners, before, commandOf, binary) {
  if (!listeners.length) return null;
  if (listeners.length !== 1) throw new Error(`port has ${listeners.length} listeners: ${listeners.join(", ")}`);
  const [pid] = listeners;
  const command = commandOf(pid) ?? "";
  if (before.has(pid)) throw new Error(`port listener ${pid} predates the launch`);
  if (!commandIsBinary(command, binary)) throw new Error(`port listener ${pid} is not ${binary}: ${command}`);
  return pid;
}
export const realPath = (path) => { try { return realpathSync.native(path); } catch { return path; } };

export function temporaryData(data) {
  const root = tmpdir();
  const realRoot = realPath(root);
  if (!isAbsolute(root) || realRoot === "/") return null;
  const under = (base, path) => {
    const inside = relative(base, path);
    return !!inside && !inside.startsWith("..") && !isAbsolute(inside) && inside.split(sep)[0].startsWith("ac-");
  };
  const path = resolve(data);
  const real = realPath(path);
  return (under(root, path) || under(realRoot, path)) && under(realRoot, real) ? real : null;
}
export function removeTemporaryData(data) {
  const real = process.env.AC_KEEP_DATA === "1" || process.argv.includes("--keep-data") ? null : temporaryData(data);
  if (!real) return false;
  try {
    rmSync(real, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
    return true;
  } catch (e) {
    process.stderr.write(`warning: couldn't remove ${real}: ${e.message}\n`);
    return false;
  }
}
const crashReports = [["crashes", (name) => /^crash-\d+\.txt$/.test(basename(name))], ["Crashpad", (name) => name.endsWith(".dmp")]];
export function keepCrashReports(data, pid, root = tmpdir()) {
  const found = crashReports.filter(([folder, isReport]) => {
    try { return readdirSync(join(data, folder), { recursive: true }).map(String).some(isReport); } catch { return false; }
  });
  if (!found.length) return null;
  const kept = mkdtempSync(join(root, `solara-crash-${pid}-`));
  for (const [folder] of found) cpSync(join(data, folder), join(kept, folder), { recursive: true });
  for (const [folder] of found) for (const name of readdirSync(join(kept, folder), { recursive: true }).map(String))
    if (/^crash-\d+\.txt$/.test(basename(name))) process.stderr.write(`${readFileSync(join(kept, folder, name), "utf8")}\n`);
  process.stderr.write(`the app (pid ${pid}) left crash reports; kept them in ${kept}\n`);
  return kept;
}
export function wipeRefusal(data) {
  const real = realPath(resolve(data));
  const within = (base, path) => {
    const inside = relative(base, path);
    return inside === "" || (!inside.startsWith("..") && !isAbsolute(inside));
  };
  const home = realPath(homedir());
  if (within(real, home)) return "it is the home folder or holds it";
  if (within(realPath(join(home, "Library", "Application Support")), real)) return "it is inside ~/Library/Application Support";
  if (within(real, realPath(join(dirname(here), "..", "..")))) return "it is the repo or holds it";
  if (!existsSync(real) || temporaryData(data) || ["instance.json", "app.out.log"].some((f) => existsSync(join(real, f)))) return null;
  return "it isn't an instance data dir (no instance.json or app.out.log)";
}
export const quitEnded = ({ how }) => how === "quit" || how === "SIGTERM" || how === "SIGKILL";
const quitData = new Set();
const diedInstances = new Set();
const reportDirs = new Map();
const launched = new Map();
const uiGuardScript = join(dirname(here), "ui-guard.mjs");
const lockedTool = join(dirname(here), "..", "agent", "locked");
let uiGate = null;
let uiGateTaking = null;
const gated = new Set();
export function frontApp() {
  const asn = spawnSync("lsappinfo", ["front"], { encoding: "utf8", timeout: 3000 }).stdout?.trim();
  return asn ? parseFront(spawnSync("lsappinfo", ["info", asn], { encoding: "utf8", timeout: 3000 }).stdout ?? "") : null;
}
function failUiGate(found) {
  process.stderr.write(`\n!!! UI GATE: failing this run: test instance pid ${found.pid} ${found.what}; it was killed.\n\n`);
  for (const pid of new Set([...launched.keys(), ...gated])) if (pid !== found.pid) try { process.kill(pid, "SIGTERM"); } catch {}
  process.exit(1);
}
function failUiGateCapped(held) {
  process.stderr.write(`\n!!! UI GATE: failing this run: test instance pid ${held.pid} held the uitest lock for ${held.heldMinutes} min, ` +
    `past the ${held.maxHold} min backstop for a running test (launched by ${held.who}); it was quit.\n` +
    `!!! If this test really needs longer, set AC_UITEST_MAX_HOLD=<minutes> before it launches.\n\n`);
  for (const pid of new Set([...launched.keys(), ...gated])) if (pid !== held.pid) try { process.kill(pid, "SIGTERM"); } catch {}
  process.exit(1);
}
function gateNote(state, entry) { appendFileSync(state, `${JSON.stringify(entry)}\n`); }
const holdNote = (key) => ({ at: Date.now(), who: key ?? `pid ${process.pid}`, by: process.pid, ...(Number(process.env.AC_UITEST_MAX_HOLD) > 0 ? { maxHold: Number(process.env.AC_UITEST_MAX_HOLD) } : {}) });
export const uiGateKey = (path) => process.env.AC_LOCKED_AS || /\/build-([^/]+)\/Build\/Products\//.exec(path ?? "")?.[1] || null;
const uiGateCurrent = (key) => join(tmpdir(), `ac-uitest-${key.replace(/[^A-Za-z0-9_.-]/g, "_")}.current`);
function liveGate(state) {
  if (!state || !existsSync(state)) return false;
  const holder = readFileSync(state, "utf8").split("\n").map((l) => { try { return JSON.parse(l).lockHolder; } catch { return null; } }).find(Boolean);
  return !!holder && isAlive(holder) && /\/scripts\/agent\/locked uitest /.test(processInfo(holder)?.command ?? "");
}
const uiGateWaiters = join(tmpdir(), "ac-uitest-waiters");
const ownWaiter = join(uiGateWaiters, `${process.pid}.json`);
function readWaiters() {
  let names = [];
  try { names = readdirSync(uiGateWaiters).filter((n) => /^\d+\.json$/.test(n)); } catch {}
  const waiters = [];
  for (const name of names) {
    const file = join(uiGateWaiters, name);
    if (!isAlive(Number(name.slice(0, -5)))) { rmSync(file, { force: true }); continue; }
    try { waiters.push(JSON.parse(readFileSync(file, "utf8"))); } catch {}
  }
  return waiters;
}
function gateIdle(state) {
  try { return joinWouldExtend(prune(readState(readFileSync(state, "utf8"))), process.pid, isAlive); } catch { return false; }
}
const othersWaiting = (key) => waitingOthers(readWaiters(), key, process.pid, isAlive, (pid) => processInfo(pid)?.command.split(" ")[0] ?? "");
export async function holdUiGate(key = null) {
  if (uiGate) return uiGate;
  uiGateTaking ??= takeUiGate(key).finally(() => {
    uiGateTaking = null;
  });
  return uiGateTaking;
}
async function takeUiGate(key) {
  let current = null;
  try { current = key ? readFileSync(uiGateCurrent(key), "utf8").trim() : null; } catch {}
  if (current && current !== process.env.AC_UITEST_STATE && liveGate(current) && gateIdle(current)) {
    const others = othersWaiting(key);
    if (others.length) {
      process.stderr.write(`not joining ${key}'s uitest hold: ${others.map((w) => w.key ?? `pid ${w.pid}`).join(", ")} ` +
        `${others.length === 1 ? "is" : "are"} waiting for it; waiting in turn\n`);
      current = null;
    }
  }
  for (const joined of [process.env.AC_UITEST_STATE, current])
    if (liveGate(joined)) {
      gateNote(joined, { owner: process.pid });
      await sleep(1200);
      if (!liveGate(joined)) continue;
      process.env.AC_UITEST_STATE = joined;
      return (uiGate = { state: joined, key });
    }
  const state = join(tmpdir(), `ac-uitest-${process.pid}-${Date.now()}.state`);
  writeFileSync(state, `${JSON.stringify({ owner: process.pid })}\n`);
  try {
    mkdirSync(uiGateWaiters, { recursive: true });
    writeFileSync(ownWaiter, JSON.stringify({ pid: process.pid, key, since: Date.now() }));
  } catch {}
  const wait = Number(process.env.AC_UITEST_WAIT ?? 480);
  const child = spawn(lockedTool, ["uitest", "--wait", String(wait), "--", process.execPath, uiGuardScript, state],
    { detached: true, stdio: ["ignore", "pipe", "pipe"] });
  let errors = "";
  child.stderr.on("data", (d) => { errors += d; });
  const notice = setTimeout(() => process.stderr.write("waiting for the uitest lock: another UI test has instances running (one at a time across agents)\n"), 2000);
  try {
    await new Promise((res, rej) => {
      let out = "";
      const onData = (d) => {
        out += d;
        if (out.includes("held\n")) { child.stdout.off("data", onData); res(); }
      };
      child.stdout.on("data", onData);
      child.on("exit", (code) => rej(new Error(`couldn't take the uitest lock (exit ${code}): ${errors.trim() || "no reason given"}`)));
    });
  } catch (e) {
    rmSync(state, { force: true });
    throw e;
  } finally {
    clearTimeout(notice);
    rmSync(ownWaiter, { force: true });
  }
  child.removeAllListeners("exit");
  child.stderr.removeAllListeners("data");
  child.stderr.on("data", (d) => process.stderr.write(d));
  let lines = "";
  child.stdout.on("data", (d) => {
    lines += d;
    for (let i; (i = lines.indexOf("\n")) >= 0; lines = lines.slice(i + 1)) {
      const line = lines.slice(0, i);
      const m = /^violation (.*)$/.exec(line), capped = /^capped (.*)$/.exec(line);
      if (m) failUiGate(JSON.parse(m[1]));
      if (capped) failUiGateCapped(JSON.parse(capped[1]));
    }
  });
  child.unref();
  child.stdout.unref?.();
  child.stderr.unref?.();
  gateNote(state, { lockHolder: child.pid });
  process.env.AC_UITEST_STATE = state;
  if (key) writeFileSync(uiGateCurrent(key), state);
  return (uiGate = { state, key });
}
export async function uiGateLaunching(binary, { allowFront = false } = {}) {
  const gate = await holdUiGate(uiGateKey(binary));
  gateNote(gate.state, { binary: realPath(binary), frontBefore: frontApp(), ...(allowFront ? { allowFront } : {}) });
}
export function uiGateWatch(pid, data = null, { allowFront = false } = {}) {
  if (!uiGate) throw new Error("uiGateWatch before uiGateLaunching: take the uitest lock before launching the app");
  gated.add(pid);
  gateNote(uiGate.state, { watch: pid, data, ...holdNote(uiGate.key), ...(allowFront ? { allowFront } : {}) });
}
export function reportSuppressedSecureInput(data, when) {
  let text = "";
  try { text = readFileSync(suppressedLog(data), "utf8"); } catch {}
  if (!text.trim()) return false;
  process.stderr.write(`\nSECURE INPUT (prevented) ${when}: a password field took focus in the test instance at ${data}. In a\n` +
    `background instance Secure Event Input is suppressed, so the owner's keyboard was not blocked; outside one it would have been:\n${text}\n`);
  return true;
}
process.on("exit", (code) => {
  try { rmSync(ownWaiter, { force: true }); } catch {}
  for (const [pid, data] of launched) if (isAlive(pid)) reportSuppressedSecureInput(data, "as the test run exits");
  if (code !== 0) {
    for (const [pid, data] of launched) if (!isAlive(pid)) keepCrashReports(data, pid);
    for (const data of quitData) keepCrashReports(data, "quit");
    return;
  }
  for (const data of quitData) removeTemporaryData(data);
  for (const [dir, report] of reportDirs) if (report.disposable) removeTemporaryData(dir);
});
export function spawnedPids(binary, before, port, dataDirs) {
  const r = spawnSync("ps", ["-ww", "-ax", "-o", "pid=", "-o", "ppid=", "-o", "command="], { encoding: "utf8", timeout: 5000, maxBuffer: 64 << 20 });
  if (r.status !== 0) return [];
  const rows = r.stdout.split("\n").map((l) => /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(l)).filter(Boolean)
    .map((m) => ({ pid: Number(m[1]), ppid: Number(m[2]), command: m[3] }));
  let listening = [];
  try { listening = listenerPids(port); } catch {}
  return rows.filter((row) => commandIsBinary(row.command, binary) && !before.has(row.pid)).map((row) => row.pid)
    .filter((pid) => listening.includes(pid) ||
      rows.some((child) => child.ppid === pid && dataDirs.some((dir) => folded(child.command).includes(`--user-data-dir=${folded(dir)}`))));
}
async function killSpawned(pids) {
  for (const pid of pids) try { process.kill(pid, "SIGTERM"); } catch {}
  for (const end = Date.now() + 5000; pids.some(isAlive) && Date.now() < end; await sleep(100));
  for (const pid of pids.filter(isAlive)) try { process.kill(pid, "SIGKILL"); } catch {}
}
export const isAlive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
export const binaryOf = (app) => join(app, "Contents/MacOS",
  execFileSync("plutil", ["-extract", "CFBundleExecutable", "raw", join(app, "Contents/Info.plist")]).toString().trim());
export const onScreenWindows = (pid) => JSON.parse(execFileSync("osascript", ["-l", "JavaScript", "-e",
  `ObjC.import("CoreGraphics"); JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)))
     .filter((w) => w.kCGWindowOwnerPID === ${pid} && w.kCGWindowLayer <= 0 && w.kCGWindowLayer > -2000000).map((w) => w.kCGWindowNumber))`], { timeout: 20000 }).toString());

const profileColors = ["plum", "blue", "green", "orange", "red"];
export function session({ profiles = ["Personal"], windows = [{}], tabs = [], ...rest } = {}) {
  const ps = profiles.map((p, i) => {
    const o = typeof p === "string" ? { name: p } : p;
    return { id: o.id ?? (i ? o.name.toLowerCase() : "default"), name: o.name ?? o.id, color: o.color ?? profileColors[i % 5], icon: null, createdAt: i, ...o };
  });
  const ws = windows.map((w, i) => ({ id: w.id ?? `w${i + 1}`, profileId: ps[0].id, ...w }));
  const ts = tabs.map((t) => {
    const windowId = t.windowId ?? ws[0].id;
    return { windowId, profileId: ws.find((w) => w.id === windowId)?.profileId ?? ps[0].id, url: "", title: "", favicon: null,
      pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null,
      createdAt: 1, lastActiveAt: 1, ...t };
  });
  const fullWindows = ws.map((w, i) => {
    const tabIds = w.tabIds ?? ts.filter((t) => t.windowId === w.id).map((t) => t.id);
    const activeTabIds = w.activeTabIds ?? Object.fromEntries(ps.map((p) => [p.id, ts.find((t) => t.windowId === w.id && t.profileId === p.id)?.id])
      .filter(([, id]) => id));
    return { incognito: false, sidebarOpen: true, frame: [80, 80, 1280, 800], createdAt: i + 1, ...w, tabIds, activeTabIds };
  });
  return {
    version: 2,
    profiles: Object.fromEntries(ps.map((p) => [p.id, p])),
    profileOrder: ps.map((p) => p.id),
    windows: fullWindows, windowOrder: fullWindows.map((w) => w.id), focusedWindowId: fullWindows[0]?.id ?? null, tabs: ts,
    groups: [], splits: [], closedTabs: [], closedWindows: [], closedGroups: [], cleanedTabs: [],
    ...rest,
  };
}

async function metroProxyMain(data, metroPort) {
  const proxy = createServer((req, res) => {
    const up = httpRequest({ host: "127.0.0.1", port: metroPort, path: req.url, method: req.method, headers: req.headers }, (r) => {
      res.writeHead(r.statusCode ?? 502, r.headers);
      r.pipe(res);
    });
    up.on("error", () => res.destroy());
    req.pipe(up);
  });
  proxy.on("upgrade", (req, socket) => socket.destroy());
  await new Promise((r) => proxy.listen(0, "127.0.0.1", r));
  process.stdout.write(`${proxy.address().port}\n`);
  let seen = Date.now();
  setInterval(() => {
    let pid = null;
    try { pid = JSON.parse(readFileSync(join(data, "instance.json"), "utf8")).pid; } catch {}
    if (pid && isAlive(pid)) seen = Date.now();
    else if (Date.now() - seen > (pid ? 60_000 : 5 * 60_000)) process.exit(0);
  }, 2000);
}
async function startMetroProxy(data, metroPort) {
  const child = spawn(process.execPath, [here, "--metro-proxy", data, String(metroPort)], { detached: true, stdio: ["ignore", "pipe", "ignore"] });
  const port = await new Promise((r, j) => {
    let out = "";
    child.stdout.on("data", (d) => { out += d; if (out.includes("\n")) r(Number(out.trim())); });
    child.on("exit", (code) => j(new Error(`the Metro proxy exited (${code})`)));
    setTimeout(() => j(new Error("the Metro proxy didn't start")), 5000);
  });
  child.stdout.destroy();
  child.unref();
  return { pid: child.pid, port, metroPort };
}

export async function devtools(target, { name = target.url } = {}) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error(`DevTools connection to ${name} failed`)))));
  let seq = 0, closed = false;
  const pending = new Map(), listeners = new Map();
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method) for (const fn of listeners.get(msg.method) ?? []) fn(msg.params);
  };
  ws.onclose = () => {
    closed = true;
    for (const [, r] of pending) r({ error: "the target closed before replying" });
    pending.clear();
  };
  const send = async (method, params = {}, { timeout = 10000 } = {}) => {
    if (closed) throw new Error(`DevTools: ${name} closed (${method})`);
    const id = ++seq;
    const reply = new Promise((r) => pending.set(id, r));
    ws.send(JSON.stringify({ id, method, params }));
    const msg = await Promise.race([reply, sleep(timeout).then(() => ({ error: "cdp timeout" }))]);
    pending.delete(id);
    if (msg.error) throw new Error(`${method}: ${JSON.stringify(msg.error)}`);
    return msg.result;
  };
  return {
    target,
    send,
    async eval(expression, { userGesture = false, awaitPromise = true, timeout } = {}) {
      const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise, userGesture }, { timeout });
      if (r.exceptionDetails) throw new Error(`page: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result?.value;
    },
    on(event, fn) {
      listeners.set(event, [...(listeners.get(event) ?? []), fn]);
      return () => listeners.set(event, (listeners.get(event) ?? []).filter((f) => f !== fn));
    },
    get closed() { return closed; },
    close() { try { ws.close(); } catch {} },
  };
}

class Instance {
  constructor(record) {
    Object.assign(this, record);
    this.evalQueue = Promise.resolve();
    this.evalSeq = 0;
  }
  get alive() { return isAlive(this.pid) && this.stillOwned(); }
  stillOwned() {
    const info = processInfo(this.pid);
    return !!info && info.started === this.started && commandIsBinary(info.command, this.binary);
  }
  get exited() { return !isAlive(this.pid); }
  save(meta) {
    if (meta) this.meta = { ...this.meta, ...meta };
    const { evalQueue, evalSeq, ...record } = this;
    writeFileSync(join(this.data, "instance.json"), JSON.stringify(record, null, 2));
    return this;
  }

  async probe(command, args = {}, { timeout = 20000, id = randomUUID(), expiresAtMs = Date.now() + Math.min(timeout, 60000) } = {}) {
    if (!this.stillOwned()) throw new Error(`the app (pid ${this.pid}) exited`);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error("probe id must be a UUID");
    if (typeof command !== "string" || !command || typeof args !== "object" || args === null || Array.isArray(args))
      throw new Error("probe needs a command and object args");
    const request = JSON.stringify({ protocol: 1, id, command, args, expiresAtMs });
    if (Buffer.byteLength(request) > 65536) throw new Error("probe request exceeds 64 KiB");
    const root = this.probeData ?? this.data;
    const inbox = join(root, "probes", "inbox");
    const outbox = join(root, "probes", "outbox", `${id}.json`);
    const temp = join(inbox, `${id}.json.tmp`);
    const file = join(inbox, `${id}.json`);
    const deadline = Date.now() + timeout;
    while (!existsSync(inbox) && Date.now() < deadline) {
      if (!this.stillOwned()) throw new Error(`the app (pid ${this.pid}) exited`);
      await sleep(25);
    }
    if (!existsSync(inbox)) throw new Error("native probes unavailable");
    writeFileSync(temp, request, { flag: "wx", mode: 0o600 });
    renameSync(temp, file);
    try {
      while (Date.now() < deadline) {
        if (!this.stillOwned()) throw new Error(`the app (pid ${this.pid}) exited`);
        if (existsSync(outbox)) {
          const reply = JSON.parse(readFileSync(outbox, "utf8"));
          rmSync(outbox, { force: true });
          if (reply.id !== id || reply.protocol !== 1) throw new Error("mismatched native probe reply");
          if (reply.error) throw Object.assign(new Error(reply.error.code), { code: reply.error.code });
          return reply.result;
        }
        await sleep(25);
      }
      throw new Error(`native probe timed out after ${timeout} ms (${command})`);
    } finally {
      rmSync(temp, { force: true });
      rmSync(file, { force: true });
    }
  }
  snapshot(args = {}, options = {}) { return this.probe("state.snapshot", args, options); }

  eval(body, { timeout = 20000 } = {}) {
    const run = this.evalQueue.then(() => this.#eval(body, timeout));
    this.evalQueue = run.catch(() => {});
    return run;
  }
  async #eval(body, timeout) {
    const id = `e${Date.now()}-${process.pid}-${++this.evalSeq}`;
    const result = join(this.data, "dev-eval-result.json");
    writeFileSync(join(this.data, "dev-eval.js"), `// ${id}\n${body}`);
    const deadline = Date.now() + timeout;
    for (let polls = 0; Date.now() < deadline; polls++) {
      if (polls % 4 === 0 && !isAlive(this.pid)) throw Object.assign(new Error(`the app (pid ${this.pid}) exited`), { appDied: true });
      try {
        const out = JSON.parse(readFileSync(result, "utf8"));
        if (out.id === id) {
          if (out.error) throw Object.assign(new Error(out.error), { fromApp: true });
          return out.result;
        }
      } catch (e) {
        if (e.fromApp) throw e;
        if (!(e instanceof SyntaxError) && e.code !== "ENOENT") throw e;
      }
      await sleep(25);
    }
    throw new Error(`eval timed out after ${timeout} ms: ${body.slice(0, 80)}`);
  }
  async ready({ timeout = 90000, test = "return true" } = {}) {
    const deadline = Date.now() + timeout;
    let last;
    while (Date.now() < deadline) {
      try {
        if ((last = await this.eval(test, { timeout: 3000 }))) return last;
      } catch (e) {
        if (e.appDied) throw e;
        last = e.message;
      }
      await sleep(100);
    }
    throw new Error(`the app's dev harness never answered (is Metro running on :${this.js?.metroPort ?? 8081}?); last: ${last}`);
  }

  async targets() { return (await fetch(`http://127.0.0.1:${this.port}/json/list`)).json(); }
  async pageTarget(urlPart) {
    const test = typeof urlPart === "function" ? urlPart : (t) => t.url.includes(urlPart);
    return (await this.targets()).find((t) => t.type === "page" && test(t)) ?? null;
  }
  async page(urlPart, { timeout = 10000 } = {}) {
    const deadline = Date.now() + timeout;
    for (;;) {
      const t = await this.pageTarget(urlPart);
      if (t) return devtools(t);
      if (Date.now() > deadline) throw new Error(`no page for ${urlPart}`);
      if (!isAlive(this.pid)) throw new Error(`the app (pid ${this.pid}) exited`);
      await sleep(100);
    }
  }
  async browser() {
    const version = await (await fetch(`http://127.0.0.1:${this.port}/json/version`)).json();
    return devtools({ url: "browser", webSocketDebuggerUrl: version.webSocketDebuggerUrl });
  }
  windows() { return onScreenWindows(this.pid); }

  async quit(opts = {}) {
    reportSuppressedSecureInput(this.data, "at quit");
    const key = uiGateKey(this.binary);
    let state = process.env.AC_UITEST_STATE;
    try { state ||= key ? readFileSync(uiGateCurrent(key), "utf8").trim() : null; } catch {}
    const gateLog = join(this.data, "ui-gate-violation.log");
    if (existsSync(gateLog)) process.stderr.write(readFileSync(gateLog, "utf8"));
    const how = await this.#quit(opts);
    if (how.how === "gone") {
      diedInstances.add(this.pid);
      keepCrashReports(this.data, this.pid);
    }
    if (!isAlive(this.pid) && state && existsSync(state)) gateNote(state, { unwatch: this.pid });
    launched.delete(this.pid);
    if (this.exited && quitEnded(how) && !this.keepData) quitData.add(this.data);
    const errors = this.jsErrors();
    if (errors) process.stderr.write(`JS errors the app caught and survived (${join(this.data, "js-errors.log")}):\n${errors}`);
    if (this.js?.mode === "pinned" && (processInfo(this.js.pid)?.command ?? "").includes(`--metro-proxy ${this.data} `))
      try { process.kill(this.js.pid); } catch {}
    return how;
  }
  async #quit({ timeout = 15000, graceful = true }) {
    const gone = async (ms) => {
      for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (!isAlive(this.pid)) return true;
      return !isAlive(this.pid);
    };
    if (!this.stillOwned()) return { how: "gone" };
    if (graceful) {
      spawnSync("osascript", ["-l", "JavaScript", "-e",
        `ObjC.import("AppKit"); const a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${this.pid}); a.isNil() ? "none" : a.terminate`], { timeout: 10000 });
      if (await gone(timeout)) return { how: "quit" };
    }
    if (!this.stillOwned()) return { how: "gone" };
    process.kill(this.pid, "SIGTERM");
    if (await gone(3000)) return { how: "SIGTERM" };
    if (this.stillOwned()) process.kill(this.pid, "SIGKILL");
    await gone(2000);
    return { how: "SIGKILL" };
  }
  kill(signal = "SIGKILL") { if (this.stillOwned()) process.kill(this.pid, signal); }
  output() { return existsSync(this.log) ? readFileSync(this.log, "utf8") : ""; }
  jsErrors() {
    const file = join(this.data, "js-errors.log");
    return existsSync(file) ? readFileSync(file, "utf8") : "";
  }
}

export async function launch(app, opts = {}) {
  app = resolve(app);
  const installed = (path) => /^\/Applications\/[^/]+\.app(\/|$)/.test(path);
  if (installed(app) || (opts.runsFrom && installed(resolve(opts.runsFrom))))
    throw new Error("never an installed app: pass a build (apps/browser/build-*)");
  if (opts.urls?.length && (opts.env?.SOLARA_ACCEPT_EXTERNAL_URLS ?? "1") !== "1")
    throw new Error("refusing to hand URLs to a hidden instance without SOLARA_ACCEPT_EXTERNAL_URLS=1: it would forward them to the owner's running app");
  app = realPath(app);
  const gate = await holdUiGate(uiGateKey(app));
  const data = resolve(opts.data ?? join(process.env.TMPDIR ?? "/tmp", `ac-instance-${process.pid}-${Date.now()}`));
  quitData.delete(data);
  if (opts.fresh) {
    const refusal = wipeRefusal(data);
    if (refusal) throw new Error(`refusing to wipe ${data}: ${refusal}`);
    rmSync(data, { recursive: true, force: true });
  }
  const created = !existsSync(data);
  mkdirSync(data, { recursive: true, mode: 0o700 });
  if (created) {
    chmodSync(data, 0o700);
    if (opts.scratchMarker !== false) writeFileSync(join(data, ".solara-probe-scratch"), "", { flag: "wx", mode: 0o600 });
  }
  const canonicalData = realpathSync.native(data);
  let previous = null;
  try { previous = JSON.parse(readFileSync(join(data, "instance.json"), "utf8")); } catch {}
  for (const f of ["dev-eval.js", "dev-eval-result.json", "instance.json", "ui-gate-violation.log", "secure-input-suppressed.log"]) rmSync(join(data, f), { force: true });
  if (opts.session) writeFileSync(join(data, "session.json"), JSON.stringify(opts.session));
  if (opts.onboarded) writeFileSync(join(data, "onboarding.json"), JSON.stringify({ version: 1, completedAt: 1 }));
  if (opts.probe || process.env.AC_PROBE === "1") writeFileSync(join(data, "perf-probe"), "");
  for (const [name, text] of Object.entries(opts.files ?? {})) writeFileSync(join(data, name), typeof text === "string" ? text : JSON.stringify(text));
  const runsFrom = opts.runsFrom ? realPath(resolve(opts.runsFrom)) : app;
  const binary = join(runsFrom, "Contents/MacOS", basename(binaryOf(app)));
  const port = opts.port ? parsePort(opts.port) : await freePort();
  const busy = listenerPids(port);
  if (busy.length) throw new Error(`DevTools port ${port} is already in use by pid ${busy.join(", ")}`);
  const metroPort = Number(opts.metroPort ?? process.env.METRO_PORT ?? 8081);
  const jsMode = opts.js ?? "pinned";
  let js = { mode: jsMode, metroPort };
  if (jsMode === "pinned") {
    const kept = previous?.js;
    js = kept?.mode === "pinned" && kept.metroPort === metroPort && isAlive(kept.pid) && listenerPids(kept.port).includes(kept.pid)
      ? kept : { mode: "pinned", ...(await startMetroProxy(data, metroPort)) };
  }
  const location = jsMode === "pinned" ? `localhost:${js.port}` : jsMode === "live" ? `localhost:${metroPort}` : jsMode === "none" ? null : jsMode;
  const switches = [opts.switches].flat().filter(Boolean).join(" ");
  const env = {
    SOLARA_BACKGROUND: "1", SOLARA_DATA_DIR: canonicalData, SOLARA_REMOTE_DEBUGGING_PORT: String(port),
    ...(location ? { SOLARA_JS_LOCATION: location } : {}),
    ...(switches ? { SOLARA_CHROMIUM_SWITCHES: switches } : {}),
    ...(process.env.SOLARA_NATIVE_SIDEBAR ? { SOLARA_NATIVE_SIDEBAR: process.env.SOLARA_NATIVE_SIDEBAR } : {}),
    ...Object.fromEntries(Object.entries(process.env).filter(([k]) => k.startsWith("SOLARA_NATIVE_") || k.startsWith("SOLARA_SHELL_") || k.startsWith("SOLARA_SYNC_"))),
    ...(opts.urls?.length ? { SOLARA_ACCEPT_EXTERNAL_URLS: "1" } : {}),
    ...opts.env,
  };
  const log = resolve(opts.log ?? join(data, "app.out.log"));
  gateNote(gate.state, { binary: realPath(binary), frontBefore: frontApp() });
  const before = binaryPids(binary);
  const launchedAt = Date.now();
  execFileSync("open", ["-g", "-n", ...Object.entries(env).filter(([, v]) => v !== null && v !== undefined).flatMap(([k, v]) => ["--env", `${k}=${v}`]),
    "--stdout", log, "--stderr", log, ...(opts.urls?.length ? ["-a", app, ...opts.urls] : [app]), ...(opts.args?.length ? ["--args", ...opts.args] : [])]);
  let owned = null;
  try {
    for (const end = Date.now() + (opts.startTimeout ?? 60000); !owned && Date.now() < end; await sleep(100)) {
      let info;
      const pid = ownedCandidate(listenerPids(port), before, (p) => (info = processInfo(p))?.command, binary);
      if (pid && info) owned = { pid, started: info.started };
    }
    if (!owned) throw new Error(`the app didn't listen on DevTools port ${port} within ${(opts.startTimeout ?? 60000) / 1000} s (log: ${log})`);
  } catch (e) {
    const dirs = [...new Set([data, realPath(data)])];
    let spawned = [];
    for (const end = Date.now() + 10000; !spawned.length && Date.now() < end; await sleep(250)) spawned = spawnedPids(binary, before, port, dirs);
    await killSpawned(spawned);
    throw e;
  }
  const instance = new Instance({ app: runsFrom, binary, data, probeData: canonicalData, port, log, launchedAt, js, keepData: opts.keepData === true, ...owned, meta: opts.meta ?? {} });
  try {
    gateNote(gate.state, { watch: owned.pid, data, ...holdNote(gate.key) });
    instance.save();
    launched.set(instance.pid, data);
    if (opts.ready !== false)
      await instance.ready(typeof opts.ready === "string" ? { test: opts.ready } : typeof opts.ready === "object" ? opts.ready : {});
    return instance;
  } catch (error) {
    await instance.quit({ graceful: false });
    throw error;
  }
}

export function attach(dir) {
  dir = resolve(dir);
  const file = [join(dir, "instance.json"), join(dir, "data", "instance.json")].find(existsSync);
  if (!file) throw new Error(`no instance recorded in ${dir}`);
  const instance = new Instance(JSON.parse(readFileSync(file, "utf8")));
  if (!instance.stillOwned()) throw Object.assign(new Error(`the instance in ${dirname(file)} (pid ${instance.pid}) has gone`), { gone: true, instance });
  return instance;
}

export function reporter(logFile, { name = "run" } = {}) {
  mkdirSync(dirname(resolve(logFile)), { recursive: true });
  writeFileSync(logFile, `# ${name} ${new Date().toISOString()}\n`);
  const results = [];
  const started = Date.now();
  let section = [];
  const write = (line) => {
    appendFileSync(logFile, `${line}\n`);
    section.push(line);
    if (process.env.VERBOSE) console.log(line);
  };
  const text = (a) => (typeof a === "string" ? a : a instanceof Error ? (a.stack ?? a.message) : JSON.stringify(a));
  const r = {
    results,
    logFile,
    log: (...a) => write(a.map(text).join(" ")),
    say: (...a) => {
      const line = a.map(text).join(" ");
      appendFileSync(logFile, `${line}\n`);
      console.log(line);
    },
    record(checkName, { ms, error = null, evidence, skip } = {}) {
      const status = skip ? "SKIP" : error ? "FAIL" : "PASS";
      const time = skip ? ` (${skip})` : ms !== undefined ? ` ${ms}ms` : "";
      const logged = section;
      section = [];
      results.push({ name: checkName, ok: !error, skipped: !!skip, ms, error: error ? String(error.message ?? error) : undefined, evidence });
      appendFileSync(logFile, `${status} ${checkName}${time}${evidence !== undefined ? ` ${text(evidence)}` : ""}${error ? `: ${text(error)}` : ""}\n`);
      if (!error) {
        console.log(`${status} ${checkName}${time}`);
        return;
      }
      const message = String(error.message ?? error).split("\n");
      const detail = [...message.slice(1), ...logged].filter((l) => l.trim()).slice(0, 19);
      console.log(`FAIL ${checkName}${time}: ${message[0].slice(0, 400)}`);
      for (const l of detail) console.log(`  ${l.slice(0, 300)}`);
      console.log(`  (log: ${logFile})`);
    },
    async check(checkName, fn, { onFail } = {}) {
      section = [];
      appendFileSync(logFile, `\n## ${checkName}\n`);
      const t0 = Date.now();
      try {
        const evidence = await fn();
        r.record(checkName, { ms: Date.now() - t0, evidence });
        return true;
      } catch (error) {
        if (onFail) try { await onFail(error); } catch {}
        r.record(checkName, { ms: Date.now() - t0, error });
        return false;
      }
    },
    get failed() { return results.filter((x) => !x.ok); },
    get disposable() { return results.length > 0 && results.every((x) => x.ok) && !diedInstances.size; },
    summary() {
      const ran = results.filter((x) => !x.skipped);
      const failed = ran.filter((x) => !x.ok);
      const line = `${ran.length - failed.length}/${ran.length} passed in ${((Date.now() - started) / 1000).toFixed(1)} s` +
        `${failed.length ? `; failed: ${failed.map((x) => x.name).join(", ")}` : ""}. Log: ${logFile}`;
      appendFileSync(logFile, `\n${line}\n`);
      console.log(line);
      return !failed.length;
    },
  };
  if (temporaryData(dirname(resolve(logFile)))) reportDirs.set(dirname(resolve(logFile)), r);
  return r;
}

if (process.argv[1] === here) {
  const args = process.argv.slice(2);
  if (args[0] === "--metro-proxy") await metroProxyMain(args[1], Number(args[2]));
  else if (args[0] === "--self-test") {
    const bin = "/tmp/Solara.app/Contents/MacOS/Solara";
    const cmd = (map) => (pid) => map[pid];
    assert.equal(parsePort("9474"), 9474);
    const made = mkdtempSync(join(tmpdir(), "ac-self-test-"));
    const link = join(tmpdir(), `ac-self-test-link-${process.pid}`);
    try {
      mkdirSync(join(made, "data"));
      assert.equal(temporaryData(join(made, "data")), realPath(join(made, "data")));
      assert.equal(temporaryData(made), realPath(made));
      symlinkSync(dirname(here), link);
      assert.equal(temporaryData(link), null);
      assert.equal(temporaryData(join(link, "..", basename(made))), realPath(made));
      assert.equal(wipeRefusal(join(made, "data")), null);
      assert.match(wipeRefusal(link), /isn't an instance data dir/);
      for (const denied of [homedir(), "/", join(homedir(), "Library", "Application Support", "com.hill.solara"), join(dirname(here), "..", "..")])
        assert.ok(wipeRefusal(denied), denied);
    } finally {
      rmSync(made, { recursive: true, force: true });
      rmSync(link, { force: true });
    }
    assert.ok(quitEnded({ how: "SIGKILL" }) && !quitEnded({ how: "gone" }));
    for (const kept of [tmpdir(), join(tmpdir(), "other", "ac-x"), join(tmpdir(), "ac-x", "..", "y"), "/private/tmp/claude-501/scratch/data", "/"])
      assert.ok(!temporaryData(kept), kept);
    for (const bad of ["0", "65536", "94.5", "-1", "", "9474x", "1e3"]) assert.throws(() => parsePort(bad), /1\.\.65535/, bad);
    assert.deepEqual(pidList("12\n34\n12\n"), [12, 34]);
    assert.deepEqual(pidList(""), []);
    assert.ok(commandIsBinary(bin, bin));
    assert.ok(commandIsBinary(`${bin} --flag`, bin));
    assert.ok(!commandIsBinary(`${bin}2`, bin));
    assert.ok(!commandIsBinary(`/tmp/Solara.app/Contents/Frameworks/Solara Helper.app/Contents/MacOS/Solara Helper`, bin));
    const solara = "/tmp/Solara.app/Contents/MacOS/Solara";
    assert.ok(commandIsBinary(`${solara} --flag`, solara));
    assert.ok(!commandIsBinary(`/tmp/Solara.app/Contents/Frameworks/Chromium Framework.framework/Helpers/Solara Helper (Renderer).app/Contents/MacOS/Solara Helper (Renderer) --type=renderer`, solara));
    assert.deepEqual(parseProcessLine(`Wed Sep 30 18:44:18 2026     ${bin} --x\n`), { started: "Wed Sep 30 18:44:18 2026", command: `${bin} --x` });
    assert.equal(parseProcessLine(""), null);
    assert.equal(ownedCandidate([], new Set(), cmd({}), bin), null);
    assert.equal(ownedCandidate([7], new Set([5]), cmd({ 7: bin }), bin), 7);
    assert.throws(() => ownedCandidate([5], new Set([5]), cmd({ 5: bin }), bin), /predates/);
    assert.throws(() => ownedCandidate([7], new Set(), cmd({ 7: "/usr/bin/python3 -m http.server" }), bin), /is not/);
    assert.throws(() => ownedCandidate([7], new Set(), cmd({}), bin), /is not/);
    assert.throws(() => ownedCandidate([7, 8], new Set(), cmd({ 7: bin, 8: bin }), bin), /2 listeners/);
    assert.ok(isAlive(process.pid));
    const s = session({ profiles: ["Personal", "Work"], tabs: [{ id: "t1" }, { id: "t2", profileId: "work" }] });
    assert.deepEqual(s.windows[0].tabIds, ["t1", "t2"]);
    assert.deepEqual(s.windows[0].activeTabIds, { default: "t1", work: "t2" });
    assert.deepEqual(s.profileOrder, ["default", "work"]);
    console.log("PASS self-test");
  }
}
