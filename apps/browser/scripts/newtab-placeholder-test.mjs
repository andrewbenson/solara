import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { crashReportsForInstance, launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node apps/browser/scripts/newtab-placeholder-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const data = join(output, "data");
const evidence = [];
const results = [];
let app;
const save = () => writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
const run = (body, timeout = 2000) => app.eval(body, { timeout });
const nativeState = async () => (await run(`
  const module = expo.modules.SolaraStoreAdapter;
  const status = module.status();
  if (!status.active || status.frozen !== false) throw new Error("native workspace ownership required");
  return JSON.parse(module.snapshot());
`)).data;
const active = (state, id = "w1") => state.windows[id]?.activeTabIds[state.windows[id].profileId];
const pageIds = () => run("return expo.modules.SolaraTabPool.devPageIds();");
const engineKeys = async () => (await run("return expo.modules.SolaraCEF.tabStrips();")).strips.flatMap((strip) => strip.tabs.map((tab) => tab.key));
const watchPagesAround = (action, ms) => run(`
  const pool = expo.modules.SolaraTabPool;
  const seen = new Set();
  const started = Date.now();
  const firstSeen = {};
  return new Promise((done) => {
    const tick = () => pool.devPageIds().then((ids) => {
      ids.forEach((id) => {
        if (!seen.has(id)) firstSeen[id] = Date.now() - started;
        seen.add(id);
      });
      if (Date.now() - started < ${ms}) setTimeout(tick, 10);
      else done({ seen: [...seen], firstSeen });
    });
    tick().then(() => ${action});
  });
`, ms + 4000);
const key = (key, keyCode, after = 0, modifiers = ["command"]) => ({ key, keyCode, modifiers, after });
const postKeys = (windowId, presses) => run(`return expo.modules.SolaraApp.devPostKeys(${JSON.stringify(windowId)}, ${JSON.stringify(presses)});`);
const placeholders = (state, windowId = "w1") => state.windows[windowId]?.tabIds.filter((id) => state.tabs[id]?.newTabPlaceholder === true) ?? [];
async function closePlaceholders(windowId = "w1") {
  for (const id of placeholders(await nativeState(), windowId)) {
    await run(`ac.store.getState().activate(${JSON.stringify(id)}); return true;`);
    await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand(${JSON.stringify(windowId)}, "closeTab", null);`);
    await until(`${id} closed`, async () => !(await nativeState()).tabs[id]);
  }
}
const firstResponder = async (windowId = "w1") => (await app.snapshot({ windowId }, { timeout: 2000 })).windows.find((window) => window.id === windowId)?.firstResponder ?? "";
const heroState = (tabId, windowId = "w1") => run(`
  const fiber = acPerf.findFibers("NativeNewTabHero", 50).find(fiber => fiber.memoizedProps?.windowId === ${JSON.stringify(windowId)} && fiber.memoizedProps?.tabId === ${JSON.stringify(tabId)});
  for (let hook = fiber?.memoizedState; hook; hook = hook.next) {
    const ref = hook.memoizedState?.current;
    if (ref && typeof ref.driverState === "function") return ref.driverState().then(JSON.parse);
  }
  return null;
`);
async function until(label, accept, ms = 12000) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() + 500 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    last = await accept();
    if (last) return last;
    await sleep(40);
  }
  throw new Error(`${label}: deadline exceeded`);
}
let partial = null;
async function check(name, fn) {
  const started = Date.now();
  partial = {};
  try {
    const details = await fn();
    evidence.push({ name, passed: true, details });
    results.push(true);
    console.log(`PASS ${name} ${Date.now() - started}ms`);
  } catch (error) {
    evidence.push({ name, passed: false, error: String(error?.stack ?? error), partial });
    results.push(false);
    console.log(`FAIL ${name} ${Date.now() - started}ms: ${error?.message ?? error}`);
  }
  save();
}
const fixture = session({
  windows: [
    { id: "w1", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } },
    { id: "w2", frame: [160, 120, 900, 700], activeTabIds: { default: "z" } },
  ],
  tabs: [
    { id: "a", url: "about:blank#a", title: "A", lastActiveAt: 2 },
    { id: "b", url: "about:blank#b", title: "B", lastActiveAt: 1 },
    { id: "z", windowId: "w2", url: "about:blank#z", title: "Z" },
  ],
  settings: { warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false, newTabOpens: "page", newTabPosition: "bottom", shareTabsAcrossWindows: false, searchSuggestions: false },
});
const ready = (fresh) => `return !!ac.store && !!globalThis.acPerf && !!expo.modules.SolaraApp.devPostKeys && !!expo.modules.SolaraTabPool.devPageIds && ${fresh ? "!!ac.store.getState().windows.w2" : "ac.store.getState().windowOrder.length > 0"};`;
const start = (fresh) => launch(appPath, { data, fresh, onboarded: true, probe: true, keepData: true, env: { SOLARA_NATIVE_WINDOW_LAYOUT: "1" }, ...(fresh ? { session: fixture } : {}), ready: { timeout: 40000, test: ready(fresh) } });

try {
  app = await start(true);
  await run('return ac.shell.focusWindow("w1");');
  await until("fixture pages", async () => {
    const ids = await pageIds();
    return ids.includes("a") && ids.includes("z");
  });

  await check("Command W before the placeholder page exists leaks no page and focuses the next tab", async () => {
    const before = await nativeState();
    const pagesBefore = await pageIds();
    const engineBefore = await engineKeys();
    const watched = await watchPagesAround(`expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([key("t", 17), key("w", 13, 5)])})`, 1500);
    const seen = watched.seen;
    const posted = watched.firstSeen;
    const after = await until("placeholder closed", async () => {
      const state = await nativeState();
      return JSON.stringify(state.windows.w1.tabIds) === JSON.stringify(before.windows.w1.tabIds) && active(state) === "a" ? state : null;
    });
    const created = seen.filter((id) => !pagesBefore.includes(id));
    assert.deepEqual(created, [], "no page was made for the closed placeholder, before or after the deferral");
    assert.deepEqual((await pageIds()).sort(), [...pagesBefore].sort());
    assert.deepEqual((await engineKeys()).sort(), [...engineBefore].sort(), "the engine holds no extra tab");
    const responder = await until("page focus", async () => {
      const responder = await firstResponder();
      return /RenderWidgetHostViewCocoa|SolaraCoreWebView/.test(responder) ? responder : null;
    });
    return { posted, seen, tabIds: after.windows.w1.tabIds, responder };
  });

  await check("Typing within 50 ms of Command T settles the tab, makes its page at once and keeps every key", async () => {
    const before = await nativeState();
    const timeline = await run(`
      const pool = expo.modules.SolaraTabPool;
      const store = expo.modules.SolaraStoreAdapter;
      const known = new Set(${JSON.stringify(before.windows.w1.tabIds)});
      const started = Date.now();
      return new Promise((done) => {
        let tabId = null;
        let madeAt = null;
        let settledAt = null;
        const tick = () => pool.devPageIds().then((ids) => {
          const data = JSON.parse(store.snapshot()).data;
          tabId = tabId ?? data.windows.w1.tabIds.find((id) => !known.has(id)) ?? null;
          const now = Date.now() - started;
          if (tabId && madeAt === null) madeAt = now;
          if (tabId && settledAt === null && data.tabs[tabId] && data.tabs[tabId].newTabPlaceholder !== true) settledAt = now;
          const pageAt = tabId && ids.includes(tabId) ? now : null;
          if ((pageAt !== null && settledAt !== null) || now > 4000) done({ tabId, madeAt, settledAt, pageAt });
          else setTimeout(tick, 10);
        });
        tick().then(() => expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([key("t", 17), key("h", 4, 20, []), key("i", 34, 10, [])])}));
      });
    `, 8000);
    Object.assign(partial, timeline);
    const { tabId } = timeline;
    assert.ok(tabId, "Command T made a tab");
    assert.ok(timeline.settledAt !== null, "typing settled the placeholder");
    assert.ok(timeline.pageAt !== null, "the settled tab has its page");
    const hero = await until("typed text", async () => {
      const hero = await heroState(tabId);
      return hero?.typed === "hi" && hero.fieldValue === "hi" ? hero : null;
    });
    assert.ok(timeline.pageAt - timeline.madeAt < 450, `page made ${timeline.pageAt - timeline.madeAt} ms after the tab, sooner than the deferral (${JSON.stringify(timeline)})`);
    await postKeys("w1", [key("w", 13)]);
    await until("typed tab closed", async () => !(await nativeState()).tabs[tabId]);
    return { ...timeline, typed: hero.typed };
  });

  await check("Command Bar mode: the page starts at once, without the 0.5 s fallback, and closing the bar leaves no stray page", async () => {
    await run('ac.store.getState().updateSettings({ newTabOpens: "commandBar" }); return true;');
    const outcomes = [];
    partial.outcomes = outcomes;
    try {
      for (const dismiss of [false, false, false, true, true]) {
        const before = await nativeState();
        const pagesBefore = await pageIds();
        const timeline = run(`
          const pool = expo.modules.SolaraTabPool;
          const store = expo.modules.SolaraStoreAdapter;
          const known = new Set(${JSON.stringify(before.windows.w1.tabIds)});
          const started = Date.now();
          return new Promise((done) => {
            let tabId = null;
            let madeAt = null;
            let goneAt = null;
            const tick = () => pool.devPageIds().then((ids) => {
              const data = JSON.parse(store.snapshot()).data;
              tabId = tabId ?? data.windows.w1.tabIds.find((id) => !known.has(id)) ?? null;
              if (tabId && !data.tabs[tabId] && goneAt === null) goneAt = Date.now() - started;
              const pageAt = tabId && ids.includes(tabId) ? Date.now() - started : null;
              if (tabId && madeAt === null && data.tabs[tabId]) madeAt = Date.now() - started;
              if (pageAt !== null || Date.now() - started > 4000) done({ tabId, madeAt, pageAt, goneAt, extra: ids.filter((id) => !${JSON.stringify(pagesBefore)}.includes(id)) });
              else setTimeout(tick, 10);
            });
            tick().then(() => expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "newTab", "create"))
              .then(() => ${dismiss ? 'new Promise((wait) => setTimeout(wait, 50)).then(() => ac.store.getState().closePanel("w1"))' : "null"});
          });
        `, 8000);
        const seen = await timeline;
        assert.ok(seen.tabId, `the create path made a tab (${JSON.stringify(seen)})`);
        const state = await nativeState();
        const tab = seen.tabId ? state.tabs[seen.tabId] : undefined;
        const outcome = { dismiss, ...seen, kept: !!tab, placeholder: tab?.newTabPlaceholder === true, url: tab?.url, navigation: tab?.navigation?.url ?? null };
        outcomes.push(outcome);
        if (outcome.kept) assert.ok(outcome.pageAt !== null && outcome.pageAt - outcome.madeAt < 400, `a kept tab has its page without waiting for the fallback (${JSON.stringify(outcome)})`);
        else assert.equal(outcome.pageAt, null, `a discarded tab never got a page (${JSON.stringify(outcome)})`);
        await run('ac.store.getState().closePanel("w1"); return true;');
        if (outcome.kept) {
          await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeTab", null);`);
          await until("cleanup", async () => !(await nativeState()).tabs[seen.tabId]);
        }
        await run('ac.store.getState().activate("a"); return true;');
        await until("base tab active", async () => active(await nativeState()) === "a");
      }
    } finally {
      await run('ac.store.getState().closePanel("w1"); ac.store.getState().updateSettings({ newTabOpens: "page" }); return true;');
    }
    return outcomes;
  });

  await check("Command Bar mode: the sidebar + toggles the bar like main and leaves no blank rows", async () => {
    await closePlaceholders();
    await run('ac.store.getState().activate("a"); ac.store.getState().updateSettings({ newTabOpens: "commandBar" }); return true;');
    await until("a active", async () => active(await nativeState()) === "a");
    const plus = () => run(`expo.modules.SolaraSettings.emit("onSettingsCall", { id: 2147483001, name: "sidebar.action", args: ${JSON.stringify(JSON.stringify(["w1", "newTab", "", {}]))} }); return true;`);
    const panelOpen = async () => (await nativeState()).windowUi?.w1?.panel?.newTab != null && (await nativeState()).windowUi?.w1?.panel?.open === true;
    const before = await nativeState();
    try {
      await plus();
      await until("first + opens the bar", panelOpen);
      partial.afterFirst = { tabIds: (await nativeState()).windows.w1.tabIds, active: active(await nativeState()) };
      await plus();
      await until("second + closes the bar", async () => !(await panelOpen()));
      await plus();
      await until("third + opens it again", panelOpen);
      await run('ac.store.getState().closePanel("w1"); return true;');
      await until("bar closed", async () => !(await panelOpen()));
      const state = await nativeState();
      const added = state.windows.w1.tabIds.filter((id) => !before.windows.w1.tabIds.includes(id));
      Object.assign(partial, { added, active: active(state), tabs: added.map((id) => state.tabs[id]) });
      assert.deepEqual(added, [], "three presses of + leave no new tabs behind");
      assert.equal(active(state), "a", "closing the bar goes back to the tab you were on");
      return partial;
    } finally {
      await run('ac.store.getState().closePanel("w1"); ac.store.getState().updateSettings({ newTabOpens: "page" }); return true;');
      await closePlaceholders();
      const left = (await nativeState()).windows.w1.tabIds.filter((id) => !before.windows.w1.tabIds.includes(id));
      for (const id of left) await run(`ac.store.getState().closeTab(${JSON.stringify(id)}); return true;`);
      await run('ac.store.getState().activate("a"); return true;');
    }
  });

  await check("Command Bar mode: typing in the bar over a placeholder made by the bar's New Tab, then Esc, ⌘W or switching to a tab, leaves no blank row", async () => {
    await closePlaceholders();
    await run('ac.store.getState().activate("a"); ac.store.getState().updateSettings({ newTabOpens: "commandBar" }); return true;');
    await until("a active", async () => active(await nativeState()) === "a");
    const bar = async () => (await app.snapshot({ windowId: "w1" }, { timeout: 1000 })).windows.find((window) => window.id === "w1")?.omnibox;
    const outcomes = [];
    const problems = [];
    Object.assign(partial, { outcomes, problems });
    const leaves = {
      escape: null,
      closeKey: 'return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeTab", null);',
      switchTo: 'ac.store.getState().closePanel("w1"); ac.store.getState().activate("b"); return true;',
    };
    const rows = async () => (await run('return expo.modules.SolaraHosted.sidebarRealization("w1").then(JSON.parse);')).pages
      .flatMap((page) => page.realization.logical.map((item) => item.key)).filter((key) => key.startsWith("t:"));
    const escape = 'return ac.shell.devKeyEquivalent("w1", { key: "\\u001b", keyCode: 53, modifiers: [], send: true, asKey: true, wait: 30 });';
    const barFocused = async () => {
      const b = await bar();
      return b?.open && b.focused ? b : null;
    };
    const starts = {
      typedNewTabUrl: async (leave, known) => {
        await postKeys("w1", [key("t", 17)]);
        await until(`${leave}: ⌘T opens the bar`, barFocused);
        await run('return ac.shell.devTypeKeys("w1", "solara://newtab", 5);');
        await until(`${leave}: the address reached the bar`, async () => (await bar())?.typed === "solara://newtab");
        await run('return ac.shell.devKeyEquivalent("w1", { key: "\\r", keyCode: 36, modifiers: [], send: true, asKey: true, wait: 30 });');
        const tabId = await until(`${leave}: placeholder made`, async () => (await nativeState()).windows.w1.tabIds.find((id) => !known.includes(id)) ?? null);
        const reopened = await until(`${leave}: bar over the placeholder`, barFocused, 2500).then(() => false, async () => {
          await postKeys("w1", [key("t", 17)]);
          await until(`${leave}: ⌘T opens the bar into the placeholder`, barFocused);
          return true;
        });
        return { tabId, reopened };
      },
      create: async (leave, known) => {
        await run('return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "newTab", "create");');
        await until(`${leave}: bar focused`, barFocused);
        const tabId = await until(`${leave}: placeholder made`, async () => (await nativeState()).windows.w1.tabIds.find((id) => !known.includes(id)) ?? null);
        return { tabId, reopened: false };
      },
    };
    const before = await nativeState();
    try {
      for (const [start, begin] of Object.entries(starts)) for (const [leave, script] of Object.entries(leaves)) {
        const known = (await nativeState()).windows.w1.tabIds;
        const visibleBefore = await rows();
        const { tabId, reopened } = await begin(`${start}/${leave}`, known);
        await run('return ac.shell.devTypeKeys("w1", "x", 5);');
        await until(`${leave}: the key reached the bar`, async () => (await bar())?.typed === "x");
        const typed = (await nativeState()).tabs[tabId];
        let escapes = 0;
        if (script) await run(script);
        else {
          for (; escapes < 3 && (await bar())?.open; escapes++) {
            await run(escape);
            await until(`${leave}: Esc handled`, async () => !(await bar())?.open || (await bar())?.typed === "", 1500).catch(() => null);
          }
        }
        partial.lastBar = await bar();
        await until(`${leave}: bar closed`, async () => !(await bar())?.open);
        await sleep(300);
        const right = await nativeState();
        const afterLeave = { kept: !!right.tabs[tabId], active: active(right) === tabId ? "itself" : active(right) };
        if (leave !== "switchTo") await run('ac.store.getState().activate("a"); return true;');
        await sleep(600);
        const state = await nativeState();
        const tab = state.tabs[tabId];
        const visibleAfter = await rows();
        const outcome = {
          start, leave, reopened, escapes, tabId, afterLeave, visibleBefore, visibleAfter, blankRowShown: visibleAfter.includes(`t:${tabId}`), rowsAdded: visibleAfter.filter((key) => !visibleBefore.includes(key)), placeholderAfterTyping: typed?.newTabPlaceholder === true,
          left: !!tab, placeholder: tab?.newTabPlaceholder === true, url: tab?.url ?? null, navigation: tab?.navigation ?? null,
          baseTabs: ["a", "b"].every((id) => !!state.tabs[id]),
        };
        outcomes.push(outcome);
        if (!outcome.baseTabs) problems.push(`${leave} closed another tab (${JSON.stringify(outcome)})`);
        if (outcome.blankRowShown || (outcome.left && !outcome.placeholder)) problems.push(`${start}/${leave} left a blank row behind (${JSON.stringify(outcome)})`);
        await closePlaceholders();
        await run('ac.store.getState().activate("a"); return true;');
        await until(`${leave}: a active`, async () => active(await nativeState()) === "a");
      }
      for (const start of Object.keys(starts)) {
        const [escape, closeKey] = ["escape", "closeKey"].map((leave) => outcomes.find((o) => o.start === start && o.leave === leave));
        if (JSON.stringify(closeKey.afterLeave) !== JSON.stringify(escape.afterLeave)) problems.push(`${start}: ⌘W over the bar did more than dismiss it, as Esc does (${JSON.stringify({ escape: escape.afterLeave, closeKey: closeKey.afterLeave })})`);
      }
      assert.deepEqual(problems, []);
      return outcomes;
    } finally {
      await run('ac.store.getState().closePanel("w1"); ac.store.getState().updateSettings({ newTabOpens: "page" }); return true;');
      await closePlaceholders();
      const left = (await nativeState()).windows.w1.tabIds.filter((id) => !before.windows.w1.tabIds.includes(id));
      for (const id of left) await run(`ac.store.getState().closeTab(${JSON.stringify(id)}); return true;`);
      await run('ac.store.getState().activate("a"); return true;');
    }
  });

  await check("A link opened in a new tab doesn't pull focus back from the Command Bar you moved to", async () => {
    await closePlaceholders();
    await run('ac.store.getState().activate("a"); return true;');
    await until("a active", async () => active(await nativeState()) === "a");
    const before = await nativeState();
    await run('ac.store.getState().newTab("w1", { url: "about:blank#linked" }); return true;');
    const tabId = await until("link tab active", async () => {
      const state = await nativeState();
      const id = state.windows.w1.tabIds.find((id) => !before.windows.w1.tabIds.includes(id));
      return id && active(state) === id ? id : null;
    });
    await run('return ac.shell.devKeyEquivalent("w1", { key: "l", keyCode: 37, modifiers: ["command"], focus: "page" });');
    const samples = [];
    for (let i = 0; i < 12; i++) {
      const snapshot = await app.snapshot({ windowId: "w1" }, { timeout: 1000 });
      const window = snapshot.windows.find((window) => window.id === "w1");
      samples.push({ responder: window?.firstResponder, bar: window?.omnibox?.focused ?? null });
      await sleep(100);
    }
    Object.assign(partial, { tabId, samples });
    const settled = samples.slice(3);
    assert.ok(settled.every((sample) => sample.bar === true && /NSTextView|FieldEditor/.test(sample.responder ?? "")), `the Command Bar keeps focus: ${JSON.stringify(samples)}`);
    await run('ac.store.getState().closePanel("w1"); return true;');
    await run(`ac.store.getState().closeTab(${JSON.stringify(tabId)}); return true;`);
    await until("link tab closed", async () => !(await nativeState()).tabs[tabId]);
    return partial;
  });

  await check("Tab sleep never meets a page-less placeholder", async () => {
    const before = await nativeState();
    const raced = await run(`
      const store = expo.modules.SolaraStoreAdapter;
      const pool = expo.modules.SolaraTabPool;
      const known = new Set(${JSON.stringify(before.windows.w1.tabIds)});
      const findPlaceholder = () => new Promise((done) => {
        const deadline = Date.now() + 3000;
        const look = () => {
          const data = JSON.parse(store.snapshot()).data;
          const tabId = data.windows.w1.tabIds.find((id) => !known.has(id) && data.tabs[id]?.newTabPlaceholder === true);
          if (tabId || Date.now() > deadline) done(tabId ?? null);
          else setTimeout(look, 2);
        };
        look();
      });
      const sweepBoth = (tabId, hadPage) => store.devTabSleep("sweep")
        .then((native) => (globalThis.acLifecycle ? acLifecycle.sweep({ idleMs: 0 }) : Promise.resolve(null))
          .then((js) => pool.devPageIds().then((after) => ({ tabId, hadPage, nativeSweep: JSON.parse(native), jsSweep: js, pageAfterSweep: after.includes(tabId) }))));
      return expo.modules.SolaraApp.devPostKeys("w1", [{ key: "t", keyCode: 17, modifiers: ["command"] }])
        .then(findPlaceholder)
        .then((tabId) => tabId ? pool.devPageIds().then((ids) => sweepBoth(tabId, ids.includes(tabId))) : { tabId });
    `, 12000);
    Object.assign(partial, raced);
    const { tabId, hadPage, nativeSweep, jsSweep } = raced;
    assert.ok(tabId, "placeholder made");
    assert.equal(hadPage, false, "the sweep ran while the placeholder had no page");
    assert.equal(nativeSweep.error, undefined, JSON.stringify(nativeSweep));
    assert.ok(!(nativeSweep.slept ?? []).includes(tabId), "native sleep skipped the placeholder");
    assert.ok(!(jsSweep ?? []).includes(tabId), "JS sleep skipped the placeholder");
    const state = await nativeState();
    assert.equal(state.tabs[tabId]?.newTabPlaceholder, true);
    assert.equal(active(state), tabId);
    assert.notEqual(state.live?.[tabId]?.discarded, true);
    await until("placeholder page after the deferral", async () => (await pageIds()).includes(tabId));
    return raced;
  });

  await check("A placeholder's hero mounting under the Command Bar never takes the bar's focus", async () => {
    await closePlaceholders();
    await run('ac.store.getState().updateSettings({ newTabOpens: "commandBar" }); return true;');
    try {
      const before = await nativeState();
      await run('return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "newTab", "create");');
      await until("bar focused", async () => {
        const bar = (await app.snapshot({ windowId: "w1" }, { timeout: 1000 })).windows.find((window) => window.id === "w1")?.omnibox;
        return bar?.open && bar.focused ? bar : null;
      });
      await run('return ac.shell.devTypeKeys("w1", "kept", 5);');
      const state = await nativeState();
      const tabId = state.windows.w1.tabIds.find((id) => !before.windows.w1.tabIds.includes(id));
      partial.tabId = tabId;
      await sleep(800);
      const snapshot = await app.snapshot({ windowId: "w1" }, { timeout: 2000 });
      const window = snapshot.windows.find((window) => window.id === "w1");
      const hero = tabId ? await heroState(tabId) : null;
      Object.assign(partial, { bar: window?.omnibox, responder: window?.firstResponder, hero });
      assert.equal(window?.omnibox?.focused, true, "the Command Bar keeps focus");
      assert.equal(window?.omnibox?.typed, "kept", "every key reached the Command Bar");
      assert.notEqual(hero?.focused, true, "the hero did not take focus");
      return partial;
    } finally {
      await run('ac.store.getState().closePanel("w1"); ac.store.getState().updateSettings({ newTabOpens: "page" }); return true;');
      await closePlaceholders();
      await run('ac.store.getState().activate("a"); return true;');
    }
  });

  await check("A hero mounting in a window that isn't key leaves the key window's focus alone", async () => {
    await run('return ac.shell.focusWindow("w1");');
    const responderBefore = await until("w1 page focus", async () => {
      const responder = await firstResponder("w1");
      return /RenderWidgetHostViewCocoa|SolaraCoreWebView/.test(responder) ? responder : null;
    });
    const before = await nativeState();
    await run('return expo.modules.SolaraApp.devWorkspaceMenuCommand("w2", "newTab", null);');
    const tabId = await until("w2 placeholder", async () => {
      const state = await nativeState();
      return state.windows.w2.tabIds.find((id) => !before.windows.w2.tabIds.includes(id));
    });
    const hero = await until("w2 hero mounted", async () => {
      const hero = await heroState(tabId, "w2");
      return hero?.mounted ? hero : null;
    });
    await sleep(500);
    const w1Responder = await firstResponder("w1");
    const w2Responder = await firstResponder("w2");
    const heroAfter = await heroState(tabId, "w2");
    Object.assign(partial, { tabId, hero, heroAfter, w1Responder, w2Responder });
    assert.equal(w1Responder, responderBefore, "the key window keeps its focus");
    await closePlaceholders("w2");
    return partial;
  });

  await check("Closing a window during the deferral leaves none of its pages behind", async () => {
    await closePlaceholders();
    await run('return ac.shell.focusWindow("w2");');
    const pagesBefore = await pageIds();
    const w1Before = (await nativeState()).windows.w1.tabIds;
    const watched = await watchPagesAround(`expo.modules.SolaraApp.devWorkspaceMenuCommand("w2", "newTab", null).then(() => expo.modules.SolaraApp.devWorkspaceMenuCommand("w2", "closeWindow", null))`, 1500);
    const seen = watched.seen;
    const posted = watched.firstSeen;
    const closing = await nativeState();
    Object.assign(partial, { posted, seen, windows: Object.keys(closing.windows), w2: closing.windows.w2?.tabIds ?? null });
    await until("w2 closed", async () => !(await nativeState()).windows.w2 && !(await run("return ac.shell.windowIds();")).includes("w2"));
    const w1After = (await nativeState()).windows.w1.tabIds;
    assert.deepEqual(w1After, w1Before, "the new tab went to w2, not w1");
    const created = seen.filter((id) => !pagesBefore.includes(id) && id !== "z");
    const left = await until("closed window's pages gone", async () => {
      const pages = await pageIds();
      const engine = await engineKeys();
      return created.every((id) => !pages.includes(id) && !engine.includes(id)) && !pages.includes("z") ? { pages, engine } : null;
    }, 6000);
    assert.ok(app.alive);
    return { posted, seen, created, left };
  });

  await check("Quitting during the deferral exits cleanly and relaunches on the tab that was active", async () => {
    await run('return ac.shell.focusWindow("w1");');
    await closePlaceholders();
    await run('ac.store.getState().activate("a"); return true;');
    await until("a active", async () => active(await nativeState()) === "a");
    const before = await nativeState();
    await postKeys("w1", [key("t", 17)]);
    await until("placeholder", async () => {
      const state = await nativeState();
      return state.windows.w1.tabIds.some((id) => !before.windows.w1.tabIds.includes(id) && state.tabs[id]?.newTabPlaceholder === true);
    });
    const pid = app.pid;
    const launchedAt = app.launchedAt;
    const quit = await app.quit();
    assert.equal(quit.how, "quit", "graceful quit");
    const crashes = crashReportsForInstance(data, pid, launchedAt);
    assert.deepEqual(crashes, [], "no crash report");
    app = await start(false);
    const state = await until("restored session", async () => {
      const state = await nativeState();
      return state.windows.w1 ? state : null;
    });
    assert.deepEqual(state.windows.w1.tabIds, before.windows.w1.tabIds, "the placeholder stayed out of the session");
    assert.equal(active(state), active(before), "the tab that was active before the placeholder is active again");
    assert.ok(Object.values(state.tabs).every((tab) => tab.newTabPlaceholder !== true));
    Object.assign(partial, { quit, tabIds: state.windows.w1.tabIds, active: active(state), before: active(before) });
    const pages = await until("restored page", async () => {
      const ids = await pageIds();
      partial.pages = ids;
      return ids.includes(active(state)) ? ids : null;
    });
    return { quit, tabIds: state.windows.w1.tabIds, active: active(state), pages };
  });

  await check("A window holding only an untouched placeholder still gives a window after relaunch", async () => {
    await run('return ac.shell.focusWindow("w1");');
    const before = await nativeState();
    await postKeys("w1", [key("t", 17)]);
    const tabId = await until("placeholder", async () => placeholders(await nativeState())[0]);
    for (const id of before.windows.w1.tabIds) await run(`ac.store.getState().closeTab(${JSON.stringify(id)}); return true;`);
    const only = await until("only the placeholder left", async () => {
      const state = await nativeState();
      return JSON.stringify(state.windows.w1?.tabIds) === JSON.stringify([tabId]) && state.tabs[tabId]?.newTabPlaceholder === true ? state : null;
    });
    partial.windows = Object.keys(only.windows);
    const quit = await app.quit();
    assert.equal(quit.how, "quit", "graceful quit");
    app = await start(false);
    const state = await until("a window after relaunch", async () => {
      const state = await nativeState();
      const shown = await run("return ac.shell.windowIds();");
      return state.windowOrder.length > 0 && shown.length > 0 ? { state, shown } : null;
    }, 20000);
    const windowId = state.state.windowOrder[0];
    Object.assign(partial, { windowOrder: state.state.windowOrder, shown: state.shown, tabs: state.state.windows[windowId]?.tabIds });
    assert.ok(state.state.windows[windowId].tabIds.length > 0, "the window has a tab");
    assert.ok(Object.values(state.state.tabs).every((tab) => tab.id !== tabId), "the old placeholder stayed out of the session");
    return partial;
  });
} catch (error) {
  evidence.push({ name: "run", passed: false, error: String(error?.stack ?? error) });
  results.push(false);
  console.log(`FAIL run: ${error?.message ?? error}`);
  save();
} finally {
  if (app) await app.quit().catch(() => {});
}
const passed = results.filter(Boolean).length;
console.log(`${passed}/${results.length} passed. Evidence: ${join(output, "evidence.json")}`);
process.exit(passed === results.length && results.length > 0 ? 0 : 1);
