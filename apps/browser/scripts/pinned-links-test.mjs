import assert from "node:assert/strict";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { isAlive, launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const app = process.argv[2];
if (!app || app === "--help") {
  console.error(`usage: METRO_PORT=<port> node apps/browser/scripts/pinned-links-test.mjs <Debug app> <evidence directory> [group…]

Links from pinned tabs and Top Apps to another site, end to end in hidden instances on local pages
(127.0.0.1 and localhost are different sites): a plain link click on a pinned tile or row opens a Peek and the
pinned page keeps its document; a normal tab's link and same-site links navigate in place; target=_blank and
noopener links peek; downloads, prevented clicks and script navigations keep Chrome's behaviour; Open as Tab keeps
the same page; closing a Peek records nothing; the New tab and Little Solara choices; closing the pinned tab or its
window while a Peek is open or a link is parked leaves no tab behind and no crash; with SOLARA_PEEK_STRICT a click
without a native mouse-up is not routed; a page with a beforeunload handler (observed: whether it asks before a link that
opens in a Peek). Groups: main, lifetimes, beforeunload, split, strict.`);
  process.exit(2);
}
const evidence = resolve(process.argv[3] ?? ".pinned-links-evidence");
const only = process.argv.slice(4);
mkdirSync(evidence, { recursive: true });

const requests = [];
const server = createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  requests.push({ host: url.hostname, path: url.pathname, at: Date.now() });
  response.setHeader("Cache-Control", "no-store");
  const html = (body) => { response.setHeader("Content-Type", "text/html; charset=utf-8"); response.end(`<!doctype html><meta charset=utf-8>${body}`); };
  if (url.pathname === "/src") {
    const other = `http://localhost:${port}`;
    const links = [
      ["out", `${other}/out`, ""],
      ["blank", `${other}/blank`, ` target="_blank"`],
      ["noopener", `${other}/noopener`, ` target="_blank" rel="noopener"`],
      ["same", `/same`, ""],
      ["dl", `${other}/dl`, ""],
      ["prevented", `${other}/prevented`, ` onclick="event.preventDefault()"`],
      ["nocontent", `${other}/nocontent`, ""],
      ["slow", `${other}/slow`, ""],
      ["slowblank", `${other}/slowblank`, ` target="_blank"`],
      ["peekdl", `${other}/peekdl`, ""],
      ["once", `${other}/once`, ""],
    ];
    return html(`<title>Source</title><body style="margin:0">${links.map(([id, href, extra]) =>
      `<a id="${id}" href="${href}"${extra} style="display:block;height:28px;font:16px sans-serif">${id}</a>`).join("")}
      <button id="script" style="display:block;height:28px" onclick="location.href='${other}/script'">script</button>
      <button id="arm" style="display:block;height:28px" onclick="window.onbeforeunload = (e) => { e.preventDefault(); e.returnValue = ''; }">arm</button>
      <input id="field" value="">`);
  }
  if (url.pathname === "/dl" || url.pathname === "/dl2") {
    response.setHeader("Content-Type", "application/octet-stream");
    response.setHeader("Content-Disposition", `attachment; filename="pinned-link-${url.pathname.slice(1)}.bin"`);
    return response.end("pinned link download");
  }
  if (url.pathname === "/nocontent") { response.statusCode = 204; return response.end(); }
  if (url.pathname === "/peekdl") return html(`<title>Peek download</title><a id="dl2" href="/dl2" style="display:block;height:40px">download</a>`);
  const hold = url.pathname.startsWith("/slow") ? 5000 : 0;
  setTimeout(() => html(`<title>Target ${url.pathname}</title><body>target ${url.pathname}`), hold);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const port = server.address().port;
const source = `http://127.0.0.1:${port}/src`;
const other = `http://localhost:${port}`;
const hits = (path) => requests.filter((r) => r.host === "localhost" && r.path === path).length;

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

const state = (instance) => instance.eval(`const s = ac.store.getState();
  return { windows: Object.fromEntries(Object.entries(s.windows).map(([id, w]) => [id, { kind: w.kind ?? null, tabIds: w.tabIds, active: w.activeTabIds[w.profileId] ?? null }])),
    tabs: Object.fromEntries(Object.entries(s.tabs).map(([id, t]) => [id, { url: t.url, windowId: t.windowId, pinned: !!t.pinned, openerId: t.openerId ?? null }])),
    peeks: s.peeks, closedTabs: s.closedTabs.length, downloads: s.downloads.map((d) => ({ filename: d.filename, state: d.state, path: d.path ?? null })) };`);
const pagesAt = async (instance, prefix) => (await instance.targets()).filter((t) => t.type === "page" && t.url.startsWith(prefix));

async function click(instance, id, { from = source } = {}) {
  const page = await instance.page(typeof from === "function" ? from : (t) => t.url.startsWith(from));
  try {
    const rect = await page.eval(`(() => { const r = document.getElementById(${JSON.stringify(id)}).getBoundingClientRect(); return { x: r.left + 10, y: r.top + r.height / 2 }; })()`);
    for (const type of ["mousePressed", "mouseReleased"])
      await page.send("Input.dispatchMouseEvent", { type, x: rect.x, y: rect.y, button: "left", buttons: type === "mousePressed" ? 1 : 0, clickCount: 1 });
    return page.target.id;
  } finally {
    page.close();
  }
}

async function sourceMark(instance, value) {
  const page = await instance.page((t) => t.url.startsWith(source));
  try {
    return await page.eval(value === undefined ? `({ mark: window.mark ?? null, field: document.getElementById("field").value, history: history.length })`
      : `(window.mark = ${JSON.stringify(value)}, document.getElementById("field").value = ${JSON.stringify(value)}, true)`);
  } finally {
    page.close();
  }
}

const peekOf = async (instance, path) => {
  const s = await state(instance);
  const peek = s.peeks?.w1;
  return peek && s.tabs[peek.tabId]?.url.startsWith(`${other}${path}`) ? { ...peek, s } : null;
};
const noPeek = async (instance) => !(await state(instance)).peeks?.w1;
const closePeek = async (instance) => {
  await instance.eval(`ac.store.getState().closePeek("w1"); return true;`);
  await until("the Peek closes", () => noPeek(instance));
};
const backToSource = async (instance, tabId = "pin") => {
  await instance.eval(`ac.store.getState().navigate(${JSON.stringify(tabId)}, ${JSON.stringify(source)}); return true;`);
  await until("the source page is back", async () => (await state(instance)).tabs[tabId].url === source && (await pagesAt(instance, source)).length > 0);
  await sleep(500);
};

async function peeks(instance, id, path) {
  await sourceMark(instance, `mark-${id}`);
  const targetBefore = (await pagesAt(instance, source))[0]?.id;
  const before = await state(instance);
  await click(instance, id);
  const hitsBefore = hits(path);
  const peek = await until(`${id} opens a Peek`, () => peekOf(instance, path));
  const after = await state(instance);
  const mark = await sourceMark(instance);
  assert.equal(after.tabs.pin.url, source, "the pinned tab stays on its page");
  assert.equal(mark.mark, `mark-${id}`, "the pinned page keeps its document (JS state)");
  assert.equal(mark.field, `mark-${id}`, "the pinned page keeps typed text");
  assert.equal((await pagesAt(instance, source))[0]?.id, targetBefore, "the pinned page is the same Chrome target");
  assert.deepEqual(after.windows.w1.tabIds, before.windows.w1.tabIds, "no tab joins the window");
  assert.equal(after.peeks.w1.sourceId, "pin");
  if (path !== "/nocontent") {
    await until(`${id}'s page loads in the Peek`, async () => (await pagesAt(instance, `${other}${path}`)).length > 0 && hits(path) > hitsBefore, 8000);
    await sleep(600);
  }
  const fetched = hits(path) - hitsBefore;
  assert.equal(fetched, 1, `the link is requested once (the Peek's load), not ${fetched} times`);
  return { peek: peek.tabId, requests: fetched, history: mark.history };
}

const groups = {
  async main() {
    const instance = await start("main");
    const out = {};
    try {
      out["plain link from a Top App opens a Peek"] = await check(() => peeks(instance, "out", "/out"));
      out["Open as Tab keeps the same page, after its source, active"] = await check(async () => {
        const peekTarget = (await pagesAt(instance, `${other}/out`))[0]?.id;
        const peekTab = (await state(instance)).peeks.w1.tabId;
        await instance.eval(`ac.store.getState().peekToTab("w1"); return true;`);
        const s = await until("the Peek becomes a tab", async () => { const s = await state(instance); return !s.peeks?.w1 && s.windows.w1.tabIds.includes(peekTab) ? s : null; });
        assert.equal((await pagesAt(instance, `${other}/out`))[0]?.id, peekTarget, "the same Chrome target");
        assert.equal(s.windows.w1.active, peekTab, "it comes to the front");
        assert.equal(s.tabs[peekTab].openerId, "pin");
        const at = s.windows.w1.tabIds.indexOf(peekTab);
        await instance.eval(`ac.store.getState().closeTab(${JSON.stringify(peekTab)}); ac.store.getState().activate("pin"); return true;`);
        await until("back on the pinned tab", async () => (await state(instance)).windows.w1.active === "pin");
        return { index: at, tabIds: s.windows.w1.tabIds };
      });
      out["closing a Peek throws its page away and records nothing"] = await check(async () => {
        await sleep(500);
        const r = await peeks(instance, "out", "/out");
        const closed = (await state(instance)).closedTabs;
        await closePeek(instance);
        await until("the Peek's page goes", async () => (await pagesAt(instance, `${other}/out`)).length === 0);
        assert.equal((await state(instance)).closedTabs, closed, "nothing in Recently Closed");
        return r;
      });
      out["target=_blank from a Top App opens a Peek, no tab"] = await check(async () => { const r = await peeks(instance, "blank", "/blank"); await closePeek(instance); return r; });
      out["noopener target=_blank opens a Peek, no tab"] = await check(async () => { const r = await peeks(instance, "noopener", "/noopener"); await closePeek(instance); return r; });
      out["a same-site link navigates the pinned tab in place"] = await check(async () => {
        await click(instance, "same");
        await until("the pinned tab navigates", async () => (await state(instance)).tabs.pin.url === `http://127.0.0.1:${port}/same`);
        assert(await noPeek(instance));
        await backToSource(instance);
        return true;
      });
      out["a single-use link is requested exactly once"] = await check(async () => {
        const r = await peeks(instance, "once", "/once");
        await sleep(1500);
        assert.equal(hits("/once"), 1, "the server saw the single-use link once");
        await closePeek(instance);
        return { ...r, total: hits("/once") };
      });
      out["a download link downloads, the Peek it opened in closes, the page stays"] = await check(async () => {
        await click(instance, "dl");
        const s = await until("the download reaches the store", async () => { const s = await state(instance); return s.downloads.some((d) => d.filename?.includes("pinned-link-dl")) ? s : null; });
        await until("no Peek is left", () => noPeek(instance), 8000);
        assert.equal((await state(instance)).tabs.pin.url, source);
        assert.equal(hits("/dl"), 1, "requested once");
        return { downloads: s.downloads };
      });
      out["a prevented click does nothing"] = await check(async () => {
        await click(instance, "prevented");
        await sleep(2500);
        const s = await state(instance);
        assert(!s.peeks?.w1, "no Peek");
        assert.equal(s.tabs.pin.url, source);
        assert.equal(hits("/prevented"), 0, "no request");
        return true;
      });
      out["a script navigation (not a link) navigates in place"] = await check(async () => {
        await click(instance, "script");
        await until("the pinned tab navigates", async () => (await state(instance)).tabs.pin.url === `${other}/script`);
        assert(await noPeek(instance));
        await backToSource(instance);
        return true;
      });
      out["a 204 link leaves no empty Peek and the pinned page stays"] = await check(async () => {
        await click(instance, "nocontent");
        await until("the request reaches the server", async () => hits("/nocontent") > 0, 8000);
        await until("no Peek is left", () => noPeek(instance), 8000);
        await sleep(1000);
        const s = await state(instance);
        assert(!s.peeks?.w1, "still no Peek");
        assert.equal(s.tabs.pin.url, source, "the pinned page stays");
        return { requests: hits("/nocontent") };
      });
      out["a slow page (5 s to respond) stays in its Peek and loads"] = await check(async () => {
        const r = await peeks(instance, "slow", "/slow");
        await sleep(1500);
        const s = await state(instance);
        assert(s.peeks?.w1, "the Peek is still open after its page loaded");
        await closePeek(instance);
        return r;
      });
      out["Stop before the first commit keeps the Peek"] = await check(async () => {
        await click(instance, "slow");
        const peek = await until("the slow link opens a Peek", () => peekOf(instance, "/slow"));
        await sleep(800);
        await instance.eval(`return ac.webviews.get(${JSON.stringify(peek.tabId)})?.stopLoading().then(() => true);`);
        await sleep(6500);
        assert((await state(instance)).peeks?.w1?.tabId === peek.tabId, "the Peek stays after Stop");
        await closePeek(instance);
        return true;
      });
      out["a download from inside a Peek downloads and the Peek stays"] = await check(async () => {
        await peeks(instance, "peekdl", "/peekdl");
        await until("the Peek's page loads", async () => (await pagesAt(instance, `${other}/peekdl`)).length > 0);
        await sleep(500);
        await click(instance, "dl2", { from: `${other}/peekdl` });
        const s = await until("the download reaches the store", async () => { const s = await state(instance); return s.downloads.some((d) => d.filename?.includes("pinned-link-dl2")) ? s : null; });
        await sleep(500);
        assert((await state(instance)).peeks?.w1, "the Peek stays open");
        await closePeek(instance);
        return { downloads: s.downloads.length };
      });
      out["a pinned row's link opens a Peek too"] = await check(async () => {
        await instance.eval(`ac.store.getState().activate("row"); return true;`);
        await until("the row is active and loaded", async () => (await state(instance)).windows.w1.active === "row" && (await pagesAt(instance, source)).length >= 1);
        await sleep(800);
        const page = await instance.page((t) => t.url.startsWith(source));
        page.close();
        await clickOn(instance, "row", "out");
        const peek = await until("the row's link peeks", async () => { const s = await state(instance); return s.peeks?.w1?.sourceId === "row" ? s.peeks.w1 : null; });
        await closePeek(instance);
        await instance.eval(`ac.store.getState().activate("pin"); return true;`);
        await until("back on the tile", async () => (await state(instance)).windows.w1.active === "pin");
        return peek;
      });
      out["a normal tab's link navigates in place, no Peek"] = await check(async () => {
        await instance.eval(`ac.store.getState().activate("plain"); return true;`);
        await until("the plain tab is active", async () => (await state(instance)).windows.w1.active === "plain");
        await sleep(1500);
        await clickOn(instance, "plain", "out");
        await until("the plain tab navigates", async () => (await state(instance)).tabs.plain.url === `${other}/out`);
        assert(await noPeek(instance));
        await instance.eval(`ac.store.getState().activate("pin"); return true;`);
        await until("back on the tile", async () => (await state(instance)).windows.w1.active === "pin");
        return true;
      });
      out["New tab choice: a foreground tab with the pinned tab as opener"] = await check(async () => {
        await instance.eval(`ac.store.getState().updateSettings({ pinnedLinkTarget: "tab" }); return true;`);
        await sleep(500);
        const before = await state(instance);
        await click(instance, "out");
        const s = await until("a new tab opens", async () => { const s = await state(instance); return s.windows.w1.tabIds.length === before.windows.w1.tabIds.length + 1 ? s : null; });
        const added = s.windows.w1.tabIds.find((id) => !before.windows.w1.tabIds.includes(id));
        assert.equal(s.tabs[added].openerId, "pin");
        assert.equal(s.windows.w1.active, added);
        assert(!s.peeks?.w1);
        assert.equal(s.tabs.pin.url, source);
        await instance.eval(`ac.store.getState().closeTab(${JSON.stringify(added)}); ac.store.getState().activate("pin"); return true;`);
        await until("back on the tile", async () => (await state(instance)).windows.w1.active === "pin");
        return { added, url: s.tabs[added].url };
      });
      out["Little Solara choice: a small window with the link"] = await check(async () => {
        await instance.eval(`ac.store.getState().updateSettings({ pinnedLinkTarget: "littleSolara" }); return true;`);
        await sleep(800);
        await click(instance, "out");
        const s = await until("a Little Solara window opens", async () => { const s = await state(instance); return Object.values(s.windows).some((w) => w.kind === "small") ? s : null; });
        const [id, w] = Object.entries(s.windows).find(([, w]) => w.kind === "small");
        const url = s.tabs[w.tabIds[0]]?.url;
        assert(url?.startsWith(`${other}/out`), `small window shows ${url}`);
        assert.equal(s.tabs.pin.url, source);
        await instance.eval(`ac.store.getState().closeWindow(${JSON.stringify(id)}); ac.store.getState().updateSettings({ pinnedLinkTarget: "peek" }); return true;`);
        return { url };
      });
      out["no crash and a clean page list at the end"] = await check(async () => {
        assert(isAlive(instance.pid));
        return { pages: (await instance.targets()).filter((t) => t.type === "page").map((t) => t.url) };
      });
    } finally {
      await stop(instance, "main", out);
    }
    return out;
  },

  async lifetimes() {
    const out = {};
    const cases = {
      "closing the pinned tab with a Peek open": async (instance) => {
        await peeks(instance, "out", "/out");
        await instance.eval(`ac.store.getState().closeTab("pin"); return true;`);
        await until("the Peek and its page go", async () => (await noPeek(instance)) && (await pagesAt(instance, `${other}/out`)).length === 0);
      },
      "closing the window with a Peek open": async (instance) => {
        await peeks(instance, "out", "/out");
        await instance.eval(`ac.store.getState().closeWindow("w1"); return true;`);
        await until("the window goes", async () => !(await state(instance)).windows.w1);
        await sleep(1500);
        assert.equal((await pagesAt(instance, `${other}/out`)).length, 0, "no page left for the Peek");
      },
      "closing the pinned tab while its Peek is still waiting on the response": async (instance) => {
        await click(instance, "slow");
        await until("the request reaches the server", async () => hits("/slow") > 0, 5000);
        await instance.eval(`ac.store.getState().closeTab("pin"); return true;`);
        await sleep(7000);
        const s = await state(instance);
        assert(!s.peeks?.w1, "no Peek");
        assert(!Object.values(s.tabs).some((t) => t.url.startsWith(`${other}/slow`)), "no tab for the link");
        assert.equal((await pagesAt(instance, `${other}/slow`)).length, 0, "no page for the link");
      },
      "closing the window while a target=_blank link's Peek is still waiting on the response": async (instance) => {
        await click(instance, "slowblank");
        await until("the request reaches the server", async () => hits("/slowblank") > 0, 5000);
        await instance.eval(`ac.store.getState().closeWindow("w1"); return true;`);
        await until("the window goes", async () => !(await state(instance)).windows.w1);
        await sleep(12000);
        const s = await state(instance);
        assert(!Object.values(s.tabs).some((t) => t.url.startsWith(`${other}/slowblank`)), "no tab adopts the parked link");
        assert.equal((await pagesAt(instance, `${other}/slowblank`)).length, 0, "no page left for the parked link");
      },
      "closing the pinned tab while a target=_blank link's Peek is still waiting on the response": async (instance) => {
        await click(instance, "slowblank");
        await until("the request reaches the server", async () => hits("/slowblank") > 0, 5000);
        await instance.eval(`ac.store.getState().closeTab("pin"); return true;`);
        await sleep(12000);
        const s = await state(instance);
        assert(!s.peeks?.w1, "no Peek");
        assert(!Object.values(s.tabs).some((t) => t.url.startsWith(`${other}/slowblank`)), "no tab adopts the parked link");
        assert.equal((await pagesAt(instance, `${other}/slowblank`)).length, 0, "no page left for the parked link");
      },
    };
    for (const [name, run] of Object.entries(cases)) {
      const key = `lifetimes-${Object.keys(out).length + 1}`;
      const instance = await start(key);
      try {
        out[name] = await check(async () => { requests.length = 0; await run(instance); assert(isAlive(instance.pid), "the app is alive"); return true; });
      } finally {
        await stop(instance, key, out, name);
      }
    }
    return out;
  },

  async beforeunload() {
    const instance = await start("beforeunload");
    const out = {};
    try {
      const page = await instance.page((t) => t.url.startsWith(source));
      const dialogs = [];
      page.on("Page.javascriptDialogOpening", (d) => dialogs.push(d));
      await page.send("Page.enable");
      const tap = async (id) => {
        const rect = await page.eval(`(() => { const r = document.getElementById(${JSON.stringify(id)}).getBoundingClientRect(); return { x: r.left + 10, y: r.top + r.height / 2 }; })()`);
        await page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: rect.x, y: rect.y, button: "left", buttons: 1, clickCount: 1 });
        const released = page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: rect.x, y: rect.y, button: "left", buttons: 0, clickCount: 1 }, { timeout: 15000 });
        await Promise.race([released, until("a dialog", async () => dialogs.length > 0, 3000).catch(() => null)]);
        released.catch(() => {});
      };
      for (const answer of [false, true]) {
        out[`a pinned page with beforeunload, link to another site, ${answer ? "Leave" : "Stay"} if asked (observed)`] = await check(async () => {
          dialogs.length = 0;
          await tap("arm");
          await sleep(300);
          await tap("out");
          const asked = await until("a dialog or a Peek", async () => dialogs.length > 0 || !(await noPeek(instance)), 6000).catch(() => false);
          const dialog = dialogs[0] ?? null;
          if (dialog) await page.send("Page.handleJavaScriptDialog", { accept: answer }).catch(() => {});
          await sleep(2500);
          const s = await state(instance);
          const observed = { asked: !!asked, dialog: dialog ? dialog.type : null, peek: !!s.peeks?.w1, pinUrl: s.tabs.pin.url, requests: hits("/out") };
          assert.equal(s.tabs.pin.url, source, "the pinned page stays");
          if (s.peeks?.w1) await closePeek(instance);
          await page.eval("window.onbeforeunload = null; true").catch(() => {});
          return observed;
        });
      }
      page.close();
    } finally {
      await stop(instance, "beforeunload", out);
    }
    return out;
  },

  async split() {
    const instance = await start("split", {}, {
      splits: [{ id: "sp", windowId: "w1", tabIds: ["pin", "plain"], orientation: "horizontal", sizes: [0.5, 0.5] }],
      activeTabIds: { default: "plain" },
    });
    const out = {};
    try {
      out["a pinned tab's link peeks from the split pane that isn't the active one"] = await check(async () => {
        const s0 = await state(instance);
        const inSplit = await instance.eval(`return Object.values(ac.store.getState().splits).map((v) => v.tabIds);`);
        if (!JSON.stringify(inSplit).includes("pin")) return { skipped: `the session's split didn't hold the pinned tab: ${JSON.stringify(inSplit)}` };
        assert.equal(s0.windows.w1.active, "plain", "the other pane is active");
        await until("both panes' pages are up", async () => (await pagesAt(instance, source)).length >= 2, 15000);
        await click(instance, "out", { from: (t) => t.url === source });
        const peek = await until("the pinned pane's link opens a Peek", async () => { const s = await state(instance); return s.peeks?.w1?.sourceId === "pin" ? s.peeks.w1 : null; });
        assert.equal((await state(instance)).tabs.pin.url, source);
        return { peek, split: inSplit };
      });
    } finally {
      await stop(instance, "split", out);
    }
    return out;
  },

  async strict() {
    const instance = await start("strict", { SOLARA_PEEK_STRICT: "1" });
    const out = {};
    try {
      out["without a native mouse-up the link isn't routed (strict gate)"] = await check(async () => {
        await click(instance, "out");
        await until("the pinned tab navigates in place", async () => (await state(instance)).tabs.pin.url === `${other}/out`);
        assert(await noPeek(instance));
        await backToSource(instance);
        return true;
      });
      out["with a plain native mouse-up over the page the link peeks"] = await check(async () => {
        const posted = await instance.eval(`const m = globalThis.expo?.modules?.SolaraCEF; if (!m?.devPostPeekMouseUp) return "no hook"; return m.devPostPeekMouseUp("", "pin");`);
        if (posted !== true) return { skipped: `devPostPeekMouseUp: ${posted}` };
        await sleep(300);
        return await peeks(instance, "out", "/out");
      });
      out["a mouse-up with ⌘ doesn't route"] = await check(async () => {
        if (!(await state(instance)).peeks?.w1) return { skipped: "previous step skipped" };
        await closePeek(instance);
        const posted = await instance.eval(`return globalThis.expo.modules.SolaraCEF.devPostPeekMouseUp("⌘", "pin");`);
        assert.equal(posted, true);
        await sleep(300);
        await click(instance, "out");
        await until("the pinned tab navigates in place", async () => (await state(instance)).tabs.pin.url === `${other}/out`);
        assert(await noPeek(instance));
        return true;
      });
    } finally {
      await stop(instance, "strict", out);
    }
    return out;
  },
};

