import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const { create } = require("zustand");

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const ticks = async (n = 20) => { for (let i = 0; i < n; i++) await new Promise((done) => setImmediate(done)); };

function load(url, imports, globals = {}) {
  const module = { exports: {} };
  const source = readFileSync(url, "utf8");
  runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
    exports: module.exports,
    require: (name) => { if (name in imports) return imports[name]; throw new Error(`Unexpected import: ${name}`); },
    AbortController,
    console,
    setTimeout,
    clearTimeout,
    ...globals,
  });
  return module.exports;
}

const htmlBookmarks = { type: "folder", title: "", children: [{ type: "folder", role: "toolbar", title: "Bar", children: [{ type: "url", title: "Link", url: "https://link.example/" }] }] };
const emptyResult = (over = {}) => ({ failed: [], warnings: [], spaces: [], history: [], favorites: [], tabs: [], credentials: [], ...over });

function bridge({ browsers, importData, importSafariDirect, importSafariExport, liveCommand, confirm, discardImported, chooseImportFile, importBookmarksHTML, readDiaTabs, historyWrite, faviconWrite, bookmarkWrite, profiles = [] }) {
  const created = [];
  const bookmarkWrites = [];
  const bookmarkFailures = [];
  const discarded = [];
  const written = [];
  const nativeWrites = [];
  const historyWrites = [];
  const faviconWrites = [];
  const openedTabs = [];
  const restored = [];
  const state = {
    profileOrder: profiles.map((p) => p.id),
    profiles: Object.fromEntries(profiles.map((p) => [p.id, p])),
    ui: { focusOrder: [] },
    windows: {},
    windowOrder: [],
    settings: { defaultProfileId: "existing" },
    bookmarks: { roots: { existing: { bar: "bar", other: "other" } }, nodes: { bar: { kind: "folder", id: "bar", children: [] }, other: { kind: "folder", id: "other", children: [] } } },
    history: {},
    createProfile: (p) => { created.push(p.name); const id = `new-${created.length}`; state.profiles[id] = { id, name: p.name }; state.profileOrder.push(id); return id; },
    createWindow: () => "window",
    newTab: (windowId, tab) => openedTabs.push({ windowId, ...tab }),
  };
  const useBrowser = { getState: () => state };
  const model = { engineProfile: (id) => id, isIncognitoProfile: () => false };
  const history = load(new URL("../../../store/history.ts", import.meta.url), {
    "@solara/settings": {
      nativeImportHistoryRows: (...args) => { historyWrites.push(args); return historyWrite?.(...args) ?? Promise.resolve(); },
      nativeDeleteHistoryUrls: async () => {},
    },
    "./model": model,
    "./safeLibraryEdits": {},
  }).createHistorySlice((change) => Object.assign(state, change(state)));
  Object.assign(state, history);
  const api = {
    listBrowsers: async () => browsers,
    importData,
    importSafariDirect,
    importSafariExport,
    readDiaTabs,
    listExtensions: async () => [],
    forgetUnlockedKeys: () => {},
    discardImported: (token) => { discarded.push(token); return discardImported?.(token); },
    writeImported: async (token) => { written.push(token); return { cookies: 0, addresses: 0, cards: 0 }; },
    chooseImportFile: chooseImportFile ?? (async () => null),
    importBookmarksHTML,
  };
  const settings = { publishSettingsTopic: () => {}, liveCommand: liveCommand ?? (async () => null) };
  const shell = { confirm: confirm ?? (async () => ({ confirmed: false })), closeWindow: () => {} };
  const nativeStore = {
    nativeSafeMode: () => false,
    nativeOwnsWorkspace: () => true,
    nativeWrite: (command) => { nativeWrites.push(command); return { result: { tabs: 0, skipped: 0 } }; },
    writeState: () => {},
  };
  const favicons = load(new URL("../../../lib/favicons.ts", import.meta.url), {
    "../store/nativeStore": nativeStore,
    "@solara/solaracore": {},
    "@solara/settings": { nativeStoreFavicon: (...args) => { faviconWrites.push(args); return faviconWrite?.(...args) ?? Promise.resolve(); } },
    "@solara/shell": shell,
    react: {},
    zustand: { create },
    "../components/layout/pageState": {},
    "../store/browser": { useBrowser, batchStoreUpdates: (change) => change() },
    "../store/model": model,
    "../store/settings": { DEFAULT_PROFILE_ID: "existing" },
    "./webviews": {},
  });
  const module = { importModule: () => api };
  const writer = {
    BookmarkConditionFailed: class extends Error {},
    submitBookmarks: async (profileId, mutations) => {
      bookmarkWrites.push([profileId, mutations]);
      await bookmarkWrite?.(profileId, mutations);
      return mutations.map(() => null);
    },
    bookmarkWriter: { addBookmarkTree: async () => [] },
    reportBookmarkFailure: (error) => bookmarkFailures.push(String(error)),
  };
  const apply = load(new URL("../../import/apply.ts", import.meta.url), {
    "@solara/shell": shell,
    "@solara/solaracore": { savePassword: async () => true },
    "../../lib/bookmarkGroups": { addGroupsFromDrafts: () => ({ made: [], skipped: 0 }) },
    "../../lib/bookmarkWriter": writer,
    "../../lib/favicons": favicons,
    "../../store/browser": { useBrowser },
    "../../store/model": { engineProfile: (id) => id, isIncognitoProfile: () => false },
    "../../store/pageKeys": { openPages: () => new Set(), pageKey: (url) => url, pinnedPages: () => new Set(), tilePages: () => new Set() },
    "../../store/tabs": { withNewTab: () => {} },
    "./module": module,
    "../../sync/engine": { adoptProfileTheme: () => {} },
    "./arcTheme": { parseArcTheme: () => null },
    "@solara/settings": settings,
    "../../store/nativeStore": nativeStore,
    "@solara/store": { encodeCommand: (name, args) => ({ name, args }) },
  });
  const handlers = load(new URL("./import.ts", import.meta.url), {
    "@solara/shell": shell,
    "@solara/settings": settings,
    "../../../lib/bookmarkGroups": { allArcHolders: () => ["holder"], restoreArcFoldersSettled: async (...args) => { restored.push(args); return []; } },
    "../../../lib/bookmarkWriter": writer,
    "../../../store/nativeStore": nativeStore,
    "../../../store/browser": { useBrowser },
    "../../../store/draftGroups": { MAX_DRAFT_LINKS: 500 },
    "../../../store/model": { plural: (n, w) => `${n} ${w}` },
    "../../onboarding/state": {},
    "../../import/apply": apply,
    "../../import/module": module,
    "../windows": { takePreferredImportSource: () => null },
  }).importHandlers;
  return { handlers, created, discarded, written, nativeWrites, historyWrites, faviconWrites, openedTabs, restored, state, bookmarkWrites, bookmarkFailures };
}

