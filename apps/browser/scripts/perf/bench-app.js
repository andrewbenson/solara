const P = globalThis.acPerf;
if (!P) throw new Error("perf probe is off (no perf-probe file in the data folder)");
const store = ac.store;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const S = () => store.getState();
const windowId = () => S().ui.focusedWindowId;
const activeId = () => {
  const s = S();
  const w = s.windows[windowId()];
  return w.activeTabIds[w.profileId];
};

function timed(fn) {
  const t = P.now();
  P.batch(fn);
  return P.now() - t;
}

async function until(test, timeoutMs, step = 25) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (test()) return true;
    await sleep(step);
  }
  return false;
}

async function quiet(ms = 400) {
  await until(() => !S().live[activeId()]?.isLoading, 8000);
  await sleep(ms);
}

const total = (counter) => Object.values(counter ?? {}).reduce((a, b) => a + (typeof b === "number" ? b : 0), 0);
const historyLoaded = () => {
  const s = S();
  return s.profileOrder.filter((id) => !id.startsWith("incognito:")).every((id) => s.historyReady[id]);
};

async function settled(quietMs = 3000, timeoutMs = 30000) {
  const end = Date.now() + timeoutMs;
  if (!(await until(historyLoaded, timeoutMs))) return false;
  while (Date.now() < end) {
    P.reset();
    await sleep(quietMs);
    const read = P.read();
    if (!Object.keys(read.writes).length && !total(read.storeUpdates) && !read.commits) return true;
  }
  return false;
}

function mergeStats(into, from) {
  for (const [key, value] of Object.entries(from)) {
    if (key === "since") into[key] ??= value;
    else if (typeof value === "number") into[key] = (into[key] ?? 0) + value;
    else if (Array.isArray(value)) (into[key] ??= []).push(...value);
    else if (value && typeof value === "object") mergeStats((into[key] ??= {}), value);
  }
  return into;
}

async function movePointer(w, point) {
  let pending;
  const ms = timed(() => (pending = ac.shell.devSetPointer(w, point)));
  if (!(await pending)) throw new Error("native pointer driver unavailable");
  return ms;
}

async function nativeHoverRows(rows, from) {
  const w = windowId();
  const drag = globalThis.expo.modules.SolaraSidebarDrag;
  const hosted = globalThis.expo.modules.SolaraHosted;
  const off = { x: S().windows[w].frame[2] - 20, y: 20 };
  await movePointer(w, off);
  await drag.scrollTo(w, 0);
  await sleep(300);
  const probe = () => JSON.parse(drag.probe(w));
  const initial = probe();
  if (!initial?.viewport) throw new Error("no native sidebar viewport");
  const list = initial.items.filter((item) => item.kind === "row" && item.key.startsWith("t:") && item.h > 0).slice(from, from + rows);
  const notTabRow = list.find((item) => item.kind !== "row" || !item.key.startsWith("t:"));
  if (notTabRow) throw new Error(`hover would cross ${notTabRow.kind} ${notTabRow.key}, not a tab row`);
  if (list.length < 2) throw new Error(`only ${list.length} hoverable native rows`);
  return {
    w, list,
    async point(item) {
      let rect = await hosted.sidebarRowFrame(w, item.key);
      const state = probe();
      const viewport = state.viewport;
      if (!rect) throw new Error(`no native row rect for ${item.key}`);
      if (rect.y < viewport.y + 4 || rect.y + rect.height > viewport.y + viewport.h - 4) {
        await movePointer(w, off);
        await drag.scrollTo(w, state.scrollY + rect.y - viewport.y - 8);
        await sleep(100);
        rect = await hosted.sidebarRowFrame(w, item.key);
      }
      if (!rect || rect.y < viewport.y || rect.y + rect.height > viewport.y + viewport.h)
        throw new Error(`native row ${item.key} is outside the sidebar viewport`);
      return { x: rect.x + Math.min(60, rect.width / 2), y: rect.y + rect.height / 2 };
    },
    off,
  };
}

