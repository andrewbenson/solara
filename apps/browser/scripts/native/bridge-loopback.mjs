import { spawn, spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const binary = process.env.SOLARA_STORE_BIN;
if (!binary) throw new Error("bridge-loopback: set SOLARA_STORE_BIN to a built solara-store");
const withData = process.env.SOLARA_LOOPBACK_DATA === "1";

const dir = mkdtempSync(join(process.env.TMPDIR ?? tmpdir(), "solara-loopback-"));
const data = join(dir, "data");
let serve = null;
let generation = 0;

function start() {
  stop();
  generation++;
  const requests = join(dir, `requests-${generation}`);
  const responses = join(dir, `responses-${generation}`);
  spawnSync("mkfifo", [requests, responses]);
  const args = ["serve", "--launch", `loop${generation}`, ...(withData ? ["--data", data, "--now", String(Date.now())] : [])];
  const child = spawn("sh", ["-c", 'b="$1"; q="$2"; r="$3"; shift 3; exec "$b" "$@" < "$q" > "$r"', "sh", binary, requests, responses, ...args], { stdio: ["ignore", "ignore", "inherit"] });
  child.unref();
  serve = { child, writer: openSync(requests, "w"), reader: openSync(responses, "r"), pending: "" };
}

function stop() {
  if (!serve) return;
  try {
    closeSync(serve.writer);
    closeSync(serve.reader);
  } catch {}
  serve.child.kill();
  spawnSync("sh", ["-c", `while kill -0 ${serve.child.pid} 2>/dev/null; do sleep 0.01; done`], { timeout: 5000 });
  serve = null;
}

function ask(request) {
  if (!serve) start();
  writeSync(serve.writer, JSON.stringify({ ...request, now: Date.now() }) + "\n");
  const chunk = Buffer.alloc(1 << 16);
  while (!serve.pending.includes("\n")) {
    const read = readSync(serve.reader, chunk, 0, chunk.length, null);
    if (read === 0) throw new Error("bridge-loopback: solara-store serve exited");
    serve.pending += chunk.toString("utf8", 0, read);
  }
  const at = serve.pending.indexOf("\n");
  const line = serve.pending.slice(0, at);
  serve.pending = serve.pending.slice(at + 1);
  return line;
}

const { docs: shellDocs } = withData ? await import(new URL("../../src/test-native/shell.ts", import.meta.url).href) : { docs: null };
const docs = () => shellDocs;
const FILES = ["session.json", "downloads.json"];

function relaunch() {
  stop();
  const store = docs();
  if (store && !store.get("session.json")) rmSync(data, { recursive: true, force: true });
  mkdirSync(data, { recursive: true });
  for (const name of FILES) {
    const text = store?.get(name);
    if (text === undefined) rmSync(join(data, name), { force: true });
    else writeFileSync(join(data, name), text);
  }
  start();
}

function syncBack() {
  const store = docs();
  if (!store) return;
  for (const name of FILES) if (existsSync(join(data, name))) store.set(name, readFileSync(join(data, name), "utf8"));
}

process.on("exit", () => {
  stop();
  rmSync(dir, { recursive: true, force: true });
});

globalThis.acTestNativeModules = {
  ...(globalThis.acTestNativeModules ?? {}),
  SolaraStoreAdapter: {
    status: () => {
      if (withData) relaunch();
      return { active: true };
    },
    snapshot: () => ask({ op: "snapshot" }),
    dispatch: (commandJSON, sinceRev) => ask({ op: "dispatch", commands: JSON.parse(commandJSON), sinceRev }),
    catchUp: (sinceRev) => ask({ op: "catchUp", sinceRev }),
    flush: () => {
      if (!withData) return true;
      const flushed = JSON.parse(ask({ op: "flush" })).flushed;
      syncBack();
      return flushed;
    },
    addListener: () => ({ remove() {} }),
  },
};