const runRequest = (over = {}) => ({ runId: "run", browserId: "chrome", profileIds: ["first"], spaceIds: [], kinds: ["bookmarks", "cookies"], target: "existing", withoutKey: false, ...over });
const chrome = { id: "chrome", name: "Chrome", family: "chromium", profiles: [{ id: "first", name: "First" }, { id: "second", name: "Second" }] };

test("the drain waits for the live folder command an Arc space import started", async () => {
  const called = deferred();
  const held = deferred();
  const arc = { id: "arc", name: "Arc", family: "arc", sidebar: "arc", profiles: [{ id: "p", name: "P", spaces: [{ id: "s1", name: "Work" }] }] };
  const space = { id: "s1", name: "Work", pinned: [{ type: "folder", title: "Pull Requests", role: "liveGitHubPullRequests", children: [] }], tabs: [] };
  const fixture = bridge({
    browsers: [arc],
    importData: async () => emptyResult({ spaces: [space] }),
    liveCommand: (name) => { called.resolve(name); return held.promise; },
  });
  await fixture.handlers["import.listBrowsers"]();
  const run = fixture.handlers["import.run"](runRequest({ browserId: "arc", profileIds: [], spaceIds: ["s1"], kinds: ["tabs"] }));
  assert.equal(await called.promise, "importFolder");
  let drained = false;
  const drain = fixture.handlers["import.cancelAndDrain"]().then(() => { drained = true; });
  await run;
  await ticks();
  assert.equal(drained, false, "the drain acknowledged while the live folder command was still running");
  held.resolve(null);
  await drain;
});

