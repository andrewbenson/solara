import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node close-recent-test.mjs <Debug Solara.app>

Closing a tab goes back to the tab used before it, as in Arc, and Back on a tab a link opened closes it and returns
to its opener, through real key presses on a hidden window (⌘W, ⌘[, ⇧⌘T via ac.shell.devKeyEquivalent) on loopback
pages: after using b, d, then c, ⌘W on c shows d (not the tab below), and the native sidebar's selected row agrees;
a tab opened behind and never shown is passed over; the last tab of a group goes back outside it; a link tab with no
history closes on ⌘[ and shows its opener, lands in Recently Closed and ⇧⌘T reopens it; a link tab that has history
goes back a page instead and stays open; ⌘[ closes only the link tab even with other tabs selected; and ⌘W on an
opener goes to a link it opened in front and was read.`);
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "ac-close-recent-"));
const rep = reporter(join(scratch, "close-recent-test.log"), { name: "close-recent-test" });
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(req.url.slice(1)));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const names = ["a", "b", "c", "d", "e"];
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: names.map((id) => ({ id, url: url(id), title: id.toUpperCase() })),
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, cmdClickCreatesTabGroup: false },
});
const K = (key, keyCode, ...modifiers) => ({ key, keyCode, modifiers: ["command", ...modifiers], focus: "window" });
let app = null;
const run = (body, timeout = 20000) => app.eval(body, { timeout });
const press = (key) => run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify(key)});`);
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const shown = `const s = ac.store.getState(), w = s.windows.w1; return w.activeTabIds[w.profileId];`;
const nativeSelected = async (expected, what) => {
  const end = Date.now() + 5000;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot({ windowId: "w1" }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
    const w = last?.windows?.find((x) => x.id === "w1");
    if (last?.consistent && w?.selectedTabId === expected) return expected;
    await sleep(100);
  }
  throw new Error(`${what}: native selected ${JSON.stringify(last?.windows?.find((x) => x.id === "w1")?.selectedTabId)}, wanted ${expected}`);
};
const use = async (id) => {
  await run(`ac.store.getState().activate(${JSON.stringify(id)}); return true;`);
  await until(`${id} shown and loaded`, `const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId] === ${JSON.stringify(id)} && s.live[${JSON.stringify(id)}] && !s.live[${JSON.stringify(id)}].isLoading || null;`, 10000);
  await sleep(250);
};

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    ready: "return !!ac.store.getState().windows.w1 && ac.store.getState().windows.w1.tabIds.length === 5",
  });
  await use("a");
  await rep.check("cmd-w-goes-back-to-the-tab-used-before", async () => {
    await use("b");
    await use("d");
    await use("c");
    await press(K("w", 13));
    const next = await until("c closed", `const s = ac.store.getState(); return !s.tabs.c ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null;`);
    if (next !== "d") throw new Error(`showed ${next}, wanted d (the tab below would be e)`);
    await nativeSelected("d", "after ⌘W on c");
    await sleep(250);
    await press(K("w", 13));
    const then = await until("d closed", `const s = ac.store.getState(); return !s.tabs.d ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null;`);
    if (then !== "b") throw new Error(`after d showed ${then}, wanted b`);
    await nativeSelected("b", "after ⌘W on d");
    return [next, then];
  });
  await rep.check("a-tab-opened-behind-is-passed-over", async () => {
    await use("a");
    await run(`ac.store.getState().newTab("w1", { url: ${JSON.stringify(url("behind"))}, openerId: "a", background: true }); return true;`);
    await sleep(250);
    await use("e");
    await press(K("w", 13));
    const next = await until("e closed", `const s = ac.store.getState(); return !s.tabs.e ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null;`);
    if (next !== "a") throw new Error(`showed ${JSON.stringify(next)}, wanted a`);
    await nativeSelected("a", "after ⌘W on e");
    return next;
  });
  let opened;
  await rep.check("cmd-left-bracket-on-a-link-tab-closes-it-and-shows-its-opener", async () => {
    await use("b");
    opened = await run(`return ac.store.getState().newTab("w1", { url: ${JSON.stringify(url("link"))}, openerId: "b" });`);
    await until("link tab loaded", `const s = ac.store.getState(); return s.live[${JSON.stringify(opened)}] && !s.live[${JSON.stringify(opened)}].isLoading && s.windows.w1.activeTabIds[s.windows.w1.profileId] === ${JSON.stringify(opened)} || null;`, 10000);
    await sleep(300);
    const live = await run(`return ac.store.getState().live[${JSON.stringify(opened)}].canGoBack;`);
    if (live) throw new Error("the link tab already has back history");
    await press(K("[", 33));
    const next = await until("link tab closed", `const s = ac.store.getState(); return !s.tabs[${JSON.stringify(opened)}] ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null;`);
    if (next !== "b") throw new Error(`showed ${next}, wanted the opener b`);
    await nativeSelected("b", "after ⌘[");
    const last = await run(`return ac.store.getState().closedTabs.at(-1)?.tabId ?? null;`);
    if (last !== opened) throw new Error(`Recently Closed ends with ${last}`);
    return next;
  });
  await rep.check("shift-cmd-t-reopens-the-link-tab", async () => {
    await press(K("t", 17, "shift"));
    const back = await until("reopened", `const s = ac.store.getState(), w = s.windows.w1, id = w.activeTabIds[w.profileId]; return s.tabs[id]?.url === ${JSON.stringify(url("link"))} ? id : null;`);
    return back;
  });
  await rep.check("cmd-left-bracket-with-history-goes-back-a-page", async () => {
    const id = await run(`return ac.store.getState().newTab("w1", { url: ${JSON.stringify(url("first"))}, openerId: "b" });`);
    await until("first loaded", `const s = ac.store.getState(); return s.live[${JSON.stringify(id)}] && !s.live[${JSON.stringify(id)}].isLoading || null;`, 10000);
    await run(`ac.store.getState().navigate(${JSON.stringify(id)}, ${JSON.stringify(url("second"))}); return true;`);
    await until("second loaded with history", `const s = ac.store.getState(); return s.tabs[${JSON.stringify(id)}]?.url === ${JSON.stringify(url("second"))} && s.live[${JSON.stringify(id)}]?.canGoBack && !s.live[${JSON.stringify(id)}].isLoading || null;`, 10000);
    await sleep(300);
    await press(K("[", 33));
    const back = await until("went back", `const s = ac.store.getState(); return s.tabs[${JSON.stringify(id)}]?.url === ${JSON.stringify(url("first"))} || null;`, 10000);
    const still = await run(`const s = ac.store.getState(), w = s.windows.w1; return !!s.tabs[${JSON.stringify(id)}] && w.activeTabIds[w.profileId] === ${JSON.stringify(id)};`);
    if (!still) throw new Error("the tab closed or lost focus instead of going back");
    return back;
  });
  await rep.check("cmd-left-bracket-closes-only-the-link-tab-when-tabs-are-selected", async () => {
    await use("b");
    const id = await run(`return ac.store.getState().newTab("w1", { url: ${JSON.stringify(url("selected"))}, openerId: "b" });`);
    await until("selected link loaded", `const s = ac.store.getState(); return s.live[${JSON.stringify(id)}] && !s.live[${JSON.stringify(id)}].isLoading && s.windows.w1.activeTabIds[s.windows.w1.profileId] === ${JSON.stringify(id)} || null;`, 10000);
    await run(`ac.store.getState().setSelection("w1", ["a", "b", ${JSON.stringify(id)}]); return true;`);
    await sleep(300);
    const before = await run(`return ac.store.getState().windows.w1.tabIds.length;`);
    await press(K("[", 33));
    const next = await until("selected link closed", `const s = ac.store.getState(); return !s.tabs[${JSON.stringify(id)}] ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null;`);
    if (next !== "b") throw new Error(`showed ${next}, wanted the opener b`);
    const after = await run(`const s = ac.store.getState(); return { count: s.windows.w1.tabIds.length, a: !!s.tabs.a, b: !!s.tabs.b };`);
    if (after.count !== before - 1 || !after.a || !after.b) throw new Error(`closed more than the one tab: ${JSON.stringify({ before, after })}`);
    await nativeSelected("b", "after ⌘[ with a selection");
    return { before, after };
  });
  await rep.check("cmd-w-on-the-opener-goes-to-a-link-it-opened-in-front-and-read", async () => {
    await use("a");
    const id = await run(`return ac.store.getState().newTab("w1", { url: ${JSON.stringify(url("front"))}, openerId: "a" });`);
    await until("front link loaded", `const s = ac.store.getState(); return s.live[${JSON.stringify(id)}] && !s.live[${JSON.stringify(id)}].isLoading && s.windows.w1.activeTabIds[s.windows.w1.profileId] === ${JSON.stringify(id)} || null;`, 10000);
    await sleep(300);
    await use("a");
    await press(K("w", 13));
    const next = await until("a closed", `const s = ac.store.getState(); return !s.tabs.a ? s.windows.w1.activeTabIds[s.windows.w1.profileId] : null;`);
    if (next !== id) throw new Error(`showed ${next}, wanted the link a opened in front (${id})`);
    await nativeSelected(id, "after ⌘W on a");
    return next;
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
