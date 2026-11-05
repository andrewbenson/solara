import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { cpSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devtools, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node side-panel-test.mjs <Debug Solara.app> [--keep-data] [--legs native,pool]

An extension's side panel, a native card, with the page pool off and on. In each leg a fixture MV3 extension with a
side_panel opens its panel in window w1 and the test checks: the native card matches the measured card and the panel
page gets its size; a drag on the grip resizes it and the width is saved; a
double-click on the grip resets it to 360; the page's window.close() closes it and reopening it at once loads a new page; its window.open() opens a tab; the ✕
closes it. Focus: with the panel page focused, closing it by the ✕, by the toolbar toggle and by replacing it with
another extension's panel leaves page A focused. Lifetime: twelve open and close cycles leave no panel page alive
(DevTools targets) and no more renderer processes than before; a replaced panel, a JS reload, a closed window and a
turned-off extension each leave at most the one panel page that should be there, and no live SolaraCoreWebView with
extensionHost "sidePanel" once closed (C.devLiveExtensionViews).`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const legsArg = args.includes("--legs") ? args[args.indexOf("--legs") + 1] : null;
const scratch = mkdtempSync(join(tmpdir(), "ac-side-panel-"));
const rep = reporter(join(scratch, "side-panel-test.log"), { name: "side-panel-test" });

const fixtureExt = resolve(dirname(fileURLToPath(import.meta.url)), "../../../packages/solaracore/scripts/fixtures/ext");
const extA = join(scratch, "ext-a");
const extB = join(scratch, "ext-b");
const extC = join(scratch, "ext-c");
for (const [dir, name] of [[extA, "Side panel A"], [extB, "Side panel B"], [extC, "Side panel C"]]) {
  cpSync(fixtureExt, dir, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.name = name;
  delete manifest.content_scripts;
  delete manifest.declarative_net_request;
  manifest.permissions = ["sidePanel"];
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  writeFileSync(join(dir, "panel.html"), `<!doctype html><meta charset="utf-8"><title>${name}</title><body style="margin:0"><input id="field" style="width:100%">${name}</body>`);
}

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  const name = req.url.slice(1) || "a";
  res.end(fixturePage(name, { bodyPrefix: '<input id="field">' }));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [
    { id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } },
    { id: "w2", frame: [140, 140, 1000, 700], activeTabIds: { default: "b" } },
  ],
  tabs: [{ id: "a", url: `${origin}/a`, title: "A", windowId: "w1" }, { id: "b", url: `${origin}/b`, title: "B", windowId: "w2" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const X = globalThis.expo.modules.SolaraExtensions;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const act = (n, a) => C.devWindow(n, a);
const at = (p) => Math.round(p[0]) + "," + Math.round(p[1]);
const click = (n, p, count) => act(n, "mouse:moved:" + at(p)).then(() => settle(40))
  .then(() => act(n, "mouse:down:" + at(p) + "," + (count || 1))).then(() => settle(40)).then(() => act(n, "mouse:up:" + at(p) + "," + (count || 1)));
const drag = (n, from, dx) => act(n, "mouse:moved:" + at(from)).then(() => settle(40)).then(() => act(n, "mouse:down:" + at(from)))
  .then(() => [1, 2, 3, 4, 5].reduce((p, i) => p.then(() => settle(30)).then(() => act(n, "mouse:dragged:" + at([from[0] + dx * i / 5, from[1]]))), Promise.resolve()))
  .then(() => settle(40)).then(() => act(n, "mouse:up:" + at([from[0] + dx, from[1]])));
const shown = (w) => ac.extensions.useExtensions.getState().sidePanels[w] || null;
const width = () => ac.store.getState().settings.extensionSidePanelWidth ?? 360;
const card = () => {
  const [nat] = fibers("NativePanelCard");
  return nat ? measure(nat).then((f) => f && [f[0] + f[2] - width(), f[1], width(), f[3]]) : Promise.resolve(null);
};
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, test, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await (typeof test === "string" ? run(test) : test()).catch((e) => {
      if (e.crossCheck || e.appDied || !app?.alive) throw e;
      return { error: String(e.message ?? e) };
    });
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const snapshotFields = ["windows.sidePanel", "windows.chromeWindowNumber", "tabs.title", "tabs.live", "tabs.url",
  "root.settings", "root.sidePanelLiveViews", "root.hostedKinds", "root.poolAvailable", "root.haptics"];
const snapshotURL = (raw) => {
  if (typeof raw !== "string" || !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(raw)) return null;
  try {
    const url = new URL(raw);
    if (!["http:", "https:", "about:", "chrome:", "file:", "solara:"].includes(url.protocol)) return url.protocol;
    if (url.protocol === "file:") {
      const path = realpathSync(fileURLToPath(url));
      const data = realpathSync(app.data);
      if (path !== data && !path.startsWith(`${data}/`)) return null;
    }
    url.username = "";
    url.password = "";
    return [...url.href].slice(0, 2048).join("");
  } catch { return null; }
};
const untilSnapshot = async (what, accept, describe = () => null) => {
  const started = Date.now();
  const end = started + 2500;
  let last;
  const remaining = () => {
    const timeout = end - Date.now();
    assert.ok(timeout > 0, `${what}: cross-check deadline`);
    return timeout;
  };
  try {
    while (Date.now() < end) {
      assert.ok(app?.alive, `${what}: the owned app exited`);
      assert.ok(remaining() >= 1000, `${what}: cross-check deadline before native request`);
      last = await app.snapshot({ fields: snapshotFields }, { timeout: 1000 });
      if (Date.now() >= end) break;
      if (last.consistent && await accept(last, remaining) && Date.now() < end) return last;
      if (Date.now() < end) await sleep(Math.min(25, remaining()));
    }
    throw new Error(`${what}: native snapshot did not match (${JSON.stringify(last)})`);
  } catch (e) {
    throw Object.assign(new Error(`${e.message}; elapsed ${Date.now() - started}ms; observed ${JSON.stringify(describe())}; native ${JSON.stringify(last)}`, { cause: e }), { crossCheck: true, appDied: e.appDied });
  }
};
const bounded = async (what, read, timeout, dispose) => {
  const end = Date.now() + timeout;
  let expired = false;
  const pending = Promise.resolve().then(read).then((value) => {
    if (expired) dispose?.(value);
    return { value };
  });
  try {
    for (;;) {
      assert.ok(app?.alive, `${what}: the owned app exited`);
      const left = end - Date.now();
      assert.ok(left > 0, `${what}: observation deadline`);
      const result = await Promise.race([pending, sleep(Math.min(25, left)).then(() => null)]);
      if (result) return result.value;
    }
  } finally {
    expired = true;
  }
};
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
const crossRead = async (what, read, current, accept = () => true) => {
  let value;
  const snapshot = await untilSnapshot(what, async (snapshot, remaining) => {
    value = await current(remaining());
    return accept(value, snapshot) && same(read(snapshot), value);
  }, () => ({ js: value }));
  assert.deepEqual(read(snapshot), value, what);
  return { value, snapshot };
};
const nativeWindow = (s, id = "w1") => s.windows.find((w) => w.id === id);
const nativeCard = async () => {
  let frame, width;
  const s = await untilSnapshot("native side panel frame", async (s, remaining) => {
    const value = await run(`return card().then((frame) => ({ frame, width: width() }));`, remaining());
    ({ frame, width } = value);
    const card = nativeWindow(s)?.sidePanel?.card;
    return !!frame && near(card?.frame, frame) && card.width === width;
  });
  assert.ok(near(nativeWindow(s).sidePanel.card.frame, frame), "native panel frame matches the measured card within half a point");
  assert.equal(nativeWindow(s).sidePanel.card.width, width, "native panel width matches the current JS width");
  return { frame, panel: nativeWindow(s).sidePanel, width };
};
const nativeClosed = async (what, windowId = "w1") => {
  let views;
  const s = await untilSnapshot(what, async (s, remaining) => {
    views = await liveViews(remaining());
    const w = nativeWindow(s, windowId);
    return views === 0 && s.sidePanelLiveViews === views
      && (windowId === "w2" && !w || !!w?.sidePanel && w.sidePanel.pages.length === 0 && !w.sidePanel.card);
  }, () => ({ windowId, jsLiveViews: views }));
  assert.equal(nativeWindow(s, windowId)?.sidePanel?.pages.length ?? 0, 0, what);
  assert.equal(views, 0, `${what}: no JS sidePanel webview remains`);
  assert.equal(s.sidePanelLiveViews, 0, `${what}: no native sidePanel webview remains`);
  return s;
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [f[0] + f[2] / 2, f[1] + f[3] / 2];
const closeButton = (f) => [f[0] + f[2] - 5 - 15, f[1] + 20];
const grip = (f) => [f[0] + 0.5, f[1] + f[3] / 2];
const pageCentre = (f) => [f[0] + f[2] / 2, f[1] + 41 + (f[3] - 41) / 2];

const panelTargets = async (id) => (await app.targets()).filter((t) => t.url.startsWith(`chrome-extension://${id}/panel.html`));
const renderers = () => {
  try {
    return execFileSync("pgrep", ["-P", String(app.pid), "-f", "type=renderer"], { encoding: "utf8" }).trim().split("\n").filter(Boolean).length;
  } catch {
    return 0;
  }
};
const liveViews = (timeout) => run(`return C.devLiveExtensionViews("sidePanel");`, timeout);
const noLiveViews = async (what) => {
  const { value, snapshot } = await crossRead(`${what}: no live side panel view`, (s) => s.sidePanelLiveViews,
    (timeout) => liveViews(timeout), (value) => value === 0);
  assert.equal(value, 0, `${what}: no live side panel view`);
  assert.equal(snapshot.sidePanelLiveViews, 0, `${what}: no native sidePanel webview remains`);
  return true;
};
const focused = async (urlPart) => {
  const target = await app.pageTarget(urlPart);
  if (!target) return null;
  const page = await devtools(target);
  try {
    let value;
    const extensionId = urlPart.startsWith("chrome-extension:") ? new URL(urlPart).host : null;
    const nativeFocused = (s) => extensionId
      ? s.windows.some((w) => w.sidePanel?.pages.some((p) => p.extensionId === extensionId && p.focused))
      : s.windows.some((w) => w.sidePanel?.focusedTabIds.some((id) => s.tabs.some((t) => t.id === id && typeof t.url === "string" && t.url.includes(urlPart))));
    const s = await untilSnapshot("native page focus matches CDP", async (s, remaining) => {
      value = await page.eval("document.hasFocus()", { timeout: remaining() });
      return nativeFocused(s) === value;
    });
    assert.equal(nativeFocused(s), value, "native first responder matches document.hasFocus()");
    return value;
  } finally {
    page.close();
  }
};

const LEGS = [
  { tag: "native", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "0" } },
  { tag: "pool", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" } },
].filter((l) => !legsArg || legsArg.split(",").includes(l.tag));
const measured = {};

try {
  for (const { tag, env } of LEGS) {
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true, env,
      ready: "return !!ac.store.getState().windows.w1",
    });
    await until("page A", `return ac.store.getState().tabs.a?.title === "A" || null;`, 15000);
    const number = await until("window w1", `const id = Object.entries(ac.pageState.getState().browsers ?? {}).find(([, t]) => t === "a")?.[0]; return id ? C.devWindowNumber(Number(id)) : null;`, 15000);
    const identity = await untilSnapshot("native page A and owning window", (s) => s.tabs.some((t) => t.id === "a" && t.title === "A") && nativeWindow(s)?.chromeWindowNumber === number);
    for (const field of ["windows.sidePanel", "sidePanelLiveViews", "settings.extensionSidePanelWidth", "hostedKinds", "haptics"]) assert.ok(identity.capabilities.available.includes(field), field);
    assert.equal(nativeWindow(identity).chromeWindowNumber, number);
    assert.equal(identity.tabs.find((t) => t.id === "a").title, "A");
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted?.kinds?.() ?? [];`);
    if (!kinds.includes("extensionSidePanel")) throw new Error(`${tag}: hosted kinds ${JSON.stringify(kinds)}`);
    assert.deepEqual([...identity.hostedKinds].sort(), [...kinds].sort(), "native hosted registrations match the JS module");
    if (tag.endsWith("pool")) {
      const { value: served, snapshot: pooled } = await crossRead("native pool serves page A",
        (s) => !!s.poolAvailable && !!s.tabs.find((t) => t.id === "a")?.live,
        (timeout) => run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.() && !!ac.webviews.get("a") && !acPerf.findFibers("TabWebView", 5).length;`, timeout));
      if (!served) throw new Error("the pool doesn't serve page A");
      assert.equal(pooled.poolAvailable, true);
      assert.equal(pooled.tabs.find((t) => t.id === "a").live, true);
    }
    const a = await run(`return X.install(${JSON.stringify(extA)}, "");`);
    const b = await run(`return X.install(${JSON.stringify(extB)}, "");`);
    const c = await run(`return X.install(${JSON.stringify(extC)}, "");`);
    await run(`return ac.extensions.refreshExtensions("").then(() => true);`);
    const open = (id, w = "w1", timeout = 2500) => run(`return ac.extensions.openSidePanel(${JSON.stringify(w)}, ${JSON.stringify(id)}).then(() => shown(${JSON.stringify(w)}));`, timeout);
    const loadedPanel = async (id, w = "w1", old = null) => {
      const url = `chrome-extension://${id}/panel.html`;
      const title = new Map([[a.id, "Side panel A"], [b.id, "Side panel B"], [c.id, "Side panel C"]]).get(id);
      let observed = { old, url, title };
      let document;
      const s = await untilSnapshot(`${id}'s loaded panel${old ? " after one immediate reopen" : ""}`, async (s, remaining) => {
        const shownPanel = await run(`return shown(${JSON.stringify(w)});`, remaining());
        const views = await liveViews(remaining());
        const targets = await bounded("panel targets", () => app.targets(), remaining());
        const panels = targets.filter((t) => t.url.startsWith(url));
        observed = { old, url, title, shown: shownPanel, jsLiveViews: views, nativeLiveViews: s.sidePanelLiveViews,
          attached: nativeWindow(s, w)?.sidePanel?.pages, targets: targets.map((t) => ({ id: t.id, type: t.type, url: t.url })) };
        const target = panels.find((t) => t.type === "page" && t.url === url && (!old || t.id !== old.targetId));
        if (!target) return false;
        const page = await bounded("panel CDP connection", () => devtools(target), remaining(), (page) => page.close());
        try {
          document = await page.eval(`(() => {
            const loaded = location.href === ${JSON.stringify(url)} && document.readyState === "complete"
              && document.title === ${JSON.stringify(title)} && !!document.querySelector("#field");
            if (loaded) globalThis.__solaraSidePanelLoadNonce ??= ${JSON.stringify(randomUUID())};
            return { url: location.href, readyState: document.readyState, title: document.title,
              field: !!document.querySelector("#field"), nonce: globalThis.__solaraSidePanelLoadNonce ?? null };
          })()`, { timeout: remaining() });
          observed.document = document;
          observed.targetId = target.id;
        } finally {
          page.close();
        }
        return panels.length === 1 && shownPanel?.extensionId === id
          && same(nativeWindow(s, w)?.sidePanel?.pages.map((p) => p.extensionId), [id])
          && views === 1 && s.sidePanelLiveViews === views && document.url === url
          && document.readyState === "complete" && document.title === title && document.field && !!document.nonce
          && (!old || target.id !== old.targetId && document.nonce !== old.nonce && !targets.some((t) => t.id === old.targetId));
      }, () => observed);
      assert.equal(observed.shown.extensionId, id);
      assert.equal(nativeWindow(s, w).sidePanel.pages[0].extensionId, observed.shown.extensionId);
      return { targetId: observed.targetId, ...document };
    };
    const openAndLoad = async (id, w = "w1") => {
      await open(id, w);
      return loadedPanel(id, w);
    };
    const closedWithFocusOnA = async (how) => {
      await until(`${how}: the panel closes`, `return !shown("w1") || null;`, 4000);
      const onA = await until(`${how}: page A has focus`, async () => (await focused(`${origin}/a`)) || null, 3000);
      await nativeClosed(`${how}: native panel closes`);
      return onA;
    };
    const focusPanel = async (id) => {
      const f = await run(`return card();`);
      await run(`return click(${number}, ${JSON.stringify(pageCentre(f))}).then(() => true);`);
      await until("the panel page has focus", async () => (await focused(`chrome-extension://${id}/panel.html`)) || null, 3000).catch(async (e) => {
        if (e.crossCheck) throw e;
        const p = pageCentre(f);
        const hit = await run(`return act(${number}, "hit:${Math.round(p[0])},${Math.round(p[1])}");`).catch((x) => String(x));
        const responders = await run(`return act(${number}, "responders:");`).catch((x) => String(x));
        throw new Error(`${e.message}; card ${JSON.stringify(f)}; hit ${JSON.stringify(hit)}; responders ${JSON.stringify(responders)}`);
      });
    };
    const baseline = renderers();

    await rep.check(`${tag}-opens`, async () => {
      await run(`ac.store.getState().updateSettings({ extensionSidePanelWidth: 360 }); return true;`);
      await openAndLoad(a.id);
      const { frame } = await nativeCard();
      const panel = await app.page(`chrome-extension://${a.id}/panel.html`);
      let page, observed;
      try {
        observed = await untilSnapshot("native panel viewport", async (s, remaining) => {
          page = await panel.eval("[innerWidth, innerHeight]", { timeout: remaining() });
          const p = nativeWindow(s)?.sidePanel?.pages.find((p) => p.extensionId === a.id);
          return p && near(p.frame.slice(2), page);
        });
      } finally {
        panel.close();
      }
      assert.ok(near(nativeWindow(observed).sidePanel.pages.find((p) => p.extensionId === a.id).frame.slice(2), page));
      assert.equal(observed.settings.extensionSidePanelWidth, 360);
      measured[tag] = { frame, page };
      return { frame, page };
    });

    await rep.check(`${tag}-grip-resizes`, async () => {
      const f = await run(`return card();`);
      await run(`return drag(${number}, ${JSON.stringify(grip(f))}, -80).then(() => true);`);
      const { value: w, snapshot: saved } = await crossRead("the width is saved", (s) => s.settings.extensionSidePanelWidth,
        (timeout) => run(`return width() !== 360 ? width() : null;`, timeout), (value) => value !== null);
      if (Math.abs(w - 440) > 1) throw new Error(`width ${w} after an 80 point drag`);
      assert.equal(saved.settings.extensionSidePanelWidth, w);
      await until("the card follows", `return card().then((c) => c && Math.abs(c[2] - ${w}) < 1 || null);`, 3000);
      const { frame: g } = await nativeCard();
      await run(`return click(${number}, ${JSON.stringify(grip(g))}, 1).then(() => click(${number}, ${JSON.stringify(grip(g))}, 2)).then(() => true);`);
      let resetFrame;
      const { snapshot: reset } = await crossRead("a double-click resets it", (s) => s.settings.extensionSidePanelWidth === 360,
        async (timeout) => {
          const value = await run(`return card().then((frame) => ({ reset: width() === 360 || null, frame }));`, timeout);
          resetFrame = value.frame;
          return value.reset;
        }, (value, s) => value === true && nativeWindow(s)?.sidePanel?.card?.width === 360 && near(nativeWindow(s).sidePanel.card.frame, resetFrame));
      assert.equal(reset.settings.extensionSidePanelWidth, 360);
      assert.ok(near(nativeWindow(reset).sidePanel.card.frame, resetFrame), "native reset frame matches the measured card within half a point");
      return w;
    });

    await rep.check(`${tag}-window-open`, async () => {
      const { value: before, snapshot: initialTabs } = await crossRead("native initial tab count", (s) => s.tabs.length,
        (timeout) => run(`return Object.keys(ac.store.getState().tabs).length;`, timeout));
      assert.equal(initialTabs.tabs.length, before);
      const panel = await app.page(`chrome-extension://${a.id}/panel.html`);
      await panel.eval(`window.open(${JSON.stringify(`${origin}/opened`)}); true`, { userGesture: true });
      panel.close();
      const tabRows = (tabs) => tabs.map((t) => ({ id: t.id, url: t.url })).sort((a, b) => a.id.localeCompare(b.id));
      const { value: jsTabs, snapshot: s } = await crossRead("native panel opens a tab", (s) => tabRows(s.tabs),
        async (timeout) => {
          const tabs = await run(`const tabs = Object.values(ac.store.getState().tabs); return tabs.some((t) => (t.url || "").endsWith("/opened")) && tabs.length > ${before} ? tabs.map((t) => ({ id: t.id, url: t.url })) : null;`, timeout);
          return tabs && tabRows(tabs.map((t) => ({ id: t.id, url: snapshotURL(t.url) })));
        }, (value, s) => !!value && s.tabs.length > before && s.tabs.some((t) => typeof t.url === "string" && t.url.endsWith("/opened")));
      assert.ok(s.tabs.length > before);
      assert.deepEqual(tabRows(s.tabs), jsTabs);
      return true;
    });
    await run(`const t = Object.values(ac.store.getState().tabs).find((t) => (t.url || "").endsWith("/opened")); if (t) ac.store.getState().closeTab(t.id); ac.store.getState().setActiveTab?.("w1", "a"); return true;`).catch(() => null);
    await sleep(300);

    await rep.check(`${tag}-focus-close-button`, async () => {
      await openAndLoad(a.id);
      await focusPanel(a.id);
      const f = await run(`return card();`);
      await run(`return click(${number}, ${JSON.stringify(closeButton(f))}).then(() => true);`);
      return closedWithFocusOnA("✕");
    });

    await rep.check(`${tag}-focus-toolbar-toggle`, async () => {
      await openAndLoad(a.id);
      await focusPanel(a.id);
      await run(`return Promise.resolve(ac.extensions.toggleSidePanel("w1", ${JSON.stringify(a.id)})).then(() => true);`);
      return closedWithFocusOnA("toggle");
    });

    await rep.check(`${tag}-focus-replace`, async () => {
      await openAndLoad(a.id);
      await focusPanel(a.id);
      await openAndLoad(b.id);
      await until("A's panel page goes", async () => (await panelTargets(a.id)).length === 0 || null, 4000);
      const onA = await until("page A has focus after the replace", async () => (await focused(`${origin}/a`)) || null, 3000);
      let replacementViews;
      const replaced = await untilSnapshot("native replaced panel page and one live view", async (s, remaining) => {
        replacementViews = await liveViews(remaining());
        return replacementViews === 1 && s.sidePanelLiveViews === replacementViews
          && same(nativeWindow(s)?.sidePanel?.pages.map((p) => p.extensionId), [b.id]);
      }, () => ({ extensionId: b.id, jsLiveViews: replacementViews }));
      assert.deepEqual(nativeWindow(replaced).sidePanel.pages.map((p) => p.extensionId), [b.id]);
      assert.equal(replacementViews, 1);
      assert.equal(replaced.sidePanelLiveViews, 1);
      await run(`ac.extensions.closeSidePanel("w1"); return true;`);
      await until("B's panel page goes", async () => (await panelTargets(b.id)).length === 0 || null, 4000);
      await nativeClosed("native replacement closes");
      return onA;
    });

    await rep.check(`${tag}-cycles`, async () => {
      for (let i = 0; i < 12; i++) {
        await openAndLoad(i % 2 ? b.id : a.id);
        await run(`ac.extensions.closeSidePanel("w1"); return true;`);
        await until("the panel closes", `return !shown("w1") || null;`, 4000);
        await nativeClosed(`native cycle ${i + 1}/12 closes`);
      }
      await until("no panel page is left", async () => (await panelTargets(a.id)).length + (await panelTargets(b.id)).length === 0 || null, 5000);
      await noLiveViews("twelve cycles");
      const after = await until("renderers settle", async () => (renderers() <= baseline + 1 ? renderers() : null), 8000).catch(() => renderers());
      if (after > baseline + 1) throw new Error(`renderers ${baseline} before, ${after} after twelve cycles`);
      return { baseline, after };
    });

    await rep.check(`${tag}-closed-window`, async () => {
      await openAndLoad(a.id, "w2");
      await run(`ac.store.getState().closeWindow("w2"); return true;`);
      await until("w2's panel page goes", async () => (await panelTargets(a.id)).length === 0 || null, 5000);
      const closedWindow = await nativeClosed("native closed window drops panel", "w2");
      assert.equal(closedWindow.windows.some((w) => w.id === "w2"), false);
      return noLiveViews("a closed window");
    });

    await rep.check(`${tag}-js-reload`, async () => {
      await openAndLoad(b.id);
      await run(`setTimeout(() => { try { globalThis.nativeModuleProxy.DevSettings.reload(); } catch {} }, 50); return true;`);
      await sleep(1500);
      await app.ready({ timeout: 60000, test: "return !!ac.store.getState().windows.w1" });
      await sleep(1500);
      const left = (await panelTargets(b.id)).length;
      if (left > 1) throw new Error(`${left} panel pages after a JS reload`);
      const { value: views, snapshot: reload } = await crossRead("native live views after reload", (s) => s.sidePanelLiveViews,
        (timeout) => liveViews(timeout));
      if (views > 1) throw new Error(`${views} live side panel views after a JS reload`);
      assert.equal(reload.sidePanelLiveViews, views);
      assert.ok(reload.sidePanelLiveViews <= 1);
      await run(`ac.extensions.closeSidePanel("w1"); return true;`);
      await until("no panel page after closing", async () => (await panelTargets(b.id)).length === 0 || null, 5000);
      await nativeClosed("native closing after a JS reload");
      await noLiveViews("closing after a JS reload");
      return { left, views };
    });

    await rep.check(`${tag}-window-close`, async () => {
      const old = await openAndLoad(c.id);
      const target = (await bounded("original C target", () => app.targets(), 2500)).find((t) => t.id === old.targetId);
      assert.ok(target, `original C target disappeared before window.close(): ${JSON.stringify(old)}`);
      const panel = await bounded("original C CDP connection", () => devtools(target), 2500, (page) => page.close());
      const closing = Date.now();
      const end = closing + 2500;
      let shownPanel;
      try {
        await panel.eval("window.close(); true", { timeout: 2500 }).catch(() => null);
        panel.close();
        while (Date.now() < end) {
          assert.ok(app?.alive, "window.close(): the owned app exited");
          const left = end - Date.now();
          if (left <= 0) break;
          shownPanel = await run(`return shown("w1");`, left);
          if (!shownPanel) break;
          await sleep(Math.min(25, Math.max(0, end - Date.now())));
        }
        assert.equal(shownPanel, null, "window.close(): JS did not observe the panel close");
      } catch (e) {
        throw new Error(`${e.message}; window.close elapsed ${Date.now() - closing}ms; old ${JSON.stringify(old)}; last shown ${JSON.stringify(shownPanel)}`, { cause: e });
      } finally {
        panel.close();
      }
      const closed = Date.now();
      const reopening = Date.now();
      let reopened, requestResult;
      try {
        requestResult = await open(c.id);
        reopened = await loadedPanel(c.id, "w1", old);
      } catch (e) {
        throw new Error(`${e.message}; old ${JSON.stringify(old)}; reopen result ${JSON.stringify(requestResult)}; close to JS ${closed - closing}ms; JS close to reopen request ${reopening - closed}ms; reopen elapsed ${Date.now() - reopening}ms`, { cause: e });
      }
      assert.notEqual(reopened.targetId, old.targetId);
      assert.notEqual(reopened.nonce, old.nonce);
      await run(`ac.extensions.closeSidePanel("w1"); return true;`);
      await until("the reopened panel closes", async () => (await panelTargets(c.id)).length === 0 || null, 5000);
      await nativeClosed("native window.close and reopened panel close drop panel");
      await noLiveViews("the reopened panel closes");
      return { reopened: true, old, replacement: reopened, closeToJS: closed - closing, closeToReopen: reopening - closed };
    });

    await rep.check(`${tag}-turned-off`, async () => {
      await openAndLoad(b.id);
      await run(`return ac.extensions.setEnabled("", ${JSON.stringify(b.id)}, false).then(() => true);`);
      await until("the panel closes", `return !shown("w1") || null;`, 5000);
      await until("its page goes", async () => (await panelTargets(b.id)).length === 0 || null, 5000);
      await nativeClosed("native turned-off extension closes");
      await noLiveViews("a turned-off extension");
      await run(`return ac.extensions.setEnabled("", ${JSON.stringify(b.id)}, true).then(() => true);`);
      return true;
    });

    await rep.check(`${tag}-hidden-haptics`, async () => {
      assert.ok(app?.alive, "hidden haptics: the owned app exited");
      const s = await app.snapshot({ fields: ["root.haptics"] }, { timeout: 1000 });
      assert.ok(s.consistent, "consistent hidden haptics snapshot");
      assert.equal(s.haptics.performed, 0, "hidden grip drags perform no haptics");
      return s.haptics;
    });
    await app.quit();
    app = null;
  }

  for (const tag of ["native", "pool"]) {
    if (!measured.rn || !measured[tag]) continue;
    await rep.check(`${tag}-matches-rn`, async () => {
      if (!near(measured[tag].frame, measured.rn.frame)) throw new Error(`card ${measured[tag].frame}, RN ${measured.rn.frame}`);
      if (!near(measured[tag].page, measured.rn.page)) throw new Error(`panel page ${measured[tag].page}, RN ${measured.rn.page}`);
      return measured.rn;
    });
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