test("an import call from a session opened before the drain is refused after a new session opens", async () => {
  const fixture = bridge({
    browsers: [chrome],
    importSafariExport: async () => ({ bookmarks: { type: "folder", title: "", children: [] }, profiles: [], tabs: [], credentials: [] }),
  });
  const stale = fixture.handlers["import.open"]();
  await fixture.handlers["import.cancelAndDrain"]();
  const fresh = fixture.handlers["import.open"]();
  assert.notEqual(stale.session, undefined, "import.open names its session");
  assert.notEqual(stale.session, fresh.session);
  const old = await fixture.handlers["import.safariExport"]("/export.zip", "joined", stale.session);
  assert.equal(old.cancelled, true, "the abandoned session's export was applied");
  const current = await fixture.handlers["import.safariExport"]("/export.zip", "existing", fresh.session);
  assert.equal(current.cancelled, undefined, "a Settings import opened after the drain still runs");
});

test("a cancel during the new-profile prompt creates no profile", async () => {
  const asked = deferred();
  const answer = deferred();
  const fixture = bridge({
    browsers: [chrome],
    profiles: [{ id: "existing", name: "Existing" }, { id: "other", name: "Second" }],
    importData: async (_, id) => emptyResult({ profile: chrome.profiles.find((p) => p.id === id) }),
    confirm: () => { asked.resolve(); return answer.promise; },
  });
  await fixture.handlers["import.listBrowsers"]();
  const run = fixture.handlers["import.run"](runRequest({ profileIds: ["first", "second"], kinds: ["bookmarks"] }));
  await asked.promise;
  const drain = fixture.handlers["import.cancelAndDrain"]();
  answer.resolve({ confirmed: true });
  const result = await run;
  await drain;
  assert.equal(result.cancelled, true);
  assert.deepEqual(fixture.created, [], "the cancelled import created a profile");
});

for (const kind of ["safariDirect", "run"]) {
  test(`a ${kind} read that lands after the drain discards its vault entry`, async () => {
    const entered = deferred();
    const release = deferred();
    const read = async (value) => { entered.resolve(); await release.promise; return value; };
    const fixture = bridge({
      browsers: [chrome],
      importSafariDirect: () => read({ bookmarks: { type: "folder", title: "", children: [] }, profiles: [], tabs: [], credentials: [], vaultToken: "vault-safari" }),
      importData: () => read(emptyResult({ vaultToken: "vault-chrome" })),
    });
    await fixture.handlers["import.listBrowsers"]();
    const pending = kind === "run" ? fixture.handlers["import.run"](runRequest()) : fixture.handlers["import.safariDirect"]("existing", true);
    await entered.promise;
    const drain = fixture.handlers["import.cancelAndDrain"]();
    release.resolve();
    assert.equal((await pending).cancelled, true);
    await drain;
    assert.deepEqual(fixture.written, []);
    assert.deepEqual(fixture.discarded, [kind === "run" ? "vault-chrome" : "vault-safari"], "the late read's vault entry outlived the drain");
  });
}