async function clickOn(instance, tabId, id) {
  const visible = await instance.eval(`return ac.store.getState().windows.w1.activeTabIds[ac.store.getState().windows.w1.profileId];`);
  assert.equal(visible, tabId);
  return click(instance, id);
}

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

async function start(name, env = {}, layout = {}) {
  const downloads = join(evidence, name, "downloads");
  mkdirSync(downloads, { recursive: true });
  const instance = await launch(app, {
    data: join(evidence, name, "data"),
    env: { SOLARA_DOWNLOADS_DIR: downloads, ...env },
    session: session({
      windows: [{ id: "w1", frame: [80, 80, 1100, 760], activeTabIds: layout.activeTabIds ?? { default: "pin" } }],
      tabs: [
        { id: "pin", windowId: "w1", url: source, title: "Source", pinned: true },
        { id: "row", windowId: "w1", url: layout.splits ? `${source}?row` : source, title: "Source row", pinned: true, pinnedAsRow: true },
        { id: "plain", windowId: "w1", url: layout.splits ? `${source}?plain` : source, title: "Source plain" },
      ],
      settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeQuitting: false },
      ...(layout.splits ? { splits: layout.splits } : {}),
    }),
  });
  await instance.ready();
  await instance.page((t) => t.url.startsWith(source), { timeout: 20000 }).then((p) => p.close());
  await sleep(1000);
  return instance;
}

async function stop(instance, name, out, label = null) {
  const alive = isAlive(instance.pid);
  const quit = await instance.quit().catch((e) => ({ error: String(e) }));
  const crash = existsSync(join(evidence, name, "data", "crash.log"));
  const errors = (() => { try { return instance.jsErrors(); } catch { return null; } })();
  const key = label ? `${label}: quit` : `${name}: quit`;
  out[key] = { pass: alive && !crash, aliveBeforeQuit: alive, quit: quit?.how ?? quit, crash, jsErrors: errors?.length ?? errors };
  if (!out[key].pass) failed = true;
}

for (const [name, run] of Object.entries(groups)) {
  if (only.length && !only.includes(name)) continue;
  results[name] = await run();
  for (const [check, r] of Object.entries(results[name])) console.log(`${r.pass ? "PASS" : "FAIL"} ${name}: ${check} ${r.ms ?? ""}${r.pass ? "" : `\n  ${r.error ?? JSON.stringify(r)}`}`);
}
writeFileSync(join(evidence, "results.json"), JSON.stringify({ requests, results }, null, 2));
console.log(`results: ${join(evidence, "results.json")}`);
server.close();
process.exit(failed ? 1 : 0);
