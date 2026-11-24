#!/usr/bin/env node
import { execFile, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, screenLocked, sleep } from "../../../scripts/lib/instance.mjs";

const LEGS = ["H1-quit", "H1-uptime", "H2-early-window", "M1-token"];
const HELP = `usage: node apps/browser/scripts/s7b-repro.mjs <Debug Solara.app> [leg…] [--list] [--keep-data]

Native queries use ac.native.state(); null means no readable native workspace, so readiness cannot pass.

Reproduces two store-unavailable bugs with only what main already has, in hidden instances. Each leg has its own data
folder and its own launch-switch defaults suite (SOLARA_LAUNCH_SWITCHES_DEFAULTS), deleted with \`defaults delete\` at the
end. Exit 0 only when every leg passes; a leg prints PASS, FAIL or INCONCLUSIVE with its evidence.

  H1-quit          a normal launch makes the data folder, then session.json becomes {"version":99} so the native store
                   refuses it (ImportRefused). Two refused launches, each quit gracefully: SolaraLaunchSwitchFailedLaunches
                   must read 1 and then 2, since a launch whose store never opened is not a success. Main clears it on quit.
  H1-uptime        the same refused launch kept up for 65 s (LaunchSuccess.uptimeSeconds is 60); the counter, read while
                   it still runs, must be 1 or more. Main clears it after the uptime.
  H2-early-window  a normal launch saves a session with a launchTab and launchBackdrop. Each relaunch reads the Debug
                   probe earlyWindow.decision: SolaraCore's own early-window decision (the function TryEarlyWindow
                   calls), leaving out whether the instance is hidden. Controls on the good session: a normal relaunch
                   must say wouldShow true, one with SOLARA_EARLY_WINDOW=off wouldShow false. Then session.json gets
                   version 99 (and loses its nativeExport marker, without which the native store reads its database
                   and never refuses): the decision must be wouldShow false. Main says true. If a control fails, the
                   leg is INCONCLUSIVE. Windows seen before JS are logged too. Every relaunch sets
                   SOLARA_TEST_EARLY_WINDOW_IGNORES_HIDDEN=1, without which a hidden instance always skips the early
                   window.
  M1-token         after the fix only (main has no safe-mode request, so it fails there). A normal launch makes the data
                   folder and opens the store. Then SolaraLaunchSwitchSafeModeRequested is written to the suite as one
                   fresh UUID and Solara is launched without SOLARA_SAFE_MODE_REQUEST: SolaraStoreAdapter.status() must
                   not report safeMode, and the key must be gone. The key is written again and Solara launched with
                   SOLARA_SAFE_MODE_REQUEST set to the same UUID: status() must report safeMode, and the key must be gone.`;

const args = process.argv.slice(2);
if (args.includes("--list")) {
  console.log(LEGS.join("\n"));
  process.exit(0);
}
if (args.includes("--help") || !args.find((a) => !a.startsWith("--"))) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const [appArg, ...picked] = args.filter((a) => !a.startsWith("--"));
const appPath = resolve(appArg);
if (appPath.startsWith("/Applications/") || appPath.includes("/build-vista/")) {
  console.error("use an isolated Debug app");
  process.exit(2);
}
for (const name of picked) if (!LEGS.includes(name)) {
  console.error(`unknown leg ${name} (--list)`);
  process.exit(2);
}
const legs = picked.length ? picked : LEGS;
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-s7b-repro-"));
const rep = reporter(join(scratch, "s7b-repro.log"), { name: "s7b-repro" });
const q = JSON.stringify;
const COUNTER = "SolaraLaunchSwitchFailedLaunches";
const SAFE_MODE_REQUEST = "SolaraLaunchSwitchSafeModeRequested";
const UPTIME_SECONDS = 60;
const LEG_MS = 9 * 60 * 1000;
const HOLD_MS = 12000;
const metroPort = Number(process.env.METRO_PORT ?? 8081);
const running = new Set();
const suites = [];
const gates = new Set();
const results = [];
let aborted = false;

class Inconclusive extends Error {}
const inconclusive = (message) => { throw new Inconclusive(message); };
const say = (line) => { rep.log(line); console.log(line); };

