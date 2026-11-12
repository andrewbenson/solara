import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const app = process.argv[2];
if (!app) throw new Error("usage: node unread-badges-test.mjs <Debug app> <evidence directory>");
const evidence = resolve(process.argv[3] ?? ".unread-evidence");
mkdirSync(evidence, { recursive: true });
const fixturePath = resolve(import.meta.dirname, "../../..", "native/SolaraKit/Tests/SolaraUITests/UnreadFixtures");
const records = [];
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  response.setHeader("Cache-Control", "no-store");
  if (url.pathname.endsWith(".png")) {
    response.setHeader("Content-Type", "image/png");
    response.end(readFileSync(join(fixturePath, url.pathname.includes("dot") ? "red-top-right.png" : "plain.png")));
    return;
  }
  const title = url.searchParams.get("title") ?? "Fixture";
  const icon = url.searchParams.get("icon") ?? "plain";
  const api = url.searchParams.has("api");
  response.setHeader("Content-Type", "text/html; charset=utf-8");
  response.end(`<!doctype html><title>${title.replaceAll("&", "&amp;").replaceAll("<", "&lt;")}</title><link rel="icon" href="/${icon}.png"><body>Unread fixture<script>window.badgeResult = "not requested"; ${api ? 'Promise.resolve().then(() => navigator.setAppBadge(7)).then(() => window.badgeResult = "resolved", e => window.badgeResult = String(e));' : ""}</script>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;
const pageURL = (id, title, icon = "plain", api = false) => `${origin}/${id}?${new URLSearchParams({ title, icon, ...(api ? { api: "1" } : {}) })}`;
const tabs = [
  { id: "idle", url: "about:blank", title: "Control" },
  { id: "pin", url: pageURL("pin", "(3) Inbox"), pinned: true, pinnedAsRow: true },
  { id: "top", url: pageURL("top", "Inbox (12)"), pinned: true },
  { id: "row", url: pageURL("row", "(123) Inbox") },
  { id: "year", url: pageURL("year", "(2024) Annual report") },
  { id: "dot", url: pageURL("dot", "Messages", "dot") },
  { id: "plain", url: pageURL("plain", "Messages") },
  { id: "api", url: pageURL("api", "(5) API wins", "plain", true) },
];
let instance;
const run = (body) => instance.eval(body, { timeout: 8000 });
const snapshot = async (name) => {
  const result = await instance.snapshot({ windowId: "w1", hoverArea: "sidebar", pages: true });
  if (name) writeFileSync(join(evidence, `${name}.json`), JSON.stringify(result, null, 2));
  return result;
};
const badges = (value) => value.windows.find((w) => w.id === "w1").hoverLayout.unreadBadges;
const assertTileCorners = (value) => {
  const layout = value.windows.find((w) => w.id === "w1").hoverLayout;
  for (const badge of layout.unreadBadges.filter((b) => b.visible && b.key.startsWith("tile:"))) {
    const tile = layout.frames.find((f) => f.id === badge.key).frame;
    assert.equal(badge.frame[1] - tile[1], 3, `${badge.key} top inset`);
    assert.equal(tile[0] + tile[2] - badge.frame[0] - badge.frame[2], 3, `${badge.key} trailing inset`);
  }
};
const until = async (name, probe, ms = 10000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await probe();
    if (last) return last;
    await sleep(100);
  }
  throw new Error(`${name} timed out: ${JSON.stringify(last)}`);
};
const capture = async (name) => assert.equal(await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(join(evidence, name + ".png"))});`), true);
try {
  instance = await launch(app, { data: join(evidence, "data"), session: session({ windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "idle" } }], tabs, settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, sidebarWidth: 270, showUnreadBadges: true } }), metroPort: Number(process.env.METRO_PORT ?? 8081), probe: true, onboarded: true, env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "0" }, ready: "return !!ac.store" });
  records.push({ instance: { pid: instance.pid, port: instance.port } });
  for (const tab of tabs.slice(1)) {
    await run(`ac.store.getState().activate(${JSON.stringify(tab.id)}); return true;`);
    await until(`${tab.id} title`, async () => {
      const s = await snapshot();
      return s.tabs.find((t) => t.id === tab.id)?.title === new URL(tab.url).searchParams.get("title");
    });
  }
  await run('ac.store.getState().activate("idle"); return true;');
  const all = await until("title and favicon badges", async () => {
    const s = await snapshot();
    const shown = badges(s).filter((b) => b.visible);
    return shown.some((b) => b.key === "t:pin" && b.text === "3") && shown.some((b) => b.key === "tile:top" && b.text === "12") && shown.some((b) => b.key === "t:row" && b.text === "99+") && shown.some((b) => b.key === "t:dot" && b.status === "Unread activity") && shown.some((b) => b.key === "t:api" && b.text === "7") ? s : null;
  });
  assertTileCorners(all);
  const shown = badges(all).filter((b) => b.visible);
  assert(!shown.some((b) => /year|plain/.test(b.key)));
  assert(shown.some((b) => b.key === "t:api" && b.text === "7"));
  records.push({ check: "pin 3, Top App 12, row 99+, favicon dot, year/plain clear, page badge over title", badges: shown });
  await snapshot("all-badges");
  await capture("all-badges");
  await run('ac.store.getState().pinTabs(["pin"], true, false); return true;');
  await until("pinned tile badge", async () => badges(await snapshot()).some((b) => b.key === "tile:pin" && b.visible && b.text === "3"));
  assertTileCorners(await snapshot("pinned-tile"));
  await capture("pinned-tile");
  records.push({ check: "pinned tab keeps its badge when moved to a Top Apps tile", pass: true });
  const api = await instance.page("/api?");
  const apiResult = await until("real navigator.setAppBadge resolves", async () => {
    const value = await api.eval("({ available: typeof navigator.setAppBadge, result: window.badgeResult })");
    assert.equal(value.available, "function");
    return value.result === "resolved" ? value : null;
  });
  records.push({ check: "real navigator.setAppBadge call", result: apiResult });
  api.close();
  for (const [id, key] of [["pin", "tile:pin"], ["top", "tile:top"], ["dot", "t:dot"]]) {
    await run(`ac.store.getState().activate(${JSON.stringify(id)}); return true;`);
    await until(`${id} active badge hidden`, async () => !badges(await snapshot()).some((b) => b.key === key && b.visible));
    await run('ac.store.getState().activate("idle"); return true;');
    await until(`${id} badge restored`, async () => badges(await snapshot()).some((b) => b.key === key && b.visible));
  }
  await run('ac.store.getState().activate("row"); return true;');
  await until("active badge hidden", async () => !badges(await snapshot()).some((b) => b.key === "t:row" && b.visible));
  await snapshot("active-hidden");
  await capture("active-hidden");
  await run('ac.store.getState().activate("idle"); return true;');
  await until("badge returns after switching", async () => badges(await snapshot()).some((b) => b.key === "t:row" && b.visible));
  records.push({ check: "active tab hides presentation and preserves signal", pass: true });
  await run('ac.store.getState().updateSettings({ showUnreadBadges: false }); return true;');
  await until("setting hides every badge", async () => !badges(await snapshot()).some((b) => b.visible));
  await snapshot("setting-off");
  await capture("setting-off");
  await run('ac.store.getState().updateSettings({ showUnreadBadges: true }); return true;');
  await until("setting restores favicon", async () => badges(await snapshot()).some((b) => b.key === "t:dot" && b.visible));
  records.push({ check: "setting hides all and restores title/favicon", pass: true });
  const stats = () => run("return globalThis.expo.modules.SolaraHosted.devUnreadBadgeStats();");
  const before = await stats();
  await sleep(700);
  const after = await stats();
  assert.equal(after.mainThreadAnalyses, 0);
  assert(after.cacheHits > 0);
  assert.deepEqual(after, before);
  records.push({ check: "background analysis, cache hit and no idle work", before, after });
  await snapshot("final");
  console.log(JSON.stringify(records, null, 2));
  writeFileSync(join(evidence, "checks.json"), JSON.stringify(records, null, 2));
} catch (error) {
  if (instance) {
    await snapshot("failure").catch(() => {});
    await capture("failure").catch(() => {});
  }
  throw error;
} finally {
  if (instance) await instance.quit();
  await new Promise((done) => server.close(done));
}