for (const entry of ["run", "runDia", "safariExport", "safariDirect", "bookmarksHtml"]) {
  test(`${entry} refuses revoked and legacy sessions after a drain`, async () => {
    let reads = 0;
    const fixture = bridge({
      browsers: [chrome],
      importData: async () => { reads++; return emptyResult(); },
      importSafariExport: async () => { reads++; return { profiles: [], tabs: [], credentials: [] }; },
      importSafariDirect: async () => { reads++; return { profiles: [], tabs: [], credentials: [] }; },
      chooseImportFile: async () => { reads++; return null; },
    });
    await fixture.handlers["import.listBrowsers"]();
    const stale = fixture.handlers["import.open"]();
    await fixture.handlers["import.cancelAndDrain"]();
    fixture.handlers["import.open"]();
    const args = {
      run: [runRequest()],
      runDia: [{ profileIds: [], target: "existing", pinned: true, open: true }],
      safariExport: ["/export.zip", "existing"],
      safariDirect: ["existing", true],
      bookmarksHtml: ["existing"],
    }[entry];
    for (const session of [stale.session, undefined]) {
      const result = await fixture.handlers[`import.${entry}`](...args, session);
      assert.equal(result.cancelled, true);
    }
    assert.equal(reads, 0);
    assert.deepEqual(fixture.nativeWrites, []);
  });
}

test("a late Safari export discards its vault before the drain resolves", async () => {
  const entered = deferred();
  const release = deferred();
  const discarding = deferred();
  const discarded = deferred();
  const fixture = bridge({
    browsers: [chrome],
    importSafariExport: async () => { entered.resolve(); await release.promise; return { profiles: [], tabs: [], credentials: [], vaultToken: "vault-export" }; },
    discardImported: async () => { discarding.resolve(); await discarded.promise; },
  });
  const opened = fixture.handlers["import.open"]();
  const pending = fixture.handlers["import.safariExport"]("/export.zip", "existing", opened.session);
  await entered.promise;
  let drained = false;
  const drain = fixture.handlers["import.cancelAndDrain"]().then(() => { drained = true; });
  release.resolve();
  await discarding.promise;
  await ticks();
  assert.equal(drained, false);
  discarded.resolve();
  assert.equal((await pending).cancelled, true);
  await drain;
  assert.deepEqual(fixture.discarded, ["vault-export"]);
  assert.deepEqual(fixture.written, []);
});

for (const phase of ["dialog", "read"]) {
  test(`bookmarks cancellation after the ${phase} prevents application`, async () => {
    const entered = deferred();
    const release = deferred();
    let reads = 0;
    const fixture = bridge({
      browsers: [chrome],
      chooseImportFile: async () => { if (phase === "dialog") { entered.resolve(); await release.promise; } return "/bookmarks.html"; },
      importBookmarksHTML: async () => { reads++; if (phase === "read") { entered.resolve(); await release.promise; } return htmlBookmarks; },
    });
    const opened = fixture.handlers["import.open"]();
    const pending = fixture.handlers["import.bookmarksHtml"]("existing", opened.session);
    await entered.promise;
    const drain = fixture.handlers["import.cancelAndDrain"]();
    fixture.handlers["import.open"]();
    release.resolve();
    assert.equal((await pending).cancelled, true);
    await drain;
    assert.equal(reads, phase === "dialog" ? 0 : 1);
    assert.deepEqual(fixture.nativeWrites, []);
    assert.deepEqual(fixture.bookmarkWrites, []);
  });
}

for (const outcome of ["accepted", "refused"]) {
  test(`a bookmarks HTML import cancelled while its write is pending reports cancelled when the write is ${outcome}`, async () => {
    const held = deferred();
    const fixture = bridge({ browsers: [chrome], chooseImportFile: async () => "/bookmarks.html", importBookmarksHTML: async () => htmlBookmarks, bookmarkWrite: () => held.promise });
    const opened = fixture.handlers["import.open"]();
    const pending = fixture.handlers["import.bookmarksHtml"]("existing", opened.session);
    for (let i = 0; i < 50 && !fixture.bookmarkWrites.length; i++) await ticks(1);
    assert.equal(fixture.bookmarkWrites.length, 1);
    const drain = fixture.handlers["import.cancelAndDrain"]();
    if (outcome === "accepted") held.resolve();
    else held.reject(new Error("journal write failed"));
    await drain;
    assert.equal((await pending).cancelled, true);
  });
}