const scenarios = {
  async startup() {
    await until(() => P.marks.firstWindow, 20000);
    const info = ac.shell.systemInfo();
    const read = P.read();
    return { marks: { ...P.marks, processStart: info.processStart ?? null, firstCommit: P.firstCommit }, stats: read };
  },

  async idle({ seconds = 10 } = {}) {
    await quiet(1000);
    const calm = await settled();
    P.reset();
    await sleep(seconds * 1000);
    return { settled: calm, stats: P.read() };
  },

  async typing({ query = "github.com/facebook/react/pull", gapMs = 60 } = {}) {
    const w = windowId();
    await quiet();
    S().closePanel(w);
    await sleep(200);
    S().openPanel(w);
    const id = `${w}:panel`;
    if (!(await until(() => ac.omnibox.get(id), 3000))) throw new Error("omnibox driver missing");
    await sleep(500);
    const driver = ac.omnibox.get(id);
    P.reset();
    const keys = [];
    for (let i = 1; i <= query.length; i++) {
      keys.push(timed(() => driver.type(query.slice(0, i))));
      await sleep(gapMs);
    }
    const stats = P.read();
    const items = driver.state().items.length;
    S().closePanel(w);
    await sleep(200);
    return { keys, items, stats };
  },

  async switchTabs({ count = 12 } = {}) {
    const w = windowId();
    const s = S();
    const view = s.windows[w].tabIds.filter((id) => s.tabs[id].profileId === s.windows[w].profileId && !s.tabs[id].pinned);
    const ids = view.slice(30, 30 + count);
    const start = activeId();
    for (const id of ids) {
      timed(() => {
        S().setSelection(w, []);
        S().activate(id);
      });
      await sleep(250);
    }
    await quiet();
    await settled(1200, 10000);
    P.reset();
    const steps = [];
    for (const id of ids) {
      steps.push(
        timed(() => {
          S().setSelection(w, []);
          S().activate(id);
        }),
      );
      await sleep(150);
    }
    const stats = P.read();
    await sleep(1200);
    const saved = P.read();
    stats.writes = saved.writes;
    stats.writeBytes = saved.writeBytes;
    stats.writeMs = saved.writeMs;
    timed(() => S().activate(start));
    await quiet();
    return { steps, stats };
  },

  async openClose({ count = 20, origin } = {}) {
    const w = windowId();
    await quiet();
    P.reset();
    const open = [];
    const ids = [];
    for (let i = 0; i < count; i++) {
      let id;
      open.push(timed(() => (id = S().newTab(w, { url: `${origin}/p/new-${i}-${Date.now()}` }))));
      ids.push(typeof id === "string" ? id : id?.id ?? activeId());
      await sleep(150);
    }
    await quiet();
    const openStats = P.read();
    P.reset();
    const close = [];
    for (const id of ids.reverse()) {
      close.push(timed(() => S().closeTab(id)));
      await sleep(150);
    }
    await sleep(500);
    return { open, close, openStats, closeStats: P.read() };
  },

  async scroll({ distance = 2400, steps = 60 } = {}) {
    await quiet();
    const w = windowId();
    const drag = globalThis.expo.modules.SolaraSidebarDrag;
    await drag.scrollTo(w, 0);
    if (!JSON.parse(drag.probe(w))?.viewport) throw new Error("no native sidebar viewport");
    await sleep(300);
    await settled();
    P.reset();
    for (let i = 1; i <= steps; i++) {
      await drag.scrollTo(w, (distance * i) / steps);
      await sleep(16);
    }
    for (let i = steps - 1; i >= 0; i--) {
      await drag.scrollTo(w, (distance * i) / steps);
      await sleep(16);
    }
    await sleep(300);
    return { stats: P.read() };
  },

  async pageLoad({ origin, runs = 3 } = {}) {
    const results = [];
    for (let r = 0; r < runs; r++) {
      await quiet(600);
      const tab = activeId();
      P.reset();
      const t0 = Date.now();
      timed(() => S().navigate(tab, `${origin}/heavy?run=${r}-${Date.now()}`));
      await until(() => S().live[tab]?.isLoading, 3000, 5);
      await until(() => !S().live[tab]?.isLoading, 15000, 10);
      const loadMs = Date.now() - t0;
      await sleep(1000);
      results.push({ loadMs, stats: P.read() });
    }
    return { runs: results };
  },

  async hover({ rows = 24, gapMs = 60, from = 8 } = {}) {
    await quiet();
    const native = await nativeHoverRows(rows, from);
    const steps = [];
    const stats = {};
    try {
      for (const item of native.list) {
        const point = await native.point(item);
        P.reset();
        steps.push(await movePointer(native.w, point));
        await sleep(gapMs);
        mergeStats(stats, P.read());
      }
      P.reset();
      steps.push(await movePointer(native.w, native.off));
      await sleep(800);
      mergeStats(stats, P.read());
      return { steps, stats };
    } finally {
      await movePointer(native.w, native.off);
      await ac.shell.devSetPointer(native.w, null);
    }
  },

  async profileSwipe({ settleMs = 1500 } = {}) {
    const w = windowId();
    await quiet();
    const out = [];
    for (const command of ["nextProfile", "previousProfile"]) {
      P.reset();
      const ms = timed(() => ac.runCommand({ command, arg: null, windowId: w }));
      await sleep(settleMs);
      out.push({ command, ms, profile: S().windows[w].profileId, stats: P.read() });
    }
    return { runs: out };
  },

  async storeUpdate({ count = 60 } = {}) {
    await quiet();
    const s = S();
    const w = windowId();
    const front = activeId();
    const pages = ac.nativePages;
    const native = pages.ownsLive();
    const candidates = s.windows[w].tabIds.filter((id) => id !== front && s.tabs[id]?.profileId === s.windows[w].profileId && !s.tabs[id].pinned);
    const bg = candidates.find((id) => s.live[id] && (!native || pages.facts(id)?.ready)) ?? candidates[0];
    if (!bg || (!native && !s.live[bg])) throw new Error("no loaded background tab for live-fact churn");
    if (native && (!pages.facts(bg)?.ready || S().live[bg]?.isLoading !== false)) {
      S().activate(bg);
      try {
        if (!(await until(() => pages.facts(bg)?.ready && S().live[bg]?.isLoading === false, 15000)))
          throw new Error(`native background page ${bg} did not settle`);
        await sleep(500);
      } finally {
        S().activate(front);
      }
      await quiet(800);
    }
    const update = (isLoading) => {
      if (!native) return S().updateLive(bg, { isLoading });
      const facts = pages.facts(bg);
      const live = S().live[bg];
      const tab = S().tabs[bg];
      if (!facts || !live || !tab) throw new Error(`native background page ${bg} disappeared`);
      const out = pages.report(bg, { type: "navigation", generation: facts.generation, url: tab.url, title: tab.title,
        isLoading, canGoBack: !!live.canGoBack, canGoForward: !!live.canGoForward, themeColor: live.themeColor ?? null });
      if (!out || out.error) throw new Error(`native page report refused: ${out?.error ?? "no response"}`);
      if (S().live[bg]?.isLoading !== isLoading) throw new Error(`native loading report for ${bg} was not applied`);
    };
    P.reset();
    const steps = [];
    try {
      for (let i = 0; i < count; i++) {
        steps.push(timed(() => update(i % 2 === 0)));
        await sleep(5);
      }
      timed(() => update(false));
      return { steps, stats: P.read() };
    } finally {
      if (S().live[bg]?.isLoading) update(false);
    }
  },

  async idleLate({ waitSeconds = 20, seconds = 10 } = {}) {
    await sleep(waitSeconds * 1000);
    return scenarios.idle({ seconds });
  },

  async activeTrail({ count = 4, origin } = {}) {
    const w = windowId();
    await quiet();
    const trail = [];
    const t0 = Date.now();
    let last = activeId();
    const stop = store.subscribe((st, prev) => {
      const now = activeId();
      if (now !== last) trail.push({ t: Date.now() - t0, from: last, to: now });
      last = now;
      const a = st.windows[w];
      const b = prev.windows[w];
      if (a !== b && a && b) {
        const fields = Object.keys(a).filter((k) => a[k] !== b[k]);
        if (!fields.includes("activeTabIds") || now === activeId()) trail.push({ t: Date.now() - t0, window: fields.join(",") });
      }
    });
    const opened = [];
    for (let i = 0; i < count; i++) {
      trail.push({ t: Date.now() - t0, open: i });
      timed(() => opened.push(S().newTab(w, { url: `${origin}/p/trail-${i}-${Date.now()}` })));
      await sleep(600);
    }
    await sleep(1000);
    stop();
    for (const id of opened) if (typeof id === "string") S().closeTab(id);
    return { opened, trail };
  },

  async slowOpen({ count = 10, slowMs = 100, gapMs = 300, origin } = {}) {
    const w = windowId();
    await quiet();
    const stop = store.subscribe((s, prev) => {
      if (s.windows === prev.windows) return;
      const end = P.now() + slowMs;
      while (P.now() < end);
    });
    let switches = 0;
    const count0 = store.subscribe((s, prev) => {
      const a = s.windows[w]?.activeTabIds[s.windows[w].profileId];
      const b = prev.windows[w]?.activeTabIds[prev.windows[w].profileId];
      if (a !== b) switches++;
    });
    const opened = [];
    for (let i = 0; i < count; i++) {
      timed(() => opened.push(S().newTab(w, { url: `${origin}/p/slow-${i}-${Date.now()}` })));
      await sleep(gapMs);
    }
    await sleep(3000);
    stop();
    count0();
    const settledSwitches = switches;
    for (const id of opened) if (typeof id === "string") S().closeTab(id);
    return { opened: opened.length, switches: settledSwitches };
  },

  async persistence() {
    const s = S();
    const time = (value) => {
      const t = P.now();
      const json = JSON.stringify(value);
      return { ms: P.now() - t, bytes: json.length };
    };
    const tabs = Object.values(s.tabs);
    return {
      history: time({ version: 2, history: s.history }),
      bookmarks: time({ version: 2, bookmarks: s.bookmarks }),
      session: time({ version: 2, profiles: s.profiles, settings: s.settings, windows: Object.values(s.windows), tabs, groups: Object.values(s.groups), closedTabs: s.closedTabs, closedWindows: s.closedWindows }),
      counts: { tabs: tabs.length, history: Object.values(s.history).reduce((n, h) => n + h.length, 0), bookmarks: Object.keys(s.bookmarks.nodes).length },
    };
  },
};

