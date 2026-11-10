#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devtools, launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node pages-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pages-"));
const data = join(scratch, "data");
const files = join(scratch, "files");
mkdirSync(files);
writeFileSync(join(files, "report.pdf"), "report");
writeFileSync(join(files, "photo.png"), "photo");
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>prompts</title><body>${req.url.slice(1).replace(/[^a-z0-9?=]/gi, "")}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const midnight = new Date();
midnight.setHours(24, 0, 0, 0);
const minutesLeftToday = Math.floor((midnight.getTime() - Date.now()) / 60_000);
const startToday = (minutes) => Math.min(minutes, minutesLeftToday - 5);
const calendarFixture = JSON.stringify({
  calendars: [{ id: "work", title: "Work", color: "#3478F6", account: "Fixture", accountType: "local", owned: true }],
  events: [
    { id: "standup", calendarId: "work", color: "#3478F6", title: "Standup", startInMinutes: startToday(3), durationMinutes: 15, allDay: false, location: "", notes: "", url: "https://zoom.us/j/123456789", cancelled: false, declined: false, organizer: null, attendees: [{ name: "Ada Lovelace", email: "ada@example.com", me: false }, { name: "Me", email: "me@example.com", me: true }] },
    { id: "review", calendarId: "work", color: "#34C759", title: "Design review", startInMinutes: startToday(90), durationMinutes: 30, allDay: false, location: "", notes: "", url: "", cancelled: false, declined: false, organizer: null, attendees: [] },
  ],
});
const rep = reporter(join(scratch, "pages-test.log"), { name: "pages-test" });
const download = (id, filename, state, extra = {}) => ({
  id, url: `https://example.com/${filename}`, filename, path: join(files, filename), state, paused: false,
  received: 1000, total: state === "downloading" ? 4000 : 1000, speed: 0, mimeType: "", ...extra,
});
const downloads = [download("d1", "report.pdf", "finished"), download("d2", "photo.png", "finished"), download("d3", "big.zip", "downloading")];
let app = null;
let nativePrompts = null;
const dev = (action) =>
  app.eval(`const C = globalThis.expo.modules.SolaraCEF; return C.chromeWindows().then((ws) => C.devWindow(ws.find((w) => w.hasRoot).window, ${JSON.stringify(action)}))`);
const untilSnapshot = async (instance, what, accept, ms = 3000, args = {}) => {
  const end = Date.now() + ms;
  let last;
  const remaining = () => {
    const timeout = end - Date.now();
    assert.ok(timeout > 0, `${what}: cross-check deadline`);
    return timeout;
  };
  while (Date.now() < end) {
    assert.ok(instance.alive, `${what}: the owned app exited`);
    assert.ok(remaining() >= 1000, `${what}: cross-check deadline before native request`);
    last = await instance.snapshot({ pages: true, fields: ["root.calendar", "root.profiles", "root.downloads", "root.hostedKinds", "windows.bookmarks", "windows.chromeWindowNumber", "windows.viewFrames", "windows.paneOverlays", "windows.hoverCard", "windows.selectedTabId", "windows.frame", "tabs.url"], ...args }, { timeout: 1000 });
    if (Date.now() >= end) break;
    if (last.consistent && await accept(last, remaining) && Date.now() < end) return last;
    await sleep(50);
  }
  throw new Error(`${what}: native snapshot did not match (${JSON.stringify(last)})`);
};
const freshMeetingTab = (snapshot, before, current) => snapshot.tabs.some((tab) => !before.includes(tab.id) && tab.url?.includes("zoom.us") && current.some((row) => row.id === tab.id && row.url === tab.url));
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
const nearFrame = (a, b) => !!a && !!b && ["x", "y", "width", "height"].every((key) => Math.abs(a[key] - b[key]) <= 0.5);
const safePageURL = (value, dataPath = "") => {
  if (typeof value !== "string" || !value) return null;
  try {
    const url = new URL(value);
    const scheme = url.protocol.slice(0, -1).toLowerCase();
    if (!["http", "https", "about", "chrome", "file", "solara", "solara"].includes(scheme)) return `${scheme}:`;
    if (scheme === "file") {
      if (!dataPath) return null;
      const path = realpathSync(fileURLToPath(url)), root = realpathSync(dataPath);
      if (path !== root && !path.startsWith(`${root}/`)) return null;
    }
    return value.replace(/^(\w+:\/\/)[^/@]*@/, "$1").slice(0, 2048);
  } catch { return null; }
};
const pageValues = (page, sanitize = true, dataPath = "") => Object.fromEntries(Object.entries(page).filter(([key]) => key !== "ax" && key !== "frames")
  .map(([key, value]) => [key, !sanitize ? value : key === "url" ? safePageURL(value, dataPath)
    : page.kind === "history" && ["shown", "selected"].includes(key) ? value.map((url) => safePageURL(url, dataPath)) : value]));
const matchesRows = (native, js, match) => {
  if (!Array.isArray(native) || !Array.isArray(js) || native.length !== js.length) return false;
  const assigned = new Map();
  const assign = (index, seen) => {
    for (let i = 0; i < native.length; i++) {
      if (seen.has(i) || !match(native[i], js[index])) continue;
      seen.add(i);
      if (!assigned.has(i) || assign(assigned.get(i), seen)) {
        assigned.set(i, index);
        return true;
      }
    }
    return false;
  };
  return js.every((_, index) => assign(index, new Set()));
};
const pagesMatch = (native, js, dataPath = "") => matchesRows(native, js, (row, page) =>
  same(pageValues(row, false), pageValues(page, true, dataPath)) && matchesRows(row.frames, page.frames, (other, frame) =>
    other.label === (frame.label.startsWith("row:") ? `row:${safePageURL(frame.label.slice(4), dataPath) ?? ""}` : frame.label.slice(0, 512)) && nearFrame(other, frame)));