const suiteFor = (leg) => {
  const suite = `solara-s7b-repro-${process.pid}-${Date.now()}-${leg}`;
  suites.push(suite);
  return suite;
};
const defaultsRead = (suite, key) => {
  const r = spawnSync("defaults", ["read", suite, key], { encoding: "utf8", timeout: 5000 });
  return r.status === 0 ? r.stdout.trim() : null;
};
const defaultsWrite = (suite, key, value) => {
  const r = spawnSync("defaults", ["write", suite, key, "-string", value], { encoding: "utf8", timeout: 5000 });
  if (r.status !== 0) throw new Error(`defaults write ${suite} ${key} failed: ${r.stderr || r.error?.message}`);
};
const systemDark = () => spawnSync("defaults", ["read", "-g", "AppleInterfaceStyle"], { encoding: "utf8", timeout: 5000 }).stdout?.trim() === "Dark";

const start = async (data, { suite, fresh = false, js, env = {} } = {}) => {
  if (aborted) throw new Error("the leg ran out of time");
  const app = await launch(appPath, {
    data, fresh, onboarded: true, ready: false, ...(js ? { js } : {}),
    env: { ...(suite ? { SOLARA_LAUNCH_SWITCHES_DEFAULTS: suite } : {}), ...env },
  });
  running.add(app);
  say(`  launched pid ${app.pid} on ${data}${suite ? `, suite ${suite}` : ""}${js ? `, JS from ${js}` : ""}${Object.keys(env).length ? `, env ${q(env)}` : ""}`);
  return app;
};
const stop = async (app) => {
  const how = await app.quit();
  running.delete(app);
  say(`  quit pid ${app.pid}: ${how.how}`);
  return how;
};
const stopAll = async () => {
  for (const app of [...running]) {
    try { await stop(app); } catch (e) { process.stderr.write(`couldn't quit pid ${app.pid}: ${e.message}\n`); }
  }
  for (const gate of [...gates]) gate.close();
};

const WINDOWS_JXA = (pid) => `ObjC.import("CoreGraphics"); JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)))
  .filter((w) => w.kCGWindowOwnerPID === ${pid} && w.kCGWindowLayer <= 0 && w.kCGWindowLayer > -2000000)
  .map((w) => ({ n: w.kCGWindowNumber, w: Math.round(w.kCGWindowBounds.Width), h: Math.round(w.kCGWindowBounds.Height), a: w.kCGWindowAlpha })))`;
const windowsOf = (pid) => new Promise((done, fail) => {
  execFile("osascript", ["-l", "JavaScript", "-e", WINDOWS_JXA(pid)], { timeout: 10000 }, (error, stdout) => {
    if (error) return fail(error);
    try { done(JSON.parse(stdout.toString())); } catch (e) { fail(e); }
  });
});
const browserSized = (w) => w.w >= 300 && w.h >= 200 && w.a > 0;
const sampleWindows = async (app, untilMs) => {
  const seen = new Map();
  let samples = 0;
  let errors = 0;
  while (Date.now() < untilMs && app.alive) {
    try {
      const t = Date.now() - app.launchedAt;
      for (const w of await windowsOf(app.pid)) {
        const key = `${w.n}:${w.w}x${w.h}`;
        if (!seen.has(key)) seen.set(key, { ...w, firstAt: t });
      }
      samples++;
    } catch {
      errors++;
    }
    await sleep(200);
  }
  return { windows: [...seen.values()], samples, errors };
};

const bundleGate = async () => {
  let open = false;
  let firstAsk = null;
  let releasedAt = null;
  const held = [];
  const server = createServer((req, res) => {
    const forward = () => {
      const up = httpRequest({ host: "127.0.0.1", port: metroPort, path: req.url, method: req.method, headers: req.headers }, (r) => {
        res.writeHead(r.statusCode ?? 502, r.headers);
        r.pipe(res);
      });
      up.on("error", () => res.destroy());
      req.pipe(up);
    };
    if (!open && (req.url ?? "").split("?")[0].endsWith(".bundle")) {
      firstAsk ??= Date.now();
      held.push(forward);
    } else forward();
  });
  server.on("upgrade", (req, socket) => socket.destroy());
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const failSafe = setTimeout(() => gate.release(), HOLD_MS + 20000);
  const gate = {
    location: `localhost:${server.address().port}`,
    get firstAsk() { return firstAsk; },
    get releasedAt() { return releasedAt; },
    release() {
      if (open) return;
      open = true;
      releasedAt = Date.now();
      for (const f of held.splice(0)) f();
    },
    close() {
      clearTimeout(failSafe);
      gate.release();
      server.closeAllConnections?.();
      server.close();
      gates.delete(gate);
    },
  };
  gates.add(gate);
  return gate;
};

