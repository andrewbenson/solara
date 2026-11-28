import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const [app, scratch, format, previousApp, previousPort] = process.argv.slice(2);
if (!app || !scratch || !["v10", "v11"].includes(format) || (previousApp && (!previousPort || format !== "v10"))) {
  throw new Error("usage: node packages/sync/scripts/password-crypto-e2e.mjs <Debug app> <fresh scratch> <v10|v11> [<157 Debug app> <157 bundle port>]");
}

const devIdentity = "network.benson.solara.dev";
for (const binary of [app, previousApp].filter(Boolean)) {
  const identity = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", resolve(binary, "Contents/Info.plist")], { encoding: "utf8" }).trim();
  assert.equal(identity, devIdentity, "a Debug test app must use the dev bundle identifier");
}

const root = resolve(scratch);
mkdirSync(root);
const home = name => resolve(root, name);
const dataDirectory = name => format === "v10" ? resolve(home(name), "Library/Application Support", devIdentity) : home(name);
const data = dataDirectory("A");
const folder = resolve(root, "folder");
const database = resolve(data, "Chromium/Default/Login Data");
const origin = "https://sync-crypto.example";
const username = "fixture";
const password = "Pässword 🔑";
const save = (user, secret) => `return globalThis.expo.modules.SolaraCEF.savePassword(${["", origin, user, secret].map(value => JSON.stringify(value)).join(", ")}).then(result => !!result && !result.error);`;
const sync = "globalThis.expo.modules.SolaraSyncAdapter";
let launches = 0;
const start = (name, binary, opts) => launch(binary, {
  data: dataDirectory(name),
  log: resolve(root, `${name}-${++launches}.log`),
  keepData: true,
  probe: true,
  env: {
    CFFIXED_USER_HOME: format === "v10" ? home(name) : undefined,
    TMPDIR: process.env.TMPDIR,
    SOLARA_SYNC_DEFAULT_FOLDER: folder,
    SOLARA_SYNC_REDESIGN: "0",
    SOLARA_TEST_REAUTH: "granted",
  },
  ready: "return !!globalThis.acSync && ac.store.getState().windowOrder.length > 0",
  ...opts,
});
const sql = (statement, readOnly = true) => execFileSync("sqlite3", [
  ...(readOnly ? ["-readonly"] : []), database, statement,
], { encoding: "utf8" }).trim();

const revealed = `return globalThis.expo.modules.SolaraCEF.getPassword(${["", origin, username].map(value => JSON.stringify(value)).join(", ")}).then(result => result?.password === ${JSON.stringify(password)});`;
const syncNow = "return acSync.syncNow()";
const remotePasswords = `
  const scope = "p:" + acSync.doc().profiles.default.syncId;
  return acSync.native.read(${JSON.stringify(folder)}, scope, []).then(remote => {
    if (remote.pending.length || remote.damaged.length) throw new Error("remote password evidence is incomplete");
    return remote.files.flatMap(({id, payload}) => {
      const file = JSON.parse(payload);
      const keys = file.kind === "log" ? file.ops.map(op => op.k) : Object.keys(file.records);
      return keys.some(key => key.startsWith("pw:")) ? [id] : [];
    }).sort();
  });
`;
let browser;
let peer;
try {
  browser = await start("A", previousApp ?? app, previousApp ? { metroPort: Number(previousPort) } : undefined);
  assert.equal(await browser.eval(save(username, password)), true, "Chromium saved the fixture");
  await browser.quit();
  browser = undefined;

  assert.equal(sql("SELECT CAST(substr(password_value, 1, 3) AS TEXT) FROM logins WHERE username_value = 'fixture'"), format);
  browser = await start("A", app);

  const matches = await browser.eval(`
    const expected = ${JSON.stringify(password)};
    return Promise.all([${sync}.readPasswords(""), ${sync}.readPasswordsWithMark("")]).then(([list, marked]) =>
      [list, marked?.logins].map(rows => rows?.some(row => row.username === ${JSON.stringify(username)} && row.password === expected) ?? false)
    );
  `);
  assert.deepEqual(matches, [true, true], "both sync readers return the exact Chromium password");
  assert.equal((await browser.eval(`return acSync.turnOnSync(${JSON.stringify(folder)})`))?.ok, true, "source activates sync");
  const words = await browser.eval("return acSync.native.recoveryWords()");
  peer = await start("B", app);
  assert.equal((await peer.eval(`return acSync.enterRecoveryPhrase(${JSON.stringify(folder)}, ${JSON.stringify(words.join(" "))})`))?.ok, true, "peer joins sync");
  const deadline = Date.now() + 30_000;
  let arrived = false;
  while (Date.now() < deadline && !arrived) {
    await browser.eval(syncNow);
    await peer.eval(syncNow);
    arrived = await peer.eval(revealed);
    if (!arrived) await sleep(300);
  }
  assert.equal(arrived, true, "the peer receives the exact password");
  console.log(`PASS ${format} ${previousApp ? "upgraded" : "fresh"} password syncs to a peer`);

  const before = await peer.eval(remotePasswords);
  assert.ok(before.length, "the synced password appears in the remote journal");
  await browser.quit();
  browser = undefined;

  sql("UPDATE logins SET password_value = X'756e7265616461626c65' WHERE username_value = 'fixture'", false);
  browser = await start("A", app);
  const failure = await browser.eval(`
    return Promise.all([${sync}.readPasswords(""), ${sync}.readPasswordsWithMark("")]).then(reads => reads.map(read => read == null));
  `);
  assert.deepEqual(failure, [true, true], "both readers refuse an unreadable row");
  assert.equal(await browser.eval(save("pending-fixture", "NeverUploaded-Pässword")), true, "Chromium saved a second, decryptable row");
  await browser.eval(syncNow);
  await peer.eval(syncNow);
  assert.equal(await peer.eval(revealed), true, "an unreadable row leaves the peer's password intact");
  assert.deepEqual(await peer.eval(remotePasswords), before, "no remote password files were added or removed");
  console.log("PASS an unreadable row pauses password sync without remote uploads or deletions");
} finally {
  await Promise.all([browser?.quit(), peer?.quit()]);
}
