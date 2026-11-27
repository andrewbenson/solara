#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const [app, scratch] = process.argv.slice(2).map((p) => path.resolve(p));
if (!app || !scratch || app.startsWith("/Applications/")) {
  console.log("usage: import-e2e.mjs <Solara.app under apps/browser/build-*> <scratch dir>");
  process.exit(64);
}
const DATA = path.join(scratch, "data");
const HOME = path.join(scratch, "home");
const SECRET = "e2e-test-secret";
for (const dir of [DATA, HOME]) fs.rmSync(dir, { recursive: true, force: true });
execFileSync("python3", [new URL("../../import/scripts/e2e_fixture.py", import.meta.url).pathname, HOME, SECRET, "8765"], { stdio: "ignore" });

const launchOptions = {
  data: DATA,
  probe: true,
  onboarded: true,
  env: { SOLARA_IMPORT_SOURCE_DIR: `${HOME}/Library/Application Support`, SOLARA_IMPORT_TEST_SECRET: SECRET },
};
let inst = await launch(app, launchOptions);
const run = (body) => inst.eval(body);
const results = [];
const ok = (cond, msg) => {
  const line = `${cond ? "ok  " : "FAIL"} ${msg}`;
  results.push(line);
  console.log(line);
};
try {
  const drive = (action, arg = null) => run(`return globalThis.expo.modules.SolaraSettings.devImport(${JSON.stringify(action)}, ${JSON.stringify(arg)})`);
  const initial = await drive("state");
  if (typeof initial.pendingWrites !== "number") throw new Error("import-e2e requires Debug before discovery");
  await run(`ac.runCommand({ command: "importBrowserData", arg: null, windowId: null }); return true`);
  const bookmarkURL = "https://restore.example/reading";
  const holder = await run(`
    const bookmarks = ac.bookmarks;
    return bookmarks.addBookmarkFolder({ profileId: "default", title: "Fixture (Arc)" }).then(holder =>
      bookmarks.addBookmarkFolder({ profileId: "default", parentId: holder, title: "Restore Fixture" }).then(folder =>
        bookmarks.addBookmark({ profileId: "default", parentId: folder, title: "Reading", url: ${JSON.stringify(bookmarkURL)} })
          .then(() => holder)));
  `);
  assert.ok(holder);
  let state = {};
  for (const deadline = Date.now() + 30000; Date.now() < deadline; await sleep(300)) {
    state = await drive("state");
    if (state.step === "choose") break;
  }
  ok(typeof state.pendingWrites === "number", "Debug import hooks are present");
  if (typeof state.pendingWrites !== "number") throw new Error("import-e2e requires a Debug app");
  ok(state.step === "choose", `native import window opened on choose (${state.step ?? state.error})`);
  ok(state.browsers?.includes("chrome"), `Chrome fixture listed (${state.browsers})`);
  state = await drive("select", "chrome");
  ok(state.kinds.includes("cookies") && state.kinds.includes("autofill"), `cookies and autofill on (${state.kinds})`);
  state = await drive("next");
  for (const deadline = Date.now() + 10000; !["unlock", "progress", "done"].includes(state.step) && Date.now() < deadline; await sleep(300)) state = await drive("state");
  ok(state.step === "unlock", `unlock step for encrypted kinds (${state.step})`);
  state = await drive("unlock");
  for (const deadline = Date.now() + 60000; state.step !== "done" && Date.now() < deadline; await sleep(500)) state = await drive("state");
  console.log("done:", JSON.stringify(state));
  ok(state.step === "done", "reached done");
  ok(state.route === "swift", "import ran in Swift");
  ok(state.counts.cookies === 5, `5 cookies (${state.counts.cookies})`);
  ok(state.counts.addresses === 1 && state.counts.cards === 1, `1 address, 1 card (${state.counts.addresses}, ${state.counts.cards})`);
  ok(state.failures.length === 0, `no failures (${JSON.stringify(state.failures)})`);
  ok(state.notes.some((n) => n.includes("1 cookie couldn't be decrypted")), `undecryptable note (${JSON.stringify(state.notes)})`);
  assert.equal(state.arcHolders, 1);
  const restored = () => run(`
    const draft = JSON.parse(expo.modules.SolaraStoreAdapter.snapshot()).data;
    const groups = Object.values(draft.groups).filter(g => g.name === "Restore Fixture" && g.pinned);
    const settings = expo.modules.SolaraSettings;
    if (settings.bookmarkWriterState().state !== "owned") return { hasView: false };
    const book = settings.bookmarkWriterSnapshot("default");
    const document = JSON.parse(book.document);
    return {
      hasView: book.hasView,
      holder: Boolean(document.nodes[${JSON.stringify(holder)}]),
      urls: groups.map(group => group.tabIds.map(id => draft.tabs[id].url)),
    };
  `);
  const settleRestoration = async (expected) => {
    let facts;
    for (const deadline = Date.now() + 30000; Date.now() < deadline; await sleep(100)) {
      facts = await restored();
      if (facts.hasView && facts.holder === expected.holder && facts.urls.length === expected.urls.length) break;
    }
    assert.deepEqual(facts, { hasView: true, ...expected });
  };
  const reopen = async () => {
    await inst.quit();
    inst = await launch(app, launchOptions);
    await inst.ready({ test: "return Boolean(globalThis.ac?.store && globalThis.expo?.modules?.SolaraSettings)" });
  };
  const cancelled = { holder: true, urls: [] };
  const accepted = { holder: false, urls: [[bookmarkURL]] };
  const press = async (action) => {
    let reply;
    for (const deadline = Date.now() + 5000; Date.now() < deadline; await sleep(100)) {
      reply = await drive(action);
      if (reply.pressed) break;
    }
    assert.deepEqual(reply, { pressed: true });
  };
  await press("cancelRestoreArc");
  await settleRestoration(cancelled);
  await reopen();
  await settleRestoration(cancelled);
  ok(true, "closing Import before placement leaves the holder and workspace unchanged across relaunch");
  const html = path.join(scratch, "restore-fixture.html");
  fs.writeFileSync(html, '<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p><DT><A HREF="https://restore.example/seed">Seed</A></DL><p>');
  await run('ac.runCommand({ command: "importBrowserData", arg: null, windowId: null }); return true');
  for (const deadline = Date.now() + 15000; Date.now() < deadline; await sleep(100)) {
    state = await drive("state");
    if (state.step === "choose") break;
  }
  assert.equal(state.step, "choose");
  state = await drive("html", html);
  assert.equal(state.step, "done");
  assert.equal(state.arcHolders, 1);
  await press("restoreArc");
  await settleRestoration(accepted);
  state = await drive("state");
  assert.equal(state.arcHolders, 0);
  assert.deepEqual(await drive("restoreArc"), { pressed: false });
  ok(true, "Restore Arc Folders button places the group and retires the holder");
  await drive("close");
  await reopen();
  await settleRestoration(accepted);
  ok(true, "restored group and removed holder persist across relaunch after closing Import");
  const log = fs.readFileSync(path.join(DATA, "app.out.log"), "utf8");
  ok(!/LogBox|Unhandled JS Exception|RedBox/i.test(log), "no LogBox or JS exception in the log");
} catch (error) {
  ok(false, `threw: ${error}`);
} finally {
  await inst.quit().catch(() => {});
}
fs.writeFileSync(path.join(scratch, "result.txt"), results.join("\n") + "\n");
process.exit(results.some((r) => r.startsWith("FAIL")) ? 1 : 0);
