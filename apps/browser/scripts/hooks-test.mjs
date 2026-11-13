import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { isAlive, launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const app = process.argv[2] && process.argv[2] !== "--help" ? resolve(process.argv[2]) : process.argv[2];
if (!app || app === "--help") {
  console.error(`usage: METRO_PORT=<port> node apps/browser/scripts/hooks-test.mjs <Debug app> <evidence directory> [group…]

hooks.json end to end in hidden instances with a scratch SOLARA_CONFIG_DIR and download folder, on local pages:
links from other apps are dropped by block rules (the URL isn't logged) and sent to another profile by the sending
app and its signing team (the Debug devHooks seam sets the sender as bundle.id@TEAMID; a rule's team pin refuses
another team, and an app with no installed copy to check is refused and named in Settings; one real Apple event through open -a checks the AppDelegate path);
a page-loaded command doesn't run until approved, then runs with page data only in its environment and stdin, stops
once its program changes, and an edit revokes it; editing hooks.json reloads live, an invalid file keeps the last
good rules, a group- or world-writable file is ignored; a camera request from a matching site is denied with no
prompt (on an ad hoc copy without device entitlements). With the engine's hooks (ac_hooks_configure_v1): a download
lands straight in an approved folder (unique names from Chrome) and not in a folder swapped for a link; link clicks,
target=_blank, redirects, userinfo URLs and typed addresses to a blocked host aren't fetched; a rewrite waits for
approval and the original is never fetched; stripParams needs no approval; a regex capture can't pick the host.
Groups: links, downloads, commands, reload, camera, pages.`);
  process.exit(2);
}
const evidence = resolve(process.argv[3] ?? ".hooks-evidence");
const only = process.argv.slice(4);
mkdirSync(evidence, { recursive: true });

const requests = [];
const server = createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  requests.push({ host: url.hostname, path: url.pathname, query: url.search, at: Date.now() });
  response.setHeader("Cache-Control", "no-store");
  const html = (body) => { response.setHeader("Content-Type", "text/html; charset=utf-8"); response.end(`<!doctype html><meta charset=utf-8>${body}`); };
  if (url.pathname.startsWith("/dl")) {
    response.setHeader("Content-Type", "application/octet-stream");
    response.setHeader("Content-Disposition", `attachment; filename="hooks${url.pathname.replace(/\//g, "-")}.bin"`);
    return response.end(`hooks download ${url.pathname}`);
  }
  if (url.pathname === "/redirect") {
    response.statusCode = 302;
    response.setHeader("Location", `http://blocked.localhost:${port}/after-redirect`);
    return response.end();
  }
  if (url.pathname === "/links") {
    return html(`<title>Links</title><body style="margin:0">
      <a id="blocked" href="http://blocked.localhost:${port}/clicked" style="display:block;height:30px">blocked</a>
      <a id="blank" href="http://blocked.localhost:${port}/blank" target="_blank" style="display:block;height:30px">blank</a>
      <a id="redirect" href="http://127.0.0.1:${port}/redirect" style="display:block;height:30px">redirect</a>
      <a id="rewrite" href="http://127.0.0.1:${port}/strip?utm=1" style="display:block;height:30px">rewrite</a>`);
  }
  if (url.pathname === "/cch") {
    response.setHeader("Accept-CH", "Sec-CH-UA-Platform-Version");
    response.setHeader("Critical-CH", "Sec-CH-UA-Platform-Version");
    return html(`<title>Critical</title>critical ${request.headers["sec-ch-ua-platform-version"] ? "with" : "without"} hint`);
  }
  if (url.pathname === "/frame") {
    return html(`<title>Frame</title><iframe src="http://blocked.localhost:${port}/in-frame"></iframe>`);
  }
  if (url.pathname === "/cam") {
    return html(`<title>Camera</title><script>
      window.ask = () => navigator.mediaDevices.getUserMedia({ video: true }).then(
        (s) => { s.getTracks().forEach((t) => t.stop()); return "granted"; },
        (e) => e.name);
    </script>`);
  }
  html(`<title>Page ${url.pathname}</title><body>page ${url.hostname} ${url.pathname}${url.search}`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const port = server.address().port;
const local = `http://127.0.0.1:${port}`;
const seen = (host, path) => requests.filter((r) => r.host === host && r.path === path);

const until = async (name, probe, ms = 10000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await probe();
    if (last) return last;
    await sleep(150);
  }
  throw new Error(`${name} timed out: ${JSON.stringify(last)}`);
};

let failed = false;
const results = {};
async function check(run) {
  const started = Date.now();
  try {
    const detail = await run();
    return { pass: true, ms: Date.now() - started, detail };
  } catch (error) {
    failed = true;
    return { pass: false, ms: Date.now() - started, error: String(error?.stack ?? error).split("\n").slice(0, 4).join("\n") };
  }
}

const config = (name) => join(evidence, name, "config");
function writeHooks(name, hooks) {
  mkdirSync(config(name), { recursive: true });
  writeFileSync(join(config(name), "hooks.json"), typeof hooks === "string" ? hooks : JSON.stringify({ hooks }, null, 2));
}

async function start(name, hooks, { appPath = app, env = {}, profiles = ["Personal", "Work"] } = {}) {
  const downloads = join(evidence, name, "downloads");
  rmSync(join(evidence, name, "data"), { recursive: true, force: true });
  mkdirSync(downloads, { recursive: true });
  writeHooks(name, hooks);
  const instance = await launch(appPath, {
    data: join(evidence, name, "data"),
    env: { SOLARA_DOWNLOADS_DIR: downloads, SOLARA_CONFIG_DIR: config(name), SOLARA_ACCEPT_EXTERNAL_URLS: "1", ...env },
    session: session({
      profiles,
      windows: [{ id: "w1", frame: [80, 80, 1100, 760], activeTabIds: { default: "t1" } }],
      tabs: [{ id: "t1", windowId: "w1", url: `${local}/home`, title: "Home" }],
      settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeQuitting: false, openLinksInLittleSolara: false },
    }),
  });
  await instance.ready();
  await until("hooks.json loads", async () => (await hooksState(instance, "status")).present);
  return instance;
}