Object.assign(scenarios, renderScenarios());
Object.assign(scenarios, censusScenarios());

scenarios.traced = function ({ scenario, ...options }) {
  P.traceTimers = true;
  return scenarios[scenario](options).finally(() => (P.traceTimers = false));
};

function renderScenarios() {
  const tabsInView = () => {
    const s = S();
    const w = s.windows[windowId()];
    return w.tabIds.filter((id) => s.tabs[id]?.profileId === w.profileId);
  };
  const settle = (ms = 1500) => sleep(ms).then(() => P.read());
  return {
    async mark({ settleMs = 0 } = {}) {
      if (settleMs) await quiet(settleMs);
      P.reset();
      return true;
    },
    async read({ settleMs = 1000 } = {}) {
      return { stats: await settle(settleMs) };
    },
    async wake({ gapMs = 400 } = {}) {
      const start = activeId();
      for (const id of tabsInView()) {
        timed(() => S().activate(id));
        await sleep(gapMs);
      }
      timed(() => S().activate(start));
      await quiet(1000);
      return tabsInView().filter((id) => S().live[id]).length;
    },
    async tabSwitch({ count = 10, gapMs = 300 } = {}) {
      const s = S();
      const ids = tabsInView().filter((id) => !s.tabs[id].pinned).slice(0, count);
      const start = activeId();
      await quiet(800);
      P.reset();
      const steps = [];
      for (const id of ids) {
        steps.push(timed(() => S().activate(id)));
        await sleep(gapMs);
      }
      const stats = await settle(800);
      timed(() => S().activate(start));
      await quiet(800);
      return { steps, stats };
    },
    async openCloseTab({ count = 5, origin, gapMs = 400 } = {}) {
      const w = windowId();
      await quiet(800);
      P.reset();
      const ids = [];
      const open = [];
      for (let i = 0; i < count; i++) {
        let id;
        open.push(timed(() => (id = S().newTab(w, { url: `${origin}/p/r-${i}-${Date.now()}` }))));
        ids.push(typeof id === "string" ? id : activeId());
        await sleep(gapMs);
      }
      const openStats = await settle(1000);
      P.reset();
      const close = [];
      for (const id of ids.reverse()) {
        close.push(timed(() => S().closeTab(id)));
        await sleep(gapMs);
      }
      return { open, close, openStats, closeStats: await settle(1000) };
    },
    async typeIn({ bar = "panel", query = "github.com/facebook/react", gapMs = 60, origin } = {}) {
      const w = windowId();
      await quiet(600);
      let tab = null;
      if (bar === "panel") S().openPanel(w);
      else tab = S().newTab(w);
      const id = `${w}:${bar}`;
      if (!(await until(() => ac.omnibox.get(id), 4000))) throw new Error(`no omnibox driver ${id}`);
      await sleep(800);
      const driver = ac.omnibox.get(id);
      P.reset();
      const keys = [];
      for (let i = 1; i <= query.length; i++) {
        keys.push(timed(() => driver.type(query.slice(0, i))));
        await sleep(gapMs);
      }
      const stats = await settle(600);
      if (bar === "panel") S().closePanel(w);
      else if (typeof tab === "string") S().closeTab(tab);
      await sleep(400);
      return { keys, stats };
    },
    async openBackground({ path, origin, settleMs = 2500 } = {}) {
      const w = windowId();
      const id = S().newTab(w, { url: `${origin}${path}`, background: true });
      await sleep(settleMs);
      return typeof id === "string" ? id : null;
    },
    async openActive({ path, origin, settleMs = 2000 } = {}) {
      const w = windowId();
      const id = S().newTab(w, { url: `${origin}${path}` });
      await quiet(settleMs);
      return typeof id === "string" ? id : null;
    },
    async closeTab({ id } = {}) {
      if (id && S().tabs[id]) S().closeTab(id);
      await sleep(400);
      return true;
    },
    async bgLoad({ origin } = {}) {
      await quiet(800);
      const s = S();
      const id = tabsInView().find((t) => t !== activeId() && !s.tabs[t].pinned && s.live[t]);
      if (!id) throw new Error("no loaded background tab");
      P.reset();
      S().navigate(id, `${origin}/heavy?run=bg-${Date.now()}`);
      return { stats: await settle(4000) };
    },
    async idleFor({ seconds = 60 } = {}) {
      await quiet(1500);
      await settled();
      P.reset();
      await sleep(seconds * 1000);
      return { stats: P.read() };
    },
    async split({ origin } = {}) {
      const w = windowId();
      await quiet(800);
      P.reset();
      const ms = timed(() => S().openSplitPane(w, { url: `${origin}/p/split-${Date.now()}` }));
      const stats = await settle(2000);
      const splitId = Object.keys(S().splits).find((k) => S().splits[k].windowId === w);
      P.reset();
      const closeMs = splitId ? timed(() => S().separateSplit(splitId)) : null;
      const closeStats = await settle(1500);
      return { ms, stats, closeMs, closeStats };
    },
    async sidebar() {
      const w = windowId();
      await quiet(800);
      P.reset();
      const ms = timed(() => S().toggleSidebar(w));
      const stats = await settle(1200);
      P.reset();
      const openMs = timed(() => S().toggleSidebar(w));
      const openStats = await settle(1200);
      return { ms, stats, openMs, openStats };
    },
    async downloads({ updates = 40, gapMs = 100 } = {}) {
      const total = 50_000_000;
      const d = { id: `bench-${Date.now()}`, url: "http://127.0.0.1/file.zip", filename: "file.zip", path: "", state: "downloading", paused: false, received: 0, total, speed: 0, mimeType: "application/zip", profile: S().windows[windowId()].profileId };
      await quiet(800);
      P.reset();
      const steps = [];
      for (let i = 0; i <= updates; i++) {
        const received = Math.round((total * i) / updates);
        steps.push(timed(() => S().upsertDownload({ ...d, received, speed: 5_000_000, state: i === updates ? "complete" : "downloading" })));
        await sleep(gapMs);
      }
      const stats = await settle(1000);
      S().removeDownload(d.id);
      S().setDownloadsOpen(windowId(), false);
      await sleep(400);
      return { steps, stats };
    },
  };
}


