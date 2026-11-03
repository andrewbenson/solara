#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

if (!process.argv[2] || resolve(process.argv[2]).startsWith("/Applications/")) {
  console.error("usage: METRO_PORT=<port> node packages/sync/scripts/remove-from-sync-e2e.mjs <Debug app under apps/browser/build-*>");
  process.exit(2);
}
const APP = resolve(process.argv[2]);
const METRO_PORT = Number(process.env.METRO_PORT ?? 8081);
const WORK = mkdtempSync(join(tmpdir(), "ac-remove-from-sync-"));
const FOLDER = join(WORK, "folder");
const results = [];
const apps = {};
const log = (...a) => console.log(...a);
const check = (name, ok, detail) => {
  results.push({ name, ok: !!ok, detail });
  log(`${ok ? "PASS" : "FAIL"} ${name}${detail === undefined ? "" : ` :: ${JSON.stringify(detail).slice(0, 600)}`}`);
};
const ev = (name, body) => apps[name].eval(body, { timeout: 90_000 });
const sync = async (...names) => {
  for (const n of names) await ev(n, "return acSync.syncNow()");
};
const dev = (name, action, argument) =>
  ev(name, `return globalThis.expo.modules.SolaraSettings.devSettings(${JSON.stringify(action)}, ${JSON.stringify(argument ?? null)}).then(JSON.parse)`);
const rows = (name) =>
  ev(name, "return acSync.useSync.getState().remoteProfiles.map((p) => ({ syncId: p.syncId, name: p.name, removal: p.removal ?? null }))");

async function start(name) {
  apps[name] = await launch(APP, {
    data: join(WORK, name),
    metroPort: METRO_PORT,
    env: { SOLARA_SYNC_DEFAULT_FOLDER: FOLDER, SOLARA_TEST_REAUTH: "granted" },
    ready: { timeout: 120_000, test: "return !!globalThis.acSync && Object.keys(ac.store.getState().windows).length > 0" },
  });
  log(`${name}: pid ${apps[name].pid}, log ${apps[name].log}`);
}

async function settingsShot(name) {
  await ev(name, `ac.openSettings("sync"); return true`);
  await sleep(3000);
  const windows = (await dev(name, "windows")).windows ?? [];
  const line = windows.find((w) => /Settings|Sync/.test(w) && w.includes("visible=true")) ?? windows.find((w) => w.includes("visible=true"));
  const number = line?.match(/#(\d+)/)?.[1];
  const file = join(WORK, `${name}-settings.png`);
  if (number) {
    try {
      execFileSync("timeout", ["20", "screencapture", "-x", "-o", "-l", number, file]);
    } catch (error) {
      log(`screencapture ${name}: ${error.message}`);
    }
  }
  return { windows, number, file };
}

try {
  await start("A");
  await ev("A", `const s = ac.store.getState(); s.createProfile({ name: "RFS Work" }); const home = s.createProfile({ name: "RFS Home" }); ac.store.getState().createProfile({ name: "RFS Kids", shareWith: home }); return true`);
  check("A turns on sync", JSON.stringify(await ev("A", `return acSync.turnOnSync(${JSON.stringify(FOLDER)})`)) === '{"ok":true}');
  const phrase = (await ev("A", "return acSync.native.recoveryWords()")).join(" ");
  await sync("A", "A");

  await start("B");
  check("B joins", JSON.stringify(await ev("B", `return acSync.enterRecoveryPhrase(${JSON.stringify(FOLDER)}, ${JSON.stringify(phrase)})`)) === '{"ok":true}');
  for (let i = 0; i < 6; i++) {
    await sync("A", "B");
    if ((await rows("B")).length >= 3) break;
    await sleep(1000);
  }
  const before = await rows("B");
  const named = (list, n) => list.find((r) => r.name === n);
  check("B offers Work, Home and Kids with a removal", ["RFS Work", "RFS Home", "RFS Kids"].every((n) => named(before, n)?.removal), before);
  check("Home's removal names Kids too", JSON.stringify(named(before, "RFS Home")?.removal?.names) === JSON.stringify(["RFS Home", "RFS Kids"]), named(before, "RFS Home"));
  const localRows = await ev("B", "return Object.keys(acSync.useSync.getState().profiles).length");
  check("B's own profiles aren't remote rows, so they have no Remove from Sync…", !before.some((r) => r.name === "Personal") && localRows >= 1, { localRows });

  log("settings on B", JSON.stringify(await settingsShot("B")));
  log("settings on A", JSON.stringify(await settingsShot("A")));

  const stale = await ev("B", `return acSync.removeRemoteProfile(${JSON.stringify(named(before, "RFS Work").syncId)}, "stale")`);
  check("a stale confirmation is refused", stale === false);

  await ev("A", `const s = ac.store.getState(); s.deleteProfile(s.profileOrder.find((id) => s.profiles[id].name === "RFS Work")); return true`);
  await sync("A", "A");
  const work = named(await rows("B"), "RFS Work");
  check("B removes Work from sync", (await ev("B", `return acSync.removeRemoteProfile(${JSON.stringify(work.syncId)}, ${JSON.stringify(work.removal.token)})`)) === true);
  check("the row goes away at once", !named(await rows("B"), "RFS Work"));
  for (let i = 0; i < 4; i++) await sync("B", "A");
  const tomb = await ev("A", `const r = acSync.doc().scopes.app?.records["prof:${work.syncId}"]; return r ? r.v : "missing"`);
  check("A gets the tombstone for Work", tomb === null, tomb);
  const homeId = await ev("A", `const s = ac.store.getState(); return acSync.useSync.getState().profiles[s.profileOrder.find((id) => s.profiles[id].name === "RFS Home")]?.syncId`);
  const homeRow = named(await rows("B"), "RFS Home");
  check("Home stays offered on B", homeRow?.syncId === homeId);
  check("A keeps Home and Kids", await ev("A", `const s = ac.store.getState(); return ["RFS Home", "RFS Kids"].every((n) => s.profileOrder.some((id) => s.profiles[id].name === n))`));
  check("B's request settles", (await ev("B", "return acSync.doc().removing ?? null")) === null);
} catch (error) {
  check("driver", false, String(error?.stack ?? error));
} finally {
  for (const app of Object.values(apps)) await app.quit().catch((e) => log(`quit: ${e.message}`));
  const failed = results.filter((r) => !r.ok).length;
  writeFileSync(join(WORK, "results.json"), JSON.stringify(results, null, 2));
  log(`DONE ${results.length - failed}/${results.length} passed; work ${WORK}`);
  process.exit(failed ? 1 : 0);
}