const hooksState = async (instance, action, argument = null) =>
  JSON.parse(await instance.eval(`return globalThis.expo.modules.SolaraSettings.devHooks(${JSON.stringify(action)}, ${JSON.stringify(argument)})`));
const approve = (instance, name) => hooksState(instance, "approve", name);
const fromApp = (instance, urls, app) => hooksState(instance, "openURLs", JSON.stringify({ urls, app }));
const tabs = (instance) => instance.eval(`const s = ac.store.getState();
  return Object.values(s.tabs).map((t) => ({ id: t.id, url: t.url, profileId: t.profileId, windowId: t.windowId }))`);
const downloadsOf = (instance) => instance.eval(`return ac.store.getState().downloads.map((d) => ({ id: d.id, filename: d.filename, state: d.state, path: d.path ?? null }))`);
const tabAt = (instance, prefix) => until(`a tab at ${prefix}`, async () => (await tabs(instance)).find((t) => t.url?.startsWith(prefix)));
const events = async (instance, kind) => (await hooksState(instance, "status")).events.filter((e) => !kind || e.kind === kind);

async function stop(instance, name, out) {
  const alive = isAlive(instance.pid);
  const quit = await instance.quit().catch((e) => ({ error: String(e) }));
  const crash = existsSync(join(evidence, name, "data", "crash.log"));
  const errors = (() => { try { return instance.jsErrors(); } catch { return null; } })();
  out[`${name}: quit`] = { pass: alive && !crash, aliveBeforeQuit: alive, quit: quit?.how ?? quit, crash, jsErrors: errors?.length ?? errors };
  if (!out[`${name}: quit`].pass) failed = true;
}

