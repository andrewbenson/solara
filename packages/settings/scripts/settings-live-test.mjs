#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, realpathSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg, mode = "both"] = process.argv.slice(2);
assert.ok(appArg && scratchArg && ["folders", "drive", "both"].includes(mode), "usage: node settings-live-test.mjs <Debug app> <scratch> [folders|drive|both]");
const appPath = realpathSync(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"));
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");

const root = resolve(scratchArg);
mkdirSync(root, { recursive: true });
const scratch = mkdtempSync(join(root, "settings-live-"));
const rep = reporter(join(scratch, "settings-live.log"), { name: "settings-live" });
const reply = (res, body, status = 200) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const client = "mockclient";
const secret = "mocksecret";
let challenge;
let exchanges = 0;
const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  switch (url.pathname) {
    case "/google/auth": {
      const query = url.searchParams;
      if (query.get("client_id") !== client || query.get("code_challenge_method") !== "S256") return reply(res, {}, 400);
      challenge = query.get("code_challenge");
      const redirect = new URL(query.get("redirect_uri"));
      redirect.searchParams.set("code", "mock-code");
      redirect.searchParams.set("state", query.get("state"));
      res.writeHead(302, { location: redirect.href }).end();
      break;
    }
    case "/google/token": {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const form = new URLSearchParams(raw);
      const proof = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
      if (form.get("client_id") !== client || form.get("client_secret") !== secret || form.get("code") !== "mock-code" || !challenge || proof !== challenge)
        return reply(res, { error: "invalid_client" }, 400);
      exchanges += 1;
      reply(res, { access_token: "mock-access", refresh_token: "mock-refresh", expires_in: 3600 });
      break;
    }
    case "/google/drive/v3/about":
      reply(res, { user: { emailAddress: "fixture@example.test", displayName: "Fixture" } });
      break;
    case "/google/drive/v3/files":
      reply(res, { files: [] });
      break;
    default:
      res.writeHead(200, { "content-type": "text/html" }).end("<title>Local fixture</title>");
  }
});
const redirect = createServer((_, res) => res.writeHead(200, { "content-type": "text/plain" }).end("Sign-in finished"));
const listen = (server, port) => new Promise((yes, no) => {
  server.once("error", no);
  server.listen(port, "127.0.0.1", yes);
});
const q = JSON.stringify;
let app;
async function until(label, predicate) {
  const deadline = Date.now() + 8000;
  do {
    const value = await predicate();
    if (value) return value;
    await sleep(100);
  } while (Date.now() < deadline);
  throw new Error(label);
}
try {
  await listen(server, 0);
  if (mode !== "folders") await listen(redirect, 53682);
  const base = `http://127.0.0.1:${server.address().port}`;
  app = await launch(appPath, {
    data: join(scratch, "data"), onboarded: true, probe: true,
    env: { SOLARA_LIVE_MOCK: base },
  });
  const native = () => app.eval("return ac.native.state()");
  const live = () => app.probe("live.snapshot");
  const control = (key, value) => until(`Settings control unavailable: ${key}`, () => app.eval(
    `return globalThis.expo.modules.SolaraSettings.devSettings("liveControl", ${q(value === undefined ? key : `${key} ${value}`)}).then(x => JSON.parse(x).accepted)`
  ));
  const initial = await until("native workspace unavailable", native);

  if (mode !== "drive") await rep.check("Settings Delete closes Live items and reconciles their open group", async () => {
    const windowId = initial.windowOrder[0];
    const profileId = initial.windows[windowId].profileId;
    const { folderId } = await app.probe("live.fixture", {
      seed: {
        profileId, kind: "documents", sources: [], collapsed: true,
        items: [{ id: "fixture", source: "notion", url: base + "/live-item", title: "Fixture", subtitle: "", updatedAt: Date.now() }],
      },
    });
    await until("fixture Live folder did not collapse", async () => (await live()).folders.some((f) => f.id === folderId && f.collapsed));
    const { tabId: first } = await app.probe("live.fixture", {
      open: { windowId, folderId, itemId: "fixture", background: false },
    });
    const fixture = await app.eval(`
      const s = ac.store.getState();
      const first = ${q(first)};
      const keep = s.newTab(${q(windowId)}, {url: ${q(base + "/keep")}});
      const group = s.groupTabs([first, keep], {pinned: false, name: "Live group"});
      return {folderId: ${q(folderId)}, first, keep, group};
    `);
    await until("fixture group was not committed", async () => {
      const state = await native();
      const group = state.groups[fixture.group];
      return state.tabs[fixture.first]?.liveItem?.folderId === fixture.folderId && group?.tabIds.length === 2 && group.collapsed === false;
    });
    await app.eval('ac.openSettings("liveFolders"); return true');
    await control(`live.delete.${fixture.folderId}`);
    await until("folder, tab and group did not settle", async () => {
      const state = await native();
      const liveState = await live();
      return !liveState.folders.some(({ id }) => id === fixture.folderId) &&
        !state.tabs[fixture.first] && state.tabs[fixture.keep] && state.groups[fixture.group]?.tabIds.join() === fixture.keep;
    });
  });

  if (mode !== "folders") await rep.check("Settings Drive sign-in exchanges the redirect once and closes its tab", async () => {
    await app.eval('ac.openSettings("liveFolders"); return true');
    const before = await native();
    await control("live.connect.gdrive");
    await control("live.google.client", client);
    await control("live.google.secret", secret);
    await control("live.google.submit");
    await until("Drive did not connect", async () => (await live()).connectedSources.includes("gdrive"));
    const after = await native();
    assert.equal(exchanges, 1);
    assert.deepEqual(after.windowOrder, before.windowOrder);
    assert.deepEqual(Object.keys(after.tabs).sort(), Object.keys(before.tabs).sort());
  });
} finally {
  try {
    await app?.quit();
  } finally {
    server.closeAllConnections();
    redirect.closeAllConnections();
    server.close();
    redirect.close();
    if (!rep.summary()) process.exitCode = 1;
  }
}
