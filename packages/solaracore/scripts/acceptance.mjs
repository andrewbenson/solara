#!/usr/bin/env node
// Stage 1 acceptance for the app on SolaraCore (docs/solaracore-parity.md): boots the SolaraCore build of the app hidden
// (SOLARA_BACKGROUND=1, its own data dir and DevTools port; scripts/lib/instance.mjs), serves fixture pages, and
// drives the real app through its dev harness (lib/devHarness.ts) and Chrome's DevTools protocol.
//
//   node packages/solaracore/scripts/acceptance.mjs <Solara.app> <scratch dir> [--keep] [check…]
//   node packages/solaracore/scripts/acceptance.mjs --attach <scratch dir> [check…]
//   node packages/solaracore/scripts/acceptance.mjs --list
//
//   [check…]   only these, plus the checks they depend on (`--list` shows them; a kept instance already has most)
//   --keep     leave the instance running at the end (and reuse the one this scratch dir already keeps)
//   --attach   run against the instance a --keep run left in <scratch dir>: no boot, seconds per check
//   SKIP=a,b   leave checks out; VERBOSE=1 prints the log as it goes; METRO_PORT (default 8081)
//
// Output: one line per check (PASS/FAIL, ms); a failure adds its first lines; the rest (evidence, state at a failure,
// diagnostics) goes to <scratch dir>/data/acceptance.log, results to <scratch dir>/results.json. It never takes focus
// and never touches a real profile: the data dir is <scratch dir>/data, wiped first (not when attaching).
// Its instance keeps Chrome's audio (SOLARA_ALLOW_AUDIO=1) so Chrome reports audible tabs, and sends it to a fake output
// (--disable-audio-output): nothing reaches the speakers. The fixtures play at -60 dBFS (Chrome's audible threshold is
// -72); the automatic Picture in Picture checks need ffmpeg for their clip (made once into <scratch dir>/media).
//
// Sections (// MARK:): Fixtures (the HTTP/HTTPS fixture server, extensions, a CRX) · The app (launch, evalApp, cdp)
// · Helpers · Checks (in run order: windows and tabs, pages, choosers and Cast, capture, restore, extensions, content
// blocker, crashes, downloads, autofill, settings) · Media, Picture in Picture, page focus · Page full screen · moving
// tabs, startup · quitting and relaunching · Camera and microphone (a copy without device entitlements) · crash-guard.
//
// Helpers (top level; `first` is page A's tab from open-url, `mainWindow` the run's window from boot):
//   evalApp(body, ms)              the app's JS (dev harness): `return …`; throws at once if the app exited
//   until(what, fn, ms)            polls fn until truthy (200 ms), else throws with the last value
//   state()                        the main window: { windowId, profileId, tabs: [{ id, url, title, loading, … }], active }
//   targets() · pageTarget(urlPart) · pageFor(tabId, urlPart) · cdp(target, method, params) · closeFromPage(target)
//   cef(call) · exts(call)         SolaraCEF / SolaraExtensions module calls
//   browserOf(tabId) · eventsOf(tabId) · lastEvent(tabId, name, test) · live(tabId) · pipWindows()
//   openTab(url, title, background) · closeTab(id) · shownAndMounted(id) · freshTab(url) · backToA() · startVideo(tabId, audio)
//   pipByHand(tabId)               Site Controls › Picture in Picture, clicked as the user does (manual PiP needs the click)
//   launch(log, env, args, opts) · appUp(log)   (re)start the app on the run's data dir; `exited` is set once it's gone
//   onScreenWindows() · firstPixel(png) · writePopupExtension(opts) · fixtureCrx()
import { acceptancePage as page, acceptancePathPage, adFirstPage, capturerPage, frameHostResponse, solidPage } from "./fixture-pages.mjs";
import { execFile, execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import { assertNotificationAuthorizationLog } from "./notification-authorization-log.mjs";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { networkInterfaces, tmpdir } from "node:os";
import { createServer as createHttpsServer } from "node:https";
import { basename, join, resolve } from "node:path";
import { X509Certificate, createHash, createSign, generateKeyPairSync } from "node:crypto";
import { crc32, deflateSync, inflateSync } from "node:zlib";
import { attach as attachInstance, launch as launchInstance, onScreenWindows as windowsOf, reporter, screenLocked, sleep, temporaryData } from "../../../scripts/lib/instance.mjs";

// MARK: What each check needs

const usesPageA = [
  "visibility", "occlusion", "favicon", "navigate-back-forward-reload", "target-blank", "window-open",
  "cmd-click", "evaluate", "tab-strips", "tab-switch", "status-text", "load-error", "chrome-strings",
  "tab-memory", "tab-cpu", "context-menu-search", "duplicate-and-reopen", "device-chooser", "bluetooth-chooser",
  "bluetooth-settings", "cast-dialog", "cast-routes", "theme-commit", "theme-modern-colors", "user-selection",
  "password-prompt", "screen-share-picker", "tab-capture", "share-instead-two-captures", "share-bar-layout",
  "restore-after-close", "discard-outcomes", "sleep-eligibility", "keep-awake-sites", "sleep-pinned-capture", "native-tab-sleep", "capture-picture", "unresponsive", "permission-dismissed", "permission-status-detached",
  "save-page", "activate-request", "extension-popup-and-panel", "extension-popup-window", "extension-popup-native-frame", "extension-popup-rail-field", "print-preview",
  "extension-prompts", "extension-prompt-closed", "extension-sheet-native", "traffic-lights-after-profile-switch", "extension-configure",
  "private-windows-create", "extension-installed-bubble", "popup-window", "popup-window-permission", "popup-origin-strip", "autofill-save-prompts",
  "settings-services", "download-navigation", "page-events", "page-background", "appearance-reaches-pages", "external-app-answer",
  "notifications", "now-playing", "media-state", "auto-picture-in-picture", "pip-window", "page-focus", "page-press-split",
  "fullscreen-tab-switch", "fullscreen-native", "escape-in-window-fullscreen", "fullscreen-transition-picture", "fullscreen-hidden-page", "fullscreen-split-sibling",
  "fullscreen-pip", "pip-fullscreen-space", "pip-keep-on-top-reopen", "webkit-picture-in-picture", "pip-document-back-to-tab", "autofill-suggestions", "images", "extension-surfaces", "frozen", "discard",
  "permission-prompt", "popup-blocked", "move-tab-slow-mount", "move-last-tab-slow-mount",
  "move-tab-closed-while-parked", "move-tab-to-window", "title-bar-close", "last-used-profile",
];
const needs = {
  ...Object.fromEntries([...usesPageA, "task-manager", "internal-pages-not-history", "second-profile"].map((name) => [name, ["open-url"]])),
  "tab-switch": ["open-url", "target-blank"],
  "tab-keys-from-page": ["open-url", "target-blank"],
  "window-close": ["window-open"],
  "no-hidden-window-after-stay": ["chrome-windows-remove", "stay-restores-window"],
  "stay-restores-window": ["open-url"],
  "site-data-clear": ["open-url"],
  "frozen": ["open-url", "cmd-click"],
  "discard": ["open-url", "cmd-click"],
  "duplicate-and-reopen": ["open-url", "navigate-back-forward-reload"],
  "context-menu-activation-log": ["context-menu-search"],
  "title-bar-close": ["open-url", "move-tab-to-window"],
  "context-menu-incognito": ["context-menu-log"],
  "context-menu-split": ["context-menu-log"],
  "relaunch-profile": ["last-used-profile", "quit"],
};
function checkIndex() {
  let section = "Checks";
  const index = [];
  for (const line of readFileSync(new URL(import.meta.url), "utf8").split("\n")) {
    const mark = /^\s*\/\/ MARK: (.*)$/.exec(line)?.[1];
    if (mark) section = mark.replace(/ \(.*$/, "");
    const name = /^\s*await (?:check|mediaCheck)\("([a-z0-9-]+)"/.exec(line)?.[1];
    if (name) index.push({ name, section });
  }
  return index;
}
function listChecks() {
  const index = checkIndex();
  const width = Math.max(...index.map((c) => c.name.length));
  for (const { name, section } of index) console.log(`${name.padEnd(width)}  ${section.padEnd(28)}  ${(needs[name] ?? []).join(", ")}`);
  console.log(`${index.length} checks (name, section, needs). Every run starts with boot.`);
  process.exit(0);
}
function selection(asked) {
  const index = checkIndex().map((c) => c.name);
  const unknown = asked.filter((n) => !index.includes(n));
  if (unknown.length) {
    console.error(`no such check: ${unknown.join(", ")} (--list shows them)`);
    process.exit(64);
  }
  if (!asked.length) return { run: new Set(index.filter((name) => name !== "notifications-one-requester")), deps: new Map() };
  const run = new Set(["boot", ...asked]);
  const deps = new Map();
  const add = (name, by) => {
    for (const dep of needs[name] ?? []) {
      if (!asked.includes(dep)) deps.set(dep, [...(deps.get(dep) ?? []), by]);
      if (!run.has(dep)) {
        run.add(dep);
        add(dep, by);
      }
    }
  };
  for (const name of asked) add(name, name);
  return { run, deps };
}

const argv = process.argv.slice(2);
const flag = (name) => (argv.includes(name) ? (argv.splice(argv.indexOf(name), 1), true) : false);
if (flag("--help") || flag("-h")) {
  const lines = readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1);
  console.log(lines.slice(0, lines.findIndex((l) => !l.startsWith("//"))).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
  process.exit(0);
}
if (flag("--list")) listChecks();
const attaching = argv[0] === "--attach";
if (attaching) argv.shift();
const keep = flag("--keep") || attaching;
if (argv.includes("notifications-one-requester") && (attaching || keep))
  throw new Error("notifications-one-requester requires a fresh owned instance without --attach or --keep");
const audioOutputOf = (browserPid) => {
  const utilities = execFileSync("ps", ["-A", "-ww", "-o", "ppid=,command="], { encoding: "utf8", maxBuffer: 64 << 20 }).split("\n")
    .filter((line) => line.trim().split(/\s+/)[0] === String(browserPid) && line.includes("--type=utility"));
  if (!utilities.length) return null;
  return utilities.some((line) => line.includes(" --disable-audio-output")) ? "fake" : "speakers";
};
const settledAudioOutput = async (browserPid) => {
  for (const deadline = Date.now() + 15000; Date.now() < deadline; await sleep(200)) {
    const output = audioOutputOf(browserPid);
    if (output) return output;
  }
  return null;
};
const unproven = (output) => (output === "speakers" ? "plays sound through this Mac's speakers (started without --disable-audio-output)"
  : "showed no Chrome helper within 15 s, so its audio output is unknown");
let kept = null;
if (attaching || keep) {
  try {
    kept = attachInstance(join(resolve(argv[attaching ? 0 : 1] ?? "."), "data"));
  } catch (e) {
    if (attaching) {
      console.error(`--attach: ${e.message}`);
      process.exit(66);
    }
  }
  const keptOutput = kept && (attaching || kept.app === resolve(argv[0])) ? await settledAudioOutput(kept.pid) : null;
  if (kept && attaching && keptOutput !== "fake") {
    console.error(`--attach: pid ${kept.pid} ${unproven(keptOutput)}; quit it (scripts/agent/ac quit ${join(resolve(argv[0]), "data")}) and start a new run`);
    process.exit(65);
  }
  if (kept && !attaching && (kept.app !== resolve(argv[0]) || keptOutput !== "fake")) {
    await kept.quit();
    kept = null;
  }
}
const [appArg, scratchArg, ...only] = attaching ? [kept.app, ...argv] : argv;
const { run: selected, deps } = selection(only);
if (!appArg || !scratchArg) {
  console.error("usage: acceptance.mjs <Solara.app> <scratch dir> [--keep] [check…] | --attach <scratch dir> [check…] | --list | --help");
  process.exit(64);
}
const app = resolve(appArg);
const scratch = resolve(scratchArg);
const notificationOnly = selected.has("notifications-one-requester");
if (notificationOnly) {
  assert.deepEqual(only, ["notifications-one-requester"], "run notifications-one-requester alone");
  assert.equal(process.env.SKIP ?? "", "", "the notification check cannot skip prerequisites");
  assert.equal(Number(process.env.SOLARA_NOTIFICATION_DISPOSABLE_UID), process.getuid(), "attest the disposable GUI user's UID");
  assert.equal(statSync("/dev/console").uid, process.getuid(), "the disposable GUI session must own the console");
  assert.equal(existsSync(scratch), false, "use a new nonexistent notification scratch directory");
}
let notificationRun = null;
const notificationDiagnostics = [];
let notificationRetired = null;
const notificationEvidence = notificationOnly ? mkdtempSync(join(tmpdir(), "notif-r3-evidence-")) : null;
if (notificationOnly) {
  assert.equal(temporaryData(notificationEvidence), null, "notification evidence must be outside reporter auto-cleanup");
  console.log(`retained notification evidence: ${notificationEvidence}`);
}
const data = join(scratch, "data");
let port;
const downloadsDir = join(scratch, "downloads");
const lightsLog = join(scratch, "traffic-lights.log");
if (!kept) {
  rmSync(lightsLog, { force: true });
  rmSync(data, { recursive: true, force: true });
}
rmSync(downloadsDir, { recursive: true, force: true });
mkdirSync(downloadsDir, { recursive: true });
mkdirSync(data, { recursive: true, mode: 0o700 });
if (!kept) writeFileSync(join(data, ".solara-probe-scratch"), "", { mode: 0o600 });

const results = [];
const report = reporter(notificationOnly ? join(notificationEvidence, "notification-acceptance.log") : join(data, "acceptance.log"), { name: `acceptance ${kept ? `attached to pid ${kept.pid}` : app}` });
const log = (...a) => report.log(...a);
const stamp = () => new Date().toISOString().slice(11, 23);

// MARK: Fixtures

const adServed = [];
const served = new Map();
const referers = new Map();
const notificationWorkerEvents = [];
const siteDataDomain = "solara-sitedata.com";
const siteDataSecureHosts = [`s.${siteDataDomain}`, "embed.solara-thirdparty.com", "top.solara-elsewhere.com"];
let clipBytes = null;
const fixtureClip = () => {
  const path = join(scratch, "media", "clip.webm");
  if (!existsSync(path)) {
    mkdirSync(join(scratch, "media"), { recursive: true });
    execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30",
      "-f", "lavfi", "-i", "aevalsrc=0.001*sin(2*PI*440*t):s=48000", "-t", "30", "-c:v", "libvpx", "-b:v", "200k", "-c:a", "libopus",
      "-shortest", path], { stdio: "ignore" });
  }
  return (clipBytes ??= readFileSync(path));
};
const server = createServer((req, res) => {
  if (!req.headers.host?.startsWith("127.0.0.1")) adServed.push(`${req.headers.host}${req.url}`);
  served.set(req.url, (served.get(req.url) ?? 0) + 1);
  referers.set(req.url, req.headers.referer ?? "");
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/notification-fixture/event") {
    notificationWorkerEvents.push(Object.fromEntries(url.searchParams));
    res.writeHead(204);
    return res.end();
  }
  if (url.pathname === "/notification-fixture/" || url.pathname === "/notification-fixture/worker.js") {
    const worker = url.pathname.endsWith("worker.js");
    res.writeHead(200, { "content-type": worker ? "text/javascript" : "text/html", "cache-control": "no-store" });
    return res.end(readFileSync(new URL(`./fixtures/notifications/${worker ? "worker.js" : "index.html"}`, import.meta.url)));
  }
  if (url.pathname === "/icon.png") {
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==", "base64");
    res.writeHead(200, { "content-type": "image/png" });
    return res.end(png);
  }
  if (url.pathname === "/site-data") {
    const set = url.searchParams.has("set");
    res.writeHead(200, { "content-type": "text/html", ...(set ? { "set-cookie": ["host_only=1; Path=/", `domain_wide=1; Path=/; Domain=${siteDataDomain}`] } : {}) });
    return res.end(page("Site data", set ? `<script>localStorage.setItem("kept", "yes")</script>` : ""));
  }
  if (url.pathname === "/frame-host") {
    const response = frameHostResponse(url, siteDataSecureHosts.map((host) => `https://${host}`));
    res.writeHead(response.status, { "content-type": "text/html" });
    return res.end(response.html);
  }
  if (url.pathname === "/frame-probe") {
    const set = url.searchParams.has("set");
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(page("Frame probe", `<script>${set ? `document.cookie = "chips=1; Secure; SameSite=None; Partitioned; Path=/"; localStorage.setItem("kept", "yes");` : ""}
      parent.postMessage({ cookie: document.cookie, ls: localStorage.getItem("kept") }, "*");</script>`));
  }
  if (url.pathname === "/file.bin") {
    res.writeHead(200, { "content-type": "application/octet-stream", "content-disposition": 'attachment; filename="solaracore-test.bin"' });
    return res.end(Buffer.alloc(64 * 1024, 7));
  }
  if (url.pathname === "/slow.bin") {
    res.writeHead(200, { "content-type": "application/octet-stream", "content-length": String(40 * 50 * 1024), "content-disposition": 'attachment; filename="solaracore-slow.bin"' });
    let sent = 0;
    const timer = setInterval(() => {
      if (res.destroyed || sent >= 40) {
        clearInterval(timer);
        if (!res.destroyed) res.end();
        return;
      }
      sent++;
      res.write(Buffer.alloc(50 * 1024, 3));
    }, 200);
    req.on("close", () => clearInterval(timer));
    return;
  }
  if (url.pathname === "/webstore/crx") {
    res.writeHead(200, { "content-type": "application/x-chrome-extension" });
    return res.end(fixtureCrx());
  }
  if (url.pathname === "/clip.webm") {
    const clip = fixtureClip();
    res.writeHead(200, { "content-type": "video/webm", "content-length": String(clip.length) });
    return res.end(clip);
  }
  if (url.pathname === "/tone.wav") {
    const rate = 8000, n = rate;
    const wav = Buffer.alloc(44 + n * 2);
    wav.write("RIFF", 0); wav.writeUInt32LE(36 + n * 2, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
    wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(rate, 24); wav.writeUInt32LE(rate * 2, 28);
    wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(n * 2, 40);
    for (let i = 0; i < n; i++) wav.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 33), 44 + i * 2);
    res.writeHead(200, { "content-type": "audio/wav", "content-length": String(wav.length) });
    return res.end(wav);
  }
  res.writeHead(200, { "content-type": "text/html" });
  if (url.pathname === "/cam")
    return res.end(page("Cam", "cam", `<script>
      window.__asks = []; window.__streams = [];
      window.ask = (c) => {
        const entry = { state: "pending" }; window.__asks.push(entry);
        navigator.mediaDevices.getUserMedia(c).then((s) => { window.__streams.push(s); Object.assign(entry, { state: "ok", audio: s.getAudioTracks().map((t) => t.readyState), video: s.getVideoTracks().map((t) => t.readyState) }); },
          (e) => Object.assign(entry, { state: "err", error: e.name }));
        return window.__asks.length - 1;
      };
      window.stopAll = () => { for (const s of window.__streams) s.getTracks().forEach((t) => t.stop()); return true; };
    </script>`));
  if (url.pathname === "/element")
    return res.end(page("Element", `<usermedia id="um" style="display:block;font-size:20px;margin:40px"></usermedia>`, `<script>
      window.__ev = [];
      addEventListener("DOMContentLoaded", () => {
        const um = document.getElementById("um");
        um.addEventListener("stream", () => __ev.push({ audio: um.stream?.getAudioTracks().map((t) => t.readyState), video: um.stream?.getVideoTracks().map((t) => t.readyState) }));
        um.addEventListener("cancel", () => __ev.push("cancel"));
        window.box = () => { const r = um.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; };
        window.stopAll = () => { um.stream?.getTracks().forEach((t) => t.stop()); return true; };
      });
    </script>`));
  if (url.pathname === "/blocking") return res.end(page("Blocking", `<img src="/nnblock-1.png"><img src="/nnblock-2.png"><img src="/icon.png">`));
  if (url.pathname === "/adfirst") {
    return res.end(adFirstPage(url));
  }
  if (url.pathname === "/login") return res.end(page("Login", `<form action="/b" method="get"><input name="u" id="u" autocomplete="username"><input type="password" name="p" id="p" autocomplete="current-password"><button id="go">Sign in</button></form>`));
  if (url.pathname === "/text") return res.end(page("Text", `<p id="t" style="font: 20px sans-serif; margin: 40px">Hello selection world, select me please</p>`));
  if (url.pathname === "/drag")
    return res.end(page("Drag", `<div id="card" draggable="true" style="position: absolute; left: 40px; top: 40px; width: 180px; height: 60px; background: #ccd">card</div>
      <div id="clicker" style="position: absolute; left: 300px; top: 40px; width: 120px; height: 60px; background: #dcc">click</div>
      <script>window.__events = []; for (const t of ["mousedown", "click", "dragstart", "dragend"]) addEventListener(t, (e) => __events.push([t, e.target.id || "", e.clientX, e.clientY]), true);
      card.addEventListener("dragstart", (e) => e.dataTransfer.setData("text/plain", "card"));</script>`));
  if (url.pathname === "/capture-target") return res.end(page("Capture Target", "the tab that tab capture picks"));
  if (url.pathname === "/solid")
    return res.end(solidPage(url));
  if (url.pathname === "/capturer")
    return res.end(capturerPage(url));
  if (url.pathname === "/media") return res.end(page("Media", `<audio id="tone" src="/tone.wav" loop></audio>`));
  if (url.pathname === "/form")
    return res.end(page("Form", `<form action="/form" method="get" autocomplete="on"><input id="c" name="city" autocomplete="on" style="font-size: 20px; margin: 80px; width: 300px"><button id="b">go</button></form>`));
  if (url.pathname === "/video")
    return res.end(page("Video", `<video id="v" playsinline style="width: 320px; height: 180px"></video><script>
      const c = document.createElement("canvas"); c.width = 320; c.height = 180;
      const g = c.getContext("2d"); let n = 0;
      setInterval(() => { g.fillStyle = "hsl(" + ((n++ * 7) % 360) + ", 70%, 50%)"; g.fillRect(0, 0, 320, 180); }, 33);
      window.start = (audio) => {
        if (location.search.includes("file")) {
          const clip = document.getElementById("v");
          clip.src = "/clip.webm";
          clip.loop = true;
          return clip.play().then(() => "ok", (e) => e.name);
        }
        const stream = c.captureStream(30);
        if (audio) {
          const ac = new AudioContext(), osc = ac.createOscillator(), quiet = new GainNode(ac, { gain: 0.001 }), out = ac.createMediaStreamDestination();
          osc.connect(quiet).connect(out); osc.start(); stream.addTrack(out.stream.getAudioTracks()[0]);
        }
        const v = document.getElementById("v"); v.srcObject = stream;
        return v.play().then(() => "ok", (e) => e.name);
      };
      if (location.search.includes("docpip"))
        navigator.mediaSession.setActionHandler("enterpictureinpicture", async () => {
          const w = await documentPictureInPicture.requestWindow({ width: 320, height: 180 });
          w.document.body.append(document.getElementById("v"));
        });
      // ?fkey: "f" toggles the player's full screen, as on YouTube; ?handlers: Media Session handlers, as YouTube's.
      if (location.search.includes("fkey"))
        document.addEventListener("keydown", (e) => {
          if (e.key === "f") document.fullscreenElement ? document.exitFullscreen() : document.body.requestFullscreen();
        });
      if (location.search.includes("handlers")) {
        navigator.mediaSession.metadata = new MediaMetadata({ title: "Fixture video", artist: "Solara" });
        for (const action of ["play", "pause", "seekbackward", "seekforward", "previoustrack", "nexttrack", "seekto"])
          navigator.mediaSession.setActionHandler(action, () => {});
      }
    </script>`));
  if (url.pathname === "/ac-ads") return res.end(page("Ads", `<img src="/nnblock-ad.png"><script src="/nnredirect-ad.js"></script>`));
  if (url.pathname === "/a") return res.end(page("Page A", `<a id="next" href="/b">to B</a> <a id="blank" target="_blank" href="/c">blank</a> <a id="cmd" href="/d">cmd</a>`));
  if (url.pathname === "/mixed-header")
    return res.end(page("Mixed header", `<nav style="position: relative; height: 60px; background: color-mix(in srgb, #f6f6f7 94%, #000)"></nav><p>mixed</p>`, "<style>html, body { margin: 0; background: #f6f6f7 }</style>"));
  if (url.pathname === "/clear-mixed-header")
    return res.end(page("Clear mixed header", `<nav style="position: relative; height: 60px; background: color-mix(in srgb, transparent 100%, #000)"></nav><p>clear</p>`, `<meta name="theme-color" content="#123456"><style>html, body { margin: 0 }</style>`));
  if (url.pathname === "/alpha-header")
    return res.end(page("Alpha header", `<nav style="position: relative; height: 60px; background: color(srgb 1 0 0 / 0.6)"></nav><p>alpha</p>`, "<style>html, body { margin: 0 }</style>"));
  if (url.pathname === "/oklch-painted") return res.end(page("Oklch painted", "oklch", "<style>html, body { background: oklch(0.3 0 0) }</style>"));
  if (url.pathname === "/perm-inner") return res.end(page("Perm inner", "inner"));
  if (url.pathname === "/perm-detach")
    return res.end(page("Perm detach", `<iframe id="f" src="/perm-inner"></iframe><script>
      window.__r = "idle";
      window.run = async (mode) => {
        const f = document.getElementById("f");
        const status = await f.contentWindow.navigator.permissions.query({ name: "geolocation" });
        const onChange = () => {};
        status.addEventListener("change", onChange);
        if (mode === "navigate") {
          await new Promise((done) => { f.onload = done; f.src = "about:blank"; });
        } else f.remove();
        status.removeEventListener("change", onChange);
        window.__r = "survived " + mode;
        return window.__r;
      };
    </script>`));
  if (url.pathname === "/red-header")
    return res.end(page("Red header", `<div style="position: fixed; top: 0; left: 0; right: 0; height: 60px; background: rgb(200, 0, 0)"></div><p style="margin-top: 80px">red</p>`));
  if (url.pathname === "/painted") return res.end(page("Painted", "painted", "<style>html, body { background: rgb(60, 60, 60) }</style>"));
  if (url.pathname === "/scheme-dark") return res.end(page("Dark scheme", "dark scheme", `<meta name="color-scheme" content="dark">`));
  if (url.pathname === "/fs-layout")
    return res.end(page("FS layout", `<div id="mast"></div><div id="player"></div><div id="title"></div><script>
      document.addEventListener("keydown", (e) => {
        if (e.key === "f") document.fullscreenElement ? document.exitFullscreen() : document.getElementById("player").requestFullscreen();
      });
    </script>`, `<style>html, body { margin: 0; background: rgb(15, 15, 15) } #mast { height: 56px; background: rgb(30, 60, 200) }
      #player { margin: 24px; width: 640px; height: 360px; background: rgb(220, 30, 30) }
      #title { margin: 0 24px; width: 640px; height: 60px; background: rgb(240, 160, 0) }
      #player:fullscreen { margin: 0; width: 100vw; height: 100vh }</style>`));
  if (url.pathname === "/b") return res.end(page("Page B", "B"));
  if (url.pathname === "/c") return res.end(page("Page C", "C"));
  if (url.pathname === "/d") return res.end(page("Page D", "D"));
  if (url.pathname === "/e") return res.end(page("Page E", "E"));
  if (url.pathname === "/cookie") return res.end(page("Cookie", `<script>document.cookie="who=" + location.search.slice(1) + "; path=/"</script>`));
  const field = (id, autocomplete, label) => `<label>${label} <input id="${id}" name="${id}" autocomplete="${autocomplete}"></label><br>`;
  if (url.pathname === "/address")
    return res.end(page("Address", `<form action="/saved" method="post">${field("name", "name", "Name")}${url.searchParams.has("email") ? field("email", "email", "Email") : ""}${field("street", "street-address", "Street")}${field("city", "address-level2", "City")}${field("state", "address-level1", "State")}${field("zip", "postal-code", "ZIP")}${field("country", "country-name", "Country")}<button id="go">Save</button></form>`));
  if (url.pathname === "/card")
    return res.end(page("Card", `<form action="/saved" method="post">${field("ccname", "cc-name", "Name on card")}${field("ccnumber", "cc-number", "Number")}${field("ccmonth", "cc-exp-month", "Month")}${field("ccyear", "cc-exp-year", "Year")}<button id="go">Pay</button></form>`));
  if (url.pathname === "/saved") {
    req.resume();
    return res.end(page("Saved", "saved"));
  }
  return res.end(acceptancePathPage(url.pathname));
});
const listen = (srv, at) => new Promise((r, j) => {
  srv.once("error", (e) => j(new Error(`fixture port ${at}: ${e.message} (the kept instance needs it back; quit it and run without --attach)`)));
  srv.listen(at, "127.0.0.1", r);
});
await listen(server, kept?.meta.http ?? 0);
const base = `http://127.0.0.1:${server.address().port}`;
const tlsDir = join(scratch, "tls");
mkdirSync(tlsDir, { recursive: true });
if (!kept || !existsSync(join(tlsDir, "cert.pem"))) execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=127.0.0.1",
  "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", join(tlsDir, "key.pem"), "-out", join(tlsDir, "cert.pem")], { stdio: "ignore" });
const tlsCert = readFileSync(join(tlsDir, "cert.pem"));
const tlsServer = createHttpsServer({ key: readFileSync(join(tlsDir, "key.pem")), cert: tlsCert }, (req, res) => server.emit("request", req, res));
await listen(tlsServer, kept?.meta.https ?? 0);
const secureBase = `https://127.0.0.1:${tlsServer.address().port}`;
const tlsSpki = createHash("sha256").update(new X509Certificate(tlsCert).publicKey.export({ type: "spki", format: "der" })).digest("base64");

// MARK: The app

let exe, stdout, pid, child, launchedAt, exited = null;
let instance = null;
let notificationWatch = null;
let notificationQuit = null;
const notificationOwnedProcesses = new Map();
const notificationEffects = ["centerAcquire", "delegate", "categories", "authorization", "settings", "attachmentLoad", "add", "query", "removeDelivered", "removePending"];
function assertNotificationEffectsZero(value) {
  for (const key of notificationEffects) assert.equal(value?.[key], 0, `real-center effect ${key}`);
}
function notificationJournal(snapshot = null) {
  if (snapshot) {
    const coverage = snapshot.coverage;
    assert.equal(coverage?.initialized, true);
    assert.equal(coverage.complete, true, "coverage truncation is red");
    assert.equal(coverage.dropped, "0");
    assert.notEqual(snapshot.truncated, true);
    const records = [...Object.values(coverage.checkpoints ?? {}), ...(coverage.events ?? [])];
    const start = records.find((row) => row.kind === "coverage-start");
    assert.ok(start?.runNonce, "engine-generated startup nonce");
    notificationRun ??= start.runNonce;
    for (const row of records) {
      assert.equal(row.pid, pid);
      assert.equal(row.runNonce, notificationRun);
      assert.match(row.ordinal, /^[1-9][0-9]*$/);
      if (!notificationDiagnostics.some((entry) => entry.ordinal === row.ordinal)) notificationDiagnostics.push(row);
    }
  }
  return notificationDiagnostics.sort((a, b) => BigInt(a.ordinal) < BigInt(b.ordinal) ? -1 : 1);
}
function assertNotificationJournal(records, final = false) {
  assert.ok(records.length >= 2, "native startup coverage diagnostics");
  records.forEach((row, index) => {
    assert.equal(row.pid, pid);
    assert.equal(row.runNonce, notificationRun);
    assert.equal(row.ordinal, String(index + 1), "complete native coverage ordinal");
    for (const key of ["alertLaunch", "bannerBind", "appShimBind", "providerBind"]) assert.equal(row[key], "0", `native attempted provider use: ${key}`);
  });
  assert.equal(records[0].kind, "coverage-start");
  assert.equal(records[0].phase, "engine");
  assert.equal(records.find((row) => row.kind === "startup-complete")?.hooksInstalled, true);
  if (final) {
    const drain = records.find((row) => row.kind === "drain-complete");
    assert.ok(drain, "native early drain receipt");
    assert.equal(drain.settled, true);
    assert.equal(drain.complete, true);
    assert.equal(drain.unresolvedIDCount, 0);
    assert.equal(drain.unresolvedOperationCount, 0);
    assert.deepEqual(drain.unresolvedIDs, []);
    assert.deepEqual(drain.unresolvedOperations, []);
    assert.equal(records.at(-1).kind, "coverage-end");
    assert.ok(notificationRetired, "synchronous retirement diagnostic copy");
    assert.equal(notificationRetired.drainSettled, true);
    assert.equal(notificationRetired.queryCount, 0);
    assert.equal(notificationRetired.nativeOperationCount, 0);
    assert.equal(notificationRetired.hub.diagnosticsComplete, true);
    assert.equal(notificationRetired.hub.pendingCount, 0);
    assert.equal(notificationRetired.hub.deliveredCount, 0);
    assert.equal(notificationRetired.hub.removalCount, 0);
    assert.equal(notificationRetired.hub.inFlight, 0);
    assert.equal(notificationRetired.hub.diagnosticDrops, 0);
    assert.deepEqual(notificationRetired.hub.pending, []);
    assert.deepEqual(notificationRetired.hub.delivered, []);
    assertNotificationEffectsZero(notificationRetired.hub.realEffects);
  }
}
function captureNotificationRetirement() {
  const text = existsSync(stdout) ? readFileSync(stdout, "utf8") : "";
  const line = text.split("\n").findLast((row) => row.startsWith("SOLARA_NOTIFICATION_RETIRED "));
  assert.ok(line, "app copied and published final diagnostics before the quit continuation");
  notificationRetired = JSON.parse(line.slice("SOLARA_NOTIFICATION_RETIRED ".length));
  notificationJournal(notificationRetired);
  writeFileSync(join(notificationEvidence, "notification-native.jsonl"), notificationJournal().map((row) => JSON.stringify(row)).join("\n") + "\n");
  writeFileSync(join(notificationEvidence, "notification-retirement.json"), JSON.stringify(notificationRetired, null, 2));
}
function startNotificationWatch() {
  let running = true;
  const history = new Map();
  const errors = [];
  let samples = 0;
  const key = (row) => `${row.pid}:${row.started}`;
  const artifact = (command) => /^(.*?\.app)\/Contents\//.exec(command)?.[1] ?? "";
  const classify = () => {
    for (const [id, root] of notificationOwnedProcesses) {
      const row = history.get(id);
      if (row && row.command.startsWith(root.binary)) row.ownedBy.add(id);
    }
    let changed = true;
    while (changed) {
      changed = false;
      for (const row of history.values()) {
        for (const parent of row.parents) for (const owner of history.get(parent)?.ownedBy ?? []) {
          if (!row.ownedBy.has(owner)) { row.ownedBy.add(owner); changed = true; }
        }
      }
    }
    const descendants = [...history.values()].filter((row) => row.ownedBy.size > 0);
    for (const row of history.values()) {
      if (!row.alerts || row.ownedBy.size > 0) continue;
      const related = descendants.filter((ancestor) => artifact(ancestor.command) && artifact(ancestor.command) === artifact(row.command) && Date.parse(ancestor.started) <= Date.parse(row.started));
      if (related.length > 0) {
        row.association = "same-built-artifact-after-observed-descendant";
        for (const ancestor of related) for (const owner of ancestor.ownedBy) row.possibleOwners.add(owner);
      }
    }
  };
  const sample = () => new Promise((done) => {
    execFile("ps", ["-A", "-ww", "-o", "pid=,ppid=,lstart=,command="], { encoding: "utf8", timeout: 2000, maxBuffer: 64 << 20 }, (error, stdout) => {
      if (error) errors.push(String(error));
      else {
        samples++;
        const lines = stdout.split("\n").filter((line) => line.trim());
        const rows = lines.map((line) => /^\s*(\d+)\s+(\d+)\s+(.{24})\s+(.*)$/.exec(line)).filter(Boolean)
          .map((m) => ({ pid: Number(m[1]), ppid: Number(m[2]), started: m[3], command: m[4] }));
        if (rows.length !== lines.length || rows.some((row) => !Number.isFinite(Date.parse(row.started)))) errors.push("incomplete process-start identity snapshot");
        const byPid = new Map(rows.map((row) => [row.pid, row]));
        const now = new Date().toISOString();
        for (const row of rows) {
          const id = key(row);
          const seen = history.get(id) ?? { ...row, parents: new Set(), ownedBy: new Set(), possibleOwners: new Set(), firstSeen: now,
            alerts: / Helper \((?:Aperitif |Apéritif )?Alerts\)\.app\//.test(row.command) };
          const parent = byPid.get(row.ppid);
          if (parent && Date.parse(parent.started) <= Date.parse(row.started)) seen.parents.add(key(parent));
          if (!parent) {
            for (const previous of history.values()) {
              if (previous.pid === row.ppid && Date.parse(previous.started) <= Date.parse(row.started) && Date.parse(previous.lastSeen) >= Date.parse(row.started)) seen.parents.add(key(previous));
            }
          }
          seen.lastSeen = now;
          history.set(id, seen);
        }
        classify();
      }
      done();
    });
  });
  const loop = (async () => {
    while (running) {
      await sample();
      if (running) await sleep(100);
    }
  })();
  return {
    get finished() { return !running; },
    async finish() { running = false; await loop; classify(); },
    async assertZero() {
      await sample();
      assert.deepEqual(errors, [], "process monitoring errors");
      assert.ok(samples > 0, "process observation began before launch");
      assert.ok([...notificationOwnedProcesses.keys()].every((id) => history.has(id)), "every owned process has an observed exact start identity");
      assert.deepEqual([...history.values()].filter((row) => row.alerts && (row.ownedBy.size > 0 || row.possibleOwners.size > 0)), [], "owned or potentially reparented Alerts process history");
    },
    evidence() {
      classify();
      return { samples, errors, roots: [...notificationOwnedProcesses.values()], supplemental: true,
        processes: [...history.values()].filter((row) => row.alerts || row.ownedBy.size > 0).map((row) => ({ ...row, parents: [...row.parents], ownedBy: [...row.ownedBy], possibleOwners: [...row.possibleOwners] })) };
    },
  };
}

process.env.SOLARA_CHROMIUM_SWITCHES = `--force-color-profile=srgb --solara-test-media-route-provider --disable-media-route-providers-for-test --solara-test-bluetooth-chooser --solara-test-browser-lifetime ${process.env.SOLARA_CHROMIUM_SWITCHES ?? ""}`.trim();
process.env.SOLARA_CHROMIUM_SWITCHES += ` --host-resolver-rules=${["ib.adnxs.com", "securepubads.g.doubleclick.net", "pagead2.googlesyndication.com", "adpage.test"]
  .map((host) => `MAP ${host} 127.0.0.1:${server.address().port}`).concat([`one.${siteDataDomain}`, `two.${siteDataDomain}`, ...siteDataSecureHosts].map((host) => `MAP ${host} 127.0.0.1:${tlsServer.address().port}`)).join(", ")}`;
process.env.SOLARA_CHROMIUM_SWITCHES += ` --apps-gallery-update-url=${base}/webstore/crx`;
process.env.SOLARA_CHROMIUM_SWITCHES += ` --ignore-certificate-errors-spki-list=${tlsSpki}`;
process.env.SOLARA_CHROMIUM_SWITCHES += " --disable-audio-output";
async function launch(logName = "app.out.log", env = {}, args = [], opts = {}) {
  instance = await launchInstance(opts.app ?? app, {
    data, log: join(scratch, logName), args, ready: false,
    env: {
      SOLARA_TEST_REAUTH: "granted", SOLARA_DOWNLOADS_DIR: downloadsDir, SOLARA_ALLOW_AUDIO: "1",
      ...Object.fromEntries(["SOLARA_ALLOW_OCCLUSION", "SOLARA_TRACE_VISIBILITY", "SOLARA_TRACE_PIP", "SOLARA_NATIVE_SHELL", "SOLARA_NATIVE_TAB_SLEEP", "SOLARA_TAB_POOL"].filter((k) => process.env[k]).map((k) => [k, process.env[k]])),
      SOLARA_TRAFFIC_LIGHTS_LOG: lightsLog,
      ...env,
      ...(process.env.SOLARA_ACCEPTANCE_VISIBLE === "1" ? { SOLARA_BACKGROUND: null } : {}),
    },
    switches: `--auto-select-tab-capture-source-by-title=Capture Target --solara-test-external-protocol-no-launch ${process.env.SOLARA_CHROMIUM_SWITCHES ?? ""} ${opts.switches ?? ""}`.trim(),
    meta: { http: server.address().port, https: tlsServer.address().port },
  });
  adopt(instance);
  const output = await settledAudioOutput(pid);
  if (output !== "fake") {
    await instance.quit();
    throw new Error(`pid ${pid} ${unproven(output)}: quit before any check plays sound`);
  }
}
function adopt(i) {
  instance = i;
  ({ pid, port, launchedAt, binary: exe, log: stdout } = i);
  const own = pid;
  if (notificationOnly) notificationOwnedProcesses.set(`${own}:${i.started}`, { pid: own, started: i.started, binary: i.binary });
  child = { pid: own, kill: (sig) => { if (i.stillOwned()) try { process.kill(own, sig); } catch {} } };
  exited = null;
  writeFileSync(join(scratch, "app.pid"), String(own));
}
if (notificationOnly) notificationWatch = startNotificationWatch();
try {
  if (kept) adopt(kept);
  else await launch();
} catch (error) {
  try { if (instance) await instance.quit(); }
  finally { await notificationWatch?.finish(); }
  throw error;
}
const alive = () => { try { process.kill(pid, 0); return true; } catch { return false; } };
setInterval(() => { if (!exited && !alive()) exited = { pid }; }, 300).unref();
const appLog = { join: () => (existsSync(stdout) ? readFileSync(stdout, "utf8") : "") };

async function evalApp(body, timeoutMs = 20000) {
  if (exited) throw new Error(`app exited ${JSON.stringify(exited)}`);
  try {
    return await instance.eval(body, { timeout: timeoutMs });
  } catch (e) {
    if (e.appDied) throw new Error(`app exited ${JSON.stringify(exited ?? { pid })}`);
    throw e;
  }
}

async function until(what, fn, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await fn();
    if (last) return last;
    await sleep(200);
  }
  throw new Error(`timed out waiting for ${what} (last: ${JSON.stringify(last)})`);
}

async function targets() {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  return res.json();
}

async function extensionWorker(id, api, timeoutMs = 15000) {
  const seen = [];
  const note = (entry) => {
    const last = seen.at(-1);
    if (last && JSON.stringify(last.what) === JSON.stringify(entry)) last.times++;
    else seen.push({ what: entry, times: 1 });
  };
  return until("the extension's worker", async () => {
    const workers = (await targets()).filter((t) => t.type === "service_worker" && t.url.includes(id));
    if (!workers.length) note("no worker target");
    for (const t of workers) {
      const r = await cdp(t, "Runtime.evaluate", { expression: `typeof chrome?.${api.split(".").join("?.")}`, returnByValue: true }).catch((e) => ({ failed: String(e?.message ?? e).slice(0, 120) }));
      if (r?.result?.value === "function") return t;
      note({ worker: t.id, url: t.url, answer: r?.failed ?? r?.result?.value ?? r });
    }
    return null;
  }, timeoutMs).catch((e) => {
    throw new Error(`${e.message}; ${id} chrome.${api} seen: ${JSON.stringify(seen.slice(-6))}`);
  });
}

async function cdp(target, method, params = {}) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error(`DevTools connection to ${target.url} failed (${method})`)))));
  const reply = new Promise((r) => {
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id === 1) r(msg);
    };
    ws.onclose = () => r({ error: `the target closed before replying (${method})` });
  });
  ws.send(JSON.stringify({ id: 1, method, params }));
  const msg = await Promise.race([reply, sleep(10000).then(() => ({ error: "cdp timeout" }))]);
  ws.close();
  if (msg.error) throw new Error(JSON.stringify(msg.error));
  return msg.result;
}

function firstPixel(base64) {
  const png = Buffer.from(base64, "base64");
  let ihdr = null;
  const idat = [];
  for (let off = 8; off < png.length; ) {
    const len = png.readUInt32BE(off), type = png.toString("latin1", off + 4, off + 8);
    if (type === "IHDR") ihdr = png.subarray(off + 8, off + 8 + len);
    if (type === "IDAT") idat.push(png.subarray(off + 8, off + 8 + len));
    if (type === "IEND") break;
    off += 12 + len;
  }
  const depth = ihdr[8], channels = { 2: 3, 6: 4 }[ihdr[9]];
  if (depth !== 8 || !channels) throw new Error(`PNG depth ${depth}, color type ${ihdr[9]}`);
  const px = inflateSync(Buffer.concat(idat)).subarray(1, 1 + channels);
  return [px[0], px[1], px[2], channels === 4 ? px[3] : 255];
}

const pageTarget = async (urlPart) => (await targets()).find((t) => t.type === "page" && t.url.includes(urlPart));
const closeFromPage = (target) =>
  cdp(target, "Runtime.evaluate", { expression: "setTimeout(() => window.close()); true" }).catch((e) => {
    if (!String(e?.message).includes("the target closed before replying")) throw e;
  });
const cef = (call) => evalApp(`return globalThis.expo.modules.SolaraCEF.${call}`);
const webKit = (call) => evalApp(`return globalThis.expo.modules.SolaraWebKit.${call}`);
const exts = (call) => evalApp(`return globalThis.expo.modules.SolaraExtensions.${call}`);
const extPath = join(scratch, "fixture-ext");
const extensionPagesOpenedAsTabs = new Set();
cpSync(resolve(new URL(".", import.meta.url).pathname, "fixtures/ext"), extPath, { recursive: true });
const extPopupPath = join(scratch, "fixture-ext-popup");
function writePopupExtension({ welcome = false } = {}) {
  rmSync(extPopupPath, { recursive: true, force: true });
  mkdirSync(extPopupPath, { recursive: true });
  const files = {
    "manifest.json": JSON.stringify({
      manifest_version: 3, name: "SolaraCore popup fixture", version: "1.0",
      action: { default_popup: "popup.html", default_title: "Popup fixture" },
      background: { service_worker: "worker.js" },
      options_page: "options.html",
      permissions: ["tabs", "declarativeNetRequest"],
      host_permissions: ["http://127.0.0.1/*"],
      web_accessible_resources: [{ resources: ["standin.js"], matches: ["http://127.0.0.1/*"] }],
      declarative_net_request: { rule_resources: [{ id: "rules", enabled: true, path: "rules.json" }] },
    }),
    "popup.html": `<!doctype html><title>Popup fixture</title><body style="width: 200px; height: 80px">popup</body>`,
    "options.html": `<!doctype html><title>Popup fixture options</title><body>options</body>`,
    "standin.js": "window.__acStandIn = true;",
    "worker.js": welcome ? `chrome.runtime.onInstalled.addListener((d) => { if (d.reason === "install") chrome.tabs.create({ url: "${base}/e?installed" }); });` : "",
    "rules.json": JSON.stringify([
      { id: 1, priority: 1, action: { type: "block" }, condition: { urlFilter: "nnblock-", resourceTypes: ["image", "script", "xmlhttprequest"] } },
      { id: 2, priority: 1, action: { type: "redirect", redirect: { extensionPath: "/standin.js" } }, condition: { urlFilter: "nnredirect-", resourceTypes: ["script"] } },
    ]),
  };
  for (const [name, text] of Object.entries(files)) writeFileSync(join(extPopupPath, name), text);
}
let crxCache = null;
function fixtureCrx() {
  if (crxCache) return crxCache;
  const files = { "manifest.json": JSON.stringify({ manifest_version: 3, name: "SolaraCore crx fixture", version: "1.0" }) };
  const locals = [], centrals = [];
  let offset = 0;
  for (const [name, text] of Object.entries(files)) {
    const data = Buffer.from(text), nameBytes = Buffer.from(name), sum = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt32LE(sum, 14);
    local.writeUInt32LE(data.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(nameBytes.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt32LE(sum, 16);
    central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, nameBytes, data);
    centrals.push(central, nameBytes);
    offset += local.length + nameBytes.length + data.length;
  }
  const directory = Buffer.concat(centrals), end = Buffer.alloc(22), count = Object.keys(files).length;
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(count, 8); end.writeUInt16LE(count, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  const zip = Buffer.concat([...locals, directory, end]);
  const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const der = publicKey.export({ type: "spki", format: "der" });
  const varint = (n) => { const out = []; while (n > 127) { out.push((n & 127) | 128); n = Math.floor(n / 128); } out.push(n); return Buffer.from(out); };
  const field = (number, bytes) => Buffer.concat([varint(number * 8 + 2), varint(bytes.length), bytes]);
  const signedData = field(1, createHash("sha256").update(der).digest().subarray(0, 16));
  const size = Buffer.alloc(4);
  size.writeUInt32LE(signedData.length);
  const signature = createSign("sha256").update(Buffer.concat([Buffer.from("CRX3 SignedData\x00", "latin1"), size, signedData, zip])).sign(privateKey);
  const header = Buffer.concat([field(2, Buffer.concat([field(1, der), field(2, signature)])), field(10000, signedData)]);
  const prefix = Buffer.alloc(12);
  prefix.write("Cr24", 0, "latin1"); prefix.writeUInt32LE(3, 4); prefix.writeUInt32LE(header.length, 8);
  return (crxCache = Buffer.concat([prefix, header, zip]));
}
const onScreenWindows = () => windowsOf(pid);
const browserOf = (tabId) => evalApp(`return ac.pageState.getState().browsers ? Object.entries(ac.pageState.getState().browsers).find(([, t]) => t === "${tabId}")?.[0] ?? null : null`);
async function pageFor(tabId, urlPart) {
  const candidates = (await targets()).filter((t) => t.type === "page" && t.url.includes(urlPart));
  if (candidates.length <= 1) return candidates[0];
  await evalApp(`return ac.webviews.get(${JSON.stringify(tabId)})?.executeJavaScript(${JSON.stringify(`window.__acTab = ${JSON.stringify(tabId)}`)})`);
  await sleep(200);
  for (const t of candidates) {
    const r = await cdp(t, "Runtime.evaluate", { expression: "String(window.__acTab)", returnByValue: true }).catch(() => null);
    if (r?.result?.value === tabId) return t;
  }
  return candidates[0];
}
let mainWindow = null;
let first;
const nativeSleepExpected = () => process.env.SOLARA_NATIVE_TAB_SLEEP !== "0" && process.env.SOLARA_TAB_POOL !== "0";
let personal = null;
const eventsOf = async (tabId) => {
  const browser = await browserOf(tabId);
  return browser ? evalApp(`return globalThis.expo.modules.SolaraCEF.devEvents(${browser})`) : [];
};
const state = () =>
  evalApp(`const s = ac.store.getState(); const w = s.windows[${JSON.stringify(mainWindow)}] ?? Object.values(s.windows).filter((w) => !w.incognito && w.kind !== "small").sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0))[0];
    return { windowId: w?.id, profileId: w?.profileId, tabs: (w?.tabIds ?? []).map((id) => ({ id, url: s.tabs[id]?.url, title: s.tabs[id]?.title, favicon: s.tabs[id]?.favicon?.slice(0, 40), adoptId: s.tabs[id]?.adoptId, profileId: s.tabs[id]?.profileId, loading: s.live[id]?.isLoading, back: s.live[id]?.canGoBack, fwd: s.live[id]?.canGoForward })), active: w ? w.activeTabIds[w.profileId] : null, windows: Object.keys(s.windows).length, profiles: s.profileOrder };`);

// MARK: Helpers

const openTab = async (url, title, background = false) => {
  const before = new Set((await state()).tabs.map((t) => t.id));
  await evalApp(`ac.actions.openUrls([${JSON.stringify(url)}], ${JSON.stringify(mainWindow)}); return true`);
  const tab = await until(`a tab for ${url}`, async () => (await state()).tabs.find((t) => !before.has(t.id) && t.title === title && !t.loading), 15000);
  if (background) {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
  }
  return tab;
};
const closeTab = (id) => evalApp(`ac.store.getState().closeTab("${id}"); return true`);
const shownAndMounted = async (id) => {
  await evalApp(`ac.actions.switchToTab(${JSON.stringify(id)}); return true`);
  await until(`${id}'s WebView`, () => evalApp(`return !!ac.webviews.get(${JSON.stringify(id)})`), 15000);
};
const freshTab = async (url) => {
  const id = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: ${JSON.stringify(url)} })`);
  await shownAndMounted(id);
  await until(`${url} loaded`, () => evalApp(`const s = ac.store.getState(); return s.tabs[${JSON.stringify(id)}]?.url && !s.live[${JSON.stringify(id)}]?.isLoading ? true : null`));
  return id;
};
const backToA = async () => {
  await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a", { userInitiated: true }); return true`);
  await until("A again", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading));
  await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
};
const lastEvent = async (tabId, name, test = () => true) => (await eventsOf(tabId)).findLast((x) => x.name === name && test(x.payload ?? {})) ?? null;
const live = (tabId) => evalApp(`return ac.store.getState().live["${tabId}"] ?? null`);
const pipWindows = () => cef(`devPictureInPicture()`).catch(() => null);
const startVideo = async (tabId, audio) => {
  const t = await pageFor(tabId, "/video");
  const r = await cdp(t, "Runtime.evaluate", { expression: `start(${audio})`, awaitPromise: true, userGesture: true, returnByValue: true });
  if (r.result?.value !== "ok") throw new Error(`the video didn't play: ${JSON.stringify(r.result ?? r)}`);
  await until("the video's first frames", async () => (await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('v').videoWidth", returnByValue: true })).result?.value > 0, 8000);
  return t;
};
const pipByHand = async (tabId) => {
  await evalApp(`ac.pageState.setState((s) => ({ popover: { ...s.popover, ${JSON.stringify(tabId)}: "siteControls" } })); return true`);
  return until("a click on Site Controls › Picture in Picture", async () => {
    const click = await evalApp(`return ac.shell.devClick(${JSON.stringify(mainWindow)}, { label: "Picture in Picture", queued: true, wait: 300 })`);
    return click?.error ? null : click;
  }, 5000);
};
const stopApp = async () => {
  if (!exited) await instance.quit();
  await until("the app to exit", async () => exited || !alive(), 5000);
  exited ??= { pid };
};
const appUp = async (logName) => {
  if (exited) await launch(logName);
  await until("the app", async () => {
    try {
      return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
    } catch (e) {
      if (exited) throw e;
      return null;
    }
  }, 90000);
  mainWindow = null;
  return (mainWindow = await until("a window", async () => (await state()).windowId, 30000));
};

let currentCheck = "";
let visibilityWatch = null;
function watchVisibility(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let last = null, seq = 0;
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    const value = msg.result?.result?.value;
    if (value && value !== last) {
      log(`  [vis ${stamp()}] ${last ?? "-"} → ${value} during ${currentCheck}`);
      last = value;
    }
  };
  const timer = setInterval(() => {
    if (ws.readyState === 1)
      ws.send(JSON.stringify({ id: ++seq, method: "Runtime.evaluate", params: { expression: "document.visibilityState + '/' + location.pathname + '/' + document.hasFocus()", returnByValue: true } }));
  }, 250);
  ws.onclose = () => clearInterval(timer);
  visibilityWatch = { stop: () => { clearInterval(timer); try { ws.close(); } catch {} } };
}

const recovered = new Set();
async function recoverKept() {
  await until("the kept instance's dev harness", () => evalApp("return true", 3000).catch(() => null), 30000);
  mainWindow = (await state()).windowId;
  recovered.add("boot");
  const a = await evalApp(`const s = ac.store.getState(); const ids = [...(s.windows[${JSON.stringify(mainWindow)}]?.tabIds ?? []), ...Object.keys(s.tabs)];
    const id = ids.find((i) => s.tabs[i]?.url?.startsWith(${JSON.stringify(`${base}/a`)}) && s.tabs[i]?.title === "Page A");
    return id ? { id, url: s.tabs[id].url, title: "Page A" } : null`);
  if (a) {
    first = a;
    recovered.add("open-url");
  }
}

async function check(name, fn) {
  if (!selected.has(name)) return;
  if ((process.env.SKIP ?? "").split(",").includes(name)) return;
  if (recovered.has(name)) return;
  currentCheck = name;
  if (process.env.SOLARA_TRACE_VISIBILITY) log(`  [check ${stamp()}] ${name}`);
  let failure = null;
  const started = Date.now();
  await report.check(name, async () => {
    const evidence = await fn();
    results.push({ name, ok: true, evidence, ms: Date.now() - started });
    return evidence;
  }, {
    async onFail(e) {
      let snapshot = null;
      try {
        snapshot = await state();
      } catch {}
      results.push({ name, ok: false, error: String(e?.message ?? e), state: snapshot, ms: Date.now() - started });
      log(`state: ${JSON.stringify(snapshot)}`);
      if (first)
        try {
          log(`events of ${first.id}: ${JSON.stringify((await eventsOf(first.id)).slice(-12))}`);
        } catch {}
    },
  });
}

// MARK: Checks

try {
  if (kept) await recoverKept();
  if (kept) report.say(`attached to pid ${pid}${recovered.size ? ` (has ${[...recovered].join(", ")})` : ""}`);
  const running = [...deps.keys()].filter((dep) => !recovered.has(dep));
  if (running.length) report.say(`first, as ${[...new Set(running.flatMap((d) => deps.get(d)))].join(", ")} need: ${running.join(", ")}`);
  // MARK: Windows, tabs and navigation

  await check("boot", async () => {
    const info = await until("the dev harness", async () => {
      try {
        return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 90000);
    if (info.engine !== "solaracore") throw new Error(`engine ${info.engine}`);
    const s = await until("a window", async () => ((await state()).windowId ? state() : null), 30000);
    await evalApp(`ac.store.getState().updateSettings({ warnBeforeQuitting: false }); return true`);
    const front = execFileSync("lsappinfo", ["front"]).toString();
    const asn = execFileSync("lsappinfo", ["info", "-only", "pid", front.trim()]).toString();
    if (asn.includes(`=${child.pid}`)) throw new Error("the app took focus");
    mainWindow = s.windowId;
    await sleep(2000);
    const native = await evalApp(`return ac.shell.windowIds()`);
    if (native.length !== 1) throw new Error(`windows ${JSON.stringify(native)} (a second JS runtime?)`);
    return { chromium: info.chromiumVersion, windows: s.windows, tabs: s.tabs.length, pid: child.pid };
  });

  await check("notifications-one-requester", async () => {
    const errors = [];
    const delivered = [];
    const displayedQueries = [];
    const authorizationRevocations = [];
    let tab = null;
    let target = null;
    let settingTouched = false;
    let initialPermission = null;
    let evidence = null;
    let osAuthorization = { status: "not-measured-hidden-adapter" };
    let previousLifetime = null;
    let priorEnvelope = null;
    const snapshot = async (requireLive = true) => {
      const value = await cef("notificationDebugSnapshot()");
      assert.equal(value.protocol, 2);
      assert.equal(value.hub.mode, "memory");
      notificationJournal(value);
      if (requireLive) assert.equal(value.state, "Live");
      assertNotificationEffectsZero(value.hub.realEffects);
      assert.equal(value.hub.diagnosticsComplete, true);
      assert.notEqual(value.hub.truncated, true);
      assert.equal(value.hub.diagnosticDrops, 0);
      assert.equal(value.hub.pendingCount, value.hub.pending.length);
      assert.equal(value.hub.deliveredCount, value.hub.delivered.length);
      for (const key of ["alertLaunch", "bannerBind", "appShimBind", "providerBind"]) assert.equal(value.providerAttempts[key], "0", `provider attempts ${key}`);
      return value;
    };
    const displayed = async () => until("authoritative Chromium displayed callback", async () => {
      const value = await cef(`notificationDebugDisplayed("", ${JSON.stringify(base)})`);
      displayedQueries.push(value);
      assert.equal(value.completed, true, "displayed callback completed");
      if (!value.supportsSynchronization) return null;
      return value.ids;
    }, 10000);
    const page = async (expression) => {
      const result = await cdp(target, "Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
      if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
      return result.result?.value;
    };
    const removed = async (route) => until(`Hub and Chromium removal ${route.nativeID}`, async () => {
      const value = await snapshot();
      if (value.hub.delivered.some((row) => row.nativeID === route.nativeID) || value.hub.pending.some((row) => row.nativeID === route.nativeID)) return false;
      return !(await displayed()).includes(route.chromiumID);
    }, 10000);
    const post = async (phase) => {
      await page(`window.showPersistent(${JSON.stringify(notificationRun)}, ${JSON.stringify(phase)})`);
      await until(`worker showNotification resolved: ${phase}`, async () => {
        const value = await page("window.notificationState");
        if (value?.state === "error") throw new Error(JSON.stringify(value));
        return value?.phase === phase && value.entered && value.state === "shown";
      }, 10000);
      const route = await until(`Hub accepted, delivered and engine acknowledged: ${phase}`, async () => {
        const value = await snapshot();
        const post = value.hub.posts.find((row) => row.title === `${notificationRun}:${phase}` && row.status === "accepted");
        if (!post?.receipt) return null;
        assert.equal(post.body, "from service worker");
        const route = value.routes.find((row) => row.token === post.token && row.generation === post.generation && row.nativeID === post.nativeID && new URL(row.origin).origin === new URL(base).origin);
        if (!route?.accepted) return null;
        assert.ok(route.token && route.generation && route.nativeID && route.chromiumID && route.scope && route.lifetime, "complete engine route");
        assert.equal(route.receipt, post.receipt);
        const scope = value.scopes.find((row) => row.scope === route.scope && row.lifetime === route.lifetime);
        assert.ok(scope && !scope.session && !scope.process, "exact regular producer scope");
        const hub = value.hub.delivered.find((row) => row.token === route.token && row.generation === route.generation && row.nativeID === route.nativeID);
        if (!hub || hub.title !== post.title || hub.body !== post.body) return null;
        assert.ok(hub.workerScope?.startsWith(base + "/notification-fixture/"), "Hub carries Chromium worker scope resources");
        if (value.hub.pending.some((row) => row.nativeID === route.nativeID)) return null;
        const ack = value.hub.acks.find((row) => row.token === route.token && row.generation === route.generation && row.nativeID === route.nativeID && row.receipt === post.receipt && row.engineAccepted === true);
        return ack ? { ...route, B: value.B, W: value.W, title: post.title, body: post.body, receipt: post.receipt } : null;
      }, 10000);
      assert.ok((await displayed()).includes(route.chromiumID), "Chromium displayed contains accepted Hub generation");
      delivered.push(route);
      return route;
    };
    const authorizationControl = async (op, values = {}) => {
      const value = await evalApp(`return globalThis.expo.modules.SolaraApp.notificationDebugAuthorization(${JSON.stringify({ op, ...values })})`);
      assert.equal(value.ok, true, `hidden authorization control ${op}`);
      return value;
    };
    const revokedAuthorization = async (delay, setting, calendarSurvivor = false) => {
      const phase = `revocation-${delay}-${setting}-${calendarSurvivor ? "calendar-survivor" : "alone"}`;
      await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", "allow")`);
      await until(`${phase} starts at effective Allow`, async () => (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications.value === "allow", 5000);
      const before = await snapshot();
      const known = new Set(before.routes.map((route) => route.token));
      await authorizationControl("configure", { holdSettings: delay === "settings", holdConsumption: delay === "consumption" });
      await page(`window.revocationNotifications ??= []; window.revocationNotifications.push(new Notification(${JSON.stringify(phase)}, { body: "current effective permission", silent: true })); true`);
      const route = await until(`${phase} has a trusted live engine route`, async () => {
        const value = await snapshot();
        return value.routes.find((row) => !known.has(row.token) && row.authorizationEligible === true && !row.withdrawn && new URL(row.origin).origin === new URL(base).origin);
      }, 5000);
      const delayed = await until(`${phase} reaches its delay`, async () => {
        const value = await authorizationControl("snapshot");
        return delay === "settings" ? value.heldSettings === 1 && value.permissionWaiters === 1 && value : value.heldConsumption > 0 && value;
      }, 5000);
      assert.equal(delayed.authorizationCalls, 0);
      if (calendarSurvivor) {
        await evalApp(`globalThis.notificationCalendarSurvivor = { settled: false }; globalThis.expo.modules.SolaraApp.requestNotificationPermission().then((granted) => { globalThis.notificationCalendarSurvivor = { settled: true, granted }; }); return true`);
        const shared = await until(`${phase} joins the same pending settings operation`, async () => {
          const value = await authorizationControl("snapshot");
          return value.permissionWaiters === 2 && value;
        }, 5000);
        assert.equal(shared.settingsCalls, 1);
        assert.equal(shared.authorizationCalls, 0);
      }
      if (setting === "reset") await cef(`resetSiteSettings("", ${JSON.stringify(base)})`);
      else await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", ${JSON.stringify(setting)})`);
      const effective = setting === "block" ? "block" : "ask";
      await until(`${phase} revokes effective permission before release`, async () => (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications.value === effective, 5000);
      const released = await authorizationControl(delay === "settings" ? "releaseSettings" : "releaseConsumption");
      assert.equal(released.authorizationCalls, calendarSurvivor ? 1 : 0, `${phase}: revoked site cannot initiate authorization`);
      assert.equal(released.authorizationPending, calendarSurvivor);
      if (calendarSurvivor) {
        await authorizationControl("completeAuthorization", { granted: true });
        const calendar = await until(`${phase} completes surviving explicit calendar caller`, async () => evalApp(`return globalThis.notificationCalendarSurvivor?.settled ? globalThis.notificationCalendarSurvivor : null`), 5000);
        assert.equal(calendar.granted, true);
      }
      await until(`${phase} settles without delivery`, async () => {
        const value = await snapshot();
        const denied = value.hub.posts.some((row) => row.nativeID === route.nativeID && row.status === "denied");
        assert.equal(value.hub.posts.some((row) => row.nativeID === route.nativeID && row.status === "accepted"), false, `${phase}: revoked waiter remains denied after shared completion`);
        return denied && !value.hub.pending.some((row) => row.nativeID === route.nativeID) && !value.hub.delivered.some((row) => row.nativeID === route.nativeID) && value.hub.inFlight === 0;
      }, 5000);
      const completed = await authorizationControl("snapshot");
      assert.equal(completed.authorizationCalls, calendarSurvivor ? 1 : 0);
      assert.equal(completed.permissionWaiters, 0);
      assert.equal(completed.heldSettings, 0);
      assert.equal(completed.heldConsumption, 0);
      assert.equal(completed.authorizationPending, false);
      authorizationRevocations.push({ phase, route, effective, delayed, released, completed });
      await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", "allow")`);
      await until(`${phase} restores Allow before closing its fixture`, async () => (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications.value === "allow", 5000);
      await page("for (const notification of window.revocationNotifications ?? []) notification.close(); window.revocationNotifications = []; true");
      await removed(route);
      await authorizationControl("reset");
    };
    const respond = async (route, kind) => {
      const identifier = kind === "click" ? "com.apple.UNNotificationDefaultActionIdentifier" : "com.apple.UNNotificationDismissActionIdentifier";
      const response = await evalApp(`return globalThis.expo.modules.SolaraApp.notificationDebugRespond(${JSON.stringify(route.nativeID)}, ${JSON.stringify(identifier)})`);
      assert.equal(response.accepted, true, "native response decoder accepted current route");
      assert.ok(response.token, "native action token");
      await until(`Chromium operation completion: ${kind}`, async () => {
        const value = await snapshot();
        return value.hub.operations.some((row) => row.token === response.token && row.state === "settled" && row.engineCompleted === true);
      }, 10000);
      await until(`worker notification${kind}`, async () => notificationWorkerEvents.find((row) => row.run === notificationRun && row.kind === kind && row.title === route.title), 10000);
      await removed(route);
    };
    const quitAndCapture = async () => {
      notificationQuit = await instance.quit();
      assert.equal(notificationQuit.how, "quit", "owned instance must shut down gracefully");
      assert.equal(alive(), false);
      captureNotificationRetirement();
      assertNotificationJournal(notificationJournal(), true);
      await notificationWatch.assertZero();
    };
    try {
      await until("native startup coverage diagnostics", async () => {
        try {
          const records = notificationJournal(await cef("notificationDebugSnapshot()"));
          return records.some((row) => row.kind === "coverage-start") && records.some((row) => row.kind === "startup-complete") ? records : null;
        } catch (error) {
          if (!alive()) throw error;
          return null;
        }
      }, 8000);
      assertNotificationJournal(notificationJournal());
      await notificationWatch.assertZero();
      assert.equal(await evalApp("return ac.shell.backgroundInstance"), true);
      await until("notification consumer Live after replay", async () => (await snapshot(false)).state === "Live", 10000);
      initialPermission = (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications;
      assert.equal(initialPermission.isDefault, true);
      settingTouched = true;
      await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", "allow")`);
      await until("fixture site notification Allow", async () => (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications.value === "allow", 5000);
      tab = await openTab(`${base}/notification-fixture/?${notificationRun}`, "Persistent notification fixture");
      target = await pageFor(tab.id, `${base}/notification-fixture/`);
      for (const delay of ["settings", "consumption"]) {
        for (const setting of ["block", "ask", "reset"]) await revokedAuthorization(delay, setting);
      }
      for (const setting of ["block", "ask"]) await revokedAuthorization("settings", setting, true);
      await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", "allow")`);
      await until("persistent fixture permission restored to Allow", async () => (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications.value === "allow", 5000);
      const click = await post("click");
      const unsupported = await evalApp(`return globalThis.expo.modules.SolaraApp.notificationDebugRespond(${JSON.stringify(click.nativeID)}, "solara.unsupported.action")`);
      assert.equal(unsupported.accepted, false, "v1 rejects action buttons before engine dispatch");
      assert.ok((await snapshot()).hub.delivered.some((row) => row.nativeID === click.nativeID));
      await respond(click, "click");
      await respond(await post("close"), "close");
      const programmatic = await post("programmatic");
      assert.equal(await page(`window.closePersistent(${JSON.stringify(notificationRun)}, "programmatic")`), 1);
      await removed(programmatic);
      await post("cleanup");
      const cleanup = await page("window.cleanupPersistent()");
      assert.deepEqual(cleanup, { closed: 1, remaining: 0, unregistered: true, registration: false });
      for (const route of delivered) await removed(route);
      assert.deepEqual(await displayed(), []);
      await sleep(1000);
      assert.deepEqual(notificationWorkerEvents.filter((row) => row.run === notificationRun).map((row) => `${row.kind}:${row.title}`).sort(), [`click:${notificationRun}:click`, `close:${notificationRun}:close`].sort(), "no synthetic programmatic-close or duplicate worker event");
      const quitLive = await post("quit-live");
      await post("quit-live-second");
      const liveID = await evalApp(`return globalThis.expo.modules.SolaraApp.postNotification({ id: "notification-quit-live", title: "App quit removal", body: "native app namespace", silent: true })`);
      assert.ok(liveID, "native app notification accepted before quit");
      const beforeQuit = await snapshot();
      assert.ok(beforeQuit.hub.delivered.some((row) => row.nativeID === liveID), "quit includes native app notifications as well as engine generations");
      assert.ok(beforeQuit.hub.delivered.filter((row) => [quitLive.nativeID, delivered.at(-1).nativeID].includes(row.nativeID)).length === 2, "quit starts with accepted settled persistent notifications still delivered");
      priorEnvelope = Object.fromEntries(["B", "W", "scope", "lifetime", "root", "profile", "incarnation", "session", "token", "creation", "generation", "nativeID"].map((key) => [key, quitLive[key]]));
      await quitAndCapture();
      previousLifetime = { pid, runNonce: notificationRun, B: beforeQuit.B, retired: notificationRetired, journal: [...notificationJournal()] };
      writeFileSync(join(notificationEvidence, "notification-first-lifetime.json"), JSON.stringify(previousLifetime, null, 2));
      notificationDiagnostics.length = 0;
      notificationRun = null;
      notificationRetired = null;
      await launch("app-notification-relaunched.out.log");
      await until("relaunched notification diagnostics", async () => {
        try { return (await snapshot(false)).state === "Live"; }
        catch (error) { if (!alive()) throw error; return false; }
      }, 30000);
      const beforePrior = await snapshot();
      assert.notEqual(beforePrior.B, previousLifetime.B);
      assert.notEqual(notificationRun, previousLifetime.runNonce);
      assert.deepEqual(beforePrior.routes, [], "relaunch does not reconstruct route authority from the notification database");
      assert.equal(await evalApp(`return globalThis.expo.modules.SolaraApp.notificationDebugRestorePrior(${JSON.stringify(priorEnvelope)})`), true, "seed only the hidden native adapter with a prior-process item");
      assert.ok((await snapshot()).hub.delivered.some((row) => row.nativeID === priorEnvelope.nativeID));
      const prior = await evalApp(`return globalThis.expo.modules.SolaraApp.notificationDebugRespond(${JSON.stringify(priorEnvelope.nativeID)}, "com.apple.UNNotificationDefaultActionIdentifier")`);
      assert.equal(prior.accepted, false);
      assert.equal(prior.error, "priorProcessAction");
      assert.equal(prior.removed, true);
      await until("prior-process exact native item removed", async () => {
        const value = await snapshot();
        return !value.hub.pending.some((row) => row.nativeID === priorEnvelope.nativeID) && !value.hub.delivered.some((row) => row.nativeID === priorEnvelope.nativeID);
      }, 5000);
      assert.deepEqual((await snapshot()).routes, []);
      assert.deepEqual(await displayed(), []);
      if (process.env.SOLARA_NOTIFICATION_USERNOTED_LOG) {
        const source = readFileSync(process.env.SOLARA_NOTIFICATION_USERNOTED_LOG, "utf8");
        const evidence = JSON.parse(source);
        writeFileSync(join(notificationEvidence, "usernoted-evidence.json"), JSON.stringify(evidence, null, 2));
        try { osAuthorization = assertNotificationAuthorizationLog(evidence); }
        catch (error) { osAuthorization = { status: "inconclusive", reason: error.message }; throw error; }
        assert.equal(osAuthorization.status, "measured-pass", "separate calibrated OS authorization measurement");
      }
      await sleep(1000);
      assert.deepEqual(notificationWorkerEvents.filter((row) => row.run === previousLifetime.runNonce).map((row) => row.kind).sort(), ["click", "close"], "prior-process click dispatches no worker event");
    } catch (error) {
      errors.push(error);
    } finally {
      const attempt = async (operation) => { try { await operation(); } catch (error) { errors.push(error); } };
      if (alive()) await attempt(async () => {
        await authorizationControl("reset");
        if (target && !previousLifetime) {
          await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", "allow")`);
          await page("for (const notification of window.revocationNotifications ?? []) notification.close(); window.revocationNotifications = []; true");
        }
        await evalApp("delete globalThis.notificationCalendarSurvivor; return true");
      });
      if (settingTouched && alive()) await attempt(async () => {
        await cef(`setSiteSetting("", ${JSON.stringify(base)}, "notifications", "default")`);
        await until("scratch site permission restored", async () => {
          const setting = (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).notifications;
          return setting.isDefault === true && setting.value === initialPermission.value;
        }, 5000);
      });
      if (alive()) await attempt(async () => {
        if (previousLifetime) {
          tab = await openTab(`${base}/notification-fixture/?cleanup`, "Persistent notification fixture");
          target = await pageFor(tab.id, `${base}/notification-fixture/`);
        }
        if (target) {
          const cleanup = await page("window.cleanupPersistent()");
          assert.equal(cleanup.unregistered, true);
          assert.equal(cleanup.registration, false);
          assert.equal(cleanup.remaining, 0);
        }
        if (tab) await closeTab(tab.id);
      });
      if (alive()) await attempt(quitAndCapture);
      await attempt(async () => notificationWatch.assertZero());
      await attempt(async () => {
        evidence = { directory: notificationEvidence, runNonce: notificationRun, pid, previousLifetime, priorEnvelope, osAuthorization, delivered, displayedQueries, authorizationRevocations, workerEvents: notificationWorkerEvents, journal: notificationJournal(), monitor: notificationWatch.evidence(), quit: notificationQuit, errors: errors.map(String) };
        writeFileSync(join(notificationEvidence, "notification-evidence.json"), JSON.stringify(evidence, null, 2));
        writeFileSync(join(notificationEvidence, "notification-native.jsonl"), notificationJournal().map((row) => JSON.stringify(row)).join("\n") + "\n");
        assert.equal(alive(), false, "never delete a running instance's data");
        rmSync(data, { recursive: true, force: true });
        assert.equal(existsSync(data), false);
      });
    }
    if (errors.length) throw new AggregateError(errors, errors.map((error) => String(error?.message ?? error)).join("; "));
    return evidence;
  });

  await check("window-profiles", async () => {
    const home = (await state()).windowId;
    const titles = (w) => evalApp(`const s = ac.store.getState(); return (s.windows[${JSON.stringify(w)}]?.tabIds ?? []).map((i) => s.tabs[i]?.title)`);
    const shows = (w, title) => until(`${title} in ${w}`, async () => ((await titles(w)).includes(title) ? true : null), 15000);
    const cookie = async (urlPart) => (await cdp(await until(urlPart, () => pageTarget(urlPart)), "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
    const open = (o) => evalApp(`return ac.actions.openWindow(${JSON.stringify(o)})`);
    const close = (w) => evalApp(`ac.store.getState().closeWindow(${JSON.stringify(w)}); return true`);
    const personalTab = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(home)}, { url: "${base}/cookie?personal" })`);
    await shows(home, "Cookie");
    const steps = [];
    const p1 = await open({ incognito: true, url: `${base}/cookie?private1` });
    await shows(p1, "Cookie");
    if ((await cookie("/cookie?private1")).includes("personal")) throw new Error("a private window sees Personal's cookie");
    await close(p1);
    const p2 = await open({ incognito: true, url: `${base}/b?private2` });
    await shows(p2, "Page B");
    steps.push("private, reopened at once");
    if ((await cookie("/b?private2")).includes("personal")) throw new Error("the reopened private window sees Personal's cookie");
    await evalApp(`const s = ac.store.getState(); s.closeTabs([...s.windows[${JSON.stringify(p2)}].tabIds]); return true`);
    await sleep(2500);
    await evalApp(`ac.store.getState().newTab(${JSON.stringify(p2)}, { url: "${base}/c?private3" }); return true`);
    await shows(p2, "Page C");
    steps.push("private, a tab after its last tab closed");
    await close(p2);
    await sleep(2500);
    const p4 = await open({ incognito: true, url: `${base}/d?private4` });
    await shows(p4, "Page D");
    steps.push("private, reopened later");
    if ((await cookie("/d?private4")).includes("personal")) throw new Error("a later private window sees Personal's cookie");
    let last = p4;
    for (let round = 0; round < 4; round++) {
      const next = await evalApp(`const s = ac.store.getState(); s.closeWindow(${JSON.stringify(last)}); return ac.actions.openWindow({ incognito: true, url: "${base}/e?churn${round}" })`);
      await shows(next, "Page E");
      await sleep(round % 2 ? 200 : 1500);
      await evalApp(`ac.store.getState().newTab(${JSON.stringify(next)}, { url: "${base}/b?churn${round}" }); return true`);
      await shows(next, "Page B");
      last = next;
    }
    steps.push("private, closed and reopened in one turn (4 rounds)");
    await close(last);
    const id = await evalApp(`return ac.store.getState().createProfile({ name: "Spare" })`);
    const w1 = await open({ profileId: id, url: `${base}/cookie?spare` });
    await shows(w1, "Cookie");
    await close(w1);
    const w2 = await open({ profileId: id, url: `${base}/b?spare2` });
    await shows(w2, "Page B");
    steps.push("profile, reopened at once");
    await close(w2);
    await sleep(2500);
    const w3 = await open({ profileId: id, url: `${base}/c?spare3` });
    await shows(w3, "Page C");
    steps.push("profile, reopened later");
    const spare = await cookie("/c?spare3");
    await close(w3);
    await evalApp(`ac.store.getState().closeTab(${JSON.stringify(personalTab)}); return true`);
    if (!spare.includes("spare") || spare.includes("personal")) throw new Error(`the profile's window sees "${spare}"`);
    return { steps, spareCookie: spare };
  });

  await check("window-size", async () => {
    const frame = await evalApp(`return ac.shell.windowFrame(${JSON.stringify(mainWindow)})`);
    if (frame?.[2] !== 1360 || frame?.[3] !== 860) throw new Error(`frame ${JSON.stringify(frame)}`);
    return { frame };
  });

  await check("open-url", async () => {
    await evalApp(`ac.actions.openUrls(["${base}/a"], ${JSON.stringify(mainWindow)}); return true`);
    const s = await until("tab A titled", async () => {
      const s = await state();
      const t = s.tabs.find((t) => t.url?.startsWith(`${base}/a`));
      return t && t.title === "Page A" && !t.loading ? { s, t } : null;
    });
    first = s.t;
    const t = await pageTarget(`${base}/a`);
    if (!t) throw new Error("no CDP target for A");
    if (process.env.SOLARA_TRACE_VISIBILITY) watchVisibility(t);
    return { tab: s.t.id, title: s.t.title, active: s.s.active === s.t.id };
  });

  await check("visibility", async () => {
    const t = await pageFor(first.id, `${base}/a`);
    const vis = (await cdp(t, "Runtime.evaluate", { expression: "document.visibilityState + '/' + document.hasFocus()", returnByValue: true })).result.value;
    const windows = (await evalApp(`return globalThis.expo.modules.SolaraCEF.chromeWindows()`)).map((w) => ({ visible: w.visible, alpha: w.alpha, key: w.key, frame: w.frame }));
    return { page: vis, windows };
  });

  await check("occlusion", async () => {
    const allow = !!process.env.SOLARA_ALLOW_OCCLUSION;
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    const t = await pageFor(first.id, `${base}/a`);
    const vis = async () => (await cdp(t, "Runtime.evaluate", { expression: "document.visibilityState", returnByValue: true })).result.value;
    const browser = await browserOf(first.id);
    const windowNumber = await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindowNumber(${browser})`);
    const chromeSees = async () => (await evalApp(`return globalThis.expo.modules.SolaraCEF.chromeWindows()`)).find((x) => x.window === windowNumber);
    await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindow(${windowNumber}, "cover")`);
    let samples = [], escape = null, w = null;
    try {
      w = await until("macOS to see the window occluded", async () => {
        const x = await chromeSees();
        return x && !x.occlusionVisible && (!allow || x.chromeOccluded) ? x : null;
      }, 10000);
      for (let i = 0; i < 8; i++) {
        samples.push(await vis());
        await sleep(400);
      }
      if (!allow) {
        const s = await state();
        const before = (await eventsOf(first.id)).filter((x) => x.name === "command" && x.payload?.command === "escape").length;
        await evalApp(`return ac.webviews.get("${first.id}").focus()`);
        await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "\u001b", keyCode: 53, modifiers: [], focus: "page" })`);
        escape = await until("Esc while covered", async () =>
          (await eventsOf(first.id)).filter((x) => x.name === "command" && x.payload?.command === "escape").length > before ? true : null, 5000);
      }
    } finally {
      await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindow(${windowNumber}, "uncover")`);
    }
    const back = await until("visible again", async () => ((await vis()) === "visible" ? "visible" : null), 10000);
    const expected = allow ? "hidden" : "visible";
    if (allow ? !samples.slice(4).every((v) => v === "hidden") : !samples.every((v) => v === "visible"))
      throw new Error(`while covered the page was ${JSON.stringify(samples)}, expected ${expected}`);
    return { chromeOccluded: w.chromeOccluded, macOSVisible: w.occlusionVisible, samples, escape, back };
  });

  await check("favicon", async () => {
    const t = await until("a favicon", async () => (await state()).tabs.find((t) => t.id === first?.id && t.favicon));
    return { favicon: String(t.favicon).slice(0, 60) };
  });

  await check("navigate-back-forward-reload", async () => {
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/b", { userInitiated: true }); return true`);
    await until("B", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page B" && t.back));
    await evalApp(`return ac.webviews.get("${first.id}").goBack()`);
    await until("back to A", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && t.fwd));
    await evalApp(`return ac.webviews.get("${first.id}").goForward()`);
    await until("forward to B", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page B"));
    const target = await pageTarget(`${base}/b`);
    await cdp(target, "Runtime.evaluate", { expression: "window.__mark = 1" });
    await evalApp(`return ac.webviews.get("${first.id}").reload()`);
    await until("reloaded", async () => {
      const t = await pageTarget(`${base}/b`);
      const r = t && (await cdp(t, "Runtime.evaluate", { expression: "String(window.__mark)", returnByValue: true }));
      return r?.result?.value === "undefined";
    });
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a", { userInitiated: true }); return true`);
    await until("A again", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading));
    return { ok: true };
  });

  await check("target-blank", async () => {
    const before = (await state()).tabs.length;
    const t = await pageTarget(`${base}/a`);
    await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('blank').click()", userGesture: true });
    const s = await until("a new tab for C", async () => {
      const s = await state();
      const c = s.tabs.find((x) => x.url?.startsWith(`${base}/c`) && x.title === "Page C");
      return s.tabs.length > before && c ? { s, c } : null;
    });
    await sleep(2500);
    const later = (await state()).tabs.find((x) => x.id === s.c.id);
    if (!later) throw new Error("the popup's tab went away");
    return { tabs: s.s.tabs.length, adoptId: s.c.adoptId ?? null, stays: !!later };
  });

  await check("window-open", async () => {
    const t = await pageTarget(`${base}/a`);
    await cdp(t, "Runtime.evaluate", { expression: `window.open("${base}/e", "_blank")`, userGesture: true });
    const e = await until("E in a tab", async () => (await state()).tabs.find((x) => x.url?.startsWith(`${base}/e`) && x.title === "Page E"));
    return { tab: e.id, adoptId: e.adoptId ?? null };
  });

  await check("cmd-click", async () => {
    const activeBefore = (await state()).active;
    const t = await pageTarget(`${base}/a`);
    const r = await cdp(t, "Runtime.evaluate", {
      expression: "JSON.stringify(document.getElementById('cmd').getBoundingClientRect())",
      returnByValue: true,
    });
    const box = JSON.parse(r.result.value);
    const x = box.x + 4, y = box.y + box.height / 2;
    for (const type of ["mousePressed", "mouseReleased"])
      await cdp(t, "Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1, modifiers: 4 });
    const d = await until("D in a background tab", async () => (await state()).tabs.find((x) => x.url?.startsWith(`${base}/d`)));
    const s = await state();
    if (s.active !== activeBefore) throw new Error("the ⌘-clicked tab came to the front");
    return { tab: d.id, adoptId: d.adoptId ?? null, background: true };
  });

  await check("evaluate", async () => {
    const title = await evalApp(`return ac.webviews.get("${first.id}").evaluate("post('result', JSON.stringify(document.title))")`);
    if (title !== "Page A") throw new Error(`evaluate gave ${JSON.stringify(title)}`);
    const script = await evalApp(`return ac.webviews.get("${first.id}").evaluate("post('result', JSON.stringify(typeof window.Notification))")`);
    return { title, notification: script };
  });

  await check("tab-strips", async () => {
    const tx = await evalApp(`return globalThis.expo.modules.SolaraCEF.tabStrips()`);
    const s = await state();
    const strip = tx.strips.find((x) => x.tabs.some((t) => t.key === first.id));
    if (!strip) throw new Error(`no strip names ${first.id}: ${JSON.stringify(tx)}`);
    const keys = strip.tabs.map((t) => t.key);
    const missing = s.tabs.filter((t) => t.url && !keys.includes(t.id)).map((t) => t.id);
    if (missing.length) throw new Error(`tabs missing from the strip: ${missing}`);
    return { rev: tx.rev, strips: tx.strips.length, tabs: keys.length, active: strip.tabs.find((t) => t.active)?.key };
  });

  await check("tab-switch", async () => {
    const s = await state();
    const other = s.tabs.find((x) => x.id !== first.id && x.url);
    await evalApp(`ac.actions.switchToTab("${other.id}"); return true`);
    await until("switched", async () => (await state()).active === other.id);
    const back = await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("switched back", async () => (await state()).active === first.id);
    return { to: other.id, back };
  });

  await check("cmd-t-cmd-w", async () => {
    const s = await state();
    const before = s.tabs.length;
    const t = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "t", keyCode: 17, modifiers: ["command"], focus: "page" })`);
    log("  ⌘T:", JSON.stringify(t));
    const afterT = await until("a new tab (⌘T)", async () => {
      const n = await state();
      return n.tabs.length > before || n.active !== s.active ? n : null;
    });
    const w = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "w", keyCode: 13, modifiers: ["command"], focus: "window" })`);
    await sleep(800);
    const afterW = await state();
    return { t, w, tabs: [before, afterT.tabs.length, afterW.tabs.length] };
  });

  await check("cmd-l-from-page", async () => {
    const s = await state();
    const r = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "l", keyCode: 37, modifiers: ["command"], focus: "page" })`);
    if (!r.fired?.some((f) => f.command === "focusCommandBar")) throw new Error(`⌘L didn't reach the menu: ${JSON.stringify(r)}`);
    return { handledBy: r.handledBy, fired: r.fired.map((f) => f.command) };
  });

  await check("tab-keys-from-page", async () => {
    const s = await state();
    const ctrlTab = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "\t", keyCode: 48, modifiers: ["control"], focus: "page" })`);
    if (!ctrlTab.fired?.some((f) => f.command === "tabSwitcher")) throw new Error(`⌃Tab: ${JSON.stringify(ctrlTab)}`);
    await evalApp(`ac.switcher.cancelSwitcher(); return true`);
    const next = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "}", keyCode: 30, modifiers: ["command", "shift"], focus: "page" })`);
    const after = await until("the next tab", async () => {
      const n = await state();
      return n.active !== s.active ? n : null;
    }, 5000);
    return { ctrlTab: ctrlTab.fired.map((f) => f.command), next: (next.fired ?? []).map((f) => f.command), from: s.active, to: after.active };
  });

  await check("window-close", async () => {
    const e = (await state()).tabs.find((x) => x.url?.startsWith(`${base}/e`));
    if (!e) throw new Error("no window.open tab to close");
    const t = await pageTarget(`${base}/e`);
    await closeFromPage(t);
    await until("the tab gone from the store", async () => !(await state()).tabs.some((x) => x.id === e.id));
    return { closed: e.id };
  });


  // MARK: Page UI

  await check("status-text", async () => {
    const t = await pageFor(first.id, `${base}/a`);
    const r = await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('next').getBoundingClientRect())", returnByValue: true });
    const box = JSON.parse(r.result.value);
    await cdp(t, "Input.dispatchMouseEvent", { type: "mouseMoved", x: box.x + 3, y: box.y + box.height / 2 });
    const status = await until("a status", async () => (await evalApp(`return ac.pageState.getState().pages["${first.id}"]?.status ?? ""`)) || null, 8000);
    return { status };
  });

  await check("load-error", async () => {
    await evalApp(`ac.store.getState().navigate("${first.id}", "http://127.0.0.1:9/nothing", { userInitiated: true }); return true`);
    const e = await until("onLoadError", async () => (await eventsOf(first.id)).find((x) => x.name === "loadError"), 10000);
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a", { userInitiated: true }); return true`);
    await until("A again", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading));
    return { loadError: e.payload };
  });

  await check("chrome-strings", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    await evalApp(`ac.store.getState().navigate("${first.id}", "chrome://version", { userInitiated: true }); return true`);
    await until("chrome://version", async () => (await state()).tabs.find((t) => t.id === first.id && /^(chrome|solara|solara):\/\/version/.test(t.url ?? "") && t.title === "About Version"), 20000);
    try {
      const t = await pageFor(first.id, "chrome://version");
      const text = (await cdp(t, "Runtime.evaluate", { expression: "document.body?.innerText ?? ''", returnByValue: true })).result?.value ?? "";
      const product = text.split("\n").find((l) => /^\w+\t\d+\.\d+\./.test(l) && !/^CEF/.test(l));
      const credit = text.match(/Copyright \d+ The Chromium Authors/)?.[0];
      if (!/^(Solara|Solara)\t/.test(product ?? "") || !credit) throw new Error(`version page: ${product} / ${credit}`);
      return { product, credit };
    } finally {
      await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a", { userInitiated: true }); return true`);
      await until("A again", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading));
    }
  });

  await check("context-menu-search", async () => {
    await evalApp(`return globalThis.expo.modules.SolaraCEF.setSearchEngineName("Acceptance").then(() => true)`);
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    await sleep(300);
    let t = await pageFor(first.id, `${base}/a`);
    const rightClick = async () => {
    const r = await cdp(t, "Runtime.evaluate", {
      expression: `(() => { const el = document.getElementById('next'); const range = document.createRange(); range.selectNodeContents(el);
        getSelection().removeAllRanges(); getSelection().addRange(range); return JSON.stringify(el.getBoundingClientRect()); })()`,
      returnByValue: true,
    });
    const box = JSON.parse(r.result.value);
    const at = { x: box.x + 3, y: box.y + box.height / 2, button: "right", clickCount: 1 };
    let e = null;
    for (let attempt = 0; attempt < 3 && !e; attempt++) {
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at });
      e = await until("a context menu", async () => (await eventsOf(first.id)).findLast((x) => x.name === "contextMenu"), 4000).catch(() => null);
    }
    return e;
    };
    let e = await rightClick();
    if (!e) {
      log("  context menu: none after 3 right-clicks; reloading the page and trying again");
      await evalApp(`return ac.webviews.get("${first.id}").reload()`);
      await sleep(1500);
      t = await pageFor(first.id, `${base}/a`);
      e = await rightClick();
    }
    if (!e) {
      const vis = (await cdp(t, "Runtime.evaluate", { expression: "document.visibilityState + '/' + document.hasFocus()", returnByValue: true })).result.value;
      throw new Error(`no context menu reported (page ${vis}); events: ${JSON.stringify((await eventsOf(first.id)).slice(-6).map((x) => x.name))}`);
    }
    const selection = !!(await eventsOf(first.id)).findLast((x) => x.name === "pageMessage" && x.payload?.kind === "selection");
    const labels = e.payload.items.filter((i) => !i.separator).map((i) => i.label);
    const search = labels.filter((l) => /^Search .* for /.test(l));
    if (!search.some((l) => l.startsWith("Search Acceptance for “to B”"))) throw new Error(`no app search item: ${JSON.stringify(labels)}`);
    await cdp(t, "Runtime.evaluate", { expression: "getSelection().removeAllRanges()" });
    return { items: labels.length, search, selectionMessage: selection };
  });

  await check("context-menu-activation-log", async () => {
    const line = await until("the activation.log line", async () =>
      (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8") : "").split("\n").findLast((l) => l.includes("context menu (not shown): ")), 5000);
    if (!line.includes("Search Acceptance for “to B”")) throw new Error(`activation.log: ${line}`);
    return { line: line.slice(line.indexOf("context menu")) };
  });

  await check("duplicate-and-reopen", async () => {
    const copyId = await evalApp(`const c = ac.store.getState().duplicateTab("${first.id}"); return typeof c === "string" ? c : c?.id ?? null`);
    if (!copyId) throw new Error("no copy");
    await until("the copy on A with history", async () => (await state()).tabs.find((t) => t.id === copyId && t.title === "Page A" && t.back && !t.loading), 15000);
    await evalApp(`ac.store.getState().closeTab("${copyId}"); return true`);
    await until("the copy closed", async () => !(await state()).tabs.some((t) => t.id === copyId));
    await sleep(500);
    const before = new Set((await state()).tabs.map((t) => t.id));
    await evalApp(`ac.store.getState().reopenClosedTab(${JSON.stringify(mainWindow)}); return true`);
    const back = await until("the reopened tab with history", async () => {
      const s = await state();
      return s.tabs.find((t) => !before.has(t.id) && t.title === "Page A" && t.back && !t.loading);
    }, 15000);
    await evalApp(`ac.store.getState().closeTab("${back.id}"); return true`);
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("first tab active", async () => (await state()).active === first.id);
    return { copy: copyId, reopened: back.id };
  });

  // MARK: Choosers and Cast

  await check("device-chooser", async () => {
    const t = await pageFor(first.id, `${base}/a`);
    await cdp(t, "Runtime.evaluate", {
      expression: "window.__usb = 'pending'; navigator.usb.requestDevice({ filters: [] }).then(() => (window.__usb = 'picked'), (e) => (window.__usb = e.name))",
      userGesture: true,
    });
    const chooser = await until("the app's chooser", async () => {
      const c = await evalApp(`return globalThis.acDeviceChoosers?.useChoosers.getState().byTab["${first.id}"] ?? null`);
      if (c) return c;
      const r = await cdp(t, "Runtime.evaluate", { expression: "String(window.__usb)", returnByValue: true });
      if (r.result.value !== "pending") throw new Error(`no chooser; the page got ${r.result.value}`);
      return null;
    }, 10000);
    await evalApp(`return globalThis.acDeviceChoosers.cancelDeviceChooser(${chooser.id}).then(() => true)`);
    const result = await until("the page's answer", async () => {
      const r = await cdp(t, "Runtime.evaluate", { expression: "window.__usb", returnByValue: true });
      return r.result.value !== "pending" ? r.result.value : null;
    }, 8000);
    await until("the sheet gone", async () => !(await evalApp(`return globalThis.acDeviceChoosers.useChoosers.getState().byTab["${first.id}"] ?? null`)), 5000);
    if (result !== "NotFoundError") throw new Error(`page got ${result}`);
    return { chooser: { id: chooser.id, title: chooser.title, options: chooser.options?.length }, page: result };
  });

  const chromeUI = (call) => evalApp(`return globalThis.expo.modules.SolaraChromeUI.${call}`);
  const chooserOf = (tabId) => evalApp(`return globalThis.acDeviceChoosers?.useChoosers.getState().byTab["${tabId}"] ?? null`);
  const bluetoothChooser = async (unauthorized) => {
    if (!(await chromeUI(`devShowBluetoothChooser(${await browserOf(first.id)}, ${unauthorized})`))) throw new Error("devShowBluetoothChooser said no (switch off?)");
    return until("the app's Bluetooth chooser", async () => {
      const c = await chooserOf(first.id);
      return c && (unauthorized ? c.unauthorized : c.options?.length) ? c : null;
    }, 10000);
  };
  const chooserEvents = () => chromeUI(`devChooserEvents()`);
  const chooserGone = () => until("the sheet gone", async () => !(await chooserOf(first.id)), 5000);

  await check("bluetooth-chooser", async () => {
    await evalApp(`globalThis.__acChooser = []; globalThis.__acChooserSub?.remove();
      globalThis.__acChooserSub = globalThis.expo.modules.SolaraChromeUI.addListener("onDeviceChooser", (e) => globalThis.__acChooser.push(e)); return true`);
    try {
      const before = (await chooserEvents()).length;
      const chooser = await bluetoothChooser(false);
      const sent = (await evalApp(`return globalThis.__acChooser`)).length;
      await chromeUI(`refreshDeviceChooser(${chooser.id}).then(() => true)`);
      const rescan = await until("Chrome's rescan", async () => (await chooserEvents()).slice(before).find((e) => e.event === "rescan") ?? null, 5000);
      const refreshed = await until("the list sent again", async () => {
        const list = await evalApp(`return globalThis.__acChooser`);
        return list.slice(sent).find((c) => c.open && c.options?.length && !c.refreshing) ?? null;
      }, 5000);
      await chromeUI(`selectDevice(${chooser.id}, 0).then(() => true)`);
      const selected = await until("the pick answered", async () => (await chooserEvents()).slice(before).find((e) => e.event === "selected") ?? null, 5000);
      await chooserGone();
      if (selected.device !== "ac-test-device") throw new Error(`picked ${selected.device}`);
      return { title: chooser.title, options: refreshed.options.map((o) => o.name), rescan: !!rescan, selected: selected.device };
    } finally {
      await evalApp(`globalThis.__acChooserSub?.remove(); return true`).catch(() => null);
      const c = await chooserOf(first.id).catch(() => null);
      if (c) await chromeUI(`cancelDeviceChooser(${c.id}).then(() => true)`).catch(() => null);
    }
  });

  await check("bluetooth-settings", async () => {
    const launches = () => evalApp(`return globalThis.expo.modules.SolaraCEF.devExternalLaunches()`);
    const isSettings = (x) => /Privacy_Bluetooth/.test(x.url ?? "");
    const t = await pageFor(first.id, `${base}/a`);
    try {
      const before = (await launches()).filter(isSettings).length;
      const events = (await chooserEvents()).length;
      const bt = await bluetoothChooser(true);
      await chromeUI(`openBluetoothSettings(${bt.id}).then(() => true)`);
      const recorded = await until("the Bluetooth settings pane recorded", async () => {
        const list = (await launches()).filter(isSettings);
        return list.length > before ? list.at(-1) : null;
      }, 5000);
      if ((await chooserOf(first.id))?.id !== bt.id) throw new Error("the chooser closed on openBluetoothSettings");
      await chromeUI(`cancelDeviceChooser(${bt.id}).then(() => true)`);
      await chooserGone();
      const cancelled = await until("the cancel answered", async () => (await chooserEvents()).slice(events).find((e) => e.event === "cancelled") ?? null, 5000);
      await cdp(t, "Runtime.evaluate", {
        expression: "window.__usb = 'pending'; navigator.usb.requestDevice({ filters: [] }).then(() => (window.__usb = 'picked'), (e) => (window.__usb = e.name))",
        userGesture: true,
      });
      const usb = await until("the WebUSB chooser", () => chooserOf(first.id), 10000);
      await chromeUI(`openBluetoothSettings(${usb.id}).then(() => true)`);
      await sleep(500);
      const after = (await launches()).filter(isSettings).length;
      if (after !== before + 1) throw new Error(`the WebUSB chooser recorded ${after - before - 1} settings pane(s)`);
      if ((await chooserOf(first.id))?.id !== usb.id) throw new Error("the WebUSB chooser closed on openBluetoothSettings");
      await chromeUI(`cancelDeviceChooser(${usb.id}).then(() => true)`);
      await chooserGone();
      return { unauthorized: bt.unauthorized, recorded: recorded.url, cancelled: !!cancelled, webUSB: "ignored" };
    } finally {
      const c = await chooserOf(first.id).catch(() => null);
      if (c) await chromeUI(`cancelDeviceChooser(${c.id}).then(() => true)`).catch(() => null);
    }
  });

  await check("cast-dialog", async () => {
    const browser = await browserOf(first.id);
    const shown = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.showCastDialog(${browser})`);
    if (!shown) throw new Error("showCastDialog said no (media router off?)");
    const dialog = await until("the app's Cast dialog", async () => evalApp(`return globalThis.acCast?.useCast.getState().dialogs["${first.id}"] ?? null`), 10000);
    const routes = await evalApp(`return globalThis.acCast.useCast.getState().routes`);
    await evalApp(`return globalThis.expo.modules.SolaraChromeUI.closeCastDialog(${dialog.id}).then(() => true)`);
    await until("the dialog closed", async () => !(await evalApp(`return globalThis.acCast.useCast.getState().dialogs["${first.id}"] ?? null`)), 5000);
    return { header: dialog.header, sinks: dialog.sinks?.length ?? 0, routeProfiles: Object.keys(routes ?? {}) };
  });

  await check("cast-routes", async () => {
    const browser = await browserOf(first.id);
    const routesNow = () => evalApp(`return Object.values(globalThis.acCast.useCast.getState().routes).flat()`);
    const dialogNow = () => evalApp(`return globalThis.acCast.useCast.getState().dialogs["${first.id}"] ?? null`);
    const openDialog = async () => {
      if (!(await evalApp(`return globalThis.expo.modules.SolaraChromeUI.showCastDialog(${browser})`))) throw new Error("showCastDialog said no");
      return until("the test sink in the app's dialog", async () => {
        const d = await dialogNow();
        const sink = d?.sinks?.find((s) => s.name === "Solara Test Sink" && s.state === "available");
        return sink ? { dialog: d, sink } : null;
      }, 10000).catch(async (e) => { throw new Error(`${e.message}; dialog ${JSON.stringify(await dialogNow())}`); });
    };
    const casting = async (dialogId, sink) => {
      await evalApp(`return globalThis.expo.modules.SolaraChromeUI.startCasting(${dialogId}, ${JSON.stringify(sink.id)}, 2).then(() => true)`);
      return until("the route in onCastRoutes", async () => (await routesNow()).find((r) => r.sink === sink.id) ?? null, 10000);
    };
    try {
      const { dialog, sink } = await openDialog();
      if (!(sink.modes & 2)) throw new Error(`the test sink can't cast a tab (modes ${sink.modes})`);
      const route = await casting(dialog.id, sink);
      const connected = await until("the sink connected in the dialog", async () => {
        const d = await dialogNow();
        const s = d?.sinks?.find((x) => x.id === sink.id);
        return s?.routeId === route.id && s.state === "connected" ? { dialog: d, sink: s } : null;
      }, 10000);
      await evalApp(`return globalThis.expo.modules.SolaraChromeUI.stopCasting(${dialog.id}, ${JSON.stringify(route.id)}).then(() => true)`);
      await until("the route gone after stopCasting", async () => !(await routesNow()).some((r) => r.id === route.id), 10000);
      const second = await casting(dialog.id, sink);
      await evalApp(`return globalThis.expo.modules.SolaraChromeUI.closeCastDialog(${dialog.id}).then(() => true)`);
      await until("the dialog closed", async () => !(await dialogNow()), 5000);
      if (!(await routesNow()).some((r) => r.id === second.id)) throw new Error("closing the dialog ended the route");
      await evalApp(`return globalThis.expo.modules.SolaraChromeUI.terminateCastRoute(${JSON.stringify(second.id)}).then(() => true)`);
      await until("the route gone after terminateCastRoute", async () => !(await routesNow()).some((r) => r.id === second.id), 10000);
      return {
        sink: { name: sink.name, modes: sink.modes },
        started: { route: route.description, source: route.source, castingStarted: connected.dialog.castingStarted, state: connected.sink.state },
        stopped: true,
        terminated: true,
      };
    } finally {
      const d = await dialogNow().catch(() => null);
      if (d) await evalApp(`return globalThis.expo.modules.SolaraChromeUI.closeCastDialog(${d.id}).then(() => true)`).catch(() => null);
      for (const r of await routesNow().catch(() => []))
        await evalApp(`return globalThis.expo.modules.SolaraChromeUI.terminateCastRoute(${JSON.stringify(r.id)}).then(() => true)`).catch(() => null);
    }
  });

  // MARK: Page state and prompts

  await check("theme-commit", async () => {
    const tab = await openTab(`${base}/red-header?commit`, "Red header");
    const color = () => evalApp(`return ac.store.getState().live["${tab.id}"]?.themeColor ?? null`);
    const settled = (title) => until(title, async () => (await state()).tabs.find((t) => t.id === tab.id && t.title === title && !t.loading));
    try {
      await until("the red header's colour", async () => (await color()) === "#C80000", 5000);
      const failed = "http://127.0.0.1:9/theme-commit";
      await evalApp(`ac.store.getState().navigate("${tab.id}", "${failed}", { userInitiated: true }); return true`);
      await until("the error page", async () => (await state()).tabs.find((t) => t.id === tab.id && t.url === failed && !t.loading), 10000);
      await sleep(100);
      const error = await color();

      await evalApp(`ac.store.getState().navigate("${tab.id}", "${base}/red-header?bf", { userInitiated: true }); return true`);
      await settled("Red header");
      await until("red again", async () => (await color()) === "#C80000", 5000);
      const red = await pageFor(tab.id, "/red-header?bf");
      await cdp(red, "Runtime.evaluate", { expression: "window.__bf = 1" });
      await evalApp(`ac.store.getState().navigate("${tab.id}", "${base}/c?bf", { userInitiated: true }); return true`);
      await settled("Page C");
      await until("Page C's colour", async () => (await color()) === "#FFFFFF", 5000);
      await evalApp(`return ac.webviews.get("${tab.id}").goBack()`);
      await settled("Red header");
      const back = await pageFor(tab.id, "/red-header?bf");
      const cached = (await cdp(back, "Runtime.evaluate", { expression: "String(window.__bf)", returnByValue: true })).result.value === "1";
      if (!cached) throw new Error("Back didn't restore the page from the back/forward cache");
      const restored = await until("the restored page's colour", async () => ((await color()) === "#C80000" ? "#C80000" : null), 2000).catch(color);
      if (error === "#C80000" || restored !== "#C80000") throw new Error(`the error page shows ${error}, the page back from the cache ${restored}`);
      return { error, restored };
    } finally {
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("theme-modern-colors", async () => {
    const seen = {};
    for (const [path, title, want] of [["/mixed-header", "Mixed header", [231, 231, 232]], ["/oklch-painted", "Oklch painted", [46, 46, 46]], ["/clear-mixed-header", "Clear mixed header", [18, 52, 86]], ["/alpha-header", "Alpha header", [255, 102, 102]]]) {
      const tab = await openTab(`${base}${path}`, title);
      try {
        const color = () => evalApp(`return ac.store.getState().live["${tab.id}"]?.themeColor ?? null`);
        const near = (c) => !!c && want.every((v, i) => Math.abs(parseInt(c.slice(1 + 2 * i, 3 + 2 * i), 16) - v) <= 2);
        seen[path] = await until(`${title}'s colour`, async () => ((c) => (near(c) ? c : null))(await color()), 5000).catch(color);
        if (!near(seen[path])) throw new Error(`${title} reports ${seen[path]}, not about rgb(${want.join(", ")}): ${JSON.stringify(seen)}`);
      } finally {
        await closeTab(tab.id);
      }
    }
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    return seen;
  });

  await check("user-selection", async () => {
    const searchBefore = await evalApp(`return ac.store.getState().settings.showSelectionSearch === true`);
    await evalApp(`ac.store.getState().updateSettings({ showSelectionSearch: true }); return true`);
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/text", { userInitiated: true }); return true`);
    await until("the text page", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Text" && !t.loading));
    try {
      const t = await pageFor(first.id, `${base}/text`);
      const r = await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('t').getBoundingClientRect())", returnByValue: true });
      const box = JSON.parse(r.result.value);
      const y = box.y + box.height / 2;
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", x: box.x + 2, y, button: "left", buttons: 1, clickCount: 1 });
      for (let k = 1; k <= 8; k++)
        await cdp(t, "Input.dispatchMouseEvent", { type: "mouseMoved", x: box.x + 2 + ((box.width - 10) * k) / 8, y, button: "left", buttons: 1 });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", x: box.x + box.width - 8, y, button: "left", buttons: 0, clickCount: 1 });
      const e = await until("onPageMessage selection", async () =>
        (await eventsOf(first.id)).findLast((x) => x.name === "pageMessage" && x.payload?.kind === "selection" && x.payload?.data), 6000);
      return { text: String(JSON.stringify(e.payload.data)).slice(0, 80) };
    } finally {
      await evalApp(`ac.store.getState().updateSettings({ showSelectionSearch: ${searchBefore} }); return true`).catch(() => null);
      await backToA();
    }
  });

  await check("password-prompt", async () => {
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/login", { userInitiated: true }); return true`);
    await until("the login page", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Login" && !t.loading));
    const typedIn = [];
    try {
      const t = await pageFor(first.id, `${base}/login`);
      typedIn.push(t);
      for (const [field, text] of [["u", "nnformuser"], ["p", "form-s3cret"]]) {
        await cdp(t, "Runtime.evaluate", { expression: `document.getElementById('${field}').focus()` });
        await cdp(t, "Input.insertText", { text });
      }
      const r = await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('go').getBoundingClientRect())", returnByValue: true });
      const box = JSON.parse(r.result.value);
      const at = { x: box.x + box.width / 2, y: box.y + box.height / 2, button: "left", clickCount: 1 };
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at, buttons: 1 });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at, buttons: 0 });
      const e = await until("onPasswordPrompt", async () => (await eventsOf(first.id)).findLast((x) => x.name === "passwordPrompt"), 10000);
      const p = e.payload;
      if (p.state !== "save" || p.username !== "nnformuser" || p.passwordLength !== 11 || p.federation !== "" || !Array.isArray(p.usernames) || p.origin !== base)
        throw new Error(`prompt ${JSON.stringify(p)}`);
      await evalApp(`return ac.webviews.get("${first.id}").resolvePasswordPrompt("save")`);
      const saved = await until("the saved login", async () => {
        const list = await evalApp(`return globalThis.expo.modules.SolaraCEF.listPasswords("")`);
        return list.passwords?.find((x) => x.username === "nnformuser") ?? null;
      }, 10000);
      const seen = (await eventsOf(first.id)).filter((x) => x.name === "passwordPrompt").length;
      await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/login?again", { userInitiated: true }); return true`);
      await until("the login page again", async () => (await state()).tabs.find((t) => t.id === first.id && t.url?.endsWith("/login?again") && !t.loading));
      const t2 = await pageFor(first.id, `${base}/login?again`);
      typedIn.push(t2);
      await cdp(t2, "Runtime.evaluate", { expression: "document.getElementById('u').value = ''; document.getElementById('p').value = ''" });
      for (const [field, text] of [["u", "nnformuser"], ["p", "form-s3cret-2"]]) {
        await cdp(t2, "Runtime.evaluate", { expression: `document.getElementById('${field}').focus()` });
        await cdp(t2, "Input.insertText", { text });
      }
      const r2 = await cdp(t2, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('go').getBoundingClientRect())", returnByValue: true });
      const box2 = JSON.parse(r2.result.value);
      const at2 = { x: box2.x + box2.width / 2, y: box2.y + box2.height / 2, button: "left", clickCount: 1 };
      await cdp(t2, "Input.dispatchMouseEvent", { type: "mousePressed", ...at2, buttons: 1 });
      await cdp(t2, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at2, buttons: 0 });
      const u = await until("the update prompt", async () => (await eventsOf(first.id)).filter((x) => x.name === "passwordPrompt")[seen], 10000);
      if (u.payload.state !== "update" || !u.payload.usernames.includes("nnformuser") || u.payload.passwordLength !== 13)
        throw new Error(`update prompt ${JSON.stringify(u.payload)}`);
      await evalApp(`return ac.webviews.get("${first.id}").resolvePasswordPrompt("update", { password: "edited-s3cret" })`);
      const edited = await until("the edited password", async () => {
        const r = await cef(`getPassword("", ${JSON.stringify(saved.origin)}, "nnformuser")`);
        return r?.password === "edited-s3cret" ? r : null;
      }, 10000);
      await evalApp(`return globalThis.expo.modules.SolaraCEF.deletePassword("", ${JSON.stringify(saved.origin)}, "nnformuser")`);
      return { prompt: { state: p.state, passwordLength: p.passwordLength, usernames: p.usernames }, update: u.payload.state, edited: !!edited, origin: saved.origin };
    } finally {
      for (const target of typedIn) await cdp(target, "Runtime.evaluate", { expression: "document.activeElement?.blur()" }).catch(() => {});
      await backToA();
    }
  });

  // MARK: Screen and tab capture

  await check("screen-share-picker", async () => {
    const target = await openTab(`${base}/capture-target?picker`, "Capture Target", true);
    const t = await pageFor(first.id, `${base}/a`);
    try {
      await evalApp(`return globalThis.expo.modules.SolaraCEF.setDisplayMediaPicker(true).then(() => true)`);
      await evalApp(`return ac.webviews.get("${first.id}").reload()`);
      await until("A loaded", async () => (await state()).tabs.find((x) => x.id === first.id && x.title === "Page A" && !x.loading), 10000);
      await sleep(500);
      const page = await pageFor(first.id, `${base}/a`);
      await cdp(page, "Runtime.evaluate", {
        expression: "window.__cap = 'pending'; navigator.mediaDevices.getDisplayMedia({ video: true }).then((s) => { window.__stream = s; window.__cap = 'live'; }, (e) => (window.__cap = e.name)); true",
        userGesture: true,
      });
      const request = await until("onDisplayMediaRequest", async () => (await eventsOf(first.id)).findLast((x) => x.name === "displayMediaRequest"), 10000);
      const sourceId = await evalApp(`return ac.webviews.get("${target.id}").mediaCaptureSourceId()`);
      if (!sourceId) throw new Error("no capture source id for the target tab");
      await evalApp(`globalThis.acSharePicker.answerDisplayMedia("${first.id}", ${JSON.stringify(sourceId)}); return true`);
      const live = await until("a live capture", async () => {
        const v = (await cdp(page, "Runtime.evaluate", { expression: "window.__cap", returnByValue: true })).result.value;
        if (v !== "pending" && v !== "live") throw new Error(`getDisplayMedia: ${v}`);
        return v === "live" ? v : null;
      }, 15000);
      await cdp(page, "Runtime.evaluate", { expression: "window.__stream?.getTracks().forEach((x) => x.stop()); true" });
      return { sources: Array.isArray(request.payload.sources) ? request.payload.sources.length : request.payload.sources, sourceId: String(sourceId).slice(0, 40), live };
    } finally {
      await closeTab(target.id);
    }
  });

  await check("tab-capture", async () => {
    const target = await openTab(`${base}/capture-target`, "Capture Target", true);
    const other = await openTab(`${base}/d?share-instead`, "Page D", true);
    await evalApp(`return globalThis.expo.modules.SolaraCEF.setDisplayMediaPicker(false).then(() => true)`);
    await evalApp(`return ac.webviews.get("${first.id}").reload()`);
    await until("A loaded", async () => (await state()).tabs.find((x) => x.id === first.id && x.title === "Page A" && !x.loading), 10000);
    await sleep(500);
    const t = await pageFor(first.id, `${base}/a`);
    try {
      await cdp(t, "Runtime.evaluate", {
        expression: "window.__cap = 'pending'; navigator.mediaDevices.getDisplayMedia({ video: true }).then((s) => { window.__stream = s; s.getVideoTracks()[0].onended = () => (window.__cap = 'ended'); window.__cap = 'live'; }, (e) => (window.__cap = e.name)); true",
        userGesture: true,
      });
      const live = await until("a live capture", async () => {
        const v = (await cdp(t, "Runtime.evaluate", { expression: "window.__cap", returnByValue: true })).result.value;
        if (v !== "pending" && v !== "live") throw new Error(`getDisplayMedia: ${v}`);
        return v === "live" ? v : null;
      }, 15000);
      const access = await until("onMediaAccess", async () => {
        for (const id of [first.id, target.id]) {
          const e = (await eventsOf(id)).findLast((x) => x.name === "mediaAccess");
          if (e) return { tab: id === first.id ? "capturer" : "captured", access: e.payload };
        }
        return null;
      }, 8000);
      const sourceId = await evalApp(`return ac.webviews.get("${target.id}")?.mediaCaptureSourceId() ?? null`);
      const capturer = await browserOf(first.id);
      const instead = await browserOf(other.id);
      const changed = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.changeCaptureSource(${capturer}, ${instead})`);
      if (changed !== true) throw new Error(`changeCaptureSource answered ${changed} (Chrome's last-used profile: ${(await cef(`engineInfo()`)).lastUsedProfile})`);
      await sleep(1000);
      const stopped = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.stopCapture(${capturer})`);
      const ended = await until("the track ended", async () =>
        (await cdp(t, "Runtime.evaluate", { expression: "window.__cap", returnByValue: true })).result.value === "ended" ? true : null, 8000);
      const windowNumber = await cef(`devWindowNumber(${capturer})`);
      const picker = await until("the picker closed", async () => {
        const children = JSON.parse(await cef(`devWindow(${windowNumber}, "children")`));
        return children.some((c) => c.visible && c.title.startsWith("Choose what to share")) ? null : "closed";
      }, 5000);
      return { live, access, sourceId: sourceId ? String(sourceId).slice(0, 40) : null, changed, stopped, ended, picker };
    } finally {
      await cdp(t, "Runtime.evaluate", { expression: "window.__stream?.getTracks().forEach((x) => x.stop())" }).catch(() => null);
      await evalApp(`return globalThis.expo.modules.SolaraCEF.setDisplayMediaPicker(true).then(() => true)`);
      await closeTab(target.id);
      await closeTab(other.id);
      await evalApp(`return ac.webviews.get("${first.id}").reload()`);
      await until("A loaded", async () => (await state()).tabs.find((x) => x.id === first.id && x.title === "Page A" && !x.loading), 10000);
    }
  });

  await check("share-instead-two-captures", async () => {
    const opened = [];
    const pages = {};
    try {
      await evalApp(`return globalThis.expo.modules.SolaraCEF.setDisplayMediaPicker(true).then(() => true)`);
      for (const [c, t] of [["ff0000", "Red"], ["00ff00", "Green"], ["0000ff", "Blue"]]) opened.push(await openTab(`${base}/solid?c=${c}&t=${t}`, t, true));
      for (const t of ["CallA", "CallB"]) opened.push(await openTab(`${base}/capturer?t=${t}`, t, true));
      const [red, green, blue, callA, callB] = opened;
      const hooks = await evalApp(`return { picker: !!globalThis.acSharePicker?.shareTab, bar: !!globalThis.acShareBar }`);
      const share = async (call, target) => {
        await evalApp(`ac.actions.switchToTab("${call.id}"); return true`);
        await until(`${call.title} shown`, async () => (await state()).active === call.id);
        const page = await pageFor(call.id, `/capturer?t=${call.title}`);
        await cdp(page, "Runtime.evaluate", { expression: "share()", userGesture: true });
        await until(`${call.title}'s picker`, async () => (await eventsOf(call.id)).findLast((x) => x.name === "displayMediaRequest"), 10000);
        if (hooks.picker) await evalApp(`return globalThis.acSharePicker.shareTab("${call.id}", "${target.id}")`);
        else {
          const source = await evalApp(`return ac.webviews.get("${target.id}").mediaCaptureSourceId()`);
          await evalApp(`globalThis.acSharePicker.answerDisplayMedia("${call.id}", ${JSON.stringify(source)}); return true`);
        }
        await until(`${call.title} live`, async () => {
          const v = (await cdp(page, "Runtime.evaluate", { expression: "window.__cap", returnByValue: true })).result.value;
          if (v !== "pending" && v !== "live") throw new Error(`${call.title} getDisplayMedia: ${v}`);
          return v === "live" ? v : null;
        }, 15000);
        return page;
      };
      pages.A = await share(callA, red);
      pages.B = await share(callB, green);
      const colour = async (page) => {
        const p = (await cdp(page, "Runtime.evaluate", { expression: "pixel()", awaitPromise: true, returnByValue: true })).result.value;
        const i = p.indexOf(Math.max(...p));
        return p[i] > 150 && p.filter((x) => x > 100).length === 1 ? ["red", "green", "blue"][i] : `rgb(${p})`;
      };
      const both = async () => ({ A: await colour(pages.A), B: await colour(pages.B) });
      const before = await until("red and green", async () => {
        const c = await both();
        return c.A === "red" && c.B === "green" ? c : null;
      }, 10000);
      const recorded = hooks.bar && (await evalApp(`const s = globalThis.acShareBar.tabShares(); return [s["${callA.id}"]?.capturedTabId === "${red.id}", s["${callB.id}"]?.capturedTabId === "${green.id}"]`));
      if (hooks.bar && !(recorded[0] && recorded[1])) throw new Error(`app records before: ${JSON.stringify(recorded)}`);
      await evalApp(`ac.actions.switchToTab("${blue.id}"); return true`);
      await until("blue shown", async () => (await state()).active === blue.id);
      const changed = hooks.bar
        ? await evalApp(`return globalThis.acShareBar.shareInstead("${callB.id}", "${blue.id}")`)
        : await evalApp(`return globalThis.expo.modules.SolaraChromeUI.changeCaptureSource(${await browserOf(callB.id)}, ${await browserOf(blue.id)})`);
      if (changed !== true) throw new Error(`share instead answered ${JSON.stringify(changed)}`);
      let after = null;
      try {
        after = await until("B on blue", async () => {
          const c = await both();
          return c.B === "blue" ? c : null;
        }, 8000);
      } catch {
        after = await both();
      }
      await sleep(1000);
      const settled = await both();
      if (settled.A !== "red" || settled.B !== "blue") throw new Error(`after B's share instead: A ${settled.A} (want red), B ${settled.B} (want blue)`);
      let records = null;
      if (hooks.bar) {
        await sleep(2000);
        records = await evalApp(`const s = globalThis.acShareBar.tabShares(); return { A: s["${callA.id}"]?.capturedTabId ?? null, B: s["${callB.id}"]?.capturedTabId ?? null }`);
        if (records.A !== red.id || records.B !== blue.id) throw new Error(`app records ${JSON.stringify(records)} (want A ${red.id}, B ${blue.id})`);
      }
      return { before, after: settled, changed, records: records && { A: "red", B: "blue" } };
    } finally {
      for (const page of Object.values(pages)) await cdp(page, "Runtime.evaluate", { expression: "window.__stream?.getTracks().forEach((x) => x.stop()); true" }).catch(() => null);
      for (const t of opened) await closeTab(t.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  // MARK: Tab lifecycle

  await check("share-bar-layout", async () => {
    const shell = await evalApp(`return !!globalThis.expo.modules.SolaraWindowShell?.active(${JSON.stringify(mainWindow)})`);
    if (!shell) return { skipped: "no native window shell" };
    const opened = [];
    let page = null;
    let second = null;
    let restoreRail = null;
    const out = {};
    try {
      await evalApp(`return globalThis.expo.modules.SolaraCEF.setDisplayMediaPicker(true).then(() => true)`);
      const red = await openTab(`${base}/solid?c=ff0000&t=Red`, "Red", true);
      opened.push(red);
      const call = await openTab(`${base}/capturer?t=CallBand`, "CallBand", true);
      opened.push(call);
      const other = await openTab(`${base}/solid?c=0000ff&t=Blue`, "Blue", true);
      opened.push(other);
      const describe = async () => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(mainWindow)})`));
      const slot = async (tabId) => (await describe())?.split?.overlays?.[tabId] ?? null;
      const shown = async (tabId) => {
        await evalApp(`ac.actions.switchToTab("${tabId}"); return true`);
        await until(`${tabId} shown`, async () => (await state()).active === tabId);
      };
      await shown(red.id);
      const redPage = await pageFor(red.id, "/solid?c=ff0000&t=Red");
      const inner = async () => (await cdp(redPage, "Runtime.evaluate", { expression: "innerHeight", returnByValue: true })).result.value;
      const iconsOnly = () => evalApp(`const s = ac.store.getState(); return s.windows[${JSON.stringify(mainWindow)}]?.sidebarIconsOnly ?? s.settings.sidebarIconsOnly ?? false`);
      const railBefore = await iconsOnly();
      restoreRail = async () => { if ((await iconsOnly()) !== railBefore) await evalApp(`ac.runCommand({ command: "toggleSidebarIconsOnly", arg: null, windowId: ${JSON.stringify(mainWindow)} }); return true`); };
      const rail = async (on) => {
        if ((await iconsOnly()) !== on) await evalApp(`ac.runCommand({ command: "toggleSidebarIconsOnly", arg: null, windowId: ${JSON.stringify(mainWindow)} }); return true`);
        await until(`the window ${on ? "in" : "out of"} the icons-only rail`, async () => (await iconsOnly()) === on, 3000);
        let last = null;
        return until(`the page settled ${on ? "in" : "out of"} the rail`, async () => {
          const h = await inner();
          const same = h === last;
          last = h;
          return same && (await describe())?.shareBand?.ticking !== true ? h : null;
        }, 5000);
      };
      const pushed = (what, without, withBar) => {
        if (Math.abs(without - withBar - 38) > 1) throw new Error(`${what}: the page is ${withBar} px tall with the bar and ${without} without, not 38 px shorter`);
      };
      await rail(false);
      const before = await until("red's page slot", () => slot(red.id), 5000);
      out.inner = { full: await inner() };
      out.inner.fullRail = await rail(true);
      await rail(false);
      await shown(call.id);
      page = await pageFor(call.id, "/capturer?t=CallBand");
      await cdp(page, "Runtime.evaluate", { expression: "share()", userGesture: true });
      await until("the picker", async () => (await eventsOf(call.id)).findLast((x) => x.name === "displayMediaRequest"), 10000);
      await evalApp(`return globalThis.acSharePicker.shareTab("${call.id}", "${red.id}")`);
      await until("the call sharing", async () => {
        const v = (await cdp(page, "Runtime.evaluate", { expression: "window.__cap", returnByValue: true })).result.value;
        if (v !== "pending" && v !== "live") throw new Error(`getDisplayMedia: ${v}`);
        return v === "live" ? v : null;
      }, 15000);
      await shown(red.id);
      const barRow = async () => {
        const rows = JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraMedia.probe("media.shareBar", ${JSON.stringify(mainWindow)})`));
        return (Array.isArray(rows) ? rows : rows?.rows ?? []).find((row) => row?.frames?.dismiss) ?? null;
      };
      const placed = await until("the share bar and the page", async () => {
        const [bar, page] = [await barRow(), await slot(red.id)];
        return bar && page ? { bar, page } : null;
      }, 5000);
      await sleep(400);
      const settledBar = await barRow();
      const settledPage = await slot(red.id);
      const pageTop = settledPage.window[1];
      const dismissBottom = settledBar.frames.dismiss[1] + settledBar.frames.dismiss[3];
      out.cover = { pageTop, dismissBottom, page: settledPage.window, dismiss: settledBar.frames.dismiss, placedAt: placed.page.window };
      await evalApp(`return ac.shell.devSnapshotWindow(${JSON.stringify(mainWindow)}, ${JSON.stringify(join(data, "share-bar-layout.png"))})`).catch(() => null);
      if (dismissBottom > pageTop + 0.5) throw new Error(`the share bar draws over the page's top instead of pushing it down: ${JSON.stringify(out.cover)}`);
      out.shared = await until("the bar over the shared tab, at full height", async () => {
        const s = await slot(red.id);
        return s?.band === 38 ? s : null;
      }, 3000);
      out.inner.bar = await rail(false);
      pushed("the page under the bar", out.inner.full, out.inner.bar);
      out.inner.barRail = await rail(true);
      await evalApp(`return ac.shell.devSnapshotWindow(${JSON.stringify(mainWindow)}, ${JSON.stringify(join(data, "share-bar-rail.png"))})`).catch(() => null);
      pushed("the page under the bar in the icons-only rail", out.inner.fullRail, out.inner.barRail);
      await rail(false);
      const [, , , h0] = before.window;
      const [, , , h1] = out.shared.window;
      if (Math.abs(h0 - h1 - 38) > 0.5) throw new Error(`the page slot didn't give the bar 38 pt: ${h0} → ${h1}`);
      out.band = await until("the band settled and its timer stopped", async () => {
        const band = (await describe()).shareBand;
        return band && !band.moving && !band.ticking ? band : null;
      }, 2000).catch(async () => (await describe()).shareBand);
      if (!out.band?.shown?.includes(red.id)) throw new Error(`the native band doesn't show the bar: ${JSON.stringify(out.band)}`);
      if (out.band.ticking) throw new Error(`the band's timer kept running after it settled: ${JSON.stringify(out.band)}`);
      await shown(other.id);
      out.other = await until("the bar over another tab of the profile", async () => {
        const s = await slot(other.id);
        return s?.band === 38 ? s : null;
      }, 3000);
      await evalApp(`ac.store.getState().createSplit(["${other.id}", "${red.id}"]); return true`);
      out.split = await until("the bar in both split panes", async () => {
        const [a, b] = [await slot(other.id), await slot(red.id)];
        return a?.band === 38 && b?.band === 38 ? { other: a, red: b } : null;
      }, 3000);
      out.inner.splitBar = await rail(false);
      const profileId = await evalApp(`return ac.store.getState().windows[${JSON.stringify(mainWindow)}].profileId`);
      second = await evalApp(`return ac.store.getState().createWindow({ url: "${base}/solid?c=00ff00&t=Green", profileId: ${JSON.stringify(profileId)}, background: true })`);
      const describeOf = async (w) => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(w)})`));
      const greenTab = await until("the second window's tab", () => evalApp(`const s = ac.store.getState(); const w = s.windows[${JSON.stringify(second)}]; return w?.profileId === ${JSON.stringify(profileId)} ? w.tabIds[0] ?? null : null`), 5000);
      await until("the bar in a second window of the profile", async () => (await describeOf(second))?.shareBand?.shown?.includes(greenTab), 5000);
      const closed = second;
      await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(closed)}); return true`);
      second = null;
      const dropped = async () => {
        const ids = (await describe())?.shareBandWindows;
        return Array.isArray(ids) && !ids.includes(closed) ? ids : null;
      };
      out.windowEnded = await until("the closed window's share band dropped", dropped, 5000);
      await sleep(1000);
      if (!(await dropped())) throw new Error(`the closed window ${closed} got its share band back: ${JSON.stringify((await describe())?.shareBandWindows)}`);
      await cdp(page, "Runtime.evaluate", { expression: "window.__stream?.getTracks().forEach((x) => x.stop()); true" });
      const stopped = Date.now();
      out.closed = await until("the bar gone after sharing stops", async () => {
        const s = await slot(red.id);
        return s && !s.band ? s : null;
      }, 5000);
      out.closedMs = Date.now() - stopped;
      out.idle = await until("the band's timer stopped after closing", async () => {
        const band = (await describe()).shareBand;
        return band && !band.ticking ? band : null;
      }, 2000).catch(async () => (await describe()).shareBand);
      if (out.idle?.ticking) throw new Error(`the band's timer kept running after the bar closed: ${JSON.stringify(out.idle)}`);
      if (out.closedMs > 1500 + 180 + 1000) throw new Error(`the bar took ${out.closedMs} ms to close`);
      out.inner.after = await rail(false);
      pushed("the split page after sharing stopped", out.inner.after, out.inner.splitBar);
      return { h0, h1, closedMs: out.closedMs, inner: out.inner };
    } finally {
      if (page) await cdp(page, "Runtime.evaluate", { expression: "window.__stream?.getTracks().forEach((x) => x.stop()); true" }).catch(() => null);
      if (second) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(second)}); return true`).catch(() => null);
      if (restoreRail) await restoreRail().catch(() => null);
      for (const t of opened) await closeTab(t.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  await check("restore-after-close", async () => {
    const shell = "globalThis.expo.modules.SolaraShell";
    const s = (expr) => evalApp(`const s = ac.store.getState(); return ${expr}`);
    const toB = async (tabId, tag) => {
      await until(`A?${tag} loaded`, async () => (await s(`s.tabs["${tabId}"]?.title === "Page A" && !s.live["${tabId}"]?.isLoading && !!ac.webviews.get("${tabId}")`)) || null, 15000);
      await evalApp(`ac.store.getState().navigate("${tabId}", "${base}/b?${tag}", { userInitiated: true }); return true`);
      await until(`B?${tag} with Back`, async () => (await s(`s.tabs["${tabId}"]?.title === "Page B" && s.live["${tabId}"]?.canGoBack && !s.live["${tabId}"]?.isLoading`)) || null, 15000);
    };
    const backReachesA = async (tabId, tag) => {
      await evalApp(`ac.actions.switchToTab("${tabId}"); return true`);
      await until(`the reopened B?${tag}`, async () => (await s(`s.tabs["${tabId}"]?.title === "Page B" && !s.live["${tabId}"]?.isLoading && !!ac.webviews.get("${tabId}")`)) || null, 15000);
      const canGoBack = await s(`!!s.live["${tabId}"]?.canGoBack`);
      if (!canGoBack) return { canGoBack };
      await evalApp(`return ac.webviews.get("${tabId}").goBack()`);
      const a = await until(`Back to A?${tag}`, async () => (await s(`s.tabs["${tabId}"]?.title === "Page A" && s.tabs["${tabId}"]?.url`)) || null, 10000).catch(() => null);
      return { canGoBack, back: a ? new URL(a).pathname + new URL(a).search : null };
    };
    const windowCase = async (tag, close) => {
      const w = await evalApp(`return ac.store.getState().createWindow({ url: "${base}/a?${tag}", background: true })`);
      const tabId = await s(`s.windows["${w}"].tabIds[0]`);
      await toB(tabId, tag);
      const windowsBefore = new Set(await s(`Object.keys(s.windows)`));
      await close(w, tabId);
      await until(`window ${tag} closed`, async () => !(await s(`!!s.windows["${w}"]`)), 15000);
      await evalApp(`ac.store.getState().reopenClosedWindow(); return true`);
      const reopened = await until("the reopened window", async () => (await s(`Object.keys(s.windows)`)).find((id) => !windowsBefore.has(id) && id !== w), 10000);
      const again = await until("its tab", async () => s(`s.windows["${reopened}"]?.tabIds.find((id) => s.tabs[id]?.url?.includes("/b?${tag}")) ?? null`), 10000);
      try {
        return await backReachesA(again, tag);
      } finally {
        await evalApp(`ac.store.getState().closeWindow("${reopened}"); return true`);
      }
    };
    const closeButton = async (tabId) => {
      const number = await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindowNumber(${await browserOf(tabId)})`);
      return evalApp(`return globalThis.expo.modules.SolaraCEF.devWindow(${number}, "close-button")`);
    };
    const warn = await s(`s.settings.warnBeforeClosingWindow`);
    const results = {};
    try {
      results.appCommand = await windowCase("r1", (w) => evalApp(`ac.store.getState().closeWindow("${w}"); return true`));
      results.closeWarning = await windowCase("r2", async (w, tabId) => {
        await evalApp(`ac.store.getState().newTab("${w}", { url: "${base}/c?r2", background: true }); ac.store.getState().updateSettings({ warnBeforeClosingWindow: true }); return true`);
        await sleep(300);
        await evalApp(`globalThis.__acConfirm = ${shell}.confirm; ${shell}.confirm = (o) => { globalThis.__acAsked = o.title; return Promise.resolve({ confirmed: true, suppressed: false }); }; return true`);
        await closeButton(tabId);
        await until("the close warning", () => evalApp(`return globalThis.__acAsked ?? null`), 5000);
      });
      await evalApp(`${shell}.confirm = globalThis.__acConfirm; return true`);
      results.nativeClose = await windowCase("r3", async (w, tabId) => {
        await evalApp(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: false }); return true`);
        await sleep(300);
        await closeButton(tabId);
      });
      const tabCase = async (tag, close) => {
        const tab = await openTab(`${base}/a?${tag}`, "Page A", true);
        await toB(tab.id, tag);
        await close(tab);
        await until(`tab ${tag} closed`, async () => !(await s(`!!s.tabs["${tab.id}"]`)), 10000);
        const before = new Set(await s(`s.windows["${mainWindow}"].tabIds`));
        await evalApp(`ac.store.getState().reopenClosedTab("${mainWindow}"); return true`);
        const again = await until("the reopened tab", async () => (await s(`s.windows["${mainWindow}"].tabIds`)).find((id) => !before.has(id)), 10000);
        try {
          return await backReachesA(again, tag);
        } finally {
          await closeTab(again);
        }
      };
      const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
      if (installed?.error) throw new Error(installed.error);
      try {
        const worker = await until("the extension's worker", async () =>
          (await targets()).find((t) => t.type === "service_worker" && t.url.includes(installed.id)) ?? null, 15000);
        results.tabsRemove = await tabCase("r4", async () => {
          const r = await cdp(worker, "Runtime.evaluate", {
            expression: `chrome.tabs.query({}).then((ts) => { const t = ts.find((t) => (t.url || "").includes("/b?r4")); return t ? chrome.tabs.remove(t.id).then(() => t.id) : null; })`,
            awaitPromise: true, returnByValue: true,
          });
          if (!r.result.value) throw new Error(`chrome.tabs.remove: ${JSON.stringify(r)}`);
        });
      } finally {
        await exts(`uninstall("${installed.id}", "")`);
      }
      results.windowClose = await (async () => {
        const opener = await pageFor(first.id, `${base}/a`);
        const before = new Set((await state()).tabs.map((t) => t.id));
        await cdp(opener, "Runtime.evaluate", { expression: `window.__r5 = window.open("${base}/a?r5", "_blank"); true`, userGesture: true });
        const tab = await until("the opened tab", async () => (await state()).tabs.find((t) => !before.has(t.id) && t.url?.includes("/a?r5")), 10000);
        await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
        await toB(tab.id, "r5");
        const page = await pageTarget(`${base}/b?r5`);
        await closeFromPage(page);
        await until("tab r5 closed", async () => !(await s(`!!s.tabs["${tab.id}"]`)), 10000);
        const now = new Set(await s(`s.windows["${mainWindow}"].tabIds`));
        await evalApp(`ac.store.getState().reopenClosedTab("${mainWindow}"); return true`);
        const again = await until("the reopened tab", async () => (await s(`s.windows["${mainWindow}"].tabIds`)).find((id) => !now.has(id)), 10000);
        try {
          return await backReachesA(again, "r5");
        } finally {
          await closeTab(again);
        }
      })();
    } finally {
      await evalApp(`if (globalThis.__acConfirm) ${shell}.confirm = globalThis.__acConfirm; ac.store.getState().updateSettings({ warnBeforeClosingWindow: ${warn} }); ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
    const failed = Object.entries(results).filter(([, r]) => !r.canGoBack || !r.back?.startsWith("/a?"));
    if (failed.length) throw new Error(`no Back to A after: ${failed.map(([k, r]) => `${k} ${JSON.stringify(r)}`).join(", ")}`);
    return results;
  });

  await check("discard-outcomes", async () => {
    const tab = await openTab(`${base}/d?discard`, "Page D", true);
    const browser = await browserOf(tab.id);
    const renderer = async () => (await evalApp(`return globalThis.expo.modules.SolaraCEF.listTasks()`)).some((t) => t.browserIds?.includes(Number(browser)));
    const flags = () => evalApp(`const l = globalThis.acLifecycle.state(); return { sleeping: !!ac.store.getState().live["${tab.id}"]?.discarded, loaded: l.loaded.includes("${tab.id}") }`);
    const raw = (opts = "") => evalApp(`return ac.webviews.get("${tab.id}").discard(${opts})`);
    try {
      const out = {};
      if (!(await renderer())) throw new Error("no renderer before the discard");
      out.unload = await raw("{ unload: true }");
      out.afterUnload = { renderer: await renderer(), ...(await flags()) };
      out.slept = await evalApp(`return globalThis.acLifecycle.sleepTab("${tab.id}")`);
      out.afterSleep = { renderer: await until("the renderer gone", async () => ((await renderer()) ? null : "gone"), 5000).catch(() => "still there"), ...(await flags()) };
      out.again = await raw();
      const other = await openTab(`${base}/e?refused`, "Page E", true);
      try {
        out.refusedSlept = await evalApp(`const h = ac.webviews.get("${other.id}"); h.discard = () => Promise.resolve("refused"); return globalThis.acLifecycle.sleepTab("${other.id}")`);
        out.refusedFlags = await evalApp(`return !!ac.store.getState().live["${other.id}"]?.discarded`);
      } finally {
        await closeTab(other.id);
      }
      await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
      out.woke = await until("awake", async () => {
        const f = await flags();
        return !f.sleeping && (await renderer()) ? { renderer: true, ...f } : null;
      }, 10000).catch(async () => ({ renderer: await renderer(), ...(await flags()) }));
      const problems = [];
      if (out.unload !== "unsupported" || !out.afterUnload.renderer || out.afterUnload.sleeping) problems.push(`unload: ${JSON.stringify([out.unload, out.afterUnload])}`);
      if (out.slept !== true || out.afterSleep.renderer !== "gone" || !out.afterSleep.sleeping) problems.push(`discard: ${JSON.stringify([out.slept, out.afterSleep])}`);
      if (out.again !== "already") problems.push(`again: ${JSON.stringify(out.again)}`);
      if (out.refusedSlept !== false || out.refusedFlags) problems.push(`refused: ${JSON.stringify([out.refusedSlept, out.refusedFlags])}`);
      if (out.woke.sleeping || !out.woke.renderer || !out.woke.loaded) problems.push(`wake: ${JSON.stringify(out.woke)}`);
      if (problems.length) throw new Error(problems.join("; "));
      return out;
    } finally {
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  await check("sleep-eligibility", async () => {
    const editor = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(page("Editor", `<div id="e" contenteditable>draft</div><script>
        const range = document.createRange();
        range.selectNodeContents(document.getElementById("e"));
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        document.execCommand("insertText", false, "typed in another origin");
        parent.postMessage("edited", "*");
      </script>`));
    });
    await new Promise((r) => editor.listen(0, "127.0.0.1", r));
    const editorUrl = `http://127.0.0.1:${editor.address().port}/`;
    const host = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(page("Sleep host", `<iframe src="${editorUrl}"></iframe><script>window.__edited = false; addEventListener("message", (e) => { if (e.data === "edited") window.__edited = true; });</script>`));
    });
    await new Promise((r) => host.listen(0, "127.0.0.1", r));
    const hostUrl = `http://127.0.0.1:${host.address().port}/`;
    const reasons = (id) => evalApp(`return ac.webviews.get("${id}").reasonsNotToSleep()`);
    const sleepIfEligible = (id) => evalApp(`return ac.webviews.get("${id}").sleepIfEligible()`);
    const awake = async (id) => {
      await evalApp(`ac.actions.switchToTab("${id}"); return true`);
      await until(`${id} reloaded`, async () => {
        const l = await evalApp(`const l = globalThis.acLifecycle.state(); return { sleeping: !!ac.store.getState().live["${id}"]?.discarded, loaded: l.loaded.includes("${id}") }`);
        const tab = (await state()).tabs.find((t) => t.id === id);
        return !l.sleeping && l.loaded && tab && !tab.loading ? true : null;
      }, 15000);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A shown", async () => (await state()).active === first.id);
      await until(`${id} eligible again`, async () => ((await reasons(id))?.length === 0 ? true : null), 5000);
    };
    const opened = [];
    const out = {};
    try {
      const plain = await openTab(`${base}/b?sleep-plain`, "Page B", true);
      opened.push(plain.id);
      out.plainReasons = await reasons(plain.id);
      out.plainSlept = await sleepIfEligible(plain.id);
      await awake(plain.id);
      out.plainSleptAgain = await sleepIfEligible(plain.id);

      const edited = await openTab(hostUrl, "Sleep host", true);
      opened.push(edited.id);
      const hostPage = await pageFor(edited.id, hostUrl);
      out.frameEdited = await until("the frame's edit", async () => ((await cdp(hostPage, "Runtime.evaluate", { expression: "window.__edited", returnByValue: true })).result.value === true ? true : null), 5000).catch(() => false);
      out.editedReasons = await reasons(edited.id);
      out.editedSlept = await sleepIfEligible(edited.id);
      out.editedForced = await evalApp(`return ac.webviews.get("${edited.id}").discard()`);

      const audible = await openTab(`${base}/media?sleep-audible`, "Media", false);
      opened.push(audible.id);
      const t = await pageFor(audible.id, `${base}/media?sleep-audible`);
      await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('tone').play(); true", userGesture: true });
      await until("live.playingAudio", async () => (await live(audible.id))?.playingAudio === true, 8000);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A shown", async () => (await state()).active === first.id);
      out.audibleReasons = await reasons(audible.id);
      out.audibleSlept = await sleepIfEligible(audible.id);

      const excepted = await openTab(`${base}/b?sleep-excepted`, "Page B", true);
      opened.push(excepted.id);
      const before = await cef(`sleepExceptions("")`);
      try {
        out.exceptionSet = await cef(`setSleepExceptions("", ${JSON.stringify([...new Set([...(before ?? []), "127.0.0.1"])])})`);
        out.exceptions = await cef(`sleepExceptions("")`);
        out.exceptedReasons = await until("the exception applied", async () => {
          const r = await reasons(excepted.id);
          return r?.includes("siteException") ? r : null;
        }, 5000).catch(() => reasons(excepted.id));
        out.exceptedSlept = await sleepIfEligible(excepted.id);
      } finally {
        await cef(`setSleepExceptions("", ${JSON.stringify(before ?? [])})`);
      }
      out.exceptionCleared = await cef(`sleepExceptions("")`);

      const problems = [];
      if (!Array.isArray(out.plainReasons) || out.plainReasons.length) problems.push(`plain reasons: ${JSON.stringify(out.plainReasons)}`);
      if (out.plainSlept !== "discarded") problems.push(`plain sleep: ${JSON.stringify(out.plainSlept)}`);
      if (out.plainSleptAgain !== "discarded") problems.push(`plain sleep after a wake: ${JSON.stringify(out.plainSleptAgain)}`);
      if (out.frameEdited !== true) problems.push("the cross-origin frame never edited");
      if (!out.editedReasons?.includes("userEdits")) problems.push(`cross-origin edit: ${JSON.stringify(out.editedReasons)}`);
      if (out.editedSlept !== "refused") problems.push(`edited sleep: ${JSON.stringify(out.editedSlept)}`);
      if (out.editedForced !== "discarded") problems.push(`forced discard: ${JSON.stringify(out.editedForced)}`);
      if (!out.audibleReasons?.includes("audible")) problems.push(`audible: ${JSON.stringify(out.audibleReasons)}`);
      if (out.audibleSlept !== "refused") problems.push(`audible sleep: ${JSON.stringify(out.audibleSlept)}`);
      if (out.exceptionSet !== true || !out.exceptions?.includes("127.0.0.1")) problems.push(`exceptions: ${JSON.stringify([out.exceptionSet, out.exceptions])}`);
      if (!out.exceptedReasons?.includes("siteException")) problems.push(`excepted: ${JSON.stringify(out.exceptedReasons)}`);
      if (out.exceptedSlept !== "refused") problems.push(`excepted sleep: ${JSON.stringify(out.exceptedSlept)}`);
      if (JSON.stringify(out.exceptionCleared ?? []) !== JSON.stringify(before ?? [])) problems.push(`exceptions not restored: ${JSON.stringify(out.exceptionCleared)}`);
      if (problems.length) throw new Error(problems.join("; "));
      return out;
    } finally {
      for (const id of opened) await closeTab(id).catch(() => null);
      editor.close();
      host.close();
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  await check("keep-awake-sites", async () => {
    const setting = () => evalApp(`return ac.store.getState().settings.keepAwakeSites ?? []`);
    const setSites = (sites) => evalApp(`ac.store.getState().updateSettings({ keepAwakeSites: ${JSON.stringify(sites)} }); return true`);
    const before = await setting();
    const adoptedBefore = await evalApp(`return ac.store.getState().settings.keepAwakeAdoptedProfiles ?? []`);
    const sub = `https://one.${siteDataDomain}/site-data`;
    const out = {};
    let tab;
    try {
      tab = await openTab(sub, "Site data", true);
      out.reasonsBefore = await evalApp(`return ac.webviews.get("${tab.id}").reasonsNotToSleep()`);
      await setSites([siteDataDomain]);
      out.engineAll = await until("the list in the engine's own exceptions", async () => {
        const list = await cef(`sleepExceptions("")`);
        return list?.includes(siteDataDomain) ? list : null;
      }, 5000).catch(() => cef(`sleepExceptions("")`));
      out.reasonsKept = await until("a subdomain kept awake by its parent", async () => {
        const reasons = await evalApp(`return ac.webviews.get("${tab.id}").reasonsNotToSleep()`);
        return reasons?.includes("siteException") ? reasons : null;
      }, 5000).catch(() => evalApp(`return ac.webviews.get("${tab.id}").reasonsNotToSleep()`));
      out.sleptWhileKept = await evalApp(`return ac.webviews.get("${tab.id}").sleepIfEligible()`);
      await setSites([]);
      out.engineCleared = await until("the engine's exceptions cleared", async () => {
        const list = await cef(`sleepExceptions("")`);
        return list && !list.includes(siteDataDomain) ? list : null;
      }, 5000).catch(() => cef(`sleepExceptions("")`));
      out.reasonsCleared = await evalApp(`return ac.webviews.get("${tab.id}").reasonsNotToSleep()`);
      out.chromeSet = await cef(`setSleepExceptions("", ${JSON.stringify(["[*.]kept.example"])})`);
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeAdoptedProfiles: [] }); return true`);
      out.adopted = await until("Chrome's own exception adopted into Settings › Tabs", async () => {
        const sites = await setting();
        return sites.includes("kept.example") ? sites : null;
      }, 5000).catch(setting);
      out.engineAfterAdopting = await until("the adopted list written back", async () => {
        const list = await cef(`sleepExceptions("")`);
        return list?.includes("kept.example") && !list.includes("[*.]kept.example") ? list : null;
      }, 5000).catch(() => cef(`sleepExceptions("")`));
      const engineNow = (await cef(`sleepExceptions("")`)) ?? [];
      out.chromeAddedLater = await cef(`setSleepExceptions("", ${JSON.stringify([...engineNow, "later.example"])})`);
      await setSites([...(await setting()), "other.example"]);
      out.adoptedLater = await until("an exception added in Chrome after adoption kept and adopted", async () => {
        const sites = await setting();
        return sites.includes("later.example") ? sites : null;
      }, 5000).catch(setting);
      out.engineLater = await until("the engine keeping both", async () => {
        const list = await cef(`sleepExceptions("")`);
        return list?.includes("later.example") && list.includes("other.example") ? list : null;
      }, 5000).catch(() => cef(`sleepExceptions("")`));
      if (nativeSleepExpected()) {
        writeFileSync(join(data, ".solara-probe-scratch"), "");
        const running = async () => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraStoreAdapter.devTabSleep("status")`)).running;
        await evalApp(`ac.store.getState().updateSettings({ sleepInactiveTabs: false }); return true`);
        out.runnerWhenOff = await until("the native runner stopped", async () => ((await running()) === false ? false : null), 5000).catch(() => running());
        await evalApp(`ac.store.getState().updateSettings({ sleepInactiveTabs: true }); return true`);
        out.runnerWhenOn = await until("the native runner running again", async () => ((await running()) === true ? true : null), 5000).catch(() => running());
      }
      const problems = [];
      if (out.reasonsBefore?.includes("siteException")) problems.push(`a site exception before any was set: ${JSON.stringify(out.reasonsBefore)}`);
      if (!out.engineAll?.includes(siteDataDomain)) problems.push(`the setting never reached the engine: ${JSON.stringify(out.engineAll)}`);
      if (!out.reasonsKept?.includes("siteException")) problems.push(`one.${siteDataDomain} wasn't kept awake by ${siteDataDomain}: ${JSON.stringify(out.reasonsKept)}`);
      if (out.sleptWhileKept !== "refused") problems.push(`slept while kept awake: ${JSON.stringify(out.sleptWhileKept)}`);
      if (out.chromeSet !== true || !out.adopted?.includes("kept.example")) problems.push(`a Chrome exception wasn't adopted into the setting: ${JSON.stringify([out.chromeSet, out.adopted])}`);
      if (!out.engineAfterAdopting?.includes("kept.example")) problems.push(`the adopted list didn't reach the engine: ${JSON.stringify(out.engineAfterAdopting)}`);
      if (out.chromeAddedLater !== true || !out.adoptedLater?.includes("later.example") || !out.engineLater?.includes("later.example") || !out.engineLater?.includes("other.example")) problems.push(`an exception added in Chrome after adoption was lost: ${JSON.stringify([out.chromeAddedLater, out.adoptedLater, out.engineLater])}`);
      if ("runnerWhenOff" in out && (out.runnerWhenOff !== false || out.runnerWhenOn !== true)) problems.push(`the switch didn't stop and restart the native runner: ${JSON.stringify([out.runnerWhenOff, out.runnerWhenOn])}`);
      if (out.engineCleared?.includes(siteDataDomain) || out.reasonsCleared?.includes("siteException")) problems.push(`removing the site didn't reach the engine: ${JSON.stringify([out.engineCleared, out.reasonsCleared])}`);
      if (problems.length) throw new Error(problems.join("; "));
      return out;
    } finally {
      await setSites(before).catch(() => null);
      await evalApp(`ac.store.getState().updateSettings({ sleepInactiveTabs: true }); return true`).catch(() => null);
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeAdoptedProfiles: ${JSON.stringify(adoptedBefore)} }); return true`).catch(() => null);
      if (tab) await closeTab(tab.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  await check("sleep-pinned-capture", async () => {
    const opened = [];
    let capturerPage;
    let capturedPage;
    const reasons = (id) => evalApp(`return ac.webviews.get("${id}").reasonsNotToSleep()`);
    const waive = (id) => evalApp(`return ac.webviews.get("${id}").sleepIfEligible({ waivingPinned: true })`);
    const pin = async (id) => {
      await evalApp(`ac.store.getState().pinTabs(["${id}"], true); return true`);
      return until(`${id} pinned in Chrome's tab strip`, async () =>
        (await cef(`tabStrips()`)).strips.flatMap((strip) => strip.tabs).find((tab) => tab.key === id && tab.pinned && !tab.active) ?? null, 10000);
    };
    const out = {};
    try {
      const target = await openTab(`${base}/capture-target?sleep-pinned`, "Capture Target", true);
      opened.push(target.id);
      capturedPage = await pageFor(target.id, `${base}/capture-target?sleep-pinned`);
      await cef(`setDisplayMediaPicker(false)`);
      const capturer = await openTab(`${base}/b?sleep-pinned-capture`, "Page B");
      opened.push(capturer.id);
      capturerPage = await pageFor(capturer.id, `${base}/b?sleep-pinned-capture`);
      await cdp(capturerPage, "Runtime.evaluate", {
        expression: "window.__cap = 'pending'; navigator.mediaDevices.getDisplayMedia({ video: true }).then((s) => { window.__stream = s; window.__cap = 'live'; }, (e) => (window.__cap = e.name)); true",
        userGesture: true,
      });
      await until("the pinned candidate's live capture", async () => {
        const value = (await cdp(capturerPage, "Runtime.evaluate", { expression: "window.__cap", returnByValue: true })).result.value;
        if (value !== "pending" && value !== "live") throw new Error(`getDisplayMedia: ${value}`);
        return value === "live" ? true : null;
      }, 15000);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A shown", async () => (await state()).active === first.id);
      out.captureStrip = await pin(target.id);
      out.captureReasons = await until("pin and capture reasons together", async () => {
        const value = await reasons(target.id);
        return value?.includes("pinnedTab") && value.some((reason) => ["capturingVideo", "capturingAudio", "mirrored", "capturingWindow", "capturingDisplay"].includes(reason)) ? value : null;
      }, 10000);
      out.captureSleep = await waive(target.id);
      out.captureStillLive = (await cdp(capturerPage, "Runtime.evaluate", {
        expression: "window.__stream.getTracks().some((track) => track.readyState === 'live')",
        returnByValue: true,
      })).result.value;
      out.captureDiscarded = (await live(target.id))?.discarded === true;
      out.capturedRenderer = (await cdp(capturedPage, "Runtime.evaluate", { expression: "document.title", returnByValue: true })).result.value;

      const plain = await openTab(`${base}/b?sleep-pinned-plain`, "Page B", true);
      opened.push(plain.id);
      out.plainStrip = await pin(plain.id);
      out.plainReasons = await until("only Chrome's pin blocks sleep", async () => {
        const value = await reasons(plain.id);
        return value?.length === 1 && value[0] === "pinnedTab" ? value : null;
      }, 10000);
      out.plainSleep = await waive(plain.id);
      if (out.captureSleep !== "refused" || out.captureStillLive !== true || out.captureDiscarded || out.capturedRenderer !== "Capture Target")
        throw new Error(`pin waiver lost capture protection: ${JSON.stringify(out)}`);
      if (out.plainSleep !== "discarded") throw new Error(`pin waiver did not sleep the plain pinned tab: ${JSON.stringify(out)}`);
      out.plainDiscarded = await until("the plain pinned tab discarded", async () => (await live(plain.id))?.discarded === true, 10000);
      return out;
    } finally {
      if (capturerPage) await cdp(capturerPage, "Runtime.evaluate", { expression: "window.__stream?.getTracks().forEach((track) => track.stop()); true" }).catch(() => null);
      for (const id of opened) {
        await evalApp(`ac.store.getState().pinTabs(["${id}"], false); return true`).catch(() => null);
        await closeTab(id).catch(() => null);
      }
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  await check("native-tab-sleep", async () => {
    writeFileSync(join(data, ".solara-probe-scratch"), "");
    const dev = async (action) => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraStoreAdapter.devTabSleep(${JSON.stringify(action)})`));
    if (!nativeSleepExpected()) {
      const runner = await dev("status");
      const store = await evalApp(`return globalThis.expo.modules.SolaraStoreAdapter.status()`);
      if (runner.running || store?.nativeTabSleep) throw new Error(`the native runner runs although ${process.env.SOLARA_TAB_POOL === "0" ? "the pool is off and it can't see RN pages' permissions" : "SOLARA_NATIVE_TAB_SLEEP=0"}: ${JSON.stringify({ runner, store })}`);
      const fallback = await openTab(`${base}/solid?c=00aa00&t=Fallback`, "Fallback", false);
      try {
        await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
        await until("the hidden tab tracked by the JS fallback", () => evalApp(`return "${fallback.id}" in globalThis.acLifecycle.state().hiddenAt || null`), 5000);
        const slept = await until("the JS sweep sleeping a hidden tab with the native runner off", async () => {
          const ids = await evalApp(`return globalThis.acLifecycle.sweep({ protectedRecent: 0, idleMs: 0 })`);
          return (await live(fallback.id))?.discarded === true ? ids : null;
        }, 20000);
        return { fallback: true, slept };
      } finally {
        await closeTab(fallback.id).catch(() => null);
      }
    }
    const started = await until("the native runner running by default", async () => ((await dev("status")).running ? true : null), 10000).catch(() => false);
    if (!started) throw new Error(`the native runner isn't running: ${JSON.stringify(await dev("status"))}`);
    const sleeping = async (id) => (await live(id))?.discarded === true;
    const sweepUntil = async (what, ids) => {
      const slept = new Set();
      await until(what, async () => {
        for (const id of (await dev("sweep")).slept ?? []) slept.add(id);
        const all = [];
        for (const id of ids) all.push(slept.has(id) && (await sleeping(id)));
        return all.every(Boolean) ? true : null;
      }, 20000).catch(() => null);
      return slept;
    };
    const pin = async (id) => {
      await evalApp(`ac.store.getState().pinTabs(["${id}"], true); return true`);
      return until(`${id} pinned in Chrome's tab strip`, async () =>
        (await cef(`tabStrips()`)).strips.flatMap((strip) => strip.tabs).find((tab) => tab.key === id && tab.pinned && !tab.active) ?? null, 10000);
    };
    const opened = [];
    const out = {};
    try {
      out.status = await until("the native runner running", async () => ((await dev("status")).running === true ? true : null), 10000).catch(async () => dev("status"));
      const plain = await openTab(`${base}/b?native-sleep-plain`, "Page B", true);
      opened.push(plain.id);
      const closing = await openTab(`${base}/c?native-sleep-closed`, "Page C", true);
      opened.push(closing.id);
      const pinned = await openTab(`${base}/d?native-sleep-pinned`, "Page D", true);
      opened.push(pinned.id);
      await pin(pinned.id);
      const audible = await openTab(`${base}/media?native-sleep-audible`, "Media", false);
      opened.push(audible.id);
      const tone = await pageFor(audible.id, `${base}/media?native-sleep-audible`);
      await cdp(tone, "Runtime.evaluate", { expression: "document.getElementById('tone').play(); true", userGesture: true });
      await until("live.playingAudio", async () => (await live(audible.id))?.playingAudio === true, 8000);
      const video = await openTab(`${base}/video?native-sleep-pip`, "Video", false);
      opened.push(video.id);
      await evalApp(`return ac.webviews.get("${video.id}").setMuted(true)`);
      const v = await startVideo(video.id, false);
      const entered = await cdp(v, "Runtime.evaluate", { expression: "document.getElementById('v').requestPictureInPicture().then(() => 'ok', (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true });
      out.pip = entered.result?.value;
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A shown", async () => (await state()).active === first.id);

      out.normalSweep = (await dev("sweep")).slept ?? [];
      out.pressure = await dev("pressure:critical");
      const slept = await sweepUntil("the plain, closing and pinned tabs asleep", [plain.id, closing.id, pinned.id]);
      out.slept = [...slept];
      out.asleep = { plain: await sleeping(plain.id), closing: await sleeping(closing.id), pinned: await sleeping(pinned.id) };
      out.protected = { shown: await sleeping(first.id), audible: await sleeping(audible.id), pip: await sleeping(video.id) };
      out.pipStillOpen = !!(await pipWindows())?.find((w) => w.video && w.visible);

      await evalApp(`ac.actions.switchToTab("${plain.id}"); return true`);
      out.woke = await until("the plain tab awake and reloaded", async () => {
        const tab = (await state()).tabs.find((t) => t.id === plain.id);
        return !(await sleeping(plain.id)) && tab && !tab.loading && tab.title === "Page B" ? true : null;
      }, 15000).catch(() => false);
      out.wokeShownNotReslept = !((await dev("sweep")).slept ?? []).includes(plain.id) && !(await sleeping(plain.id));
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A shown", async () => (await state()).active === first.id);

      const closedUrl = `${base}/c?native-sleep-closed`;
      await closeTab(closing.id);
      opened.splice(opened.indexOf(closing.id), 1);
      for (let i = 0; i < 3; i++) await dev("sweep");
      await sleep(1500);
      const after = await state();
      out.closedGone = !after.tabs.some((t) => t.id === closing.id || t.url === closedUrl);

      const problems = [];
      if (out.status !== true) problems.push(`runner: ${JSON.stringify(out.status)}`);
      if (out.normalSweep.some((id) => [plain.id, closing.id, pinned.id].includes(id))) problems.push(`slept at normal pressure inside the idle window: ${JSON.stringify(out.normalSweep)}`);
      if (![plain.id, closing.id, pinned.id].some((id) => slept.has(id))) problems.push(`no manual sweep reported a tab it slept: ${JSON.stringify(out.slept)}`);
      if (!out.asleep.plain || !out.asleep.closing) problems.push(`plain tabs not asleep: ${JSON.stringify(out.asleep)}`);
      if (!out.asleep.pinned) problems.push(`a plain pinned tab not asleep through the waiver: ${JSON.stringify(out.asleep)}`);
      if (out.protected.shown || out.protected.audible || out.protected.pip) problems.push(`a protected tab slept: ${JSON.stringify(out.protected)}`);
      if (out.pip !== "ok" || !out.pipStillOpen) problems.push(`PiP: ${JSON.stringify([out.pip, out.pipStillOpen])}`);
      if (out.woke !== true || !out.wokeShownNotReslept) problems.push(`wake: ${JSON.stringify([out.woke, out.wokeShownNotReslept])}`);
      if (!out.closedGone) problems.push("a closed slept tab came back");
      if (problems.length) throw new Error(`${problems.join("; ")}: ${JSON.stringify(out)}`);
      return out;
    } finally {
      const reset = await dev("pressure:normal").catch((e) => ({ error: String(e) }));
      for (const id of opened) {
        await evalApp(`return ac.webviews.get("${id}")?.exitPictureInPicture?.()`).catch(() => null);
        await evalApp(`ac.store.getState().pinTabs(["${id}"], false); return true`).catch(() => null);
        await closeTab(id).catch(() => null);
      }
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
      if (reset?.pressure !== "normal") throw new Error(`the runner's pressure wasn't reset: ${JSON.stringify(reset)}`);
    }
  });

  await check("capture-picture", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    const picture = await evalApp(`return ac.webviews.get("${first.id}").capturePicture(0.3)`);
    if (!picture?.data || !Buffer.from(picture.data, "base64").subarray(0, 2).equals(Buffer.from([0xff, 0xd8])))
      throw new Error(`no JPEG: ${JSON.stringify(picture)?.slice(0, 120)}`);
    return { bytes: Buffer.from(picture.data, "base64").length, frame: picture.frame };
  });

  await check("unresponsive", async () => {
    const busy = await openTab(`${base}/b?busy`, "Page B");
    try {
      await evalApp(`return ac.webviews.get("${busy.id}").focus()`);
      await evalApp(`return ac.webviews.get("${busy.id}").executeJavaScript("setTimeout(() => { document.title = 'Busy'; const end = Date.now() + 40000; while (Date.now() < end); }, 50)")`);
      await until("the page busy", async () => (await state()).tabs.find((t) => t.id === busy.id && t.title === "Busy"), 10000);
      await sleep(300);
      const s = await state();
      const sent = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "a", keyCode: 0, modifiers: [], focus: "page" })`);
      const busyNow = "-";
      const hung = await until("onUnresponsive", async () => (await eventsOf(busy.id)).find((x) => x.name === "unresponsive"), 35000)
        .catch(async (e) => { throw new Error(`${e.message}; page ${busyNow}; key ${JSON.stringify(sent)}; events ${JSON.stringify((await eventsOf(busy.id)).map((x) => x.name).slice(-8))}; active ${(await state()).active === busy.id}`); });
      await evalApp(`return ac.webviews.get("${busy.id}").resolveUnresponsive(false)`);
      const back = await until("onResponsive", async () => (await eventsOf(busy.id)).find((x) => x.name === "responsive"), 45000)
        .catch(async (e) => { throw new Error(`${e.message}; events ${JSON.stringify((await eventsOf(busy.id)).map((x) => x.name).slice(-10))}`); });
      return { unresponsive: !!hung, responsive: !!back };
    } finally {
      await closeTab(busy.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("permission-status-detached", async () => {
    const seen = {};
    for (const mode of ["remove", "navigate"]) {
      const tab = await openTab(`${base}/perm-detach?${mode}`, "Perm detach");
      try {
        const t = await pageFor(tab.id, `${base}/perm-detach?${mode}`);
        await cdp(t, "Runtime.evaluate", { expression: `run("${mode}")`, awaitPromise: true, returnByValue: true }).catch(() => null);
        await sleep(1000);
        const crashed = await evalApp(`return ac.pageState.getState().pages["${tab.id}"]?.crashed ?? null`);
        const result = crashed ? null : (await cdp(await pageFor(tab.id, `${base}/perm-detach?${mode}`), "Runtime.evaluate", { expression: "window.__r", returnByValue: true }).catch(() => null))?.result?.value;
        seen[mode] = { crashed, result };
        if (crashed || result !== `survived ${mode}`) throw new Error(`removeEventListener on a detached frame's PermissionStatus: ${JSON.stringify(seen)}`);
      } finally {
        await closeTab(tab.id);
      }
    }
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    return seen;
  });

  await check("permission-dismissed", async () => {
    await evalApp(`globalThis.__acDismissed = []; globalThis.__acDismissSub?.remove(); globalThis.__acDismissSub = globalThis.expo.modules.SolaraCEF.addListener("onPermissionDismissed", (e) => globalThis.__acDismissed.push(e)); return true`);
    const asker = await openTab(`${base}/c?asker`, "Page C");
    try {
      const t = await pageFor(asker.id, `${base}/c?asker`);
      await cdp(t, "Runtime.evaluate", { expression: "navigator.requestMIDIAccess({ sysex: true }).catch(() => {}); true", userGesture: true });
      const request = await until("the prompt", async () => evalApp(`return ac.pageState.getState().pages["${asker.id}"]?.permission ?? null`), 10000);
      await closeTab(asker.id);
      const dismissed = await until("onPermissionDismissed", async () => {
        const list = await evalApp(`return globalThis.__acDismissed`);
        return list.find((x) => x.id === request.id) ?? null;
      }, 10000).catch(async (e) => { throw new Error(`${e.message}; request ${request.id}; got ${JSON.stringify(await evalApp(`return globalThis.__acDismissed`))}`); });
      return { request: request.id, dismissed };
    } finally {
      await evalApp(`globalThis.__acDismissSub?.remove(); return true`);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("task-manager", async () => {
    const tab = await openTab(`${base}/c?tasks`, "Page C", true);
    const call = (args) => evalApp(`return globalThis.expo.modules.SolaraCEF.engineCall("ac_task_manager_open", "", ${JSON.stringify(args)})`).then(JSON.parse);
    try {
      const browser = Number(await browserOf(tab.id));
      const task = await until("the tab's task", async () => {
        const tasks = await evalApp(`return globalThis.expo.modules.SolaraCEF.listTasks()`);
        return tasks.find((x) => (x.browserIds ?? []).includes(browser)) ?? null;
      }, 10000);
      const opened = await call(null);
      if (!opened.ok) throw new Error(`ac_task_manager_open: ${JSON.stringify(opened)}`);
      return { task: task.title ?? task.id, opened: true };
    } finally {
      await call(JSON.stringify({ hide: true })).catch(() => null);
      await closeTab(tab.id);
    }
  });

  const resourceCall = async (name, args, profile = "") => {
    const started = Date.now();
    const value = JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraCEF.engineCall(${JSON.stringify(name)}, ${JSON.stringify(profile)}, ${JSON.stringify(typeof args === "string" ? args : JSON.stringify(args))})`, 15000));
    return { value, started, ended: Date.now() };
  };
  const resourceRace = async (name, id, action) => {
    const started = Date.now();
    const value = JSON.parse(await evalApp(`const pending = globalThis.expo.modules.SolaraCEF.engineCall(${JSON.stringify(name)}, "", ${JSON.stringify(JSON.stringify({ tabIds: [id] }))}); ${action}; return pending`, 15000));
    return { value, started, ended: Date.now() };
  };
  const resourceRows = (reply, ids, kind) => {
    assert.deepEqual(Object.keys(reply.value), ["tabs"]);
    assert.ok(Array.isArray(reply.value.tabs));
    const seen = [];
    for (const row of reply.value.tabs) {
      assert.deepEqual(Object.keys(row).sort(), (kind === "memory" ? ["tabId", "bytes", "source", "at"] : ["tabId", "cpuMs", "elapsedMs", "measurementId", "source", "at"]).sort());
      assert.ok(Number.isInteger(row.tabId) && ids.includes(row.tabId));
      assert.ok(Number.isFinite(row.at) && row.at >= reply.started - 5000 && row.at <= reply.ended + 5000);
      if (kind === "memory") {
        assert.ok(Number.isFinite(row.bytes) && row.bytes >= 0);
        assert.ok(["attribution", "footprint"].includes(row.source));
      } else {
        assert.equal(row.source, "attribution");
        assert.ok(Number.isFinite(row.cpuMs) && row.cpuMs >= 0);
        assert.ok(Number.isFinite(row.elapsedMs) && row.elapsedMs >= 0);
        assert.ok(typeof row.measurementId === "string" && row.measurementId.length > 0);
      }
      seen.push(row.tabId);
    }
    assert.deepEqual(seen, [...new Set(seen)].sort((a, b) => a - b));
    return reply.value.tabs;
  };
  const resourceSessionId = (tab) => until("the scratch tab's session ID", async () => {
    const browser = Number(await browserOf(tab));
    if (!Number.isInteger(browser) || browser <= 0) return null;
    const id = await cef(`chromeTabId(${browser})`);
    return Number.isInteger(id) && id >= 0 ? id : null;
  }, 10000);
  const resourceArguments = async (name) => {
    assert.deepEqual((await resourceCall(name, { tabIds: [] })).value, { tabs: [] });
    for (const args of [{}, { tabIds: null }, { tabIds: "1" }, { tabIds: [true] }, { tabIds: [1.5] }, { tabIds: ["1"] }, { tabIds: [2147483648] }]) {
      assert.deepEqual((await resourceCall(name, args)).value, { error: "tabIds must be a list of integer tab ids" });
    }
    assert.deepEqual(resourceRows(await resourceCall(name, { tabIds: [-1, 0, 2147483647] }), [-1, 0, 2147483647], name === "ac_tabs_memory" ? "memory" : "cpu"), []);
    const refused = await resourceCall(name, { tabIds: [] }, "api38-unloaded-profile");
    assert.equal(refused.value.error, `${name} requires an empty profile`);
  };

  await check("tab-memory", async () => {
    const opened = [];
    let privateWindow = null;
    const profiles = (await state()).profiles;
    try {
      const tab = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: "${base}/c?api38-memory" })`);
      opened.push(tab);
      await shownAndMounted(tab);
      await until("the scratch memory page", () => evalApp(`const s = ac.store.getState(); return s.tabs[${JSON.stringify(tab)}]?.title === "Page C" && !s.live[${JSON.stringify(tab)}]?.isLoading`), 15000);
      const id = await resourceSessionId(tab);
      await resourceArguments("ac_tabs_memory");
      const sample = await until("the live tab's memory attribution", async () => resourceRows(await resourceCall("ac_tabs_memory", `{"tabIds":[${id}.0,${id},-1]}`), [id, -1], "memory").find((row) => row.tabId === id) ?? null, 30000);
      privateWindow = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${base}/c?api38-private-memory" })`);
      const privateTab = await until("the scratch private page", () => evalApp(`const s = ac.store.getState(); const w = s.windows[${JSON.stringify(privateWindow)}]; return w?.tabIds.find((id) => s.tabs[id]?.title === "Page C" && !s.live[id]?.isLoading) ?? null`), 15000);
      const privateId = await resourceSessionId(privateTab);
      const paired = await until("regular and private memory attribution", async () => {
        const rows = resourceRows(await resourceCall("ac_tabs_memory", { tabIds: [privateId, id, privateId] }), [privateId, id], "memory");
        return rows.length === 2 ? rows : null;
      }, 30000);
      resourceRows(await resourceRace("ac_tabs_memory", id, `ac.store.getState().navigate(${JSON.stringify(tab)}, "${base}/c?api38-memory-next", { userInitiated: true })`), [id], "memory");
      await until("the scratch memory navigation", () => evalApp(`const s = ac.store.getState(); return s.tabs[${JSON.stringify(tab)}]?.url === "${base}/c?api38-memory-next" && !s.live[${JSON.stringify(tab)}]?.isLoading`), 15000);
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(first.id)}); return true`);
      await until("the scratch memory tab in the background", async () => (await state()).active === first.id, 5000);
      assert.equal(await evalApp(`return ac.webviews.get(${JSON.stringify(tab)})?.discard()`), "discarded");
      await until("the scratch memory page discarded", async () => (await eventsOf(tab)).some((event) => event.name === "discarded"), 10000);
      assert.deepEqual(resourceRows(await resourceCall("ac_tabs_memory", { tabIds: [id] }), [id], "memory"), []);
      resourceRows(await resourceRace("ac_tabs_memory", privateId, `ac.store.getState().closeWindow(${JSON.stringify(privateWindow)})`), [privateId], "memory");
      privateWindow = null;
      await until("the closed private page omitted from memory", async () => resourceRows(await resourceCall("ac_tabs_memory", { tabIds: [privateId] }), [privateId], "memory").length === 0, 15000);
      assert.deepEqual((await state()).profiles, profiles);
      return { sample, paired, discardedOmitted: true, closedOmitted: true };
    } finally {
      if (privateWindow) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(privateWindow)}); return true`).catch(() => null);
      for (const tab of opened) await closeTab(tab).catch(() => null);
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(first.id)}); return true`).catch(() => null);
    }
  });

  await check("tab-cpu", async () => {
    let tab = null;
    const profiles = (await state()).profiles;
    try {
      tab = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: "${base}/c?api38-cpu" })`);
      await shownAndMounted(tab);
      await until("the scratch CPU page", () => evalApp(`const s = ac.store.getState(); return s.tabs[${JSON.stringify(tab)}]?.title === "Page C" && !s.live[${JSON.stringify(tab)}]?.isLoading`), 15000);
      const id = await resourceSessionId(tab);
      await resourceArguments("ac_tabs_cpu");
      const sample = async () => resourceRows(await resourceCall("ac_tabs_cpu", { tabIds: [id, id] }), [id], "cpu").find((row) => row.tabId === id) ?? null;
      const baseline = await until("the production attribution CPU monitor with default health sampling disabled", sample, 15000);
      await sleep(2000);
      const idle = await sample();
      assert.ok(idle, "the idle sample is available");
      assert.equal(idle.measurementId, baseline.measurementId);
      assert.ok(idle.elapsedMs > baseline.elapsedMs && idle.cpuMs >= baseline.cpuMs);
      const idlePercent = 100 * (idle.cpuMs - baseline.cpuMs) / (idle.elapsedMs - baseline.elapsedMs);
      const code = `window.__api38Busy = true; window.__api38BusyEnd = performance.now() + 10000; const tick = () => { if (!window.__api38Busy || performance.now() >= window.__api38BusyEnd) return; const end = performance.now() + 35; while (performance.now() < end) Math.sqrt(Math.random()); window.__api38BusyTimer = setTimeout(tick, 0); }; window.__api38BusyTimer = setTimeout(tick, 0); true`;
      await evalApp(`return ac.webviews.get(${JSON.stringify(tab)}).executeJavaScript(${JSON.stringify(code)})`, 5000);
      await sleep(3500);
      const busy = await sample();
      assert.ok(busy, "the busy sample is available");
      assert.equal(busy.measurementId, idle.measurementId);
      assert.ok(busy.elapsedMs > idle.elapsedMs && busy.cpuMs > idle.cpuMs + 10);
      const busyPercent = 100 * (busy.cpuMs - idle.cpuMs) / (busy.elapsedMs - idle.elapsedMs);
      assert.ok(busyPercent > idlePercent * 1.25 + 1, `same-tab busy CPU ${busyPercent}% did not exceed idle ${idlePercent}%`);
      await evalApp(`return ac.webviews.get(${JSON.stringify(tab)}).executeJavaScript("window.__api38Busy = false; clearTimeout(window.__api38BusyTimer); true")`, 5000);
      resourceRows(await resourceRace("ac_tabs_cpu", id, `ac.store.getState().navigate(${JSON.stringify(tab)}, "${base}/c?api38-cpu-next", { userInitiated: true })`), [id], "cpu");
      await until("the scratch CPU navigation", () => evalApp(`const s = ac.store.getState(); return s.tabs[${JSON.stringify(tab)}]?.url === "${base}/c?api38-cpu-next" && !s.live[${JSON.stringify(tab)}]?.isLoading`), 15000);
      await closeTab(tab);
      tab = null;
      await until("the closed scratch page omitted from CPU", async () => resourceRows(await resourceCall("ac_tabs_cpu", { tabIds: [id] }), [id], "cpu").length === 0, 10000);
      assert.deepEqual((await state()).profiles, profiles);
      return { baseline, idle, busy, idlePercent, busyPercent, comparison: "same-tab idle and busy intervals", closedOmitted: true };
    } finally {
      if (tab) {
        await evalApp(`return ac.webviews.get(${JSON.stringify(tab)})?.executeJavaScript("window.__api38Busy = false; clearTimeout(window.__api38BusyTimer); true")`, 5000).catch(() => null);
        await closeTab(tab).catch(() => null);
      }
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(first.id)}); return true`).catch(() => null);
    }
  });

  await check("module-events", async () => {
    await evalApp(`globalThis.__acEvents = []; globalThis.__acSubs?.forEach((x) => x.remove());
      globalThis.__acSubs = [globalThis.expo.modules.SolaraCEF.addListener("onContentBlocker", (e) => globalThis.__acEvents.push(["blocker", e])),
        globalThis.expo.modules.SolaraExtensions.addListener("onChanged", (e) => globalThis.__acEvents.push(["extensions", e]))]; return true`);
    try {
      await evalApp(`return globalThis.expo.modules.SolaraCEF.setContentBlockerEnabled(false)`);
      await evalApp(`return globalThis.expo.modules.SolaraCEF.setContentBlockerEnabled(true)`);
      const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
      const configured = await exts(`configure("${installed.id}", "", { incognito: true })`);
      if (configured?.error) throw new Error(`configure: ${configured.error}`);
      await exts(`uninstall("${installed.id}", "")`);
      const events = await until("both events", async () => {
        const list = await evalApp(`return globalThis.__acEvents`);
        return list.some((x) => x[0] === "blocker") && list.filter((x) => x[0] === "extensions").length >= 2 ? list : null;
      }, 15000).catch(async (e) => { throw new Error(`${e.message}; got ${JSON.stringify(await evalApp(`return globalThis.__acEvents`)).slice(0, 300)}`); });
      const sources = await evalApp(`return globalThis.expo.modules.SolaraCEF.displayMediaSources()`);
      if (!sources.some((x) => x.kind === "screen")) throw new Error("no screen among the display media sources");
      return { blocker: events.filter((x) => x[0] === "blocker").length, extensions: events.filter((x) => x[0] === "extensions").map((x) => x[1].event), configured: true, sources: sources.length };
    } finally {
      await evalApp(`globalThis.__acSubs?.forEach((x) => x.remove()); return true`);
    }
  });

  const closeDownloads = () => evalApp(`ac.store.getState().setDownloadsOpen(${JSON.stringify(mainWindow)}, false); return true`).catch(() => null);

  await check("save-page", async () => {
    const file = join(scratch, "saved-page.html");
    writeFileSync(join(data, "file-chooser.txt"), file + "\n");
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await evalApp(`return ac.webviews.get("${first.id}").runPageCommand("savePage")`);
    try {
      const saved = await until("the saved page", async () => existsSync(file) && readFileSync(file, "utf8").includes("Page A"), 15000);
      await until("the saved page in the app's downloads", () =>
        evalApp(`return ac.store.getState().downloads.some((d) => d.state === "finished" && (d.path ?? d.filename ?? "").endsWith("saved-page.html"))`), 10000);
      return { saved };
    } finally {
      await closeDownloads();
    }
  });

  await check("activate-request", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    const t = await pageFor(first.id, `${base}/a`);
    const before = new Set((await state()).tabs.map((x) => x.id));
    await cdp(t, "Runtime.evaluate", { expression: `window.__popup = window.open("${base}/c?focus-me", "_blank"); true`, userGesture: true });
    const popup = await until("the popup", async () => (await state()).tabs.find((x) => !before.has(x.id) && x.title === "Page C" && !x.loading), 10000);
    try {
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A shown", async () => (await state()).active === first.id);
      await cdp(t, "Runtime.evaluate", { expression: "window.__popup.focus(); true", userGesture: true });
      const e = await until("onActivateRequest", async () => (await eventsOf(popup.id)).findLast((x) => x.name === "activateRequest"), 8000)
        .catch(async (err) => { throw new Error(`${err.message}; popup events ${JSON.stringify((await eventsOf(popup.id)).map((x) => x.name).slice(-8))}`); });
      return { reason: e.payload.reason };
    } finally {
      await closeTab(popup.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("private-release", async () => {
    const a = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${base}/cookie?private1" })`);
    await until("the private cookie set", async () => {
      const tabs = await evalApp(`const s = ac.store.getState(); return (s.windows["${a}"]?.tabIds ?? []).map((i) => s.tabs[i]?.title)`);
      return tabs.includes("Cookie") ? true : null;
    }, 10000);
    await sleep(500);
    await evalApp(`ac.store.getState().closeWindow("${a}"); return true`);
    await sleep(2000);
    const b = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${base}/b?private2" })`);
    try {
      await until("the second private window's page", async () => {
        const tabs = await evalApp(`const s = ac.store.getState(); return (s.windows["${b}"]?.tabIds ?? []).map((i) => s.tabs[i]?.title)`);
        return tabs.includes("Page B") ? true : null;
      }, 10000);
      const pt = await pageTarget(`${base}/b?private2`);
      const cookie = (await cdp(pt, "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
      if (cookie.includes("private1")) throw new Error(`the first private window's cookie survived: ${cookie}`);
      return { cookie: cookie || "(none)" };
    } finally {
      await evalApp(`ac.store.getState().closeWindow("${b}"); return true`);
    }
  });

  await check("private-churn", async () => {
    const titles = (w) => evalApp(`const s = ac.store.getState(); return (s.windows[${JSON.stringify(w)}]?.tabIds ?? []).map((i) => s.tabs[i]?.title)`);
    let last = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${base}/e?churn-start" })`);
    const waits = [];
    try {
      await until("the first private page", async () => ((await titles(last)).includes("Page E") ? true : null), 15000);
      for (let round = 0; round < 50; round++) {
        const started = Date.now();
        const next = await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(last)}); return ac.actions.openWindow({ incognito: true, url: "${base}/e?churn${round}" })`);
        last = next;
        await until(`round ${round}: a live tab`, async () => ((await titles(next)).includes("Page E") ? true : null), 15000);
        waits.push(Date.now() - started);
        if (round % 2) {
          await sleep(1200);
          const after = await titles(next);
          if (!after.includes("Page E")) throw new Error(`round ${round}: the tab went: ${JSON.stringify(after)}`);
        }
      }
      for (let round = 0; round < 10; round++)
        last = await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(last)}); return ac.actions.openWindow({ incognito: true, url: "${base}/e?burst${round}" })`);
      await until("the burst's last window: a live tab", async () => ((await titles(last)).includes("Page E") ? true : null), 15000);
      await sleep(1500);
      if (!(await titles(last)).includes("Page E")) throw new Error(`the burst's last tab went: ${JSON.stringify(await titles(last))}`);
      if (exited) throw new Error("the app exited");
      return { rounds: 50, burst: 10, slowestMs: Math.max(...waits), medianMs: waits.sort((a, b) => a - b)[25] };
    } finally {
      await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(last)}); return true`).catch(() => null);
    }
  });

  // MARK: Chrome services and extensions

  const nativeExtensionPopup = async (windowId = mainWindow) => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraToolbar.devExtensionPopup(${JSON.stringify(windowId)})`));

  await check("extension-popup-and-panel", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const windowsBefore = (await cef(`chromeWindows()`)).length;
    try {
      await evalApp(`return ac.extensions.refreshExtensions("").then(() => true)`);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await evalApp(`const lists = ac.extensions.useExtensions.getState().lists; const ext = Object.values(lists).flat().find((x) => x.id === "${installed.id}");
        return ac.extensions.activateExtension(${JSON.stringify(mainWindow)}, ext, { x: 100, y: 40, width: 20, height: 20 }).then(() => true)`);
      await until("the native popup frame", async () => (await nativeExtensionPopup())?.frame ?? null, 8000);
      const popupTarget = await until("the popup page", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${installed.id}/popup.html`)), 10000);
      const strips = await cef(`tabStrips()`);
      const inStrip = strips.strips.some((st) => st.tabs.some((x) => x.key == null));
      const popupVisible = (await cdp(popupTarget, "Runtime.evaluate", { expression: "document.visibilityState", returnByValue: true })).result.value;
      const pageSize = async (t) => (await cdp(t, "Runtime.evaluate", { expression: "[innerWidth, innerHeight]", returnByValue: true })).result.value;
      const grown = await until("the popup sized to its page", async () => { const s = await pageSize(popupTarget); return s[0] > 100 ? s : null; }, 5000);
      await cdp(popupTarget, "Runtime.evaluate", { expression: "document.body.style.height = '30px'" });
      const shrunk = await until("the popup shrunk with its page", async () => { const s = await pageSize(popupTarget); return s[1] < grown[1] ? s : null; }, 5000)
        .catch(async () => { throw new Error(`the popup kept its size: ${JSON.stringify(grown)} → ${JSON.stringify(await pageSize(popupTarget))}`); });
      await cdp(popupTarget, "Runtime.evaluate", { expression: "window.__acOld = 1" });
      const worker = await until("the extension's worker", async () =>
        (await targets()).find((t) => t.type === "service_worker" && t.url.includes(`${installed.id}/worker.js`)) ?? null, 10000);
      const opened = (await cdp(worker, "Runtime.evaluate", { expression: "chrome.action.openPopup().then(() => 'ok', (e) => e.message)", awaitPromise: true, returnByValue: true })).result.value;
      if (opened !== "ok") throw new Error(`chrome.action.openPopup(): ${opened}`);
      await until("the popup reopened", async () => {
        const t = (await targets()).find((x) => x.type === "page" && x.url.includes(`${installed.id}/popup.html`));
        return t && (await cdp(t, "Runtime.evaluate", { expression: "window.__acOld === undefined", returnByValue: true })).result.value ? t : null;
      }, 8000);
      await evalApp(`ac.extensions.closeExtensionPopup(); return true`);
      await until("the popup gone", async () => !(await targets()).some((t) => t.url.includes(`${installed.id}/popup.html`)), 8000);
      await evalApp(`return ac.extensions.openSidePanel(${JSON.stringify(mainWindow)}, "${installed.id}").then(() => !!ac.extensions.useExtensions.getState().sidePanels[${JSON.stringify(mainWindow)}])`);
      const panelTarget = await until("the side panel page", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${installed.id}/panel.html`)), 10000);
      const panelVisible = (await cdp(panelTarget, "Runtime.evaluate", { expression: "document.visibilityState", returnByValue: true })).result.value;
      const stripsWithPanel = await cef(`tabStrips()`);
      const panelInStrip = stripsWithPanel.strips.some((st) => st.tabs.length !== strips.strips.find((x) => x.strip === st.strip)?.tabs.length);
      await evalApp(`ac.extensions.closeSidePanel(${JSON.stringify(mainWindow)}); return true`);
      await until("the panel gone", async () => !(await targets()).some((t) => t.url.includes(`${installed.id}/panel.html`)), 8000);
      const windowsAfter = await until("the standalone window closed", async () => {
        const n = (await cef(`chromeWindows()`)).length;
        return n <= windowsBefore ? n : null;
      }, 8000).catch(async () => (await cef(`chromeWindows()`)).length);
      if (inStrip || panelInStrip) throw new Error("a standalone WebView's tab is in the window's strip");
      if (popupVisible !== "visible" || panelVisible !== "visible") throw new Error(`popup ${popupVisible}, panel ${panelVisible}`);
      return { popup: popupVisible, panel: panelVisible, popupSize: `${grown.join("x")} → ${shrunk.join("x")}`, openPopup: opened, windowsBefore, windowsAfter };
    } finally {
      await evalApp(`ac.extensions.closeExtensionPopup(); ac.extensions.closeSidePanel(${JSON.stringify(mainWindow)}); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`);
    }
  });

  await check("print-preview", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await evalApp(`return ac.webviews.get("${first.id}").print()`);
    const preview = await until("the print preview", async () => (await targets()).find((t) => t.url.startsWith("chrome://print")), 15000);
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a?after-print", { userInitiated: true }); return true`);
    await until("the preview closed", async () => !(await targets()).some((t) => t.url.startsWith("chrome://print")), 10000);
    await backToA();
    return { preview: preview.url };
  });

  await check("extension-prompts", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    try {
      await evalApp(`return ac.extensions.refreshExtensions("").then(() => true)`);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      const activate = () => evalApp(`const lists = ac.extensions.useExtensions.getState().lists; const ext = Object.values(lists).flat().find((x) => x.id === "${installed.id}");
        return ac.extensions.activateExtension(${JSON.stringify(mainWindow)}, ext, { x: 100, y: 40, width: 20, height: 20 }).then(() => true)`);
      await activate();
      const popup = await until("the popup page", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${installed.id}/popup.html`)), 10000);
      await cdp(popup, "Runtime.evaluate", { expression: "chrome.permissions.remove({ permissions: ['bookmarks'] }).then(() => true)", awaitPromise: true });
      await cdp(popup, "Runtime.evaluate", { expression: "window.__perm = 'pending'; chrome.permissions.request({ permissions: ['bookmarks'] }).then((g) => (window.__perm = String(g)), (e) => (window.__perm = String(e))); true", userGesture: true });
      const request = await until("the app's install dialog", async () => evalApp(`return ac.extensions.useExtensions.getState().install ?? null`), 10000);
      const requestId = request.requestId ?? request.prompt?.requestId ?? request.request?.requestId;
      await exts(`resolveInstallPrompt(${JSON.stringify(requestId)}, true)`);
      const granted = await until("the page's answer", async () => {
        const v = (await cdp(popup, "Runtime.evaluate", { expression: "window.__perm", returnByValue: true })).result.value;
        return v !== "pending" ? v : null;
      }, 10000);
      if (granted !== "true") throw new Error(`permissions.request answered ${granted}`);
      await evalApp(`ac.extensions.closeExtensionPopup(); return true`);
      const worker = await extensionWorker(installed.id, "sidePanel.open");
      await cdp(worker, "Runtime.evaluate", { expression: "chrome.action.setPopup({ popup: '' }); chrome.action.onClicked.addListener((tab) => chrome.sidePanel.open({ tabId: tab.id })); true" });
      await sleep(300);
      await activate();
      const panel = await until("the side panel", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${installed.id}/panel.html`)), 10000);
      const shown = await evalApp(`return !!ac.extensions.useExtensions.getState().sidePanels[${JSON.stringify(mainWindow)}]`);
      return { prompt: request.type ?? request.prompt?.type ?? Object.keys(request), granted, panel: !!panel, shown };
    } finally {
      await evalApp(`ac.extensions.closeExtensionPopup(); ac.extensions.closeSidePanel(${JSON.stringify(mainWindow)}); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`);
    }
  });

  await check("extension-prompt-closed", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const click = () => evalApp(`return ac.shell.devClick(${JSON.stringify(mainWindow)}, { in: "page", x: 200, y: 200, asKey: false })`);
    const ask = async () => {
      await evalApp(`const lists = ac.extensions.useExtensions.getState().lists; const ext = Object.values(lists).flat().find((x) => x.id === "${installed.id}");
        return ac.extensions.activateExtension(${JSON.stringify(mainWindow)}, ext, { x: 100, y: 40, width: 20, height: 20 }).then(() => true)`);
      const popup = await until("the popup page", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${installed.id}/popup.html`)), 10000);
      await cdp(popup, "Runtime.evaluate", { expression: "chrome.permissions.remove({ permissions: ['bookmarks'] }).then(() => true)", awaitPromise: true });
      await cdp(popup, "Runtime.evaluate", { expression: "chrome.permissions.request({ permissions: ['bookmarks'] }); true", userGesture: true });
      return until("the app's install dialog", async () => evalApp(`return ac.extensions.useExtensions.getState().install?.prompt ?? null`), 10000);
    };
    try {
      await evalApp(`return ac.extensions.refreshExtensions("").then(() => true)`);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      const before = (await click()).hit;
      const prompt = await ask();
      const covered = (await click()).hit;
      await exts(`resolveInstallPrompt(${JSON.stringify(prompt.requestId)}, true)`);
      await sleep(1000);
      const left = await evalApp(`return ac.extensions.useExtensions.getState().install?.status ?? null`);
      await evalApp(`ac.extensions.closeExtensionPopup(); return true`);
      await sleep(500);
      const answered = (await click()).hit;
      if (left !== null || answered !== before) throw new Error(`after the engine-side answer the dialog is ${left ?? "gone"} and a click lands on ${answered}, not ${before} (under the dialog: ${covered})`);
      const second = await ask();
      await evalApp(`ac.extensions.closeExtensionPopup(); return true`);
      await until("the dialog to go when its popup closes", async () => ((await evalApp(`return ac.extensions.useExtensions.getState().install === null`)) === true ? true : null), 5000);
      const closed = (await click()).hit;
      if (closed !== before) throw new Error(`after the popup closed a click lands on ${closed}, not ${before}`);
      return { before, covered, answered, closed, requests: [prompt.requestId, second.requestId] };
    } finally {
      await evalApp(`ac.extensions.cancelInstall(); ac.extensions.closeExtensionPopup(); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`);
    }
  });

  await check("extension-sheet-native", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    let tab = null;
    const snapshot = async () => {
      const value = await instance.snapshot({ fields: ["windows.sheet"] });
      assert.ok(value.capabilities?.available?.includes("windows.sheet"));
      const window = value.windows.find((w) => w.id === mainWindow);
      assert.ok(window, "the sheet's window is in the native snapshot");
      return window.sheet;
    };
    const pageFocus = () => until("focus restored to the shown page", async () => {
      const value = await nativeExtensionPopup(mainWindow);
      return value?.focusedTabId === tab && !value.omniboxFocused ? true : null;
    }, 5000);
    const clickScrim = async (sheet) => {
      const x = sheet.scrim[0] + 20;
      const y = sheet.scrim[1] + sheet.scrim[3] / 2;
      assert.ok(x < sheet.card[0] - 30, "the scrim click is well outside the card");
      const result = await evalApp(`return ac.shell.devClick(${JSON.stringify(mainWindow)}, { x: ${x}, y: ${y}, asKey: false })`);
      if (result.error) throw new Error(result.error);
      return result.hit;
    };
    const gone = async () => {
      await until("the native sheet removed", async () => (await snapshot()) === null, 5000);
      await pageFocus();
    };
    try {
      await evalApp(`return ac.extensions.refreshExtensions("").then(() => true)`);
      extensionPagesOpenedAsTabs.add(`chrome-extension://${installed.id}/popup.html`);
      tab = await freshTab(`chrome-extension://${installed.id}/popup.html`);
      const page = await until("the extension page", () => pageFor(tab, `${installed.id}/popup.html`), 10000);
      await cdp(page, "Runtime.evaluate", { expression: "chrome.permissions.remove({ permissions: ['bookmarks'] }).then(() => true)", awaitPromise: true });
      await evalApp(`return ac.webviews.get(${JSON.stringify(tab)}).focus()`);
      const ask = async () => {
        await cdp(page, "Runtime.evaluate", {
          expression: "window.__perm = 'pending'; chrome.permissions.request({ permissions: ['bookmarks'] }).then((granted) => (window.__perm = String(granted)), (error) => (window.__perm = String(error))); true",
          userGesture: true,
        });
        const prompt = await until("the permission request", () => evalApp(`return ac.extensions.useExtensions.getState().install?.prompt ?? null`), 10000);
        const sheet = await until("the native permission sheet", async () => {
          const value = await snapshot();
          return value?.kind === "install" ? value : null;
        }, 5000);
        assert.equal(sheet.key, prompt.requestId);
        assert.equal(sheet.busy, false);
        assert.equal(sheet.focusInSheet, true);
        assert.ok(Math.abs(sheet.card[2] - 380) <= 0.5, `card width ${sheet.card[2]}`);
        const window = (await nativeExtensionPopup(mainWindow)).window;
        assert.ok(Math.abs(sheet.card[0] + sheet.card[2] / 2 - window[0] / 2) <= 0.5, "the card is horizontally centred in the window");
        return { prompt, sheet };
      };
      const cancelled = async () => {
        await until("install state cleared", () => evalApp(`return ac.extensions.useExtensions.getState().install === null`), 5000);
        const answer = await until("the page's permission answer", async () => {
          const value = (await cdp(page, "Runtime.evaluate", { expression: "window.__perm", returnByValue: true })).result.value;
          return value !== "pending" ? value : null;
        }, 5000);
        assert.equal(answer, "false");
        await gone();
        return answer;
      };
      const firstPrompt = await ask();
      const installHit = await clickScrim(firstPrompt.sheet);
      const scrimAnswer = await cancelled();
      const second = await ask();
      assert.notEqual(second.prompt.requestId, firstPrompt.prompt.requestId);
      const escape = await evalApp(`return ac.shell.devKeyEquivalent(${JSON.stringify(mainWindow)}, { key: "\\u001b", keyCode: 53, modifiers: [] })`);
      if (escape.error) throw new Error(escape.error);
      const escapeAnswer = await cancelled();
      await evalApp(`ac.extensions.useExtensions.setState({ pinDialog: { windowId: ${JSON.stringify(mainWindow)} } }); return true`);
      const pins = await until("the native pin sheet", async () => {
        const value = await snapshot();
        return value?.kind === "pins" ? value : null;
      }, 5000);
      assert.equal(pins.key, "pins");
      const pinsHit = await clickScrim(pins);
      await until("the pin dialog closed", () => evalApp(`return ac.extensions.useExtensions.getState().pinDialog === null`), 5000);
      await gone();
      return { card: firstPrompt.sheet.card, scrimAnswer, escapeAnswer, installHit, pinsHit, requests: [firstPrompt.prompt.requestId, second.prompt.requestId] };
    } finally {
      await evalApp(`ac.extensions.cancelInstall(); ac.extensions.useExtensions.setState({ pinDialog: null }); return true`).catch(() => null);
      if (tab) await closeTab(tab).catch(() => null);
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(first.id)}); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`);
    }
  });

  await check("crash", async () => {
    await evalApp(`ac.actions.openUrls(["${base}/crash-me"], ${JSON.stringify(mainWindow)}); return true`);
    const tab = await until("the tab to crash", async () => (await state()).tabs.find((x) => x.url?.includes("crash-me") && x.title === "/crash-me" && x.loading === false));
    const t = await pageTarget("crash-me");
    cdp(t, "Page.crash").catch(() => null);
    const crashed = await until("onCrashed", async () => evalApp(`return ac.pageState.getState().pages["${tab.id}"]?.crashed ?? null`), 10000);
    return { crashed };
  });

  await check("traffic-lights-after-profile-switch", async () => {
    const s = await state();
    const browser = await browserOf(first.id);
    const windowNumber = await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindowNumber(${browser})`);
    const lights = () => evalApp(`return globalThis.expo.modules.SolaraCEF.devWindow(${windowNumber}, "lights")`);
    const before = await lights();
    const id = await evalApp(`return ac.store.getState().createProfile({ name: "Lights" })`);
    await evalApp(`ac.actions.switchProfile("${s.windowId}", "${id}"); return true`);
    await until("profile shown", async () => (await state()).profileId === id);
    await sleep(500);
    const during = await lights();
    await evalApp(`ac.actions.switchProfile("${s.windowId}", "${s.profileId}"); return true`);
    await until("profile back", async () => (await state()).profileId === s.profileId);
    await sleep(500);
    const after = await lights();
    if (during !== before || after !== before) throw new Error(`lights moved: ${before} → ${during} → ${after}`);
    return { lights: before };
  });


  await check("passwords", async () => {
    const origin = "https://example.test";
    const saved = await cef(`savePassword("", "${origin}", "nnuser", "s3cret")`);
    if (saved?.error) throw new Error(saved.error);
    const list = await until("the saved login", async () => {
      const r = await cef(`listPasswords("")`);
      return r.passwords?.find((p) => p.username === "nnuser") ? r : null;
    });
    const revealed = await cef(`getPassword("", "${origin}", "nnuser")`);
    await cef(`deletePassword("", "${origin}", "nnuser")`);
    const after = await cef(`listPasswords("")`);
    if (after.passwords?.some((p) => p.username === "nnuser")) throw new Error("not deleted");
    const autofill = await cef(`getPasswordAutofill("")`);
    await cef(`setPasswordAutofill("", false)`);
    const off = await cef(`getPasswordAutofill("")`);
    await cef(`setPasswordAutofill("", true)`);
    return { listed: list.passwords.length, revealed: revealed?.password ?? revealed, autofill, off };
  });

  await check("autofill", async () => {
    const saved = await cef(`saveAddress("", { fullName: "The mascot", city: "Tel Aviv", country: "IL" })`);
    if (saved?.error) throw new Error(saved.error);
    const list = await until("the address", async () => {
      const r = await cef(`listAddresses("")`);
      return r.addresses?.length ? r : null;
    });
    const id = list.addresses[0].id;
    await cef(`deleteAutofillEntry("", "${id}")`);
    const settings = await cef(`getAutofillSettings("")`);
    return { addresses: list.addresses.length, first: list.addresses[0].fullName ?? list.addresses[0].name, settings };
  });

  await check("zoom-levels", async () => {
    await cef(`setZoom("", "zoom.test", 1.5)`);
    const levels = await until("the zoom level", async () => {
      const l = await cef(`getZoomLevels("")`);
      return l["zoom.test"] ? l : null;
    });
    await cef(`setZoom("", "zoom.test", 1)`);
    return { levels };
  });

  await check("extensions", async () => {
    const inspected = await exts(`inspectUnpacked(${JSON.stringify(extPath)})`);
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const list = await until("the extension listed", async () => {
      const r = await exts(`list("")`);
      return r.extensions?.find((e) => e.id === installed.id) ? r : null;
    });
    await exts(`setEnabled("${installed.id}", "", false)`);
    await exts(`uninstall("${installed.id}", "")`);
    const engines = await exts(`searchEngineList("")`);
    return { id: installed.id, name: inspected.name, listed: list.extensions.length, engines: !!engines.list };
  });

  await check("extension-configure", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const id = installed.id;
    const info = async () => (await exts(`list("")`)).extensions?.find((e) => e.id === id) ?? null;
    const configure = async (options) => {
      const r = await exts(`configure("${id}", "", ${JSON.stringify(options)})`);
      if (r?.error) throw new Error(`configure ${JSON.stringify(options)}: ${r.error}`);
    };
    const scriptRan = async (tag) => {
      const tab = await openTab(`${base}/e?cfg-${tag}`, "Page E");
      try {
        const t = await pageFor(tab.id, `/e?cfg-${tag}`);
        const deadline = Date.now() + 2500;
        while (Date.now() < deadline) {
          const r = await cdp(t, "Runtime.evaluate", { expression: "document.documentElement.dataset.nnext ?? null", returnByValue: true });
          if (r.result.value) return r.result.value;
          await sleep(200);
        }
        return null;
      } finally {
        await closeTab(tab.id);
      }
    };
    await evalApp(`globalThis.__acCfg = []; globalThis.__acCfgSub?.remove();
      globalThis.__acCfgSub = globalThis.expo.modules.SolaraExtensions.addListener("onChanged", (e) => globalThis.__acCfg.push(e)); return true`);
    try {
      const before = await until("the extension listed", info);
      if (!before.siteAccess) throw new Error("the fixture has no site access to change");
      if (!(await scriptRan("before"))) throw new Error("the content script didn't run before any change");
      const set = { pinned: !before.pinned, incognito: !before.incognito, fileAccess: !before.fileAccess };
      for (const [key, value] of Object.entries(set)) {
        await configure({ [key]: value });
        await until(`${key} = ${value}`, async () => (await info())?.[key] === value);
      }
      await configure({ siteAccess: "onClick" });
      const onClick = await until("site access on click", async () => {
        const e = await info();
        return e?.siteAccess === "ON_CLICK" ? e : null;
      });
      const ranOnClick = await scriptRan("onclick");
      if (ranOnClick) throw new Error(`the content script ran with site access on click (${ranOnClick})`);
      await configure({ siteAccess: "allSites" });
      const allSites = await until("site access on all sites", async () => {
        const e = await info();
        return e?.siteAccess === "ON_ALL_SITES" ? e : null;
      });
      const ranAgain = await scriptRan("allsites");
      if (!ranAgain) throw new Error("the content script didn't run again on all sites");
      const configured = await until("onChanged configured", async () => {
        const list = await evalApp(`return globalThis.__acCfg`);
        const mine = list.filter((x) => x.event === "configured" && x.id === id);
        return mine.length >= 5 ? mine : null;
      }, 10000).catch(async (e) => { throw new Error(`${e.message}; got ${JSON.stringify(await evalApp(`return globalThis.__acCfg`)).slice(0, 300)}`); });
      await configure({ pinned: before.pinned, incognito: before.incognito, fileAccess: before.fileAccess });
      return {
        set,
        siteAccess: [before.siteAccess, onClick.siteAccess, allSites.siteAccess],
        contentScript: { onClick: ranOnClick, allSites: ranAgain },
        configuredEvents: configured.length,
      };
    } finally {
      await evalApp(`globalThis.__acCfgSub?.remove(); return true`).catch(() => null);
      await exts(`uninstall("${id}", "")`).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`).catch(() => null);
    }
  });

  await check("chrome-windows-create", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const worker = await extensionWorker(installed.id, "windows.create");
    const made = await cdp(worker, "Runtime.evaluate", {
      expression: `chrome.windows.create({ url: "${base}/e?window" }).then((w) => JSON.stringify({ id: w.id, tabs: w.tabs?.length }))`,
      awaitPromise: true,
      returnByValue: true,
    });
    log("  chrome.windows.create:", JSON.stringify(made.result?.value ?? made.exceptionDetails?.exception?.description ?? made));
    const tab = await until("the window's tab in the app", async () => {
      const tabs = await evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).map((t) => ({ id: t.id, url: t.url, adoptId: t.adoptId, windowId: t.windowId }))`);
      return tabs.find((t) => t.url?.includes("e?window")) ?? null;
    }, 15000);
    try {
      if (tab.windowId === mainWindow) throw new Error("the window's tab landed in the run's window, not a new one");
      const created = JSON.parse(made.result?.value ?? "{}");
      const strip = await until("the new window's strip", async () => (await cef(`tabStrips()`)).strips.find((st) => st.appWindow === tab.windowId && st.tabs.length) ?? null, 10000);
      if (strip.strip !== created.id) throw new Error(`chrome.windows.create answered window ${created.id}, the app shows ${strip.strip}`);
      return { tab: tab.id, adoptId: tab.adoptId ?? null, window: tab.windowId, chromeWindow: created.id };
    } finally {
      if (tab.windowId !== mainWindow) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(tab.windowId)}); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
    }
  });

  await check("chrome-windows-remove", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const worker = await extensionWorker(installed.id, "windows.remove");
    const inWorker = async (expression) => {
      const r = await cdp(worker, "Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? JSON.stringify(r.exceptionDetails));
      return r.result?.value;
    };
    const tabIdOf = (m) => until(`the store tab for ${m}`, async () => (await storeTabs()).find((t) => t.url?.includes(`e?${m}`))?.id, 10000);
    const storeTabs = () => evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).map((t) => ({ id: t.id, url: t.url, windowId: t.windowId, windowOpen: !!s.windows[t.windowId] }))`);
    const pages = async (marks) => (await targets()).filter((t) => t.type === "page" && marks.some((m) => t.url.includes(m))).map((t) => t.url.split("?")[1]);
    const before = (await storeTabs()).filter((t) => t.windowId === mainWindow).map((t) => t.id).sort();
    const made = [];
    const openWindow = async (marks, beforeunload) => {
      const id = await inWorker(`chrome.windows.create({ url: ${JSON.stringify(marks.map((m) => `${base}/e?${m}`))} }).then((w) => w.id)`);
      const appWindow = await until(`the app window for ${marks}`, async () => {
        const tabs = (await storeTabs()).filter((t) => marks.some((m) => t.url?.includes(`e?${m}`)));
        return tabs.length === marks.length && new Set(tabs.map((t) => t.windowId)).size === 1 ? tabs[0].windowId : null;
      }, 15000);
      made.push(appWindow);
      if (appWindow === mainWindow) throw new Error("the extension's window landed in the run's window");
      await until(`${marks} loaded`, async () => (await pages(marks)).length === marks.length, 15000);
      for (const m of beforeunload) {
        const page = await pageTarget(`e?${m}`);
        await cdp(page, "Runtime.evaluate", { expression: "addEventListener('beforeunload', () => {}); true" });
      }
      return { id, appWindow };
    };
    const remove = async (marks, keep, beforeunload = []) => {
      const { id, appWindow } = await openWindow(marks, beforeunload);
      if (keep && (await cef(`devKeepTabsOnClose(${keep})`)) < 0) throw new Error("devKeepTabsOnClose needs a Debug build");
      await inWorker(`chrome.windows.remove(${id}).then(() => true)`);
      const kept = marks.slice(0, keep), closed = marks.slice(keep);
      const live = await until(`windows.remove of ${marks} (keeping ${keep})`, async () => {
        const now = await pages(marks);
        return closed.every((m) => !now.includes(m)) ? now : null;
      }, 15000);
      await sleep(500);
      const after = await pages(marks);
      if (kept.some((m) => !after.includes(m))) throw new Error(`kept pages closed: wanted ${kept}, live ${after}`);
      const store = (await storeTabs()).filter((t) => t.windowId === appWindow);
      const left = await inWorker(`chrome.windows.getAll().then((ws) => ws.some((w) => w.id === ${id}))`);
      if (left) throw new Error(`chrome.windows.getAll still lists window ${id}`);
      return { marks, keep, beforeunload, live, afterSettle: after, storeTabsLeft: store.map((t) => t.url.split("?")[1]) };
    };
    try {
      const plain = await remove(["rm-a", "rm-b"], 0);
      const plainStore = await until("the app window closing with chrome.windows.remove", async () => {
        const open = await evalApp(`return !!ac.store.getState().windows[${JSON.stringify(made[0])}]`);
        const left = (await storeTabs()).filter((t) => t.windowId === made[0] || ["e?rm-a", "e?rm-b"].some((m) => t.url?.includes(m)));
        return !open && !left.length ? { windowClosed: true, tabsLeft: 0 } : null;
      }, 10000).catch(async (e) => {
        throw new Error(`${e.message}; store tabs: ${JSON.stringify((await storeTabs()).filter((t) => t.windowId === made[0]))}`);
      });
      const unload = await remove(["rm-c", "rm-d"], 0, ["rm-c"]);
      const keepOne = await remove(["rm-e", "rm-f"], 1, ["rm-f"]);
      const keepAll = await remove(["rm-g", "rm-h"], 2);
      const cancelled = await (async () => {
        const marks = ["rm-i", "rm-j"];
        const { id, appWindow } = await openWindow(marks, []);
        const target = await pageTarget("e?rm-i");
        await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
        const ws = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error("DevTools connection failed")))));
        let leave = false;
        const prompts = [];
        ws.onmessage = (m) => {
          const msg = JSON.parse(m.data);
          if (msg.method !== "Page.javascriptDialogOpening") return;
          prompts.push({ type: msg.params.type, leave });
          ws.send(JSON.stringify({ id: 100 + prompts.length, method: "Page.handleJavaScriptDialog", params: { accept: leave } }));
        };
        ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
        try {
          await sleep(300);
          const keptBrowser = await browserOf((await tabIdOf("rm-j")));
          await evalApp(`ac.actions.switchToTab(${JSON.stringify((await tabIdOf("rm-i")))}); return true`);
          await sleep(300);
          await cef(`devKeepBrowsersOnClose([${keptBrowser}], [])`);
          await inWorker(`chrome.windows.remove(${id}).then(() => true, () => true)`);
          await until("the beforeunload prompt", async () => prompts.length >= 1, 10000).catch(async (e) => {
            const listed = await inWorker(`chrome.windows.get(${id}, { populate: true }).then((w) => w.tabs.map((t) => t.url), () => "gone")`);
            throw new Error(`${e.message}; live ${JSON.stringify(await pages(marks))}; chrome window ${JSON.stringify(listed)}; activation ${JSON.stringify((await cdp(target, "Runtime.evaluate", { expression: "navigator.userActivation.hasBeenActive", returnByValue: true }).catch(() => null))?.result?.value)}`);
          });
          await sleep(1000);
          const inWindow = await inWorker(`chrome.windows.get(${id}, { populate: true }).then((w) => w.tabs.length, () => -1)`);
          if (inWindow !== 2) throw new Error(`after Stay the window holds ${inWindow} tabs, not 2: the kept tab moved on a cancelled close`);
          const now = await pages(marks);
          if (marks.some((m) => !now.includes(m))) throw new Error(`a page closed though beforeunload said Stay: ${now}`);
          const listed = await inWorker(`chrome.windows.getAll().then((ws) => ws.some((w) => w.id === ${id}))`);
          if (!listed) throw new Error(`window ${id} closed though beforeunload said Stay`);
          const store = (await storeTabs()).filter((t) => t.windowId === appWindow).length;
          if (store !== marks.length) throw new Error(`the store has ${store} of the window's ${marks.length} tabs after Stay`);
          leave = true;
          await inWorker(`chrome.windows.remove(${id}).then(() => true)`);
          await until("the window closing after Leave", async () => (await pages(marks)).length === 0, 15000);
          return { prompts, tabsInWindowAfterStay: inWindow, storeTabsAfterStay: store };
        } finally {
          leave = true;
          setTimeout(() => { try { ws.close(); } catch {} }, 3000);
        }
      })();
      const main = (await storeTabs()).filter((t) => t.windowId === mainWindow).map((t) => t.id).sort();
      if (JSON.stringify(main) !== JSON.stringify(before)) throw new Error(`the run's window changed: ${JSON.stringify(before)} → ${JSON.stringify(main)}`);
      const hostClose = await (async () => {
        const marks = ["rm-k", "rm-l"];
        const { appWindow } = await openWindow(marks, []);
        const target = await pageTarget("e?rm-k");
        await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
        const ws = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error("DevTools connection failed")))));
        const prompts = [];
        ws.onmessage = (m) => {
          const msg = JSON.parse(m.data);
          if (msg.method !== "Page.javascriptDialogOpening") return;
          prompts.push(msg.params.type);
          ws.send(JSON.stringify({ id: 100 + prompts.length, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
        };
        ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
        try {
          await sleep(300);
          const windowNumber = await cef(`devWindowNumber(${await browserOf((await tabIdOf("rm-k")))})`);
          await evalApp(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: false }); return true`);
          await cef(`devKeepBrowsersOnClose([${await browserOf((await tabIdOf("rm-k")))}], [])`);
          const clicked = await cef(`devWindow(${windowNumber}, "close-button")`);
          await until("the window closing", async () => !(await storeTabs()).some((t) => t.windowId === appWindow), 15000);
          await until("rm-l closing", async () => !(await pages(marks)).includes("rm-l"), 15000);
          await sleep(1000);
          const unused = await cef(`devKeepBrowsersOnClose([], [])`);
          const live = await pages(marks);
          if (unused !== 0) throw new Error(`the host close never asked which tabs to keep (knobs left ${unused})`);
          if (!live.includes("rm-k")) throw new Error(`the kept page with beforeunload closed with the window: ${live}`);
          if (prompts.length) throw new Error(`the kept page got a beforeunload prompt: ${prompts}`);
          return { clicked, prompts, live };
        } finally {
          const kept = await pageTarget("e?rm-k").catch(() => null);
          if (kept) await fetch(`http://127.0.0.1:${port}/json/close/${kept.id}`).catch(() => null);
          setTimeout(() => { try { ws.close(); } catch {} }, 3000);
        }
      })();
      const hostCloseFrees = await (async () => {
        const poolIds = () => evalApp(`const pool = globalThis.expo.modules.SolaraTabPool; return pool?.available() ? pool.devPageIds() : null`);
        const baseline = await poolIds();
        const marks = ["rm-q", "rm-r"];
        const { appWindow } = await openWindow(marks, []);
        const ids = [await tabIdOf("rm-q"), await tabIdOf("rm-r")];
        const windowNumber = await cef(`devWindowNumber(${await browserOf(ids[0])})`);
        await cef(`devWindow(${windowNumber}, "close-button")`);
        await until("the window closing", async () => !(await storeTabs()).some((t) => t.windowId === appWindow), 15000);
        await until(`${marks} closing`, async () => (await pages(marks)).length === 0, 15000);
        if (baseline === null) return { pool: false };
        const after = await until("the pool freeing the window's pages", async () => {
          const now = await poolIds();
          return JSON.stringify(now) === JSON.stringify(baseline) ? now : null;
        }, 5000).catch(async (e) => {
          throw new Error(`${e.message}: pool pages ${JSON.stringify(await poolIds())}, baseline ${JSON.stringify(baseline)}, closed ${JSON.stringify(ids)}`);
        });
        return { pool: true, pages: after.length };
      })();
      const sharePinBack = async (tabId, pinKey, appWindow, label) => {
        const copy = await until(`${label}: its copy in another window`, () => evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).find((t) => t.id !== ${JSON.stringify(tabId)} && t.windowId !== ${JSON.stringify(appWindow)} && s.windows[t.windowId] && (t.pinKey ?? t.id) === ${JSON.stringify(pinKey)})?.id ?? null`), 10000);
        await evalApp(`ac.store.getState().activate(${JSON.stringify(copy)}); return true`);
        const frozen = await until(`${label}: its page shown in the other window`, () => evalApp(`const s = ac.store.getState(); return s.tabs[${JSON.stringify(tabId)}]?.windowId !== ${JSON.stringify(appWindow)} ? Object.values(s.tabs).find((t) => t.windowId === ${JSON.stringify(appWindow)} && t.pageIn === ${JSON.stringify(tabId)})?.id ?? null : null`), 10000);
        await evalApp(`ac.store.getState().activate(${JSON.stringify(frozen)}); return true`);
      };
      const poolHoldThroughLeave = await (async () => {
        const poolIds = () => evalApp(`const pool = globalThis.expo.modules.SolaraTabPool; return pool?.available() ? pool.devPageIds() : null`);
        if (await poolIds() === null) return { pool: false };
        const marks = ["rm-hold-pin", "rm-hold-leave"];
        const { appWindow } = await openWindow(marks, []);
        const ids = [await tabIdOf(marks[0]), await tabIdOf(marks[1])];
        const previous = await evalApp(`const s = ac.store.getState(); s.pinTabs([${JSON.stringify(ids[0])}], true); return s.settings.warnBeforeClosingWindow`);
        const pinKey = await evalApp(`return ac.store.getState().tabs[${JSON.stringify(ids[0])}].pinKey ?? ${JSON.stringify(ids[0])}`);
        let ws;
        let prompt = false;
        let leaving = false;
        let windowNumber;
        try {
          await sharePinBack(ids[0], pinKey, appWindow, "the held pin");
          await until("the pinned page mirrored into another window", () => evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).some((t) => t.id !== ${JSON.stringify(ids[0])} && t.windowId !== ${JSON.stringify(appWindow)} && t.pageIn === ${JSON.stringify(ids[0])})`), 10000);
          const target = await pageTarget(`e?${marks[1]}`);
          const installed = await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
          if (installed.exceptionDetails) throw new Error(`installing Leave beforeunload: ${JSON.stringify(installed.exceptionDetails)}`);
          ws = new WebSocket(target.webSocketDebuggerUrl);
          await Promise.race([new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = () => reject(new Error("DevTools connection failed"))))), sleep(5000).then(() => { throw new Error("Leave DevTools connection timed out"); })]);
          let enabled;
          const ready = new Promise((resolve, reject) => {
            enabled = (message) => message.error ? reject(new Error(JSON.stringify(message.error))) : resolve();
          });
          ws.onmessage = (message) => {
            const event = JSON.parse(message.data);
            if (event.id === 1) enabled(event);
            if (event.method !== "Page.javascriptDialogOpening") return;
            prompt = true;
            if (leaving) ws.send(JSON.stringify({ id: 101, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
          };
          ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
          await Promise.race([ready, sleep(5000).then(() => { throw new Error("Page.enable timed out for Leave"); })]);
          const pinBrowser = await browserOf(ids[0]);
          windowNumber = await cef(`devWindowNumber(${await browserOf(ids[1])})`);
          await evalApp(`const s = ac.store.getState(); s.updateSettings({ warnBeforeClosingWindow: false }); s.activate(${JSON.stringify(ids[1])}); return true`);
          await cef(`devKeepBrowsersOnClose([${pinBrowser}], [])`);
          await cef(`devWindow(${windowNumber}, "close-button")`);
          await until("the Leave beforeunload prompt", async () => prompt, 15000);
          for (let sample = 0; sample < 3; sample++) {
            const probe = await evalApp(`const s = ac.store.getState(); const pool = globalThis.expo.modules.SolaraTabPool; return Promise.all([pool.devClosingWindows(), pool.devPageIds()]).then(([holds, pages]) => ({ holds, pages, open: !!s.windows[${JSON.stringify(appWindow)}], survivor: s.tabs[${JSON.stringify(ids[0])}]?.windowId }))`);
            if (probe.open || !probe.survivor || probe.survivor === appWindow) throw new Error(`Leave did not exercise a shared pinned survivor: ${JSON.stringify(probe)}`);
            if (!Object.values(probe.holds).includes(windowNumber) || !probe.pages.includes(ids[1])) throw new Error(`the pool released its hold before Leave finished the close: ${JSON.stringify(probe)}`);
            if (!(await pages(marks)).includes(marks[1])) throw new Error(`the held page's engine page closed before Leave: ${JSON.stringify(probe)}`);
            await sleep(50);
          }
          leaving = true;
          ws.send(JSON.stringify({ id: 101, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
          await until("Leave finishing the Chrome window close", async () => !(await cef(`chromeWindows()`)).some((w) => w.window === windowNumber) && !(await pages(marks)).includes(marks[1]), 15000);
          const holds = await until("the pool releasing the finished Leave hold", async () => {
            const now = await evalApp(`return globalThis.expo.modules.SolaraTabPool.devClosingWindows()`);
            return Object.values(now).includes(windowNumber) ? null : now;
          }, 10000);
          return { pool: true, pinned: ids[0], prompt, holdSamples: 3, holds };
        } finally {
          leaving = true;
          if (prompt) try { ws?.send(JSON.stringify({ id: 102, method: "Page.handleJavaScriptDialog", params: { accept: true } })); } catch {}
          setTimeout(() => { try { ws?.close(); } catch {} }, 3000);
          await cef(`devKeepBrowsersOnClose([], [])`).catch(() => null);
          await evalApp(`const s = ac.store.getState(); s.updateSettings({ warnBeforeClosingWindow: ${JSON.stringify(previous)} }); const pins = Object.values(s.tabs).filter((t) => (t.pinKey ?? t.id) === ${JSON.stringify(pinKey)}); for (const t of pins) { s.pinTabs([t.id], false); s.closeTab(t.id); } return true`).catch(() => null);
        }
      })();
      const poolHeldIdentityChange = await (async () => {
        if (!await evalApp(`return !!globalThis.expo.modules.SolaraTabPool?.available()`)) return { pool: false, skip: "held identity replacement requires the native page pool" };
        for (const call of ["devKeepTabsOnClose(0)", "devFailKeptMoves(0)", "devKeepBrowsersOnClose([], [])"]) {
          if (await cef(call) < 0) throw new Error(`${call} requires a Debug build`);
        }
        const marks = ["rm-identity-pin", "rm-identity-leave"];
        const url = `${base}/e?${marks[0]}`;
        const { appWindow } = await openWindow(marks, []);
        const ids = [await tabIdOf(marks[0]), await tabIdOf(marks[1])];
        const previous = await evalApp(`return ac.store.getState().settings.warnBeforeClosingWindow`);
        const probe = () => evalApp(`const pool = globalThis.expo.modules.SolaraTabPool; return Promise.all([pool.devClosingWindows(), pool.devPageIds(), pool.livePages()]).then(([holds, ids, live]) => { const s = ac.store.getState(); const tab = s.tabs[${JSON.stringify(ids[0])}]; const events = globalThis.__acHeldIdentity; return { holds, ids, live, sourceOpen: !!s.windows[${JSON.stringify(appWindow)}], tab, survivorOpen: !!s.windows[tab?.windowId], created: events?.created ?? 0, gone: events?.gone ?? 0 }; })`);
        const tokenOf = (page) => `${page.engine}|${page.ready?.browserId}`;
        let pinKey;
        let ws;
        let prompt = false;
        let leaving = false;
        let windowNumber;
        try {
          await evalApp(`ac.store.getState().pinTabs([${JSON.stringify(ids[0])}], true); return true`);
          pinKey = await evalApp(`return ac.store.getState().tabs[${JSON.stringify(ids[0])}].pinKey ?? ${JSON.stringify(ids[0])}`);
          await sharePinBack(ids[0], pinKey, appWindow, "the identity pin");
          await until("the identity pin mirrored elsewhere", () => evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).some((t) => t.id !== ${JSON.stringify(ids[0])} && t.windowId !== ${JSON.stringify(appWindow)} && t.pageIn === ${JSON.stringify(ids[0])})`), 10000);
          await until("the identity source shell and pane roots", () => evalApp(`const shell = globalThis.expo.modules.SolaraWindowShell; return !!shell?.active(${JSON.stringify(appWindow)}) && !!shell?.paneRoots(${JSON.stringify(appWindow)})`), 10000);
          const original = await until("the original pooled identity page loaded", async () => {
            const now = await probe();
            const pages = now.live.filter((p) => p.tabId === ids[0]);
            return pages.length === 1 && pages[0].engine === "chromium" && pages[0].ready?.browserId != null && pages[0].navigation?.url === url && pages[0].navigation.isLoading === false ? { page: pages[0], profileId: now.tab.profileId } : null;
          }, 15000);
          const oldToken = tokenOf(original.page);
          const oldTarget = await pageTarget(`e?${marks[0]}`);
          const oldPageIsLive = async () => (await targets()).some((t) => t.id === oldTarget.id || t.type === "page" && t.url === url);
          const target = await until("the identity Leave page loaded", async () => {
            const found = await pageTarget(`e?${marks[1]}`).catch(() => null);
            const ready = found && await cdp(found, "Runtime.evaluate", { expression: `location.href.includes(${JSON.stringify(`e?${marks[1]}`)}) ? document.readyState : "initial"`, returnByValue: true }).catch(() => null);
            return ready?.result?.value === "complete" ? found : null;
          }, 15000);
          const installed = await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
          if (installed.exceptionDetails) throw new Error(`installing identity beforeunload: ${JSON.stringify(installed.exceptionDetails)}`);
          ws = new WebSocket(target.webSocketDebuggerUrl);
          await Promise.race([new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = () => reject(new Error("identity DevTools connection failed"))))), sleep(5000).then(() => { throw new Error("identity DevTools connection timed out"); })]);
          let enabled;
          const ready = new Promise((resolve, reject) => { enabled = (event) => event.error ? reject(new Error(JSON.stringify(event.error))) : resolve(); });
          ws.onmessage = (message) => {
            const event = JSON.parse(message.data);
            if (event.id === 1) enabled(event);
            if (event.method !== "Page.javascriptDialogOpening") return;
            prompt = true;
            if (leaving) ws.send(JSON.stringify({ id: 101, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
          };
          ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
          await Promise.race([ready, sleep(5000).then(() => { throw new Error("identity Page.enable timed out"); })]);
          windowNumber = await cef(`devWindowNumber(${await browserOf(ids[1])})`);
          await evalApp(`const s = ac.store.getState(); s.updateSettings({ warnBeforeClosingWindow: false }); s.activate(${JSON.stringify(ids[1])}); return true`);
          await cef(`devWindow(${windowNumber}, "close-button")`);
          await until("the identity closing beforeunload prompt", async () => prompt, 15000);
          const held = await until("the identity source held with its pin transferred", async () => {
            const now = await probe();
            return !now.sourceOpen && now.tab?.windowId !== appWindow && now.survivorOpen && now.tab?.profileId === original.profileId && Object.values(now.holds).includes(windowNumber) && now.ids.includes(ids[1]) ? now : null;
          }, 10000);
          const pin = held.live.filter((p) => p.tabId === ids[0]);
          if (pin.length !== 1 || tokenOf(pin[0]) !== oldToken) throw new Error(`identity pin changed before the command: ${JSON.stringify(held)}`);
          if (!(await targets()).some((t) => t.id === oldTarget.id)) throw new Error("the identity pin's Chromium page closed before the engine command");
          await evalApp(`globalThis.__acHeldIdentity?.sub?.remove(); const counts = { created: 0, gone: 0 }; counts.sub = globalThis.expo.modules.SolaraTabPool.addListener("onPageEvent", (e) => { if (e.tabId !== ${JSON.stringify(ids[0])}) return; if (e.name === "onPageCreated") counts.created++; if (e.name === "onPageGone") counts.gone++; }); globalThis.__acHeldIdentity = counts; const s = ac.store.getState(); s.activate(${JSON.stringify(ids[0])}); ac.runCommand({ command: "togglePageEngine", windowId: ${JSON.stringify(held.tab.windowId)} }); return true`);
          const replacement = await until("one new WebKit page under the held pin id", async () => {
            const now = await probe();
            const pages = now.live.filter((p) => p.tabId === ids[0]);
            return pages.length === 1 && pages[0].engine === "webkit" && pages[0].ready?.browserId != null && pages[0].navigation?.url === url && pages[0].navigation.isLoading === false && now.created === 1 && now.gone === 1 ? { page: pages[0], state: now } : null;
          }, 15000);
          const newToken = tokenOf(replacement.page);
          if (newToken === oldToken || replacement.page.ready.browserId === original.page.ready.browserId) throw new Error(`identity page token did not change: ${JSON.stringify(replacement)}`);
          await until("the discarded identity page gone from Chromium", async () => !await oldPageIsLive(), 10000);
          const verify = (now, holding) => {
            const pages = now.live.filter((p) => p.tabId === ids[0]);
            if (now.sourceOpen || !now.survivorOpen || now.tab?.windowId !== held.tab.windowId || now.tab?.profileId !== original.profileId || now.ids.filter((id) => id === ids[0]).length !== 1 || pages.length !== 1 || tokenOf(pages[0]) !== newToken || now.live.some((p) => tokenOf(p) === oldToken) || now.created !== 1 || now.gone !== 1) throw new Error(`identity replacement leaked or changed: ${JSON.stringify(now)}`);
            if (Object.values(now.holds).includes(windowNumber) !== holding || now.ids.includes(ids[1]) !== holding) throw new Error(`identity hold lifecycle disagrees: ${JSON.stringify(now)}`);
          };
          for (let sample = 0; sample < 3; sample++) {
            verify(await probe(), true);
            if (await oldPageIsLive()) throw new Error("the discarded identity page or a duplicate returned to Chromium");
            await sleep(50);
          }
          leaving = true;
          ws.send(JSON.stringify({ id: 101, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
          await until("the identity source window and hold released", async () => {
            const now = await probe();
            return !Object.values(now.holds).includes(windowNumber) && !now.ids.includes(ids[1]) && !(await cef(`chromeWindows()`)).some((w) => w.window === windowNumber) && !(await targets()).some((t) => t.id === target.id) ? now : null;
          }, 15000);
          const final = await probe();
          verify(final, false);
          if (await oldPageIsLive()) throw new Error("the old identity page or a duplicate survived Leave");
          return { pool: true, tabId: ids[0], oldToken, newToken, created: final.created, gone: final.gone, holdSamples: 3, holds: final.holds };
        } finally {
          leaving = true;
          if (prompt) try { ws?.send(JSON.stringify({ id: 102, method: "Page.handleJavaScriptDialog", params: { accept: true } })); } catch {}
          await evalApp(`globalThis.__acHeldIdentity?.sub?.remove(); delete globalThis.__acHeldIdentity; const s = ac.store.getState(); s.updateSettings({ warnBeforeClosingWindow: ${JSON.stringify(previous)} }); const pins = Object.values(s.tabs).filter((t) => (t.pinKey ?? t.id) === ${JSON.stringify(pinKey ?? ids[0])}); for (const t of pins) { s.pinTabs([t.id], false); s.closeTab(t.id); } return true`).catch(() => null);
          if (ws && ws.readyState !== WebSocket.CLOSED) await Promise.race([new Promise((resolve) => { ws.onclose = resolve; try { ws.close(); } catch { resolve(); } }), sleep(1000)]);
        }
      })();
      const failedMove = await (async () => {
        const marks = ["rm-m", "rm-n"];
        const { id } = await openWindow(marks, []);
        const target = await pageTarget("e?rm-m");
        await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
        const ws = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error("DevTools connection failed")))));
        const prompts = [];
        ws.onmessage = (m) => {
          const msg = JSON.parse(m.data);
          if (msg.method !== "Page.javascriptDialogOpening") return;
          prompts.push(msg.params.type);
          ws.send(JSON.stringify({ id: 100 + prompts.length, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
        };
        ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
        try {
          await sleep(300);
          const failingBrowser = await browserOf((await tabIdOf("rm-m")));
          await cef(`devKeepBrowsersOnClose([${failingBrowser}], [${failingBrowser}])`);
          await inWorker(`chrome.windows.remove(${id}).then(() => true)`);
          await until("the window closing after the failed move", async () => (await pages(marks)).length === 0, 15000);
          const unusedKnobs = await cef(`devKeepBrowsersOnClose([], [])`);
          if (unusedKnobs !== 0) throw new Error(`the forced failure didn't run (knobs left ${unusedKnobs})`);
          if (!prompts.includes("beforeunload")) throw new Error(`the tab whose move failed closed without its beforeunload: ${prompts}`);
          return { prompts };
        } finally {
          setTimeout(() => { try { ws.close(); } catch {} }, 3000);
        }
      })();
      const failedMoveStay = await (async () => {
        const marks = ["rm-o", "rm-p"];
        await openWindow(marks, []);
        const target = await pageTarget("e?rm-o");
        await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
        const ws = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error("DevTools connection failed")))));
        let leave = false;
        const prompts = [];
        ws.onmessage = (m) => {
          const msg = JSON.parse(m.data);
          if (msg.method !== "Page.javascriptDialogOpening") return;
          prompts.push({ type: msg.params.type, leave });
          ws.send(JSON.stringify({ id: 100 + prompts.length, method: "Page.handleJavaScriptDialog", params: { accept: leave } }));
        };
        ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
        try {
          await sleep(300);
          const tabId = (await tabIdOf("rm-o"));
          const windowNumber = await cef(`devWindowNumber(${await browserOf(tabId)})`);
          await evalApp(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: false }); return true`);
          const failingBrowser = await browserOf(tabId);
          await cef(`devKeepBrowsersOnClose([${failingBrowser}], [${failingBrowser}])`);
          await cef(`devWindow(${windowNumber}, "close-button")`);
          await until("the beforeunload prompt after the failed move", async () => prompts.length >= 1, 15000);
          await sleep(1000);
          const afterStay = await pages(marks);
          if (!afterStay.includes("rm-o")) throw new Error(`the page closed though beforeunload said Stay: ${afterStay}`);
          leave = true;
          const again = await cef(`devWindow(${windowNumber}, "close-button")`);
          await until("the window closing on the second try", async () => !(await pages(marks)).includes("rm-o"), 15000);
          return { prompts, afterStay, again };
        } finally {
          leave = true;
          setTimeout(() => { try { ws.close(); } catch {} }, 3000);
        }
      })();
      const twoProfiles = await (async () => {
        const windowId = await evalApp(`return ac.actions.openWindow({ url: "${base}/e?mp-a" })`);
        made.push(windowId);
        const profile = await evalApp(`return ac.store.getState().createProfile({ name: "Close keep" })`);
        await evalApp(`ac.actions.switchProfile(${JSON.stringify(windowId)}, ${JSON.stringify(profile)}); return true`);
        await evalApp(`ac.actions.openUrls(["${base}/e?mp-b1", "${base}/e?mp-b3"], ${JSON.stringify(windowId)}); return true`);
        const marks = ["mp-a", "mp-b1", "mp-b3"];
        await until("the two profiles' pages", async () => (await pages(marks)).length === 3, 15000);
        const [a, b1] = await Promise.all(["mp-a", "mp-b1"].map(async (m) => browserOf(await tabIdOf(m))));
        const personal = await evalApp(`return Object.keys(ac.store.getState().profiles).find((id) => id !== ${JSON.stringify(profile)})`);
        await until("mp-a shown", async () => {
          await evalApp(`ac.actions.switchProfile(${JSON.stringify(windowId)}, ${JSON.stringify(personal)}); return true`);
          return evalApp(`return ac.store.getState().windows[${JSON.stringify(windowId)}]?.profileId === ${JSON.stringify(personal)}`);
        }, 10000);
        const pageA = await pageTarget("e?mp-a");
        await cdp(pageA, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
        const ws = new WebSocket(pageA.webSocketDebuggerUrl);
        await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error("DevTools connection failed")))));
        const prompts = [];
        ws.onmessage = (m) => {
          const msg = JSON.parse(m.data);
          if (msg.method !== "Page.javascriptDialogOpening") return;
          prompts.push(msg.params.type);
          ws.send(JSON.stringify({ id: 100 + prompts.length, method: "Page.handleJavaScriptDialog", params: { accept: false } }));
        };
        ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
        try {
          await sleep(300);
          const windowNumber = await cef(`devWindowNumber(${a})`);
          await evalApp(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: false }); return true`);
          await cef(`devKeepBrowsersOnClose([${a}, ${b1}], [${a}])`);
          await cef(`devWindow(${windowNumber}, "close-button")`);
          await until("profile A's beforeunload prompt", async () => prompts.length >= 1, 15000);
          await until("profile B's close finishing", async () => !(await pages(marks)).includes("mp-b3"), 15000);
          const live = await until("both kept pages settled", async () => {
            const now = await pages(marks);
            return now.includes("mp-a") && now.includes("mp-b1") ? now : null;
          }, 5000).catch(async () => { throw new Error(`a kept page closed: live ${JSON.stringify(await pages(marks))}`); });
          const left = await cef(`devKeepBrowsersOnClose([], [])`);
          if (left !== 0) throw new Error(`knobs left ${left}`);
          return { prompts, live };
        } finally {
          for (const m of ["mp-a", "mp-b1"]) {
            const t = await pageTarget(`e?${m}`).catch(() => null);
            if (t) await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => null);
          }
          setTimeout(() => { try { ws.close(); } catch {} }, 3000);
          await evalApp(`const s = ac.store.getState(); const p = Object.values(s.profiles ?? {}).find((x) => x.name === "Close keep"); if (p && s.deleteProfile) s.deleteProfile(p.id); return true`).catch(() => null);
        }
      })();
      const held = await until("the pool holding only hidden windows Chrome still has", async () => {
        const holds = await evalApp(`const pool = globalThis.expo.modules.SolaraTabPool; return pool?.available() ? pool.devClosingWindows() : {}`);
        const chrome = await cef(`chromeWindows()`);
        const alive = new Set(chrome.map((w) => w.window));
        const hidden = new Set(chrome.filter((w) => !w.visible && !w.hasRoot).map((w) => w.window));
        const heldWindows = Object.values(holds);
        return heldWindows.every((w) => alive.has(w) && hidden.has(w)) ? { holds: heldWindows.length, hidden: hidden.size } : null;
      }, 10000).catch(async (e) => {
        const chrome = (await cef(`chromeWindows()`)).map((w) => ({ window: w.window, visible: w.visible, hasRoot: w.hasRoot }));
        throw new Error(`${e.message}: holds ${JSON.stringify(await evalApp(`return globalThis.expo.modules.SolaraTabPool.devClosingWindows()`))}, chrome windows ${JSON.stringify(chrome)}`);
      });
      return { plain: { ...plain, ...plainStore }, unload, keepOne, keepAll, cancelled, hostClose, hostCloseFrees, poolHoldThroughLeave, poolHeldIdentityChange, failedMove, failedMoveStay, twoProfiles, held, mainTabs: main.length };
    } finally {
      await cef(`devKeepTabsOnClose(0)`).catch(() => null);
      await cef(`devFailKeptMoves(0)`).catch(() => null);
      for (const w of made) if (w !== mainWindow) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(w)}); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
    }
  });

  await check("stay-restores-window", async () => {
    const previous = await evalApp(`return ac.store.getState().settings.warnBeforeClosingWindow`);
    const pooled = await evalApp(`return !!globalThis.expo.modules.SolaraTabPool?.available()`);
    const legs = [];
    try {
      for (const kind of ["normal", "private", "small"]) {
        const lazy = kind === "normal" && !pooled;
        const marks = kind === "small" ? [`stay-${kind}-a`] : lazy ? ["a", "b", "c", "d"].map((m) => `stay-${kind}-${m}`) : [`stay-${kind}-a`, `stay-${kind}-b`];
        const url = (mark) => `${base}/e?${mark}`;
        const oldWindow = await evalApp(`return ac.store.getState().createWindow(${JSON.stringify({ incognito: kind === "private", small: kind === "small", url: url(marks[0]) })})`);
        for (const mark of marks.slice(1)) await evalApp(`ac.store.getState().newTab(${JSON.stringify(oldWindow)}, { url: ${JSON.stringify(url(mark))}, background: true }); return true`);
        const before = await until(`${kind} tabs loaded`, async () => {
          const result = await evalApp(`const s = ac.store.getState(); const w = s.windows[${JSON.stringify(oldWindow)}]; return w && { profileId: w.profileId, ids: w.tabIds, urls: w.tabIds.map((id) => s.tabs[id]?.url) }`);
          return result?.urls.length === marks.length && marks.every((mark) => result.urls.some((u) => u?.includes(mark))) ? result : null;
        }, 15000);
        const split = kind === "normal" ? await evalApp(`return ac.store.getState().createSplit(${JSON.stringify(before.ids.slice(0, 2))}, "vertical")`) : null;
        const target = await until(`${kind} first page ready`, async () => {
          const found = await pageTarget(`e?${marks[0]}`).catch(() => null);
          const ready = found && (await cdp(found, "Runtime.evaluate", { expression: `location.href.includes(${JSON.stringify(`e?${marks[0]}`)}) ? document.readyState : "initial"`, returnByValue: true }).catch(() => null));
          return ready?.result?.value === "complete" ? found : null;
        }, 15000);
        const token = `stay-${kind}-${Date.now()}`;
        const windowPooled = pooled && await evalApp(`const shell = globalThis.expo.modules.SolaraWindowShell; return !!shell?.active(${JSON.stringify(oldWindow)}) && !!shell?.paneRoots(${JSON.stringify(oldWindow)})`);
        await cdp(target, "Runtime.evaluate", { expression: `globalThis.stayToken = ${JSON.stringify(token)}; addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
        const ws = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = () => reject(new Error("DevTools connection failed")))));
        let leave = false;
        let prompts = 0;
        ws.onmessage = (message) => {
          const event = JSON.parse(message.data);
          if (event.method !== "Page.javascriptDialogOpening") return;
          prompts++;
          ws.send(JSON.stringify({ id: 100 + prompts, method: "Page.handleJavaScriptDialog", params: { accept: leave } }));
        };
        ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
        try {
          await sleep(300);
          const tabId = before.ids[0];
          const windowNumber = await cef(`devWindowNumber(${await browserOf(tabId)})`);
          await evalApp(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: false }); return true`);
          const browsers = await Promise.all(before.ids.map((id) => browserOf(id)));
          if (!windowPooled) await cef(`devKeepBrowsersOnClose([${browsers.join(",")}], [${browsers.join(",")}])`);
          await cef(`devWindow(${windowNumber}, "close-button")`);
          await until(`${kind} beforeunload prompt`, async () => prompts > 0, 15000);
          const restored = await until(`${kind} window restored`, async () => {
            const windows = await evalApp(`const s = ac.store.getState(); return Object.values(s.windows).map((w) => ({ id: w.id, profileId: w.profileId, incognito: w.incognito, kind: w.kind, ids: w.tabIds, urls: w.tabIds.map((id) => s.tabs[id]?.url), closed: s.closedWindows.some((c) => c.tabs.some((t) => ${JSON.stringify(before.ids)}.includes(t.tabId))) }))`);
            return windows.find((w) => w.id !== oldWindow && marks.every((mark) => w.urls.some((u) => u?.includes(mark)))) ?? null;
          }, 15000);
          if (restored.incognito !== (kind === "private") || (restored.kind === "small") !== (kind === "small")) throw new Error(`${kind} restored with wrong window kind: ${JSON.stringify(restored)}`);
          if (restored.profileId !== before.profileId) throw new Error(`${kind} profile changed: ${before.profileId} to ${restored.profileId}`);
          if (restored.closed) throw new Error(`${kind} left a closedWindows entry`);
          if (windowPooled && JSON.stringify(restored.ids) !== JSON.stringify(before.ids)) throw new Error(`${kind} restored with different tab ids: ${JSON.stringify(restored.ids)}`);
          if (windowPooled) {
            const holds = await until(`${kind} pool hold released`, async () => {
              const now = await evalApp(`return globalThis.expo.modules.SolaraTabPool.devClosingWindows()`);
              return Object.values(now).includes(windowNumber) ? null : now;
            }, 10000);
            if (Object.values(holds).includes(windowNumber)) throw new Error(`${kind} pool still holds the NSWindow`);
          }
          if (split) {
            const splits = await evalApp(`const s = ac.store.getState(); return Object.values(s.splits).filter((x) => x.windowId === ${JSON.stringify(restored.id)}).map((x) => ({ orientation: x.orientation, urls: x.tabIds.map((id) => s.tabs[id]?.url) }))`);
            if (!splits.some((x) => x.orientation === "vertical" && marks.slice(0, 2).every((mark) => x.urls.some((u) => u?.includes(mark))))) throw new Error(`${kind} split not restored: ${JSON.stringify(splits)}`);
          }
          const visible = await until(`${kind} NSWindow visible`, async () => (await cef(`chromeWindows()`)).find((w) => w.window === windowNumber && w.visible && w.hasRoot) ?? null, 10000).catch(async (e) => {
            throw new Error(`${e.message}; window ${windowNumber}, restored ${JSON.stringify(restored)}, chrome ${JSON.stringify((await cef(`chromeWindows()`)).map((w) => [w.window, w.visible, w.hasRoot, w.stray, w.frame]))}`);
          });
          const kept = await cdp(target, "Runtime.evaluate", { expression: "globalThis.stayToken", returnByValue: true });
          if (kept.result?.value !== token) throw new Error(`${kind} page reloaded after Stay`);
          if (lazy) {
            const last = await until("the unvisited tab's page", () => pageTarget(`e?${marks[3]}`).catch(() => null), 5000);
            await cdp(last, "Runtime.evaluate", { expression: `globalThis.stayToken = ${JSON.stringify(token)}; true` });
            await sleep(25000);
            await evalApp(`const s = ac.store.getState(); const id = s.windows[${JSON.stringify(restored.id)}].tabIds.find((t) => s.tabs[t]?.url?.includes(${JSON.stringify(marks[3])})); s.activate(id); return true`);
            await sleep(2000);
            const pages = (await targets()).filter((t) => t.type === "page" && t.url.includes(`e?${marks[3]}`));
            const tokens = await Promise.all(pages.map(async (t) => (await cdp(t, "Runtime.evaluate", { expression: "globalThis.stayToken ?? null", returnByValue: true }).catch(() => null))?.result?.value ?? null));
            if (pages.length !== 1 || tokens[0] !== token) throw new Error(`the tab visited 25 s after the restore did not keep its page: ${pages.length} pages, tokens ${JSON.stringify(tokens)}`);
            const strays = (await cef(`chromeWindows()`)).filter((w) => !w.visible && !w.hasRoot && !w.stray);
            if (strays.length) throw new Error(`a hidden window is left after visiting the last tab: ${JSON.stringify(strays.map((w) => w.window))}`);
          }
          if (!prompts) throw new Error(`${kind} did not prompt beforeunload`);
          leave = true;
          await cef(`devWindow(${windowNumber}, "close-button")`);
          await until(`${kind} window closed after Leave`, async () => !((await evalApp(`return !!ac.store.getState().windows[${JSON.stringify(restored.id)}]`))), 15000);
          legs.push({ kind, restored: restored.id, window: visible.window, prompts });
        } finally {
          leave = true;
          if (!windowPooled) await cef(`devKeepBrowsersOnClose([], [])`).catch(() => null);
          setTimeout(() => { try { ws.close(); } catch {} }, 3000);
          await evalApp(`const s = ac.store.getState(); const w = Object.values(s.windows).find((w) => w.tabIds.some((id) => s.tabs[id]?.url?.includes(${JSON.stringify(marks[0])}))); if (w) s.closeWindow(w.id); return true`).catch(() => null);
        }
      }
      return legs;
    } finally {
      await evalApp(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: ${JSON.stringify(previous)} }); return true`).catch(() => null);
    }
  });

  await check("no-hidden-window-after-stay", async () => {
    const hidden = (await cef(`chromeWindows()`)).filter((w) => !w.visible && !w.hasRoot && !w.stray).map((w) => w.window);
    if (hidden.length) throw new Error(`${hidden.length} window(s) still alive but hidden after chrome-windows-remove's Stay cases: ${JSON.stringify(hidden)}`);
    return { hidden: 0 };
  });

  await check("private-windows-create", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    await exts(`configure("${installed.id}", "", { incognito: true })`);
    const privateTabs = () => evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).map((t) => ({ id: t.id, url: t.url, title: t.title, windowId: t.windowId, incognito: !!s.windows[t.windowId]?.incognito, adoptId: t.adoptId }))`);
    const opened = [];
    try {
      const worker = await extensionWorker(installed.id, "windows.create");
      const create = async (tag) => {
        const made = await cdp(worker, "Runtime.evaluate", {
          expression: `chrome.windows.create({ url: "${base}/cookie?${tag}", incognito: true }).then((w) => JSON.stringify({ incognito: w.incognito }), (e) => "error: " + e.message)`,
          awaitPromise: true,
          returnByValue: true,
        });
        const tab = await until(`the ${tag} tab in the app`, async () => (await privateTabs()).find((t) => t.url?.includes(`cookie?${tag}`) && t.title === "Cookie") ?? null, 15000)
          .catch((e) => { throw new Error(`${e.message}; windows.create: ${made.result?.value ?? JSON.stringify(made.exceptionDetails ?? made)}`); });
        opened.push(tab.windowId);
        return { tab, created: made.result?.value };
      };
      await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/cookie?personal", { userInitiated: true }); return true`);
      await until("Personal's cookie", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Cookie" && !t.loading));
      const lone = await create("private-ext1");
      if (!lone.tab.incognito) throw new Error(`the private tab landed in a normal window: ${JSON.stringify(lone)}`);
      const cookie = (await cdp(await pageTarget("cookie?private-ext1"), "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
      if (cookie.includes("personal")) throw new Error(`the private page sees Personal's cookie: ${cookie}`);
      const second = await create("private-ext2");
      if (!second.tab.incognito || second.tab.windowId !== lone.tab.windowId) throw new Error(`the second private tab: ${JSON.stringify(second)} (first in ${lone.tab.windowId})`);
      return { first: { window: lone.tab.windowId, adoptId: lone.tab.adoptId ?? null, cookie: cookie || "(none)" }, second: { sameWindow: true } };
    } finally {
      for (const w of new Set(opened)) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(w)}); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
      await backToA().catch(() => null);
    }
  });

  const withPopupExtension = async (options, fn) => {
    writePopupExtension(options);
    const installed = await exts(`install(${JSON.stringify(extPopupPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    try {
      await evalApp(`return ac.extensions.refreshExtensions("").then(() => true)`);
      return await fn(installed.id);
    } finally {
      await evalApp(`ac.extensions.closeExtensionPopup(); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
    }
  };
  const mainStrip = async () => (await cef(`tabStrips()`)).strips.find((st) => st.appWindow === mainWindow && st.profile === "");

  await check("extension-popup-window", async () => {
    return withPopupExtension({}, async (id) => {
      const tab = await freshTab(`${base}/b?under-popup`);
      try {
        const windowsBefore = (await cef(`chromeWindows()`)).length;
        const stripTabs = async () => (await cef(`tabStrips()`)).strips.flatMap((st) => st.tabs.map((x) => ({ strip: st.strip, profile: st.profile, ...x })));
        const browsersBefore = new Set((await stripTabs()).map((x) => x.browser));
        await evalApp(`const ext = Object.values(ac.extensions.useExtensions.getState().lists).flat().find((x) => x.id === "${id}");
          return ac.extensions.activateExtension(${JSON.stringify(mainWindow)}, ext, { x: 100, y: 40, width: 20, height: 20 }).then(() => true)`);
        await until("the native popup frame", async () => (await nativeExtensionPopup())?.frame ?? null, 8000);
        const popup = await until("the popup page", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${id}/popup.html`)), 10000);
        const seen = JSON.parse((await cdp(popup, "Runtime.evaluate", {
          expression: `Promise.all([chrome.windows.getCurrent(), chrome.tabs.query({ active: true, currentWindow: true }), chrome.extension.getViews({ type: "popup" }).length])
            .then(([w, tabs, popups]) => JSON.stringify({ window: w.id, tabs: tabs.map((t) => t.url), popups }))`,
          awaitPromise: true,
          returnByValue: true,
        })).result.value);
        const strip = await mainStrip();
        if (seen.window !== strip?.strip) throw new Error(`the popup's current window is ${seen.window}, the app's is ${strip?.strip}`);
        if (seen.tabs.length !== 1 || seen.tabs[0] !== `${base}/b?under-popup`) throw new Error(`the popup's active tab: ${JSON.stringify(seen.tabs)}`);
        if (seen.popups !== 1) throw new Error(`chrome.extension.getViews({ type: "popup" }): ${seen.popups}`);
        const added = (await stripTabs()).filter((x) => !browsersBefore.has(x.browser));
        if (added.length) throw new Error(`the popup is a tab in a strip: ${JSON.stringify(added)}`);
        const windowsWith = (await cef(`chromeWindows()`)).length;
        if (windowsWith !== windowsBefore) throw new Error(`windows ${windowsBefore} → ${windowsWith} with the popup open`);
        for (const type of ["rawKeyDown", "keyUp"])
          await cdp(popup, "Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53 }).catch(() => null);
        await until("Esc closing the native popup", async () => !(await nativeExtensionPopup())?.frame, 8000);
        await until("the popup page gone", async () => !(await targets()).some((t) => t.url.includes(`${id}/popup.html`)), 8000);
        return { window: seen.window, activeTab: seen.tabs[0], popups: seen.popups, windows: windowsWith };
      } finally {
        await closeTab(tab).catch(() => null);
      }
    });
  });

  await check("extension-popup-native-frame", async () => {
    return withPopupExtension({}, async (id) => {
      const tab = await freshTab(`${base}/b?native-popup`);
      const beforeLayout = await evalApp(`return ac.store.getState().settings.tabLayout`);
      const windowNumber = await cef(`devWindowNumber(${await browserOf(tab)})`);
      const act = (action) => cef(`devWindow(${windowNumber}, ${JSON.stringify(action)})`);
      const snapshot = () => nativeExtensionPopup(mainWindow);
      const popupTargets = async () => (await targets()).filter((t) => t.type === "page" && t.url.includes(`${id}/popup.html`));
      const near = (a, b) => Math.abs(a - b) <= 0.5;
      const click = async ([x, y]) => {
        await act(`mouse:down:${Math.round(x)},${Math.round(y)},1`);
        await sleep(40);
        await act(`mouse:up:${Math.round(x)},${Math.round(y)},1`);
      };
      let lastHit = null;
      const button = () => until("the extension's native toolbar button, uncovered", async () => {
        const toolbar = JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraToolbar.devToolbar(${JSON.stringify(mainWindow)}, "${tab}")`));
        const found = toolbar.extensions.find((e) => e.id === `ext:${id}` && e.frame[2] > 0);
        if (!found) return null;
        lastHit = String(await act(`hit:${Math.round(found.frame[0] + found.frame[2] / 2)},${Math.round(found.frame[1] + found.frame[3] / 2)}`));
        return lastHit.startsWith("RCT") ? null : found;
      }, 8000).catch((error) => { throw new Error(`${error.message}; hit ${lastHit}`); });
      const open = async () => {
        const { frame } = await button();
        await click([frame[0] + frame[2] / 2, frame[1] + frame[3] / 2]);
        const shown = await until("the native popup under the toolbar button", async () => {
          const s = await snapshot();
          return s?.extensionId === id && s.frame?.[2] > 100 ? s : null;
        }, 8000);
        const [x, y, width, height] = shown.frame;
        const [windowWidth, windowHeight] = shown.window;
        if (!near(x, Math.max(8, Math.min(frame[0] + frame[2] - width, windowWidth - 8 - width))) ||
          !near(y, Math.max(8, Math.min(frame[1] + frame[3] + 6, windowHeight - 8 - height))))
          throw new Error(`native frame ${JSON.stringify(shown.frame)} does not follow button ${JSON.stringify(frame)}`);
        if (x < 8 || y < 8 || x + width > windowWidth - 7.5 || y + height > windowHeight - 7.5)
          throw new Error(`native popup escaped the window: ${JSON.stringify(shown)}`);
        const target = await until("the popup renderer", async () => (await popupTargets())[0] ?? null, 8000);
        return { shown, target };
      };
      const closed = async (reason, opened) => {
        const result = await until(`${reason}: popup frame, page view and renderer released`, async () => {
          const s = await snapshot();
          return s && !s.frame && s.liveViews === 0 && !(await popupTargets()).length ? s : null;
        }, 10000);
        return result;
      };
      const urlEditor = async () => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraToolbar.devToolbar(${JSON.stringify(mainWindow)}, "${tab}")`)).urlEditor === true;
      const pageFocus = () => until("focus restored to the page", async () => {
        const s = await snapshot();
        return s?.focusedTabId === tab && !s.omniboxFocused ? true : null;
      }, 5000);
      const dismissed = [];
      let closingWindow = null;
      try {
        await evalApp(`ac.store.getState().updateSettings({ tabLayout: "top" }); return ac.extensions.setPinned("", "${id}", true)`);
        await act("fakeActiveClicks");
        await evalApp(`return ac.webviews.get("${tab}").focus()`);
        let opened = await open();
        const resize = async (width, height) => {
          await cdp(opened.target, "Runtime.evaluate", { expression: `document.body.textContent = ''; document.body.style.cssText = 'margin:0;width:${width}px;height:${height}px'` });
          return until(`popup preferred size ${width}×${height}`, async () => {
            const s = await snapshot();
            const expected = [Math.min(s.window[0] - 16, Math.min(800, Math.max(25, width)) + 1), Math.min(s.window[1] - 16, Math.min(600, Math.max(25, height)) + 1)];
            if (!s.frame || !near(s.frame[2], expected[0]) || !near(s.frame[3], expected[1])) return null;
            const [x, y, w, h] = s.frame;
            const [ax, ay, aw, ah] = s.anchor;
            if (!near(x, Math.max(8, Math.min(ax + aw - w, s.window[0] - 8 - w))) ||
              !near(y, Math.max(8, Math.min(ay + ah + 6, s.window[1] - 8 - h))))
              throw new Error(`resized popup escaped its anchor or window: ${JSON.stringify(s)}`);
            return s.frame;
          }, 5000);
        };
        const grown = await resize(450, 260);
        const shrunk = await resize(60, 30);
        const maximum = await resize(5000, 5000);
        const minimum = await resize(0, 0);
        if (grown[2] <= shrunk[2] || grown[3] <= shrunk[3]) throw new Error(`native popup did not shrink: ${grown} → ${shrunk}`);
        await click([10, 10]);
        await closed("outside click", opened);
        await pageFocus();
        dismissed.push("outside click");
        opened = await open();
        let pagePoint = null;
        for (const point of [[700, 420], [600, 500], [400, 400]]) {
          if (String(await act(`hit:${point.join(",")}`)).startsWith("RenderWidgetHostViewCocoa")) { pagePoint = point; break; }
        }
        if (!pagePoint) throw new Error("no exposed page point for native popup dismissal");
        await click(pagePoint);
        await closed("click in page", opened);
        await pageFocus();
        dismissed.push("click in page");
        opened = await open();
        for (const type of ["rawKeyDown", "keyUp"])
          await cdp(opened.target, "Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53 }).catch(() => null);
        await closed("Esc", opened);
        await pageFocus();
        dismissed.push("Esc");
        opened = await open();
        const toggle = (await button()).frame;
        await click([toggle[0] + toggle[2] / 2, toggle[1] + toggle[3] / 2]);
        await closed("toggle", opened);
        await pageFocus();
        dismissed.push("toggle");
        opened = await open();
        await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
        await closed("tab switch", opened);
        dismissed.push("tab switch");
        await evalApp(`ac.actions.switchToTab("${tab}"); return true`);
        await evalApp(`return ac.webviews.get("${tab}").focus()`);
        opened = await open();
        await evalApp(`ac.store.getState().navigate("${tab}", "${base}/b?native-popup-navigated", { userInitiated: true }); return true`);
        await closed("navigation", opened);
        dismissed.push("navigation");
        await until("the navigated page", async () => (await state()).tabs.find((t) => t.id === tab && !t.loading), 10000);
        await evalApp(`return ac.webviews.get("${tab}").focus()`);
        opened = await open();
        try {
          if (await act("fakeAppActive:0") !== "0") throw new Error("app resign hook unavailable");
          await closed("app resign", opened);
        } finally {
          await act("fakeAppActive:1");
        }
        dismissed.push("app resign");
        try {
          if (await act("fakeAppActive:0") !== "0") throw new Error("app resign hook unavailable");
          opened = await open();
          const { frame: inactiveButton } = await button();
          await click([inactiveButton[0] + inactiveButton[2] / 2, inactiveButton[1] + inactiveButton[3] / 2]);
          await closed("toolbar toggle while the app is inactive", opened);
          dismissed.push("toolbar click while inactive");
          const worker = await until("the extension's worker", async () =>
            (await targets()).find((t) => t.type === "service_worker" && t.url.includes(`${id}/worker.js`)) ?? null, 10000);
          const api = (await cdp(worker, "Runtime.evaluate", { expression: "chrome.action.openPopup().then(() => 'ok', (e) => e.message)", awaitPromise: true, returnByValue: true })).result.value;
          await sleep(1500);
          const after = await snapshot();
          if (after?.frame || (await popupTargets()).length) throw new Error(`chrome.action.openPopup (${api}) showed a popup while the app was inactive: ${JSON.stringify(after)}`);
          dismissed.push("openPopup refused while inactive");
        } finally {
          await act("fakeAppActive:1");
        }
        await evalApp(`ac.runCommand({ command: "focusCommandBar", arg: null, windowId: ${JSON.stringify(mainWindow)} }); return true`);
        await until("omnibox focused before opening", async () => (await snapshot())?.omniboxFocused, 5000);
        opened = await open();
        for (const type of ["rawKeyDown", "keyUp"])
          await cdp(opened.target, "Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53 }).catch(() => null);
        await closed("Esc from omnibox", opened);
        await until("focus restored to the omnibox", async () => (await snapshot())?.omniboxFocused, 5000);
        await until("the held field blur dropped once focus is back in the field", async () => (await snapshot())?.heldFieldBlurs === 0, 3000);
        if (!(await urlEditor())) throw new Error("the URL edit ended while the popup had focus");
        const escape = await act("keys:0:\u001b:53");
        await pageFocus().catch((error) => { throw new Error(`Esc in the restored field did not end its edit (${escape}): ${error.message}`); });
        await until("the restored field's edit ended by Esc", async () => !(await urlEditor()), 3000);
        dismissed.push("Esc back to the field, then Esc ends the edit");
        await evalApp(`ac.runCommand({ command: "focusCommandBar", arg: null, windowId: ${JSON.stringify(mainWindow)} }); return true`);
        await until("omnibox focused before the page click", async () => (await snapshot())?.omniboxFocused, 5000);
        opened = await open();
        await until("the field's blur held while the popup is up", async () => (await snapshot())?.heldFieldBlurs === 1, 3000);
        await click(pagePoint);
        await closed("page click from the field", opened);
        await pageFocus();
        await until("the held field blur flushed by the page click", async () => (await snapshot())?.heldFieldBlurs === 0, 3000);
        await until("the URL edit ended by the flushed blur", async () => !(await urlEditor()), 3000);
        dismissed.push("page click flushes the field blur");
        closingWindow = await evalApp(`return ac.actions.openWindow({ url: "${base}/b?native-popup-window-close" })`);
        const closingTab = await until("the popup's closing window", async () => evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).find((t) => t.windowId === ${JSON.stringify(closingWindow)} && t.url?.includes("native-popup-window-close"))?.id ?? null`), 10000);
        const closingButton = await until("the closing window's extension button", async () => {
          const toolbar = JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraToolbar.devToolbar(${JSON.stringify(closingWindow)}, ${JSON.stringify(closingTab)})`));
          return toolbar.extensions.find((e) => e.id === `ext:${id}` && e.frame[2] > 0) ?? null;
        }, 8000);
        const closingNumber = await cef(`devWindowNumber(${await browserOf(closingTab)})`);
        const [cx, cy, cw, ch] = closingButton.frame;
        await cef(`devWindow(${closingNumber}, "fakeActiveClicks")`);
        for (const type of ["down", "up"]) {
          await cef(`devWindow(${closingNumber}, "mouse:${type}:${Math.round(cx + cw / 2)},${Math.round(cy + ch / 2)},1")`);
          await sleep(40);
        }
        const beforeClose = await until("popup in the closing window", async () => {
          const s = await nativeExtensionPopup(closingWindow);
          return s?.frame && s.browserId ? s : null;
        }, 8000);
        await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(closingWindow)}); return true`);
        await until("window close releases the native popup and renderer", async () => {
          const s = await nativeExtensionPopup(closingWindow);
          return s && !s.frame && s.liveViews === 0 && !(await popupTargets()).length;
        }, 10000);
        dismissed.push("window close");
        return { frame: opened.shown.frame, anchor: opened.shown.anchor, sizes: { grown, shrunk, maximum, minimum }, dismissed, focus: ["page", "omnibox"] };
      } finally {
        if (closingWindow) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(closingWindow)}); return true`).catch(() => null);
        await evalApp(`ac.extensions.closeExtensionPopup(); ac.store.getState().updateSettings({ tabLayout: ${JSON.stringify(beforeLayout)} }); return true`).catch(() => null);
        await closeTab(tab).catch(() => null);
      }
    });
  });

  await check("extension-popup-rail-field", async () => {
    if (process.env.SOLARA_NATIVE_SHELL !== "1") return { skipped: "the sidebar rail needs SOLARA_NATIVE_SHELL=1" };
    return withPopupExtension({}, async (id) => {
      const tab = await freshTab(`${base}/b?rail-field`);
      const windowNumber = await cef(`devWindowNumber(${await browserOf(tab)})`);
      const act = (action) => cef(`devWindow(${windowNumber}, ${JSON.stringify(action)})`);
      const snapshot = () => nativeExtensionPopup(mainWindow);
      const toolbar = async () => JSON.parse(await evalApp(`return globalThis.expo.modules.SolaraToolbar.devToolbar(${JSON.stringify(mainWindow)}, "${tab}")`));
      const before = await evalApp(`const s = ac.store.getState().settings; return { tabLayout: s.tabLayout, iconsOnly: s.sidebarIconsOnly }`);
      const setRail = async (on) => {
        const now = await evalApp(`return ac.store.getState().settings.sidebarIconsOnly`);
        if (now !== on) await evalApp(`ac.runCommand({ command: "toggleSidebarIconsOnly", arg: null, windowId: ${JSON.stringify(mainWindow)} }); return true`);
        await until(`sidebar rail ${on ? "on" : "off"}`, async () => (await evalApp(`return ac.store.getState().settings.sidebarIconsOnly`)) === on, 5000);
      };
      let popup = null;
      try {
        await evalApp(`ac.store.getState().updateSettings({ tabLayout: "sidebar" }); return ac.extensions.setPinned("", "${id}", true)`);
        await setRail(true);
        await act("fakeActiveClicks");
        const placed = await until("the toolbar moved into the rail, outside its React Native host", async () => {
          const button = (await toolbar()).extensions.find((e) => e.id === `ext:${id}` && e.frame[2] > 0);
          if (!button) return null;
          const hit = String(await act(`hit:${Math.round(button.frame[0] + button.frame[2] / 2)},${Math.round(button.frame[1] + button.frame[3] / 2)}`));
          return hit.includes("ToolbarView") && !hit.includes("NativeToolbarHostView") ? { button, hit } : null;
        }, 8000);
        await evalApp(`ac.runCommand({ command: "focusCommandBar", arg: null, windowId: ${JSON.stringify(mainWindow)} }); return true`);
        await until("the toolbar URL field editing", async () => (await snapshot())?.omniboxFocused && (await toolbar()).urlEditor, 5000);
        await evalApp(`const ext = Object.values(ac.extensions.useExtensions.getState().lists).flat().find((x) => x.id === "${id}");
          return ac.extensions.activateExtension(${JSON.stringify(mainWindow)}, ext, { x: ${placed.button.frame[0]}, y: ${placed.button.frame[1]}, width: ${placed.button.frame[2]}, height: ${placed.button.frame[3]} }).then(() => true)`);
        popup = await until("the popup renderer", async () => (await targets()).find((t) => t.type === "page" && t.url.includes(`${id}/popup.html`)) ?? null, 8000);
        await until("the field's blur held while the popup is up", async () => (await snapshot())?.heldFieldBlurs === 1, 3000);
        if (!(await toolbar()).urlEditor) throw new Error("the URL edit ended while the popup had focus in the rail");
        for (const type of ["rawKeyDown", "keyUp"])
          await cdp(popup, "Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53 }).catch(() => null);
        await until("Esc closing the popup", async () => !(await snapshot())?.frame, 5000);
        await until("focus back in the rail's URL field", async () => (await snapshot())?.omniboxFocused, 5000);
        await until("the held blur dropped", async () => (await snapshot())?.heldFieldBlurs === 0, 3000);
        if (!(await toolbar()).urlEditor) throw new Error("Esc from the popup ended the rail's URL edit");
        const escape = await act("keys:0:\u001b:53");
        await until("Esc in the restored rail field ending its edit", async () => !(await toolbar()).urlEditor, 3000)
          .catch((error) => { throw new Error(`${error.message} (${escape})`); });
        return { hit: placed.hit.split(" < ").slice(0, 4).join(" < ") };
      } finally {
        await evalApp(`ac.extensions.closeExtensionPopup(); return true`).catch(() => null);
        await setRail(before.iconsOnly).catch(() => null);
        await evalApp(`ac.store.getState().updateSettings({ tabLayout: ${JSON.stringify(before.tabLayout)} }); return true`).catch(() => null);
        await closeTab(tab).catch(() => null);
      }
    });
  });

  await check("extension-windows-hidden", async () => {
    const appWindows = async () => (await cef(`chromeWindows()`)).map((w) => w.window);
    const before = new Set([...onScreenWindows(), ...(await appWindows())]);
    return withPopupExtension({ welcome: true }, async (id) => {
      const opened = [];
      try {
        const welcome = await until("the extension's install tab in the app", async () => {
          const tabs = await evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).map((t) => ({ id: t.id, url: t.url, windowId: t.windowId }))`);
          return tabs.find((t) => t.url?.includes("e?installed")) ?? null;
        }, 15000);
        opened.push(welcome.id);
        if (welcome.windowId !== mainWindow) throw new Error(`the install tab is in ${welcome.windowId}, not the run's window`);
        const worker = await extensionWorker(id, "windows.getAll");
        const listed = JSON.parse((await cdp(worker, "Runtime.evaluate", { expression: "chrome.windows.getAll().then((ws) => JSON.stringify(ws.map((w) => w.id)))", awaitPromise: true, returnByValue: true })).result.value);
        const strips = new Set((await cef(`tabStrips()`)).strips.map((st) => st.strip));
        const hidden = listed.filter((w) => !strips.has(w));
        if (hidden.length) throw new Error(`chrome.windows.getAll lists windows the app doesn't show: ${JSON.stringify(hidden)} (app's: ${JSON.stringify([...strips])})`);
        await cdp(worker, "Runtime.evaluate", { expression: "chrome.runtime.openOptionsPage().then(() => true)", awaitPromise: true });
        const options = await until("the options page in the app", async () => {
          const tabs = await evalApp(`const s = ac.store.getState(); return Object.values(s.tabs).map((t) => ({ id: t.id, url: t.url, windowId: t.windowId }))`);
          return tabs.find((t) => t.url?.includes(`${id}/options.html`)) ?? null;
        }, 15000);
        opened.push(options.id);
        if (options.windowId !== mainWindow) throw new Error(`the options page is in ${options.windowId}, not the run's window`);
        await sleep(1000);
        const app = new Set(await appWindows());
        const stray = onScreenWindows().filter((w) => !before.has(w) && !app.has(w));
        if (stray.length) throw new Error(`windows on screen the app didn't show: ${JSON.stringify(stray)}`);
        return { listed, installTab: welcome.url, options: options.url };
      } finally {
        for (const tab of opened) await closeTab(tab).catch(() => null);
      }
    });
  });

  await check("content-blocked-count", async () => {
    return withPopupExtension({}, async () => {
      const tab = await freshTab(`${base}/ac-ads`);
      try {
        const target = await until("the page", () => pageTarget("/ac-ads"));
        const standIn = (await cdp(target, "Runtime.evaluate", { expression: "window.__acStandIn === true", returnByValue: true })).result.value;
        if (!standIn) throw new Error("the script wasn't sent to the stand-in");
        const blocked = await until("the count", async () => {
          const n = await evalApp(`return ac.pageState.getState().pages[${JSON.stringify(tab)}]?.blocked ?? 0`);
          return n >= 2 ? n : null;
        }, 8000).catch(async () => evalApp(`return ac.pageState.getState().pages[${JSON.stringify(tab)}]?.blocked ?? 0`));
        await sleep(500);
        const settled = await evalApp(`return ac.pageState.getState().pages[${JSON.stringify(tab)}]?.blocked ?? 0`);
        if (settled !== 2) throw new Error(`blocked ${settled} (then ${blocked}), not 2 (the image and the redirected script)`);
        return { blocked: settled, standIn };
      } finally {
        await closeTab(tab).catch(() => null);
      }
    });
  });

  await check("extension-download-hidden", async () => {
    const listed = () => evalApp(`return ac.store.getState().downloads.map((d) => d.url ?? "")`);
    const open = () => evalApp(`return !!ac.store.getState().windowUi[${JSON.stringify(mainWindow)}]?.downloadsOpen`);
    const wasOpen = await open();
    const tab = await freshTab(`${base}/b?crx`);
    try {
      const target = await until("the page", () => pageTarget("/b?crx"));
      const url = `${base}/webstore/crx?ac=${Date.now()}`;
      await cdp(target, "Runtime.evaluate", { expression: `(() => { const a = document.createElement("a"); a.href = "${url}"; document.body.append(a); a.click(); return true; })()`, userGesture: true });
      await until("the .crx becoming a download", async () => (await eventsOf(tab)).some((x) => x.name === "downloadNavigation" && JSON.stringify(x.payload).includes("/webstore/crx")), 10000);
      const seen = [];
      for (let i = 0; i < 10; i++) {
        seen.push(...(await listed()));
        await sleep(300);
      }
      if (seen.some((u) => u.includes("/webstore/crx"))) throw new Error(`the .crx is one of the user's downloads: ${JSON.stringify([...new Set(seen)])}`);
      if (!wasOpen && (await open())) throw new Error("the downloads popover opened");
      return { downloads: new Set(seen).size };
    } finally {
      await closeTab(tab).catch(() => null);
    }
  });

  await check("extension-installed-bubble", async () => {
    const crxPath = join(scratch, "fixture.crx");
    writeFileSync(crxPath, fixtureCrx());
    const profile = await evalApp(`return ac.store.getState().createProfile({ name: "Installs" })`);
    const opened = [];
    const bubbleIn = async (windowId) => {
      for (const w of await cef(`chromeWindows()`)) {
        const children = JSON.parse(await cef(`devWindow(${w.window}, "children")`));
        if (children.some((c) => /has been added/.test(c.title))) return w.window;
      }
      return null;
    };
    const profileWindow = async (path) => {
      const before = new Set((await cef(`chromeWindows()`)).map((w) => w.window));
      const id = await evalApp(`return ac.actions.openWindow({ profileId: ${JSON.stringify(profile)}, url: "${base}${path}" })`);
      opened.push(id);
      await until(`${path} shown`, () => pageTarget(path));
      const native = await until("its window", async () => (await cef(`chromeWindows()`)).find((w) => !before.has(w.window))?.window ?? null);
      return { id, native };
    };
    const install = async (closeFirst) => {
      await evalApp(`ac.extensions.cancelInstall(); globalThis.__acCrx = null;
        globalThis.expo.modules.SolaraExtensions.installCrx(${JSON.stringify(crxPath)}, ${JSON.stringify(profile)}).then((r) => (globalThis.__acCrx = r)); return true`);
      const prompt = await until("the install prompt", async () => {
        const p = await evalApp(`return ac.extensions.useExtensions.getState().install?.prompt ?? null`);
        return p?.name === "SolaraCore crx fixture" ? p : null;
      }, 15000);
      if (closeFirst) await closeFirst();
      await exts(`resolveInstallPrompt(${JSON.stringify(prompt.requestId)}, true)`);
      const result = await until("the install", () => evalApp(`return globalThis.__acCrx`), 15000);
      if (!result.id) throw new Error(`install: ${JSON.stringify(result)}`);
      return result.id;
    };
    let id = null;
    try {
      const first = await profileWindow("/b?installs-1");
      id = await install();
      const shown = await until("the bubble", () => bubbleIn(), 8000);
      if (shown !== first.native) throw new Error(`the bubble is in window ${shown}, not the profile's ${first.native}`);
      await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(first.id)}); return true`);
      await sleep(1500);
      await exts(`uninstall("${id}", ${JSON.stringify(profile)})`);
      const before = new Set([...onScreenWindows(), ...(await cef(`chromeWindows()`)).map((w) => w.window)]);
      const second = await profileWindow("/c?installs-2");
      id = await install(async () => {
        await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(second.id)}); return true`);
        await until("the profile's window closed", async () => !(await cef(`chromeWindows()`)).some((w) => w.window === second.native && w.visible), 8000)
          .catch(async (e) => { throw new Error(`${e.message}; windows ${JSON.stringify(await cef(`chromeWindows()`))}; app ${JSON.stringify(await evalApp(`return ac.store.getState().windowOrder`))}`); });
      });
      await sleep(2000);
      const early = await bubbleIn();
      if (early) throw new Error(`the bubble showed in window ${early} with no window of the profile`);
      const stray = onScreenWindows().filter((w) => !before.has(w));
      if (stray.length) throw new Error(`windows on screen the app didn't show: ${JSON.stringify(stray)}`);
      const third = await profileWindow("/d?installs-3");
      const later = await until("the waiting bubble", () => bubbleIn(), 8000);
      if (later !== third.native) throw new Error(`the waiting bubble is in window ${later}, not the profile's ${third.native}`);
      return { immediate: shown, waited: later };
    } finally {
      await evalApp(`ac.extensions.cancelInstall(); return true`).catch(() => null);
      for (const w of opened) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(w)}); return true`).catch(() => null);
      if (id) await exts(`uninstall("${id}", ${JSON.stringify(profile)})`).catch(() => null);
    }
  });

  await check("context-menu-reading-mode", async () => {
    const tab = await freshTab(`${base}/text`);
    try {
      const target = await until("the page", () => pageTarget("/text"));
      const before = (await eventsOf(tab)).filter((x) => x.name === "contextMenu").length;
      let menu = null;
      for (let attempt = 0; attempt < 3 && !menu; attempt++) {
        const at = { x: 300, y: 300, button: "right", clickCount: 1 };
        await cdp(target, "Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
        await cdp(target, "Input.dispatchMouseEvent", { type: "mousePressed", ...at });
        await cdp(target, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at });
        menu = await until("a context menu", async () => {
          const menus = (await eventsOf(tab)).filter((x) => x.name === "contextMenu");
          return menus.length > before ? menus.at(-1) : null;
        }, 4000).catch(() => null);
      }
      if (!menu) throw new Error("no context menu reported");
      const items = menu.payload.items;
      const flat = (list) => list.flatMap((i) => [i, ...flat(i.submenu ?? [])]);
      const found = flat(items).filter((i) => i.id === 50169 || /reading mode|listen to this page/i.test(i.label ?? ""));
      if (found.length) throw new Error(`still there: ${JSON.stringify(found.map((i) => i.label))}`);
      const doubled = items.some((i, n) => i.separator && (n === 0 || n === items.length - 1 || items[n + 1]?.separator));
      if (doubled) throw new Error(`a doubled or end separator: ${JSON.stringify(items.map((i) => (i.separator ? "—" : i.label)))}`);
      return { items: items.filter((i) => !i.separator).map((i) => i.label) };
    } finally {
      await closeTab(tab).catch(() => null);
    }
  });

  // MARK: Content blocker

  await check("content-blocker", async () => {
    const state = await until("the blocker's state", async () => {
      const s = await cef(`getContentBlocker()`);
      return s?.stats?.ready ? s : null;
    }, 30000);
    const enabledLists = state.lists.filter((l) => l.enabled).length;
    if (state.lists.length < 20 || enabledLists < 5 || !(state.stats.networkFilters > 20000))
      throw new Error(`uBlock Origin has no bundled lists on a fresh profile: ${state.lists.length} lists, ${enabledLists} on, ${state.stats.networkFilters} network filters`);
    await cef(`setContentBlockerAllowed("allowed.test", true)`);
    const allowed = await cef(`isContentBlockerAllowed("allowed.test")`);
    await cef(`setContentBlockerAllowed("allowed.test", false)`);
    return { enabled: state.enabled, lists: state.lists.length, on: enabledLists, networkFilters: state.stats.networkFilters, version: state.version, allowed };
  });

  await check("content-blocker-fails-closed", async () => {
    const enabled = async () => (await cef(`getContentBlocker()`)).lists.filter((l) => l.enabled).map((l) => l.id).sort();
    const before = await enabled();
    const off = (await cef(`getContentBlocker()`)).lists.find((l) => !l.enabled);
    await cef(`devContentBlockerFailNextMessage()`);
    const error = await evalApp(`return globalThis.expo.modules.SolaraCEF.setFilterListEnabled(${JSON.stringify(off.id)}, true).then(() => null, (e) => e.message)`);
    const after = await enabled();
    if (!error) throw new Error("the failed change reported no error");
    if (JSON.stringify(after) !== JSON.stringify(before)) throw new Error(`the lists changed: ${before} → ${after}`);
    return { error, enabled: after.length };
  });

  const adsServedFor = (tag) => adServed.filter((s) => !s.startsWith("adpage.test") && s.endsWith(`?${tag}`));

  const contentBlockerRounds = async (profileId) => {
    await until("the blocker's state", async () => ((await cef(`getContentBlocker()`))?.stats?.ready ? true : null), 30000);
    const origin = `http://adpage.test:${server.address().port}`;
    const page = `${origin}/adpage`;
    const tag0 = profileId ? profileId : "personal";
    const firstTag = `first-${tag0}-${Date.now()}`;
    const firstPage = `${origin}/adfirst?${firstTag}`;
    const ownWindow = profileId ? await evalApp(`return ac.actions.openWindow({ profileId: ${JSON.stringify(profileId)}, url: "${firstPage}" })`) : null;
    const tab = ownWindow
      ? await until("the profile's tab", () => evalApp(`return ac.store.getState().windows[${JSON.stringify(ownWindow)}]?.tabIds[0] ?? null`))
      : await evalApp(`return ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: "${firstPage}" })`);
    try {
      await until("the first page", () => evalApp(`const s = ac.store.getState(); const t = s.tabs[${JSON.stringify(tab)}];
        return t?.title === "Ad first" && !s.live[${JSON.stringify(tab)}]?.isLoading ? true : null`), 20000);
      await sleep(500);
      const first = adsServedFor(firstTag);
      if (first.length) throw new Error(`the first page's ads went out: ${JSON.stringify(first)}`);
      const round = async (tag) => {
        tag = `${tag0}-${tag}`;
        await evalApp(`ac.store.getState().navigate(${JSON.stringify(tab)}, "${page}?${tag}", { userInitiated: true }); return true`);
        await until(`the page (${tag})`, () => evalApp(`const s = ac.store.getState(); const t = s.tabs[${JSON.stringify(tab)}];
          return t?.url?.endsWith(${JSON.stringify(`?${tag}`)}) && !s.live[${JSON.stringify(tab)}]?.isLoading ? true : null`));
        const t = await until("its target", () => pageTarget(`/adpage?${tag}`));
        const reached = async (url) => {
          const before = adServed.length;
          const r = (await cdp(t, "Runtime.evaluate", { expression: `fetch("${url}", { mode: "no-cors" }).then(() => "loaded", () => "failed")`, awaitPromise: true, returnByValue: true })).result.value;
          return { fetch: r, reached: adServed.slice(before).some((s) => url.includes(s.split("?")[0])) };
        };
        const script = async () => {
          const before = adServed.length;
          const url = `http://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?${tag}`;
          const r = (await cdp(t, "Runtime.evaluate", { expression: `new Promise((r) => { const s = document.createElement("script"); s.src = "${url}";
            s.onload = () => r(window.adsbygoogle?.loaded === true ? "stand-in" : "loaded"); s.onerror = () => r("failed"); document.head.append(s); })`, awaitPromise: true, returnByValue: true })).result.value;
          return { script: r, reached: adServed.slice(before).some((s) => s.startsWith("pagead2.")) };
        };
        return { adnxs: await reached(`http://ib.adnxs.com/ut/v3?${tag}`), gpt: await reached(`http://securepubads.g.doubleclick.net/tag/js/gpt.js?${tag}`), adsbygoogle: await script() };
      };
      const stopped = (r) => !r.adnxs.reached && !r.gpt.reached && r.adnxs.fetch === "failed" && !r.adsbygoogle.reached && r.adsbygoogle.script === "stand-in";
      const blocked = await round("blocked");
      await cef(`setContentBlockerAllowed("adpage.test", true)`);
      const allowed = await round("allowed");
      await cef(`setContentBlockerAllowed("adpage.test", false)`);
      const again = await round("again");
      if (!stopped(blocked)) throw new Error(`not blocked: ${JSON.stringify(blocked)}`);
      if (!allowed.adnxs.reached || !allowed.gpt.reached || !allowed.adsbygoogle.reached) throw new Error(`allowing the site let nothing through: ${JSON.stringify(allowed)}`);
      if (!stopped(again)) throw new Error(`blocked again? ${JSON.stringify(again)}`);
      return { firstPage: "blocked", blocked, allowed, again };
    } finally {
      if (ownWindow) await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(ownWindow)}); return true`);
      else await evalApp(`ac.store.getState().closeTab(${JSON.stringify(tab)}); return true`);
    }
  };

  await check("content-blocker-blocks", async () => {
    return contentBlockerRounds(undefined);
  });

  await check("content-blocker-profile", async () => {
    const id = await evalApp(`return ac.store.getState().createProfile({ name: "Blocker" })`);
    if (!id) throw new Error("no profile made");
    return { profile: id, ...(await contentBlockerRounds(id)) };
  });

  await check("content-blocker-held", async () => {
    const delay = 1500;
    await cef(`devContentBlockerDelayNextLoad(${delay})`);
    const id = await evalApp(`return ac.store.getState().createProfile({ name: "Held" })`);
    const tag = `held-${Date.now()}`;
    const started = Date.now();
    const w = await evalApp(`return ac.actions.openWindow({ profileId: ${JSON.stringify(id)}, url: "http://adpage.test:${server.address().port}/adfirst?${tag}" })`);
    try {
      await until("the held page", () => evalApp(`const s = ac.store.getState(); const t = s.windows[${JSON.stringify(w)}]?.tabIds[0];
        return t && s.tabs[t]?.title === "Ad first" && !s.live[t]?.isLoading ? true : null`), 20000);
      const loadedAfterMs = Date.now() - started;
      await sleep(500);
      const served = adsServedFor(tag);
      if (served.length) throw new Error(`the held page's ads went out: ${JSON.stringify(served)}`);
      if (loadedAfterMs < delay) throw new Error(`the page loaded ${loadedAfterMs} ms in, before the blocker (not held)`);
      return { profile: id, loadedAfterMs };
    } finally {
      await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(w)}); return true`);
    }
  });

  await check("content-blocker-private", async () => {
    const origin = `http://adpage.test:${server.address().port}`;
    const out = [];
    for (const step of ["first", "after-release"]) {
      const tag = `private-${step}-${Date.now()}`;
      const w = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${origin}/adfirst?${tag}" })`);
      try {
        await until(`the ${step} private page`, () => evalApp(`const s = ac.store.getState(); const id = s.windows[${JSON.stringify(w)}]?.tabIds[0];
          return id && s.tabs[id]?.title === "Ad first" && !s.live[id]?.isLoading ? true : null`), 20000);
        await sleep(500);
        const served = adsServedFor(tag);
        if (served.length) throw new Error(`the ${step} private window's ads went out: ${JSON.stringify(served)}`);
        out.push(step);
      } finally {
        await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(w)}); return true`);
      }
      await sleep(2000);
    }
    return { blocked: out };
  });

  // MARK: Data, downloads and crashes

  await check("internal-pages-not-history", async () => {
    const userOpened = (u) => /^chrome-extension:\/\/[a-p]{32}\/options\.html/.test(u) || extensionPagesOpenedAsTabs.has(u.split(/[?#]/)[0]);
    const profiles = ["", ...(await evalApp(`return ac.store.getState().profileOrder.filter((p) => p !== "default")`))];
    await sleep(1500);
    const found = {};
    let pages = 0;
    for (const profile of profiles) {
      const r = JSON.parse(await cef(`engineCall("ac_history_query", ${JSON.stringify(profile)}, ${JSON.stringify(JSON.stringify({ maxUrls: 1000, maxVisits: 1 }))})`));
      const urls = (r.entries ?? []).map((e) => e.u ?? "");
      pages += urls.filter((u) => u.startsWith("http")).length;
      const internal = urls.filter((u) => u.startsWith("chrome-extension://") && !userOpened(u));
      if (internal.length) found[profile || "personal"] = internal;
    }
    if (Object.keys(found).length) throw new Error(`extension pages in history: ${JSON.stringify(found)}`);
    if (!pages) throw new Error("no history at all (the check proves nothing)");
    return { profiles: profiles.length, webPages: pages };
  });

  await check("crash-reload", async () => {
    const tab = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: "${base}/crash-reload" })`);
    try {
      await until("the page", async () => (await state()).tabs.find((t) => t.id === tab && t.title === "/crash-reload" && !t.loading));
      await cdp(await pageTarget("/crash-reload"), "Page.crash").catch(() => null);
      const crashed = await until("the sad tab", () => evalApp(`return ac.pageState.getState().pages[${JSON.stringify(tab)}]?.crashed ?? null`), 10000);
      await evalApp(`return ac.webviews.get(${JSON.stringify(tab)}).reload()`);
      const title = await until("the page again", async () => {
        const t = await pageTarget("/crash-reload");
        const r = t && (await cdp(t, "Runtime.evaluate", { expression: "document.title", returnByValue: true }).catch(() => null));
        return r?.result?.value === "/crash-reload" ? r.result.value : null;
      });
      const after = await until("no sad tab", async () => {
        const p = await evalApp(`return { crashed: ac.pageState.getState().pages[${JSON.stringify(tab)}]?.crashed ?? null, url: ac.store.getState().tabs[${JSON.stringify(tab)}]?.url }`);
        return !p.crashed && p.url?.endsWith("/crash-reload") ? p : null;
      }, 5000).catch(async () => { throw new Error(`still crashed: ${JSON.stringify(await evalApp(`return ac.pageState.getState().pages[${JSON.stringify(tab)}]?.crashed`))}`); });
      return { crashed: crashed.reason, title, url: after.url };
    } finally {
      await evalApp(`ac.store.getState().closeTab(${JSON.stringify(tab)}); return true`);
    }
  });

  await check("crash-debug-url", async () => {
    const tab = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: "${base}/crash-url" })`);
    try {
      await until("the page", async () => (await state()).tabs.find((t) => t.id === tab && t.title === "/crash-url" && !t.loading));
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(tab)}); ac.store.getState().navigate(${JSON.stringify(tab)}, "chrome://crash", { userInitiated: true }); return true`);
      await until("the sad tab", () => evalApp(`return ac.pageState.getState().pages[${JSON.stringify(tab)}]?.crashed ?? null`), 10000);
      await sleep(1000);
      const url = await evalApp(`return ac.store.getState().tabs[${JSON.stringify(tab)}]?.url`);
      if (!url?.startsWith(`${base}/crash-url`)) throw new Error(`the tab's URL became ${url}`);
      await evalApp(`return ac.webviews.get(${JSON.stringify(tab)}).reload()`);
      await until("the page again, not crashed", async () => {
        const p = await evalApp(`return { crashed: ac.pageState.getState().pages[${JSON.stringify(tab)}]?.crashed ?? null, url: ac.store.getState().tabs[${JSON.stringify(tab)}]?.url }`);
        const t = await pageTarget("/crash-url");
        const r = t && (await cdp(t, "Runtime.evaluate", { expression: "document.title", returnByValue: true }).catch(() => null));
        return !p.crashed && p.url?.startsWith(`${base}/crash-url`) && r?.result?.value === "/crash-url" ? p : null;
      });
      return { url };
    } finally {
      await evalApp(`ac.store.getState().closeTab(${JSON.stringify(tab)}); return true`);
    }
  });

  await check("popup-window", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    const opener = await pageFor(first.id, `${base}/a`);
    const popups = async () => (await cef(`engineInfo()`)).popupWindows;
    const before = await popups();
    await cdp(opener, "Runtime.evaluate", { expression: `window.__msg = null; addEventListener("message", (e) => (window.__msg = e.data)); window.open("${base}/popup-page", "pop", "width=480,height=360"); true`, userGesture: true });
    const t = await until("the popup's page", () => pageTarget("/popup-page"));
    await until("a popup window", async () => ((await popups()) === before + 1 ? true : null), 10000);
    const page = (await cdp(t, "Runtime.evaluate", { expression: `JSON.stringify({ size: innerWidth + "x" + innerHeight, opener: !!window.opener })`, returnByValue: true })).result.value;
    await cdp(t, "Runtime.evaluate", { expression: `window.opener.postMessage("from-popup", "*")` });
    const message = await until("the opener's message", async () => (await cdp(opener, "Runtime.evaluate", { expression: "window.__msg", returnByValue: true })).result.value);
    const asTab = (await state()).tabs.some((x) => x.url?.includes("/popup-page"));
    await closeFromPage(t);
    await until("the popup window closed", async () => ((await popups()) === before && !(await pageTarget("/popup-page")) ? true : null), 10000);
    const { size, opener: hasOpener } = JSON.parse(page);
    if (asTab) throw new Error("the popup became a tab");
    if (size !== "480x360" || !hasOpener) throw new Error(`popup page ${page}`);
    return { size, opener: hasOpener, message };
  });

  await check("popup-window-permission", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    const opener = await pageFor(first.id, `${base}/a`);
    await cdp(opener, "Runtime.evaluate", { expression: `window.open("${base}/popup-page?permission", "perm", "width=480,height=360"); true`, userGesture: true });
    const t = await until("the popup's page", () => pageTarget("/popup-page?permission"));
    const popup = await until("the pop-up window", async () => (await cef(`engineInfo()`)).popupOrigins.find((o) => o.origin.startsWith(base)) ?? null, 10000);
    const answer = async () => (await cdp(t, "Runtime.evaluate", { expression: "String(window.__perm)", returnByValue: true })).result.value;
    const shown = async () => (await cef(`engineInfo()`)).popupOrigins.find((o) => o.permission)?.permission ?? null;
    const ask = async () => {
      await cdp(t, "Runtime.evaluate", {
        expression: "window.__perm = 'pending'; navigator.geolocation.getCurrentPosition(() => (window.__perm = 'granted'), (e) => (window.__perm = 'error:' + e.code)); true",
        userGesture: true,
      });
      return until("the pop-up window's permission sheet", shown, 10000);
    };
    const stillAsking = async (what, detail) => {
      await sleep(300);
      const now = { sheet: !!(await shown()), page: await answer() };
      if (!now.sheet || now.page !== "pending") throw new Error(`${what} answered the sheet: ${JSON.stringify(now)} (${detail})`);
    };
    const armed = () => until("Allow enabled after the input delay", async () => ((await shown())?.allowEnabled ? true : null), 3000);
    const enabled = await cef(`devWindow(${popup.window}, "alertSheets:1")`);
    if (enabled !== "1") throw new Error(`real sheets unavailable: ${enabled}`);
    try {
      const prompt = await ask();
      const returnKey = () => cef(`devWindow(${prompt.sheetWindow}, "keys:0:\\r:36")`);
      if (prompt.allowEnabled) throw new Error("Allow took input as soon as the sheet appeared");
      await stillAsking("Return right after the sheet appeared", await returnKey());
      await armed();
      await stillAsking("Return once Allow was enabled", await returnKey());
      const expected = `${new URL(base).protocol}//${new URL(base).host}`;
      if (!prompt.question.includes(expected)) throw new Error(`the question doesn't name ${expected}: ${prompt.question}`);
      const space = await cef(`devWindow(${prompt.sheetWindow}, "keys:0: :49")`);
      let afterSpace = await until("Space's answer", async () => ((await answer()) !== "pending" ? answer() : null), 5000).catch(() => "pending");
      if (afterSpace === "granted") throw new Error(`Space granted the permission (${space})`);
      let spaceNote = "Space answered the sheet";
      if (afterSpace === "pending") {
        const focused = await cef(`devWindow(${prompt.sheetWindow}, "responder")`);
        if (/button/i.test(focused)) throw new Error(`Space on the focused ${focused} left the sheet unanswered (${space})`);
        spaceNote = `no button had focus (${focused}): a hidden instance's sheet never becomes key, so its initial first responder, Don't Allow, isn't applied and Space has nothing to press`;
        await cef(`devWindow(${prompt.sheetWindow}, "keys:0:\\u001b:53")`);
        afterSpace = await until("Escape's answer", async () => ((await answer()) !== "pending" ? answer() : null), 5000);
        if (afterSpace === "granted") throw new Error("Escape granted the permission");
      }
      await cef(`setSiteSetting("", "${base}", "location", "default")`);
      await until("the sheet gone", async () => ((await shown()) ? null : true), 5000);

      const geo = async () => (await cdp(t, "Runtime.evaluate", { expression: "outerWidth + 'x' + outerHeight + ' at ' + screenX + ',' + screenY", returnByValue: true })).result.value;
      const second = await ask();
      const geometryBefore = await geo();
      await cdp(t, "Runtime.evaluate", { expression: "window.moveBy(25, 15); window.resizeTo(outerWidth + 40, outerHeight + 30); true", userGesture: true });
      const pageMoves = { before: geometryBefore, after: await geo() };
      const rearms = {};
      for (const name of ["NSWindowDidMoveNotification", "NSWindowDidResizeNotification", "NSWindowDidChangeOcclusionStateNotification"]) {
        await armed();
        await cef(`devWindow(${popup.window}, "postNotification:window:${name}")`);
        const now = await shown();
        if (now.allowEnabled) throw new Error(`Allow stayed enabled after ${name}`);
        const [x, y] = now.allowAt;
        await stillAsking(`A click on Allow right after ${name}`, await cef(`devWindow(${second.sheetWindow}, "click:${x},${y}")`));
        rearms[name] = [x, y];
      }
      await armed();
      const [cx, cy] = (await shown()).allowAt;
      await cef(`devWindow(${second.sheetWindow}, "click:${cx},${cy}")`);
      await until("a deliberate click on Allow answers the sheet", async () => ((await shown()) ? null : true), 5000);
      await sleep(500);
      const control = await answer();
      if (control === "error:1") throw new Error("a click on Allow once it was enabled was taken as a denial");
      const granted = (await cef(`getSiteSettings("", ${JSON.stringify(base)})`)).location;
      if (granted?.value !== "allow") throw new Error(`a click on Allow once it was enabled didn't grant the site location: ${JSON.stringify(granted)}`);
      return { question: prompt.question, afterSpace, spaceNote, pageMoves, rearms, control, granted: granted.value };
    } finally {
      await cef(`devWindow(${popup.window}, "alertSheets:0")`).catch(() => {});
      await closeFromPage(t).catch(() => {});
      await cef(`setSiteSetting("", "${base}", "location", "default")`).catch(() => {});
    }
  });

  await check("popup-origin-strip", async () => {
    const lan = Object.values(networkInterfaces()).flat().find((i) => i?.family === "IPv4" && !i.internal)?.address;
    if (!lan) throw new Error("no non-loopback IPv4 address to serve an http pop-up from");
    const plain = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end("<!doctype html><title>strip</title>plain http");
    });
    await new Promise((r) => plain.listen(0, lan, r));
    const url = `http://${lan}:${plain.address().port}/strip-page`;
    try {
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      const opener = await pageFor(first.id, `${base}/a`);
      const popups = async () => (await cef(`engineInfo()`)).popupWindows;
      const before = await popups();
      await cdp(opener, "Runtime.evaluate", { expression: `window.open("${url}", "strip", "width=480,height=360"); true`, userGesture: true });
      const t = await until("the http pop-up's page", () => pageTarget("/strip-page"));
      let last = null;
      const strip = await until("the strip marks the http pop-up not secure", async () => {
        last = (await cef(`engineInfo()`)).popupOrigins.find((o) => o.origin.includes(lan)) ?? null;
        return last?.symbol === "lock.open.trianglebadge.exclamationmark.fill" ? last : null;
      }, 10000).catch(() => { throw new Error(`strip ${JSON.stringify(last)}`); });
      await closeFromPage(t);
      await until("the pop-up closed", async () => ((await popups()) === before ? true : null), 10000);
      if (strip.description !== "Connection is not secure") throw new Error(`strip ${JSON.stringify(strip)}`);
      return strip;
    } finally {
      plain.close();
    }
  });

  await check("download", async () => {
    await evalApp(`ac.actions.openUrls(["${base}/file.bin"], ${JSON.stringify(mainWindow)}); return true`);
    const d = await until("the finished download", async () => {
      const list = await evalApp(`return ac.store.getState().downloads.map((d) => ({ id: d.id, state: d.state, filename: d.filename, path: d.path, received: d.received }))`);
      return list.find((x) => x.filename?.includes("solaracore-test") && x.state === "finished") ?? null;
    }, 20000);
    const quarantine = (() => { try { return execFileSync("xattr", ["-p", "com.apple.quarantine", d.path]).toString().trim(); } catch { return null; } })();
    const froms = (() => {
      try {
        const hex = execFileSync("xattr", ["-px", "com.apple.metadata:kMDItemWhereFroms", d.path]).toString().replace(/\s+/g, "");
        return JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", "-"], { input: Buffer.from(hex, "hex") }).toString());
      } catch { return []; }
    })();
    await closeDownloads();
    if (!d.path.startsWith(downloadsDir)) throw new Error(`downloaded to ${d.path}, not the scratch dir`);
    if (!quarantine) throw new Error(`${d.path} has no com.apple.quarantine when it's finished`);
    if (!froms.includes(`${base}/file.bin`)) throw new Error(`${d.path} doesn't say where it came from: ${JSON.stringify(froms)}`);
    return { ...d, quarantine, froms };
  });

  await check("site-settings", async () => {
    const origin = "https://settings.test";
    await cef(`setSiteSetting("", "${origin}", "popups", "allow")`);
    const settings = await until("the setting", async () => {
      const s = await cef(`getSiteSettings("", "${origin}")`);
      return s?.popups?.value === "allow" ? s : null;
    });
    const origins = await cef(`getSiteSettingsOrigins("")`);
    await cef(`resetSiteSettings("", "${origin}")`);
    const cleared = await cef(`clearSiteData("", "${origin}")`);
    return { popups: settings.popups, origins: origins.length, cleared };
  });

  await check("site-data-clear", async () => {
    const one = `https://one.${siteDataDomain}`, two = `https://two.${siteDataDomain}`;
    const read = async (url) => {
      const tab = await openTab(url, "Site data", true);
      try {
        const t = await until(`${url}'s page`, () => pageTarget(url));
        const r = await cdp(t, "Runtime.evaluate", { expression: `document.cookie.split("; ").filter(Boolean).sort().join("; ") + " | " + localStorage.getItem("kept")`, returnByValue: true });
        return r.result.value;
      } finally {
        await closeTab(tab.id);
      }
    };
    const [secure, thirdParty, elsewhere] = siteDataSecureHosts.map((host) => `https://${host}`);
    const readFrame = async (top, src) => {
      const url = `${top}/frame-host?src=${encodeURIComponent(src)}`;
      const tab = await openTab(url, "Frame host", true);
      try {
        const t = await until(`${url}'s page`, () => pageTarget("/frame-host"));
        return await until(`the frame's report on ${top}`, async () => (await cdp(t, "Runtime.evaluate", { expression: "window.__frame", returnByValue: true })).result.value ?? null);
      } finally {
        await closeTab(tab.id);
      }
    };
    const persisted = async () => {
      const tab = await openTab(`${secure}/site-data`, "Site data", true);
      try {
        const t = await until("the secure page", () => pageTarget(`${secure}/site-data`));
        return (await cdp(t, "Runtime.evaluate", { expression: "navigator.storage.persisted()", awaitPromise: true, returnByValue: true })).result.value;
      } finally {
        await closeTab(tab.id);
      }
    };
    await cef(`setSiteSetting("", "${secure}", "notifications", "allow")`);
    const persistTab = await openTab(`${secure}/site-data`, "Site data", true);
    try {
      const t = await until("the secure page", () => pageTarget(`${secure}/site-data`));
      await cdp(t, "Runtime.evaluate", { expression: "navigator.storage.persist()", awaitPromise: true, returnByValue: true });
    } finally {
      await closeTab(persistTab.id);
    }
    const before = {
      one: await read(`${one}/site-data?set`), two: await read(`${two}/site-data`),
      embeddedOnSite: await readFrame(secure, `${thirdParty}/frame-probe?set`),
      siteEmbeddedElsewhere: await readFrame(elsewhere, `${secure}/frame-probe?set`),
      persisted: await persisted(),
    };
    if (before.one !== "domain_wide=1; host_only=1 | yes" || before.two !== "domain_wide=1 | null") throw new Error(`the fixture's data: ${JSON.stringify(before)}`);
    for (const k of ["embeddedOnSite", "siteEmbeddedElsewhere"])
      if (before[k]?.cookie !== "chips=1" || before[k]?.ls !== "yes") throw new Error(`the fixture's partitioned data: ${JSON.stringify(before)}`);
    if (before.persisted !== true) throw new Error(`persistent storage wasn't granted: ${JSON.stringify(before)}`);
    const cleared = await cef(`clearSiteData("", "${one}")`);
    const after = {
      one: await read(`${one}/site-data`), two: await read(`${two}/site-data`),
      embeddedOnSite: await readFrame(secure, `${thirdParty}/frame-probe`),
      siteEmbeddedElsewhere: await readFrame(elsewhere, `${secure}/frame-probe`),
      persisted: await persisted(),
      notifications: (await cef(`getSiteSettings("", "${secure}")`))?.notifications?.value,
    };
    await cef(`resetSiteSettings("", "${secure}")`);
    const wrong = [];
    if (after.one !== " | null" || after.two !== " | null") wrong.push("the site's own cookies or storage");
    if (after.embeddedOnSite?.cookie !== "" || after.embeddedOnSite?.ls !== null) wrong.push("a third party's data stored under the site");
    if (after.siteEmbeddedElsewhere?.cookie !== "chips=1" || after.siteEmbeddedElsewhere?.ls !== "yes") wrong.push("the site's data stored under another site (Chrome keeps it)");
    if (after.persisted !== false) wrong.push("the persistent-storage grant (Chrome resets it)");
    if (after.notifications !== "allow") wrong.push("the notifications permission (a setting, not data)");
    if (cleared.cookies !== 3 || !cleared.storage) wrong.push(`the reply ${JSON.stringify(cleared)}`);
    if (wrong.length) throw new Error(`${wrong.join("; ")}: ${JSON.stringify({ before, cleared, after })}`);
    return { before, cleared, after };
  });

  await check("passwords-more", async () => {
    const origin = "https://more.test";
    await cef(`savePassword("", "${origin}", "olduser", "pw1")`);
    const updated = await cef(`updatePassword("", "${origin}", "olduser", "newuser", "pw2")`);
    if (updated?.error) throw new Error(`update: ${updated.error}`);
    const revealed = await until("the edited login", async () => {
      const r = await cef(`getPassword("", "${origin}", "newuser")`);
      return r?.password === "pw2" ? r : null;
    });
    const unlocked = await cef(`unlockPasswords("")`);
    const never = await cef(`getNeverSavePasswordOrigins("")`);
    const allowed = await cef(`allowSavingPasswords("", "https://never.test")`);
    const file = join(scratch, "passwords.csv");
    writeFileSync(join(data, "file-chooser.txt"), file + "\n");
    const exported = await cef(`exportPasswords("")`);
    const written = await until("the export file", async () => existsSync(file) && readFileSync(file, "utf8").includes("newuser"), 10000);
    await cef(`deletePassword("", "${origin}", "newuser")`);
    return { updated: revealed.password, unlocked, never: never?.origins?.length ?? never, allowed, exported: exported?.status ?? exported, written };
  });

  await check("autofill-cards", async () => {
    const saved = await cef(`saveCard("", { name: "Acceptance Test", expMonth: 12, expYear: 2031 }, "4111111111111111")`);
    if (saved?.error) throw new Error(`save: ${saved.error}`);
    const card = await until("the card listed", async () => {
      const r = await cef(`listCards("")`);
      return r?.cards?.find((c) => c.id === saved.id) ?? null;
    });
    const number = await cef(`revealCardNumber("", "${saved.id}")`);
    if (number?.number !== "4111111111111111") throw new Error(`reveal: ${JSON.stringify(number)}`);
    await cef(`deleteAutofillEntry("", "${saved.id}")`);
    await until("the card gone", async () => !(await cef(`listCards("")`))?.cards?.some((c) => c.id === saved.id));
    await cef(`setAutofillSettings("", null, false)`);
    const off = await cef(`getAutofillSettings("")`);
    await cef(`setAutofillSettings("", null, true)`);
    if (off.cards !== false) throw new Error(`cards setting: ${JSON.stringify(off)}`);
    return { card: { last4: card.lastFour ?? card.last4 ?? null, name: card.name }, revealed: true, cardsOff: true };
  });

  await check("autofill-save-prompts", async () => {
    const prompts = async () => (await eventsOf(first.id)).filter((x) => x.name === "autofillPrompt");
    const lastId = async () => Math.max(0, ...(await prompts()).map((x) => x.payload.id));
    const offerAfter = (id, what) =>
      until(what, async () => (await prompts()).findLast((x) => !x.payload.closed && x.payload.id > id)?.payload ?? null, 10000);
    const closed = async (id) => (await prompts()).some((x) => x.payload.closed && x.payload.id === id);
    const appPrompt = () => evalApp(`return ac.pageState.getState().pages[${JSON.stringify(first.id)}]?.autofillPrompt ?? null`);
    const answer = (id, action) => evalApp(`return ac.webviews.get(${JSON.stringify(first.id)}).resolveAutofillPrompt(${id}, ${JSON.stringify(action)})`);
    const addresses = async (profile = "") => (await cef(`listAddresses(${JSON.stringify(profile)})`))?.addresses ?? [];
    const cards = async (profile = "") => (await cef(`listCards(${JSON.stringify(profile)})`))?.cards ?? [];
    const sendForm = async (path, title, values) => {
      await evalApp(`ac.store.getState().navigate(${JSON.stringify(first.id)}, ${JSON.stringify(secureBase + path)}, { userInitiated: true }); return true`);
      await until(title, async () => (await state()).tabs.find((x) => x.id === first.id && x.title === title && x.url?.endsWith(path) && !x.loading), 15000);
      const t = await pageFor(first.id, path);
      for (const [id, text] of values) {
        await cdp(t, "Runtime.evaluate", { expression: `document.getElementById(${JSON.stringify(id)}).focus()` });
        await cdp(t, "Input.insertText", { text });
      }
      const box = JSON.parse((await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('go').getBoundingClientRect())", returnByValue: true })).result.value);
      const at = { x: box.x + box.width / 2, y: box.y + box.height / 2, button: "left", clickCount: 1 };
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at, buttons: 1 });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at, buttons: 0 });
      await until("the form sent", async () => (await state()).tabs.find((x) => x.id === first.id && x.title === "Saved" && !x.loading), 15000);
    };
    const address = [["name", "Jane Doe"], ["street", "1 Meadow Lane"], ["city", "Springfield"], ["state", "IL"], ["zip", "62701"], ["country", "United States"]];
    const card = (number, name) => [["ccname", name], ["ccnumber", number], ["ccmonth", "12"], ["ccyear", "2031"]];
    let profileB = null;
    let other = null;
    try {
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(first.id)}); return true`);
      await until("A shown", async () => (await state()).active === first.id);
      const saveSeen = await lastId();

      await sendForm("/address", "Address", address);
      const save = await offerAfter(saveSeen, "the save-address offer");
      if (save.kind !== "saveAddress" || !save.title || !save.accept || !save.decline || !JSON.stringify(save.lines).includes("Springfield"))
        throw new Error(`save offer ${JSON.stringify(save)}`);
      const shown = await until("the offer in the app", async () => ((await appPrompt())?.id === save.id ? true : null), 5000);
      await answer(save.id, "accept");
      const saved = await until("the address saved", async () => (await addresses()).find((a) => a.city === "Springfield") ?? null);
      await until("the offer gone from the page", async () => ((await appPrompt()) === null ? true : null), 5000);

      const email = "big.mascot@example.com";
      let seen = await lastId();
      await sendForm("/address?email", "Address", [...address.slice(0, 1), ["email", email], ...address.slice(1)]);
      const update = await offerAfter(seen, "the update-address offer");
      if (update.kind !== "updateAddress" || !JSON.stringify(update.changes ?? []).includes(email))
        throw new Error(`update offer ${JSON.stringify(update)}`);
      other = await openTab(`${base}/b`, "Page B");
      await until("the offer closed by the tab switch", () => closed(update.id), 8000);
      await evalApp(`ac.actions.switchToTab(${JSON.stringify(first.id)}); return true`);
      await until("A shown again", async () => (await state()).active === first.id);
      await sleep(1500);
      if (await appPrompt()) throw new Error(`the offer came back after the tab switch: ${JSON.stringify(await appPrompt())}`);
      if ((await addresses()).some((a) => a.email === email)) throw new Error("the ignored update was saved");

      seen = await lastId();
      await sendForm("/address?email", "Address", [...address.slice(0, 1), ["email", email], ...address.slice(1)]);
      const update2 = await offerAfter(seen, "the update offer again");
      if (update2.kind !== "updateAddress") throw new Error(`second update offer ${JSON.stringify(update2)}`);
      const s = await state();
      profileB = await evalApp(`return ac.store.getState().createProfile({ name: "Prompts" })`);
      await evalApp(`ac.actions.switchProfile(${JSON.stringify(s.windowId)}, ${JSON.stringify(profileB)}); return true`);
      await until("profile B shown", async () => (await state()).profileId === profileB);
      await sleep(1000);
      await evalApp(`ac.actions.switchProfile(${JSON.stringify(s.windowId)}, ${JSON.stringify(s.profileId)}); return true`);
      await until("profile A back", async () => (await state()).profileId === s.profileId && (await state()).active === first.id);
      await sleep(500);
      const kept = await appPrompt();
      if (kept?.id !== update2.id) throw new Error(`after the profile switch the page offers ${JSON.stringify(kept)}`);
      if (await closed(update2.id)) throw new Error("the profile switch closed the offer");
      await answer(update2.id, "accept");
      const updated = await until("the address updated", async () => (await addresses()).find((a) => a.email === email) ?? null);
      if ((await addresses()).length !== 1) throw new Error(`addresses ${JSON.stringify(await addresses())}`);
      if ((await addresses(profileB)).length) throw new Error("profile B got the address");

      seen = await lastId();
      await sendForm("/card", "Card", card("4111111111111111", "The mascot"));
      const cardOffer = await offerAfter(seen, "the save-card offer");
      if (cardOffer.kind !== "saveCard" || !JSON.stringify(cardOffer.lines).includes("1111")) throw new Error(`card offer ${JSON.stringify(cardOffer)}`);
      await answer(cardOffer.id, "accept");
      const savedCard = await until("the card saved", async () => (await cards()).find((c) => c.last4 === "1111") ?? null);
      seen = await lastId();
      await sendForm("/card", "Card", card("5555555555554444", "The mascot"));
      const declined = await offerAfter(seen, "the second card's offer");
      await answer(declined.id, "decline");
      await until("the declined offer closed", () => closed(declined.id), 5000);
      await sleep(1000);
      if ((await cards()).some((c) => c.last4 === "4444")) throw new Error("the declined card was saved");
      await answer(cardOffer.id, "accept");
      return {
        save: { title: save.title, accept: save.accept, decline: save.decline, lines: save.lines, shown },
        saved: { name: saved.name, city: saved.city },
        update: { title: update.title, changes: update.changes, closedOnTabSwitch: true, keptOverProfileSwitch: true },
        updated: { email: updated.email },
        card: { title: cardOffer.title, lines: cardOffer.lines, saved: savedCard.last4, declined: true },
      };
    } finally {
      for (const a of await addresses().catch(() => [])) await cef(`deleteAutofillEntry("", ${JSON.stringify(a.id)})`).catch(() => null);
      for (const c of await cards().catch(() => [])) await cef(`deleteAutofillEntry("", ${JSON.stringify(c.id)})`).catch(() => null);
      if (other) await closeTab(other.id).catch(() => null);
      if (profileB) await evalApp(`ac.store.getState().deleteProfile(${JSON.stringify(profileB)}); return true`).catch(() => null);
      await backToA();
    }
  });

  await check("settings-services", async () => {
    await evalApp(`return globalThis.expo.modules.SolaraCEF.clearBrowsingData("", ["cache", "history"], null)`, 90000);
    await cef(`setSiteSetting("", "https://reset.test", "sound", "block")`);
    await cef(`resetSiteSettings("", "https://reset.test")`);
    const reset = await until("the site reset", async () => {
      const r = await cef(`getSiteSettings("", "https://reset.test")`);
      return r?.sound?.isDefault ? r.sound : null;
    });
    const before = await cef(`getContentBlocker()`);
    await cef(`setContentBlockerEnabled(false)`);
    const off = await until("the blocker off", async () => ((await cef(`getContentBlocker()`)).enabled === false ? true : null), 15000);
    await cef(`setContentBlockerEnabled(true)`);
    await until("the blocker on", async () => ((await cef(`getContentBlocker()`)).enabled === true ? true : null), 15000);
    const list = before.lists.find((l) => !l.enabled) ?? before.lists[0];
    await cef(`setFilterListEnabled(${JSON.stringify(list.id)}, ${!list.enabled})`);
    const toggled = await until("the list toggled", async () =>
      (await cef(`getContentBlocker()`)).lists.find((l) => l.id === list.id)?.enabled === !list.enabled ? true : null, 20000);
    await cef(`setFilterListEnabled(${JSON.stringify(list.id)}, ${list.enabled})`);
    await cef(`removeExternalAppAllowance("", "https://none.test", "solaracore-no-such-app")`);
    const siteData = await evalApp(`return ac.webviews.get("${first.id}")?.clearSiteData() ?? null`);
    if (!siteData || siteData.error) throw new Error(`clearSiteData: ${JSON.stringify(siteData)}`);
    return { reset: reset.value, blockerOff: off, list: list.id, toggled, siteData };
  });

  await check("download-controls", async () => {
    await evalApp(`ac.actions.openUrls(["${base}/slow.bin"], ${JSON.stringify(mainWindow)}); return true`);
    const find = () => evalApp(`return ac.store.getState().downloads.map((d) => ({ id: d.id, state: d.state, paused: d.paused, filename: d.filename, received: d.received }))`)
      .then((l) => l.find((x) => x.filename?.includes("solaracore-slow")) ?? null);
    try {
      const d = await until("the slow download running", async () => { const x = await find(); return x?.state === "downloading" && !x.paused && x.received > 0 ? x : null; }, 15000);
      await cef(`pauseDownload("${d.id}")`);
      await until("paused", async () => ((await find())?.paused ? true : null), 8000);
      await cef(`resumeDownload("${d.id}")`);
      await until("running again", async () => { const x = await find(); return x?.state === "downloading" && !x.paused ? true : null; }, 8000);
      await cef(`cancelDownload("${d.id}")`);
      const last = await until("cancelled", async () => { const x = await find(); return x?.state === "cancelled" ? x : null; }, 8000);
      return { id: d.id, state: last.state };
    } finally {
      await closeDownloads();
    }
  });

  await check("tasks-components", async () => {
    const tasks = await until("tasks", async () => {
      const t = await cef(`listTasks()`);
      return t.length ? t : null;
    });
    const components = await cef(`components()`);
    const allowances = await cef(`getExternalAppAllowances("")`);
    return { tasks: tasks.length, browserTasks: tasks.filter((t) => t.browserIds.length).length, components: components.length, allowances: allowances.length };
  });

  await check("download-navigation", async () => {
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/file.bin?nav", { userInitiated: true }); return true`);
    const e = await until("onDownloadNavigation", async () => (await eventsOf(first.id)).find((x) => x.name === "downloadNavigation"), 15000);
    return e.payload;
  });

  await check("tracing", async () => {
    const started = await cef(`beginTracing()`);
    const during = await cef(`isTracing()`);
    const path = await cef(`endTracing(false)`);
    const after = await cef(`isTracing()`);
    if (!started || !during || after) throw new Error(`tracing ${started} ${during} ${after}`);
    return { started, during, after, path };
  });

  await check("delete-profile-data", async () => {
    const folder = join(data, "Chromium", "Profile scratch-delete");
    await cef(`listPasswords("scratch-delete")`);
    await until("the profile loaded", async () => existsSync(folder), 10000);
    await webKit(`devTouchStore("scratch-delete")`);
    if (!(await webKit(`devStoreExists("scratch-delete")`))) throw new Error("the profile's WebKit store wasn't made");
    const pending = JSON.stringify(["Chromium deletion pending restart"]);
    const result = await cef(`deleteProfileData("scratch-delete")`);
    if (JSON.stringify(result.remaining) !== pending) throw new Error(`a loaded profile's Chromium data should wait for the next launch: ${JSON.stringify(result)}`);
    const again = await cef(`deleteProfileData("scratch-delete")`);
    if (JSON.stringify(again.remaining) !== pending) throw new Error(`a second delete while one is pending: ${JSON.stringify(again)}`);
    if (!(await webKit(`deleteProfileData("scratch-delete")`))) throw new Error("the profile's WebKit store wasn't removed");
    if (await webKit(`devStoreExists("scratch-delete")`)) throw new Error("the profile's WebKit store is still on disk");
    await webKit(`devTouchStore("scratch-held")`);
    await webKit(`devHoldStore("scratch-held")`);
    if (await webKit(`deleteProfileData("scratch-held")`)) throw new Error("a held WebKit store reported removed");
    if (!(await webKit(`devStoreExists("scratch-held")`))) throw new Error("a held WebKit store went missing");
    const shown = (await cef(`chromeWindows()`)).filter((w) => w.visible || w.alpha >= 0).map((w) => w.profile);
    if (shown.includes("scratch-delete")) throw new Error(`a window still shows the deleted profile: ${JSON.stringify(shown)}`);
    return { ...result, pendingRestart: true, windowProfiles: shown };
  });

  // MARK: Page events

  await check("page-events", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A's WebView", async () => evalApp(`return !!ac.webviews.get("${first.id}")`), 8000);
    await evalApp(`return ac.webviews.get("${first.id}").zoomStep(1)`);
    const zoom = await until("onZoom", async () => (await eventsOf(first.id)).filter((x) => x.name === "zoom").pop(), 8000);
    await evalApp(`return ac.webviews.get("${first.id}").zoomStep(0)`);
    const security = await evalApp(`return ac.webviews.get("${first.id}").getSecurityInfo()`);
    const s = await state();
    await evalApp(`return ac.webviews.get("${first.id}").focus()`);
    await sleep(300);
    const sent = await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "\u001b", keyCode: 53, modifiers: [], focus: "page" })`);
    const escape = await until("onCommand escape", async () => (await eventsOf(first.id)).find((x) => x.name === "command" && x.payload?.command === "escape"), 5000)
      .catch(async (e) => {
        const profile = await evalApp(`const s = ac.store.getState(); return s.windows["${s.windowId}"]?.profileId ?? null`);
        const pt = await pageFor(first.id, `${base}/a`);
        const vis = (await cdp(pt, "Runtime.evaluate", { expression: "document.visibilityState + '/' + document.hasFocus()", returnByValue: true })).result.value;
        const tx = await evalApp(`return globalThis.expo.modules.SolaraCEF.tabStrips()`);
        const chromeActive = tx.strips.map((st) => st.tabs.find((x) => x.active)?.key ?? null);
        throw new Error(`${e.message}; key: ${JSON.stringify(sent)}; window profile: ${profile}; active: ${(await state()).active}; Chrome's active: ${JSON.stringify(chromeActive)}; page ${vis}`);
      });
    const t = await pageFor(first.id, `${base}/a`);
    await cdp(t, "Runtime.evaluate", { expression: "location.href = 'solaracore-no-such-app://hello'", userGesture: true });
    const external = await until("onExternalApp", async () => evalApp(`return ac.pageState.getState().pages["${first.id}"]?.externalApp ?? null`), 10000);
    const securityEvent = (await eventsOf(first.id)).some((x) => x.name === "security");
    if (!securityEvent) throw new Error("no onSecurity");
    const focused = (await eventsOf(first.id)).some((x) => x.name === "focus");
    const other = await openTab(`${base}/d?page-events`, "Page D", true);
    let activate = null;
    try {
      const ot = await until("the background page", () => pageTarget(`${base}/d?page-events`), 10000);
      await cdp(ot, "Runtime.evaluate", { expression: "window.focus()", userGesture: true });
      activate = await until("onActivateRequest", async () => (await eventsOf(other.id)).find((x) => x.name === "activateRequest"), 3000).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    } finally {
      await closeTab(other.id).catch(() => null);
    }
    return { zoom: zoom.payload.zoom, security: security?.level, securityEvent, focused, activate: activate?.payload?.reason ?? null,
      external: { scheme: external.scheme, app: external.app }, escape: escape.payload.command };
  });

  await check("page-background", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    const pixel = async (t) => {
      const shot = await cdp(t, "Page.captureScreenshot", { format: "png", clip: { x: 600, y: 400, width: 1, height: 1, scale: 1 } });
      return firstPixel(shot.data);
    };
    const visit = async (path, title) => {
      await evalApp(`ac.store.getState().navigate("${first.id}", "${base}${path}", { userInitiated: true }); return true`);
      await until(`the ${title} page`, async () => (await state()).tabs.find((t) => t.id === first.id && t.title === title && !t.loading), 10000);
      await sleep(500);
      return pixel(await pageFor(first.id, `${base}${path}`));
    };
    const plain = await pixel(await pageFor(first.id, `${base}/a`));
    await evalApp(`return ac.webviews.get("${first.id}").reload()`);
    await sleep(1000);
    await until("A reloaded", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading), 10000);
    await sleep(500);
    const reloaded = await pixel(await pageFor(first.id, `${base}/a`));
    let painted, darkScheme;
    try {
      painted = await visit("/painted", "Painted");
      darkScheme = await visit("/scheme-dark", "Dark scheme");
    } finally {
      await backToA();
    }
    await sleep(500);
    const after = await pixel(await pageFor(first.id, `${base}/a`));
    const near = (a, b) => a.every((v, i) => Math.abs(v - b[i]) <= 3);
    const white = [255, 255, 255, 255];
    const result = { plainPage: plain, reloaded, paintedPage: painted, darkSchemePage: darkScheme, afterPainted: after };
    if (!near(plain, white) || !near(reloaded, white) || !near(after, white))
      throw new Error(`a page with no background isn't on Chrome's white canvas: ${JSON.stringify(result)}`);
    if (!near(darkScheme, [18, 18, 18, 255])) throw new Error(`the color-scheme: dark page isn't on Chrome's dark canvas: ${JSON.stringify(result)}`);
    if (!near(painted, [60, 60, 60, 255])) throw new Error(`the painted page shows ${JSON.stringify(painted)}`);
    return result;
  });

  await check("appearance-reaches-pages", async () => {
    const shell = "globalThis.expo.modules.SolaraShell";
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    const prefersDark = async () => (await cdp(await pageFor(first.id, `${base}/a`), "Runtime.evaluate", { expression: "matchMedia('(prefers-color-scheme: dark)').matches", returnByValue: true })).result?.value;
    const seen = [];
    try {
      for (const mode of ["light", "dark", "light"]) {
        const wantDark = mode === "dark";
        await evalApp(`return ${shell}.setAppearance("${mode}")`);
        await until(`the app in ${mode}`, async () => (await evalApp(`return ${shell}.isDarkAppearance()`)) === wantDark, 5000);
        const followed = await until(`the page's prefers-color-scheme to follow ${mode}`, async () => (await prefersDark()) === wantDark, 5000).then(() => true, () => false);
        seen.push({ mode, pagePrefersDark: await prefersDark() });
        if (!followed) throw new Error(`the app is ${mode} but the page still answers prefers-color-scheme: dark = ${!wantDark}: ${JSON.stringify(seen)}`);
      }
    } finally {
      await evalApp(`return ${shell}.setAppearance("auto")`).catch(() => null);
    }
    return seen;
  });

  await check("external-app-answer", async () => {
    const running = () => { try { return execFileSync("pgrep", ["-x", "Shortcuts"]).toString().trim().length > 0; } catch { return false; } };
    const wasRunning = running();
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    const ask = async (n) => {
      await evalApp(`ac.pageState.setState((s) => ({ pages: { ...s.pages, "${first.id}": { ...s.pages["${first.id}"], externalApp: null } } })); return true`);
      const t = await pageFor(first.id, `${base}/a`);
      for (const type of ["mousePressed", "mouseReleased"])
        await cdp(t, "Input.dispatchMouseEvent", { type, x: 600, y: 400, button: "left", clickCount: 1 });
      await cdp(t, "Runtime.evaluate", { expression: `location.href = 'shortcuts://solaracore-acceptance-${n}'`, userGesture: true });
      return until(`prompt ${n}`, async () => evalApp(`return ac.pageState.getState().pages["${first.id}"]?.externalApp ?? null`), 10000);
    };
    const decline = async (request) => {
      await evalApp(`ac.pageState.setState((s) => ({ pages: { ...s.pages, "${first.id}": { ...s.pages["${first.id}"], externalApp: null } } }));
        return globalThis.expo.modules.SolaraCEF.resolveExternalApp(${JSON.stringify(request.id)}, false, true).then(() => true)`);
      await sleep(1500);
    };
    const firstAsk = await ask(1);
    if (!firstAsk.app || !firstAsk.appPath?.endsWith("Shortcuts.app")) throw new Error(`no app found: ${JSON.stringify({ ...firstAsk, icon: !!firstAsk.icon })}`);
    if (!firstAsk.remember) throw new Error("no \"always allow\" offered for a trustworthy origin");
    await decline(firstAsk);
    const allowances = await cef(`getExternalAppAllowances("")`);
    if (JSON.stringify(allowances).includes("shortcuts")) throw new Error(`Chrome recorded an allowance: ${JSON.stringify(allowances)}`);
    const again = await ask(2);
    if (again.id === firstAsk.id) throw new Error("the second link reused the first request");
    await decline(again);
    const third = await ask(3);
    await evalApp(`ac.pageState.setState((s) => ({ pages: { ...s.pages, "${first.id}": { ...s.pages["${first.id}"], externalApp: null } } }));
      return globalThis.expo.modules.SolaraCEF.resolveExternalApp(${JSON.stringify(third.id)}, true, true).then(() => true)`);
    const launch = await until("the recorded launch", async () =>
      (await cef(`devExternalLaunches()`)).find((l) => l.url?.includes("solaracore-acceptance-3")) ?? null, 8000);
    const remembered = await until("Chrome's allowance", async () => {
      const list = await cef(`getExternalAppAllowances("")`);
      return list.find((a) => a.scheme === "shortcuts") ?? null;
    }, 8000);
    await cef(`removeExternalAppAllowance("", ${JSON.stringify(remembered.origin)}, "shortcuts")`);
    const after = await cef(`getExternalAppAllowances("")`);
    if (after.some((a) => a.scheme === "shortcuts")) throw new Error(`the allowance stayed: ${JSON.stringify(after)}`);
    if (!wasRunning && running()) throw new Error("Shortcuts was launched");
    return { app: firstAsk.app, origin: firstAsk.origin, remember: firstAsk.remember, icon: !!firstAsk.icon,
      declined: [firstAsk.id, again.id], allowancesAfterDecline: allowances.length, opened: launch, allowance: remembered,
      removed: true, launched: false };
  });

  await check("notifications", async () => {
    await cef(`setSiteSetting("", "${base}", "notifications", "allow")`);
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    const t = await pageFor(first.id, `${base}/a`);
    const snapshot = () => cef("notificationDebugSnapshot()");
    const routeFor = async (title) => until(`native document route ${title}`, async () => {
      const value = await snapshot();
      const native = value.hub.delivered.find((row) => row.title === title);
      const route = value.routes.find((row) => row.nativeID === native?.nativeID && row.accepted && !row.withdrawn);
      return route ? { ...route, title } : null;
    }, 8000);
    const nativeConstructor = await cdp(t, "Runtime.evaluate", { expression: "Function.prototype.toString.call(Notification)", returnByValue: true });
    assert.match(nativeConstructor.result.value, /\[native code\]/, "Blink owns the Notification constructor");
    await cdp(t, "Runtime.evaluate", {
      expression: "window.__clicked = false; window.__documentNotification = new Notification('Acceptance', { body: 'hello', tag: 'ac' }); window.__documentNotification.onclick = () => (window.__clicked = true); true",
      userGesture: true,
    });
    const route = await routeFor("Acceptance");
    const response = await evalApp(`return globalThis.expo.modules.SolaraApp.notificationDebugRespond(${JSON.stringify(route.nativeID)}, "com.apple.UNNotificationDefaultActionIdentifier")`);
    assert.equal(response.accepted, true);
    const clicked = await until("the native document listener click", async () => (await cdp(t, "Runtime.evaluate", { expression: "window.__clicked", returnByValue: true })).result.value === true, 8000);
    await cdp(t, "Runtime.evaluate", { expression: "window.__documentNotification.close(); window.__closed = 0; window.__n2 = new Notification('Second'); window.__n2.onclose = () => window.__closed++; true", userGesture: true });
    const second = await routeFor("Second");
    await cdp(t, "Runtime.evaluate", { expression: "window.__n2.close(); true" });
    await until("programmatic document removal", async () => !(await snapshot()).hub.delivered.some((row) => row.nativeID === second.nativeID), 8000);
    const closed = await until("one Blink close event", async () => (await cdp(t, "Runtime.evaluate", { expression: "window.__closed", returnByValue: true })).result.value === 1, 8000);
    await sleep(500);
    assert.equal((await cdp(t, "Runtime.evaluate", { expression: "window.__closed", returnByValue: true })).result.value, 1);
    const shownCount = async () => (await snapshot()).hub.posts.length;
    const nothingShown = async (expression, what) => {
      const before = await shownCount();
      await cdp(t, "Runtime.evaluate", { expression, userGesture: true });
      await sleep(1000);
      const pagePermission = (await cdp(t, "Runtime.evaluate", { expression: "Notification.permission", returnByValue: true })).result.value;
      assert.equal(await shownCount(), before, `no native post ${what}`);
      return pagePermission;
    };
    await cef(`setSiteSetting("", "${base}", "notifications", "block")`);
    const permission = await nothingShown("window.__n3 = new Notification('Blocked'); true", "after the site was blocked");
    await cef(`setSiteSetting("", "${base}", "notifications", "default")`);
    const askPermission = await nothingShown("window.__n4 = new Notification('Unasked'); true", "while the site's setting is Ask");
    await cdp(t, "Runtime.evaluate", { expression: "window.__asked = 'pending'; Notification.requestPermission().then((r) => (window.__asked = r)); true", userGesture: true });
    const request = await until("the notification prompt", async () => evalApp(`return ac.pageState.getState().pages["${first.id}"]?.permission ?? null`), 10000);
    await evalApp(`ac.permissions.answerPermission("${first.id}", "${request.id}", "deny"); return true`);
    const asked = await until("the page's answer", async () => {
      const v = (await cdp(t, "Runtime.evaluate", { expression: "window.__asked", returnByValue: true })).result.value;
      return v !== "pending" ? v : null;
    }, 10000);
    const deniedPermission = await nothingShown("window.__n5 = new Notification('Denied'); true", "after the prompt was denied");
    await cef(`setSiteSetting("", "${base}", "notifications", "default")`);
    return { clicked, closed, nativeConstructor: true, blockedPagePermission: permission, askPagePermission: askPermission, deniedAnswer: asked, deniedPagePermission: deniedPermission };
  });

  await check("now-playing", async () => {
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/media", { userInitiated: true }); return true`);
    await until("the media page", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Media" && !t.loading), 10000);
    await evalApp(`return ac.webviews.get("${first.id}").setMuted(true)`);
    const t = await pageTarget(`${base}/media`);
    await cdp(t, "Runtime.evaluate", {
      expression: "navigator.mediaSession.metadata = new MediaMetadata({ title: 'NN Tone', artist: 'Acceptance' }); window.__play = 'pending'; document.getElementById('tone').play().then(() => (window.__play = 'ok'), (e) => (window.__play = e.name)); true",
      userGesture: true,
    });
    try {
    const playing = await until("onNowPlaying playing", async () =>
      (await eventsOf(first.id)).findLast((x) => x.name === "nowPlaying" && x.payload?.state?.title === "NN Tone" && x.payload?.state?.playbackState === "playing"), 10000);
    await evalApp(`return ac.webviews.get("${first.id}").mediaCommand("pause")`);
    await until("paused by the app", async () => {
      const r = await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('tone').paused", returnByValue: true });
      return r.result.value === true ? true : null;
    }, 8000);
    const media = (await eventsOf(first.id)).filter((x) => x.name === "media").length;
    if (!media) throw new Error("no onMedia while playing");
    return { title: playing.payload.state.title, artist: playing.payload.state.artist, mediaEvents: media };
    } finally {
      await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a", { userInitiated: true }); return true`);
      await until("A again", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading));
      await evalApp(`return ac.webviews.get("${first.id}").setMuted(false)`).catch(() => null);
    }
  });

  // MARK: Media, Picture in Picture, page focus

  await check("media-state", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/media", { userInitiated: true }); return true`);
    await until("the media page", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Media" && !t.loading), 10000);
    try {
      await evalApp(`return ac.webviews.get("${first.id}").setMuted(true)`);
      const mutedEvent = await until("onMedia muted", async () => lastEvent(first.id, "media", (p) => p.muted === true), 5000);
      const t = await pageFor(first.id, `${base}/media`);
      await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('tone').play(); true", userGesture: true });
      const on = await until("onMedia playing", async () => {
        const e = await lastEvent(first.id, "media");
        return e?.payload.playing && e.payload.muted ? e : null;
      }, 8000);
      await until("live.playingAudio", async () => (await live(first.id))?.playingAudio === true, 5000);
      const pausedAt = Date.now();
      await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('tone').pause(); true" });
      const off = await until("onMedia stopped", async () => {
        const e = await lastEvent(first.id, "media");
        return e && !e.payload.playing ? e : null;
      }, 8000);
      const stoppedAfterMs = Date.now() - pausedAt;
      await until("live.playingAudio off", async () => (await live(first.id))?.playingAudio === false, 5000);
      await evalApp(`return ac.webviews.get("${first.id}").setMuted(false)`);
      const unmuted = await until("onMedia unmuted", async () => {
        const e = await lastEvent(first.id, "media");
        return e && e.payload.muted === false ? e : null;
      }, 5000);
      return { muted: mutedEvent.payload, playing: on.payload, stopped: off.payload, stoppedAfterMs, unmuted: unmuted.payload };
    } finally {
      await backToA();
      await evalApp(`return ac.webviews.get("${first.id}").setMuted(false)`).catch(() => null);
    }
  });

  await check("picture-in-picture", async () => {
    const tab = await openTab(`${base}/video`, "Video");
    try {
      await evalApp(`return ac.webviews.get("${tab.id}").setMuted(true)`);
      const t = await startVideo(tab.id, false);
      const click = await pipByHand(tab.id);
      const on = await until("onPictureInPicture video", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "video" && p.active), 5000);
      const element = (await cdp(t, "Runtime.evaluate", { expression: "document.pictureInPictureElement?.id ?? null", returnByValue: true })).result.value;
      const video = await until("Chrome's PiP window, styled", async () => (await pipWindows())?.find((w) => w.video && w.styled) ?? null, 5000)
        .catch(async (e) => { throw new Error(`${e.message}: ${JSON.stringify(await pipWindows())}`); });
      if (!video.rounded || !video.keepOnTop || video.rim !== 1 || video.level < 3 || video.host !== "127.0.0.1" || !video.backToTab)
        throw new Error(`not styled as on CEF: ${JSON.stringify(video)}`);
      await sleep(800);
      const videoShown = (await pipWindows())?.find((w) => w.window === video.window) ?? video;
      if (videoShown.alpha !== 0 || !videoShown.ignoresMouseEvents) throw new Error(`a hidden run's PiP window shows: ${JSON.stringify(videoShown)}`);
      const menu = await cef(`devPictureInPictureAction("menu")`);
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`);
      const off = await until("onPictureInPicture video off", async () => {
        const e = await lastEvent(tab.id, "pictureInPicture");
        return e && e.payload.kind === "video" && !e.payload.active ? e : null;
      }, 5000);
      const doc = await cdp(t, "Runtime.evaluate", {
        expression: "documentPictureInPicture.requestWindow({ width: 320, height: 180 }).then(() => 'ok', (e) => e.name)",
        awaitPromise: true, userGesture: true, returnByValue: true,
      });
      const docOn = await until("onPictureInPicture document", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "document" && p.active), 5000)
        .catch((e) => { throw new Error(`${e.message}; requestWindow: ${JSON.stringify(doc.result)}`); });
      const docWindow = await until("the document PiP window", async () => (await pipWindows())?.find((w) => w.document) ?? null, 5000)
        .catch(async (e) => { throw new Error(`${e.message}: ${JSON.stringify(await pipWindows())}`); });
      await sleep(800);
      const docShown = (await pipWindows())?.find((w) => w.window === docWindow.window) ?? docWindow;
      if (docShown.alpha !== 0 || !docShown.ignoresMouseEvents) throw new Error(`a hidden run's document PiP window shows: ${JSON.stringify(docShown)}`);
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`);
      const docOff = await until("onPictureInPicture document off", async () => {
        const e = await lastEvent(tab.id, "pictureInPicture");
        return e && e.payload.kind === "document" && !e.payload.active ? e : null;
      }, 5000);
      return { clickAt: click.at, on: on.payload, element, window: { frame: video.frame, level: video.level, alpha: video.alpha }, menu, off: off.payload,
        docOn: docOn.payload, docWindow: { title: docWindow.title, alpha: docWindow.alpha }, docOff: docOff.payload };
    } finally {
      await closeTab(tab.id);
    }
  });

  await check("pip-document-back-to-tab", async () => {
    const tab = await openTab(`${base}/video?document-back-to-tab`, "Video");
    const logLines = () => (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8") : "").split("\n");
    const backToTab = (from) => logLines().slice(from).filter((l) => l.includes("Back to Tab (document Picture in Picture)"));
    let other = null;
    try {
      const t = await pageFor(tab.id, "/video");
      const doc = await cdp(t, "Runtime.evaluate", {
        expression: "documentPictureInPicture.requestWindow({ width: 320, height: 180 }).then(() => 'ok', (e) => e.name)",
        awaitPromise: true, userGesture: true, returnByValue: true,
      });
      if (doc.result?.value !== "ok") throw new Error(`documentPictureInPicture.requestWindow: ${JSON.stringify(doc.result)}`);
      const docWindow = await until("the document PiP window", async () => (await pipWindows())?.find((w) => w.document && w.visible) ?? null, 5000);
      await sleep(500);
      const snapshot = await cef(`devPictureInPictureAction("documentSnapshot:document-bar")`);
      other = await openTab(`${base}/a?document-back-to-tab`, "Page A");
      const quiet = logLines().length - 1;
      await cdp(t, "Runtime.evaluate", { expression: "window.focus(); true", userGesture: true });
      await sleep(1000);
      const pageFocusActivated = backToTab(quiet).length > 0;
      const focusShowedTab = (await state()).active === tab.id;
      if (!(await pipWindows())?.some((w) => w.document && w.visible)) {
        await evalApp(`ac.actions.switchToTab(${JSON.stringify(tab.id)}); return true`);
        await until("the call's tab shown again", async () => ((await state()).active === tab.id ? true : null), 5000);
        const again = await cdp(t, "Runtime.evaluate", {
          expression: "documentPictureInPicture.requestWindow({ width: 320, height: 180 }).then(() => 'ok', (e) => e.name)",
          awaitPromise: true, userGesture: true, returnByValue: true,
        });
        if (again.result?.value !== "ok") throw new Error(`documentPictureInPicture.requestWindow again: ${JSON.stringify(again.result)}`);
        await until("the document PiP window again", async () => (await pipWindows())?.find((w) => w.document && w.visible) ?? null, 5000);
        await evalApp(`ac.actions.switchToTab(${JSON.stringify(other.id)}); return true`);
        await until("the other tab shown", async () => ((await state()).active === other.id ? true : null), 5000);
        await sleep(500);
      }
      const before = logLines().length - 1;
      const clicked = await cef(`devPictureInPictureAction("documentBackToTab")`);
      if (!String(clicked).startsWith("started")) throw new Error(`documentBackToTab: ${clicked}`);
      const line = await until("the Back to Tab activation", async () => backToTab(before)[0] ?? null, 5000)
        .catch(() => null);
      const shown = await until("the call's tab shown", async () => ((await state()).active === tab.id ? true : null), 5000).catch(() => false);
      const closed = !!(await until("document PiP closed", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "document" && !p.active), 5000).catch(() => null));
      const out = { clicked, activated: line, shown, closed, pageFocusActivated, focusShowedTab, frame: docWindow.frame, snapshot };
      if (!line || !shown || !closed || pageFocusActivated) throw new Error(JSON.stringify(out));
      return out;
    } finally {
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`).catch(() => null);
      if (other) await closeTab(other.id).catch(() => null);
      await closeTab(tab.id).catch(() => null);
    }
  });

  await check("webkit-picture-in-picture", async () => {
    const tab = await openTab(`${base}/video?webkit-pip`, "Video");
    const id = JSON.stringify(tab.id);
    const page = async (code) => (await evalApp(`return ac.webviews.get(${id})?.evaluate(${JSON.stringify(code)}) ?? null`)) ?? null;
    const video = () => page(`const v = document.getElementById("v"); post("result", JSON.stringify(v ? { mode: v.webkitPresentationMode ?? null, supports: !!(v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode("picture-in-picture")), api: document.pictureInPictureEnabled === true, playing: !v.paused, width: v.videoWidth } : null))`);
    const modeIs = (mode, what, ms = 8000) => until(what, async () => { const v = await video(); return v?.mode === mode ? v : null; }, ms).catch(() => null);
    const activations = () => (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8") : "").split("\n");
    const backToTab = (from) => activations().slice(from).filter((l) => l.includes("Back to Tab (WebKit Picture in Picture)"));
    const show = (which) => evalApp(`ac.actions.switchToTab(${JSON.stringify(which)}); return true`);
    const enter = async () => {
      await evalApp(`return ac.webviews.get(${id}).requestPictureInPicture({ clickAt: 0, control: 0 })`);
      const v = await modeIs("picture-in-picture", "picture-in-picture mode");
      if (v) await sleep(1500);
      return v;
    };
    try {
      const locked = screenLocked();
      const play = () => page(`const v = document.getElementById("v"); v.muted = true; v.loop = true; if (!v.src) v.src = "/clip.webm"; v.play().then(() => post("result", JSON.stringify("ok")), (e) => post("result", JSON.stringify(e.name)))`);
      const playing = (what) => until(what, async () => { const v = await video(); return v?.playing && v.width > 0 ? v : null; }, 8000)
        .catch(async (e) => { throw new Error(`${e.message}: ${JSON.stringify(await video())}`); });
      const settled = () => page(`post("result", JSON.stringify(document.pictureInPictureElement === null))`);
      const fresh = async () => {
        await evalApp(`return ac.webviews.get(${id}).reload()`);
        await until("the reloaded video", async () => ((await video())?.mode === "inline" ? true : null), 10000);
        await play();
        return playing("the reloaded video playing");
      };
      await evalApp(`const s = ac.store.getState(); s.activate(${id}); ac.runCommand({ command: "togglePageEngine", arg: null, windowId: s.tabs[${id}].windowId }); return true`);
      await until("the WebKit engine", async () => ((await evalApp(`return ac.store.getState().tabs[${id}]?.engine ?? null`)) === "webkit" ? true : null), 15000);
      await until("the video in WebKit", async () => (await video()) ?? null, 10000);
      await evalApp(`return ac.webviews.get(${id}).setMuted(true)`);
      const started = await play();
      const before = await playing("the video playing").catch((e) => { throw new Error(`${e.message}; play ${JSON.stringify(started)}`); });
      const out = { locked, before, settledExits: [] };
      const exited = async (what) => {
        const mode = (await modeIs("inline", what))?.mode ?? null;
        await sleep(800);
        out.settledExits.push(await settled());
        return mode;
      };

      out.entered = (await enter())?.mode ?? null;
      const quiet = activations().length - 1;
      await evalApp(`return ac.webviews.get(${id}).exitPictureInPicture()`);
      out.left = await exited("inline again");
      out.exitActivated = backToTab(quiet).length > 0;

      await fresh();
      out.reentered = (await enter())?.mode ?? null;
      await show(first.id);
      await until("another tab shown", async () => ((await state()).active === first.id ? true : null), 5000);
      await sleep(800);
      out.whileAway = (await video())?.mode ?? null;
      await show(tab.id);
      out.closedOnReturn = await exited("PiP closed on return");

      await fresh();
      out.thirdEntry = (await enter())?.mode ?? null;
      await show(first.id);
      await until("another tab shown", async () => ((await state()).active === first.id ? true : null), 5000);
      const fromPage = activations().length - 1;
      out.pageExit = await page(`const v = document.getElementById("v"); v.webkitSetPresentationMode("inline"); v.play().then(() => post("result", JSON.stringify("ok")), (e) => post("result", JSON.stringify(e.name)))`);
      out.pageExitMode = await exited("inline after the page's own exit");
      await sleep(700);
      out.pageExitActivated = backToTab(fromPage).length > 0;
      out.pageExitStayedAway = (await state()).active === first.id;
      const fromFake = activations().length - 1;
      await page(`document.dispatchEvent(new Event("enterpictureinpicture")); document.dispatchEvent(new Event("leavepictureinpicture")); post("result", JSON.stringify("ok"))`);
      await sleep(1500);
      out.fakeEventsActivated = backToTab(fromFake).length > 0;

      await show(tab.id);
      await until("the video's tab shown", async () => ((await state()).active === tab.id ? true : null), 5000);
      await fresh();
      out.fourthEntry = (await enter())?.mode ?? null;
      await show(first.id);
      await until("another tab shown", async () => ((await state()).active === first.id ? true : null), 5000);
      const fromReturn = activations().length - 1;
      out.returnSeam = await evalApp(`return globalThis.expo.modules.SolaraTabPool.livePages().then((live) => globalThis.expo.modules.SolaraWebKit.devReturnFromPictureInPicture(live.find((p) => p.tabId === ${id})?.ready?.browserId ?? -1))`).catch((e) => String(e.message ?? e));
      out.returnActivated = (await until("the Back to Tab activation", async () => backToTab(fromReturn)[0] ?? null, 5000).catch(() => null)) !== null;
      out.returnShown = (await until("the video's tab shown", async () => ((await state()).active === tab.id ? true : null), 5000).catch(() => false)) === true;
      out.returnClosed = await exited("PiP closed once the tab is back");

      const other = await evalApp(`return ac.store.getState().createWindow({ url: "${base}/a?webkit-pip-move", background: true })`);
      try {
        const otherTab = await until("the other window's tab", async () => evalApp(`return ac.store.getState().windows[${JSON.stringify(other)}]?.tabIds[0] ?? null`), 10000);
        await evalApp(`ac.store.getState().moveTabsToWindow([${id}], ${JSON.stringify(other)}); return true`);
        await until("the video in the other window", async () => ((await evalApp(`return ac.store.getState().tabs[${id}]?.windowId`)) === other ? true : null), 5000);
        await fresh();
        out.movedEntry = (await enter())?.mode ?? null;
        await evalApp(`ac.store.getState().activate(${JSON.stringify(otherTab)}); return true`);
        await sleep(800);
        out.movedAway = (await video())?.mode ?? null;
        await evalApp(`ac.store.getState().moveTabsToWindow([${id}], ${JSON.stringify(mainWindow)}); return true`);
        out.movedBack = (await until("the video back in the first window", async () => {
          const s = await evalApp(`const s = ac.store.getState(); return { windowId: s.tabs[${id}]?.windowId, active: Object.values(s.windows[${JSON.stringify(mainWindow)}]?.activeTabIds ?? {}).includes(${id}) }`);
          return s.windowId === mainWindow && s.active ? true : null;
        }, 5000).catch(() => false)) === true;
        out.movedClosed = await exited("PiP closed once the tab is moved into a seen window");
      } finally {
        await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(other)}); return true`).catch(() => null);
      }
      if (locked) report.say("webkit-picture-in-picture: the screen is locked, so WebKit never finishes a PiP exit (PIP.framework restores, WebKit's did-exit never comes); each exit is checked as begun and the page is reloaded before the next entry");

      if (!before.supports || out.entered !== "picture-in-picture" || out.left !== "inline" || out.exitActivated ||
          out.reentered !== "picture-in-picture" || out.whileAway !== "picture-in-picture" || out.closedOnReturn !== "inline" ||
          out.thirdEntry !== "picture-in-picture" || out.pageExitMode !== "inline" || out.pageExitActivated || !out.pageExitStayedAway || out.fakeEventsActivated ||
          out.fourthEntry !== "picture-in-picture" || out.returnSeam !== true || !out.returnActivated || !out.returnShown || out.returnClosed !== "inline" ||
          out.movedEntry !== "picture-in-picture" || out.movedAway !== "picture-in-picture" || !out.movedBack || out.movedClosed !== "inline" ||
          (!locked && out.settledExits.some((s) => s !== true)))
        throw new Error(JSON.stringify(out));
      return out;
    } finally {
      await evalApp(`return ac.webviews.get(${id})?.exitPictureInPicture()`).catch(() => null);
      await closeTab(tab.id).catch(() => null);
    }
  });

  await check("auto-picture-in-picture", async () => {
    const results = {};
    for (const [path, kind] of [["/video?auto&file", "video"], ["/video?docpip", "document"]]) {
      const tab = await openTab(`${secureBase}${path}`, "Video");
      try {
        await startVideo(tab.id, true);
        await until("live.playingAudio", async () => (await live(tab.id))?.playingAudio === true, 8000);
        await until("onNowPlaying with video", async () => lastEvent(tab.id, "nowPlaying", (p) => p.state?.hasVideo && p.state?.playbackState === "playing"), 5000);
        await sleep(300);
        await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
        const out = await until(`auto PiP (${kind})`, async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === kind && p.active), 8000);
        await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
        const back = await until(`auto PiP ended (${kind})`, async () => {
          const e = await lastEvent(tab.id, "pictureInPicture");
          return e && e.payload.kind === kind && !e.payload.active ? e : null;
        }, 8000);
        results[kind] = { out: out.payload, back: back.payload };
      } finally {
        await closeTab(tab.id);
      }
    }
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    return results;
  });

  await check("pip-fullscreen-space", async () => {
    const jxa = (code) => JSON.parse(execFileSync("osascript", ["-l", "JavaScript", "-e", `ObjC.import("CoreGraphics"); ${code}`], { timeout: 20000 }).toString());
    const skip = (why) => {
      report.say(`pip-fullscreen-space skipped: ${why}`);
      return { skipped: why };
    };
    if (process.env.SOLARA_SPACE_SWITCH_TESTS !== "1")
      return skip("it switches Spaces and activates a fixture app, so it runs only with SOLARA_SPACE_SWITCH_TESTS=1 on a machine nobody is using");
    if (jxa(`const d = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())); JSON.stringify(!d || !!d.CGSSessionScreenIsLocked || !d.kCGSSessionOnConsoleKey)`))
      return skip("the screen is locked or this session isn't on the console, so no app can enter a full-screen Space");
    const fixture = join(scratch, "fullscreen-space-app");
    if (!existsSync(fixture)) {
      try {
        execFileSync("xcrun", ["swiftc", "-O", resolve(new URL(".", import.meta.url).pathname, "fixtures/fullscreen-space-app.swift"), "-o", fixture], { stdio: "ignore", timeout: 180000 });
      } catch (e) {
        return skip(`swiftc couldn't build the full-screen fixture app: ${e.message}`);
      }
    }
    const { spawn } = await import("node:child_process");
    const onScreen = () => jxa(`JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))).map((w) => w.kCGWindowNumber))`);
    const throughOtherFullScreen = async (pip) => {
      const seen = { flags: { level: pip.level, fullScreenAuxiliary: pip.fullScreenAuxiliary, allSpaces: pip.allSpaces, activationIndependent: pip.activationIndependent }, before: onScreen().includes(pip.window) };
      const child = spawn(fixture, [], { stdio: ["ignore", "pipe", "ignore"] });
      const exited = new Promise((r) => child.once("exit", r));
      let full = false, windowed = false;
      child.stdout.on("data", (d) => {
        if (String(d).includes("fullscreen")) full = true;
        if (String(d).includes("windowed")) windowed = true;
      });
      try {
        if (!(await until("the fixture app in its own full-screen Space", async () => (full ? true : null), 15000).catch(() => false))) return null;
        await sleep(2500);
        seen.inOtherFullScreen = onScreen().includes(pip.window);
        child.kill("SIGUSR1");
        seen.fixtureLeft = await until("the fixture app out of full screen", async () => (windowed ? true : null), 15000).catch(() => false);
        await sleep(2500);
        seen.afterExit = onScreen().includes(pip.window);
        seen.stillVisible = !!(await pipWindows())?.find((w) => w.window === pip.window && w.visible);
      } finally {
        jxa(`ObjC.import("AppKit"); const finder = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.apple.finder").firstObject; if (finder) finder.activateWithOptions(0); JSON.stringify(true)`);
        await sleep(1500);
        child.kill();
        await exited;
        await sleep(1000);
      }
      return seen;
    };
    const throughOwnFullScreen = async (pip) => {
      const seen = { flags: { level: pip.level, fullScreenAuxiliary: pip.fullScreenAuxiliary, allSpaces: pip.allSpaces, activationIndependent: pip.activationIndependent }, before: onScreen().includes(pip.window) };
      const filling = () => jxa(`const main = ObjC.deepUnwrap(ObjC.castRefToObject($.CGDisplayBounds($.CGMainDisplayID()))); JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)))
        .filter((w) => w.kCGWindowOwnerPID === ${pid} && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Width >= main.size.width && w.kCGWindowBounds.Height >= main.size.height).length > 0)`);
      const opened = await evalApp(`return ac.actions.openWindow({ url: "${base}/a?own-fullscreen" })`);
      const id = typeof opened === "string" ? opened : opened?.windowId ?? opened?.id;
      try {
        await until("the second Solara window", async () => ((await evalApp(`return Object.keys(ac.store.getState().windows)`)).includes(id) ? true : null), 10000);
        await sleep(1500);
        jxa(`ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationWithProcessIdentifier(${pid}).activateWithOptions(0); JSON.stringify(true)`);
        await evalApp(`globalThis.expo.modules.SolaraShell.restoreFullScreen(["${id}"], "${id}"); return true`);
        seen.filled = await until("Solara's window in a real full-screen Space", async () => (filling() ? true : null), 20000).catch(() => false);
        await sleep(2500);
        seen.inOwnFullScreen = onScreen().includes(pip.window);
      } finally {
        await evalApp(`ac.store.getState().closeWindow("${id}"); return true`).catch(() => null);
      }
      seen.left = await until("the full-screen window gone", async () => (!filling() ? true : null), 20000).catch(() => false);
      await sleep(2500);
      seen.afterExit = onScreen().includes(pip.window);
      seen.stillVisible = !!(await pipWindows())?.find((w) => w.window === pip.window && w.visible);
      return seen;
    };
    const ownOk = (seen) => seen.flags.fullScreenAuxiliary && seen.flags.allSpaces && seen.filled && seen.left && seen.before && seen.inOwnFullScreen && seen.afterExit && seen.stillVisible;
    const visible = process.env.SOLARA_ACCEPTANCE_VISIBLE === "1" && process.env.SOLARA_PIP_OWN_FULLSCREEN === "1";
    if (!visible) report.say("pip-fullscreen-space: Solara's own full screen needs SOLARA_ACCEPTANCE_VISIBLE=1 (a hidden instance only acts full screen out), so only another app's full-screen Space is checked");
    const ok = (seen) => seen.flags.fullScreenAuxiliary && seen.flags.allSpaces && seen.flags.activationIndependent === (seen.flags.level >= 3) && seen.before && seen.inOtherFullScreen && seen.fixtureLeft && seen.afterExit && seen.stillVisible;
    const tab = await openTab(`${base}/video?fullscreen-space`, "Video");
    const out = {};
    try {
      await evalApp(`return ac.webviews.get("${tab.id}").setMuted(true)`);
      const t = await startVideo(tab.id, false);
      const entered = await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('v').requestPictureInPicture().then(() => 'ok', (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true });
      if (entered.result?.value !== "ok") throw new Error(`requestPictureInPicture: ${JSON.stringify(entered.result)}`);
      const video = await until("the styled PiP window", async () => (await pipWindows())?.find((w) => w.video && w.styled && w.visible) ?? null, 10000)
        .catch(async (e) => { throw new Error(`${e.message}: ${JSON.stringify(await cef(`devPictureInPicture()`).catch((x) => String(x)))}`); });
      if (visible) out.videoOwn = await throughOwnFullScreen(video);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("Page A shown", async () => (await state()).active === first.id);
      out.video = await throughOtherFullScreen(video);
      if (!out.video) return skip("the fixture app never entered a full-screen Space in this session");
      if ((await cef(`devPictureInPictureAction("keepOnTop:0")`)) === "started") {
        const unpinned = (await pipWindows())?.find((w) => w.window === video.window);
        out.videoNotOnTop = await throughOtherFullScreen(unpinned);
        if (!out.videoNotOnTop) return skip("the fixture app never entered a full-screen Space in this session");
        await cef(`devPictureInPictureAction("keepOnTop:1")`);
        out.keepOnTopRestored = (await pipWindows())?.find((w) => w.window === video.window)?.level >= 3;
      } else out.videoNotOnTop = { missing: "no Keep Window on Top seam", flags: {} };
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`);
      await until("video PiP closed", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "video" && !p.active), 5000);
      await shownAndMounted(tab.id);
      const request = await cdp(t, "Runtime.evaluate", {
        expression: "documentPictureInPicture.requestWindow({ width: 320, height: 180 }).then(() => 'ok', (e) => e.name)",
        awaitPromise: true, userGesture: true, returnByValue: true,
      });
      if (request.result?.value !== "ok") throw new Error(`documentPictureInPicture.requestWindow: ${JSON.stringify(request.result)}`);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("Page A shown", async () => (await state()).active === first.id);
      const doc = await until("the document PiP window", async () => (await pipWindows())?.find((w) => w.document && w.visible && w.fullScreenAuxiliary !== undefined) ?? null, 5000);
      await sleep(500);
      if (visible) out.documentOwn = await throughOwnFullScreen((await pipWindows())?.find((w) => w.window === doc.window) ?? doc);
      out.document = await throughOtherFullScreen((await pipWindows())?.find((w) => w.window === doc.window) ?? doc);
      if (!out.document) return skip("the fixture app never entered a full-screen Space in this session");
      if ((visible && (!ownOk(out.videoOwn) || !ownOk(out.documentOwn))) || !ok(out.video) || out.videoNotOnTop.flags.level !== 0 || out.videoNotOnTop.flags.activationIndependent !== false || !out.videoNotOnTop.afterExit || !out.videoNotOnTop.stillVisible || !out.keepOnTopRestored || !ok(out.document)) throw new Error(JSON.stringify(out));
      return out;
    } finally {
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`).catch(() => null);
      await closeTab(tab.id).catch(() => null);
    }
  });

  await check("pip-keep-on-top-reopen", async () => {
    const tab = await openTab(`${base}/video?keep-on-top-reopen`, "Video");
    let unpinned = false;
    try {
      await evalApp(`return ac.webviews.get("${tab.id}").setMuted(true)`);
      const t = await startVideo(tab.id, false);
      const enter = async () => {
        const entered = await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('v').requestPictureInPicture().then(() => 'ok', (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true });
        if (entered.result?.value !== "ok") throw new Error(`requestPictureInPicture: ${JSON.stringify(entered.result)}`);
        return until("the styled PiP window", async () => (await pipWindows())?.find((w) => w.video && w.styled && w.visible) ?? null, 10000);
      };
      const opened = await enter();
      if ((await cef(`devPictureInPictureAction("keepOnTop:0")`)) !== "started") throw new Error("no Keep Window on Top seam");
      unpinned = true;
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`);
      await until("video PiP closed", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "video" && !p.active), 5000);
      const again = await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('v').requestPictureInPicture().then(() => 'ok', (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true });
      if (again.result?.value !== "ok") throw new Error(`reopen requestPictureInPicture: ${JSON.stringify(again.result)}`);
      await sleep(1000);
      const after = (await pipWindows())?.find((w) => w.video) ?? {};
      const out = { sameWindow: after.window === opened.window, visible: after.visible, styled: after.styled, level: after.level, activationIndependent: after.activationIndependent, alive: (await evalApp("return true")) === true };
      if (!out.alive || out.level !== 0 || out.activationIndependent !== false) throw new Error(JSON.stringify(out));
      return out;
    } finally {
      if (unpinned) await cef(`devPictureInPictureAction("keepOnTop:1")`).catch(() => null);
      await evalApp(`return ac.webviews.get("${tab.id}").exitPictureInPicture()`).catch(() => null);
      await closeTab(tab.id).catch(() => null);
    }
  });

  await check("pip-window", async () => {
    const tab = await openTab(`${base}/video?window`, "Video");
    const selftest = join(data, "pip-selftest.json"), button = join(data, "pip-button-selftest.json");
    rmSync(selftest, { force: true });
    rmSync(button, { force: true });
    try {
      await evalApp(`return ac.webviews.get("${tab.id}").setMuted(true)`);
      const t = await startVideo(tab.id, false);
      const open = async () => {
        await pipByHand(tab.id);
        await until("the styled PiP window", async () => (await pipWindows())?.find((w) => w.video && w.styled && w.visible) ?? null, 5000);
      };
      await open();
      if ((await cef(`devPictureInPictureAction("selftest")`)) !== "started") throw new Error("no self-test");
      const result = await until("the PiP self-test", async () => (existsSync(selftest) ? JSON.parse(readFileSync(selftest, "utf8")) : null), 20000);
      const failed = result.steps.filter((x) => !x.pass);
      if (failed.length) throw new Error(`self-test steps failed: ${JSON.stringify(failed)}`);
      const activate = await lastEvent(tab.id, "activateRequest", (p) => p.reason === "pictureInPicture");
      if (!activate) throw new Error("Back to Tab sent no onActivateRequest");
      await until("PiP closed by Back to Tab", async () => lastEvent(tab.id, "pictureInPicture", (p) => !p.active), 5000);
      const n = await cef(`devWindowNumber(${await browserOf(first.id)})`);
      const appActive = (on) => cef(`devWindow(${n}, "fakeAppActive:${on ? 1 : 0}")`);
      const logLines = () => (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8").split("\n") : []);
      const clickButton = async (name) => {
        await sleep(500);
        rmSync(button, { force: true });
        await open();
        if ((await appActive(false)) !== "0") throw new Error("no app-active seam");
        const from = logLines().length;
        try {
          if ((await cef(`devPictureInPictureAction("${name}")`)) !== "started") throw new Error("no button self-test");
          const clicked = await until(`the ${name} click`, async () => (existsSync(button) ? JSON.parse(readFileSync(button, "utf8")) : null), 10000);
          await sleep(300);
          const raised = logLines().slice(from).filter((l) => /^\S+ \S+ \S+ (makeKey|orderFront)/.test(l) && !l.includes("NativeWidgetMacFramelessNSWindow"));
          return { ...clicked, raised };
        } finally {
          await appActive(true);
        }
      };
      const closed = await clickButton("close");
      const time = async () => (await cdp(t, "Runtime.evaluate", { expression: "({ paused: v.paused, time: v.currentTime, pip: !!document.pictureInPictureElement })", returnByValue: true })).result.value;
      const before = await time();
      await sleep(1000);
      const after = await time();
      if (!closed.closed || after.pip || after.paused || after.time === before.time) throw new Error(`close: ${JSON.stringify({ closed, before, after })}`);
      if (!closed.preventsActivation || closed.activations !== 0 || closed.appActive || closed.raised.length)
        throw new Error(`the close click activated or raised something: ${JSON.stringify(closed)}`);
      const requests = (await eventsOf(tab.id)).filter((x) => x.name === "activateRequest").length;
      const back = await clickButton("backToTab");
      const backRequests = (await eventsOf(tab.id)).filter((x) => x.name === "activateRequest").length - requests;
      if (!back.closed || !back.preventsActivation || back.activations !== 1 || backRequests !== 1)
        throw new Error(`Chrome's Back to Tab: ${JSON.stringify({ back, backRequests })}`);
      return {
        steps: result.steps.map((x) => x.step),
        closeButton: closed.point,
        playing: [before.time.toFixed(1), after.time.toFixed(1)],
        close: { activations: closed.activations, raised: closed.raised.length },
        backToTab: { activations: back.activations, activateRequests: backRequests },
      };
    } finally {
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("page-focus", async () => {
    const other = await openTab(`${base}/b?focus`, "Page B", true);
    try {
      const split = await evalApp(`return ac.store.getState().createSplit(["${first.id}", "${other.id}"])`);
      if (!split) throw new Error("no split");
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("A active, both shown", async () => (await state()).active === first.id && (await evalApp(`return !!ac.webviews.get("${other.id}")`)), 8000);
      await sleep(500);
      const before = (await eventsOf(other.id)).filter((x) => x.name === "focus").length;
      await evalApp(`return ac.webviews.get("${other.id}").focus()`);
      await sleep(600);
      const fromApp = (await eventsOf(other.id)).filter((x) => x.name === "focus").length - before;
      await evalApp(`return ac.webviews.get("${first.id}").focus()`);
      await sleep(600);
      if ((await state()).active !== first.id) throw new Error("the app's focus() switched tabs");
      const took = await cef(`devFocusPage(${await browserOf(other.id)})`);
      const focus = await until("onPageFocus", async () => {
        const all = (await eventsOf(other.id)).filter((x) => x.name === "focus");
        return all.length > before + fromApp ? all.at(-1) : null;
      }, 5000);
      await until("the clicked pane active", async () => (await state()).active === other.id, 5000);
      if (fromApp) throw new Error(`the app's own focus() sent onPageFocus (${fromApp})`);
      const front = execFileSync("lsappinfo", ["front"]).toString();
      if (execFileSync("lsappinfo", ["info", "-only", "pid", front.trim()]).toString().includes(`=${child.pid}`)) throw new Error("the app took focus");
      return { took, focus: focus.name, active: "clicked pane" };
    } finally {
      await closeTab(other.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("page-drag", async () => {
    const tab = await freshTab(`${base}/drag`);
    try {
      const target = await until("the page", () => pageTarget("/drag"));
      const n = await cef(`devWindowNumber(${await browserOf(tab)})`);
      const act = (action) => cef(`devWindow(${n}, ${JSON.stringify(action)})`);
      const events = async () => (await cdp(target, "Runtime.evaluate", { expression: "window.__events", returnByValue: true })).result.value ?? [];
      const press = async ([x, y]) => {
        await act(`mouse:down:${x},${y}`);
        await sleep(80);
        await act(`mouse:up:${x},${y}`);
      };
      await act("fakeActiveClicks");
      let spot = null;
      for (const [x, y] of [[700, 420], [600, 500], [900, 300]])
        if (!spot && String(await act(`hit:${x},${y}`)).startsWith("RenderWidgetHostViewCocoa")) spot = [x, y];
      if (!spot) throw new Error("no window point over the page");
      await press(spot);
      const down = await until("the calibration press", async () => (await events()).find((e) => e[0] === "mousedown"), 4000);
      const at = (x, y) => [Math.round(x + spot[0] - down[2]), Math.round(y + spot[1] - down[3])];
      const [x, y] = at(130, 70);
      await act(`mouse:down:${x},${y}`);
      for (let i = 1; i <= 12; i++) {
        await act(`mouse:dragged:${x + i * 20},${y + i * 10}`);
        await sleep(30);
      }
      await until("dragstart", async () => (await events()).some((e) => e[0] === "dragstart"), 5000);
      await sleep(300);
      await act(`mouse:dragged:${x + 250},${y + 125}`);
      await sleep(100);
      await act(`mouse:up:${x + 250},${y + 125}`);
      await until("dragend: the drag the page started reached AppKit and ended", async () => (await events()).some((e) => e[0] === "dragend"), 8000);
      const clickerClicks = async () => (await events()).filter((e) => e[0] === "click" && e[1] === "clicker").length;
      const clicksBefore = await clickerClicks();
      await press(at(360, 70));
      await until("a new click on the page after the drag", async () => (await clickerClicks()) > clicksBefore, 4000);
      return { spot, events: (await events()).map((e) => `${e[0]}:${e[1]}`) };
    } finally {
      await closeTab(tab).catch(() => null);
    }
  });

  await check("page-press-split", async () => {
    const a = await openTab(`${base}/drag?pane=a`, "Drag");
    const b = await openTab(`${base}/drag?pane=b`, "Drag");
    try {
      if (!(await evalApp(`return ac.store.getState().createSplit(["${a.id}", "${b.id}"])`))) throw new Error("no split");
      await evalApp(`ac.actions.switchToTab("${a.id}"); return true`);
      await until("the split shown with a active", async () => (await state()).active === a.id && (await evalApp(`return !!ac.webviews.get("${b.id}")`)), 8000);
      const pageB = await until("b's page", () => pageTarget("/drag?pane=b"));
      const pageA = await until("a's page", () => pageTarget("/drag?pane=a"));
      const downs = async (t) => ((await cdp(t, "Runtime.evaluate", { expression: "window.__events", returnByValue: true })).result.value ?? []).filter((e) => e[0] === "mousedown").length;
      const n = await cef(`devWindowNumber(${await browserOf(a.id)})`);
      const act = (action) => cef(`devWindow(${n}, ${JSON.stringify(action)})`);
      await act("fakeActiveClicks");
      for (let x = 1300; x >= 200; x -= 100) {
        if (!String(await act(`hit:${x},420`)).startsWith("RenderWidgetHostViewCocoa")) continue;
        const before = [await downs(pageA), await downs(pageB)];
        await act(`mouse:down:${x},420`);
        await sleep(80);
        await act(`mouse:up:${x},420`);
        await until("the press reached a page", async () => (await downs(pageA)) > before[0] || (await downs(pageB)) > before[1], 4000);
        if ((await downs(pageB)) === before[1]) continue;
        await until("a press on the inactive pane's page activates it", async () => (await state()).active === b.id, 4000);
        return { x };
      }
      throw new Error("no window point over the inactive pane's page");
    } finally {
      await closeTab(b.id);
      await closeTab(a.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  // MARK: Page full screen
  const fsFlag = (tabId) => evalApp(`return !!ac.pageState.getState().pages[${JSON.stringify(tabId)}]?.fullscreen`);
  const fsWindow = async (tabId, action = "fullScreen") => {
    const n = await cef(`devWindowNumber(${await browserOf(tabId)})`);
    const out = await cef(`devWindow(${n}, ${JSON.stringify(action)})`);
    try {
      return JSON.parse(out);
    } catch {
      throw new Error(`devWindow ${action}: ${JSON.stringify(out)} (a build without page full screen?)`);
    }
  };
  const fsElement = async (t) => (await cdp(t, "Runtime.evaluate", { expression: "!!document.fullscreenElement", returnByValue: true })).result.value;
  const fsRequest = (t) => cdp(t, "Runtime.evaluate", { expression: "document.documentElement.requestFullscreen().then(() => 'ok', (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true });
  const fsEvents = async (tabId) => (await eventsOf(tabId)).filter((x) => x.name === "fullscreen").map((x) => x.payload.fullscreen);
  const fsEnter = async (tabId, t) => {
    const asked = await fsRequest(t);
    await until("the page in full screen", async () => (await fsFlag(tabId)) && (await fsElement(t)), 6000)
      .catch((e) => { throw new Error(`${e.message}; requestFullscreen: ${JSON.stringify(asked.result?.value)}`); });
  };
  const fsLeft = (tabId, t, what) => until(what, async () => !(await fsFlag(tabId)) && !(await fsElement(t)), 6000);
  const fsEscape = async (t) => {
    for (const type of ["rawKeyDown", "keyUp"])
      await cdp(t, "Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53 });
  };

  await check("fullscreen-tab-switch", async () => {
    const tab = await openTab(`${base}/b?fs-switch`, "Page B");
    try {
      const t = await pageFor(tab.id, "/b?fs-switch");
      await fsEnter(tab.id, t);
      const during = await fsWindow(tab.id);
      const bBefore = await fsEvents(first.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
      await until("B shown", async () => (await state()).active === first.id);
      await until("A's flag cleared on the switch", async () => !(await fsFlag(tab.id)), 5000)
        .catch(async (e) => { throw new Error(`${e.message}; A's events ${JSON.stringify(await fsEvents(tab.id))}, B's ${JSON.stringify((await fsEvents(first.id)).slice(bBefore.length))}`); });
      await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
      await until("A shown again", async () => (await state()).active === tab.id);
      await sleep(600);
      const back = { flag: await fsFlag(tab.id), element: await fsElement(t), window: await fsWindow(tab.id) };
      const bGot = (await fsEvents(first.id)).slice(bBefore.length);
      if (back.flag || back.element || back.window.fullScreen) throw new Error(`A back in full screen: ${JSON.stringify(back)}`);
      if (bGot.length) throw new Error(`B got A's full-screen events: ${JSON.stringify(bGot)}`);
      if (!during.fullScreen || !during.pageFullScreen?.entered) throw new Error(`the window didn't go full screen for A: ${JSON.stringify(during)}`);
      return { during, aEvents: await fsEvents(tab.id), bEvents: bGot.length, back };
    } finally {
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("fullscreen-native", async () => {
    const tab = await openTab(`${base}/b?fs-native`, "Page B");
    const out = {};
    try {
      const t = await pageFor(tab.id, "/b?fs-native");
      const win = () => fsWindow(tab.id);
      const settled = (what, test) => until(what, async () => {
        const w = await win();
        return !w.pageFullScreen?.transitioning && test(w) ? w : null;
      }, 6000).catch(async (e) => { throw new Error(`${e.message}; window ${JSON.stringify(await win())}`); });
      await fsEnter(tab.id, t);
      out.entered = await settled("the window in full screen", (w) => w.fullScreen && w.chromeCounts && w.pageFullScreen?.entered);
      await fsEscape(t);
      await fsLeft(tab.id, t, "Esc ended the page's full screen");
      out.esc = await settled("the window out of full screen after Esc", (w) => !w.fullScreen);
      await fsEnter(tab.id, t);
      await settled("the window in full screen again", (w) => w.fullScreen);
      await fsWindow(tab.id, "fakeFullScreen:0");
      await fsLeft(tab.id, t, "the green button ended the page's full screen");
      out.greenButton = await settled("the window out after the green button", (w) => !w.fullScreen);
      await fsWindow(tab.id, "fakeFullScreen:1");
      await settled("the window in full screen by hand", (w) => w.fullScreen);
      await fsEnter(tab.id, t);
      out.alreadyEntered = await settled("the page full screen in a full-screen window", (w) => w.fullScreen && w.pageFullScreen && !w.pageFullScreen.entered);
      await fsEscape(t);
      await fsLeft(tab.id, t, "Esc in a window already full screen");
      await sleep(400);
      out.alreadyEsc = await win();
      if (!out.alreadyEsc.fullScreen) throw new Error(`Esc took the user's full-screen window out: ${JSON.stringify(out.alreadyEsc)}`);
      await fsEnter(tab.id, t);
      await fsWindow(tab.id, "fakeFullScreen:0");
      await fsLeft(tab.id, t, "the green button in a window already full screen");
      out.alreadyGreen = await settled("the window out", (w) => !w.fullScreen);
      await fsWindow(tab.id, "fakeFullScreenMs:1500");
      await fsEnter(tab.id, t);
      const mid = await until("the window's transition started", async () => {
        const w = await win();
        return w.pageFullScreen?.transitioning ? w : null;
      }, 2000).catch(() => win());
      await cdp(t, "Runtime.evaluate", { expression: "document.exitFullscreen().then(() => 'ok', (e) => e.name)", awaitPromise: true, returnByValue: true });
      await fsLeft(tab.id, t, "the page out mid-transition");
      out.midTransition = { during: mid.pageFullScreen, after: await settled("the window out after the transition", (w) => !w.fullScreen && !w.pageFullScreen?.entered) };
      if (!mid.pageFullScreen?.transitioning) throw new Error(`the transition had ended before the page left: ${JSON.stringify(mid)}`);
      await fsEnter(tab.id, t);
      const n = await cef(`devWindowNumber(${await browserOf(tab.id)})`);
      const closing = await until("the window's transition started", async () => {
        const w = JSON.parse(await cef(`devWindow(${n}, "fullScreen")`)).pageFullScreen;
        return w?.transitioning ? w : null;
      }, 2000).catch(async () => JSON.parse(await cef(`devWindow(${n}, "fullScreen")`)).pageFullScreen);
      if (!closing?.transitioning) throw new Error(`the transition had ended before the close: ${JSON.stringify(closing)}`);
      await closeTab(tab.id);
      out.closedMidTransition = await until("the window out after its tab closed mid-transition", async () => {
        const w = JSON.parse(await cef(`devWindow(${n}, "fullScreen")`));
        return !w.fullScreen && !w.pageFullScreen?.transitioning && w.pageFullScreen?.page == null ? w : null;
      }, 6000).catch(async (e) => { throw new Error(`${e.message}; closing the tab mid-transition left ${await cef(`devWindow(${n}, "fullScreen")`)}`); });
      const slow = await openTab(`${base}/b?fs-slow`, "Page B");
      try {
        const st = await pageFor(slow.id, "/b?fs-slow");
        await fsWindow(slow.id, "fakeFullScreenMs:4500");
        await fsEnter(slow.id, st);
        await sleep(3300);
        await cdp(st, "Runtime.evaluate", { expression: "document.exitFullscreen().then(() => 'ok', (e) => e.name)", awaitPromise: true, returnByValue: true });
        await fsLeft(slow.id, st, "the page out during a slow transition");
        out.slowTransition = await until("the window out after a slow transition", async () => {
          const w = await fsWindow(slow.id);
          return !w.fullScreen && !w.pageFullScreen?.transitioning ? w : null;
        }, 15000).catch(async (e) => { throw new Error(`${e.message}; window ${JSON.stringify(await fsWindow(slow.id))}`); });
      } finally {
        await fsWindow(slow.id, "fakeFullScreenMs:0").catch(() => null);
        await closeTab(slow.id);
      }
      const again = await openTab(`${base}/b?fs-again`, "Page B");
      try {
        const at = await pageFor(again.id, "/b?fs-again");
        await fsEnter(again.id, at);
        await until("the window in full screen", async () => {
          const w = await fsWindow(again.id);
          return w.fullScreen && !w.pageFullScreen?.transitioning ? w : null;
        }, 6000);
        await fsWindow(again.id, "fakeFullScreenMs:4500");
        await cdp(at, "Runtime.evaluate", { expression: "document.exitFullscreen().then(() => 'ok', (e) => e.name)", awaitPromise: true, returnByValue: true });
        await fsLeft(again.id, at, "the page out, the window on its slow way out");
        await sleep(3300);
        await fsEnter(again.id, at);
        out.backDuringSlowExit = await until("the window back in full screen for the page", async () => {
          const w = await fsWindow(again.id);
          return w.fullScreen && !w.pageFullScreen?.transitioning ? w : null;
        }, 15000).catch(async (e) => { throw new Error(`${e.message}; page ${await fsFlag(again.id)}/${await fsElement(at)}, window ${JSON.stringify(await fsWindow(again.id))}`); });
        await sleep(800);
        if (!(await fsFlag(again.id)) || !(await fsElement(at))) throw new Error(`the late end of the app's transition took the page out: ${JSON.stringify(await fsWindow(again.id))}`);
      } finally {
        await fsWindow(again.id, "fakeFullScreenMs:0").catch(() => null);
        await closeTab(again.id);
      }
      const log = readFileSync(join(data, "activation.log"), "utf8").split("\n").filter((l) => l.includes("toggleFullScreen")).length;
      out.actedToggles = log;
      return out;
    } finally {
      await cef(`devWindow(${await cef(`devWindowNumber(${await browserOf(first.id)})`)}, "fakeFullScreenMs:0")`).catch(() => null);
      await closeTab(tab.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("escape-in-window-fullscreen", async () => {
    const tab = await openTab(`${base}/b?esc-fs`, "Page B");
    const out = {};
    try {
      const t = await pageFor(tab.id, "/b?esc-fs");
      const win = () => fsWindow(tab.id);
      const settled = (what, test) => until(what, async () => {
        const w = await win();
        return !w.pageFullScreen?.transitioning && test(w) ? w : null;
      }, 6000).catch(async (e) => { throw new Error(`${e.message}; window ${JSON.stringify(await win())}`); });
      const escapes = async () => (await cdp(t, "Runtime.evaluate", { expression: "window.escapes ?? 0", returnByValue: true })).result.value;
      const press = async () => {
        const s = await state();
        await evalApp(`return ac.webviews.get("${tab.id}").focus()`);
        return evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "\u001b", keyCode: 53, modifiers: [], focus: "page" })`);
      };
      await cdp(t, "Runtime.evaluate", { expression: "window.escapes = 0; addEventListener('keydown', (e) => { if (e.key === 'Escape') window.escapes++; }, true); true", returnByValue: true });
      await fsWindow(tab.id, "fakeFullScreen:1");
      out.entered = await settled("the window in full screen", (w) => w.fullScreen);
      out.pressed = await press();
      out.pageEscapes = await until("the page's keydown for Esc", async () => ((await escapes()) >= 1 ? await escapes() : null), 5000);
      await sleep(800);
      out.afterEscape = await win();
      if (!out.afterEscape.fullScreen) throw new Error(`Esc on the page took the window out of full screen: ${JSON.stringify(out.afterEscape)}`);
      await fsEnter(tab.id, t);
      out.element = await settled("the page in full screen in the full-screen window", (w) => w.fullScreen && w.pageFullScreen);
      await press();
      await fsLeft(tab.id, t, "Esc ended the element's full screen");
      await sleep(800);
      out.afterElementEscape = await win();
      if (!out.afterElementEscape.fullScreen) throw new Error(`Esc after the element's full screen took the window out: ${JSON.stringify(out.afterElementEscape)}`);
      return out;
    } finally {
      await fsWindow(tab.id, "fakeFullScreen:0").catch(() => null);
      await closeTab(tab.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("fullscreen-transition-picture", async () => {
    const tab = await openTab(`${base}/fs-layout`, "FS layout");
    const act = async (action) => cef(`devWindow(${await cef(`devWindowNumber(${await browserOf(tab.id)})`)}, ${JSON.stringify(action)})`);
    try {
      const t = await pageFor(tab.id, "/fs-layout");
      const key = async () => {
        for (const type of ["keyDown", "keyUp"])
          await cdp(t, "Input.dispatchKeyEvent", { type, key: "f", code: "KeyF", text: type === "keyDown" ? "f" : undefined, windowsVirtualKeyCode: 70, nativeVirtualKeyCode: 3 });
      };
      const settled = (what, full) => until(what, async () => {
        const w = await fsWindow(tab.id);
        const p = w.pageFullScreen;
        return w.fullScreen === full && p && !p.transitioning && !p.covered && !p.picturing && !p.telling ? w : null;
      }, 8000).catch(async (e) => { throw new Error(`${e.message}; window ${JSON.stringify(await fsWindow(tab.id))}`); });
      const rgb = (hex) => [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
      const near = (c, ref, tol) => c.every((v, i) => Math.abs(v - ref[i]) <= tol);
      const kind = (f) => {
        if (!f.grid) return "none";
        const cells = f.grid.map(rgb);
        if (f.uniform >= 0.97 && cells.every((c) => Math.max(...c) < 32)) return "bare";
        if (cells.filter((c) => near(c, [220, 30, 30], 45)).length >= 44) return "full";
        if (cells.slice(0, 8).some((c) => c[2] > c[0] + 30) && cells.some((c) => c[0] > c[1] + 80)) return "windowed";
        return "other";
      };
      const run = async (cover) => {
        await act(`pageCover:${cover ? 1 : 0}`);
        await act("fakeFullScreenMs:800");
        await act("fullScreenProbe:9000");
        await key();
        await settled("the window in full screen", true);
        await key();
        await settled("the window out of full screen", false);
        const frames = JSON.parse(await act("fullScreenProbe"));
        const runs = [];
        for (const f of frames) {
          if (!f.transitioning) continue;
          const last = runs.at(-1);
          if (last && frames.indexOf(f) - last.end === 1) { last.frames.push(f); last.end = frames.indexOf(f); }
          else runs.push({ frames: [f], end: frames.indexOf(f) });
        }
        if (runs.length !== 2) throw new Error(`expected two transitions in the probe, got ${runs.length} (${frames.length} frames)`);
        const tally = (r, want) => {
          const laid = r.frames.filter((f) => !f.relayout);
          const kinds = laid.map(kind);
          return { frames: kinds.length, relayout: r.frames.length - laid.length, bare: kinds.filter((k) => k === "bare").length,
            stale: kinds.filter((k) => k !== want && k !== "bare").length, uncovered: laid.filter((f) => !f.cover).length,
            kinds: [...new Set(kinds)], bareAtMs: laid.filter((f, i) => kinds[i] === "bare").map((f) => f.t - r.frames[0].t) };
        };
        const keyAt = frames[0]?.t ?? 0;
        const timing = (r) => {
          const start = r.frames[0].t, end = r.frames.at(-1).t;
          const shown = frames.find((f) => f.t > end && !f.cover)?.t;
          return { startsMs: start - keyAt, lastsMs: end - start, uncoversMs: shown != null ? shown - end : null };
        };
        return { in: { ...tally(runs[0], "full"), ...timing(runs[0]) }, out: { ...tally(runs[1], "windowed"), ...timing(runs[1]) } };
      };
      const off = await run(false);
      const on = await run(true);
      if (off.in.bare < off.in.frames * 0.9 || off.out.bare < off.out.frames * 0.9)
        throw new Error(`without the page's picture the probe didn't see the bare background: ${JSON.stringify(off)}`);
      for (const [dir, r] of Object.entries({ in: on.in, out: on.out }))
        if (r.bare || r.stale || r.uncovered || r.frames < 10 || r.relayout > 1) throw new Error(`the way ${dir}: ${JSON.stringify(r)}; all ${JSON.stringify(on)}`);
      const other = await openTab(`${base}/fs-layout?pane`, "FS layout");
      let split;
      try {
        if (!(await evalApp(`return ac.store.getState().createSplit(["${tab.id}", "${other.id}"])`))) throw new Error("no split");
        await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
        await until("the split shown", async () => (await state()).active === tab.id && (await evalApp(`return !!ac.webviews.get("${other.id}")`)), 8000);
        await sleep(500);
        await key();
        await settled("the pane's window in full screen", true);
        await act("fullScreenProbe:5000");
        await key();
        await settled("the split's window out of full screen", false);
        const frames = JSON.parse(await act("fullScreenProbe")).filter((f) => f.transitioning);
        split = { frames: frames.length, bothCovered: frames.filter((f) => f.covers >= 2).length };
        if (frames.length < 10 || split.bothCovered !== frames.length) throw new Error(`a split's way out left a pane without its picture: ${JSON.stringify(split)}`);
      } finally {
        await closeTab(other.id);
      }
      return { on, off: { in: off.in.kinds, out: off.out.kinds }, split };
    } finally {
      await act("pageCover:1").catch(() => null);
      await act("fakeFullScreenMs:0").catch(() => null);
      await closeTab(tab.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("fullscreen-hidden-page", async () => {
    const tab = await openTab(`${base}/b?fs-hide`, "Page B");
    const s = await state();
    let profileB = null;
    const out = {};
    try {
      const t = await pageFor(tab.id, "/b?fs-hide");
      await fsEnter(tab.id, t);
      const lock = (await cdp(t, "Runtime.evaluate", { expression: "Promise.resolve(document.body.requestPointerLock()).then(() => !!document.pointerLockElement, (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true })).result.value;
      const keys = (await cdp(t, "Runtime.evaluate", { expression: "navigator.keyboard.lock().then(() => 'locked', (e) => e.name)", awaitPromise: true, userGesture: true, returnByValue: true })).result.value;
      const ntp = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(s.windowId)})`);
      await until("the New Tab page shown", async () => (await state()).active === ntp);
      await fsLeft(tab.id, t, "the New Tab page ended the page's full screen");
      out.newTab = { pointerLock: lock, keyboardLock: keys, pointerLockAfter: (await cdp(t, "Runtime.evaluate", { expression: "!!document.pointerLockElement", returnByValue: true })).result.value, window: await fsWindow(tab.id) };
      if (out.newTab.pointerLockAfter) throw new Error(`pointer lock kept: ${JSON.stringify(out.newTab)}`);
      await closeTab(ntp);
      await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
      await until("the page shown again", async () => (await state()).active === tab.id);
      await sleep(500);
      if ((await fsFlag(tab.id)) || (await fsElement(t))) throw new Error("the page came back in full screen");
      await fsEnter(tab.id, t);
      profileB = await evalApp(`return ac.store.getState().createProfile({ name: "Full screen" })`);
      await evalApp(`ac.actions.switchProfile(${JSON.stringify(s.windowId)}, ${JSON.stringify(profileB)}); return true`);
      await until("the other Space shown", async () => (await state()).profileId === profileB);
      await fsLeft(tab.id, t, "the Space switch ended the page's full screen");
      await evalApp(`ac.actions.switchProfile(${JSON.stringify(s.windowId)}, ${JSON.stringify(s.profileId)}); return true`);
      await until("the first Space back", async () => (await state()).profileId === s.profileId && (await state()).active === tab.id);
      await sleep(500);
      out.space = { flag: await fsFlag(tab.id), element: await fsElement(t), window: await fsWindow(tab.id) };
      if (out.space.flag || out.space.element || out.space.window.fullScreen) throw new Error(`back from the Space in full screen: ${JSON.stringify(out.space)}`);
      const split = await evalApp(`return ac.store.getState().createSplit(["${tab.id}", "${first.id}"])`);
      if (!split) throw new Error("no split");
      await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
      await until("the split shown", async () => (await state()).active === tab.id && (await evalApp(`return !!ac.webviews.get("${first.id}")`)), 8000);
      await sleep(400);
      await fsEnter(tab.id, t);
      await sleep(1000);
      out.split = { flag: await fsFlag(tab.id), element: await fsElement(t) };
      if (!out.split.flag || !out.split.element) throw new Error(`the split pane's full screen ended: ${JSON.stringify(out.split)}`);
      await cdp(t, "Runtime.evaluate", { expression: "document.exitFullscreen().then(() => 'ok', (e) => e.name)", awaitPromise: true, returnByValue: true });
      await fsLeft(tab.id, t, "the split pane out of full screen");
      return out;
    } finally {
      await evalApp(`ac.actions.switchProfile(${JSON.stringify(s.windowId)}, ${JSON.stringify(s.profileId)}); return true`).catch(() => null);
      if (profileB) await evalApp(`ac.store.getState().deleteProfile(${JSON.stringify(profileB)}); return true`).catch(() => null);
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("fullscreen-split-sibling", async () => {
    const video = await openTab(`${base}/video?split`, "Video");
    const tab = await openTab(`${base}/b?fs-split`, "Page B");
    try {
      await evalApp(`return ac.webviews.get("${video.id}").setMuted(true)`);
      const split = await evalApp(`return ac.store.getState().createSplit(["${tab.id}", "${video.id}"])`);
      if (!split) throw new Error("no split");
      await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
      await until("the split shown", async () => (await state()).active === tab.id && (await evalApp(`return !!ac.webviews.get("${video.id}")`)), 8000);
      const v = await startVideo(video.id, true);
      await until("live.playingAudio", async () => (await live(video.id))?.playingAudio === true, 8000);
      await sleep(500);
      const pipBefore = (await eventsOf(video.id)).filter((x) => x.name === "pictureInPicture").length;
      const t = await pageFor(tab.id, "/b?fs-split");
      await fsEnter(tab.id, t);
      await sleep(1500);
      const pip = (await eventsOf(video.id)).filter((x) => x.name === "pictureInPicture").slice(pipBefore).map((x) => x.payload);
      const sibling = (await cdp(v, "Runtime.evaluate", { expression: "({ pip: !!document.pictureInPictureElement, visibility: document.visibilityState, paused: v.paused })", returnByValue: true })).result.value;
      await cdp(t, "Runtime.evaluate", { expression: "document.exitFullscreen().then(() => 'ok', (e) => e.name)", awaitPromise: true, returnByValue: true });
      await fsLeft(tab.id, t, "the pane out of full screen");
      if (pip.length || sibling.pip || sibling.visibility !== "visible" || sibling.paused)
        throw new Error(`the other pane counted as hidden: ${JSON.stringify({ pip, sibling })}`);
      return { sibling };
    } finally {
      await closeTab(tab.id);
      await closeTab(video.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("fullscreen-pip", async () => {
    const n = await cef(`devWindowNumber(${await browserOf(first.id)})`);
    const win = (action) => cef(`devWindow(${n}, ${JSON.stringify(action)})`);
    const pressF = async (t) => {
      for (const type of ["keyDown", "keyUp"])
        await cdp(t, "Input.dispatchKeyEvent", { type, key: "f", code: "KeyF", text: type === "keyDown" ? "f" : undefined, windowsVirtualKeyCode: 70, nativeVirtualKeyCode: 3 });
    };
    const pipEvents = async (tabId) => (await eventsOf(tabId)).filter((x) => x.name === "pictureInPicture");
    const gaps = [-150, 0, 40, 120, 300];
    const out = {};
    try {
      await win("fakeOcclusion:visible");
      await win("fakeFullScreenMs:700");
      for (const [path, name] of [["/video?fkey&file", "plain"], ["/video?fkey&handlers", "handlers"]]) {
        const tab = await openTab(`${secureBase}${path}`, "Video");
        try {
          const t = await startVideo(tab.id, true);
          await until("live.playingAudio", async () => (await live(tab.id))?.playingAudio === true, 8000);
          await until("onNowPlaying playing", async () => lastEvent(tab.id, "nowPlaying", (p) => p.state?.hasVideo && p.state?.playbackState === "playing"), 5000);
          await sleep(300);
          const seen = new Set((await pipEvents(tab.id)).map((x) => x.t));
          const settled = (what, test) => until(what, async () => {
            const w = await fsWindow(tab.id);
            return !w.pageFullScreen?.transitioning && test(w) ? w : null;
          }, 6000);
          for (let i = 0; i < 20; i++) {
            const gap = gaps[i % gaps.length];
            await win(`fakeFullScreenOcclusionMs:${gap}`);
            await pressF(t);
            await settled(`round ${i}: in full screen`, (w) => w.fullScreen && w.pageFullScreen?.page != null);
            await sleep(Math.max(0, gap) + 150);
            await pressF(t);
            await settled(`round ${i}: out of full screen`, (w) => !w.fullScreen && w.pageFullScreen?.page == null);
            await sleep(Math.max(0, gap) + 600);
            const fresh = (await pipEvents(tab.id)).filter((x) => !seen.has(x.t));
            const page = (await cdp(t, "Runtime.evaluate", { expression: "({ pip: !!document.pictureInPictureElement, paused: v.paused, fs: !!document.fullscreenElement })", returnByValue: true })).result.value;
            if (fresh.length || page.pip || page.fs || page.paused) {
              const timeline = (await eventsOf(tab.id)).filter((x) => x.name === "fullscreen" || x.name === "pictureInPicture").slice(-6)
                .map((x) => `${x.t} ${x.name} ${JSON.stringify(x.payload)}`);
              throw new Error(`${name}, round ${i} (visible again ${gap} ms after the transition): ${JSON.stringify({ pip: fresh.map((x) => x.payload), page, timeline })}`);
            }
          }
          out[name] = { rounds: 20, pipWindows: (await pipWindows())?.length ?? null };
          if (name !== "plain") continue;
          await win("fakeOcclusion:occluded");
          const popped = await until("auto PiP on leaving the window", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "video" && p.active), 5000);
          await win("fakeOcclusion:visible");
          await until("auto PiP ended with the window back", async () => {
            const e = await lastEvent(tab.id, "pictureInPicture");
            return e && e.t > popped.t && !e.payload.active ? e : null;
          }, 5000);
          out.leftWindow = "popped out and back";
          await evalApp(`ac.store.getState().updateSettings({ autoPictureInPicture: false }); return true`);
          try {
            out.manual = {};
            for (const [what, leave, back] of [
              ["tab", () => evalApp(`ac.actions.switchToTab("${first.id}"); return true`), () => evalApp(`ac.actions.switchToTab("${tab.id}"); return true`)],
              ["window", () => win("fakeOcclusion:occluded"), () => win("fakeOcclusion:visible")],
            ]) {
              await pipByHand(tab.id);
              const opened = await until("PiP opened by hand", async () => lastEvent(tab.id, "pictureInPicture", (p) => p.kind === "video" && p.active), 5000);
              await leave();
              await sleep(800);
              await back();
              out.manual[what] = (await until(`the hand-opened PiP closed coming back (${what})`, async () => {
                const e = await lastEvent(tab.id, "pictureInPicture");
                return e && e.t > opened.t && !e.payload.active ? e : null;
              }, 5000)).payload;
            }
          } finally {
            await evalApp(`ac.store.getState().updateSettings({ autoPictureInPicture: true }); return true`);
          }
        } finally {
          await closeTab(tab.id);
        }
      }
      return out;
    } finally {
      for (const action of ["fakeFullScreenOcclusionMs:-1", "fakeFullScreenMs:0", "fakeOcclusion:off"]) await win(action).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  // MARK: Pages, profiles and windows

  await check("autofill-suggestions", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    const go = async (path, title) => {
      await evalApp(`ac.store.getState().navigate("${first.id}", "${base}${path}", { userInitiated: true }); return true`);
      await until(title, async () => (await state()).tabs.find((t) => t.id === first.id && t.title === title && t.url?.endsWith(path) && !t.loading), 10000);
      await sleep(500);
      return pageFor(first.id, `${base}${path}`);
    };
    const shownSince = async (count, needle) => {
      const all = (await eventsOf(first.id)).filter((x) => x.name === "autofillSuggestions");
      return all.length > count && JSON.stringify(all.at(-1).payload.items).includes(needle) ? all.at(-1) : null;
    };
    const shownCount = async () => (await eventsOf(first.id)).filter((x) => x.name === "autofillSuggestions").length;
    const key = async (t, k) => {
      const code = { ArrowDown: 40, Enter: 13, Escape: 27 }[k];
      const at = { key: k, code: k, windowsVirtualKeyCode: code, nativeVirtualKeyCode: code };
      await cdp(t, "Input.dispatchKeyEvent", { type: "rawKeyDown", ...at, ...(k === "Enter" ? { text: "\r" } : {}) });
      if (k === "Enter") await cdp(t, "Input.dispatchKeyEvent", { type: "char", ...at, text: "\r" });
      await cdp(t, "Input.dispatchKeyEvent", { type: "keyUp", ...at });
    };
    const value = async (t) => (await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('c').value", returnByValue: true })).result.value;
    try {
      let t = await go("/form", "Form");
      await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('c').value = 'Springfield'; document.getElementById('b').click(); 1" });
      t = await until("the form submitted", async () => (await state()).tabs.find((x) => x.id === first.id && x.url?.includes("/form?city=") && !x.loading) && pageFor(first.id, "/form?city="), 10000);
      await sleep(1500);
      await cdp(t, "Page.navigate", { url: `${base}/form` });
      await until("the form again", async () => (await state()).tabs.find((x) => x.id === first.id && x.url === `${base}/form` && !x.loading), 10000);
      await sleep(800);
      t = await pageFor(first.id, `${base}/form`);
      let count = await shownCount();
      const box = JSON.parse((await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('c').getBoundingClientRect())", returnByValue: true })).result.value);
      const at = { x: box.x + 20, y: box.y + box.height / 2, button: "left", clickCount: 1 };
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at, buttons: 1 });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at, buttons: 0 });
      const clicked = await until("the dropdown on a click", async () => shownSince(count, "Springfield"), 6000);
      await sleep(300);
      await key(t, "ArrowDown");
      await sleep(300);
      await key(t, "Enter");
      const picked = await until("the picked entry in the field", async () => ((await value(t)) === "Springfield" ? true : null), 4000)
        .catch(async (e) => { throw new Error(`${e.message}; field "${await value(t)}"`); });
      await cdp(t, "Runtime.evaluate", { expression: "const c = document.getElementById('c'); c.value = ''; c.blur(); c.focus(); 1", userGesture: true });
      await sleep(400);
      count = await shownCount();
      const browser = await browserOf(first.id);
      const shown = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.showAutofillSuggestions(${browser}, false)`);
      const command = await until("the dropdown from showAutofillSuggestions", async () => shownSince(count, "Springfield"), 6000)
        .catch((e) => { throw new Error(`${e.message}; showAutofillSuggestions answered ${shown}`); });
      await cef(`savePassword("", ${JSON.stringify(base)}, "nnfill", "fill-s3cret")`);
      t = await go("/login?fill", "Login");
      await evalApp(`return ac.webviews.get("${first.id}").focus()`);
      await cdp(t, "Runtime.evaluate", { expression: "document.getElementById('u').focus(); 1", userGesture: true });
      await sleep(1000);
      await key(t, "Escape");
      await sleep(400);
      count = await shownCount();
      await evalApp(`ac.runCommand({ command: "autofill", arg: "passwords", windowId: ${JSON.stringify(mainWindow)} }); return true`);
      const passwords = await until("the saved passwords", async () => shownSince(count, "nnfill"), 6000)
        .catch(async (e) => {
          const direct = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.showAutofillSuggestions(${browser}, true)`);
          await sleep(1500);
          throw new Error(`${e.message}; direct ${direct}; saved ${JSON.stringify(await cef(`listPasswords("")`)).slice(0, 300)}; shown ${JSON.stringify((await eventsOf(first.id)).filter((x) => x.name === "autofillSuggestions").map((x) => x.payload))}`);
        });
      const labels = (e) => e.payload.items.map((i) => `${i.label} (${i.type})`);
      return { click: labels(clicked), picked, command: labels(command), shown, passwords: labels(passwords) };
    } finally {
      await cef(`deletePassword("", ${JSON.stringify(base)}, "nnfill")`).catch(() => null);
      await backToA();
    }
  });

  await check("images", async () => {
    const image = await evalApp(`return ac.webviews.get("${first.id}").downloadImage("${base}/icon.png", 64)`);
    const favicon = await evalApp(`return ac.webviews.get("${first.id}").downloadFavicon("${base}/icon.png")`);
    const fetched = await cef(`fetchFavicon("${base}/icon.png", "")`);
    const isData = (r) => JSON.stringify(r ?? null).includes("data:image/png");
    if (!isData(image) || !isData(favicon) || !isData(fetched)) throw new Error(`not data URLs: ${JSON.stringify({ image, favicon, fetched }).slice(0, 300)}`);
    return { image: true, favicon: true, fetched: true };
  });

  await check("favicon-fetch", async () => {
    const png = (side, rgb) => {
      const chunk = (type, body) => {
        const out = Buffer.alloc(12 + body.length);
        out.writeUInt32BE(body.length, 0);
        out.write(type, 4, "ascii");
        body.copy(out, 8);
        out.writeUInt32BE(crc32(out.subarray(4, 8 + body.length)), 8 + body.length);
        return out;
      };
      const header = Buffer.alloc(13);
      header.writeUInt32BE(side, 0);
      header.writeUInt32BE(side, 4);
      header.set([8, 2, 0, 0, 0], 8);
      const row = Buffer.concat([Buffer.from([0]), Buffer.concat(Array.from({ length: side }, () => Buffer.from(rgb)))]);
      return Buffer.concat([
        Buffer.from("89504e470d0a1a0a", "hex"),
        chunk("IHDR", header),
        chunk("IDAT", deflateSync(Buffer.concat(Array.from({ length: side }, () => row)))),
        chunk("IEND", Buffer.alloc(0)),
      ]);
    };
    const icon = png(16, [0, 160, 0]);
    const ico = Buffer.concat([Buffer.from([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0]), Buffer.alloc(8), icon]);
    ico.writeUInt32LE(icon.length, 14);
    ico.writeUInt32LE(22, 18);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#0a0"/></svg>`;
    const pngPath = join(scratch, "favicon-fetch.png"), tiffPath = join(scratch, "favicon-fetch.tiff");
    writeFileSync(pngPath, icon);
    execFileSync("sips", ["-s", "format", "tiff", pngPath, "--out", tiffPath], { stdio: "ignore" });
    const tiff = readFileSync(tiffPath);
    const seen = [];
    const hung = new Set();
    const icons = createServer((req, res) => {
      const url = new URL(req.url, "http://x");
      seen.push({ path: url.pathname + url.search, host: req.headers.host, cookie: req.headers.cookie ?? null, authorization: req.headers.authorization ?? null });
      const send = (status, type, body, headers = {}) => {
        res.writeHead(status, { "content-type": type, ...headers });
        res.end(body);
      };
      if (url.pathname === "/set-cookie") return send(200, "text/html", "<!doctype html><title>Favicon Cookie</title>", { "set-cookie": "nnfav=1; path=/" });
      if (url.pathname === "/icon.png") return send(200, "image/png", icon);
      if (url.pathname === "/icon.ico") return send(200, "text/plain", ico);
      if (url.pathname === "/icon.svg") return send(200, "image/svg+xml", svg);
      if (url.pathname === "/svg-as-text") return send(200, "text/plain", svg);
      if (url.pathname === "/icon.tiff") return send(200, "image/png", tiff);
      if (url.pathname === "/redirect") return send(302, "text/plain", "", { location: "/icon.png?redirected" });
      if (url.pathname === "/missing") return send(404, "image/png", icon);
      if (url.pathname === "/auth") return send(401, "image/png", icon, { "www-authenticate": 'Basic realm="nnfav"' });
      if (url.pathname === "/oversized") return send(200, "image/png", Buffer.concat([icon, Buffer.alloc(3 * 1024 * 1024)]));
      if (url.pathname === "/hang") return hung.add(res);
      send(404, "text/plain", "no");
    });
    await new Promise((r) => icons.listen(0, "127.0.0.1", r));
    const favBase = `http://nnfav.localhost:${icons.address().port}`;
    const fetchIcon = async (url, profile = "") => {
      const started = Date.now();
      const r = await evalApp(`return globalThis.expo.modules.SolaraCEF.fetchFavicon(${JSON.stringify(url)}, ${JSON.stringify(profile)})`, 60000);
      return { uri: typeof r?.uri === "string" ? r.uri.slice(0, 22) : null, width: r?.width ?? null, ms: Date.now() - started };
    };
    const ok = (r) => r.uri === "data:image/png;base64,";
    let privateWindow = null;
    try {
      await evalApp(`const h = (globalThis.acFaviconHang = { started: Date.now() });
        globalThis.expo.modules.SolaraCEF.fetchFavicon(${JSON.stringify(`${favBase}/hang`)}, "").then((r) => { h.uri = r?.uri ?? null; h.ms = Date.now() - h.started; }, () => { h.uri = null; h.ms = Date.now() - h.started; });
        return true`);
      const cookieTab = await openTab(`${favBase}/set-cookie`, "Favicon Cookie");
      const cookie = (await cdp(await pageFor(cookieTab.id, "/set-cookie"), "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
      await closeTab(cookieTab.id);
      if (!cookie.includes("nnfav=1")) throw new Error(`the profile has no cookie for the host: "${cookie}"`);
      const accepted = {
        png: await fetchIcon(`${favBase}/icon.png?cookie`),
        ico: await fetchIcon(`${favBase}/icon.ico`),
        svg: await fetchIcon(`${favBase}/icon.svg`),
        redirect: await fetchIcon(`${favBase}/redirect`),
        https: await fetchIcon("https://github.githubassets.com/favicons/favicon.svg"),
      };
      const refused = {
        missing: await fetchIcon(`${favBase}/missing`),
        auth: await fetchIcon(`${favBase}/auth`),
        oversized: await fetchIcon(`${favBase}/oversized`),
        tiff: await fetchIcon(`${favBase}/icon.tiff`),
        svgAsText: await fetchIcon(`${favBase}/svg-as-text`),
        noHost: await fetchIcon("http://nnfav-nowhere.invalid/favicon.ico"),
        notHttp: await fetchIcon("file:///System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"),
      };
      const bad = [
        ...Object.entries(accepted).filter(([, r]) => !ok(r)).map(([k, r]) => `${k} not loaded (${JSON.stringify(r)})`),
        ...Object.entries(refused).filter(([, r]) => r.uri !== null).map(([k]) => `${k} loaded`),
      ];
      if (bad.length) throw new Error(bad.join("; "));
      const iconRequest = seen.find((s) => s.path === "/icon.png?cookie");
      if (!iconRequest || iconRequest.cookie) throw new Error(`the icon request carried cookies: ${JSON.stringify(iconRequest)}`);
      if (!seen.some((s) => s.path === "/icon.png?redirected")) throw new Error("the redirect wasn't followed");
      if (seen.some((s) => s.authorization)) throw new Error("credentials were sent");
      const remoteUrl = "http://neverssl.com/favicon.ico";
      const reachable = await fetch(remoteUrl, { signal: AbortSignal.timeout(8000) }).then((r) => r.ok, () => false);
      const remoteFetch = await fetchIcon(remoteUrl);
      if (reachable && !ok(remoteFetch)) throw new Error(`${remoteUrl} not loaded (${JSON.stringify(remoteFetch)})`);
      const remote = `${ok(remoteFetch) ? "ok" : "null"}${reachable ? "" : " (not reachable from this script)"}`;
      const noWindow = await fetchIcon(`${favBase}/icon.png?no-private-window`, "incognito:nnfav@");
      if (noWindow.uri !== null) throw new Error("a fetch made a private profile");
      privateWindow = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${favBase}/icon.png?private-page" })`);
      const privateProfile = await until("the private window's engine profile", async () =>
        (await evalApp(`return globalThis.expo.modules.SolaraCEF.tabStrips()`)).strips.find((st) => st.appWindow === privateWindow)?.profile ?? null, 10000);
      if (!privateProfile.startsWith("incognito:")) throw new Error(`the private window's engine profile: ${JSON.stringify(privateProfile)}`);
      await until("the private page", () => (seen.some((s) => s.path === "/icon.png?private-page") ? true : null), 10000);
      const privately = await fetchIcon(`${favBase}/icon.png?private`, privateProfile);
      if (!ok(privately)) throw new Error(`the private window's fetch failed: ${JSON.stringify(privately)}`);
      const stored = JSON.parse(await cef(`engineCall("ac_favicons_set", ${JSON.stringify(privateProfile)}, ${JSON.stringify(JSON.stringify({ page: `${favBase}/private-page`, icon: `${favBase}/icon.png?private`, png: "AA==" }))})`).catch((e) => JSON.stringify({ refused: String(e) })));
      if (!stored?.error) throw new Error(`a private profile wrote Chrome's favicon store: ${JSON.stringify(stored)}`);
      const timedOut = await until("the hung request's end", () => evalApp(`const h = globalThis.acFaviconHang; return h.ms ? { uri: h.uri ? h.uri.slice(0, 22) : null, ms: h.ms } : null`), 50000);
      if (timedOut.uri !== null || timedOut.ms < 25000 || timedOut.ms > 50000) throw new Error(`the hung request: ${JSON.stringify(timedOut)}`);
      const ms = (o) => Object.fromEntries(Object.entries(o).map(([k, r]) => [k, r.ms]));
      return { accepted: ms(accepted), refused: ms(refused), timedOutMs: timedOut.ms, remote, private: { noWindow: null, open: "data", storeSet: stored.error } };
    } finally {
      if (privateWindow) await evalApp(`ac.store.getState().closeWindow("${privateWindow}"); return true`).catch(() => null);
      for (const res of hung) res.destroy();
      icons.close();
    }
  });

  await check("extension-surfaces", async () => {
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const browser = await browserOf(first.id);
    const states = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.actionStates(${browser}, ["${installed.id}"])`);
    if (!states?.[installed.id]) throw new Error(`no action state: ${JSON.stringify(states)}`);
    const panel = await evalApp(`return globalThis.expo.modules.SolaraChromeUI.sidePanelURL(${browser}, "${installed.id}")`);
    const reloaded = await exts(`reload("${installed.id}", "")`);
    if (reloaded?.error) throw new Error(`reload: ${reloaded.error}`);
    await sleep(1000);
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/blocking", { userInitiated: true }); return true`);
    const blocked = await until("onContentBlocked", async () =>
      (await eventsOf(first.id)).findLast((x) => x.name === "contentBlocked" && x.payload?.count >= 2), 10000).catch(() => null);
    await exts(`uninstall("${installed.id}", "")`);
    await evalApp(`ac.store.getState().navigate("${first.id}", "${base}/a", { userInitiated: true }); return true`);
    await until("A again", async () => (await state()).tabs.find((t) => t.id === first.id && t.title === "Page A" && !t.loading));
    if (!blocked) throw new Error("no onContentBlocked count for the extension's blocked images");
    return { state: states[installed.id], panel, reloaded: true, blocked: blocked.payload };
  });

  await check("frozen", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("the first tab in front", async () => (await state()).active === first.id, 4000);
    const s = await state();
    const other = s.tabs.find((x) => x.id !== first.id && x.id !== s.active && x.url?.startsWith(`${base}/d`));
    if (!other) throw new Error("no background tab");
    const t = await pageFor(other.id, `${base}/d`);
    await evalApp(`return ac.webviews.get("${other.id}")?.setFrozen(false)`);
    await until("the background page loaded", async () => {
      const r = await cdp(t, "Runtime.evaluate", { expression: "document.readyState === 'complete' && location.pathname === '/d'", returnByValue: true });
      return r.result.value === true;
    }, 10000);
    await cdp(t, "Runtime.evaluate", { expression: "window.__life = []; document.addEventListener('freeze', () => __life.push('freeze')); document.addEventListener('resume', () => __life.push('resume')); true" });
    await evalApp(`return ac.webviews.get("${other.id}")?.setFrozen(true)`);
    await sleep(1500);
    await evalApp(`return ac.webviews.get("${other.id}")?.setFrozen(false)`);
    let seen = null;
    const life = await until("freeze and resume", async () => {
      const r = await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify({ life: window.__life, visibility: document.visibilityState, url: location.href })", returnByValue: true });
      seen = JSON.parse(r.result.value ?? "{}");
      const l = seen.life ?? [];
      return l.includes("freeze") && l.includes("resume") ? l : null;
    }, 8000).catch((e) => { throw new Error(`${e.message}; the page saw ${JSON.stringify(seen)} (tab ${other.id}, target ${t?.url})`); });
    return { life };
  });

  await check("discard", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("the first tab in front", async () => (await state()).active === first.id, 4000);
    const s = await state();
    let other = null;
    for (const x of s.tabs.filter((x) => x.id !== first.id && x.id !== s.active && x.url?.startsWith(base)))
      if (await evalApp(`return !!ac.webviews.get(${JSON.stringify(x.id)})`)) { other = x; break; }
    if (!other) throw new Error("no background tab to discard");
    const ok = await evalApp(`return ac.webviews.get("${other.id}").discard()`);
    const e = await until("onDiscarded", async () => (await eventsOf(other.id)).find((x) => x.name === "discarded"), 8000);
    return { ok, url: e.payload.url };
  });

  await check("permission-prompt", async () => {
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    await until("A shown", async () => (await state()).active === first.id);
    const t = await pageFor(first.id, `${base}/a`);
    await cdp(t, "Runtime.evaluate", {
      expression: "navigator.requestMIDIAccess({ sysex: true }).then(() => (window.__geo = 'ok'), (e) => (window.__geo = 'denied:' + e.name))",
      userGesture: true,
    });
    const request = await until("the prompt", async () => evalApp(`return ac.pageState.getState().pages["${first.id}"]?.permission ?? null`), 10000);
    await cef(`resolvePermission("${request.id}", "deny", false)`);
    const answer = await until("the page's answer", async () => {
      const r = await cdp(t, "Runtime.evaluate", { expression: "String(window.__geo)", returnByValue: true });
      return r.result.value !== "undefined" ? r.result.value : null;
    }, 10000);
    return { permissions: request.permissions, origin: request.origin, answer };
  });

  await check("popup-blocked", async () => {
    await evalApp(`return ac.webviews.get("${first.id}").reload()`);
    await sleep(1500);
    await until("A loaded", async () => (await state()).tabs.find((t) => t.id === first.id && !t.loading), 10000);
    const t = await pageFor(first.id, `${base}/a`);
    await cdp(t, "Runtime.evaluate", { expression: `window.open("${base}/c?blocked")` });
    const popups = await until("the blocked popup", async () => {
      const p = await evalApp(`return ac.pageState.getState().pages["${first.id}"]?.popups ?? []`);
      return p.length ? p : null;
    }, 10000);
    await evalApp(`return ac.webviews.get("${first.id}").openBlockedPopup("${popups[0].id}")`);
    const opened = await until("the popup as a tab", async () => (await state()).tabs.find((x) => x.url?.includes("c?blocked")), 10000);
    return { popup: popups[0].url, tab: opened.id };
  });

  await check("second-profile", async () => {
    const s = await state();
    const id = await evalApp(`return ac.store.getState().createProfile({ name: "Work" })`);
    if (!id) throw new Error("no profile made");
    await evalApp(`ac.actions.switchProfile("${s.windowId}", "${id}"); return true`);
    await until("profile shown", async () => (await state()).profileId === id);
    await evalApp(`ac.actions.openUrls(["${base}/cookie?B"], ${JSON.stringify(mainWindow)}); return true`);
    const tb = await until("cookie page in B", async () => (await state()).tabs.find((x) => x.profileId === id && x.url?.includes("/cookie")));
    const targetsNow = await targets();
    const b = targetsNow.find((t) => t.url.includes("/cookie?B"));
    const a = targetsNow.find((t) => t.url.startsWith(`${base}/a`));
    const cookieA = (await cdp(a, "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
    const cookieB = (await cdp(b, "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
    if (cookieA.includes("who=B")) throw new Error("profile A sees B's cookie");
    const windows = await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`);
    await evalApp(`ac.actions.switchProfile("${s.windowId}", "${s.profileId}"); return true`);
    return { profile: id, tab: tb.id, cookieB, cookieA, chromeWindows: windows.chromeWindows };
  });

  await check("settings-window", async () => {
    const before = await evalApp(`return ac.shell.windowIds()`);
    await evalApp(`ac.openSettings(); return true`);
    const after = await until("a settings window", async () => {
      const ids = await evalApp(`return ac.shell.windowIds()`);
      return ids.length > before.length ? ids : null;
    });
    return { before, after };
  });
  await check("incognito-window", async () => {
    const id = await evalApp(`return ac.actions.openWindow({ incognito: true, url: "${base}/b?private" })`);
    const t = await until("a private tab", async () => {
      const tabs = await evalApp(`const s = ac.store.getState(); return (s.windows["${id}"]?.tabIds ?? []).map((i) => ({ url: s.tabs[i]?.url, title: s.tabs[i]?.title, profile: s.tabs[i]?.profileId }))`);
      return tabs.find((x) => x.title === "Page B") ?? null;
    });
    return { window: id, tab: t };
  });

  const slowMount = async (body) => {
    await evalApp(`globalThis.acDevMountDelayMs = 5000; return true`);
    try {
      return await body();
    } finally {
      await evalApp(`globalThis.acDevMountDelayMs = 0; return true`);
    }
  };
  const closeWindowOf = (tabId) =>
    evalApp(`const s = ac.store.getState(); const w = s.tabs[${JSON.stringify(tabId)}]?.windowId; if (w && w !== ${JSON.stringify(mainWindow)}) s.closeWindow(w); return true`);

  // MARK: Moving tabs

  await check("move-tab-slow-mount", async () => {
    const tab = await openTab(`${base}/a?slow`, "Page A");
    try {
      await evalApp(`ac.store.getState().navigate("${tab.id}", "${base}/b?slow", { userInitiated: true }); return true`);
      await until("B", async () => (await state()).tabs.find((t) => t.id === tab.id && t.title === "Page B" && !t.loading));
      await cdp(await pageFor(tab.id, "/b?slow"), "Runtime.evaluate", { expression: "window.__kept = 42" });
      const browser = await browserOf(tab.id);
      const windowId = await slowMount(async () => {
        const id = await evalApp(`return ac.store.getState().moveTabsToWindow(["${tab.id}"], null)`);
        await sleep(6000);
        return id;
      });
      await until("the tab's view in the new window", () => evalApp(`return !!ac.webviews.get("${tab.id}") && ac.store.getState().tabs["${tab.id}"]?.windowId === "${windowId}"`), 10000);
      await sleep(500);
      const t = await pageFor(tab.id, "/b?slow");
      const page = t && (await cdp(t, "Runtime.evaluate", { expression: "({ kept: String(window.__kept), entries: history.length })", returnByValue: true })).result.value;
      const after = await browserOf(tab.id);
      if (page?.kept !== "42" || page?.entries !== 2 || String(after) !== String(browser))
        throw new Error(`the page reloaded or went: ${JSON.stringify({ page, browser, after })}`);
      return { windowId, page, browser };
    } finally {
      await closeWindowOf(tab.id);
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("move-last-tab-slow-mount", async () => {
    const tab = await openTab(`${base}/a?last`, "Page A");
    try {
      const own = await evalApp(`return ac.store.getState().moveTabsToWindow(["${tab.id}"], null)`);
      await until("the tab's view in a window of its own", () => evalApp(`return !!ac.webviews.get("${tab.id}") && ac.store.getState().tabs["${tab.id}"]?.windowId === "${own}"`), 10000);
      await sleep(500);
      await cdp(await pageFor(tab.id, "/a?last"), "Runtime.evaluate", { expression: "window.__kept = 42" });
      const browser = await browserOf(tab.id);
      const windowId = await slowMount(async () => {
        const id = await evalApp(`return ac.store.getState().moveTabsToWindow(["${tab.id}"], null)`);
        await until("its first window gone", () => evalApp(`return !ac.store.getState().windows["${own}"]`), 5000);
        await sleep(6000);
        return id;
      });
      await until("the tab's view in the new window", () => evalApp(`return !!ac.webviews.get("${tab.id}") && ac.store.getState().tabs["${tab.id}"]?.windowId === "${windowId}"`), 10000);
      await sleep(500);
      const t = await pageFor(tab.id, "/a?last");
      const page = t && (await cdp(t, "Runtime.evaluate", { expression: "String(window.__kept)", returnByValue: true })).result.value;
      const after = await browserOf(tab.id);
      if (page !== "42" || String(after) !== String(browser)) throw new Error(`the page reloaded or went: ${JSON.stringify({ page, browser, after })}`);
      return { windowId, page, browser };
    } finally {
      await closeWindowOf(tab.id);
      await closeTab(tab.id);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("move-tab-closed-while-parked", async () => {
    const tab = await openTab(`${base}/c?parked`, "Page C");
    const target = await pageFor(tab.id, "/c?parked");
    try {
      return await slowMount(async () => {
        const pooled = await evalApp(`return !!globalThis.expo.modules.SolaraTabPool?.available()`);
        await evalApp(`ac.store.getState().moveTabsToWindow(["${tab.id}"], null); return true`);
        if (pooled) await sleep(1000);
        else await until("the old view gone", () => evalApp(`return !ac.webviews.get("${tab.id}")`), 3000);
        await sleep(300);
        if (!(await targets()).some((x) => x.id === target.id)) throw new Error("the page went before its tab closed");
        const copies = (await targets()).filter((x) => x.type === "page" && x.url.includes("/c?parked")).length;
        if (copies !== 1) throw new Error(`${copies} pages for the moved tab`);
        await closeTab(tab.id);
        const closed = Date.now();
        await until("the parked page gone", async () => !(await targets()).some((x) => x.id === target.id), 1500);
        return { goneAfterMs: Date.now() - closed };
      });
    } finally {
      await closeWindowOf(tab.id).catch(() => null);
      await closeTab(tab.id).catch(() => null);
      await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    }
  });

  await check("move-tab-to-window", async () => {
    const t = await pageTarget(`${base}/a`);
    await cdp(t, "Runtime.evaluate", { expression: "window.__kept = 42" });
    const windowId = await evalApp(`const id = ac.store.getState().moveTabsToWindow(["${first.id}"], null); return id`);
    await until("the tab in the new window", async () => evalApp(`return ac.store.getState().tabs["${first.id}"]?.windowId === "${windowId}" && ac.store.getState().windows["${windowId}"]?.tabIds.includes("${first.id}")`));
    await sleep(1500);
    const t2 = await pageTarget(`${base}/a`);
    const kept = (await cdp(t2, "Runtime.evaluate", { expression: "String(window.__kept)", returnByValue: true })).result.value;
    if (kept !== "42") throw new Error(`the page reloaded or went: ${kept}`);
    const tx = await evalApp(`return globalThis.expo.modules.SolaraCEF.tabStrips()`);
    const browser = await browserOf(first.id);
    const windowNumber = await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindowNumber(${browser})`);
    const holding = tx.strips.find((x) => x.tabs.some((tab) => tab.browser === Number(browser)));
    if (!holding || holding.window !== windowNumber) throw new Error(`the tab's strip is window ${holding?.window}, its view is in ${windowNumber}`);
    return { windowId, kept, strip: holding.strip, window: holding.window };
  });

  // MARK: Startup and engine

  await check("title-bar-close", async () => {
    const ids = await evalApp(`return ac.shell.windowIds()`);
    const browser = await browserOf(first.id);
    const windowNumber = await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindowNumber(${browser})`);
    const clicked = await evalApp(`return globalThis.expo.modules.SolaraCEF.devWindow(${windowNumber}, "close-button")`);
    const after = await until("one window fewer", async () => {
      const now = await evalApp(`return ac.shell.windowIds()`);
      return now.length < ids.length ? now : null;
    }, 10000);
    return { clicked, before: ids.length, after: after.length };
  });

  await check("little-solara", async () => {
    const before = await evalApp(`return Object.keys(ac.store.getState().windows)`);
    await evalApp(`ac.runCommand({ command: "newLittleSolara" }); return true`);
    const id = await until("a Little Solara window", async () => {
      const w = await evalApp(`return Object.values(ac.store.getState().windows).find((w) => w.kind === "small")?.id ?? null`);
      return w;
    });
    const tabId = await until("its tab", async () => evalApp(`return ac.store.getState().windows["${id}"]?.tabIds[0] ?? null`));
    await evalApp(`ac.store.getState().navigate("${tabId}", "${base}/b?small", { userInitiated: true }); return true`);
    await until("Page B in Little Solara", async () => evalApp(`return ac.store.getState().tabs["${tabId}"]?.title === "Page B"`));
    return { window: id, tab: tabId };
  });

  await check("startup-native-messaging", async () => {
    const dir = join(data, "Chromium", "NativeMessagingHosts");
    const known = {
      "com.1password.1password": "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport",
      "com.8bit.bitwarden": "/Applications/Bitwarden.app/Contents/MacOS/desktop_proxy",
      "org.keepassxc.keepassxc_browser": "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-proxy",
      "me.proton.pass.nm": "/Applications/Proton Pass.app/Contents/Resources/assets/proton_pass_nm_host",
    };
    const expected = Object.keys(known).filter((name) => existsSync(known[name])).sort();
    const managed = JSON.parse(existsSync(join(dir, ".solara-managed.json")) ? readFileSync(join(dir, ".solara-managed.json"), "utf8") : "[]");
    for (const name of expected) {
      const manifest = JSON.parse(readFileSync(join(dir, `${name}.json`), "utf8"));
      if (manifest.name !== name || manifest.type !== "stdio" || !existsSync(manifest.path)) throw new Error(`${name}: ${JSON.stringify(manifest)}`);
    }
    if (JSON.stringify(managed.slice().sort()) !== JSON.stringify(expected)) throw new Error(`managed ${JSON.stringify(managed)}, expected ${JSON.stringify(expected)}`);

    const ext = join(scratch, "fixture-ext-nm");
    cpSync(extPath, ext, { recursive: true });
    const manifest = JSON.parse(readFileSync(join(ext, "manifest.json"), "utf8"));
    manifest.permissions = [...manifest.permissions, "nativeMessaging"];
    writeFileSync(join(ext, "manifest.json"), JSON.stringify(manifest, null, 2));
    const installed = await exts(`install(${JSON.stringify(ext)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    const host = join(scratch, "echo-host.sh");
    writeFileSync(host, "#!/bin/sh\nexec cat\n", { mode: 0o755 });
    const hostManifest = join(dir, "com.solara.acceptance.echo.json");
    writeFileSync(hostManifest, JSON.stringify({ name: "com.solara.acceptance.echo", description: "echo", path: host, type: "stdio", allowed_origins: [`chrome-extension://${installed.id}/`] }));
    try {
      const worker = await extensionWorker(installed.id, "runtime.sendNativeMessage");
      const reply = await cdp(worker, "Runtime.evaluate", {
        expression: `chrome.runtime.sendNativeMessage("com.solara.acceptance.echo", { ping: 42 }).then((r) => JSON.stringify(r), (e) => "error: " + e.message)`,
        awaitPromise: true,
        returnByValue: true,
      });
      const echoed = reply.result?.value;
      if (echoed !== JSON.stringify({ ping: 42 })) throw new Error(`echo host: ${echoed}`);
      return { hosts: expected, echoed };
    } finally {
      rmSync(hostManifest, { force: true });
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
    }
  });

  await check("startup-accept-language", async () => {
    const system = JSON.parse(execFileSync("osascript", ["-l", "JavaScript", "-e",
      `ObjC.import("Foundation"); const out = []; const all = $.NSLocale.preferredLanguages;
       for (let i = 0; i < all.count; i++) { const l = $.NSLocale.localeWithLocaleIdentifier(all.objectAtIndex(i));
         out.push([ObjC.unwrap(l.languageCode), ObjC.unwrap(l.regionCode) ?? null, ObjC.unwrap(l.scriptCode) ?? null]); }
       JSON.stringify(out)`]).toString());
    const expected = [];
    for (let [language, region, script] of system) {
      if (!language) continue;
      if (language === "zh" && !region) region = script === "Hant" ? "TW" : "CN";
      for (const tag of region ? [`${language}-${region}`, language] : [language]) if (!expected.includes(tag)) expected.push(tag);
    }
    const reduced = expected.slice(0, 1);
    const reducedHeader = reduced[0].includes("-") ? [reduced[0], reduced[0].split("-")[0]] : reduced;
    let header = null;
    const echo = createServer((req, res) => {
      header = req.headers["accept-language"] ?? "";
      res.writeHead(200, { "content-type": "text/html" });
      res.end("<!doctype html><title>Languages</title>");
    });
    await new Promise((r) => echo.listen(0, "127.0.0.1", r));
    const tab = await openTab(`http://127.0.0.1:${echo.address().port}/languages`, "Languages");
    try {
      const t = await pageFor(tab.id, "/languages");
      const languages = (await cdp(t, "Runtime.evaluate", { expression: "navigator.languages", returnByValue: true })).result.value;
      const sent = (header ?? "").split(",").map((s) => s.split(";")[0].trim()).filter(Boolean);
      if (JSON.stringify(languages) !== JSON.stringify(reduced)) throw new Error(`navigator.languages ${JSON.stringify(languages)}, expected ${JSON.stringify(reduced)} (Helium's reduced Accept-Language: the first of ${JSON.stringify(expected)})`);
      if (JSON.stringify(sent) !== JSON.stringify(reducedHeader)) throw new Error(`Accept-Language "${header}", expected ${JSON.stringify(reducedHeader)} (Helium's reduced Accept-Language: the first of ${JSON.stringify(expected)})`);
      return { system: expected, languages, header };
    } finally {
      await closeTab(tab.id);
      echo.close();
    }
  });

  await check("engine-call-guard", async () => {
    const parse = async (call) => JSON.parse(await cef(call));
    const privateHistory = await parse(`engineCall("ac_history_query", "incognito-check", null)`);
    const notAllowed = await parse(`engineCall("ac_passwords_list", "", null)`);
    const history = await parse(`engineCall("ac_history_query", "", ${JSON.stringify(JSON.stringify({ maxUrls: 5, maxVisits: 1 }))})`);
    if (!privateHistory.error || !notAllowed.error || history.error) throw new Error(JSON.stringify({ privateHistory, notAllowed, history }));
    return { privateHistory: privateHistory.error, notAllowed: notAllowed.error, historyEntries: history.entries?.length };
  });

  await check("devtools-toggle", async () => {
    const tab = await freshTab(`${base}/b?devtools`);
    const devtools = async () => (await targets()).filter((t) => t.url.startsWith("devtools://")).length;
    const handle = (panel) => evalApp(`return ac.webviews.get("${tab}").showDevTools(${JSON.stringify(panel)})`);
    await handle("toggle");
    const opened = await until("DevTools open", async () => ((await devtools()) > 0 ? await devtools() : null), 10000);
    await handle("toggle");
    await until("DevTools closed", async () => ((await devtools()) === 0 ? true : null), 10000);
    await handle("console");
    await until("DevTools on the console", async () => ((await devtools()) > 0 ? true : null), 10000);
    await handle("toggle");
    await until("DevTools closed again", async () => ((await devtools()) === 0 ? true : null), 10000);
    await evalApp(`ac.store.getState().closeTab("${tab}"); return true`);
    return { opened };
  });

  await check("navigation-download-memory", async () => {
    const files = () => readdirSync(downloadsDir).filter((f) => f.startsWith("solaracore-test")).length;
    const before = files();
    const tab = await freshTab(`${base}/b?memory`);
    await evalApp(`ac.store.getState().navigate("${tab}", "${base}/file.bin?memory", { userInitiated: true }); return true`);
    await until("the download", async () => (files() > before ? true : null), 15000);
    const saved = JSON.parse(readFileSync(join(data, "Chromium", "NavigationDownloads.json"), "utf8"));
    if (!saved[`${base}/file.bin?memory`]) throw new Error(`not remembered: ${JSON.stringify(saved)}`);
    await evalApp(`ac.store.getState().newTab(${JSON.stringify(mainWindow)}, { url: "${base}/file.bin?memory", snapshot: { url: "${base}/file.bin?memory", title: "file.bin" } }); return true`);
    const skipped = await until("downloadNavigation skipped", async () => {
      for (const t of (await state()).tabs) {
        const e = (await eventsOf(t.id)).find((x) => x.name === "downloadNavigation" && x.payload?.skipped);
        if (e) return { tab: t.id, payload: e.payload };
      }
      return null;
    }, 10000);
    await sleep(1500);
    const after = files();
    if (after !== before + 1) throw new Error(`downloaded ${after - before} times`);
    return { skipped, downloads: after - before };
  });

  await check("delete-original-profile-data", async () => {
    const origin = "https://original.test";
    await cef(`savePassword("", "${origin}", "nnoriginal", "s3cret")`);
    await cef(`saveAddress("", { fullName: "Original Mascot", city: "Haifa", country: "IL" })`);
    await cef(`setZoom("", "original.test", 1.5)`);
    await cef(`setSiteSetting("", "${origin}", "popups", "allow")`);
    await until("the data saved", async () => {
      const p = await cef(`listPasswords("")`), a = await cef(`listAddresses("")`), z = await cef(`getZoomLevels("")`), o = await cef(`getSiteSettingsOrigins("")`);
      return p.passwords?.length && a.addresses?.length && z["original.test"] && o.length ? true : null;
    });
    const result = await evalApp(`return globalThis.expo.modules.SolaraCEF.deleteProfileData("")`, 60000);
    const p = await cef(`listPasswords("")`), a = await cef(`listAddresses("")`), z = await cef(`getZoomLevels("")`), o = await cef(`getSiteSettingsOrigins("")`);
    const left = { passwords: p.passwords?.length, addresses: a.addresses?.length, zoom: Object.keys(z).length, origins: o.length };
    if (result?.remaining?.length || Object.values(left).some(Boolean)) throw new Error(JSON.stringify({ result, left }));
    return { remaining: result.remaining, left };
  });

  // MARK: Quitting and relaunching

  await check("last-used-profile", async () => {
    const s = await state();
    personal = s.profileId;
    await evalApp(`ac.actions.switchToTab("${first.id}"); return true`);
    const before = new Set(s.tabs.map((x) => x.id));
    await evalApp(`ac.actions.openUrls(["${base}/cookie?personal"], ${JSON.stringify(mainWindow)}); return true`);
    await until("Personal's cookie page", async () => (await state()).tabs.find((x) => !before.has(x.id) && x.title === "Cookie" && !x.loading), 10000);
    const play = await evalApp(`return ac.store.getState().createProfile({ name: "Play" })`);
    await evalApp(`ac.actions.switchProfile("${s.windowId}", "${play}"); return true`);
    await until("Play shown", async () => (await state()).profileId === play);
    await evalApp(`ac.actions.openUrls(["${base}/cookie?play"], ${JSON.stringify(mainWindow)}); return true`);
    await until("Play's cookie page", async () => (await state()).tabs.find((x) => x.profileId === play && x.url?.includes("cookie?play") && !x.loading), 10000);
    await sleep(1000);
    return { personal, play };
  });

  await check("quit", async () => {
    const s = await state();
    await evalApp(`ac.actions.openUrls(["${base}/quit-marker"], "${s.windowId}"); return true`);
    await until("the marker tab", async () => (await state()).tabs.some((x) => x.url?.includes("quit-marker")));
    const started = Date.now();
    await evalApp(`return ac.shell.devKeyEquivalent("${s.windowId}", { key: "q", keyCode: 12, modifiers: ["command"], focus: "window" })`, 5000).catch(() => null);
    await until("the app to exit", async () => exited, 20000);
    await sleep(4000);
    const saved = readFileSync(join(data, "session.json"), "utf8").includes("quit-marker");
    if (!saved) throw new Error("the session wasn't saved on quit");
    const dir = join(process.env.HOME, "Library/Logs/DiagnosticReports");
    const ours = readdirSync(dir).filter((f) => {
      if (!f.includes(basename(exe)) || statSync(join(dir, f)).mtimeMs < launchedAt) return false;
      try {
        return new RegExp(`"pid"\\s*:\\s*${child.pid}\\b`).test(readFileSync(join(dir, f), "utf8").slice(0, 8000));
      } catch {
        return false;
      }
    });
    const crashes = ours.filter((f) => !f.startsWith("ExcUserFault_"));
    if (crashes.length) throw new Error(`crash report: ${crashes}`);
    return { exitedAfterMs: Date.now() - started, sessionSaved: saved, faults: ours.filter((f) => f.startsWith("ExcUserFault_")) };
  });

  await check("relaunch-profile", async () => {
    if (!personal) throw new Error("last-used-profile didn't run");
    await launch("app2.out.log");
    await until("the relaunched app", async () => {
      try {
        return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 90000);
    const windowId = await until("a window", async () => (await state()).windowId, 30000);
    mainWindow = windowId;
    await evalApp(`ac.actions.switchProfile("${windowId}", "${personal}"); return true`);
    await until("Personal shown", async () => (await state()).profileId === personal, 10000);
    const before = new Set((await state()).tabs.map((x) => x.id));
    await evalApp(`ac.actions.openUrls(["${base}/b?personal-again"], ${JSON.stringify(windowId)}); return true`);
    await until("a Personal page", async () => (await state()).tabs.find((x) => !before.has(x.id) && x.title === "Page B" && !x.loading), 15000);
    const t = await pageTarget(`${base}/b?personal-again`);
    const cookie = (await cdp(t, "Runtime.evaluate", { expression: "document.cookie", returnByValue: true })).result.value;
    const info = await evalApp(`return globalThis.expo.modules.SolaraCEF.chromeWindows()`);
    await stopApp();
    if (!cookie.includes("who=personal") || cookie.includes("who=play")) throw new Error(`Personal's page sees "${cookie}"`);
    return { cookie, windows: info.map((w) => w.profile) };
  });

  await check("keep-awake-relaunch", async () => {
    await appUp("app-keep-awake.out.log");
    const setting = () => evalApp(`return ac.store.getState().settings.keepAwakeSites ?? []`);
    const engine = () => cef(`sleepExceptions("")`);
    const before = await setting();
    const out = {};
    try {
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeSites: ["first.example"] }); return true`);
      const wrote = await until("the list in the engine", async () => ((await engine())?.includes("first.example") ? await engine() : null), 5000);
      out.addedBeforeQuit = await cef(`setSleepExceptions("", ${JSON.stringify([...wrote, "[*.]quit.example"])})`);
      await sleep(500);
      await stopApp();
      await appUp("app-keep-awake-quit.out.log");
      out.afterQuit = await until("the Chrome exception still in Settings after a quit", async () => {
        const sites = await setting();
        return sites.includes("quit.example") ? sites : null;
      }, 15000).catch(setting);
      out.engineAfterQuit = await engine();
      out.addedBeforeCrash = await cef(`setSleepExceptions("", ${JSON.stringify([...(out.engineAfterQuit ?? []), "[*.]crash.example"])})`);
      await sleep(12000);
      instance.kill();
      await until("the app to die", async () => exited || !alive(), 5000);
      exited ??= { pid };
      await appUp("app-keep-awake-crash.out.log");
      out.afterCrash = await until("the Chrome exception adopted when its profile loads after a crash", async () => {
        const sites = await setting();
        return sites.includes("crash.example") ? sites : null;
      }, 15000).catch(setting);
      out.engineAfterCrash = await engine();
      const removed = (await setting()).filter((site) => site !== "quit.example" && site !== "crash.example");
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeSites: ${JSON.stringify(removed)} }); return true`);
      await until("both removals in the engine", async () => {
        const list = await engine();
        return list && !list.some((p) => p.includes("quit.example") || p.includes("crash.example")) ? list : null;
      }, 5000);
      await stopApp();
      await appUp("app-keep-awake-removed.out.log");
      await sleep(3000);
      out.afterRemovalQuit = await setting();
      out.engineAfterRemovalQuit = await engine();
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeSites: [...${JSON.stringify(removed)}, "late.example"] }); return true`);
      await until("late.example in the engine", async () => ((await engine())?.includes("late.example") ? true : null), 5000);
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeSites: ${JSON.stringify(removed)} }); return true`);
      await until("late.example out of the engine", async () => ((await engine())?.includes("late.example") === false ? true : null), 5000);
      await sleep(12000);
      instance.kill();
      await until("the app to die", async () => exited || !alive(), 5000);
      exited ??= { pid };
      await appUp("app-keep-awake-removed-crash.out.log");
      await sleep(3000);
      out.afterRemovalCrash = await setting();
      out.engineAfterRemovalCrash = await engine();
      const problems = [];
      if (out.addedBeforeQuit !== true || !out.afterQuit?.includes("quit.example") || !out.engineAfterQuit?.some((p) => p.includes("quit.example"))) problems.push(`an exception added in Chrome didn't survive a quit: ${JSON.stringify([out.afterQuit, out.engineAfterQuit])}`);
      if (out.addedBeforeCrash !== true || !out.afterCrash?.includes("crash.example") || !out.engineAfterCrash?.some((p) => p.includes("crash.example"))) problems.push(`an exception added in Chrome didn't survive a crash: ${JSON.stringify([out.afterCrash, out.engineAfterCrash])}`);
      if (!out.afterCrash?.includes("first.example") || !out.afterCrash?.includes("quit.example")) problems.push(`the list lost an entry: ${JSON.stringify(out.afterCrash)}`);
      const back = (list) => (list ?? []).filter((p) => /quit\.example|crash\.example|late\.example/.test(p));
      if (back(out.afterRemovalQuit).length || back(out.engineAfterRemovalQuit).length) problems.push(`removed sites came back after a quit: ${JSON.stringify([out.afterRemovalQuit, out.engineAfterRemovalQuit])}`);
      if (back(out.afterRemovalCrash).length || back(out.engineAfterRemovalCrash).length) problems.push(`removed sites came back after a crash: ${JSON.stringify([out.afterRemovalCrash, out.engineAfterRemovalCrash])}`);
      if (!out.afterRemovalCrash?.includes("first.example")) problems.push(`first.example was lost: ${JSON.stringify(out.afterRemovalCrash)}`);
      if (problems.length) throw new Error(problems.join("; "));
      return out;
    } finally {
      await evalApp(`ac.store.getState().updateSettings({ keepAwakeSites: ${JSON.stringify(before)} }); return true`).catch(() => null);
    }
  });

  const pressQuit = (windowId) =>
    evalApp(`return ac.shell.devKeyEquivalent("${windowId}", { key: "q", keyCode: 12, modifiers: ["command"], focus: "window" })`, 5000).catch(() => null);
  const savedSession = () => (existsSync(join(data, "session.json")) ? readFileSync(join(data, "session.json"), "utf8") : "");
  const restored = async (urlPart) => {
    await appUp("app-restored.out.log");
    return until(`${urlPart} restored`, async () => (await state()).tabs.find((t) => t.url?.includes(urlPart)) ?? null, 15000);
  };

  await check("quit-cancelled", async () => {
    const windowId = await appUp("app-quit-cancelled.out.log");
    await evalApp(`ac.actions.openUrls(["${base}/b?stay"], "${windowId}"); return true`);
    await until("the page loaded", async () => (await state()).tabs.find((t) => t.url?.includes("b?stay") && t.title === "Page B" && !t.loading), 15000);
    const target = await until("the page", () => pageTarget(`${base}/b?stay`), 15000);
    await cdp(target, "Runtime.evaluate", { expression: `addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; }); true`, userGesture: true });
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = () => j(new Error("DevTools connection failed")))));
    let leave = false;
    const prompts = [];
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.method !== "Page.javascriptDialogOpening") return;
      prompts.push({ type: msg.params.type, leave });
      ws.send(JSON.stringify({ id: 100 + prompts.length, method: "Page.handleJavaScriptDialog", params: { accept: leave } }));
    };
    ws.send(JSON.stringify({ id: 1, method: "Page.enable" }));
    try {
      await sleep(300);
      await pressQuit(windowId);
      await until("the beforeunload prompt", async () => prompts.length === 1, 10000);
      await sleep(1500);
      if (exited) throw new Error("the app quit though the page said Stay");
      await evalApp(`ac.actions.openUrls(["${base}/c?after-stay"], "${windowId}"); return true`);
      await until("the tab after Stay saved", async () => savedSession().includes("after-stay"), 10000);
      leave = true;
      const started = Date.now();
      await pressQuit(windowId);
      await until("the app to exit", async () => exited, 20000);
      const exitMs = Date.now() - started;
      if (!savedSession().includes("after-stay")) throw new Error("the second quit didn't save the session");
      const tab = await restored("after-stay");
      return { prompts, exitMs, restored: tab.url };
    } finally {
      try { ws.close(); } catch {}
    }
  });

  await check("content-blocker-restored", async () => {
    const windowId = await appUp("app-blocker-restored.out.log");
    const tag = `restored-${Date.now()}`;
    const url = `http://adpage.test:${server.address().port}/adfirst?${tag}`;
    const loaded = (id) => evalApp(`const s = ac.store.getState(); const t = s.tabs[${JSON.stringify(id)}];
      return t?.title === "Ad first" && !s.live[${JSON.stringify(id)}]?.isLoading ? true : null`);
    const id = await evalApp(`const s = ac.store.getState(); const id = s.newTab(${JSON.stringify(windowId)}, { url: ${JSON.stringify(url)} });
      ac.store.getState().activate(id); return id`);
    await until("the ad page", () => loaded(id), 15000);
    const beforeQuit = adsServedFor(tag);
    await until("the ad page saved", async () => savedSession().includes(tag), 10000);
    await pressQuit(windowId);
    await until("the app to exit", async () => exited, 20000);
    const relaunched = Date.now();
    const tab = await restored(tag);
    await until("the restored page loaded", () => loaded(tab.id), 20000);
    const loadedAfterMs = Date.now() - relaunched;
    if (beforeQuit.length) throw new Error(`ads went out before the quit: ${JSON.stringify(beforeQuit)}`);
    await until("the blocker's state", async () => ((await cef(`getContentBlocker()`))?.stats?.ready ? true : null), 30000);
    const racedAtLaunch = adsServedFor(tag).length;
    if (racedAtLaunch !== 0) throw new Error(`the restored page's ads raced at launch: ${JSON.stringify(adsServedFor(tag))}`);
    if (!(await evalApp(`return !!ac.webviews.get(${JSON.stringify(tab.id)})`))) throw new Error("the restored tab has no page view");
    const again = `${tag}-ready`;
    const pagesBefore = adServed.filter((s) => s.startsWith("adpage.test") && s.endsWith(`?${again}`)).length;
    await evalApp(`ac.store.getState().navigate(${JSON.stringify(tab.id)}, ${JSON.stringify(`http://adpage.test:${server.address().port}/adfirst?${again}`)}, { userInitiated: true }); return true`);
    await until("the restored tab's next page", () => evalApp(`const s = ac.store.getState(); const t = s.tabs[${JSON.stringify(tab.id)}];
      return t?.url?.endsWith(${JSON.stringify(`?${again}`)}) && t.title === "Ad first" && !s.live[${JSON.stringify(tab.id)}]?.isLoading ? true : null`), 20000);
    await sleep(500);
    const documents = adServed.filter((s) => s.startsWith("adpage.test") && s.endsWith(`?${again}`)).length - pagesBefore;
    if (documents < 1) throw new Error("the next page's document never reached the server");
    const afterReady = adsServedFor(again);
    if (afterReady.length) throw new Error(`ads went out once uBlock Origin was ready: ${JSON.stringify(afterReady)}`);
    return { restored: tab.url, loadedAfterMs, racedAtLaunch, nextDocuments: documents };
  });

  await check("doomed-browser-not-reused", async () => {
    const mainId = await appUp("app-doomed-browser.out.log");
    const s = (expr) => evalApp(`const s = ac.store.getState(); return ${expr}`);
    const windowId = await evalApp(`return ac.store.getState().createWindow({ url: "${base}/a?doomed", background: true })`);
    const id = await until("the window's tab", async () => s(`s.windows["${windowId}"]?.tabIds.length === 1 && s.tabs[s.windows["${windowId}"].tabIds[0]]?.title === "Page A" && !s.live[s.windows["${windowId}"].tabIds[0]]?.isLoading ? s.windows["${windowId}"].tabIds[0] : null`), 15000);
    const browser = await until("its browser", () => browserOf(id), 10000);
    const out = await cef(`devCloseBrowserKeepingWindow(${browser})`);
    if (out?.error) throw new Error(out.error);
    if (!out.scheduled || !out.cachedIsScheduled) throw new Error(`the close left no Browser scheduled for deletion in the cache: ${JSON.stringify(out)}`);
    if (out.acquiredIsScheduled || (out.windowOpen && !out.acquired)) throw new Error(`BrowserFor answered with a Browser scheduled for deletion: ${JSON.stringify(out)}`);
    await sleep(1500);
    if (!(await s(`!!s.windows["${mainId}"]?.tabIds.length`))) throw new Error("the run's own window lost its tabs");
    if (appLog.join().includes("Check failed: !IsDeleteScheduled()")) throw new Error("a tab went into a Browser scheduled for deletion");
    await evalApp(`const s = ac.store.getState(); if (s.windows["${windowId}"]) s.closeWindow("${windowId}"); return true`);
    return out;
  });

  await check("closed-tabs-own-lists", async () => {
    let windowId = await appUp("app-closed-tabs.out.log");
    const s = (expr) => evalApp(`const s = ac.store.getState(); return ${expr}`);
    const entries = (id) => evalApp(`return ac.webviews.get(${JSON.stringify(id)})?.navigationEntries().then((e) => e.map((x) => { const u = new URL(x.url); return u.pathname + u.search; })) ?? null`);
    const onSamePage = async (tag) => {
      const id = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(windowId)}, { url: "${base}/a?${tag}" })`);
      await until(`A?${tag}`, async () => (await s(`s.tabs["${id}"]?.title === "Page A" && !s.live["${id}"]?.isLoading && !!ac.webviews.get("${id}")`)) || null, 15000);
      await evalApp(`ac.store.getState().navigate("${id}", "${base}/b?same", { userInitiated: true }); return true`);
      await until(`B from A?${tag}`, async () => (await s(`s.tabs["${id}"]?.title === "Page B" && s.live["${id}"]?.canGoBack && !s.live["${id}"]?.isLoading`)) || null, 15000);
      return id;
    };
    const a = await onSamePage("first-closed"), b = await onSamePage("second-closed");
    await sleep(1000);
    const closed = Object.fromEntries(await evalApp(`const s = ac.store.getState(); s.closeTab("${a}"); s.closeTab("${b}");
      return ac.store.getState().closedTabs.filter((c) => c.tabId === "${a}" || c.tabId === "${b}").map((c) => [c.tabId, c.id])`));
    if (!closed[a] || !closed[b]) throw new Error(`closed entries: ${JSON.stringify(closed)}`);
    await sleep(1500);
    const reopen = async (entryId, expected) => {
      const id = await evalApp(`const s = ac.store.getState(); const before = new Set(Object.keys(s.tabs));
        s.restoreClosed(${JSON.stringify(entryId)}, ${JSON.stringify(windowId)});
        const id = Object.keys(ac.store.getState().tabs).find((t) => !before.has(t)); ac.store.getState().activate(id); return id`);
      const list = await until(`the reopened tab's list`, async () => {
        const e = await entries(id);
        return e?.includes("/b?same") ? e : null;
      }, 15000);
      if (JSON.stringify(list) !== JSON.stringify(expected)) throw new Error(`reopened ${entryId}: ${JSON.stringify(list)}, not ${JSON.stringify(expected)}`);
      await evalApp(`ac.store.getState().closeTab("${id}"); return true`);
      return list;
    };
    const first = await reopen(closed[a], ["/a?first-closed", "/b?same"]);
    await sleep(1500);
    await pressQuit(windowId);
    await until("the quit", async () => exited, 30000);
    windowId = await appUp("app-closed-tabs-2.out.log");
    const second = await reopen(closed[b], ["/a?second-closed", "/b?same"]);
    return { first, afterQuit: second };
  });

  await check("js-reload-keeps-pages", async () => {
    const windowId = await appUp("app-js-reload.out.log");
    const path = `/b?kept-${Date.now()}`;
    const visits = async () => JSON.parse(await cef(`engineCall("ac_history_query", "", "{}")`)).entries.filter((e) => e.u === `${base}${path}`).map((e) => e.v.length);
    const id = await evalApp(`return ac.store.getState().newTab(${JSON.stringify(windowId)}, { url: "${base}${path}" })`);
    await until("the page", async () => (await state()).tabs.find((t) => t.id === id && t.title === "Page B" && !t.loading), 15000);
    await until("its visit", async () => (await visits()).length || null);
    await sleep(2000);
    const pooled = await evalApp(`return !!globalThis.expo.modules.SolaraTabPool?.available()`);
    const page = await pageFor(id, path);
    const expected = pooled ? `${base}${path}-pushed` : `${base}${path}`;
    await evalApp(`setTimeout(() => { try { globalThis.nativeModuleProxy.DevSettings.reload(); } catch {} }, 50); return true`);
    await sleep(300);
    if (pooled) await cdp(page, "Runtime.evaluate", { expression: `history.pushState(null, "", ${JSON.stringify(`${path}-pushed`)})` });
    await sleep(1200);
    await until("the reloaded app", async () => {
      try {
        return await evalApp(`const s = ac.store.getState(); return Object.keys(s.windows).length > 0 && !!s.historyReady.default && !!ac.webviews.get(${JSON.stringify(id)})`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 60000);
    await sleep(2000);
    const out = { loads: served.get(path), visits: await visits(), url: (await state()).tabs.find((t) => t.id === id)?.url };
    if (out.loads !== 1 || JSON.stringify(out.visits) !== "[1]" || out.url !== expected) throw new Error(`after the reload: ${JSON.stringify(out)}`);
    return out;
  });

  await check("quit-js-stall", async () => {
    const windowId = await appUp("app-quit-stall.out.log");
    const started = Date.now();
    await evalApp(`ac.shell.devKeyEquivalent("${windowId}", { key: "q", keyCode: 12, modifiers: ["command"], focus: "window" });
      const t = Date.now(); while (Date.now() - t < 2000) {}
      ac.actions.openUrls(["${base}/d?stalled"], "${windowId}"); return true`, 5000).catch(() => null);
    await until("the app to exit", async () => exited, 20000);
    const exitMs = Date.now() - started;
    if (!savedSession().includes("d?stalled")) throw new Error(`the quit didn't wait for the app's save (exited after ${exitMs} ms)`);
    const tab = await restored("d?stalled");
    return { exitMs, restored: tab.url };
  });

  await check("quit-js-hung", async () => {
    const windowId = await appUp("app-quit-hung.out.log");
    const started = Date.now();
    await evalApp(`ac.shell.devKeyEquivalent("${windowId}", { key: "q", keyCode: 12, modifiers: ["command"], focus: "window" });
      for (;;) {}`, 1000).catch(() => null);
    try {
      const line = await until("the quit alert's log", async () => appLog.join().split("\n").find((l) => l.includes("[shell] quit alert:")) ?? null, Math.max(0, 6000 - (Date.now() - started)));
      const ms = Date.now() - started;
      if (ms > 6000) throw new Error(`the alert came after ${ms} ms`);
      if (exited) throw new Error("the app quit without the answer");
      return { ms, line: line.slice(line.indexOf("[shell]")) };
    } finally {
      child.kill("SIGKILL");
      await until("the hung app gone", async () => exited, 10000).catch(() => null);
    }
  });

  await check("extension-tab-empty-window", async () => {
    if (exited) await launch("app3.out.log");
    await until("the app", async () => {
      try {
        return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 90000);
    const windowId = await until("a window", async () => (await state()).windowId, 30000);
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    if (installed?.error) throw new Error(installed.error);
    await evalApp(`globalThis.__acTabs = []; globalThis.__acTabsSub?.remove();
      globalThis.__acTabsSub = globalThis.expo.modules.SolaraExtensions.addListener("onTabs", (e) => globalThis.__acTabs.push(e)); return true`);
    try {
      const worker = await extensionWorker(installed.id, "tabs.create");
      const create = async (url) => {
        const made = await cdp(worker, "Runtime.evaluate", {
          expression: `chrome.tabs.create({ url: "${url}" }).then((t) => JSON.stringify({ id: t.id, windowId: t.windowId }), (e) => "error: " + e.message)`,
          awaitPromise: true,
          returnByValue: true,
        });
        return made.result?.value ?? made.exceptionDetails?.exception?.description;
      };
      await evalApp(`const s = ac.store.getState(); Object.keys(s.windows).filter((id) => id !== "${windowId}").forEach((id) => s.closeWindow(id));
        s.closeTabs([...s.windows["${windowId}"].tabIds]); return true`);
      await until("one app window", async () => ((await evalApp(`return Object.keys(ac.store.getState().windows).length`)) === 1 ? true : null), 10000);
      const empty = await until("the window without pages", async () => {
        const s = await state();
        return s.windowId === windowId && s.tabs.every((t) => !t.url) ? s : null;
      }, 10000);
      await sleep(1000);
      const created = await create(`${base}/e?empty-window`);
      const made = JSON.parse(created.startsWith("{") ? created : "null");
      if (!made) throw new Error(`tabs.create: ${created}`);
      const shownTab = async () => {
        const s = await state();
        const tabs = s.tabs.filter((t) => t.url?.includes("e?empty-window"));
        return s.active === tabs[0]?.id && tabs[0].title === "Page E" && !tabs[0].loading ? { s, tabs } : null;
      };
      const { s: after, tabs: appTabs } = await until("the extension's tab shown as an app tab", shownTab, 10000)
        .catch(async (e) => { throw new Error(`${e.message}; tabs.create: ${created}; strips ${JSON.stringify(await cef(`tabStrips()`))}`); });
      await sleep(1500);
      const opened = appTabs[0];
      const chromeTab = JSON.parse((await cdp(worker, "Runtime.evaluate", {
        expression: `Promise.all([chrome.tabs.get(${made.id}).then((t) => ({ id: t.id, windowId: t.windowId, active: t.active, url: t.url }), (e) => ({ error: e.message })),
          chrome.tabs.query({}).then((ts) => ts.filter((t) => (t.url || t.pendingUrl || "").includes("e?empty-window")).map((t) => t.id))]).then(JSON.stringify)`,
        awaitPromise: true,
        returnByValue: true,
      })).result.value);
      const strips = (await cef(`tabStrips()`)).strips.filter((st) => st.appWindow === windowId);
      const strip = strips.find((st) => st.tabs.some((t) => t.key === opened.id));
      const out = {
        appTabs: (await state()).tabs.filter((t) => t.url?.includes("e?empty-window")).length,
        window: after.windowId === windowId,
        profile: opened.profileId === after.profileId ? opened.profileId : `${opened.profileId} in a ${after.profileId} window`,
        adoptId: opened.adoptId ?? null,
        chromeTab: chromeTab[0],
        chromeTabs: chromeTab[1],
        strip: strip ? { strip: strip.strip, active: strip.tabs.find((t) => t.active)?.key === opened.id, keyless: strip.tabs.filter((t) => !t.key).length } : null,
        loads: served.get("/e?empty-window") ?? 0,
      };
      const wrong = [
        out.appTabs !== 1 && "not exactly one app tab",
        !out.window && "another window",
        out.profile !== after.profileId && "another profile",
        !out.adoptId?.startsWith("tab:") && "a fresh tab, not Chrome's",
        (out.chromeTab.error || out.chromeTab.windowId !== made.windowId || !out.chromeTab.active) && "chrome.tabs doesn't see the extension's tab active in its window",
        JSON.stringify(out.chromeTabs) !== JSON.stringify([made.id]) && "chrome.tabs has another tab for the URL",
        (!out.strip || out.strip.strip !== made.windowId || !out.strip.active || out.strip.keyless) && "Chrome's strip for the app window disagrees",
        out.loads !== 1 && "the page loaded more than once",
      ].filter(Boolean);
      if (wrong.length) throw new Error(`${wrong.join("; ")}: ${JSON.stringify(out)}`);
      const event = (await evalApp(`return globalThis.__acTabs`)).some((e) => e.url?.includes("e?empty-window"));
      await evalApp(`const s = ac.store.getState(); Object.keys(s.windows).forEach((id) => s.closeWindow(id)); return true`);
      await until("no app windows", async () => ((await evalApp(`return Object.keys(ac.store.getState().windows).length`)) === 0 ? true : null), 10000);
      await sleep(1000);
      const noWindow = await create(`${base}/e?no-window`);
      await sleep(1500);
      const noWindowEvent = (await evalApp(`return globalThis.__acTabs`)).some((e) => e.url?.includes("e?no-window"));
      return { placeholderTabs: empty.tabs.length, tabsCreate: created, appTab: opened.id, ...out, route: event ? "onTabs" : "openWindow",
        noWindow: { tabsCreate: noWindow, onTabs: noWindowEvent } };
    } finally {
      await evalApp(`globalThis.__acTabsSub?.remove(); return true`).catch(() => null);
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
    }
  });

  await check("traffic-lights-steady", async () => {
    const w = (await state()).windowId ?? (await evalApp(`return ac.actions.openWindow()`));
    if (!w) throw new Error("no window to work in");
    await sleep(1000);
    const W = JSON.stringify(w);
    const logLength = () => (existsSync(lightsLog) ? readFileSync(lightsLog, "utf8").length : 0);
    const from = logLength();
    const run = async (body, settle = 500) => {
      const result = await evalApp(body);
      await sleep(settle);
      return result;
    };
    const tabs = [];
    for (let i = 0; i < 4; i++) tabs.push(await run(`return ac.store.getState().newTab(${W}, { url: "${base}/a?lights${i}" })`));
    for (const id of [tabs[0], tabs[2], tabs[1], tabs[3]]) await run(`ac.actions.switchToTab("${id}"); return true`);
    await run(`return ac.store.getState().createSplit(["${tabs[2]}", "${tabs[3]}"])`);
    await run(`ac.store.getState().closeTab("${tabs[3]}"); return true`);
    const hiding = logLength();
    await run(`ac.store.getState().toggleSidebar(${W}); return true`, 1500);
    const hidden = logLength();
    await run(`ac.actions.switchToTab("${tabs[0]}"); return true`);
    const showing = logLength();
    await run(`ac.store.getState().toggleSidebar(${W}); return true`, 1500);
    const shown = logLength();
    for (const id of [tabs[0], tabs[1], tabs[2]]) await run(`ac.store.getState().closeTab("${id}"); return true`);
    const other = await run(`return ac.actions.openWindow()`);
    await run(`ac.store.getState().closeWindow(${JSON.stringify(other)}); return true`);
    const log = readFileSync(lightsLog, "utf8");
    const linesOf = (a, b) => log.slice(a, b).split("\n").filter(Boolean);
    const sample = (line) => line.match(/ -> (.*?) \| /)?.[1] ?? line;
    const rest = (a, b) => linesOf(a, b).filter((line) => line.includes(" layout -> ")).slice(-1);
    const docked = [...linesOf(from, hiding), ...rest(showing, shown), ...linesOf(shown)];
    const away = [...rest(hiding, hidden), ...linesOf(hidden, showing)];
    if (!away.length || !rest(showing, shown).length) throw new Error(`no settled layout logged for the sidebar's slides`);
    const lines = [...docked, ...away];
    const healthy = (line) => sample(line).endsWith(" hidden=0 alpha=1.00") && !/ _NSTheme\w*Widget set/.test(line);
    const bad = docked.filter((line) => !sample(line).startsWith("close=(18.0,20.0) ") || !healthy(line));
    const out = (line) => {
      const xs = [...sample(line).matchAll(/=\((-?[\d.]+),(-?[\d.]+)\)/g)].map((m) => [Number(m[1]), Number(m[2])]);
      return xs.length === 3 && xs.every(([x, y]) => x + 14 <= 0 && y === 20);
    };
    const window = (line) => line.match(/window=(\d+)/)?.[1];
    const badAway = away.filter((line) => window(line) === window(docked[0] ?? "") && (!out(line) || !healthy(line)));
    const moved = [];
    for (const [phase, set] of [["docked", docked], ["hidden", away]]) {
      const places = new Map();
      for (const line of set) places.set(window(line), (places.get(window(line)) ?? new Set()).add(sample(line)));
      for (const [win, at] of places) if (at.size > 1) moved.push({ phase, window: win, places: [...at] });
    }
    if (!lines.some((line) => line.includes(" layout -> "))) throw new Error("no layout pass logged (is SOLARA_TRAFFIC_LIGHTS_LOG set?)");
    if (bad.length || badAway.length || moved.length)
      throw new Error(`traffic lights left their spot: ${JSON.stringify({ moved, bad: bad.slice(0, 6), badAway: badAway.slice(0, 6) })}`);
    return { samples: lines.length, hiddenSamples: away.length, layoutPasses: lines.filter((line) => line.includes(" layout -> ")).length };
  });

  await check("launch-cocoa-args", async () => {
    await stopApp();
    await launch("app-args.out.log", {}, ["-NSAppSleepDisabled", "YES", "-ApplePersistenceIgnoreState", "YES"]);
    await until("the relaunched app", async () => {
      try {
        return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 90000);
    await sleep(2000);
    const pages = (await targets()).filter((t) => t.type === "page").map((t) => t.url);
    if (pages.some((u) => /yes/i.test(u))) throw new Error(`a page for the defaults' value: ${JSON.stringify(pages)}`);
    const argv = execFileSync("ps", ["-o", "args=", "-p", String(pid)]).toString().trim();
    if (!argv.includes("-NSAppSleepDisabled YES")) throw new Error(`the process arguments lost the defaults: ${argv}`);
    return { pages: pages.length, argv: argv.slice(argv.indexOf("-NS")) };
  });

  await check("extension-pins-owner-shape", async () => {
    await appUp("app-pins-owner.out.log");
    mainWindow = await until("a window", async () => (await state()).windowId, 30000);
    const names = ["Alpha Keeper", "Bravo Notes", "Charlie Helper", "Delta Recorder"];
    const dirs = names.map((name) => {
      const dir = join(scratch, `owner-ext-${name.replace(/\W/g, "")}`);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "manifest.json"), JSON.stringify({ manifest_version: 3, name, version: "1.0", action: { default_popup: "popup.html", default_title: name }, background: { service_worker: "worker.js" } }));
      writeFileSync(join(dir, "popup.html"), `<!doctype html><title>${name}</title><p>${name}</p>`);
      writeFileSync(join(dir, "worker.js"), "chrome.runtime.onInstalled.addListener(() => {});");
      return dir;
    });
    const work = await evalApp(`return ac.store.getState().createProfile({ name: "Owner Work" })`);
    const play = await evalApp(`return ac.store.getState().createProfile({ name: "Owner Play" })`);
    const profiles = { personal: "", work, play };
    for (const id of [work, play]) await evalApp(`return ac.actions.openWindow({ profileId: ${JSON.stringify(id)}, url: "${base}/b?owner-${id}" })`);
    const listIn = async (p) => {
      const result = await exts(`list(${JSON.stringify(p)})`);
      if (result?.error) throw new Error(`list ${p}: ${result.error}`);
      return (result?.extensions ?? []).filter((x) => names.includes(x.name));
    };
    const pinnedNames = (list) => list.filter((x) => x.pinned).map((x) => x.name).sort();
    const shownPins = (p) => evalApp(`const list = ac.extensions.useExtensions.getState().lists[${JSON.stringify(p)}]; return list ? list.filter((e) => ${JSON.stringify(names)}.includes(e.name) && e.pinned).map((e) => e.name).sort() : null;`);
    const want = { personal: names.slice(), work: [names[0], names[2]], play: [names[3]] };
    const ids = {};
    for (const [key, p] of Object.entries(profiles)) {
      ids[key] = {};
      for (const dir of dirs) {
        const installed = await exts(`install(${JSON.stringify(dir)}, ${JSON.stringify(p)})`);
        if (!installed?.id) throw new Error(`install in ${key}: ${JSON.stringify(installed)}`);
        ids[key][installed.name ?? ""] = installed.id;
      }
      const list = await until(`${key}'s fixtures with actions`, async () => {
        const l = await listIn(p);
        return l.length === 4 && l.every((x) => x.hasAction !== false) ? l : null;
      }, 15000);
      for (const ext of list) if (want[key].includes(ext.name)) await exts(`configure("${ext.id}", ${JSON.stringify(p)}, { pinned: true })`);
    }
    const before = {};
    for (const [key, p] of Object.entries(profiles)) before[key] = pinnedNames(await listIn(p));
    await stopApp();
    await launch("app-pins-owner.out.log");
    await until("the relaunched app", async () => {
      try {
        return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 90000);
    mainWindow = await until("a window", async () => (await state()).windowId, 30000);
    const windows = await until("all three windows restored", async () => {
      const w = await evalApp(`return Object.values(ac.store.getState().windows).filter((w) => !w.incognito).map((w) => w.profileId)`);
      return w.length >= 3 ? w : null;
    }, 30000).catch(() => null);
    const firstShown = {};
    for (const [key, p] of Object.entries(profiles)) firstShown[key] = await until(`${key}'s first list in the app`, () => shownPins(p), 20000).catch(() => "never listed");
    await sleep(3000);
    const shownAfter = {};
    for (const [key, p] of Object.entries(profiles)) shownAfter[key] = await shownPins(p);
    const engineAfter = {};
    for (const [key, p] of Object.entries(profiles)) engineAfter[key] = pinnedNames(await listIn(p));
    const toggled = (await listIn(work)).find((x) => x.name === names[1]);
    await evalApp(`return ac.extensions.setPinned(${JSON.stringify(work)}, ${JSON.stringify(toggled.id)}, true).then(() => true)`);
    await sleep(2000);
    const afterToggle = { work: await shownPins(work), workEngine: pinnedNames(await listIn(work)), personal: await shownPins(""), play: await shownPins(play) };
    const out = { windows, before, firstShown, shownAfter, engineAfter, afterToggle };
    const problems = [];
    for (const key of Object.keys(profiles)) {
      if (JSON.stringify(before[key]) !== JSON.stringify(want[key].slice().sort())) problems.push(`${key} pins before: ${JSON.stringify(before[key])}`);
      if (JSON.stringify(firstShown[key]) !== JSON.stringify(want[key].slice().sort())) problems.push(`${key} first list after relaunch: ${JSON.stringify(firstShown[key])}`);
      if (JSON.stringify(shownAfter[key]) !== JSON.stringify(want[key].slice().sort())) problems.push(`${key} list 3 s later: ${JSON.stringify(shownAfter[key])}`);
      if (JSON.stringify(engineAfter[key]) !== JSON.stringify(want[key].slice().sort())) problems.push(`${key} engine after relaunch: ${JSON.stringify(engineAfter[key])}`);
    }
    const workWant = [names[0], names[1], names[2]].sort();
    if (JSON.stringify(afterToggle.work) !== JSON.stringify(workWant)) problems.push(`work after pinning ${names[1]}: ${JSON.stringify(afterToggle.work)}`);
    if (JSON.stringify(afterToggle.personal) !== JSON.stringify(want.personal.slice().sort()) || JSON.stringify(afterToggle.play) !== JSON.stringify(want.play)) problems.push(`other profiles changed by the toggle: ${JSON.stringify(afterToggle)}`);
    if (problems.length) throw new Error(`${problems.join("; ")} | ${JSON.stringify(out)}`);
    return out;
  });

  await check("extension-pins-after-relaunch", async () => {
    await appUp("app-pins.out.log");
    const installed = await exts(`install(${JSON.stringify(extPath)}, "")`);
    const listed = async () => {
      const result = await exts(`list("")`);
      if (result?.error) throw new Error(`list: ${result.error}`);
      return (result?.extensions ?? []).find((x) => x.id === installed.id) ?? null;
    };
    try {
      await until("the fixture listed with its action", async () => ((await listed())?.hasAction ? true : null), 10000);
      await exts(`configure("${installed.id}", "", { pinned: true })`);
      const pinnedBefore = (await listed())?.pinned === true;
      await stopApp();
      await launch("app-pins.out.log");
      await until("the relaunched app", async () => {
        try {
          return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
        } catch (e) {
          if (exited) throw e;
          return null;
        }
      }, 90000);
      mainWindow = await until("a window", async () => (await state()).windowId, 30000);
      const shown = () => evalApp(`const lists = ac.extensions.useExtensions.getState().lists; for (const list of Object.values(lists)) { const x = list.find((e) => e.id === "${installed.id}"); if (x) return { pinned: !!x.pinned }; } return null;`);
      await until("the app's first extension list", shown, 20000);
      await sleep(3000);
      const afterRelaunch = await shown();
      const engineAfter = (await listed())?.pinned === true;
      if (!pinnedBefore) throw new Error("the pin didn't take before the relaunch");
      if (afterRelaunch?.pinned !== true) throw new Error(`the toolbar's list lost the pin after a relaunch: ${JSON.stringify({ afterRelaunch, engineAfter })}`);
      return { pinnedBefore, afterRelaunch, engineAfter };
    } finally {
      await exts(`uninstall("${installed.id}", "")`).catch(() => null);
    }
  });

  await check("context-menu-log", async () => {
    const menuLog = join(scratch, "context-menu.json");
    rmSync(menuLog, { force: true });
    await stopApp();
    await launch("app4.out.log", { SOLARA_CONTEXT_MENU_LOG: menuLog });
    await until("the relaunched app", async () => {
      try {
        return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
      } catch (e) {
        if (exited) throw e;
        return null;
      }
    }, 90000);
    mainWindow = await until("a window", async () => (await state()).windowId, 30000);
    await evalApp(`ac.actions.openUrls(["${base}/a?menu"], ${JSON.stringify(mainWindow)}); return true`);
    const tab = await until("A", async () => (await state()).tabs.find((t) => t.url?.endsWith("/a?menu") && !t.loading));
    await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
    await sleep(500);
    const t = await pageFor(tab.id, "/a?menu");
    const rightClick = async () => {
      const box = JSON.parse((await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('next').getBoundingClientRect())", returnByValue: true })).result.value);
      const at = { x: box.x + 3, y: box.y + box.height / 2, button: "right", clickCount: 1 };
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at });
    };
    await rightClick();
    const menu = await until("the menu dumped", async () => (existsSync(menuLog) ? JSON.parse(readFileSync(menuLog, "utf8")) : null), 8000);
    const open = menu.items.find((i) => i.label === "Open Link in New Tab");
    if (!menu.url?.endsWith("/a?menu") || !menu.link?.endsWith("/b") || !open || open.type !== 1 || !menu.items.some((i) => i.type === 4))
      throw new Error(`menu ${JSON.stringify(menu).slice(0, 600)}`);
    const before = new Set((await state()).tabs.map((x) => x.id));
    writeFileSync(`${menuLog}.pick`, "Open Link in New Tab\t0\n");
    await rightClick();
    const opened = await until("the picked item's tab", async () => (await state()).tabs.find((x) => !before.has(x.id) && x.url?.endsWith("/b")), 8000);
    if (existsSync(`${menuLog}.pick`)) throw new Error("the pick file wasn't taken");
    return { items: menu.items.length, link: menu.link, picked: opened.url };
  });

  await check("context-menu-incognito", async () => {
    const menuLog = join(scratch, "context-menu.json");
    const tab = await until("A", async () => (await state()).tabs.find((t) => t.url?.endsWith("/a?menu") && !t.loading));
    await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
    const t = await pageFor(tab.id, "/a?menu");
    const box = JSON.parse((await cdp(t, "Runtime.evaluate", { expression: "JSON.stringify(document.getElementById('next').getBoundingClientRect())", returnByValue: true })).result.value);
    const at = { x: box.x + 3, y: box.y + box.height / 2, button: "right", clickCount: 1 };
    const windowsBefore = await evalApp(`return Object.keys(ac.store.getState().windows)`);
    const tabsBefore = await evalApp(`return Object.keys(ac.store.getState().tabs)`);
    writeFileSync(`${menuLog}.pick`, "Open Link in Incognito Window\t0\n");
    await cdp(t, "Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
    await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at });
    await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at });
    const newTabs = () => evalApp(`const s = ac.store.getState(), before = new Set(${JSON.stringify(tabsBefore)});
      return Object.values(s.tabs).filter((t) => !before.has(t.id)).map((t) => ({ id: t.id, url: t.url, title: t.title, windowId: t.windowId,
        incognito: !!s.windows[t.windowId]?.incognito, newWindow: !${JSON.stringify(windowsBefore)}.includes(t.windowId) }))`);
    const landed = await until("the link's page in the app", async () => (await newTabs()).find((t) => t.url?.endsWith("/b") && t.title === "Page B") ?? null, 15000)
      .catch(async (e) => { throw new Error(`${e.message}; new tabs ${JSON.stringify(await newTabs())}`); });
    await sleep(500);
    const all = await newTabs();
    if (!landed.incognito || !landed.newWindow || all.some((x) => !x.incognito)) throw new Error(`Open Link in Incognito Window: ${JSON.stringify(all)}`);
    await evalApp(`ac.store.getState().closeWindow(${JSON.stringify(landed.windowId)}); return true`);
    return landed;
  });

  await check("context-menu-split", async () => {
    const menuLog = join(scratch, "context-menu.json");
    const tab = await until("A", async () => (await state()).tabs.find((t) => t.url?.endsWith("/a?menu") && !t.loading));
    await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
    await sleep(500);
    const t = await pageFor(tab.id, "/a?menu");
    const tabsBefore = await evalApp(`return Object.keys(ac.store.getState().tabs)`);
    const groupsBefore = await evalApp(`return Object.keys(ac.store.getState().groups)`);
    const result = () => evalApp(`const s = ac.store.getState(), before = new Set(${JSON.stringify(tabsBefore)}), groupsBefore = new Set(${JSON.stringify(groupsBefore)});
      const opened = Object.values(s.tabs).filter((t) => !before.has(t.id)).map((t) => ({ id: t.id, url: t.url, windowId: t.windowId }));
      const split = Object.values(s.splits).find((v) => v.tabIds.includes(${JSON.stringify(tab.id)})) ?? null;
      return { opened, split, newGroups: Object.keys(s.groups).filter((g) => !groupsBefore.has(g)) }`);
    const openInSplit = async (path) => {
      const box = JSON.parse((await cdp(t, "Runtime.evaluate", { expression: `(() => { const a = document.getElementById('next'); a.setAttribute('href', ${JSON.stringify(path)}); return JSON.stringify(a.getBoundingClientRect()); })()`, returnByValue: true })).result.value);
      const at = { x: box.x + 3, y: box.y + box.height / 2, button: "right", clickCount: 1 };
      writeFileSync(`${menuLog}.pick`, "Open Link in Split View\t0\n");
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mousePressed", ...at });
      await cdp(t, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at });
      await until(`the tab for ${path}`, async () => (await result()).opened.some((x) => x.url?.endsWith(path)), 15000)
        .catch(async (e) => { throw new Error(`${e.message}; ${JSON.stringify(await result())}`); });
      await sleep(1500);
      return { r: await result(), requests: served.get(path) ?? 0, referer: referers.get(path) };
    };
    const first = await openInSplit("/b?split-1");
    const b = first.r.opened.find((x) => x.url?.endsWith("/b?split-1"));
    if (first.r.opened.length !== 1 || first.r.split?.tabIds.join() !== [tab.id, b.id].join() || first.r.newGroups.length || first.requests !== 1 || !first.referer?.endsWith("/a?menu"))
      throw new Error(`Open Link in Split View: ${JSON.stringify(first)}`);
    const second = await openInSplit("/b?split-2");
    const c = second.r.opened.find((x) => x.url?.endsWith("/b?split-2"));
    if (second.r.opened.length !== 2 || second.r.split?.tabIds.join() !== [tab.id, c.id].join() || second.r.newGroups.length || second.requests !== 1 || !second.referer?.endsWith("/a?menu"))
      throw new Error(`Open Link in Split View from a split page: ${JSON.stringify(second)}`);
    await evalApp(`ac.store.getState().closeTabs(${JSON.stringify([b.id, c.id])}); return true`);
    return { split: second.r.split.tabIds, kept: b.id, requests: [first.requests, second.requests], referer: second.referer };
  });
  // MARK: Camera and microphone (the 0.2.21 crash: Allow on a camera + microphone prompt aborted the app)
  const mediaChecks = ["camera-mic-allow", "permission-answer-once", "permission-element-allow"];
  if (!only.length || mediaChecks.some((c) => only.includes(c))) {
    const mediaApp = join(scratch, "media-app", basename(app));
    let media = null;
    try {
      rmSync(join(scratch, "media-app"), { recursive: true, force: true });
      mkdirSync(join(scratch, "media-app"), { recursive: true });
      execFileSync("cp", ["-cR", app, mediaApp]);
      const entitlements = join(scratch, "media-app", "entitlements.plist");
      writeFileSync(entitlements, `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>`);
      execFileSync("codesign", ["-f", "-s", "-", "--options", "runtime", "--entitlements", entitlements, mediaApp], { stdio: "ignore" });
      const signed = execFileSync("codesign", ["-d", "--entitlements", "-", "--xml", mediaApp], { stdio: ["ignore", "pipe", "ignore"] }).toString();
      if (/device\.(camera|audio-input)/.test(signed)) throw new Error("the media copy kept a device entitlement");
      await stopApp();
      await launch("app-media.out.log", {}, [], { app: mediaApp, switches: "--solara-test-system-media-permission=ask" });
      await until("the media copy", async () => {
        try {
          return await evalApp(`return globalThis.expo.modules.SolaraCEF.engineInfo()`, 3000);
        } catch (e) {
          if (exited) throw e;
          return null;
        }
      }, 90000);
      mainWindow = await until("a window", async () => (await state()).windowId, 30000);
      const port = server.address().port;
      let site = 0;
      media = {
        async open(path, title) {
          const url = `http://media${++site}.localhost:${port}${path}`;
          const before = new Set((await state()).tabs.map((t) => t.id));
          await evalApp(`ac.actions.openUrls([${JSON.stringify(url)}], ${JSON.stringify(mainWindow)}); return true`);
          const tab = await until(`a tab for ${url}`, async () => (await state()).tabs.find((t) => !before.has(t.id) && t.title === title && !t.loading), 15000);
          await evalApp(`ac.actions.switchToTab("${tab.id}"); return true`);
          await until("it shown", async () => (await state()).active === tab.id);
          return { ...tab, target: await until("its page", () => pageTarget(url), 10000) };
        },
        js: async (t, expression) => (await cdp(t, "Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, userGesture: true })).result.value,
        prompt: (tabId) => evalApp(`return ac.pageState.getState().pages["${tabId}"]?.permission ?? null`),
        answer: (tabId, id, result) => evalApp(`ac.permissions.answerPermission("${tabId}", "${id}", "${result}"); return true`),
        async answered(t, i = 0) {
          return until("the page's getUserMedia answer", async () => {
            const a = JSON.parse(await this.js(t, "JSON.stringify(window.__asks)"))[i];
            return a && a.state !== "pending" ? a : null;
          }, 15000);
        },
      };
    } catch (e) {
      media = { error: String(e?.message ?? e) };
    }
    const mediaCheck = (name, fn) => check(name, async () => {
      if (media?.error) throw new Error(`media copy: ${media.error}`);
      return fn();
    });

    await mediaCheck("camera-mic-allow", async () => {
      const tab = await media.open("/cam", "Cam");
      try {
        await media.js(tab.target, `ask({ audio: true, video: true })`);
        const request = await until("the prompt", () => media.prompt(tab.id), 10000);
        if (request.permissions.length !== 2 || !request.permissions.includes("camera") || !request.permissions.includes("microphone"))
          throw new Error(`one prompt for both, got ${JSON.stringify(request.permissions)}`);
        await media.answer(tab.id, request.id, "accept");
        const answer = await media.answered(tab.target);
        if (answer.state !== "ok" || answer.audio?.[0] !== "live" || answer.video?.[0] !== "live") throw new Error(`getUserMedia: ${JSON.stringify(answer)}`);
        await sleep(1000);
        const again = await media.prompt(tab.id);
        if (again) throw new Error(`a second prompt: ${JSON.stringify(again)}`);
        if (exited) throw new Error("the app exited");
        return { permissions: request.permissions, audio: answer.audio, video: answer.video };
      } finally {
        await media.js(tab.target, "stopAll()").catch(() => null);
        await closeTab(tab.id);
      }
    });

    await mediaCheck("permission-answer-once", async () => {
      const tab = await media.open("/cam", "Cam");
      try {
        await media.js(tab.target, `ask({ audio: true, video: true })`);
        const request = await until("the prompt", () => media.prompt(tab.id), 10000);
        await evalApp(`ac.permissions.answerPermission("${tab.id}", "${request.id}", "accept"); ac.permissions.answerPermission("${tab.id}", "${request.id}", "accept"); return true`);
        await cef(`resolvePermission("${request.id}", "accept", true)`);
        await cef(`resolvePermission("${request.id}", "deny", true)`);
        const answer = await media.answered(tab.target);
        if (answer.state !== "ok" || answer.audio?.[0] !== "live" || answer.video?.[0] !== "live") throw new Error(`getUserMedia: ${JSON.stringify(answer)}`);
        await media.js(tab.target, `navigator.requestMIDIAccess({ sysex: true }).then(() => (window.__midi = "granted"), (e) => (window.__midi = e.name)); true`);
        const next = await until("the next prompt", async () => {
          const p = await media.prompt(tab.id);
          return p && p.id !== request.id ? p : null;
        }, 10000);
        await media.answer(tab.id, request.id, "accept");
        await sleep(800);
        const still = await media.prompt(tab.id);
        if (still?.id !== next.id) throw new Error(`a late answer to ${request.id} answered ${next.id}`);
        await media.answer(tab.id, next.id, "dismiss");
        if (exited) throw new Error("the app exited");
        return { first: request.permissions, next: next.permissions, alive: true };
      } finally {
        await media.js(tab.target, "stopAll()").catch(() => null);
        await closeTab(tab.id);
      }
    });

    await mediaCheck("permission-element-allow", async () => {
      const tab = await media.open("/element", "Element");
      try {
        await sleep(1200);
        const at = await media.js(tab.target, "box()");
        for (const type of ["mouseMoved", "mousePressed", "mouseReleased"])
          await cdp(tab.target, "Input.dispatchMouseEvent", { type, x: at.x, y: at.y, button: "left", clickCount: 1 });
        const request = await until("the prompt", () => media.prompt(tab.id), 10000);
        await media.answer(tab.id, request.id, "accept");
        const events = await until("the element's stream", async () => {
          const ev = JSON.parse(await media.js(tab.target, "JSON.stringify(__ev)"));
          return ev.length ? ev : null;
        }, 10000);
        const again = await media.prompt(tab.id);
        if (again) throw new Error(`a second prompt: ${JSON.stringify(again)}`);
        if (events[0]?.audio?.[0] !== "live" || events[0]?.video?.[0] !== "live") throw new Error(`the element: ${JSON.stringify(events)}`);
        if (exited) throw new Error("the app exited");
        return { permissions: request.permissions, stream: events[0] };
      } finally {
        await media.js(tab.target, "stopAll()").catch(() => null);
        await closeTab(tab.id);
      }
    });
  }

  // MARK: Crash guard (ends the run)

  await check("crash-guard", async () => {
    const reports = () => readdirSync(join(process.env.HOME, "Library/Logs/DiagnosticReports")).filter((f) => f.startsWith(`${basename(exe)}-`));
    const before = new Set(reports());
    const front = execFileSync("lsappinfo", ["front"]).toString().trim();
    const crashed = pid;
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const ws = new WebSocket(version.webSocketDebuggerUrl);
    await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
    ws.send(JSON.stringify({ id: 1, method: "Browser.crash" }));
    await until("the instance gone", async () => exited, 15000);
    try { ws.close(); } catch {}
    const record = join(data, "crashes", `crash-${crashed}.txt`);
    await until("its crash record", async () => existsSync(record), 5000);
    await sleep(3000);
    const fresh = reports().filter((f) => !before.has(f));
    const frontAfter = execFileSync("lsappinfo", ["front"]).toString().trim();
    if (fresh.length) throw new Error(`macOS made a crash report: ${fresh}`);
    if (frontAfter !== front) throw new Error(`the frontmost app changed: ${front} → ${frontAfter}`);
    return { record: readFileSync(record, "utf8").split("\n")[0], front: "unchanged" };
  });
} finally {
  if (notificationOnly && instance && alive()) {
    try {
      notificationQuit = await instance.quit();
      assert.equal(alive(), false, "fallback owned shutdown completed");
      captureNotificationRetirement();
      assertNotificationJournal(notificationJournal(), true);
    } catch (error) {
      results.push({ name: "notifications-one-requester-shutdown", ok: false, error: String(error) });
      report.record("notifications-one-requester-shutdown", { error });
    }
  }
  if (notificationWatch) {
    if (!notificationWatch.finished) {
      await notificationWatch.finish();
      try { await notificationWatch.assertZero(); }
      catch (error) {
        results.push({ name: "notifications-one-requester-monitor", ok: false, error: String(error) });
        report.record("notifications-one-requester-monitor", { error });
      }
    }
    writeFileSync(join(notificationEvidence, "notification-process-history.json"), JSON.stringify(notificationWatch.evidence(), null, 2));
  }
  visibilityWatch?.stop();
  writeFileSync(join(notificationOnly ? notificationEvidence : scratch, "results.json"), JSON.stringify(results, null, 2));
  const passed = results.filter((r) => r.ok).length;
  report.summary();
  if (keep && !exited) {
    instance.save({ http: server.address().port, https: tlsServer.address().port });
    report.say(`kept pid ${pid}: --attach ${scratch} [check…] runs more; scripts/agent/ac quit ${data} ends it`);
  } else {
    if (keep) report.say("not kept: the app had exited");
    if (!notificationOnly) await instance.quit();
    rmSync(join(scratch, "media-app"), { recursive: true, force: true });
  }
  server.closeAllConnections?.();
  server.close();
  tlsServer.closeAllConnections?.();
  tlsServer.close();
  process.exit(passed === results.length ? 0 : 1);
}