const groups = {
  async links() {
    const out = {};
    const instance = await start("links", [
      { name: "no-blocked", match: { hosts: ["blocked.localhost"] }, block: true },
      { name: "chat-to-work", match: { apps: ["com.example.chat"], team: "ABCDE12345" }, openIn: { profile: "Work" } },
      { name: "chat-drops", match: { apps: ["com.example.chat"], team: "ABCDE12345", hosts: ["dropped.localhost"] }, block: true },
      { name: "uninstalled-to-work", match: { apps: ["com.example.uninstalled"] }, openIn: { profile: "Work" } },
    ]);
    try {
      out["hooks.json loads with its four rules"] = await check(async () => {
        const s = await hooksState(instance, "status");
        assert.equal(s.error, null);
        assert.deepEqual(s.rules.map((r) => [r.name, r.needsApproval]), [["no-blocked", false], ["chat-to-work", false], ["chat-drops", false], ["uninstalled-to-work", false]]);
        return { path: s.path, engine: s.engine };
      });
      out["a blocked link from another app opens nothing, isn't fetched and isn't logged"] = await check(async () => {
        await fromApp(instance, [`http://blocked.localhost:${port}/from-app`], "com.apple.mail@apple");
        const blocks = await until("the block is recorded", async () => { const e = await events(instance, "block"); return e.length ? e : null; });
        await sleep(1500);
        assert.equal((await tabs(instance)).filter((t) => t.url?.includes("/from-app")).length, 0);
        assert.equal(seen("blocked.localhost", "/from-app").length, 0, "never requested");
        assert(!blocks.some((e) => e.detail.includes("from-app")), "the dropped URL isn't logged");
        return blocks;
      });
      out["a link from the chat app opens in the Work profile; other senders aren't routed"] = await check(async () => {
        await fromApp(instance, [`${local}/routed`], "com.example.chat@ABCDE12345");
        const routed = await tabAt(instance, `${local}/routed`);
        assert.equal(routed.profileId, "work");
        await instance.eval(`ac.store.getState().switchProfile?.("w1", "default"); return true`);
        await fromApp(instance, [`${local}/not-routed`], "com.apple.mail@apple");
        await fromApp(instance, [`${local}/no-sender`], null);
        const plain = await tabAt(instance, `${local}/not-routed`);
        const unknown = await tabAt(instance, `${local}/no-sender`);
        const routes = await events(instance, "openIn");
        assert.equal(routes.length, 1, "only the chat app's link was routed");
        return { routed, plain, unknown, routes };
      });
      out["an apps rule only drops links from that app"] = await check(async () => {
        const before = (await events(instance, "block")).length;
        await fromApp(instance, [`http://dropped.localhost:${port}/from-chat`], "com.example.chat@ABCDE12345");
        await until("dropped", async () => (await events(instance, "block")).length > before);
        await fromApp(instance, [`http://dropped.localhost:${port}/from-mail`], "com.apple.mail@apple");
        await tabAt(instance, `http://dropped.localhost:${port}/from-mail`);
        assert.equal(seen("dropped.localhost", "/from-chat").length, 0);
        return true;
      });
      out["another team under the chat app's name isn't routed by the pinned rule"] = await check(async () => {
        const before = (await events(instance, "openIn")).length;
        await fromApp(instance, [`${local}/impostor`], "com.example.chat@ZZZZZ99999");
        const landed = await tabAt(instance, `${local}/impostor`);
        assert.notEqual(landed.profileId, "work");
        assert.equal((await events(instance, "openIn")).length, before);
        return landed;
      });
      out["an app with no installed copy to check isn't routed, and Settings says why"] = await check(async () => {
        const before = (await events(instance, "openIn")).length;
        await fromApp(instance, [`${local}/uninstalled`], "com.example.uninstalled@ABCDE12345");
        const landed = await tabAt(instance, `${local}/uninstalled`);
        assert.notEqual(landed.profileId, "work");
        assert.equal((await events(instance, "openIn")).length, before);
        const s = await hooksState(instance, "status");
        assert(s.appProblems.some((p) => p.includes("com.example.uninstalled") && p.includes("no installed copy")), JSON.stringify(s.appProblems));
        assert.deepEqual(s.appTeams, []);
        return { landed, problems: s.appProblems };
      });
      out["a real Apple event from open -a reaches the hooks"] = await check(async () => {
        const before = (await events(instance, "block")).length;
        execFileSync("open", ["-g", "-a", app, `http://blocked.localhost:${port}/apple-event`]);
        await until("the block is recorded", async () => (await events(instance, "block")).length > before, 10000);
        await sleep(1000);
        assert.equal(seen("blocked.localhost", "/apple-event").length, 0);
        return (await events(instance, "block")).at(-1);
      });
    } finally {
      await stop(instance, "links", out);
    }
    return out;
  },

  async downloads() {
    const out = {};
    const filed = join(evidence, "downloads", "filed");
    rmSync(filed, { recursive: true, force: true });
    mkdirSync(filed, { recursive: true });
    const instance = await start("downloads", [{ name: "file-bins", match: { urls: [`http://127.0.0.1:${port}/dl*`] }, fileInto: filed }]);
    const download = async (path) => {
      await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}${path}`)}); return true`);
      return until(`${path} finishes`, async () => (await downloadsOf(instance)).filter((d) => d.filename?.includes(path.slice(1)) && d.state === "finished").at(-1), 15000);
    };
    try {
      if (!(await hooksState(instance, "status")).engine) {
        out["downloads saved in a folder (needs the engine's hooks)"] = { pass: true, skipped: "this engine has no ac_hooks_configure_v1" };
        return out;
      }
      out["an unapproved folder outside Downloads leaves the file in the default folder"] = await check(async () => {
        const d = await download("/dl-one");
        assert(existsSync(join(evidence, "downloads", "downloads", "hooks-dl-one.bin")), "in the download folder");
        assert.equal(readdirSync(filed).length, 0);
        return d;
      });
      out["once approved, Chrome saves matching downloads straight into the folder"] = await check(async () => {
        const approved = await approve(instance, "file-bins");
        assert.equal(approved.error ?? null, null);
        const row = await download("/dl-two");
        const saved = join(filed, "hooks-dl-two.bin");
        assert(existsSync(saved), "saved in the folder");
        assert(!existsSync(join(evidence, "downloads", "downloads", "hooks-dl-two.bin")));
        assert.equal(readFileSync(saved, "utf8"), "hooks download /dl-two");
        assert(row.path?.endsWith("/filed/hooks-dl-two.bin"), `row path ${row.path}`);
        return row;
      });
      out["a second file with the same name gets a unique name from Chrome"] = await check(async () => {
        await download("/dl-two");
        await until("the copy is saved", async () => readdirSync(filed).length === 2);
        return readdirSync(filed);
      });
      out["a folder swapped for a link after approval isn't used"] = await check(async () => {
        const elsewhere = join(evidence, "downloads", "elsewhere");
        mkdirSync(elsewhere, { recursive: true });
        execFileSync("mv", [filed, `${filed}-old`]);
        symlinkSync(elsewhere, filed);
        try {
          await download("/dl-three");
          assert(existsSync(join(evidence, "downloads", "downloads", "hooks-dl-three.bin")), "back in the default folder");
          assert.equal(readdirSync(elsewhere).length, 0);
          return await events(instance, "fileInto");
        } finally {
          rmSync(filed, { force: true });
          execFileSync("mv", [`${filed}-old`, filed]);
        }
      });
    } finally {
      await stop(instance, "downloads", out);
    }
    return out;
  },

  async commands() {
    const out = {};
    const output = join(evidence, "commands", "ran.txt");
    const program = join(evidence, "commands", "hook.sh");
    rmSync(output, { force: true });
    mkdirSync(join(evidence, "commands"), { recursive: true });
    writeFileSync(program, `#!/bin/sh\nenv > "$1.env"\nprintf "%s\\n" "$SOLARA_URL" >> "$1"\ncat > "$1.stdin"\n`, { mode: 0o700 });
    const rule = { name: "note-loads", on: ["page.loaded"], match: { hosts: ["cmd.localhost"] }, run: [program, output] };
    const instance = await start("commands", [rule]);
    const load = (path) => instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`http://cmd.localhost:${port}${path}`)}); return true`);
    try {
      out["an unapproved command doesn't run"] = await check(async () => {
        await load("/before?x=$(touch%20/tmp/hooks-pwned)");
        await until("the page loads", async () => seen("cmd.localhost", "/before").length > 0);
        await sleep(2500);
        assert(!existsSync(output), "nothing ran");
        assert.equal((await events(instance, "run")).length, 0);
        return true;
      });
      out["once approved it runs, with page data only in its environment and stdin"] = await check(async () => {
        const approved = await approve(instance, "note-loads");
        assert.equal(approved.error ?? null, null);
        await load("/after?x=$(touch%20/tmp/hooks-pwned)");
        const line = await until("the command writes", async () => existsSync(output) && readFileSync(output, "utf8").trim(), 10000);
        assert.equal(line, `http://cmd.localhost:${port}/after?x=$(touch%20/tmp/hooks-pwned)`);
        const env = await until("its environment", async () => existsSync(`${output}.env`) && readFileSync(`${output}.env`, "utf8"));
        for (const forbidden of ["SOLARA_DATA_DIR", "SOLARA_REMOTE_DEBUGGING_PORT", "SOLARA_CONFIG_DIR", "SOLARA_BACKGROUND", "DYLD_"])
          assert(!env.includes(forbidden), `${forbidden} leaked`);
        assert(env.includes("SOLARA_EVENT=page.loaded"));
        const stdin = JSON.parse(await until("its stdin", async () => existsSync(`${output}.stdin`) && readFileSync(`${output}.stdin`, "utf8")));
        assert.equal(stdin.event, "page.loaded");
        assert(!existsSync("/tmp/hooks-pwned"));
        return { line, stdin };
      });
      out["changing the program after approval stops it"] = await check(async () => {
        writeFileSync(program, `#!/bin/sh\necho changed >> "$1"\n`, { mode: 0o700 });
        rmSync(output, { force: true });
        await load("/after-program-change");
        await until("the page loads", async () => seen("cmd.localhost", "/after-program-change").length > 0);
        await sleep(2500);
        assert(!existsSync(output), "the changed program didn't run");
        const s = await hooksState(instance, "status");
        assert.match(s.rules[0].state, /changed since it was approved/);
        return s.rules[0].state;
      });
      out["editing the rule revokes its approval"] = await check(async () => {
        writeFileSync(program, `#!/bin/sh\nenv > "$1.env"\nprintf "%s\\n" "$SOLARA_URL" >> "$1"\ncat > "$1.stdin"\n`, { mode: 0o700 });
        writeHooks("commands", [{ ...rule, timeout: 20 }]);
        const s = await until("the edit loads", async () => { const s = await hooksState(instance, "status"); return s.rules[0]?.summary.includes("20 s") ? s : null; });
        assert.equal(s.rules[0].approved, false);
        assert.match(s.rules[0].state, /Changed since it was approved/);
        rmSync(output, { force: true });
        await load("/after-edit");
        await until("the page loads", async () => seen("cmd.localhost", "/after-edit").length > 0);
        await sleep(2500);
        assert(!existsSync(output), "the edited rule didn't run");
        return s.rules[0];
      });
    } finally {
      await stop(instance, "commands", out);
    }
    return out;
  },

  async reload() {
    const out = {};
    const instance = await start("reload", [{ name: "first", match: { hosts: ["one.localhost"] }, block: true }]);
    try {
      out["a saved edit reloads live"] = await check(async () => {
        writeHooks("reload", [{ name: "first", match: { hosts: ["one.localhost"] }, block: true }, { name: "second", match: { hosts: ["two.localhost"] }, block: true }]);
        const s = await until("two rules", async () => { const s = await hooksState(instance, "status"); return s.rules.length === 2 ? s : null; }, 5000);
        return s.rules.map((r) => r.name);
      });
      out["an invalid file keeps the last good rules and reports one error"] = await check(async () => {
        writeHooks("reload", `{"hooks": [{"name": "broken", "block": "yes"}]}`);
        const s = await until("the error", async () => { const s = await hooksState(instance, "status"); return s.error ? s : null; }, 5000);
        assert.equal(s.rules.length, 2);
        assert.match(s.error, /broken.*must be true/);
        const before = (await events(instance, "block")).length;
        await fromApp(instance, [`http://two.localhost:${port}/still-blocked`], null);
        await until("still blocked", async () => (await events(instance, "block")).length > before);
        return s.error;
      });
      out["a hooks.json other users can change is ignored"] = await check(async () => {
        writeHooks("reload", [{ name: "first", match: { hosts: ["one.localhost"] }, block: true }]);
        await until("one rule", async () => (await hooksState(instance, "status")).rules.length === 1, 5000);
        chmodSync(join(config("reload"), "hooks.json"), 0o666);
        const s = await until("refused", async () => { const s = await hooksState(instance, "status"); return s.error?.includes("other users") ? s : null; }, 5000);
        assert.equal(s.rules.length, 0);
        chmodSync(join(config("reload"), "hooks.json"), 0o644);
        await until("loads again", async () => (await hooksState(instance, "status")).rules.length === 1, 5000);
        return s.error;
      });
      out["removing hooks.json turns every hook off"] = await check(async () => {
        rmSync(join(config("reload"), "hooks.json"));
        const s = await until("no rules", async () => { const s = await hooksState(instance, "status"); return !s.present ? s : null; }, 5000);
        await fromApp(instance, [`http://one.localhost:${port}/opens-now`], null);
        await tabAt(instance, `http://one.localhost:${port}/opens-now`);
        return s;
      });
    } finally {
      await stop(instance, "reload", out);
    }
    return out;
  },

  async camera() {
    const out = {};
    const mediaDir = join(evidence, "camera", "media-app");
    const mediaApp = join(mediaDir, basename(app));
    rmSync(mediaDir, { recursive: true, force: true });
    mkdirSync(mediaDir, { recursive: true });
    execFileSync("cp", ["-cR", app, mediaApp]);
    const entitlements = join(mediaDir, "entitlements.plist");
    writeFileSync(entitlements, `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>`);
    execFileSync("codesign", ["-f", "-s", "-", "--options", "runtime", "--entitlements", entitlements, mediaApp], { stdio: "ignore" });
    const signed = execFileSync("codesign", ["-d", "--entitlements", "-", "--xml", mediaApp], { stdio: ["ignore", "pipe", "ignore"] }).toString();
    if (/device\.(camera|audio-input)/.test(signed)) throw new Error("the media copy kept a device entitlement");
    const instance = await start("camera", [{ name: "no-cam", match: { hosts: ["cam.localhost"] }, deny: ["camera"] }], { appPath: mediaApp });
    try {
      out["a camera request from a matching site is denied without a prompt"] = await check(async () => {
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`http://cam.localhost:${port}/cam`)}); return true`);
        const page = await instance.page((t) => t.url.startsWith(`http://cam.localhost:${port}/cam`), { timeout: 15000 });
        try {
          const answer = await page.eval(`window.ask()`, { userGesture: true });
          assert.equal(answer, "NotAllowedError");
        } finally {
          page.close();
        }
        const prompt = await instance.eval(`return ac.pageState.getState().pages["t1"]?.permission ?? null`);
        assert.equal(prompt, null, "no prompt was shown");
        const denied = await events(instance, "deny");
        assert.equal(denied.length, 1);
        assert.equal((await hooksState(instance, "status")).rules[0].needsApproval, false);
        return denied;
      });
    } finally {
      await stop(instance, "camera", out);
    }
    return out;
  },

  async pages() {
    const out = {};
    const instance = await start("pages", [
      { name: "no-blocked", match: { hosts: ["blocked.localhost"] }, block: true },
      { name: "strip", match: { urls: [`http://127.0.0.1:${port}/strip*`] }, rewrite: "{origin}{path}" },
      { name: "clean", match: { urls: [`http://127.0.0.1:${port}/clean*`] }, stripParams: ["utm_*"] },
      { name: "escape", match: { regex: `http://127\\.0\\.0\\.1:${port}/go/(.*)` }, rewrite: `http://127.0.0.1:${port}/landed?to={1}` },
      { name: "critical", match: { urls: [`http://127.0.0.1:${port}/cch-from*`] }, rewrite: "{origin}/cch" },
    ]);
    try {
      if (!(await hooksState(instance, "status")).engine) {
        out["in-page navigations (needs the engine's hooks)"] = { pass: true, skipped: "this engine has no ac_hooks_configure_v1" };
        return out;
      }
      out["the launch hold released on the real rules: no page loaded unchecked"] = await check(async () => {
        const s = await hooksState(instance, "status");
        assert.equal(s.lateLoads, 0);
        return { lateLoads: s.lateLoads };
      });
      await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}/links`)}); return true`);
      const click = async (id) => {
        const page = await instance.page((t) => t.url.startsWith(`${local}/links`), { timeout: 15000 });
        try {
          const rect = await page.eval(`(() => { const r = document.getElementById(${JSON.stringify(id)}).getBoundingClientRect(); return { x: r.left + 10, y: r.top + r.height / 2 }; })()`);
          for (const type of ["mousePressed", "mouseReleased"])
            await page.send("Input.dispatchMouseEvent", { type, x: rect.x, y: rect.y, button: "left", buttons: type === "mousePressed" ? 1 : 0, clickCount: 1 });
        } finally {
          page.close();
        }
      };
      const back = async () => {
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}/links`)}); return true`);
        await sleep(800);
      };
      const blocked = (path) => until("blocked", async () => (await events(instance, "block")).some((e) => e.detail.includes(path)));
      out["a link click to a blocked host isn't fetched"] = await check(async () => {
        await click("blocked");
        await blocked("/clicked");
        await sleep(800);
        assert.equal(seen("blocked.localhost", "/clicked").length, 0);
        await back();
        return true;
      });
      out["a redirect to a blocked host is stopped"] = await check(async () => {
        await back();
        await click("redirect");
        await blocked("/after-redirect");
        await sleep(800);
        assert.equal(seen("blocked.localhost", "/after-redirect").length, 0);
        return true;
      });
      out["a userinfo URL to a blocked host is still blocked"] = await check(async () => {
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`http://a@blocked.localhost:${port}/userinfo`)}); return true`);
        await blocked("/userinfo");
        await sleep(800);
        assert.equal(seen("blocked.localhost", "/userinfo").length, 0);
        return true;
      });
      out["a rewrite waits for approval, then applies before the original is fetched"] = await check(async () => {
        await back();
        await click("rewrite");
        await until("loaded unrewritten", async () => seen("127.0.0.1", "/strip").length > 0);
        assert.deepEqual(seen("127.0.0.1", "/strip").map((r) => r.query), ["?utm=1"]);
        const approved = await approve(instance, "strip");
        assert.equal(approved.error ?? null, null);
        await back();
        await click("rewrite");
        await until("rewritten", async () => (await tabs(instance)).some((t) => t.url === `${local}/strip`));
        await sleep(800);
        assert.deepEqual(seen("127.0.0.1", "/strip").map((r) => r.query), ["?utm=1", ""]);
        return true;
      });
      out["a target=_blank link to a blocked host isn't fetched"] = await check(async () => {
        await back();
        await click("blank");
        await blocked("/blank");
        await sleep(800);
        assert.equal(seen("blocked.localhost", "/blank").length, 0);
        return true;
      });
      out["stripParams needs no approval and keeps the rest of the query"] = await check(async () => {
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}/clean?utm_source=x&keep=1&utm_medium=y`)}); return true`);
        await until("cleaned", async () => (await tabs(instance)).some((t) => t.url === `${local}/clean?keep=1`));
        assert.deepEqual(seen("127.0.0.1", "/clean").map((r) => r.query), ["?keep=1"]);
        return true;
      });
      out["a page-chosen capture is encoded and can't pick the host"] = await check(async () => {
        await approve(instance, "escape");
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}/go/x@evil.example/?a=1#b`)}); return true`);
        await until("landed", async () => seen("127.0.0.1", "/landed").length > 0);
        assert.equal(seen("127.0.0.1", "/go/x@evil.example/").length, 0, "the original isn't fetched");
        assert.equal(seen("127.0.0.1", "/landed")[0].query, "?to=x%40evil.example%2F%3Fa%3D1%23b");
        return seen("127.0.0.1", "/landed")[0];
      });
      out["a frame from a blocked host isn't fetched"] = await check(async () => {
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}/frame`)}); return true`);
        await blocked("/in-frame");
        await sleep(800);
        assert.equal(seen("blocked.localhost", "/in-frame").length, 0);
        return true;
      });
      out["a Critical-CH restart never goes back to the address before the rewrite"] = await check(async () => {
        await approve(instance, "critical");
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`${local}/cch-from?fbclid=1`)}); return true`);
        await until("the target answered", async () => seen("127.0.0.1", "/cch").length > 0);
        await sleep(1500);
        assert.equal(seen("127.0.0.1", "/cch-from").length, 0, "the pre-rewrite address isn't fetched");
        return { cch: seen("127.0.0.1", "/cch").length, blocks: (await events(instance, "block")).length };
      });
      out["a typed address to a blocked host isn't fetched"] = await check(async () => {
        await instance.eval(`ac.store.getState().navigate("t1", ${JSON.stringify(`http://blocked.localhost:${port}/typed`)}); return true`);
        await blocked("/typed");
        await sleep(800);
        assert.equal(seen("blocked.localhost", "/typed").length, 0);
        return true;
      });
    } finally {
      await stop(instance, "pages", out);
    }
    return out;
  },
};

for (const [name, run] of Object.entries(groups)) {
  if (only.length && !only.includes(name)) continue;
  results[name] = await run().catch((error) => { failed = true; return { [`${name}: setup`]: { pass: false, error: String(error?.stack ?? error) } }; });
  for (const [label, r] of Object.entries(results[name])) console.log(`${r.pass ? "PASS" : "FAIL"} ${name}: ${label} ${r.ms ?? ""}${r.skipped ? ` (skipped: ${r.skipped})` : ""}${r.pass ? "" : `\n  ${r.error ?? JSON.stringify(r)}`}`);
}
writeFileSync(join(evidence, "results.json"), JSON.stringify({ requests, results }, null, 2));
console.log(`results: ${join(evidence, "results.json")}`);
server.close();
process.exit(failed ? 1 : 0);