test("a bookmarks HTML import goes through the writer, and a refused write is a bookmarks failure, not an invalid file", async () => {
  let refuse = false;
  const fixture = bridge({
    browsers: [chrome],
    chooseImportFile: async () => "/bookmarks.html",
    importBookmarksHTML: async () => htmlBookmarks,
    bookmarkWrite: async () => { if (refuse) throw new Error("journal write failed"); },
  });
  const opened = fixture.handlers["import.open"]();
  const done = await fixture.handlers["import.bookmarksHtml"]("existing", opened.session);
  assert.equal(done.counts.bookmarks, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(fixture.bookmarkWrites.map(([profileId, mutations]) => [profileId, mutations.map((m) => m.method)]))), [["existing", ["expectChildren", "addBookmarkTree"]]]);
  refuse = true;
  const refused = await fixture.handlers["import.bookmarksHtml"]("existing", opened.session);
  assert.equal(refused.error, undefined);
  assert.deepEqual([refused.counts.bookmarks, [...refused.failed]], [0, ["bookmarks"]]);
  assert.deepEqual(fixture.bookmarkFailures, ["Error: journal write failed"]);
});

test("a rejected live folder command does not fail the Arc import or drain", async () => {
  const arc = { id: "arc", name: "Arc", family: "arc", sidebar: "arc", profiles: [{ id: "p", name: "P", spaces: [{ id: "s1", name: "Work" }] }] };
  const space = { id: "s1", name: "Work", pinned: [{ type: "folder", title: "Pull Requests", role: "liveGitHubPullRequests", children: [] }], tabs: [] };
  const fixture = bridge({ browsers: [arc], importData: async () => emptyResult({ spaces: [space] }), liveCommand: async () => { throw new Error("Unavailable"); } });
  await fixture.handlers["import.listBrowsers"]();
  const result = await fixture.handlers["import.run"](runRequest({ browserId: "arc", profileIds: [], spaceIds: ["s1"], kinds: ["tabs"] }));
  assert.equal(result.cancelled, undefined);
  assert.equal(result.failures.length, 0);
  assert.equal(result.status.tabs, "done");
  await fixture.handlers["import.cancelAndDrain"]();
});

test("a fresh session cannot start an import while a drain is active", async () => {
  const entered = deferred();
  const release = deferred();
  const fixture = bridge({ browsers: [chrome], importData: async () => { entered.resolve(); await release.promise; return emptyResult(); } });
  await fixture.handlers["import.listBrowsers"]();
  const pending = fixture.handlers["import.run"](runRequest());
  await entered.promise;
  const drain = fixture.handlers["import.cancelAndDrain"]();
  const opened = fixture.handlers["import.open"]();
  const refused = fixture.handlers["import.run"](runRequest(), opened.session);
  release.resolve();
  assert.equal((await refused).cancelled, true);
  assert.equal((await pending).cancelled, true);
  await drain;
  assert.deepEqual(fixture.nativeWrites, []);
});