const refusal = (app) => /\[store\] unavailable: ([^\n]*)/.exec(app.output())?.[1] ?? null;

const prepare = async (data, extra = async () => {}) => {
  const app = await start(data, { fresh: true });
  await app.ready({ test: "return Object.keys(ac.native.state()?.windows ?? {}).length > 0", timeout: 90000 });
  await extra(app);
  await app.eval("return new Promise((r) => setTimeout(r, 2000));", { timeout: 10000 });
  const how = await stop(app);
  if (how.how !== "quit") throw new Error(`the preparing launch didn't quit gracefully (${how.how})`);
  if (!existsSync(join(data, "session.json"))) throw new Error("the preparing launch saved no session.json");
};

const refusedUp = async (app, ms = 30000) => {
  const deadline = Date.now() + ms;
  let js = null;
  while (Date.now() < deadline && !js) {
    try {
      js = await app.eval("const s = globalThis.expo?.modules?.SolaraStoreAdapter?.status?.(); return s ? s : { adapter: false };", { timeout: 3000 });
    } catch (e) {
      if (e.appDied) throw e;
    }
    if (!js) await sleep(250);
  }
  const refused = refusal(app);
  const evidence = { js: js ? { active: js.active, reason: js.reason, refusedSession: js.refusedSession ?? null } : "JS never answered", refused };
  say(`  refused launch up after ${Date.now() - app.launchedAt} ms: ${q(evidence)}`);
  if (!refused && !(js && js.active === false && js.refusedSession)) inconclusive(`the store didn't refuse the session: ${q(evidence)}`);
  return evidence;
};

const storeStatus = async (app, ms = 90000) => {
  const deadline = Date.now() + ms;
  let last = null;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error(`pid ${app.pid} exited before the store answered`);
    try {
      last = await app.eval("const s = globalThis.expo?.modules?.SolaraStoreAdapter?.status?.(); return s ? s : { adapter: false };", { timeout: 3000 });
      if (last && typeof last.active === "boolean") return last;
    } catch (e) {
      if (e.appDied) throw e;
    }
    await sleep(250);
  }
  throw new Error(`SolaraStoreAdapter.status() never answered within ${ms / 1000} s: ${q(last)}`);
};

const graceful = (how, what) => {
  if (how.how !== "quit") inconclusive(`${what} ended by ${how.how}, not a graceful quit, so willTerminate never ran and the counter proves nothing`);
};

const legRun = async (name, fn) => {
  if (!legs.includes(name)) return;
  rep.log(`\n## ${name}`);
  console.log(`\n${name}`);
  aborted = false;
  const t0 = Date.now();
  let status;
  let detail;
  let timer;
  try {
    detail = await Promise.race([fn(), new Promise((_, fail) => { timer = setTimeout(() => { aborted = true; fail(new Error(`${name} ran past ${LEG_MS / 60000} min`)); }, LEG_MS); })]);
    status = detail.status;
    detail = detail.evidence;
  } catch (e) {
    status = e instanceof Inconclusive ? "INCONCLUSIVE" : "FAIL";
    detail = e instanceof Inconclusive ? e.message : `driver error: ${e.stack ?? e.message}`;
  } finally {
    clearTimeout(timer);
    await stopAll();
  }
  const line = `${status} ${name} (${((Date.now() - t0) / 1000).toFixed(1)} s): ${typeof detail === "string" ? detail : q(detail)}`;
  rep.log(line);
  console.log(line);
  results.push({ name, status });
};