function censusScenarios() {
  const total = (o) => Object.values(o ?? {}).reduce((a, b) => a + (typeof b === "number" ? b : 0), 0);
  const summary = (r, ms) => ({
    ms,
    commits: r.commits,
    renders: total(r.renders),
    wasted: total(r.wasted),
    hooks: total(r.hooks),
    hostUpdates: r.hostUpdates,
    storeUpdates: total(r.storeUpdates),
    subNotified: total(r.subNotified),
    selectors: total(r.selectorCalls),
    timers: total(r.timersScheduled),
    renderMs: total(r.renderMs),
    commitMs: r.commitMs,
    taskMs: total(r.taskMs),
  });
  const merge = (into, from) => {
    for (const key of Object.keys(from)) {
      const v = from[key];
      if (typeof v === "number") into[key] = (into[key] ?? 0) + v;
      else if (v && typeof v === "object" && !Array.isArray(v)) merge((into[key] ??= {}), v);
    }
    return into;
  };
  const SKIP = new Set(["commitTimes", "commitTaskLog", "taskLog", "since"]);
  async function action(act, settleMs, sink) {
    P.reset();
    const ms = timed(act);
    await sleep(settleMs);
    const r = P.read();
    for (const k of SKIP) delete r[k];
    sink.per.push(summary(r, ms));
    merge(sink.stats, r);
    return r;
  }
  const sink = () => ({ per: [], stats: {} });
  const tabsInView = () => {
    const s = S();
    const w = s.windows[windowId()];
    return w.tabIds.filter((id) => s.tabs[id]?.profileId === w.profileId);
  };
  const run = (command, arg = null) => () => ac.runCommand({ command, arg, windowId: windowId() });
  const panelId = (w) => `${w}:${S().settings.addressBar === "sidebar" ? "sidebar" : "panel"}`;
  async function driverOf(id) {
    if (!(await until(() => ac.omnibox.get(id), 4000))) throw new Error(`no omnibox driver ${id}`);
    await sleep(800);
    return ac.omnibox.get(id);
  }
  function untilStore(test, timeoutMs) {
    return new Promise((resolve) => {
      if (test(S())) return resolve(true);
      let timer;
      const off = store.subscribe((st) => {
        if (!test(st)) return;
        off();
        clearTimeout(timer);
        resolve(true);
      });
      timer = setTimeout(() => {
        off();
        resolve(false);
      }, timeoutMs);
    });
  }
  return {
    async cenStartup() {
      await until(() => P.marks.firstWindow, 20000);
      const r = P.read();
      for (const k of SKIP) delete r[k];
      return { per: [summary(r, 0)], stats: r, marks: { ...P.marks, firstCommit: P.firstCommit } };
    },
    async cenNewTab({ count = 4 } = {}) {
      const out = sink();
      for (let i = 0; i < count; i++) {
        await quiet(500);
        let id;
        await action(() => {
          ac.runCommand({ command: "newTab", arg: null, windowId: windowId() });
          id = activeId();
        }, 900, out);
        await until(() => ac.omnibox.get(`${windowId()}:hero`), 3000);
        S().closeTab(id);
        await sleep(500);
      }
      return out;
    },
    async cenTypeHero({ query = "github.com/facebook/react", gapMs = 120 } = {}) {
      const w = windowId();
      await quiet(600);
      const id = S().newTab(w);
      const driver = await driverOf(`${w}:hero`);
      const out = sink();
      for (let i = 1; i <= query.length; i++) await action(() => driver.type(query.slice(0, i)), gapMs, out);
      if (typeof id === "string") S().closeTab(id);
      await sleep(400);
      return out;
    },
    async cenPanel({ query = "github.com/facebook/react", gapMs = 120, repeats = 3 } = {}) {
      const w = windowId();
      await quiet(600);
      const open = sink();
      const close = sink();
      const keys = sink();
      for (let r = 0; r < repeats; r++) {
        await action(run("focusCommandBar"), 900, open);
        const driver = await driverOf(panelId(w));
        if (r === 0) for (let i = 1; i <= query.length; i++) await action(() => driver.type(query.slice(0, i)), gapMs, keys);
        await action(() => driver.key("Escape"), 700, close);
        await quiet(300);
      }
      return { open, keys, close };
    },
    async cenEnter({ origin, repeats = 3 } = {}) {
      const w = windowId();
      const enter = sink();
      const load = sink();
      for (let r = 0; r < repeats; r++) {
        await quiet(600);
        S().openPanel(w, "");
        const driver = await driverOf(panelId(w));
        driver.type(`${origin}/heavy?run=cen-${r}-${Date.now()}`);
        await sleep(600);
        const tab = activeId();
        P.reset();
        const ms = timed(() => driver.submit());
        await sleep(150);
        let rd = P.read();
        for (const k of SKIP) delete rd[k];
        enter.per.push(summary(rd, ms));
        merge(enter.stats, rd);
        P.reset();
        await untilStore((st) => !st.live[tab]?.isLoading, 15000);
        await sleep(1500);
        rd = P.read();
        for (const k of SKIP) delete rd[k];
        load.per.push(summary(rd, 0));
        merge(load.stats, rd);
      }
      return { enter, load };
    },
    async cenSwitch({ count = 10, gapMs = 300 } = {}) {
      const w = windowId();
      const s = S();
      const ids = tabsInView().filter((id) => !s.tabs[id].pinned).slice(0, count);
      const start = activeId();
      await quiet(800);
      const click = sink();
      for (const id of ids) {
        await action(() => {
          S().setSelection(w, []);
          S().activate(id);
        }, gapMs, click);
      }
      const shortcut = sink();
      for (let i = 0; i < count; i++) await action(run(i % 2 ? "nextTab" : "selectTab", i % 2 ? null : String(1 + (i % 5))), gapMs, shortcut);
      timed(() => S().activate(start));
      await quiet(800);
      return { click, shortcut };
    },
    async cenHover({ rows = 14, from = 0, gapMs = 150 } = {}) {
      await quiet(800);
      const native = await nativeHoverRows(rows, from);
      const out = sink();
      async function sample(point) {
        P.reset();
        const ms = await movePointer(native.w, point);
        await sleep(gapMs);
        const read = P.read();
        for (const key of SKIP) delete read[key];
        out.per.push(summary(read, ms));
        merge(out.stats, read);
      }
      try {
        for (const item of native.list) await sample(await native.point(item));
        await sample(native.off);
        return out;
      } finally {
        await movePointer(native.w, native.off);
        await ac.shell.devSetPointer(native.w, null);
      }
    },
    async cenBgLoad({ origin, repeats = 2 } = {}) {
      const out = sink();
      for (let r = 0; r < repeats; r++) {
        await quiet(800);
        const s = S();
        const id = tabsInView().find((t) => t !== activeId() && !s.tabs[t].pinned && s.live[t]);
        if (!id) throw new Error("no loaded background tab");
        await action(() => S().navigate(id, `${origin}/heavy?run=cenbg-${r}-${Date.now()}`), 3500, out);
      }
      return out;
    },
  };
}

globalThis.acBench = {
  names: Object.keys(scenarios),
  run: (name, options) => scenarios[name](options ?? {}),
};
return globalThis.acBench.names;