const readPages = async (instance) => {
  let js;
  await untilSnapshot(instance, "native page models and frames", async (snapshot, remaining) => {
    js = JSON.parse(await instance.eval(`return globalThis.expo.modules.SolaraPages.devPages()`, { timeout: remaining() })).pages;
    return pagesMatch(snapshot.pages.map((page) => ({ ...page, frames: snapshot.pageFrames })), js, instance.data);
  }, 3000, { fields: ["root.pages", "root.pageFrames"] });
  return js;
};
const page = async () => (await readPages(app))[0];
const readFrame = async (instance, windowNumber, needle) => {
  let js;
  await untilSnapshot(instance, `${needle} frame`, async (snapshot, remaining) => {
    js = JSON.parse(await instance.eval(`return globalThis.expo.modules.SolaraPages.devViewFrame(${windowNumber}, ${JSON.stringify(needle)})`, { timeout: remaining() }));
    const row = snapshot.windows.find((window) => window.chromeWindowNumber === windowNumber)?.viewFrames?.[needle];
    return row?.found === js.found && (!js.found || row.class === js.class && row.alpha === js.alpha && row.transformed === js.transformed && nearFrame(row, js));
  }, 3000, { viewFrames: [needle], fields: ["windows.chromeWindowNumber", "windows.viewFrames"] });
  return js;
};
const canonicalURL = (url) => (typeof url === "string" ? new URL(url).href : url ?? null);
const crossValue = async (instance, what, read, value, args = {}) => {
  const snapshot = await untilSnapshot(instance, what, (snapshot) => same(read(snapshot), value), 3000, args);
  assert.deepEqual(read(snapshot), value, what);
};
const crossRead = async (instance, what, read, current, args = {}) => {
  let value;
  await untilSnapshot(instance, what, async (snapshot, remaining) => {
    value = await current(remaining());
    return same(read(snapshot), value);
  }, 3000, args);
  return value;
};
const crossPane = async (instance, tabId, key, current) => {
  let js;
  await untilSnapshot(instance, `${key} pane`, async (snapshot, remaining) => {
    js = await current(remaining());
    const entry = snapshot.windows.flatMap((window) => [window.paneOverlays?.tabs?.[tabId]?.[key]]).find(Boolean);
    if (!js) return !entry || entry.hidden || !entry.card;
    return !!entry && entry.hidden === js.hidden && entry.opacity === js.opacity &&
      same(entry.card, js.card) && same(entry.controls, js.controls);
  }, 3000, { fields: ["windows.paneOverlays"] });
  return js;
};
const until = async (test, ms = 3000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await test();
    if (last.ok) return last;
    await sleep(100);
  }
  return last;
};
const frameOf = (current, label) => current.frames.find((f) => f.label === label);
const click = (frame) => dev(`click:${frame.x + frame.width / 2},${frame.y + frame.height / 2}`);

const PROMPT_FIELDS = {
  permission: ["permission", `{ id: "probe-perm", browserId: 0, origin: ${JSON.stringify(base)}, permissions: ["notifications"] }`],
  password: ["passwordPrompt", `{ state: "save", origin: "https://example.com", username: "ada@example.com", passwordLength: 12, federation: "", usernames: ["ada@example.com"] }`],
  autofill: ["autofillPrompt", `{ id: 7, kind: "saveAddress", origin: "https://example.com", title: "Save address?", message: "", accept: "Save", decline: "No thanks", footer: "", lines: ["Ada Lovelace", "1 Analytical Way"] }`],
  externalApp: ["externalApp", `{ id: "probe-ext", url: "zoommtg://x", scheme: "zoommtg", origin: "https://example.com", app: "zoom.us", appPath: null, icon: null, title: "Open zoom.us?", message: "https://example.com wants to open this application.", remember: "Always allow example.com to open links of this type" }`],
};
const PROMPT_NAMES = [...Object.keys(PROMPT_FIELDS), "engine", "chooser", "popups"];
const PAGE_EVENTS = { password: ["onPasswordPrompt", "{}"], autofill: ["onAutofillPrompt", "{ id: 7, closed: true }"], externalApp: ["onExternalApp", "{}"] };
const PANE_KEYS = { permission: "permission", password: "password", autofill: "autofill", externalApp: "externalApp", engine: "engineOffer", chooser: "deviceChooser", popups: "popups" };
const panePromptsHosted = async (instance) => {
  const hosted = await crossRead(instance, "pane prompts hosting", (snapshot) => snapshot.hostedKinds.includes("panePrompts"),
    (timeout) => instance.eval(`return Promise.resolve(globalThis.expo.modules.SolaraHosted?.kinds?.() ?? []).then((k) => k.includes("panePrompts"))`, { timeout }));
  assert.equal(hosted, true, "pane prompts are hosted natively");
};
const paneEntry = (instance, tabId, key) => crossPane(instance, tabId, key, async (timeout) => {
  const described = JSON.parse(await instance.eval(`const M = globalThis.expo.modules.SolaraMedia; const w = Object.keys(ac.store.getState().windows)[0]; return M?.describePaneOverlays ? M.describePaneOverlays(w) : "null"`, { timeout }));
  const entry = described?.tabs?.[tabId]?.[key] ?? null;
  return entry && !entry.hidden && entry.card ? entry : null;
});
const askFromPage = async (instance, url, expression) => {
  let target = null;
  for (let i = 0; i < 40 && !target; i++) {
    target = await instance.pageTarget(url).catch(() => null);
    if (!target) await sleep(200);
  }
  if (!target) throw new Error(`no DevTools target for ${url}`);
  const cdp = await devtools(target);
  try {
    await cdp.send("Runtime.evaluate", { expression, userGesture: true, returnByValue: true });
  } finally {
    cdp.close();
  }
};
const POPUPS = JSON.stringify([1, 2, 3].map((n) => ({ id: `pop${n}`, url: `https://example.com/pop${n}`, origin: "https://example.com" })));

