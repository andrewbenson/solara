import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appPath, scratchArg, mode = "default"] = process.argv.slice(2);
if (!appPath || !scratchArg || !["default", "pool-off", "safe"].includes(mode)) {
  console.error("usage: node translation-lifecycle-test.mjs <Debug app> <scratch> [default|pool-off|safe]");
  process.exit(2);
}

const scratch = resolve(scratchArg);
mkdirSync(scratch, { recursive: true });
const report = reporter(join(scratch, "translation.log"), { name: `translation-lifecycle-${mode}` });
const original = "Das ist ein deutscher Text über die Stadt und ihre Geschichte. Die Menschen leben seit vielen Jahren hier.";
const paragraphs = Array.from({ length: 12 }, (_, index) => `<p>Deutscher Absatz Nummer ${index}.</p>`).join("");
const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
  response.end(`<!doctype html><html lang="de"><title>Übersetzung</title><link rel="icon" href="data:,"><p id="text">${original} <a href="/other">Weiterlesen</a></p><code>Originalcode</code>${paragraphs}</html>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}/article`;
const suite = mode === "safe" ? `solara-translation-${randomUUID()}` : null;
const env = mode === "pool-off" ? { SOLARA_NATIVE_PAGES_POOL: "0", SOLARA_TAB_POOL: "0" } : suite
  ? { SOLARA_LAUNCH_SWITCHES_DEFAULTS: suite, SOLARA_LAUNCH_SWITCHES_OPTION: "1" } : {};
const quote = JSON.stringify;
const helpers = `
const T = globalThis.expo.modules.SolaraToolbar;
const S = () => ac.store.getState();
const state = (id) => T.devTranslationState(id).then(JSON.parse);
const act = (id, action, target) => T.devTranslationAction(id, action, target || null);
const words = (id) => ac.webviews.get(id)?.evaluate("post('result', JSON.stringify(document.querySelector('#text')?.textContent))");
const go = (id, url) => S().navigate(id, url, { userInitiated: true });
`;

let app;
const run = (code) => app.eval(`${helpers}\n${code}`);
const state = (id) => run(`return state(${quote(id)});`);
const words = (id) => run(`return words(${quote(id)});`);
const act = (id, name) => run(`return act(${quote(id)}, ${quote(name)}, "en");`);
const fixture = (delay = 0, fail = false) => run(`return T.devTranslationFixture("TR: ", ${delay}, ${fail});`);
const until = async (description, read, matches = Boolean) => {
  const end = Date.now() + 12000;
  let last;
  while (Date.now() < end) {
    try {
      last = await read();
      if (matches(last)) return last;
    } catch (error) {
      last = error.message;
    }
    await sleep(100);
  }
  throw new Error(`${description}: ${quote(last)}`);
};
const offered = (id) => until(`German offer for ${id}`, () => state(id), (value) => value?.source === "de" && value.document);
const phase = (id, expected) => until(`${id} is ${expected}`, () => state(id), (value) => value?.phase === expected);
const unchanged = (id) => until(`original text in ${id}`, () => words(id), (text) => text?.startsWith(original));

try {
  app = await launch(resolve(appPath), {
    data: join(scratch, "data"), fresh: true, onboarded: true, probe: true, env,
    session: session({
      windows: [{ id: "w1", activeTabIds: { default: "a" }, frame: [80, 80, 1100, 740] }],
      tabs: [{ id: "a", url, title: "Übersetzung" }],
      settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
    }),
    ready: "return !!globalThis.expo.modules.SolaraToolbar && !!ac.store.getState().windows",
  });
  await fixture();
  const initial = await until("active tab", () => run("const w = Object.values(S().windows)[0]; return w?.activeTabIds[w.profileId];"));
  if (suite) {
    assert.equal(await run("return ac.native.status().safeMode;"), "option");
    await run(`go(${quote(initial)}, ${quote(url)}); return true;`);
  }

  await report.check("detection, translation, live additions, and exact revert", async () => {
    const offer = await offered(initial);
    assert.ok(offer.rows.some((row) => row.id === "translate:toggle"));
    await until("native toolbar translation button", () => run(`
      const id = ${quote(initial)};
      const toolbars = JSON.parse(T.devToolbarStates(S().tabs[id].windowId));
      return toolbars.find((bar) => bar.tabId === id)?.url?.trailing?.find((button) => button.id === "translate");
    `));
    const before = await unchanged(initial);
    await act(initial, "translate");
    await phase(initial, "translated");
    assert.match(await words(initial), /^TR: /);
    const after = await run(`return ac.webviews.get(${quote(initial)}).evaluate("document.querySelector('#text').appendChild(document.createTextNode(' Ein neuer Absatz.')); post('result', 'true');");`);
    assert.equal(after, true);
    await until("dynamic text translated", () => words(initial), (text) => text?.includes("TR:") && text.includes("Ein neuer Absatz.") && text.split("TR:").length >= 3);
    await act(initial, "revert");
    await phase(initial, "idle");
    await until("exact original text after revert", () => words(initial), (text) => text === `${before} Ein neuer Absatz.`);
  });

  await report.check("cancel, reload at the same URL, and a failed batch leave original text", async () => {
    await fixture(1600);
    await act(initial, "translate");
    const pending = await phase(initial, "translating");
    assert.equal(pending.progress, null);
    await until("delayed progress toast", () => state(initial), (value) => value?.phase === "translating" && value.progress != null);
    await act(initial, "revert");
    assert.equal((await phase(initial, "idle")).progress, null);
    await sleep(1800);
    await unchanged(initial);

    const old = await offered(initial);
    await act(initial, "translate");
    await phase(initial, "translating");
    await run(`return ac.webviews.get(${quote(initial)}).reload().then(() => true);`);
    await until("different document at same URL", () => state(initial), (value) => value?.phase === "idle" && value?.document && value.document !== old.document);
    await sleep(1800);
    await unchanged(initial);

    await fixture(0, true);
    await offered(initial);
    await act(initial, "translate");
    await until("failed batch returned to idle", () => state(initial), (value) => value?.phase === "idle" && value?.lastError === "test translation failed");
    await unchanged(initial);
    await fixture();
  });

  if (mode === "default") {
    const window = await run(`return S().tabs[${quote(initial)}].windowId;`);
    await report.check("never translate is shared with private windows and is read-only there", async () => {
      await act(initial, "never");
      await until("site translation disabled", () => state(initial), (value) => value?.never && value.source == null);
      const privateWindow = await run(`return S().createWindow({ incognito: true, profileId: "default", url: ${quote(url)} });`);
      const privateTab = await until("private page", () => run(`
        const w = S().windows[${quote(privateWindow)}];
        return w?.activeTabIds[w.profileId] ?? null;
      `));
      const blocked = await until("private inherited rule", () => state(privateTab), (value) => value?.never);
      assert.deepEqual(blocked.rows, []);
      await act(privateTab, "allow");
      assert.equal((await state(initial)).never, true);
      await act(initial, "allow");
      const offer = await offered(privateTab);
      assert.ok(offer.rows.some((row) => row.id === "translate:toggle"));
      assert.ok(offer.rows.every((row) => row.id !== "translate:never"));
      await run(`S().closeWindow(S().tabs[${quote(privateTab)}].windowId); return true;`);
    });

    await report.check("Peek promotion cannot deliver a pending result into its source or replacement", async () => {
      await fixture(2000);
      const peek = await run(`S().activate(${quote(initial)}); return S().openPeek(${quote(initial)}, ${quote(url)});`);
      assert.ok(peek);
      await offered(peek);
      await act(peek, "translate");
      await phase(peek, "translating");
      await run(`ac.peek.openPeekAsTab(${quote(window)}); return true;`);
      await until("Peek promoted", () => run(`return !S().peeks[${quote(window)}] && !!S().tabs[${quote(peek)}];`));
      await phase(peek, "idle");
      await sleep(2200);
      await unchanged(initial);
      await unchanged(peek);
      await offered(peek);
      await act(peek, "translate");
      await phase(peek, "translating");
      await run(`S().closeTab(${quote(peek)}); S().activate(${quote(initial)}); return true;`);
      await until("closed Peek receipt", () => state(peek), (value) => value && !value.document);
    });

    await report.check("profile moves retire pending results and isolate site rules", async () => {
      const prior = await offered(initial);
      await act(initial, "translate");
      await phase(initial, "translating");
      const profile = await run('return S().createProfile({ name: "Translation Work" });');
      await run(`S().moveTabToProfile(${quote(initial)}, ${quote(profile)}); return true;`);
      await until("replacement in Work", () => state(initial), (value) => value?.profile === profile && value.phase === "idle" && value.document && value.document !== prior.document);
      await sleep(2200);
      await unchanged(initial);
      await act(initial, "never");
      await until("Work site rule", () => state(initial), (value) => value?.never);
      await run(`S().moveTabToProfile(${quote(initial)}, "default"); return true;`);
      assert.equal((await offered(initial)).never, false);
    });

    await report.check("engine replacement rejects a delayed Chromium result", async () => {
      await fixture(2000);
      const old = await offered(initial);
      await act(initial, "translate");
      await phase(initial, "translating");
      await run(`
        const id = ${quote(initial)};
        S().updateTab(id, { engine: "webkit", navigation: { url: ${quote(url)}, seq: (S().tabs[id].navigation?.seq ?? 0) + 1, fresh: true } });
        return true;
      `);
      await until("WebKit engine", () => run(`return S().tabs[${quote(initial)}]?.engine === "webkit";`));
      await until("WebKit document", () => state(initial), (value) => value?.document && value.document !== old.document && value.phase === "idle");
      await sleep(2200);
      await unchanged(initial);
    });

    await report.check("Little Solara can translate and closing it retires its receipt", async () => {
      await fixture();
      await run('ac.runCommand({ command: "newLittleSolara" }); return true;');
      const small = await until("Little Solara page", () => run(`
        const w = Object.values(S().windows).find((candidate) => candidate.kind === "small");
        return w?.activeTabIds[w.profileId] ?? null;
      `));
      await run(`go(${quote(small)}, ${quote(url)}); return true;`);
      await offered(small);
      await act(small, "translate");
      await phase(small, "translated");
      assert.match(await words(small), /^TR: /);
      await run(`S().closeWindow(S().tabs[${quote(small)}].windowId); return true;`);
      await until("closed Little Solara receipt", () => state(small), (value) => value && !value.document);
    });
  }

} catch (error) {
  report.record("run", { error });
} finally {
  await app?.quit();
  server.close();
  if (suite) {
    try { execFileSync("defaults", ["delete", suite], { stdio: "ignore" }); } catch {}
  }
}

process.exitCode = report.summary() ? 0 : 1;
