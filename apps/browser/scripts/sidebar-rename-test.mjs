#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node sidebar-rename-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-rename-"));
const rep = reporter(join(scratch, "sidebar-rename-test.log"), { name: "sidebar-rename-test" });
const ids = ["t0", "t1", "t2"];
const tabs = ids.map((id) => ({ id, url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` }));

const app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  session: session({ profiles: ["Personal"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t0" }, frame: [60, 60, 1200, 800] }], tabs }),
  ready: "return !!ac.store",
});
let nativePollDeadline = 0;
const run = (body, timeout = 30000) => {
  if (nativePollDeadline) {
    if (nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms remaining");
    timeout = Math.min(timeout, 1000);
  }
  return app.eval(body, { timeout });
};
const renaming = () => run(`return ac.sidebarRows.useSidebarUi.getState().renaming?.id ?? null`);
const tabCount = () => run(`return ac.store.getState().windows.w1.tabIds.length`);
const until = async (what, test, ms = 3000) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await test()) return;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(40);
  }
};
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    if (!app.alive) throw new Error(`${what}: the owned app exited`);
    if (end - Date.now() < 1000) break;
    last = await app.snapshot({ windowId: "w1" }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
    nativePollDeadline = end;
    try {
      if (!last.error && last.consistent && Date.now() < end && await accept(last) && Date.now() < end) return last;
    } finally {
      nativePollDeadline = 0;
    }
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const assertNativeRename = async (id, title, count) => {
  const snapshot = await untilSnapshot(`native rename of ${id}`, (state) => state.tabs.some((tab) => tab.id === id && tab.customTitle === title) &&
    state.windows.some((window) => window.id === "w1" && window.tabIds.length === count));
  assert.equal(snapshot.tabs.find((tab) => tab.id === id)?.customTitle, title);
  assert.equal(snapshot.windows.find((window) => window.id === "w1")?.tabIds.length, count);
};
const startRename = async (id) => {
  await run(`ac.pages.setSidebarUi({ renaming: { windowId: "w1", kind: "tab", id: ${JSON.stringify(id)} } }); return true`);
  await sleep(400);
};

try {
  await sleep(2500);
  const last = await run(`return ac.sidebarRows.measureRow("w1", "t2")`);
  const blank = { x: last.x + 60, y: Math.round(last.y + last.height + 160) };

  await rep.check("a click on the empty sidebar keeps the typed name, closes the field and opens no tab", async () => {
    const before = await tabCount();
    await startRename("t1");
    await run(`return ac.shell.devTypeKeys("w1", "Renamed", 10)`);
    await sleep(200);
    const click = await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    rep.say(`clicked ${JSON.stringify(click)}`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t1.customTitle`), "Renamed");
    await sleep(500);
    assert.equal(await tabCount(), before, "no new tab");
    await assertNativeRename("t1", "Renamed", before);
  });

  await rep.check("a second click there right after opens no tab either", async () => {
    const before = await tabCount();
    await startRename("t2");
    await run(`return ac.shell.devTypeKeys("w1", "Second", 10)`);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t2.customTitle`), "Second");
    await sleep(500);
    assert.equal(await tabCount(), before, "no new tab");
    await assertNativeRename("t2", "Second", before);
  });

  await rep.check("a click on another row keeps the typed name and selects that row", async () => {
    const before = await tabCount();
    const row = await run(`return ac.sidebarRows.measureRow("w1", "t2")`);
    await startRename("t1");
    await run(`return ac.shell.devTypeKeys("w1", "Away", 10)`);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${Math.round(row.x + row.width / 2)}, y: ${Math.round(row.y + row.height / 2)} })`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t1.customTitle`), "Away");
    await until("t2 to be the active tab", async () => await run(`return Object.values(ac.store.getState().windows.w1.activeTabIds).includes("t2")`));
    assert.equal(await tabCount(), before, "no new tab");
    await assertNativeRename("t1", "Away", before);
  });

  await rep.check("Esc still cancels", async () => {
    await startRename("t0");
    await run(`return ac.shell.devTypeKeys("w1", "Nope", 10)`);
    await sleep(200);
    await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t0.customTitle ?? null`), null);
    await assertNativeRename("t0", null, await tabCount());
  });
} finally {
  await app.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);