async function promptOutcomes(instance) {
  const run = (action) =>
    instance.eval(`const C = globalThis.expo.modules.SolaraCEF; return C.chromeWindows().then((ws) => C.devWindow(ws.find((w) => w.hasRoot).window, ${JSON.stringify(action)}))`);
  const ids = JSON.parse(await instance.eval(`const C = globalThis.expo.modules.SolaraCEF; const s = ac.store.getState(); const w = Object.keys(s.windows)[0];
    const tab = s.newTab(w, { url: ${JSON.stringify(`${base}/prompts`)} });
    return C.chromeWindows().then((ws) => JSON.stringify({ tab, win: ws.find((x) => x.hasRoot).window }))`));
  await run("fakeActiveClicks");
  await sleep(2000);
  const tab = JSON.stringify(ids.tab);
  await panePromptsHosted(instance);
  let visit = 0;
  const pageEvent = (name, payload) => instance.eval(`return globalThis.expo.modules.SolaraTabPool.devPageEvent(${tab}, ${JSON.stringify(name)}, ${payload})`);
  const pageField = (field, value) => `ac.pageState.setState((s) => ({ pages: { ...s.pages, [${tab}]: { ...(s.pages[${tab}] || {}), ${field}: ${value} } } })); return true`;
  const plant = (name) =>
    instance.eval(
      name === "engine" ? `ac.pages.engineOffers.setState({ [${tab}]: { site: "https://example.com", host: "example.com", keySystem: "com.widevine.alpha", canRemember: true } }); return true`
      : name === "popups" ? `ac.pageState.setState((s) => ({ pages: { ...s.pages, [${tab}]: { ...(s.pages[${tab}] || {}), popups: ${POPUPS} } }, popover: { ...s.popover, [${tab}]: "popups" } })); return true`
      : pageField(PROMPT_FIELDS[name][0], PROMPT_FIELDS[name][1]),
    );
  const unplant = (name) =>
    instance.eval(
      name === "engine" ? `ac.pages.engineOffers.setState({}, true); return true`
      : name === "popups" ? `ac.pageState.setState((s) => ({ pages: { ...s.pages, [${tab}]: { ...(s.pages[${tab}] || {}), popups: [] } }, popover: { ...s.popover, [${tab}]: null } })); return true`
      : pageField(PROMPT_FIELDS[name][0], "null"),
    );
  const present = (name, timeout) =>
    instance.eval(
      name === "engine" ? `return !!ac.pages.engineOffers.getState()[${tab}]`
      : name === "popups" ? `const s = ac.pageState.getState(); return s.popover[${tab}] === "popups" ? s.pages[${tab}].popups.map((p) => p.id).join(",") : false`
      : `return !!ac.pageState.getState().pages[${tab}]?.${PROMPT_FIELDS[name][0]}`,
      { timeout },
    );
  const show = async (name) => {
    if (name === "permission") {
      if (await present(name)) return true;
      await askFromPage(instance, `${base}/prompts`, "Notification.requestPermission(); true");
      for (let i = 0; i < 25 && !(await present(name)); i++) await sleep(200);
      return true;
    }
    if (PAGE_EVENTS[name]) return pageEvent(PAGE_EVENTS[name][0], PROMPT_FIELDS[name][1]);
    return plant(name);
  };
  const clear = async (name) => {
    if (name === "permission") {
      await instance.eval(`ac.store.getState().navigate(${tab}, ${JSON.stringify(`${base}/prompts?visit=`)} + ${++visit}, { userInitiated: true }); return true`);
      for (let i = 0; i < 25 && (await present(name)); i++) await sleep(200);
      await sleep(800);
      return true;
    }
    if (PAGE_EVENTS[name]) await pageEvent(PAGE_EVENTS[name][0], PAGE_EVENTS[name][1]);
    return unplant(name);
  };
  const crossPresent = async (name) => {
    let value;
    const snapshot = await untilSnapshot(instance, `${name} prompt visibility`, async (snapshot, remaining) => {
      value = await present(name, remaining());
      const entry = snapshot.windows.flatMap((window) => [window.paneOverlays?.tabs?.[ids.tab]?.[PANE_KEYS[name]]]).find(Boolean);
      if (!!value !== (!!entry && !entry.hidden && !!entry.card)) return false;
      if (name === "popups" && value) {
        const ids = Object.keys(entry.controls ?? {}).filter((label) => /\/pop[123]$/.test(label)).map((label) => label.split("/").at(-1)).sort().join(",");
        return ids === value;
      }
      return true;
    });
    assert.equal(!!value, snapshot.windows.some((window) => {
      const entry = window.paneOverlays?.tabs?.[ids.tab]?.[PANE_KEYS[name]];
      return !!entry && !entry.hidden && !!entry.card;
    }));
    return value;
  };
  const out = {};
  for (const name of PROMPT_NAMES) {
    if (name === "chooser") {
      out[name] = { native: null, host: "no test input", card: null, afterEsc: null, afterOutside: null, afterRow: null };
      continue;
    }
    await show(name);
    await sleep(600);
    const pane = await paneEntry(instance, ids.tab, PANE_KEYS[name]);
    const card = pane ? { x: pane.card[0], y: pane.card[1], width: pane.card[2], height: pane.card[3] } : null;
    await run("keys:0:\u001b:53");
    await sleep(400);
    const afterEsc = await crossPresent(name);
    await show(name);
    await sleep(400);
    await run("click:700,560");
    await sleep(400);
    const afterOutside = await crossPresent(name);
    let afterRow = null;
    if (name === "popups" && card) {
      await clear(name);
      await show(name);
      await sleep(600);
      const rowControl = Object.entries((await paneEntry(instance, ids.tab, "popups"))?.controls ?? {}).find(([label]) => label.endsWith("/pop3"))?.[1];
      const [rx, ry] = rowControl ? [rowControl[0] + rowControl[2] / 2, rowControl[1] + rowControl[3] / 2] : [card.x + card.width / 2, card.y + card.height - 6 - 16];
      await run(`click:${rx},${ry}`);
      await sleep(400);
      afterRow = await crossPresent(name);
    }
    await clear(name);
    await sleep(300);
    out[name] = { native: !!pane, host: "pane prompts", card, afterEsc, afterOutside, afterRow };
  }
  return out;
}