for (const entry of ["run", "runDia", "safariDirect", "bookmarksHtml"]) {
  test(`${entry} works with a fresh Settings session after a drain`, async () => {
    const fixture = bridge({
      browsers: [chrome],
      importData: async () => emptyResult(),
      importSafariDirect: async () => ({ profiles: [], tabs: [], credentials: [] }),
      chooseImportFile: async () => "/bookmarks.html",
      importBookmarksHTML: async () => ({ children: [] }),
      readDiaTabs: async () => ({ profiles: [{ id: "first", name: "First", pinned: [], tabs: [] }], windowCount: 1 }),
    });
    fixture.handlers["import.open"]();
    await fixture.handlers["import.cancelAndDrain"]();
    const opened = fixture.handlers["import.open"]();
    assert.equal(opened.available, true);
    await fixture.handlers["import.listBrowsers"]();
    if (entry === "runDia") await fixture.handlers["import.readDia"]();
    const args = {
      run: [runRequest()],
      runDia: [{ profileIds: ["first"], target: "existing", pinned: true, open: true }],
      safariDirect: ["existing", true],
      bookmarksHtml: ["existing"],
    }[entry];
    const result = await fixture.handlers[`import.${entry}`](...args, opened.session);
    assert.equal(result.cancelled, undefined);
    assert.equal(result.error, undefined);
    assert.equal(result.counts.tabs, 0);
    assert.equal((result.failures ?? result.failed).length, 0);
  });
}

for (const entry of ["run", "safariExport", "safariDirect"]) {
  for (const fails of [false, true]) {
    test(`${entry} drains a completed import's held production history write${fails ? " even when it rejects" : ""}`, async () => {
      const held = deferred();
      const history = [{ url: "https://history.test/", title: "History", visits: 2, lastVisit: 100 }];
      const safari = { profiles: [{ name: "", history }], tabs: [], credentials: [] };
      const fixture = bridge({
        browsers: [chrome],
        importData: async () => emptyResult({ history }),
        importSafariExport: async () => safari,
        importSafariDirect: async () => safari,
        historyWrite: () => held.promise,
      });
      await fixture.handlers["import.listBrowsers"]();
      const result = await (entry === "run"
        ? fixture.handlers["import.run"](runRequest({ kinds: ["history"] }))
        : entry === "safariExport" ? fixture.handlers["import.safariExport"]("/export.zip", "existing")
        : fixture.handlers["import.safariDirect"]("existing", false));
      assert.equal(result.counts.history, 1);
      assert.equal(fixture.state.history.existing[0].url, history[0].url);
      assert.equal(fixture.historyWrites.length, 1);
      let drained = false;
      const drain = fixture.handlers["import.cancelAndDrain"]().then(() => { drained = true; });
      try {
        await ticks();
        assert.equal(drained, false, "the drain acknowledged while the native history write was pending");
        if (fails) held.reject(new Error("History unavailable"));
        else held.resolve();
        await drain;
        assert.equal(drained, true);
        assert.equal(result.cancelled, undefined);
        assert.equal((result.failures ?? result.failed).length, 0);
      } finally {
        held.resolve();
        await drain;
      }
    });
  }
}

for (const entry of ["run", "safariExport", "safariDirect"]) {
  test(`${entry} cancelled while its bookmarks are being written applies nothing after them and discards its vault`, async () => {
    const held = deferred();
    const history = [{ url: "https://history.test/", title: "History", visits: 2, lastVisit: 100 }];
    const safari = { bookmarks: htmlBookmarks, profiles: [{ name: "", history }], tabs: [], credentials: [], vaultToken: `vault-${entry}` };
    const fixture = bridge({
      browsers: [chrome],
      importData: async () => emptyResult({ history, bookmarks: htmlBookmarks, vaultToken: `vault-${entry}` }),
      importSafariExport: async () => safari,
      importSafariDirect: async () => safari,
      bookmarkWrite: () => held.promise,
    });
    await fixture.handlers["import.listBrowsers"]();
    const pending = entry === "run"
      ? fixture.handlers["import.run"](runRequest({ kinds: ["bookmarks", "history"] }))
      : entry === "safariExport" ? fixture.handlers["import.safariExport"]("/export.zip", "existing")
      : fixture.handlers["import.safariDirect"]("existing", false);
    for (let i = 0; i < 50 && !fixture.bookmarkWrites.length; i++) await ticks(1);
    assert.equal(fixture.bookmarkWrites.length, 1, "the bookmark write started");
    const drain = fixture.handlers["import.cancelAndDrain"]();
    held.resolve();
    await drain;
    assert.equal((await pending).cancelled, true);
    assert.equal(fixture.historyWrites.length, 0, "no history after the cancel");
    assert.deepEqual([...fixture.discarded], [`vault-${entry}`]);
  });
}