try {
  await legRun("H1-quit", async () => {
    const data = join(scratch, "H1-quit");
    const suite = suiteFor("H1-quit");
    await prepare(data);
    writeFileSync(join(data, "session.json"), '{"version":99}');
    const counts = [];
    for (const n of [1, 2]) {
      const app = await start(data, { suite });
      const up = await refusedUp(app);
      const how = await stop(app);
      graceful(how, `refused launch ${n}`);
      const counter = defaultsRead(suite, COUNTER);
      say(`  after refused launch ${n} quit: ${COUNTER} = ${counter ?? "(missing)"}`);
      counts.push({ launch: n, counter, quit: how.how, refused: up.refused });
    }
    const ok = Number(counts[0].counter) >= 1 && Number(counts[1].counter) === 2;
    return { status: ok ? "PASS" : "FAIL", evidence: { expected: "1 or more after the first quit, then 2", counts } };
  });

  await legRun("H1-uptime", async () => {
    const data = join(scratch, "H1-uptime");
    const suite = suiteFor("H1-uptime");
    await prepare(data);
    writeFileSync(join(data, "session.json"), '{"version":99}');
    const app = await start(data, { suite });
    const up = await refusedUp(app);
    const early = defaultsRead(suite, COUNTER);
    say(`  ${COUNTER} soon after launch: ${early ?? "(missing)"}`);
    const readAt = app.launchedAt + (UPTIME_SECONDS + 5) * 1000;
    while (Date.now() < readAt && app.alive) await sleep(500);
    if (!app.alive) throw new Error(`pid ${app.pid} exited before ${UPTIME_SECONDS + 5} s`);
    const uptime = Math.round((Date.now() - app.launchedAt) / 1000);
    const counter = defaultsRead(suite, COUNTER);
    let windows = null;
    try { windows = (await windowsOf(app.pid)).filter(browserSized).length; } catch {}
    say(`  at ${uptime} s, still running: ${COUNTER} = ${counter ?? "(missing)"}, browser-sized windows on screen ${windows}`);
    const how = await stop(app);
    return {
      status: Number(counter) >= 1 ? "PASS" : "FAIL",
      evidence: { expected: "1 or more while it runs past the uptime", counterSoonAfterLaunch: early, counterAtUptime: counter, uptime, windows, refused: up.refused, quit: how.how },
    };
  });

  await legRun("H2-early-window", async () => {
    const data = join(scratch, "H2-early-window");
    const suite = suiteFor("H2-early-window");
    const file = join(data, "session.json");
    await prepare(data, (app) => app.eval(`const st = ac.native.state(); const w = Object.keys(st.windows)[0];
      ac.native.command("newTab", w, { url: "data:text/html,<title>early</title>early" }); return new Promise((r) => setTimeout(r, 2500));`, { timeout: 15000 }));
    const rows = (table) => Array.isArray(table) ? table : Object.values(table ?? {});
    const ensureLaunchTab = (why) => {
      const saved = JSON.parse(readFileSync(file, "utf8"));
      if (!saved.launchTab) {
        const focused = rows(saved.windows).find((w) => w.id === saved.focusedWindowId);
        const tabId = focused?.activeTabIds?.[focused.profileId] ?? focused?.tabIds?.at(-1);
        const tab = rows(saved.tabs).find((t) => t.id === tabId);
        if (!tab) inconclusive(`H2 not reproducible in a hidden instance: no tab in the focused window to name as the launchTab (${why}): ${q(focused ?? null)}`);
        saved.launchTab = { id: tab.id, url: tab.url, profile: tab.profileId === "default" ? "" : tab.profileId };
        writeFileSync(file, JSON.stringify(saved));
        say(`  named the launchTab (${why}): ${q(saved.launchTab)}`);
      }
      return saved;
    };
    const describe = (saved) => {
      const focused = rows(saved.windows).find((w) => w.id === saved.focusedWindowId);
      let layout = null;
      try { layout = JSON.parse(readFileSync(join(data, "launch-layout.json"), "utf8")); } catch {}
      const layouts = layout?.windows ?? layout;
      return {
        focusedWindowId: saved.focusedWindowId ?? null, frame: focused?.frame ?? null, incognito: focused?.incognito ?? null, kind: focused?.kind ?? null,
        launchTab: saved.launchTab ?? null, launchBackdrop: saved.launchBackdrop ?? null, systemDark: systemDark(),
        backdropMatchesSystem: typeof saved.launchBackdrop?.dark === "boolean" ? saved.launchBackdrop.dark === systemDark() : null,
        windowsIsArray: Array.isArray(saved.windows), nativeExport: saved.nativeExport ?? null,
        launchLayout: layout ? (layouts && typeof layouts === "object" && saved.focusedWindowId in layouts ? "has the focused window" : `present, keys ${q(Object.keys(layouts ?? {}))}`) : "missing",
        screenLocked: screenLocked(),
      };
    };
    const saved = ensureLaunchTab("after the preparing launch");
    const prepared = describe(saved);
    say(`  saved session: ${q(prepared)}`);

    const readDecision = async (app) => {
      const deadline = Date.now() + 20000;
      let last;
      while (Date.now() < deadline) {
        try {
          const reply = await app.probe("earlyWindow.decision", {}, { timeout: 5000 });
          return reply?.result ?? reply;
        } catch (e) {
          last = e.message;
          await sleep(250);
        }
      }
      return { error: last ?? "no reply" };
    };
    const heldLaunch = async (env, what) => {
      const gate = await bundleGate();
      const app = await start(data, { suite, js: gate.location, env: { SOLARA_DRAW_WINDOWS: "1", SOLARA_TEST_EARLY_WINDOW_IGNORES_HIDDEN: "1", ...env } });
      const until = Date.now() + HOLD_MS;
      const seen = await sampleWindows(app, until);
      const beforeJS = seen.windows.filter(browserSized);
      const decision = await readDecision(app);
      say(`  ${what}: early-window decision ${q(decision)}`);
      say(`  ${what}: before JS (bundle asked at ${gate.firstAsk ? `${gate.firstAsk - app.launchedAt} ms` : "never"}, ${seen.samples} samples, ${seen.errors} errors): every window ${q(seen.windows)}`);
      gate.release();
      return { app, gate, beforeJS, decision, all: seen.windows, samples: seen.samples, bundleAsked: gate.firstAsk ? gate.firstAsk - app.launchedAt : null };
    };

    const positive = await heldLaunch({}, "control, early window on");
    if (refusal(positive.app)) throw new Error(`the good session was refused: ${refusal(positive.app)}`);
    try {
      await positive.app.ready({ test: "return Object.keys(ac.native.state()?.windows ?? {}).length > 0", timeout: 90000 });
      await positive.app.eval("return new Promise((r) => setTimeout(r, 2000));", { timeout: 10000 });
    } catch (e) {
      say(`  control: JS never came up after the gate opened: ${e.message}`);
    }
    await stop(positive.app);
    positive.gate.close();

    const negative = await heldLaunch({ SOLARA_EARLY_WINDOW: "off" }, "control, SOLARA_EARLY_WINDOW=off");
    try {
      await negative.app.ready({ test: "return Object.keys(ac.native.state()?.windows ?? {}).length > 0", timeout: 90000 });
    } catch (e) {
      say(`  off control: JS never came up after the gate opened: ${e.message}`);
    }
    await stop(negative.app);
    negative.gate.close();

    const sizes = (list) => list.map((w) => `${w.w}x${w.h}`);
    const controls = { on: positive.decision, off: negative.decision, windowsOn: sizes(positive.beforeJS), windowsOff: sizes(negative.beforeJS) };
    if (positive.decision?.atLaunch !== true || negative.decision?.atLaunch !== true) {
      inconclusive(`the decision wasn't recorded at launch (TryEarlyWindow never ran); ${q({ controls, prepared })}`);
    }
    if (positive.decision?.wouldShow !== true || positive.decision?.savedSession !== true || positive.decision?.safeMode !== false) {
      inconclusive(`the positive control failed: a good session should read savedSession and wouldShow true with safeMode false; ${q({ controls, prepared })}`);
    }
    if (negative.decision?.skipped !== "switchedOff" && negative.decision?.wouldShow !== false) {
      inconclusive(`the off control failed: SOLARA_EARLY_WINDOW=off should skip the early window; ${q({ controls, prepared })}`);
    }
    say(`  controls pass: a good session would show the early window (wouldShow true), and the switch turns it off`);

    const good = ensureLaunchTab("after the controls");
    const broken = { ...good, version: 99 };
    const hadMarker = Object.prototype.hasOwnProperty.call(broken, "nativeExport");
    delete broken.nativeExport;
    writeFileSync(file, JSON.stringify(broken));
    say(`  session.json: version 99${hadMarker ? ", nativeExport marker removed (deviation from editing only version: with the marker the store loads its database and never refuses)" : ", no nativeExport marker to remove"}; ${q(describe(broken))}`);

    const refusedRun = await heldLaunch({}, "refused session");
    await sleep(2000);
    const refused = refusal(refusedRun.app);
    await stop(refusedRun.app);
    refusedRun.gate.close();
    if (!refused) inconclusive(`the store didn't refuse the edited session (no "[store] unavailable:" line); windows before JS ${q(refusedRun.all)}`);
    const decision = refusedRun.decision;
    if (decision?.atLaunch !== true || decision?.skipped || typeof decision?.wouldShow !== "boolean") inconclusive(`no early-window decision from the refused launch: ${q(decision)}`);
    const evidence = {
      expected: "wouldShow false (and SavedSession nil) over a refused store", refused, decision,
      everyWindowBeforeJS: refusedRun.all, controls, hadMarker,
    };
    return { status: decision.wouldShow ? "FAIL" : "PASS", evidence };
  });

  await legRun("M1-token", async () => {
    const data = join(scratch, "M1-token");
    const suite = suiteFor("M1-token");
    await prepare(data);
    const token = randomUUID();
    const requestedLaunch = async (env, what) => {
      defaultsWrite(suite, SAFE_MODE_REQUEST, token);
      const stored = defaultsRead(suite, SAFE_MODE_REQUEST);
      if (stored !== token) inconclusive(`${what}: the request didn't land in ${suite}: ${q(stored)}`);
      const app = await start(data, { suite, env: env(token) });
      const status = await storeStatus(app);
      let probe = null;
      try {
        const reply = await app.probe("storeUnavailable.state", {}, { timeout: 5000 });
        const state = reply?.result ?? reply;
        probe = { safeMode: state?.safeMode ?? null, safeModeReason: state?.safeModeReason ?? null, shown: state?.shown ?? null };
      } catch (e) {
        probe = { error: e.message };
      }
      const left = defaultsRead(suite, SAFE_MODE_REQUEST);
      const counter = defaultsRead(suite, COUNTER);
      const how = await stop(app);
      const row = { what, tokenPassed: "SOLARA_SAFE_MODE_REQUEST" in env(token), active: status.active, safeMode: status.safeMode ?? null, probe, requestLeft: left, counter, quit: how.how };
      say(`  ${what}: ${q(row)}`);
      if (!status.active) inconclusive(`${what}: the store didn't open: ${q(status)}`);
      return row;
    };
    const without = await requestedLaunch(() => ({}), "launch without the token");
    const matching = await requestedLaunch((token) => ({ SOLARA_SAFE_MODE_REQUEST: token }), "launch with the matching token");
    const ok = !without.safeMode && without.requestLeft === null && Boolean(matching.safeMode) && matching.requestLeft === null;
    return {
      status: ok ? "PASS" : "FAIL",
      evidence: { expected: "no safe mode and the key gone without the token; safe mode and the key gone with it", without, matching },
    };
  });
} finally {
  await stopAll();
  for (const suite of suites) spawnSync("defaults", ["delete", suite], { stdio: "ignore", timeout: 5000 });
  if (!keep) for (const name of LEGS) rmSync(join(scratch, name), { recursive: true, force: true });
}
const passed = results.filter((r) => r.status === "PASS").length;
const summary = `${passed}/${results.length} legs passed: ${results.map((r) => `${r.name} ${r.status}`).join(", ")}. Log: ${rep.logFile}`;
rep.log(summary);
console.log(`\n${summary}`);
process.exit(results.length && passed === results.length ? 0 : 1);