try {
  app = await launch(resolve(appArg), { data, onboarded: true, files: { "calendar-fixture.json": calendarFixture }, env: { SOLARA_CALENDAR_FIXTURE: "1" } });
  await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devPages" });
  await sleep(5000);
  await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; for (const d of ${JSON.stringify(downloads)}) s.upsertDownload(d); s.setDownloadsOpen(w, false); ac.pages.openInternalPage("downloads", w); return true`);
  await dev("fakeActiveClicks");

  await rep.check("Downloads lists the window's downloads, newest first", async () => {
    const shown = await until(async () => {
      const p = await page();
      return { ok: p?.kind === "downloads" && p.shown.length === 3, p };
    });
    assert.deepEqual(shown.p?.shown, ["d3", "d2", "d1"]);
  });

  await rep.check("typing in the search field filters, Escape clears it", async () => {
    const p = await page();
    await click(frameOf(p, "Search downloads"));
    await sleep(200);
    await dev("type:photo");
    const filtered = await until(async () => {
      const now = await page();
      return { ok: now.query === "photo", now };
    });
    assert.equal(filtered.now.query, "photo");
    assert.deepEqual(filtered.now.shown, ["d2"]);
    await dev("keys:0:\u001b:53");
    const cleared = await until(async () => {
      const now = await page();
      return { ok: now.query === "", now };
    });
    assert.deepEqual(cleared.now.shown, ["d3", "d2", "d1"]);
  });

  await rep.check("✕ removes a download from the list", async () => {
    const p = await page();
    await click(frameOf(p, "remove:d2"));
    const after = await until(async () => {
      const ids = await app.eval(`return ac.store.getState().downloads.map((d) => d.id).join(",")`);
      return { ok: ids === "d3,d1", ids };
    });
    assert.equal(after.ids, "d3,d1");
    assert.equal(await crossRead(app, "removed download ids", (snapshot) => snapshot.downloads.ids.join(","),
      (timeout) => app.eval(`return ac.store.getState().downloads.map((d) => d.id).join(",")`, { timeout })), after.ids);
  });

  await rep.check("Clear All keeps only the running download", async () => {
    const p = await page();
    await click(frameOf(p, "Clear All"));
    const after = await until(async () => {
      const ids = await app.eval(`return ac.store.getState().downloads.map((d) => d.id).join(",")`);
      return { ok: ids === "d3", ids };
    });
    assert.equal(after.ids, "d3");
    assert.equal(await crossRead(app, "remaining download ids", (snapshot) => snapshot.downloads.ids.join(","),
      (timeout) => app.eval(`return ac.store.getState().downloads.map((d) => d.id).join(",")`, { timeout })), after.ids);
  });
  const now = Date.now();
  const sites = ["https://news.example.com/", "https://github.com/solara", "https://en.wikipedia.org/wiki/Sun", "https://apple.example.net/mac"];
  const history = Array.from({ length: 8 }, (_, i) => ({ url: `${sites[i % 4]}?p=${i}`, title: `Page ${i}`, visits: 1, lastVisit: now - i * 5 * 3600_000 }));
  await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.importHistory(s.windows[w].profileId, ${JSON.stringify(history)}); ac.pages.openInternalPage("history", w); return true`);

  await rep.check("History lists every visit, newest first", async () => {
    const shown = await until(async () => {
      const p = await page();
      return { ok: p?.kind === "history" && p.shown.length === 8, p };
    });
    assert.deepEqual(shown.p?.shown, history.map((h) => h.url));
  });

  await rep.check("typing in the search field filters the history", async () => {
    const p = await page();
    await click(frameOf(p, "Search history"));
    await sleep(200);
    await dev("type:wikipedia");
    const filtered = await until(async () => {
      const now = await page();
      return { ok: now.query === "wikipedia" && now.shown.length === 2, now };
    });
    assert.deepEqual(filtered.now.shown, [history[2].url, history[6].url]);
    await dev("keys:0:\u001b:53");
    await until(async () => ({ ok: (await page()).shown.length === 8 }));
  });

  await rep.check("hovering shows a row's checkbox, click selects, shift-click extends, Cancel clears", async () => {
    const rowFrame = (p, url) => frameOf(p, `row:${url}`);
    const ready = await until(async () => {
      const now = await page();
      return { ok: !!rowFrame(now, history[1].url) && !!rowFrame(now, history[3].url), now };
    });
    assert.ok(ready.ok, `row frames: ${ready.now.frames.map((f) => f.label).join(" | ")}`);
    let p = ready.now;
    const first = rowFrame(p, history[1].url);
    await app.eval(`return globalThis.expo.modules.SolaraPages.devPageHover(${JSON.stringify(history[1].url)})`);
    const hovered = await until(async () => {
      const now = await page();
      return { ok: now.frames.some((f) => f.label === "Select" && Math.abs(f.y + f.height / 2 - (first.y + first.height / 2)) < 4), now };
    });
    assert.ok(hovered.ok, "checkbox on hover");
    const box = hovered.now.frames.find((f) => f.label === "Select" && Math.abs(f.y + f.height / 2 - (first.y + first.height / 2)) < 4);
    await click(box);
    await app.eval(`return globalThis.expo.modules.SolaraPages.devPageHover(null)`);
    const one = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 1, now };
    });
    assert.deepEqual(one.now.selected, [history[1].url]);
    p = one.now;
    const third = rowFrame(p, history[3].url);
    await dev(`mouse:down:${third.x + 200},${third.y + third.height / 2},1,${0x20000}`);
    await dev(`mouse:up:${third.x + 200},${third.y + third.height / 2},1,${0x20000}`);
    const range = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 3, now };
    });
    assert.deepEqual(range.now.selected, [history[1].url, history[2].url, history[3].url].sort());
    await click(frameOf(range.now, "Cancel"));
    const none = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 0, now };
    });
    assert.equal(none.now.selected.length, 0);
  });

  await rep.check("Clear Browsing Data… opens the dialog; Clear Data empties the history and closes it", async () => {
    const p = await page();
    await click(frameOf(p, "Clear Browsing Data…"));
    const open = await until(async () => {
      const now = await page();
      return { ok: now.clearOpen && !!frameOf(now, "Clear Data"), now };
    });
    assert.ok(open.ok, "dialog open");
    let last = null;
    const still = await until(async () => {
      const now = frameOf(await page(), "Clear Data");
      const ok = !!now && !!last && JSON.stringify(now) === JSON.stringify(last);
      last = now;
      return { ok, now };
    });
    await click(still.now);
    const cleared = await until(async () => {
      const now = await page();
      return { ok: !now.clearOpen, now };
    }, 20000);
    assert.equal(cleared.now.clearOpen, false, "dialog closed");
    assert.deepEqual(cleared.now.shown, history.slice(1).map((h) => h.url), "the last hour's visit is gone");
  });
  const seeded = await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; const profileId = s.windows[w].profileId; const bar = s.bookmarks.roots[profileId].bar;
    const add = (t) => ac.bookmarks.addBookmark({ profileId, url: "https://" + t + ".example.com/", title: t[0].toUpperCase() + t.slice(1), parentId: bar });
    return ac.bookmarks.addBookmarkFolder({ profileId, title: "Work", parentId: bar }).then((work) =>
      ["alpha", "beta", "gamma", "delta"].reduce((done, t) => done.then((ids) => add(t).then((id) => [...ids, id])), Promise.resolve([])).then((ids) =>
        ac.bookmarks.addBookmark({ profileId, url: "https://reports.example.org/q4", title: "Q4 Report", parentId: work }).then((inner) => {
          ac.pages.openInternalPage("bookmarks", w);
          return JSON.stringify({ bar, work, ids, inner });
        })));`);
  const marks = JSON.parse(seeded);
  const barIds = () => crossRead(app, "bookmark bar order", (snapshot) => snapshot.windows.flatMap((window) => window.bookmarks).find((node) => node.id === marks.bar)?.children.join(",") ?? null,
    (timeout) => app.eval(`const s = ac.store.getState(); return s.bookmarks.nodes[${JSON.stringify(marks.bar)}].children.join(",")`, { timeout }));

  await rep.check("Bookmarks lists the bar's bookmarks and folders", async () => {
    const shown = await until(async () => {
      const p = await page();
      return { ok: p?.kind === "bookmarks" && p.shown.length === 5, p };
    });
    assert.deepEqual(shown.p?.shown, [marks.work, ...marks.ids]);
  });

  await rep.check("the folder tree opens a folder; search finds across folders", async () => {
    let p = await until(async () => {
      const now = await page();
      return { ok: !!frameOf(now, `folder:${marks.work}`), now };
    });
    await click(frameOf(p.now, `folder:${marks.work}`));
    const inWork = await until(async () => {
      const now = await page();
      return { ok: now.folder === marks.work, now };
    });
    assert.deepEqual(inWork.now.shown, [marks.inner]);
    await click(frameOf(inWork.now, "Search bookmarks"));
    await sleep(200);
    await dev("type:report");
    const found = await until(async () => {
      const now = await page();
      return { ok: now.query === "report", now };
    });
    assert.deepEqual(found.now.shown, [marks.inner]);
    await dev("keys:0:\u001b:53");
    p = await until(async () => ({ ok: (await page()).query === "", now: await page() }));
    await click(frameOf(p.now, `folder:${marks.bar}`));
    await until(async () => ({ ok: (await page()).folder === marks.bar }));
  });

  await rep.check("click, ⌘-click and shift-click select; Delete removes with an Undo toast that restores", async () => {
    let p = await until(async () => {
      const now = await page();
      return { ok: marks.ids.every((id) => frameOf(now, `bookmark:${id}`)), now };
    });
    const at = (id) => { const f = frameOf(p.now, `bookmark:${id}`); return `${f.x + 120},${f.y + f.height / 2}`; };
    await dev(`click:${at(marks.ids[0])}`);
    const one = await until(async () => {
      const now = await page();
      return { ok: now?.selected.length === 1, now };
    });
    assert.deepEqual(one.now?.selected, [marks.ids[0]], `tabs: ${await app.eval("return JSON.stringify(Object.values(ac.store.getState().tabs).map((t) => t.url))")}`);
    await sleep(600);
    await dev(`mouse:down:${at(marks.ids[2])},1,${0x100000}`);
    await dev(`mouse:up:${at(marks.ids[2])},1,${0x100000}`);
    const two = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 2, now };
    });
    assert.deepEqual(two.now.selected, [marks.ids[0], marks.ids[2]]);
    await sleep(600);
    await dev(`click:${at(marks.ids[0])}`);
    await sleep(600);
    await dev(`mouse:down:${at(marks.ids[3])},1,${0x20000}`);
    await dev(`mouse:up:${at(marks.ids[3])},1,${0x20000}`);
    const range = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 4, now };
    });
    assert.deepEqual(range.now.selected, marks.ids);
    await click(frameOf(range.now, "Delete"));
    const gone = await until(async () => {
      const now = await page();
      return { ok: now.undo === 4 && now.shown.length === 1, now };
    });
    assert.equal(gone.now.undo, 4, "undo toast");
    assert.equal(await barIds(), marks.work);
    const toast = await until(async () => {
      const now = await page();
      return { ok: !!frameOf(now, "Undo"), now };
    });
    await click(frameOf(toast.now, "Undo"));
    const back = await until(async () => ({ ok: (await barIds()) === [marks.work, ...marks.ids].join(","), now: await page() }));
    assert.ok(back.ok, `bar after undo: ${await barIds()}`);
  });

  await rep.check("dragging a row below another moves it there", async () => {
    const p = await until(async () => {
      const now = await page();
      return { ok: marks.ids.every((id) => frameOf(now, `bookmark:${id}`)), now };
    });
    const from = frameOf(p.now, `bookmark:${marks.ids[0]}`);
    const to = frameOf(p.now, `bookmark:${marks.ids[2]}`);
    await dev(`drag:${from.x + 120},${from.y + from.height / 2};${to.x + 120},${to.y + to.height * 0.8}`);
    const moved = await until(async () => ({ ok: (await barIds()) === [marks.work, marks.ids[1], marks.ids[2], marks.ids[0], marks.ids[3]].join(",") }), 4000);
    assert.ok(moved.ok, `bar after drag: ${await barIds()}`);
  });
  const formPage = async () => (await readPages(app)).find((p) => p.kind === "bookmarkForm") ?? null;
  const bookmarkTitle = (id) => crossRead(app, "bookmark title", (snapshot) => snapshot.windows.flatMap((window) => window.bookmarks).find((node) => node.id === id)?.title ?? null,
    (timeout) => app.eval(`return ac.store.getState().bookmarks.nodes[${JSON.stringify(id)}]?.title ?? null`, { timeout }));
  const bookmarkParent = (id) => crossRead(app, "bookmark parent", (snapshot) => snapshot.windows.flatMap((window) => window.bookmarks).find((node) => node.id === id)?.parentId ?? null,
    (timeout) => app.eval(`return ac.store.getState().bookmarks.nodes[${JSON.stringify(id)}]?.parentId ?? null`, { timeout }));
  const openPopover = async (id) => {
    await app.eval(`const s = ac.store.getState(); ac.pages.bookmarkDialog.getState().set({ kind: "page", windowId: Object.keys(s.windows)[0], bookmarkId: ${JSON.stringify(id)} }); return true`);
    return until(async () => {
      const now = await formPage();
      return { ok: !!now && !!frameOf(now, "Done"), now };
    });
  };
  const dialogOpen = () => crossRead(app, "bookmark form visibility", (snapshot) => snapshot.pages.some((page) => page.kind === "bookmarkForm"),
    (timeout) => app.eval(`return !!ac.pages.bookmarkDialog.getState().open || !!ac.pages.bookmarkEditor.getState().open`, { timeout }), { fields: ["root.pages"] });
  const closed = () => until(async () => ({ ok: !(await dialogOpen()) }));

  await rep.check("the ⌘D popover renames with Return and moves to the picked folder with Done", async () => {
    const id = marks.ids[1];
    let shown = await openPopover(id);
    assert.ok(shown.ok, "popover shown");
    await dev("type:Beta Renamed");
    await dev("keys:0:\r:36");
    assert.ok((await closed()).ok, "closed after Return");
    assert.equal(await bookmarkTitle(id), "Beta Renamed");
    shown = await openPopover(id);
    await click(frameOf(shown.now, `pick:${marks.work}`));
    await until(async () => ({ ok: (await formPage())?.folder === marks.work }));
    await click(frameOf((await formPage()), "Done"));
    assert.ok((await closed()).ok, "closed after Done");
    assert.equal(await bookmarkParent(id), marks.work);
  });

  await rep.check("Esc and a click outside the popover save and close it; Remove deletes", async () => {
    const id = marks.ids[2];
    await openPopover(id);
    await dev("type:Gamma Esc");
    await dev("keys:0:\u001b:53");
    assert.ok((await closed()).ok, "closed after Esc");
    assert.equal(await bookmarkTitle(id), "Gamma Esc");
    await openPopover(id);
    await dev("type:Gamma Outside");
    await dev("click:40,700");
    assert.ok((await closed()).ok, "closed after a click outside");
    assert.equal(await bookmarkTitle(id), "Gamma Outside");
    const shown = await openPopover(id);
    await click(frameOf(shown.now, "Remove"));
    assert.ok((await closed()).ok, "closed after Remove");
    assert.equal(await bookmarkTitle(id), null);
  });

  await rep.check("the editor needs a URL, saves with Return, and Esc or a click outside cancels", async () => {
    const id = marks.ids[3];
    const openEditor = async () => {
      await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; ac.pages.bookmarkEditor.getState().set({ windowId: w, bookmarkId: ${JSON.stringify(id)}, folder: false, profileId: s.windows[w].profileId }); return true`);
      return until(async () => {
        const now = await formPage();
        return { ok: !!now && !!frameOf(now, "URL field"), now };
      });
    };
    let shown = await openEditor();
    assert.ok(shown.ok, "editor shown");
    await click(frameOf(shown.now, "URL field"));
    await dev("keys:1048576:a:0");
    await dev("type: ");
    await until(async () => ({ ok: (await formPage())?.valid === false }));
    assert.equal((await formPage())?.valid, false, "Save off without a URL");
    await dev("keys:0:\r:36");
    await sleep(300);
    assert.equal(await dialogOpen(), true, "Return without a URL keeps it open");
    await dev("keys:1048576:a:0");
    await dev("type:delta.example.net");
    await dev("keys:0:\r:36");
    assert.ok((await closed()).ok, "closed after Return");
    assert.equal(await app.eval(`return ac.store.getState().bookmarks.nodes[${JSON.stringify(id)}]?.url`), "https://delta.example.net/");
    const savedURL = await crossRead(app, "saved bookmark URL", (snapshot) => canonicalURL(snapshot.windows.flatMap((window) => window.bookmarks).find((node) => node.id === id)?.url),
      async (timeout) => canonicalURL(await app.eval(`return ac.store.getState().bookmarks.nodes[${JSON.stringify(id)}]?.url`, { timeout })));
    assert.equal(savedURL, "https://delta.example.net/");
    shown = await openEditor();
    await dev("type:Delta Esc");
    await dev("keys:0:\u001b:53");
    assert.ok((await closed()).ok, "closed after Esc");
    assert.notEqual(await bookmarkTitle(id), "Delta Esc");
    shown = await openEditor();
    await dev("type:Delta Outside");
    await dev("click:40,700");
    assert.ok((await closed()).ok, "closed after a click outside");
    assert.notEqual(await bookmarkTitle(id), "Delta Outside");
  });
  await rep.check("Create a Profile: Return creates it, a preset shares data, Esc and a click outside create nothing", async () => {
    const count = () => crossRead(app, "profile count", (snapshot) => snapshot.profiles.length, (timeout) => app.eval(`return ac.store.getState().profileOrder.length`, { timeout }));
    const open = async (preset) => {
      const pending = app.eval(`const s = ac.store.getState(); globalThis.__created = undefined; ac.actions.createProfile(Object.keys(s.windows)[0], ${JSON.stringify(preset ?? {})}).then((id) => { globalThis.__created = id; }); return true`);
      await pending;
      return until(async () => {
        const all = (await readPages(app));
        return { ok: all.some((p) => p.kind === "createProfile") };
      });
    };
    const created = () => until(async () => ({ ok: (await app.eval(`return globalThis.__created !== undefined`)) }));
    const before = await count();
    assert.ok((await open()).ok, "sheet shown");
    await sleep(300);
    await dev("type:Travel");
    await dev("keys:0:\r:36");
    assert.ok((await created()).ok, "resolved after Return");
    let travel;
    const travelName = await crossRead(app, "created profile name", (snapshot) => snapshot.profiles.find((profile) => profile.id === JSON.parse(travel)?.id)?.name ?? null,
      async (timeout) => {
        travel = await app.eval(`const s = ac.store.getState(); return JSON.stringify(s.profiles[globalThis.__created] ?? null)`, { timeout });
        return JSON.parse(travel)?.name ?? null;
      });
    assert.equal(travelName, "Travel");
    assert.equal(await count(), before + 1);
    await open();
    await sleep(300);
    await dev("keys:0:\u001b:53");
    assert.ok((await created()).ok, "resolved after Esc");
    assert.equal(await app.eval(`return globalThis.__created`), null);
    await open();
    await sleep(300);
    await dev("click:40,700");
    assert.ok((await created()).ok, "resolved after a click outside");
    assert.equal(await app.eval(`return globalThis.__created`), null);
    assert.equal(await count(), before + 1, "nothing made by Esc or the outside click");
    const head = await app.eval(`const s = ac.store.getState(); return s.windows[Object.keys(s.windows)[0]].profileId`);
    await open({ name: "Shared", shareWith: head });
    await sleep(300);
    await dev("keys:0:\r:36");
    assert.ok((await created()).ok, "resolved after Return");
    let shared;
    await crossRead(app, "shared profile", (snapshot) => {
      const profile = snapshot.profiles.find((profile) => profile.name === shared.name);
      return { name: profile?.name ?? null, data: profile?.dataId ?? null, head: snapshot.profiles.find((profile) => profile.id === head)?.dataId ?? null };
    }, async (timeout) => {
      shared = JSON.parse(await app.eval(`const s = ac.store.getState(); const p = s.profiles[globalThis.__created]; return JSON.stringify({ name: p?.name, data: p?.dataId ?? p?.id, head: s.profiles[${JSON.stringify(head)}]?.dataId ?? ${JSON.stringify(head)} })`, { timeout }));
      return { name: shared.name ?? null, data: shared.data ?? null, head: shared.head ?? null };
    });
    assert.equal(shared.name, "Shared");
    assert.equal(shared.data, shared.head, "shares the preset's data");
  });
  const kindPage = async (kind) => (await readPages(app)).find((p) => p.kind === kind) ?? null;
  const calendarRows = async (windowId) => {
    let card;
    await crossRead(app, "calendar hover rows", (snapshot) => {
      const hover = snapshot.windows.find((window) => window.id === windowId)?.hoverCard;
      return hover?.kind === "calendar" ? hover.events : null;
    }, async (timeout) => {
      card = JSON.parse(await app.eval(`return globalThis.expo.modules.SolaraHosted?.sidebarHoverCard?.(${JSON.stringify(windowId)}) ?? "null"`, { timeout }));
      return card?.kind === "calendar" ? card.events : null;
    });
    if (card?.kind === "calendar") return Object.entries(card.events ?? {}).map(([label, [x, y, width, height]]) => ({ label, x, y, width, height }));
    return (await kindPage("calendarPreview"))?.frames ?? null;
  };
  const alertButtons = async () => {
    const page = await kindPage("meetingAlert");
    if (page) return { join: frameOf(page, "Join"), ignore: frameOf(page, "Ignore") };
    const win = await app.eval(`return globalThis.expo.modules.SolaraCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window)`);
    const f = await readFrame(app, win, "MeetingAlertFrameView");
    if (!f.found || f.height <= 100) return null;
    return { join: { x: f.x + 150 - 50, y: f.y + f.height - 27 - 10, width: 100, height: 20 }, ignore: { x: f.x + 283 - 6, y: f.y + 19 - 6, width: 12, height: 12 } };
  };

  await rep.check("the calendar preview lists today's events and a click shows the calendar tab", async () => {
    const ids = JSON.parse(await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0];
      const before = s.windows[w].activeTabIds[s.windows[w].profileId];
      const tab = s.newTab(w, { url: "https://calendar.google.com/calendar/u/0/r", pinned: true, background: true });
      return JSON.stringify({ w, tab, before })`));
    await until(async () => ({ ok: (await app.eval(`return ac.pages.calendar.getState().events.length`)) >= 2 }), 5000);
    await crossRead(app, "native calendar event count", (snapshot) => snapshot.calendar.count,
      (timeout) => app.eval(`return ac.pages.calendar.getState().events.length`, { timeout }));
    await app.eval(`ac.pages.setSidebarUi({ hover: { windowId: ${JSON.stringify(ids.w)}, kind: "tab", id: ${JSON.stringify(ids.tab)}, anchor: { x: 10, y: 120, width: 240, height: 32 } } }); return true`);
    const shown = await until(async () => {
      const now = await calendarRows(ids.w);
      return { ok: !!now && now.some((f) => f.label.startsWith("event:standup")), now };
    });
    assert.ok(shown.ok, "preview with the standup row");
    await sleep(800);
    const row = shown.now.find((f) => f.label.startsWith("event:review"));
    const hit = await click(row);
    const active = await until(async () => ({ ok: (await app.eval(`const s = ac.store.getState(); const w = s.windows[${JSON.stringify(ids.w)}]; return w.activeTabIds[w.profileId]`)) === ids.tab }));
    assert.ok(active.ok, `the calendar tab is shown (clicked ${JSON.stringify(row)} on ${hit})`);
    assert.equal(await crossRead(app, "calendar tab selection", (snapshot) => snapshot.windows.find((window) => window.id === ids.w)?.selectedTabId,
      (timeout) => app.eval(`const s = ac.store.getState(); const w = s.windows[${JSON.stringify(ids.w)}]; return w.activeTabIds[w.profileId]`, { timeout })), ids.tab);
    await app.eval(`ac.pages.setSidebarUi({ hover: null }); return true`);
  });

  await rep.check("the meeting alert's Join opens the meeting and Ignore dismisses it", async () => {
    const show = () => app.eval(`const e = ac.pages.calendar.getState().events.find((x) => x.id === "standup"); ac.store.getState().setFocusedWindow?.(Object.keys(ac.store.getState().windows)[0]); ac.pages.meetingAlert.setState({ event: e }); return !!e`);
    assert.equal(await show(), true, "fixture event");
    await crossValue(app, "native standup fixture event", (snapshot) => snapshot.calendar.eventIds.includes("standup"), true);
    let shown = await until(async () => {
      const now = await alertButtons();
      return { ok: !!now?.join, now };
    });
    assert.ok(shown.ok, `alert with Join (focused: ${await app.eval("return ac.store.getState().ui.focusedWindowId")})`);
    const tabsBefore = await app.eval(`return Object.keys(ac.store.getState().tabs).length`);
    await sleep(800);
    const beforeJoin = await crossRead(app, "meeting tabs before Join", (snapshot) => snapshot.tabs.map((tab) => tab.id).sort(),
      async (timeout) => (await app.eval(`return Object.keys(ac.store.getState().tabs)`, { timeout })).sort(), { fields: ["tabs.url"] });
    await click(shown.now.join);
    const opened = await until(async () => ({ ok: (await app.eval(`return Object.values(ac.store.getState().tabs).some((t) => (t.url || "").includes("zoom.us"))`)) }), 4000);
    assert.ok(opened.ok, `a zoom tab (tabs ${tabsBefore} → ${await app.eval("return Object.keys(ac.store.getState().tabs).length")})`);
    await untilSnapshot(app, "fresh meeting tab URL", async (snapshot, remaining) => freshMeetingTab(snapshot, beforeJoin, await app.eval(`return Object.values(ac.store.getState().tabs).map(({ id, url }) => ({ id, url }))`, { timeout: remaining() })), 3000, { fields: ["tabs.url"] });
    await show();
    shown = await until(async () => {
      const now = await alertButtons();
      return { ok: !!now?.ignore, now };
    });
    await sleep(800);
    await click(shown.now.ignore);
    const gone = await until(async () => ({ ok: (await app.eval(`return ac.pages.meetingAlert.getState().event === null`)) }));
    assert.ok(gone.ok, "dismissed");
    await untilSnapshot(app, "meeting alert dismissed", (snapshot) => !snapshot.pages.some((page) => page.kind === "meetingAlert"), 3000, { fields: ["root.pages"] });
  });

  await rep.check("the page prompts open in a native frame; the six stay up on Esc and a click on the page, blocked pop-ups close on it and open a row's pop-up", async () => {
    nativePrompts = await promptOutcomes(app);
    const unmeasured = [];
    for (const name of PROMPT_NAMES) {
      const got = nativePrompts[name];
      if (got.native === null) {
        unmeasured.push(`${name}: ${got.host}`);
        continue;
      }
      assert.ok(got.native, `${name}: in a native pane prompt frame, got ${got.host}`);
      if (name === "popups") continue;
      assert.equal(got.afterEsc, true, `${name}: still asked after Esc`);
      assert.equal(got.afterOutside, true, `${name}: still asked after a click on the page`);
    }
    assert.equal(nativePrompts.popups.afterOutside, false, "pop-ups: closed by a click on the page");
    assert.equal(nativePrompts.popups.afterRow, "pop1,pop2", "pop-ups: the last row opens pop3 and the rest stay listed");
    return { hosts: Object.fromEntries(PROMPT_NAMES.map((name) => [name, nativePrompts[name].host])), unmeasured };
  });

  await rep.check("a click on the native frame's Allow within 0.5 s of the prompt is ignored, and 0.8 s later it answers", async () => {
    const ids = JSON.parse(await app.eval(`const C = globalThis.expo.modules.SolaraCEF; const s = ac.store.getState(); const w = Object.keys(s.windows)[0];
      const tab = s.newTab(w, { url: ${JSON.stringify(`${base}/guard`)} });
      return C.chromeWindows().then((ws) => JSON.stringify({ tab, win: ws.find((x) => x.hasRoot).window }))`));
    await sleep(2000);
    await panePromptsHosted(app);
    const tab = JSON.stringify(ids.tab);
    const asked = (timeout) => app.eval(`return !!ac.pageState.getState().pages[${tab}]?.permission`, { timeout });
    const shownPermission = (snapshot) => snapshot.windows.map((window) => window.paneOverlays?.tabs?.[ids.tab]?.permission)
      .find((entry) => entry && !entry.hidden && entry.card) ?? null;
    const choices = (entry) => Object.entries(entry?.controls ?? {}).filter(([label]) => label === "Allow" || label === "Don't Allow")
      .map(([, [x, y, width, height]]) => ({ x, y, width, height, key: entry.key })).sort((a, b) => a.x - b.x);
    await askFromPage(app, `${base}/guard`, "Notification.requestPermission(); true");
    const shown = choices(shownPermission(await untilSnapshot(app, "the prompt's buttons",
      (snapshot) => choices(shownPermission(snapshot)).length >= 2, 2000, { fields: ["windows.paneOverlays"] })));
    assert.ok(shown.length >= 2, `the prompt's buttons: ${JSON.stringify(shown)}`);
    const allow = shown[shown.length - 1];
    await click(allow);
    await sleep(300);
    assert.equal(await asked(), true, "the early click is ignored");
    await untilSnapshot(app, "early permission remains visible", async (snapshot, remaining) => !!shownPermission(snapshot) && await asked(remaining()), 2000, { fields: ["windows.paneOverlays"] });
    await sleep(800);
    const current = choices(shownPermission(await untilSnapshot(app, "the permission prompt's Allow before the later click",
      (snapshot) => choices(shownPermission(snapshot)).length >= 2, 2000, { fields: ["windows.paneOverlays"] })));
    const later = current[current.length - 1];
    assert.equal(later.key, allow.key, "the later click meets the prompt the early click met, not a rebuilt one whose guard restarted");
    await click(later);
    const answered = await until(async () => ({ ok: !(await asked()) }), 2000);
    assert.ok(answered.ok, `the later click answers it (early Allow ${JSON.stringify(allow)}, later Allow ${JSON.stringify(later)})`);
    assert.equal(await crossRead(app, "permission pane dismissed", (snapshot) => !!shownPermission(snapshot), asked, { fields: ["windows.paneOverlays"] }), false);
    return { early: allow, later, moved: !nearFrame(allow, later) };
  });
  await rep.check("bookmark drags perform no haptics in a hidden instance", async () => {
    const snapshot = await app.snapshot({ fields: ["root.haptics"] }, { timeout: 1000 });
    assert.equal(snapshot.haptics.performed, 0, "hidden bookmark drags perform no haptics");
    return snapshot.haptics;
  });
} finally {
  await app?.quit();
  if (!keep && !rep.failed.length) for (const dir of [data, files]) rmSync(dir, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}

const shellData = join(scratch, "shell-data");
let shell = null;
try {
  shell = await launch(resolve(appArg), { data: shellData, onboarded: true, files: { "calendar-fixture.json": calendarFixture }, env: { SOLARA_NATIVE_SHELL: "1", SOLARA_CALENDAR_FIXTURE: "1" } });
  await shell.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devViewFrame" });
  await sleep(4000);
  await rep.check("under the native shell the meeting alert is in a native frame at RN's spot; Join opens the meeting, ✕ dismisses it", async () => {
    const win = await shell.eval(`return globalThis.expo.modules.SolaraCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window)`);
    const run = (action) => shell.eval(`return globalThis.expo.modules.SolaraCEF.devWindow(${win}, ${JSON.stringify(action)})`);
    const press = async (x, y) => {
      await run(`mouse:down:${x},${y}`);
      await sleep(60);
      await run(`mouse:up:${x},${y}`);
    };
    await run("fakeActiveClicks");
    const show = () => shell.eval(`const e = ac.pages.calendar.getState().events.find((x) => x.id === "standup"); ac.store.getState().setFocusedWindow?.(Object.keys(ac.store.getState().windows)[0]); ac.pages.meetingAlert.setState({ event: e }); return !!e`);
    await until(async () => ({ ok: (await shell.eval(`return ac.pages.calendar.getState().events.length`)) > 0 }), 5000);
    await crossRead(shell, "shell native calendar event count", (snapshot) => snapshot.calendar.count,
      (timeout) => shell.eval(`return ac.pages.calendar.getState().events.length`, { timeout }));
    assert.equal(await show(), true, "fixture event");
    await crossValue(shell, "shell native standup fixture event", (snapshot) => snapshot.calendar.eventIds.includes("standup"), true);
    const frameNow = async () => await readFrame(shell, win, "MeetingAlertFrameView");
    const shown = await until(async () => {
      const f = await frameNow();
      return { ok: f.found && f.height > 100, f };
    }, 3000);
    assert.ok(shown.ok, `a native frame: ${JSON.stringify(shown.f)}`);
    const windowWidth = await crossRead(shell, "meeting window width", (snapshot) => snapshot.windows.find((window) => window.chromeWindowNumber === win)?.frame.width,
      async (timeout) => {
        const width = await shell.eval(`return globalThis.expo.modules.SolaraCEF.devWindow(${win}, "winfo").then((s) => JSON.parse(s).frame)`, { timeout });
        const value = Number(String(width).replace(/[{}]/g, "").split(",")[2]);
        assert.ok(Number.isFinite(value), "the meeting window width is finite");
        return value;
      });
    assert.equal(shown.f.width, 300);
    assert.equal(shown.f.y, 52, "52 from the top, as RN");
    assert.ok(Math.abs(shown.f.x - Math.max(8, windowWidth - 300 - 14)) <= 1, `x ${shown.f.x} for a ${windowWidth} wide window`);
    const pages = (await readPages(shell));
    assert.ok(!pages.some((p) => p.kind === "meetingAlert"), "no RN-hosted card as well");
    await sleep(800);
    const beforeJoin = await crossRead(shell, "shell meeting tabs before Join", (snapshot) => snapshot.tabs.map((tab) => tab.id).sort(),
      async (timeout) => (await shell.eval(`return Object.keys(ac.store.getState().tabs)`, { timeout })).sort(), { fields: ["tabs.url"] });
    await press(shown.f.x + 150, shown.f.y + shown.f.height - 27);
    const opened = await until(async () => ({ ok: (await shell.eval(`return Object.values(ac.store.getState().tabs).some((t) => (t.url || "").includes("zoom.us"))`)) }), 4000);
    assert.ok(opened.ok, "Join opened the meeting");
    await untilSnapshot(shell, "fresh shell meeting tab URL", async (snapshot, remaining) => freshMeetingTab(snapshot, beforeJoin, await shell.eval(`return Object.values(ac.store.getState().tabs).map(({ id, url }) => ({ id, url }))`, { timeout: remaining() })), 3000, { fields: ["tabs.url"] });
    await show();
    const again = await until(async () => {
      const f = await frameNow();
      return { ok: f.found && f.height > 100, f };
    }, 3000);
    await sleep(800);
    await press(again.f.x + 283, again.f.y + 19);
    const gone = await until(async () => ({ ok: (await shell.eval(`return ac.pages.meetingAlert.getState().event === null`)) && !(await frameNow()).found }), 3000);
    assert.ok(gone.ok, "✕ dismissed it and the frame went away");
  });
} finally {
  await shell?.quit();
  if (!keep && !rep.failed.length) rmSync(shellData, { recursive: true, force: true });
}
server.close();
process.exit(rep.summary() ? 0 : 1);