for (const entry of ["run", "arc", "runDia"]) {
  for (const fails of [false, true]) {
    test(`${entry} drains every production favicon write after import completion${fails ? " even when the first rejects" : ""}`, async () => {
      const first = deferred();
      const second = deferred();
      const tabs = ["https://first.test/", "https://second.test/"].map((url) => ({ url, title: url, pinned: false }));
      const favicons = tabs.map(({ url }) => ({ page: url, icon: `${url}favicon.png`, png: "AAAA" }));
      const arc = { id: "arc", name: "Arc", family: "arc", sidebar: "arc", profiles: [{ id: "p", name: "P", spaces: [{ id: "s", name: "Work" }] }] };
      let writes = 0;
      const fixture = bridge({
        browsers: entry === "arc" ? [arc] : [chrome],
        importData: async () => emptyResult({ tabs: entry === "arc" ? [] : tabs, favicons, spaces: entry === "arc" ? [{ id: "s", name: "Work", pinned: [], tabs }] : [] }),
        readDiaTabs: async () => ({ profiles: [{ id: "first", name: "First", pinned: [], tabs }], windowCount: 1, favicons }),
        faviconWrite: () => ++writes === 1 ? first.promise : second.promise,
      });
      await fixture.handlers["import.listBrowsers"]();
      if (entry === "runDia") await fixture.handlers["import.readDia"]();
      const result = await (entry === "runDia"
        ? fixture.handlers["import.runDia"]({ profileIds: ["first"], target: "existing", pinned: false, open: true })
        : fixture.handlers["import.run"](runRequest(entry === "arc"
          ? { browserId: "arc", profileIds: [], spaceIds: ["s"], kinds: ["tabs"] }
          : { kinds: ["tabs"] })));
      assert.equal(result.cancelled, undefined);
      assert.equal(result.failures.length, 0);
      assert.equal(fixture.faviconWrites.length, 1, "the sequential loop has submitted only its first write");
      assert.equal(fixture.faviconWrites[0][1], tabs[0].url);
      let drained = false;
      const drain = fixture.handlers["import.cancelAndDrain"]().then(() => { drained = true; });
      try {
        await ticks();
        assert.equal(drained, false, "the drain acknowledged while the first native favicon write was pending");
        if (fails) first.reject(new Error("Favicon unavailable"));
        else first.resolve();
        await ticks();
        assert.equal(fixture.faviconWrites.length, 2);
        assert.equal(fixture.faviconWrites[1][1], tabs[1].url);
        assert.equal(drained, false, "the drain acknowledged while the second native favicon write was pending");
        second.resolve();
        await drain;
        assert.equal(drained, true);
      } finally {
        first.resolve();
        second.resolve();
        await drain;
      }
    });
  }
}

for (const entry of ["openInWebStore", "restoreArcFolders"]) {
  test(`${entry} refuses revoked and legacy sessions while admitting a fresh session`, async () => {
    const fixture = bridge({ browsers: [chrome] });
    const stale = fixture.handlers["import.open"]();
    await fixture.handlers["import.cancelAndDrain"]();
    const fresh = fixture.handlers["import.open"]();
    const args = entry === "openInWebStore" ? ["existing", ["https://chromewebstore.google.com/detail/example"]] : [];
    const mutations = entry === "openInWebStore" ? fixture.openedTabs : fixture.restored;
    for (const session of [stale.session, undefined]) {
      await fixture.handlers[`import.${entry}`](...args, session);
      assert.equal(mutations.length, 0, "a refused session mutated the workspace");
    }
    await fixture.handlers[`import.${entry}`](...args, fresh.session);
    assert.equal(mutations.length, 1, "a fresh session can still mutate the workspace");
  });
}
