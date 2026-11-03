import { createCipheriv, createDecipheriv, createHash, pbkdf2Sync, randomBytes, randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, lstatSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, readSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, truncateSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { hostname, tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { attach, binaryOf, binaryPids, freePort, isAlive, launch, listenerPids, processInfo, sleep, uiGateLaunching, uiGateWatch } from "../../../scripts/lib/instance.mjs";
import { rekeyPage } from "../../../scripts/lib/fixture-html.mjs";

const USAGE = `usage:
  node apps/browser/scripts/rekey-e2e.mjs fixture <Debug app> <fixture dir> [--other-key-only]
  node apps/browser/scripts/rekey-e2e.mjs run <Debug app> <fixture dir> [check…] [--keep]
  node apps/browser/scripts/rekey-e2e.mjs scan <user data dir> [--key <secret> | --key-file <file>]
  node apps/browser/scripts/rekey-e2e.mjs --list

The Safe Storage re-key (option D) end to end, on scratch dirs and the file keychain only (SOLARA_TEST_KEYCHAIN=file):
the login keychain is never touched.

fixture  makes <fixture dir>/template, a read-only data dir made by the app on Chrome's mock keychain (no test
         keychain): two profiles with persistent, session and HttpOnly cookies, saved passwords with notes, a card,
         an IBAN, a Chrome search engine and history; and <fixture dir>/manifest.json with every planted plaintext
         and the count of mock-keyed values per column. Notes, the IBAN and the search engine have no engine call,
         so they are written into the quit profile's databases, mock-encrypted, and a relaunch on the mock key
         must still read everything back. Then <fixture dir>/other-key: a fresh dir where Chrome made its own
         random key on the file keychain, a cookie and a password under it, the key file removed.
run      clones the app and, per check, the template (APFS clones) and launches the clone hidden on it, one at a
         time; --list names the checks, crash:<point> runs one crash point. Run dirs are removed when all pass,
         unless --keep.
scan     decrypts every v10 value under a key (default mock_password) and prints the counts per column.`;

const CHECKS = {
  "baseline-a": "the template with the file keychain seeded with mock_password and no re-key: everything reads back (validates the harness; option A by hand)",
  "today": "the template on the file keychain with no item and no re-key: Chrome's Safe Storage dialog (today's problem)",
  "migrate": "SOLARA_TEST_REKEY=1: no dialog, every planted value reads back through Chrome, nothing mock-keyed left, one 'add created' in the file keychain log, a real key",
  "crash": "SOLARA_TEST_REKEY_CRASH=<point> for every point, then a relaunch: the migrated end state or the abort message with the dir intact",
  "truncated": "a staged file truncated as after a power loss, then a relaunch: the migrated end state or the abort message with the dir intact",
  "item-present": "a real-looking key already in the file keychain: no migration, data untouched",
  "keychain-denied": "SOLARA_TEST_KEYCHAIN_FAIL=denied: no migration, data untouched",
  "keychain-interaction": "SOLARA_TEST_KEYCHAIN_FAIL=interaction (locked): no migration, data untouched",
  "fresh": "a fresh data dir: no migration; Chrome makes its own key once",
  "other-key": "data under a key that isn't mock_password, the item gone: no migration, data untouched",
  "singleton": "a live process holding SingletonLock: the quit message, nothing changed, no key",
  "unknown-column": "a mock-keyed value in a column the re-key doesn't list, in a listed store: falls back to A (mock_password item), data intact and readable",
  "unlisted-v10": "a v10-looking title in a database the re-key doesn't list: logged, no block, migrated",
  "undo": "SOLARA_TEST_REKEY_FAIL_AFTER_KEY=1: a failure after the key is undone to A (mock_password item, journal abandoned), data intact and readable",
  "undo-crash": "every after-undo point the undo run logs, crashed, then a relaunch: undone to A or the abort message, dir intact",
  "sync-reads": "after the re-key, sync's own password read (acSync.native.readPasswords) decrypts every planted password with the key file's bytes",
  "sync-pause": "after the re-key, the key file replaced by another key (a reset or Start Over), sync on with SOLARA_SYNC_REDESIGN=1: sync's read is nil, it logs the pause, no login or note is deleted",
  "sync-ledger": "re-key, then the first sealed ledger (SOLARA_SYNC_REDESIGN=1): each profile's Login Data mark equals its ledger L@t, nothing held, Login Data otherwise unchanged, and a second Mac joining gets exactly the fixture's passwords",
  "a-then-d": "the file keychain seeded with mock_password, then SOLARA_TEST_REKEY=1: the item is updated (no add), everything reads back",
  "a-crash": "the file keychain seeded with mock_password, a crash after keying, after the update and after keyed, then a relaunch: migrated with an update and no add, or back to A",
  "version-change": "re-key, then a copy with another CFBundleVersion (and a crash at before-cleanup on it): .rekey-old removed, no keychain write, everything reads",
  "rare-points": "the crash points the fixture alone never reaches: after-discard-N (a planted GCM Store), after-restage-keyed (a truncated staged file fails verify) and after-undo-N (the key gone mid-swap), each crashed and recovered",
  "key-overwrite": "re-key, then the key file overwritten with another valid key, two launches with sealed sync: reports tracked prefs and their encrypted hashes, the off extension, rows on disk, what Chrome reads, the sync pause",
  "off-mode": "a re-key stopped at staged, then a build that can't re-key (mock keychain, no test mode): the quit message, nothing touched; then the test build finishes it",
  "test-refused": "SOLARA_TEST_REKEY=1 without the file keychain, and SOLARA_TEST_REKEY=yes: refused and logged, no re-key, data untouched",
  "rollback": "re-key, then the manual rollback (originals back from .rekey-old, item and journal deleted): the next launch re-keys again",
  "leftover-old": "a .rekey-old with no journal and no item: logged and left alone, the A item added, everything reads on the mock key",
};

const IV = Buffer.alloc(16, 0x20);
const MOCK = "mock_password";
const keyOf = (secret) => pbkdf2Sync(Buffer.from(secret), "saltysalt", 1003, 16, "sha1");
const encrypt = (key, plain) => {
  const c = createCipheriv("aes-128-cbc", key, IV);
  return Buffer.concat([Buffer.from("v10"), c.update(plain), c.final()]);
};
const decrypt = (key, blob) => {
  if (!blob || blob.length < 19 || (blob.length - 3) % 16 || blob.subarray(0, 3).toString("latin1") !== "v10") return null;
  try {
    const d = createDecipheriv("aes-128-cbc", key, IV);
    return Buffer.concat([d.update(blob.subarray(3)), d.final()]);
  } catch {
    return null;
  }
};
const strictUtf8 = (buf) => { try { return new TextDecoder("utf-8", { fatal: true }).decode(buf); } catch { return null; } };
const chromeNow = () => (BigInt(Date.now()) + 11644473600000n) * 1000n;
const sha256 = (s) => createHash("sha256").update(s).digest();
const q = (name) => `"${name.replaceAll('"', '""')}"`;

function isSqlite(file) {
  try {
    const fd = openSync(file, "r");
    const head = Buffer.alloc(16);
    readSync(fd, head, 0, 16, 0);
    closeSync(fd);
    return head.toString("latin1") === "SQLite format 3\0";
  } catch {
    return false;
  }
}
function filesUnder(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = lstatSync(p);
    if (st.isDirectory()) filesUnder(p, out);
    else out.push(p);
  }
  return out;
}

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = lstatSync(p);
    if (st.isSymbolicLink() || name.startsWith(".rekey-")) continue;
    if (st.isDirectory()) walk(p, out);
    else if (st.isFile() && st.size >= 512 && isSqlite(p)) out.push(p);
  }
  return out;
}
const openRead = (file) => new DatabaseSync(`file:${encodeURI(file)}?immutable=1`, { readOnly: true });

function scan(userDataDir, secret = MOCK) {
  const key = keyOf(secret);
  const hits = {};
  const values = {};
  const unreadable = [];
  for (const file of walk(userDataDir)) {
    const rel = relative(userDataDir, file);
    let db;
    try { db = openRead(file); } catch (e) { unreadable.push(`${rel}: ${e.message}`); continue; }
    try {
      let version = 0;
      try { version = Number(db.prepare("SELECT value FROM meta WHERE key='version'").get()?.value ?? 0); } catch {}
      for (const { name: table } of db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all()) {
        const cols = db.prepare(`PRAGMA table_info(${q(table)})`).all().map((c) => c.name);
        for (const col of cols) {
          let rows;
          try {
            rows = db.prepare(`SELECT ${table === "cookies" ? "host_key, " : ""}${q(col)} AS v FROM ${q(table)} WHERE substr(CAST(${q(col)} AS BLOB), 1, 3) = CAST('v10' AS BLOB)`).all();
          } catch { continue; }
          for (const row of rows) {
            const blob = typeof row.v === "string" ? Buffer.from(row.v, "utf8") : Buffer.from(row.v);
            const plain = decrypt(key, blob);
            if (!plain) continue;
            let text;
            if (table === "cookies" && col === "encrypted_value" && version >= 24) {
              if (plain.length < 32 || !plain.subarray(0, 32).equals(sha256(row.host_key ?? ""))) continue;
              text = strictUtf8(plain.subarray(32));
            } else text = strictUtf8(plain);
            if (text === null) continue;
            const where = `${rel} ${table}.${col}`;
            hits[where] = (hits[where] ?? 0) + 1;
            (values[where] ??= []).push(text);
          }
        }
      }
    } finally {
      db.close();
    }
  }
  for (const file of prefFiles(userDataDir)) {
    const rel = relative(userDataDir, file);
    let json;
    try { json = JSON.parse(readFileSync(file, "utf8")); } catch (e) { unreadable.push(`${rel}: ${e.message}`); continue; }
    for (const [path, value] of leaves(json)) {
      if (typeof value !== "string" || value.length < 28 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) continue;
      const plain = decrypt(key, Buffer.from(value, "base64"));
      if (!plain || (plain.length !== 32 && strictUtf8(plain) === null)) continue;
      const where = `${rel} prefs`;
      hits[where] = (hits[where] ?? 0) + 1;
      (values[where] ??= []).push(path);
    }
  }
  return { hits, values, unreadable };
}

function prefFiles(userDataDir) {
  const files = [join(userDataDir, "Local State")];
  for (const name of readdirSync(userDataDir))
    if (name === "Default" || name.startsWith("Profile ")) files.push(join(userDataDir, name, "Preferences"), join(userDataDir, name, "Secure Preferences"));
  return files.filter((f) => existsSync(f));
}

function* leaves(value, path = "") {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const [k, v] of Object.entries(value)) yield* leaves(v, path ? `${path}.${k}` : k);
  } else yield [path, value];
}

function plainRows(file) {
  const db = openRead(file);
  try {
    const out = {};
    for (const { name: table } of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all()) {
      const rows = db.prepare(`SELECT * FROM ${q(table)} ORDER BY rowid`);
      rows.setReadBigInts(true);
      out[table] = rows.all().map((row) => Object.fromEntries(Object.entries(row).map(([k, v]) => {
        const b = v instanceof Uint8Array ? Buffer.from(v) : null;
        return [k, b ? (b.subarray(0, 3).toString("latin1") === "v10" ? "<v10>" : b.toString("base64")) : typeof v === "bigint" ? String(v) : v];
      })));
    }
    return out;
  } finally {
    db.close();
  }
}

function loginDataChanges(template, udd, dirs, { ignoreMeta = [] } = {}) {
  const wrong = [];
  for (const dir of dirs) {
    const before = plainRows(join(template, "Chromium", dir, "Login Data"));
    const after = plainRows(join(udd, dir, "Login Data"));
    if (after.meta) after.meta = after.meta.filter((r) => !ignoreMeta.includes(r.key));
    for (const table of new Set([...Object.keys(before), ...Object.keys(after)]))
      if (JSON.stringify(before[table]) !== JSON.stringify(after[table])) wrong.push(`${dir}/Login Data ${table}: ${JSON.stringify(before[table]).slice(0, 200)} → ${JSON.stringify(after[table]).slice(0, 200)}`);
  }
  return wrong;
}

function trackedPrefs(userDataDir, dirs) {
  const out = {};
  for (const dir of dirs) {
    const read = (name) => { try { return JSON.parse(readFileSync(join(userDataDir, dir, name), "utf8")); } catch { return {}; } };
    const secure = read("Secure Preferences"), plain = read("Preferences");
    const at = (obj, path) => path.split(".").reduce((o, k) => (o && typeof o === "object" ? o[k] : undefined), obj);
    const values = {};
    for (const [path] of leaves(secure.protection?.macs ?? {})) {
      if (/_encrypted_hash/.test(path)) continue;
      const v = at(secure, path) ?? at(plain, path);
      values[path] = v === undefined ? null : JSON.stringify(v);
    }
    out[dir] = { values, resetTime: at(secure, "prefs.preference_reset_time") ?? at(plain, "prefs.preference_reset_time") ?? null };
  }
  return out;
}

const VOLATILE_TRACKED = [/^extensions\.settings\./, /^schedule_to_flush_to_disk$/, /^media\.storage_id_salt$/];
function trackedChanges(before, after) {
  const wrong = [];
  for (const [dir, b] of Object.entries(before)) {
    const a = after[dir];
    if (!a) { wrong.push(`${dir}: no tracked prefs`); continue; }
    if (a.resetTime !== b.resetTime) wrong.push(`${dir}: prefs.preference_reset_time ${b.resetTime} → ${a.resetTime}`);
    for (const [path, v] of Object.entries(b.values)) {
      if (VOLATILE_TRACKED.some((r) => r.test(path))) continue;
      if (a.values[path] !== v) wrong.push(`${dir}: ${path} ${String(v).slice(0, 60)} → ${String(a.values[path]).slice(0, 60)}`);
    }
  }
  return wrong;
}

async function serve() {
  const server = createServer((req, res) => {
    const page = req.url.split("?")[0].slice(1) || "index.html";
    res.writeHead(200, { "content-type": "text/html" });
    res.end(rekeyPage(page));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}

const PLANT = [
  { name: "Personal", page: "personal.html", cookies: [
    { name: "p_persist", value: "persist-personal-7d1" },
    { name: "p_session", value: "session-personal-c42", session: true },
    { name: "p_http", value: "httponly-personal-90a", httpOnly: true },
    { name: "p_http_session", value: "httponly-session-personal-5be", httpOnly: true, session: true },
  ], passwords: [
    { username: "alice", password: "pw-personal-123", note: "alice's note: door code 4417" },
    { username: "alice.second", password: "pw-personal-unicodé-ß", note: "second note ✓" },
  ], cards: [{ name: "Ada Lovelace", number: "4111111111111111", expMonth: "12", expYear: "2031" }],
    ibans: [{ value: "GB82WEST12345698765432", nickname: "Personal IBAN" }],
    keywords: [{ name: "Rekey Search", keyword: "rk", url: "https://rekey.example/search?q={searchTerms}" }],
    history: ["personal.html", "personal-two.html"], extensionOff: true },
  { name: "Work", page: "work.html", cookies: [
    { name: "w_persist", value: "persist-work-3f8" },
    { name: "w_session", value: "session-work-d11", session: true },
    { name: "w_http", value: "httponly-work-a77", httpOnly: true },
  ], passwords: [{ username: "bob", password: "pw-work-456", note: "bob's work note" }],
    cards: [{ name: "Grace Hopper", number: "5555555555554444", expMonth: "06", expYear: "2030" }],
    ibans: [{ value: "DE89370400440532013000", nickname: "Work IBAN" }],
    keywords: [{ name: "Work Search", keyword: "wk", url: "https://work.example/find?q={searchTerms}" }],
    history: ["work.html"], extensionOff: false },
];

const HELP = `const S = () => ac.store.getState(); const C = globalThis.expo.modules.SolaraCEF; const X = globalThis.expo.modules.SolaraExtensions;
const W = () => Object.keys(S().windows)[0]; const P = (id) => (id === "default" ? "" : id);
const seq = (items, f) => items.reduce((p, x) => p.then(() => f(x)), Promise.resolve());`;
const inApp = (app, body, timeout = 20000) => app.eval(`${HELP}\n${body}`, { timeout });

async function waitWindow(app) {
  for (let i = 0; i < 90; i++) {
    const w = await inApp(app, `return W() || null;`, 3000).catch(() => null);
    if (w) return w;
    await sleep(1000);
  }
  throw new Error("no window");
}

async function pageIn(app, profileId, address) {
  const id = JSON.stringify(profileId);
  const url = `${address}?tab=${Date.now()}`;
  await inApp(app, `ac.actions.switchProfile(W(), ${id}); const t = S().newTab(W(), { url: ${JSON.stringify(url)}, profileId: ${id} }); ac.actions.switchToTab(t); return t;`);
  for (let i = 0; i < 40; i++) {
    const page = await app.page(url, { timeout: 0 }).catch(() => null);
    if (page) {
      const state = await page.send("Runtime.evaluate", { expression: "document.readyState", returnByValue: true }).then((r) => r.result?.value, () => null);
      if (state === "complete") return page;
      page.close();
    }
    await sleep(500);
  }
  throw new Error(`no page ${url}`);
}

async function readBack(app, origin, profiles) {
  const out = {};
  out.profiles = await inApp(app, `return S().profileOrder.map((id) => ({ id, name: S().profiles[id].name }));`);
  for (const p of profiles) {
    const r = (out[p.name] = {});
    const page = await pageIn(app, p.id, `${origin}/read-${p.page}`);
    try {
      const { cookies } = await page.send("Network.getCookies", { urls: [`${origin}/`] });
      r.cookies = cookies.map((c) => ({ name: c.name, value: c.value, httpOnly: c.httpOnly, session: c.session })).sort((a, b) => a.name.localeCompare(b.name));
    } finally {
      page.close();
    }
    Object.assign(r, await inApp(app, `const p = P(${JSON.stringify(p.id)}); const r = {};
      return C.unlockPasswords(p).then(() => C.listPasswords(p)).then((l) => { r.passwords = []; return seq((l && l.passwords) || [], (e) => C.getPassword(p, e.origin, e.username).then((v) => { r.passwords.push({ origin: e.origin, username: e.username, password: v && v.password }); })); })
        .then(() => C.listCards(p)).then((l) => { r.cards = []; return seq((l && l.cards) || [], (c) => C.revealCardNumber(p, c.id).then((n) => { r.cards.push({ name: c.name, number: n && n.number }); })); })
        .then(() => X.searchEngineList(p)).then((l) => { r.engines = JSON.parse(JSON.stringify(l)); })
        .then(() => X.list(p)).then((l) => { r.extensions = ((l && l.extensions) || []).map((e) => ({ id: e.id, enabled: !!e.enabled })).sort((a, b) => a.id.localeCompare(b.id)); })
        .then(() => C.engineCall("ac_history_query", p, JSON.stringify({ maxUrls: 200, maxVisits: 5 }))).then((h) => { r.history = (JSON.parse(h).entries || []).map((e) => e.u).sort(); })
        .then(() => r);`, 60000));
    r.passwords?.sort((a, b) => a.username.localeCompare(b.username));
  }
  return out;
}

function plantOffline(userDataDir, profiles, secret = MOCK) {
  const key = keyOf(secret);
  for (const p of profiles) {
    const dir = join(userDataDir, p.dir);
    const login = new DatabaseSync(join(dir, "Login Data"));
    for (const pw of p.plant.passwords) {
      const row = login.prepare("SELECT id FROM logins WHERE username_value = ?").get(pw.username);
      if (!row) throw new Error(`no login ${pw.username} in ${p.dir}`);
      login.prepare("INSERT INTO password_notes (parent_id, key, value, date_created, confidential) VALUES (?, '', ?, ?, 1)")
        .run(row.id, encrypt(key, Buffer.from(pw.note)), chromeNow());
    }
    login.close();
    const web = new DatabaseSync(join(dir, "Web Data"));
    for (const iban of p.plant.ibans)
      web.prepare("INSERT INTO local_ibans (guid, use_count, use_date, value_encrypted, nickname) VALUES (?, 0, 0, ?, ?)")
        .run(randomUUID(), encrypt(key, Buffer.from(iban.value)), iban.nickname);
    for (const k of p.plant.keywords) {
      const id = Number(web.prepare("SELECT max(id) AS m FROM keywords").get().m ?? 0) + 1;
      const now = chromeNow() / 1000000n;
      web.prepare(`INSERT INTO keywords (id, short_name, keyword, favicon_url, url, safe_for_autoreplace, originating_url, date_created, usage_count, input_encodings, suggest_url, prepopulate_id, created_by_policy, last_modified, sync_guid, alternate_urls, image_url, search_url_post_params, suggest_url_post_params, image_url_post_params, new_tab_url, last_visited, created_from_play_api, is_active, starter_pack_id, enforced_by_policy, featured_by_policy, url_hash)
        VALUES (?, ?, ?, '', ?, 0, '', ?, 0, '', '', 0, 0, ?, ?, '[]', '', '', '', '', '', 0, 0, 1, 0, 0, 0, NULL)`)
        .run(id, k.name, k.keyword, k.url, now, now, randomUUID());
    }
    web.close();
  }
}

function leftovers(userDataDir) {
  const left = [];
  for (const n of ["SingletonLock", "SingletonSocket", "SingletonCookie"]) {
    try { lstatSync(join(userDataDir, n)); left.push(n); } catch {}
  }
  for (const file of walk(userDataDir))
    for (const side of ["-wal", "-journal"]) {
      try { if (statSync(file + side).size > 0) left.push(relative(userDataDir, file + side)); } catch {}
    }
  return left;
}

function wanted(origin, profiles) {
  const want = {};
  for (const p of profiles)
    want[p.name] = {
      cookies: p.plant.cookies.map((c) => ({ name: c.name, value: c.value, httpOnly: !!c.httpOnly, session: !!c.session })).sort((a, b) => a.name.localeCompare(b.name)),
      passwords: p.plant.passwords.map((x) => ({ username: x.username, password: x.password })).sort((a, b) => a.username.localeCompare(b.username)),
      cards: p.plant.cards.map((c) => ({ name: c.name, number: c.number })),
      notes: p.plant.passwords.map((x) => x.note).sort(),
      ibans: p.plant.ibans.map((x) => x.value).sort(),
      keywords: p.plant.keywords.map((k) => k.keyword),
      history: p.plant.history.map((h) => `${origin}/${h}`),
      extensionsOff: p.plant.extensionsOff,
    };
  return want;
}

function compare(read, manifest, scanned) {
  const wrong = [];
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  for (const [name, want] of Object.entries(manifest.want)) {
    const got = read[name];
    if (!got) { wrong.push(`${name}: nothing read`); continue; }
    const cookies = (got.cookies ?? []).map(({ name, value, httpOnly, session }) => ({ name, value, httpOnly, session }));
    const expected = want.cookies.filter((c) => manifest.sessionCookiesKept || !c.session);
    if (!same(cookies, expected)) wrong.push(`${name} cookies: ${JSON.stringify(cookies)}`);
    const passwords = (got.passwords ?? []).map((p) => ({ username: p.username, password: p.password }));
    if (!same(passwords, want.passwords)) wrong.push(`${name} passwords: ${JSON.stringify(passwords)}`);
    if (!same(got.cards ?? [], want.cards)) wrong.push(`${name} cards: ${JSON.stringify(got.cards)}`);
    const keywords = (JSON.stringify(got.engines ?? {}).match(/"keyword":"[^"]*"/g) ?? []).map((k) => k.slice(11, -1));
    for (const k of want.keywords) if (!keywords.includes(k)) wrong.push(`${name} search engine ${k} missing`);
    for (const id of want.extensionsOff ?? []) {
      const e = (got.extensions ?? []).find((x) => x.id === id);
      if (!e || e.enabled) wrong.push(`${name} extension ${id} ${e ? "enabled again (a tracked-pref reset?)" : "missing"}`);
    }
    for (const h of want.history) if (!(got.history ?? []).some((u) => u === h || u.startsWith(`${h}?`))) wrong.push(`${name} history ${h} missing`);
    if (scanned) {
      const dir = manifest.profiles.find((p) => p.name === name).dir;
      const notes = (scanned.values[`${dir}/Login Data password_notes.value`] ?? []).slice().sort();
      if (!same(notes, want.notes)) wrong.push(`${name} notes: ${JSON.stringify(notes)}`);
      const ibans = (scanned.values[`${dir}/Web Data local_ibans.value_encrypted`] ?? []).slice().sort();
      if (!same(ibans, want.ibans)) wrong.push(`${name} IBANs: ${JSON.stringify(ibans)}`);
    }
  }
  return wrong;
}

async function makeFixture(app, dir) {
  if (existsSync(join(dir, "template"))) throw new Error(`${dir}/template exists; pick a new fixture dir`);
  const work = join(dir, "making");
  const data = join(work, "data");
  const userDataDir = join(data, "Chromium");
  mkdirSync(work, { recursive: true });
  const { server, origin } = await serve();
  const env = { SOLARA_TEST_REAUTH: "granted", SOLARA_TEST_KEYCHAIN: null, SOLARA_TEST_REKEY: null };
  const opts = (log) => ({ data, onboarded: true, env, log: join(work, log), switches: "--disable-backgrounding-occluded-windows" });
  const profiles = [];
  const extension = join(dir, "extension");
  execFileSync("cp", ["-R", resolve(new URL("../../../packages/solaracore/scripts/fixtures/ext", import.meta.url).pathname), extension]);
  let instance = await launch(app, opts("make.app.log"));
  try {
    await waitWindow(instance);
    const workId = await inApp(instance, `return S().createProfile({ name: "Work", color: "blue" });`);
    await sleep(2500);
    const ids = { Personal: "default", Work: workId };
    for (const plant of PLANT) {
      const id = ids[plant.name];
      for (const h of plant.history) (await pageIn(instance, id, `${origin}/${h}`)).close();
      const page = await pageIn(instance, id, `${origin}/${plant.page}`);
      try {
        for (const c of plant.cookies) {
          const r = await page.send("Network.setCookie", { name: c.name, value: c.value, url: `${origin}/`, path: "/", httpOnly: !!c.httpOnly, ...(c.session ? {} : { expires: Math.floor(Date.now() / 1000) + 31536000 }) });
          if (!r.success) throw new Error(`Network.setCookie refused ${c.name}`);
        }
      } finally {
        page.close();
      }
      await inApp(instance, `const p = P(${JSON.stringify(id)});
        return seq(${JSON.stringify(plant.passwords)}, (x) => C.savePassword(p, ${JSON.stringify(origin)}, x.username, x.password).then((r) => { if (!r || !r.ok) throw new Error("savePassword " + JSON.stringify(r)); }))
          .then(() => seq(${JSON.stringify(plant.cards)}, (c) => C.saveCard(p, { name: c.name, expMonth: c.expMonth, expYear: c.expYear }, c.number).then((r) => { if (!r || !r.id) throw new Error("saveCard " + JSON.stringify(r)); })))
          .then(() => "ok");`, 60000);
      plant.extensionsOff = [];
      if (plant.extensionOff) {
        const off = await inApp(instance, `const p = P(${JSON.stringify(id)});
          return X.install(${JSON.stringify(extension)}, p).then(() => X.list(p)).then((l) => { const e = ((l && l.extensions) || []).find((e) => e.name === "SolaraCore spike extension"); if (!e) throw new Error("the fixture extension didn't install: " + JSON.stringify(l)); return X.setEnabled(e.id, p, false).then(() => e.id); });`, 60000);
        plant.extensionsOff.push(off);
      }
      profiles.push({ id, name: plant.name, page: plant.page, plant });
      console.log(`planted ${plant.name} (${id})`);
    }
    await sleep(4000);
  } finally {
    console.log(`quit: ${(await instance.quit()).how}`);
  }
  const cache = JSON.parse(readFileSync(join(userDataDir, "Local State"), "utf8")).profile?.info_cache ?? {};
  for (const p of profiles) {
    p.dir = p.id === "default" ? "Default" : Object.keys(cache).find((d) => d.includes(p.id));
    if (!p.dir) throw new Error(`no profile dir for ${p.id} among ${Object.keys(cache)}`);
  }
  const atQuit = scan(userDataDir);
  console.log(`session cookies on disk after a quit: ${(atQuit.values["Default/Cookies cookies.encrypted_value"] ?? []).includes("httponly-session-personal-5be")}`);
  plantOffline(userDataDir, profiles);
  instance = await launch(app, opts("check.app.log"));
  let read;
  try {
    await waitWindow(instance);
    await sleep(2000);
    read = await readBack(instance, origin, profiles);
    await sleep(3000);
  } finally {
    await instance.quit();
    server.close();
  }
  const scanned = scan(userDataDir);
  const manifest = {
    made: new Date().toISOString(),
    app,
    origin,
    sessionCookiesKept: read.Personal.cookies.some((c) => c.name === "p_session"),
    profiles: profiles.map((p) => ({ id: p.id, name: p.name, dir: p.dir, page: p.page })),
    want: wanted(origin, profiles),
    mockHits: scanned.hits,
    tracked: trackedPrefs(userDataDir, profiles.map((p) => p.dir)),
  };
  const resets = Object.entries(manifest.tracked).filter(([, t]) => t.resetTime);
  if (resets.length) throw new Error(`Chrome reset tracked prefs while making the fixture: ${resets.map(([d]) => d).join(", ")}`);
  writeFileSync(join(dir, "baseline-read.json"), JSON.stringify(read, null, 2));
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest, null, 2));
  const wrong = compare(read, manifest, scanned);
  if (wrong.length) throw new Error(`the mock relaunch didn't read back what was planted:\n  ${wrong.join("\n  ")}`);
  for (const f of ["dev-eval.js", "dev-eval-result.json", "instance.json", "perf-probe"]) rmSync(join(data, f), { force: true });
  const left = leftovers(userDataDir);
  if (left.length) throw new Error(`the quit dir isn't clean: ${left.join(", ")}`);
  if (existsSync(join(userDataDir, "Test Safe Storage Key"))) throw new Error("a test keychain key is in the template");
  execFileSync("cp", ["-c", "-R", data, join(dir, "template")]);
  execFileSync("chmod", ["-R", "a-w", join(dir, "template")]);
  console.log(`template ${join(dir, "template")} (read-only), manifest ${join(dir, "manifest.json")}`);
  console.log(`session cookies kept across a relaunch: ${manifest.sessionCookiesKept}`);
  console.log(`mock-keyed values per column:\n  ${Object.entries(scanned.hits).map(([k, v]) => `${k}: ${v}`).join("\n  ")}`);
}

async function makeOtherKey(app, dir) {
  const work = join(dir, "making-other-key");
  const data = join(work, "data");
  const userDataDir = join(data, "Chromium");
  mkdirSync(work, { recursive: true });
  const { server, origin } = await serve();
  const instance = await launch(app, { data, onboarded: true, env: { SOLARA_TEST_REAUTH: "granted", SOLARA_TEST_KEYCHAIN: "file", SOLARA_TEST_REKEY: null }, log: join(work, "make.app.log") });
  try {
    await waitWindow(instance);
    const page = await pageIn(instance, "default", `${origin}/other.html`);
    try {
      const r = await page.send("Network.setCookie", { name: "o_persist", value: "persist-other-key", url: `${origin}/`, path: "/", expires: Math.floor(Date.now() / 1000) + 31536000 });
      if (!r.success) throw new Error("Network.setCookie refused o_persist");
    } finally {
      page.close();
    }
    await inApp(instance, `return C.savePassword("", ${JSON.stringify(origin)}, "olga", "pw-other-key").then((r) => { if (!r || !r.ok) throw new Error("savePassword " + JSON.stringify(r)); return 1; });`, 60000);
    await sleep(4000);
  } finally {
    await instance.quit();
    server.close();
  }
  const secret = readFileSync(join(userDataDir, "Test Safe Storage Key"), "latin1");
  const hits = scan(userDataDir, secret).hits;
  if (!Object.keys(hits).some((w) => w.endsWith("logins.password_value")) || Object.keys(scan(userDataDir, MOCK).hits).length) throw new Error(`the other-key data isn't under its own key: ${JSON.stringify(hits)}`);
  unlinkSync(join(userDataDir, "Test Safe Storage Key"));
  rmSync(join(userDataDir, "Test Safe Storage Log"), { force: true });
  for (const f of ["dev-eval.js", "dev-eval-result.json", "instance.json", "perf-probe"]) rmSync(join(data, f), { force: true });
  const left = leftovers(userDataDir);
  if (left.length) throw new Error(`the quit dir isn't clean: ${left.join(", ")}`);
  execFileSync("cp", ["-c", "-R", data, join(dir, "other-key")]);
  execFileSync("chmod", ["-R", "a-w", join(dir, "other-key")]);
  console.log(`other-key ${join(dir, "other-key")} (read-only): ${JSON.stringify(hits)} under a random key, its item removed`);
}

const KEY_FILE = "Test Safe Storage Key";
const KEY_LOG = "Test Safe Storage Log";
const read = (file) => { try { return readFileSync(file, "utf8"); } catch { return null; } };
const UNFINISHED = "This copy of Solara can't finish moving your saved passwords and cookies to their new key. Open the installed Solara instead.";
const isRealSecret = (s) => typeof s === "string" && /^[A-Za-z0-9+/]{22}==$/.test(s);

function snapshot(run) {
  const udd = run.udd;
  let journal = null;
  try { journal = JSON.parse(readFileSync(join(udd, ".safe-storage-rekey.json"), "utf8")); } catch {}
  return {
    key: read(join(udd, KEY_FILE)),
    keyLog: (read(join(udd, KEY_LOG)) ?? "").split("\n").filter(Boolean),
    rekeyLog: read(join(udd, ".safe-storage-rekey.log")) ?? "",
    journal,
    staging: filesUnder(join(udd, ".rekey-staging")).length > 0,
    stagingDir: existsSync(join(udd, ".rekey-staging")),
    old: existsSync(join(udd, ".rekey-old")),
    appLog: run.logs.map((f) => read(f) ?? "").join("\n"),
  };
}
const count = (lines, what) => lines.filter((l) => l === what).length;
const points = (appLog) => [...appLog.matchAll(/\[rekey\] point (\S+)/g)].map((m) => m[1]);
const dialogShown = (appLog) => /Safe Storage key unreadable/.test(appLog);

function prepare(root, name, fixture, { from = "template" } = {}) {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  const data = join(dir, "data");
  if (from) {
    execFileSync("cp", ["-c", "-R", join(fixture, from), data]);
    execFileSync("chmod", ["-R", "u+w", data]);
  } else mkdirSync(data);
  const run = { dir, data, udd: join(data, "Chromium"), logs: [], launches: 0 };
  made.push(run);
  return run;
}

const made = [];
function discard(runs) {
  for (const run of runs) {
    if (!existsSync(run.dir)) continue;
    execFileSync("chmod", ["-R", "u+w", run.dir]);
    rmSync(run.dir, { recursive: true, force: true });
  }
}

function cloneApp(app, root) {
  const clone = join(root, "Solara.app");
  if (!existsSync(clone)) execFileSync("cp", ["-c", "-R", app, clone]);
  return clone;
}

async function start(app, run, env, { until = "devtools", timeout = 120000 } = {}) {
  const binary = binaryOf(app);
  const port = await freePort();
  const log = join(run.dir, `launch-${++run.launches}.log`);
  run.logs.push(log);
  writeFileSync(join(run.data, "onboarding.json"), JSON.stringify({ version: 1, completedAt: 1 }));
  const full = { SOLARA_BACKGROUND: "1", SOLARA_DATA_DIR: run.data, SOLARA_REMOTE_DEBUGGING_PORT: String(port), SOLARA_JS_LOCATION: "localhost:8081", SOLARA_TEST_REAUTH: "granted", ...env };
  const before = binaryPids(binary);
  if (before.size) throw new Error(`${binary} is already running (${[...before]})`);
  await uiGateLaunching(binary);
  const launchedAt = Date.now();
  execFileSync("open", ["-g", "-n", ...Object.entries(full).filter(([, v]) => v !== null && v !== undefined).flatMap(([k, v]) => ["--env", `${k}=${v}`]), "--stdout", log, "--stderr", log, app]);
  let pid = null;
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (!pid && (pid = [...binaryPids(binary)][0] ?? null)) uiGateWatch(pid, run.data);
    const text = read(log) ?? "";
    if (pid && !isAlive(pid)) return { outcome: dialogShown(read(log) ?? "") ? "dialog" : "exited", pid, ms: Date.now() - launchedAt };
    if (!pid && Date.now() - launchedAt > 15000) return { outcome: "exited", pid: null, ms: Date.now() - launchedAt };
    if (dialogShown(text)) {
      if (pid) await stop(pid);
      return { outcome: "dialog", pid, ms: Date.now() - launchedAt };
    }
    if (pid && until === "decision" && (/not migrating|: quitting/.test(read(join(run.udd, ".safe-storage-rekey.log")) ?? "") || listenerPids(port).includes(pid))) {
      await stop(pid);
      return { outcome: "decided", pid, ms: Date.now() - launchedAt };
    }
    if (pid && until === "devtools" && listenerPids(port).includes(pid)) {
      const info = processInfo(pid);
      writeFileSync(join(run.data, "instance.json"), JSON.stringify({ app, binary, data: run.data, port, log, launchedAt, js: { mode: "live", metroPort: 8081 }, pid, started: info.started, meta: {} }));
      return { outcome: "running", pid, instance: attach(run.data), ms: Date.now() - launchedAt };
    }
    await sleep(100);
  }
  if (pid) await stop(pid);
  return { outcome: "timeout", pid, ms: Date.now() - launchedAt };
}

async function stop(pid) {
  if (!pid || !isAlive(pid)) return;
  try { process.kill(pid, "SIGKILL"); } catch {}
  for (const end = Date.now() + 5000; isAlive(pid) && Date.now() < end; await sleep(100));
}

async function settle(app, run, origin, profiles) {
  const instance = run.started.instance;
  await waitWindow(instance);
  await sleep(1500);
  const r = await readBack(instance, origin, profiles);
  await sleep(1000);
  await instance.quit();
  return r;
}

function migratedState(run, manifest, { fromA = false, allowUnlisted = [] } = {}) {
  const s = snapshot(run);
  const wrong = [];
  if (s.journal?.phase !== "done") wrong.push(`journal ${JSON.stringify(s.journal?.phase)}`);
  if (!isRealSecret(s.key)) wrong.push(`key file ${JSON.stringify(s.key)}`);
  const adds = count(s.keyLog, "add created"), updates = count(s.keyLog, "rekey update done");
  if (fromA ? adds !== 0 || updates !== 1 : adds !== 1 || updates !== 0) wrong.push(`file keychain: ${adds} add created, ${updates} rekey update done`);
  if (s.keyLog.some((l) => /add-or-update|item (add|update|delete)/.test(l))) wrong.push(`file keychain: ${s.keyLog.filter((l) => /add-or-update|item /.test(l)).join(", ")}`);
  if (dialogShown(s.appLog)) wrong.push("Chrome's Safe Storage dialog");
  const mock = scan(run.udd, MOCK);
  const left = Object.entries(mock.hits).filter(([w]) => !allowUnlisted.some((u) => w.includes(u)));
  if (left.length) wrong.push(`still mock-keyed: ${left.map(([w, n]) => `${w} ${n}`).join(", ")}`);
  const fresh = isRealSecret(s.key) ? scan(run.udd, s.key) : { hits: {}, values: {} };
  const counts = (h) => JSON.stringify(Object.entries(h).filter(([w]) => !w.endsWith(" prefs") && !allowUnlisted.some((u) => w.includes(u))).sort());
  if (counts(fresh.hits) !== counts(manifest.mockHits)) wrong.push(`under the new key ${counts(fresh.hits)}, made ${counts(manifest.mockHits)}`);
  wrong.push(...trackedChanges(manifest.tracked ?? {}, trackedPrefs(run.udd, manifest.profiles.map((p) => p.dir))).map((w) => `tracked pref ${w}`));
  return { wrong, snapshot: s, scanned: fresh };
}

function intactState(run, manifest, { key = [null] } = {}) {
  const s = snapshot(run);
  const wrong = [];
  if (!key.includes(s.key)) wrong.push(`key file ${JSON.stringify(s.key)}`);
  if (s.staging || s.old) wrong.push("re-key folders left");
  const mock = scan(run.udd, MOCK);
  const counts = (h) => JSON.stringify(Object.entries(h).filter(([w]) => !w.endsWith(" prefs")).sort());
  if (counts(mock.hits) !== counts(manifest.mockHits)) wrong.push(`mock-keyed ${counts(mock.hits)}, made ${counts(manifest.mockHits)}`);
  wrong.push(...trackedChanges(manifest.tracked ?? {}, trackedPrefs(run.udd, manifest.profiles.map((p) => p.dir))).map((w) => `tracked pref ${w}`));
  return { wrong, snapshot: s, scanned: mock };
}

const REKEY = { SOLARA_TEST_KEYCHAIN: "file", SOLARA_TEST_REKEY: "1" };
const FILE_ONLY = { SOLARA_TEST_KEYCHAIN: "file" };

function seedKey(run, secret) {
  writeFileSync(join(run.udd, KEY_FILE), secret, { mode: 0o600 });
}

async function migrateAndCheck(ctx, run, env, opts = {}) {
  const lines = [];
  run.started = await start(ctx.app, run, env);
  if (run.started.outcome !== "running") {
    const s = snapshot(run);
    return [{ ok: false, name: "the migrated launch reaches Chrome", detail: `${run.started.outcome}; ${s.rekeyLog.trim().split("\n").slice(-3).join(" | ")}` }];
  }
  let readBackResult;
  try {
    readBackResult = await settle(ctx.app, run, ctx.origin, ctx.profiles);
  } catch (e) {
    await stop(run.started.pid);
    return [{ ok: false, name: "the migrated launch reads back", detail: String(e.message ?? e) }];
  }
  const state = migratedState(run, ctx.manifest, opts);
  lines.push({ ok: !state.wrong.length, name: "migrated: key, journal, file keychain, nothing mock-keyed, counts under the new key", detail: state.wrong.join("; ") });
  const rows = loginDataChanges(join(ctx.fixture, "template"), run.udd, ctx.manifest.profiles.map((p) => p.dir));
  lines.push({ ok: !rows.length, name: "Login Data unchanged but for the ciphertexts: meta rows, every login's dates, every other table", detail: rows.join("; ") });
  const wrong = compare(readBackResult, ctx.manifest, state.scanned);
  lines.push({ ok: !wrong.length, name: "every planted value reads back through Chrome (notes and IBANs under the new key)", detail: wrong.join("; ") });
  run.started = await start(ctx.app, run, env);
  if (run.started.outcome === "running") await run.started.instance.quit();
  const after = snapshot(run);
  lines.push({ ok: run.started.outcome === "running" && after.journal?.phase === "done" && !after.staging && after.old && !dialogShown(after.appLog) && isRealSecret(after.key), name: "the next launch of the same version: no dialog, no staging left, the originals kept in .rekey-old", detail: `${run.started.outcome}, journal ${JSON.stringify(after.journal?.phase)}, staging ${after.staging}, old ${after.old}` });
  return lines;
}

const CASES = {
  async "baseline-a"(ctx) {
    const run = prepare(ctx.root, "baseline-a", ctx.fixture);
    seedKey(run, MOCK);
    run.started = await start(ctx.app, run, FILE_ONLY);
    if (run.started.outcome !== "running") return [{ ok: false, name: "reaches Chrome", detail: run.started.outcome }];
    const r = await settle(ctx.app, run, ctx.origin, ctx.profiles);
    const state = intactState(run, ctx.manifest, { key: [MOCK] });
    const wrong = compare(r, ctx.manifest, state.scanned);
    const s = snapshot(run);
    return [
      { ok: !wrong.length, name: "option A by hand: every planted value reads back", detail: wrong.join("; ") },
      { ok: !state.wrong.length && !dialogShown(s.appLog) && count(s.keyLog, "add created") === 0, name: "no dialog, no add, data still on the mock key", detail: `${state.wrong.join("; ")} log ${s.keyLog.join(", ")}` },
    ];
  },
  async today(ctx) {
    const run = prepare(ctx.root, "today", ctx.fixture);
    run.started = await start(ctx.app, run, FILE_ONLY, { until: "dialog", timeout: 90000 });
    const state = intactState(run, ctx.manifest);
    return [{ ok: run.started.outcome === "dialog" && !state.wrong.length, name: "no item, no re-key: Chrome's dialog, nothing changed", detail: `${run.started.outcome}; ${state.wrong.join("; ")}` }];
  },
  async migrate(ctx) {
    const run = prepare(ctx.root, "migrate", ctx.fixture);
    const lines = await migrateAndCheck(ctx, run, REKEY);
    const s = snapshot(run);
    ctx.points = [...new Set(points(s.appLog))];
    lines.push({ ok: ctx.points.length > 0, name: "the test build names its crash points", detail: ctx.points.join(" ") });
    return lines;
  },
  async crash(ctx) {
    if (!ctx.points?.length) await CASES.migrate(ctx);
    const lines = [];
    const only = ctx.only.filter((c) => c.startsWith("crash:")).map((c) => c.slice(6));
    for (const point of only.length ? only : ctx.points) {
      const run = prepare(ctx.root, `crash-${point}`, ctx.fixture);
      run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: point });
      const died = run.started.outcome === "exited" && points(snapshot(run).appLog).at(-1) === point;
      if (!died) { lines.push({ ok: false, name: `crash at ${point}`, detail: `${run.started.outcome}, last point ${points(snapshot(run).appLog).at(-1)}` }); continue; }
      const result = await recoverAndCheck(ctx, run, `crash at ${point}`);
      lines.push(...result);
      if (!ctx.keep && result.every((l) => l.ok)) discard([run]);
    }
    return lines;
  },
  async truncated(ctx) {
    const run = prepare(ctx.root, "truncated", ctx.fixture);
    run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: "after-staged" });
    const staged = join(run.udd, ".rekey-staging", "Default", "Login Data");
    if (run.started.outcome !== "exited" || !existsSync(staged)) return [{ ok: false, name: "a staged Login Data to truncate", detail: `${run.started.outcome}, staged ${existsSync(staged)}` }];
    const size = statSync(staged).size;
    truncateSync(staged, Math.floor(size / 2));
    return recoverAndCheck(ctx, run, `a staged Login Data cut from ${size} to ${Math.floor(size / 2)} bytes`);
  },
  async "item-present"(ctx) {
    const run = prepare(ctx.root, "item-present", ctx.fixture);
    const other = randomBytes(16).toString("base64");
    seedKey(run, other);
    run.started = await start(ctx.app, run, REKEY, { until: "decision", timeout: 60000 });
    return notMigrated(ctx, run, "a key already in the keychain", /exists and isn't the mock key: not migrating/, [other]);
  },
  async "keychain-denied"(ctx) {
    const run = prepare(ctx.root, "keychain-denied", ctx.fixture);
    run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_KEYCHAIN_FAIL: "denied" }, { until: "decision", timeout: 60000 });
    return notMigrated(ctx, run, "keychain access denied", /can't be looked up \(-25293\): not migrating/, [null]);
  },
  async "keychain-interaction"(ctx) {
    const run = prepare(ctx.root, "keychain-interaction", ctx.fixture);
    run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_KEYCHAIN_FAIL: "interaction" }, { until: "decision", timeout: 60000 });
    return notMigrated(ctx, run, "keychain locked", /can't be looked up \(-25315\): not migrating/, [null]);
  },
  async fresh(ctx) {
    const run = prepare(ctx.root, "fresh", ctx.fixture, { from: null });
    run.started = await start(ctx.app, run, REKEY);
    if (run.started.outcome === "running") { await waitWindow(run.started.instance); await run.started.instance.quit(); }
    const s = snapshot(run);
    return [{ ok: run.started.outcome === "running" && !s.journal && !s.rekeyLog && !s.staging && count(s.keyLog, "add created") === 1 && isRealSecret(s.key), name: "a fresh dir: no re-key; Chrome makes its key once", detail: `${run.started.outcome}, journal ${JSON.stringify(s.journal)}, log ${JSON.stringify(s.rekeyLog.slice(0, 120))}, keychain ${s.keyLog.join(", ")}` }];
  },
  async "other-key"(ctx) {
    const source = join(ctx.fixture, "other-key");
    if (!existsSync(source)) return [{ ok: false, name: "other-key fixture", detail: `${source} is missing (fixture --other-key)` }];
    const run = prepare(ctx.root, "other-key", ctx.fixture, { from: "other-key" });
    run.started = await start(ctx.app, run, REKEY, { until: "decision", timeout: 60000 });
    if (run.started.outcome === "running") await run.started.instance.quit();
    const s = snapshot(run);
    const ok = /isn't provably mock-keyed: not migrating/.test(s.rekeyLog) && s.key === null && !s.staging && !s.old && !(s.journal && s.journal.phase !== "abandoned");
    return [{ ok, name: "data under another key, no item: not migrating, no key made by the re-key", detail: `${run.started.outcome}; ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}; key ${JSON.stringify(s.key)}` }];
  },
  async singleton(ctx) {
    const run = prepare(ctx.root, "singleton", ctx.fixture);
    const holderApp = join(run.dir, "Holder.app");
    execFileSync("cp", ["-c", "-R", ctx.app, holderApp]);
    const holderBinary = join(holderApp, "Contents", "MacOS", "rekey-holder");
    execFileSync("cp", ["/bin/sleep", holderBinary]);
    const holder = spawn(holderBinary, ["300"], { stdio: "ignore" });
    try {
      symlinkSync(`${hostname()}-${holder.pid}`, join(run.udd, "SingletonLock"));
      run.started = await start(ctx.app, run, REKEY, { until: "exit", timeout: 60000 });
    } finally {
      holder.kill("SIGKILL");
    }
    const s = snapshot(run);
    try { unlinkSync(join(run.udd, "SingletonLock")); } catch {}
    const state = intactState(run, ctx.manifest);
    return [{ ok: run.started.outcome === "exited" && /another copy owns the data dir: quitting/.test(s.rekeyLog) && !state.wrong.length && !s.journal, name: "another copy holds SingletonLock: quits, nothing changed, no key", detail: `${run.started.outcome}; ${state.wrong.join("; ")}; ${s.rekeyLog.trim().split("\n").slice(-1)}` }];
  },
  async "unknown-column"(ctx) {
    const run = prepare(ctx.root, "unknown-column", ctx.fixture);
    const db = new DatabaseSync(join(run.udd, "Default", "Login Data"));
    db.exec("ALTER TABLE logins ADD COLUMN rekey_unknown BLOB");
    db.prepare("UPDATE logins SET rekey_unknown = ? WHERE username_value = 'alice'").run(encrypt(keyOf(MOCK), Buffer.from("a secret in a column nobody listed")));
    db.close();
    const plantedHits = { ...ctx.manifest.mockHits, "Default/Login Data logins.rekey_unknown": 1 };
    run.started = await start(ctx.app, run, REKEY);
    let r = null;
    if (run.started.outcome === "running") r = await settle(ctx.app, run, ctx.origin, ctx.profiles).catch((e) => ({ error: String(e.message) }));
    const s = snapshot(run);
    const mock = scan(run.udd, MOCK);
    const counts = (h) => JSON.stringify(Object.entries(h).sort());
    const wrong = r && !r.error ? compare(r, ctx.manifest, mock) : [r?.error ?? run.started.outcome];
    return [
      { ok: s.key === MOCK && s.journal?.phase === "abandoned" && !s.staging && !s.old && counts(mock.hits) === counts(plantedHits), name: "a mock-keyed value in an unlisted column of a listed store: falls back to A, data intact", detail: `key ${JSON.stringify(s.key)}, journal ${JSON.stringify(s.journal?.phase)}, ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}` },
      { ok: !wrong.length && !dialogShown(s.appLog), name: "after the fallback every planted value reads back", detail: wrong.join("; ") },
    ];
  },
  async "unlisted-v10"(ctx) {
    const run = prepare(ctx.root, "unlisted-v10", ctx.fixture);
    const db = new DatabaseSync(join(run.udd, "Default", "History"));
    db.prepare("UPDATE urls SET title = ? WHERE id = (SELECT min(id) FROM urls)").run(encrypt(keyOf(MOCK), Buffer.from("a title that decrypts")));
    db.close();
    const lines = await migrateAndCheck(ctx, run, REKEY, { allowUnlisted: ["History urls.title"] });
    const s = snapshot(run);
    lines.push({ ok: /History/.test(s.rekeyLog), name: "the v10-looking title in an unlisted database is logged", detail: s.rekeyLog.split("\n").filter((l) => /History|unlisted|preflight/.test(l)).join(" | ") });
    return lines;
  },
  async undo(ctx) {
    const run = prepare(ctx.root, "undo", ctx.fixture);
    run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_FAIL_AFTER_KEY: "1" });
    let r = null;
    if (run.started.outcome === "running") r = await settle(ctx.app, run, ctx.origin, ctx.profiles).catch((e) => ({ error: String(e.message) }));
    const s = snapshot(run);
    ctx.undoPoints = [...new Set(points(s.appLog))].filter((p) => p.startsWith("after-undo"));
    const state = intactState(run, ctx.manifest, { key: [MOCK] });
    const wrong = r && !r.error ? compare(r, ctx.manifest, state.scanned) : [r?.error ?? run.started.outcome];
    return [
      { ok: s.journal?.phase === "abandoned" && !state.wrong.length && count(s.keyLog, "rekey update done") === 1 && count(s.keyLog, "add created") === 1, name: "a failure after the key: undone to A (one add, one update back to mock_password), data intact", detail: `journal ${JSON.stringify(s.journal?.phase)}; ${state.wrong.join("; ")}; ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}` },
      { ok: !wrong.length && !dialogShown(s.appLog), name: "after the undo every planted value reads back", detail: wrong.join("; ") },
      { ok: ctx.undoPoints.length > 0, name: "the undo names its crash points", detail: ctx.undoPoints.join(" ") },
    ];
  },
  async "undo-crash"(ctx) {
    if (!ctx.undoPoints?.length) await CASES.undo(ctx);
    const lines = [];
    for (const point of ctx.undoPoints ?? []) {
      const run = prepare(ctx.root, `undo-crash-${point}`, ctx.fixture);
      run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_FAIL_AFTER_KEY: "1", SOLARA_TEST_REKEY_CRASH: point });
      const died = run.started.outcome === "exited" && points(snapshot(run).appLog).at(-1) === point;
      if (!died) { lines.push({ ok: false, name: `undo crash at ${point}`, detail: `${run.started.outcome}, last point ${points(snapshot(run).appLog).at(-1)}` }); continue; }
      const result = await recoverAndCheck(ctx, run, `undo crash at ${point}`, { SOLARA_TEST_REKEY_FAIL_AFTER_KEY: "1" });
      lines.push(...result);
      if (!ctx.keep && result.every((l) => l.ok)) discard([run]);
    }
    return lines;
  },
  async "sync-reads"(ctx) {
    const run = prepare(ctx.root, "sync-reads", ctx.fixture);
    run.started = await start(ctx.app, run, REKEY);
    if (run.started.outcome !== "running") return [{ ok: false, name: "the migrated launch reaches Chrome", detail: run.started.outcome }];
    const got = await syncRead(ctx, run);
    await run.started.instance.quit();
    const s = snapshot(run);
    const want = Object.fromEntries(Object.entries(ctx.manifest.want).map(([n, w]) => [n, w.passwords.map((p) => `${p.username}=${p.password}`).sort()]));
    return [{ ok: s.journal?.phase === "done" && JSON.stringify(got) === JSON.stringify(want), name: "after the re-key sync decrypts every password with the key file's bytes (the same secret Chrome's FileKeychain uses)", detail: `journal ${s.journal?.phase}; got ${JSON.stringify(got)}` }];
  },
  async "sync-pause"(ctx) {
    const run = prepare(ctx.root, "sync-pause", ctx.fixture);
    run.started = await start(ctx.app, run, REKEY);
    if (run.started.outcome !== "running") return [{ ok: false, name: "the migrated launch reaches Chrome", detail: run.started.outcome }];
    await run.started.instance.quit();
    const counts = () => Object.fromEntries(ctx.manifest.profiles.map((p) => {
      const db = openRead(join(run.udd, p.dir, "Login Data"));
      try { return [p.dir, [db.prepare("SELECT count(*) AS n FROM logins").get().n, db.prepare("SELECT count(*) AS n FROM password_notes").get().n].join("/")]; } finally { db.close(); }
    }));
    const before = counts();
    seedKey(run, randomBytes(16).toString("base64"));
    const folder = join(run.dir, "folder");
    mkdirSync(folder);
    run.started = await start(ctx.app, run, REKEY);
    if (run.started.outcome !== "running") return [{ ok: false, name: "the launch over a replaced key reaches Chrome", detail: run.started.outcome }];
    let read = null;
    try { read = await syncRead(ctx, run); } finally { await run.started.instance.quit(); }
    run.started = await start(ctx.app, run, { ...REKEY, SOLARA_SYNC_REDESIGN: "1", SOLARA_SYNC_DEFAULT_FOLDER: folder });
    if (run.started.outcome !== "running") return [{ ok: false, name: "the sealed launch over a replaced key reaches Chrome", detail: run.started.outcome }];
    const app = run.started.instance;
    let state = null;
    try {
      await waitWindow(app);
      const on = await app.eval(`return acSync.turnOnSync(${JSON.stringify(folder)})`, { timeout: 90000 });
      for (let i = 0; i < 3; i++) { await app.eval("return acSync.syncNow()", { timeout: 90000 }); await sleep(1000); }
      state = { on, ...(await app.eval("const u = acSync.useSync.getState(); return { status: u.status, error: u.error, passwordsError: u.passwordsError ?? null, pending: u.pending };", { timeout: 20000 })) };
    } finally {
      await app.quit();
    }
    const s = snapshot(run);
    const after = counts();
    const paused = /saved passwords didn't decrypt; not syncing passwords now/.test(s.appLog);
    const sealedFiles = readdirSync(folder, { recursive: true }).map(String);
    let ledger = null;
    try { ledger = JSON.parse(readFileSync(join(run.data, "sync-pw-ledger.json"), "utf8")); } catch {}
    const marked = ctx.manifest.profiles.filter((p) => {
      const db = openRead(join(run.udd, p.dir, "Login Data"));
      try { return !!db.prepare("SELECT value FROM meta WHERE key = 'solara_sync_ledger'").get(); } finally { db.close(); }
    }).map((p) => p.name);
    return [
      { ok: Object.values(read ?? {}).every((v) => v === null), name: "with Chrome's key replaced (a reset or Start Over), sync's read of every profile is nil", detail: JSON.stringify(read) },
      { ok: paused && !Object.keys(ledger?.profiles ?? {}).length && !marked.length, name: "sync logs the pause and writes no ledger entry and no mark", detail: `${JSON.stringify(state)}; ledger ${JSON.stringify(Object.keys(ledger?.profiles ?? {}))}; marked ${marked}` },
      { ok: JSON.stringify(before) === JSON.stringify(after), name: "no login and no note deleted from Login Data", detail: `${JSON.stringify(before)} → ${JSON.stringify(after)}` },
      { ok: s.journal?.phase === "done" && !/migrating|undoing/.test(s.rekeyLog.split("\n").slice(-3).join(" ")), name: "the re-key leaves a replaced item alone", detail: `${s.journal?.phase}; files ${sealedFiles.length}` },
    ];
  },
  async "sync-ledger"(ctx) {
    const run = prepare(ctx.root, "sync-ledger", ctx.fixture);
    const folder = join(run.dir, "folder");
    mkdirSync(folder);
    const env = { ...REKEY, SOLARA_SYNC_REDESIGN: "1", SOLARA_SYNC_DEFAULT_FOLDER: folder };
    run.started = await start(ctx.app, run, env);
    if (run.started.outcome !== "running") return [{ ok: false, name: "the migrating sealed launch reaches Chrome", detail: run.started.outcome }];
    const a = run.started.instance;
    let phrase, heldA;
    try {
      await waitWindow(a);
      const sealing = await a.eval("return acSync.sealing()", { timeout: 20000 });
      if (sealing !== true) throw new Error(`launched with SOLARA_SYNC_REDESIGN=1 but sealing is ${sealing}`);
      const on = await a.eval(`return acSync.turnOnSync(${JSON.stringify(folder)})`, { timeout: 90000 });
      if (JSON.stringify(on) !== '{"ok":true}') throw new Error(`turnOnSync ${JSON.stringify(on)}`);
      phrase = (await a.eval("return acSync.native.recoveryWords()", { timeout: 20000 })).join(" ");
      for (let i = 0; i < 4; i++) { await a.eval("return acSync.syncNow()", { timeout: 90000 }); await sleep(1000); }
      heldA = await a.eval("return acSync.useSync.getState().heldPasswords ?? null", { timeout: 20000 });
    } finally {
      await a.quit();
    }
    const s = snapshot(run);
    const lines = [];
    let ledger = null;
    try { ledger = JSON.parse(readFileSync(join(run.data, "sync-pw-ledger.json"), "utf8")); } catch {}
    const marks = {};
    const wrongMarks = [];
    for (const p of ctx.manifest.profiles) {
      const key = p.id === "default" ? "" : p.id;
      const entry = ledger?.profiles?.[key];
      const db = openRead(join(run.udd, p.dir, "Login Data"));
      try { marks[p.dir] = db.prepare("SELECT value FROM meta WHERE key = 'solara_sync_ledger'").get()?.value ?? null; } finally { db.close(); }
      if (!entry?.L || entry.t === undefined) wrongMarks.push(`${p.name}: no ledger entry`);
      else if (marks[p.dir] !== `${entry.L}@${entry.t}`) wrongMarks.push(`${p.name}: mark ${marks[p.dir]} ≠ ledger ${entry.L}@${entry.t}`);
      if (entry && (entry.held ?? []).length) wrongMarks.push(`${p.name}: held ${JSON.stringify(entry.held)}`);
      const keys = Object.keys(entry?.keys ?? {}).filter((k) => k.startsWith("pw:")).length;
      if (entry && keys !== ctx.manifest.want[p.name].passwords.length) wrongMarks.push(`${p.name}: ${keys} pw keys in the ledger`);
    }
    lines.push({ ok: s.journal?.phase === "done", name: "the re-key ran before sync", detail: s.journal?.phase });
    lines.push({ ok: !wrongMarks.length, name: "the first sealed ledger: each profile's mark in Login Data's meta equals its ledger L@t, every password keyed, nothing held", detail: `${wrongMarks.join("; ")} held ${JSON.stringify(heldA)}` });
    const rows = loginDataChanges(join(ctx.fixture, "template"), run.udd, ctx.manifest.profiles.map((p) => p.dir), { ignoreMeta: ["solara_sync_ledger"] });
    lines.push({ ok: !rows.length, name: "Login Data after the re-key and the ledger: unchanged but for ciphertexts and the mark (dates, notes, rows)", detail: rows.join("; ") });
    const b = prepare(ctx.root, "sync-ledger-b", ctx.fixture, { from: null });
    const bApp = join(ctx.root, "B.app");
    if (!existsSync(bApp)) execFileSync("cp", ["-c", "-R", ctx.app, bApp]);
    b.started = await start(bApp, b, { SOLARA_SYNC_REDESIGN: "1", SOLARA_SYNC_DEFAULT_FOLDER: folder });
    if (b.started.outcome !== "running") return [...lines, { ok: false, name: "a second Mac starts", detail: b.started.outcome }];
    let seen = null;
    try {
      const bi = b.started.instance;
      await waitWindow(bi);
      const joined = await bi.eval(`return acSync.enterRecoveryPhrase(${JSON.stringify(folder)}, ${JSON.stringify(phrase)})`, { timeout: 90000 });
      if (JSON.stringify(joined) !== '{"ok":true}') throw new Error(`enterRecoveryPhrase ${JSON.stringify(joined)}`);
      const want = ctx.manifest.want.Personal.passwords.map((p) => `${p.username}=${p.password}`).sort();
      for (let i = 0; i < 20; i++) {
        await bi.eval("return acSync.syncNow()", { timeout: 90000 });
        seen = await bi.eval(`const c = globalThis.expo.modules.SolaraCEF; return c.listPasswords("").then((l) => Promise.all(((l && l.passwords) || []).map((p) => c.getPassword("", p.origin, p.username).then((r) => p.username + "=" + (r && r.password))))).then((all) => all.sort());`, { timeout: 60000 });
        if (JSON.stringify(seen) === JSON.stringify(want)) break;
        await sleep(1500);
      }
    } finally {
      await b.started.instance.quit();
    }
    lines.push({ ok: JSON.stringify(seen) === JSON.stringify(ctx.manifest.want.Personal.passwords.map((p) => `${p.username}=${p.password}`).sort()), name: "a second Mac joining the folder gets exactly the fixture's Personal passwords: nothing claimed away, nothing deleted", detail: JSON.stringify(seen) });
    return lines;
  },
  async "a-then-d"(ctx) {
    const run = prepare(ctx.root, "a-then-d", ctx.fixture);
    seedKey(run, MOCK);
    return migrateAndCheck(ctx, run, REKEY, { fromA: true });
  },
  async "a-crash"(ctx) {
    const lines = [];
    for (const point of ["after-keying", "after-key-write", "after-keyed"]) {
      const run = prepare(ctx.root, `a-crash-${point}`, ctx.fixture);
      seedKey(run, MOCK);
      run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: point });
      const s = snapshot(run);
      if (run.started.outcome !== "exited" || points(s.appLog).at(-1) !== point) { lines.push({ ok: false, name: `from A, crash at ${point}`, detail: `${run.started.outcome}, last point ${points(s.appLog).at(-1)}` }); continue; }
      const result = await recoverAndCheck(ctx, run, `from A, crash at ${point}`, {}, { fromA: true });
      const after = snapshot(run);
      const adds = count(after.keyLog, "add created");
      result.push({ ok: adds === 0, name: `from A, crash at ${point}: the item was updated, never added`, detail: after.keyLog.join(", ") });
      lines.push(...result);
      if (!ctx.keep && result.every((l) => l.ok)) discard([run]);
    }
    return lines;
  },
  async "version-change"(ctx) {
    const next = join(ctx.root, "next", "Solara.app");
    mkdirSync(join(next, ".."), { recursive: true });
    execFileSync("cp", ["-c", "-R", ctx.app, next]);
    const plist = join(next, "Contents", "Info.plist");
    const version = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleVersion", plist], { encoding: "utf8" }).trim();
    execFileSync("/usr/libexec/PlistBuddy", ["-c", `Set CFBundleVersion ${version}9`, plist]);
    execFileSync("codesign", ["--force", "--deep", "-s", "-", next], { stdio: "ignore" });
    const lines = [];
    for (const crashAt of [null, "before-cleanup"]) {
      const label = crashAt ? "a crash at before-cleanup, then " : "";
      const run = prepare(ctx.root, crashAt ? "version-change-crash" : "version-change", ctx.fixture);
      run.started = await start(ctx.app, run, REKEY);
      if (run.started.outcome === "running") await run.started.instance.quit();
      const first = snapshot(run);
      if (first.journal?.phase !== "done" || !first.old) { lines.push({ ok: false, name: `${label}a re-key to start from`, detail: `${run.started.outcome}, journal ${JSON.stringify(first.journal?.phase)}, old ${first.old}` }); continue; }
      if (crashAt) {
        run.started = await start(next, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: crashAt });
        const c = snapshot(run);
        if (run.started.outcome !== "exited" || points(c.appLog).at(-1) !== crashAt) { lines.push({ ok: false, name: `crash at ${crashAt} on the next version`, detail: `${run.started.outcome}, last point ${points(c.appLog).at(-1)}` }); continue; }
      }
      run.started = await start(next, run, REKEY);
      if (run.started.outcome !== "running") { lines.push({ ok: false, name: `${label}the next version reaches Chrome`, detail: run.started.outcome }); continue; }
      const r = await settle(next, run, ctx.origin, ctx.profiles);
      const s = snapshot(run);
      const state = migratedState(run, ctx.manifest);
      const wrong = compare(r, ctx.manifest, state.scanned);
      const ok = !s.old && !s.stagingDir && s.key === first.key && !s.keyLog.slice(first.keyLog.length).some((l) => /add|update/.test(l)) && !state.wrong.length && !wrong.length;
      lines.push({ ok, name: `${label}the first launch of another CFBundleVersion: .rekey-old removed, no keychain write, everything reads`, detail: `old ${s.old}, staging ${s.stagingDir}, keychain ${s.keyLog.slice(first.keyLog.length).join(", ")}; ${[...state.wrong, ...wrong].join("; ")}` });
    }
    return lines;
  },
  async "rare-points"(ctx) {
    const lines = [];
    const plantGcm = (run) => {
      mkdirSync(join(run.udd, "Default", "GCM Store"), { recursive: true });
      writeFileSync(join(run.udd, "Default", "GCM Store", "LOG"), "gcm");
    };
    const probe = prepare(ctx.root, "rare-discard", ctx.fixture);
    plantGcm(probe);
    lines.push(...(await migrateAndCheck(ctx, probe, REKEY)).map((l) => ({ ...l, name: `a GCM Store to discard: ${l.name}` })));
    const discardPoints = [...new Set(points(snapshot(probe).appLog))].filter((p) => p.startsWith("after-discard-"));
    lines.push({ ok: discardPoints.length > 0 && existsSync(join(probe.udd, ".rekey-old", "Default", "GCM Store", "LOG")) && !existsSync(join(probe.udd, "Default", "GCM Store", "LOG")), name: "the GCM Store is moved aside into .rekey-old (Chrome makes a new empty one)", detail: discardPoints.join(" ") });
    for (const point of discardPoints) {
      const run = prepare(ctx.root, `rare-${point}`, ctx.fixture);
      plantGcm(run);
      run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: point });
      if (run.started.outcome !== "exited" || points(snapshot(run).appLog).at(-1) !== point) { lines.push({ ok: false, name: `crash at ${point}`, detail: `${run.started.outcome}, last point ${points(snapshot(run).appLog).at(-1)}` }); continue; }
      lines.push(...await recoverAndCheck(ctx, run, `crash at ${point}`));
    }
    const restage = prepare(ctx.root, "rare-restage", ctx.fixture);
    restage.started = await start(ctx.app, restage, { ...REKEY, SOLARA_TEST_REKEY_CRASH: "after-staged" });
    const staged = join(restage.udd, ".rekey-staging", "Default", "Login Data");
    if (restage.started.outcome !== "exited" || !existsSync(staged)) lines.push({ ok: false, name: "a staged Login Data to truncate", detail: restage.started.outcome });
    else {
      truncateSync(staged, Math.floor(statSync(staged).size / 2));
      restage.started = await start(ctx.app, restage, { ...REKEY, SOLARA_TEST_REKEY_CRASH: "after-restage-keyed" });
      const s = snapshot(restage);
      const died = restage.started.outcome === "exited" && points(s.appLog).at(-1) === "after-restage-keyed";
      lines.push({ ok: died && /didn't verify: staging again from the originals/.test(s.rekeyLog), name: "a truncated staged Login Data fails verify and stages again (after-restage-keyed)", detail: `${restage.started.outcome}, last point ${points(s.appLog).at(-1)}; ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}` });
      if (died) lines.push(...await recoverAndCheck(ctx, restage, "crash at after-restage-keyed"));
    }
    const undoRun = async (name, crashAt) => {
      const run = prepare(ctx.root, name, ctx.fixture);
      run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: "after-aside-4" });
      if (run.started.outcome !== "exited" || points(snapshot(run).appLog).at(-1) !== "after-aside-4") return { run, failed: `crash at after-aside-4: ${run.started.outcome}` };
      unlinkSync(join(run.udd, KEY_FILE));
      run.started = await start(ctx.app, run, crashAt ? { ...REKEY, SOLARA_TEST_REKEY_CRASH: crashAt } : REKEY, crashAt ? {} : { until: "devtools" });
      return { run };
    };
    const first = await undoRun("rare-undo", null);
    let undoPoints = [];
    if (first.failed) lines.push({ ok: false, name: "a swap with the key gone, to undo", detail: first.failed });
    else {
      const s = snapshot(first.run);
      undoPoints = [...new Set(points(s.appLog))].filter((p) => /^after-undo-\d+$/.test(p));
      if (first.run.started.outcome === "running") await first.run.started.instance.quit();
      const state = intactState(first.run, ctx.manifest, { key: [MOCK] });
      lines.push({ ok: /the key is gone while swapping: undoing/.test(s.rekeyLog) && s.journal?.phase === "abandoned" && undoPoints.length > 0 && !state.wrong.length, name: "the key gone mid-swap: undone to A, the originals put back one by one (after-undo-N)", detail: `${undoPoints.join(" ")}; journal ${JSON.stringify(s.journal?.phase)}; ${state.wrong.join("; ")}` });
    }
    for (const point of undoPoints) {
      const { run, failed } = await undoRun(`rare-${point}`, point);
      if (failed || run.started.outcome !== "exited" || points(snapshot(run).appLog).at(-1) !== point) { lines.push({ ok: false, name: `crash at ${point}`, detail: failed ?? `${run.started.outcome}, last point ${points(snapshot(run).appLog).at(-1)}` }); continue; }
      lines.push(...await recoverAndCheck(ctx, run, `crash at ${point}`));
    }
    return lines;
  },
  async "key-overwrite"(ctx) {
    const run = prepare(ctx.root, "key-overwrite", ctx.fixture);
    run.started = await start(ctx.app, run, REKEY);
    if (run.started.outcome !== "running") return [{ ok: false, name: "the migrated launch reaches Chrome", detail: run.started.outcome }];
    await waitWindow(run.started.instance);
    await run.started.instance.quit();
    const first = snapshot(run).key;
    const dirs = ctx.manifest.profiles.map((p) => p.dir);
    const rowCounts = () => Object.fromEntries(dirs.flatMap((dir) => [["Login Data", "logins"], ["Login Data", "password_notes"], ["Cookies", "cookies"], ["Web Data", "credit_cards"], ["Web Data", "local_ibans"]].map(([file, table]) => {
      const db = openRead(join(run.udd, dir, file));
      try { return [`${dir}/${table}`, db.prepare(`SELECT count(*) AS n FROM ${q(table)}`).get().n]; } finally { db.close(); }
    })));
    const underFirst = (k) => Object.entries(scan(run.udd, k).hits).filter(([w]) => !w.endsWith(" prefs")).map(([w, n]) => `${w} ${n}`).sort();
    const rowsBefore = rowCounts();
    const firstHits = underFirst(first);
    const trackedBefore = trackedPrefs(run.udd, dirs);
    const second = randomBytes(16).toString("base64");
    seedKey(run, second);
    const folder = join(run.dir, "folder");
    mkdirSync(folder);
    const observations = [];
    for (let launch = 1; launch <= 2; launch++) {
      run.started = await start(ctx.app, run, { ...REKEY, SOLARA_SYNC_REDESIGN: "1", SOLARA_SYNC_DEFAULT_FOLDER: folder });
      if (run.started.outcome !== "running") return [{ ok: false, name: `launch ${launch} over the overwritten key reaches Chrome`, detail: `${run.started.outcome}; dialog ${dialogShown(snapshot(run).appLog)}` }];
      const app = run.started.instance;
      let read = null, sync = null;
      try {
        await waitWindow(app);
        await sleep(1500);
        read = await readBack(app, ctx.origin, ctx.profiles);
        if (launch === 1) {
          sync = await app.eval(`return acSync.turnOnSync(${JSON.stringify(folder)})`, { timeout: 90000 });
          for (let i = 0; i < 2; i++) { await app.eval("return acSync.syncNow()", { timeout: 90000 }); await sleep(1000); }
        }
      } finally {
        await app.quit();
      }
      observations.push({ read, sync });
    }
    const s = snapshot(run);
    const rowsAfter = rowCounts();
    const trackedAfter = trackedPrefs(run.udd, dirs);
    const prefWrong = trackedChanges(ctx.manifest.tracked ?? {}, trackedAfter);
    const changedSinceRekey = trackedChanges(trackedBefore, trackedAfter);
    const prefHits = (k) => Object.entries(scan(run.udd, k).hits).filter(([w]) => w.endsWith(" prefs")).map(([w, n]) => `${w} ${n}`);
    const lost = compare(observations[1].read, ctx.manifest, null);
    const paused = /saved passwords didn't decrypt; not syncing passwords now/.test(s.appLog);
    let ledger = null;
    try { ledger = JSON.parse(readFileSync(join(run.data, "sync-pw-ledger.json"), "utf8")); } catch {}
    const ext = ctx.manifest.profiles.map((p) => `${p.name}: ${JSON.stringify(observations.map((o) => o.read?.[p.name]?.extensions))}`);
    return [
      { ok: true, name: `observed: tracked prefs after two launches on another key ${prefWrong.length || changedSinceRekey.length ? "RESET" : "kept"} (encrypted pref hashes)`, detail: `vs fixture: ${prefWrong.join("; ") || "none"} | vs after the re-key: ${changedSinceRekey.join("; ") || "none"} | encrypted hashes under the first key ${JSON.stringify(prefHits(first))}, under the second ${JSON.stringify(prefHits(second))}` },
      { ok: true, name: `observed: the extension the fixture turned off ${lost.some((w) => /extension/.test(w)) ? "LOST" : "kept, still off"}`, detail: ext.join(" | ") },
      { ok: !Object.keys(rowsBefore).some((k) => !k.endsWith("/cookies") && rowsBefore[k] !== rowsAfter[k]), name: `logins, notes, cards and IBANs stay on disk (row counts); observed: cookies ${Object.keys(rowsBefore).some((k) => k.endsWith("/cookies") && rowsBefore[k] !== rowsAfter[k]) ? "DELETED" : "kept"}`, detail: `${JSON.stringify(rowsBefore)} → ${JSON.stringify(rowsAfter)}` },
      { ok: JSON.stringify(firstHits.filter((w) => !w.includes("Cookies"))) === JSON.stringify(underFirst(first).filter((w) => !w.includes("Cookies"))), name: "every login, note, card and IBAN on disk still decrypts under the first key (unreadable to Chrome, not rewritten)", detail: `${JSON.stringify(firstHits)} → ${JSON.stringify(underFirst(first))}` },
      { ok: true, name: "what Chrome reads on the second launch (report)", detail: lost.join("; ") || "everything" },
      { ok: paused && !Object.keys(ledger?.profiles ?? {}).length, name: "sync pauses passwords, no ledger entry", detail: `turnOnSync ${JSON.stringify(observations[0].sync)}; paused ${paused}; ledger ${JSON.stringify(Object.keys(ledger?.profiles ?? {}))}` },
      { ok: !dialogShown(s.appLog) && s.journal?.phase === "done" && s.key === second, name: "no Safe Storage dialog, the re-key leaves the item alone", detail: `journal ${s.journal?.phase}, key is the second ${s.key === second}` },
    ];
  },
  async "off-mode"(ctx) {
    const run = prepare(ctx.root, "off-mode", ctx.fixture);
    run.started = await start(ctx.app, run, { ...REKEY, SOLARA_TEST_REKEY_CRASH: "after-staged" });
    const before = snapshot(run);
    if (run.started.outcome !== "exited" || before.journal?.phase !== "staged") return [{ ok: false, name: "an unfinished journal to open in off mode", detail: `${run.started.outcome}, journal ${JSON.stringify(before.journal?.phase)}` }];
    run.started = await start(ctx.app, run, {}, { until: "exit", timeout: 60000 });
    const s = snapshot(run);
    const mock = scan(run.udd, MOCK);
    const counts = (h) => JSON.stringify(Object.entries(h).filter(([w]) => !w.endsWith(" prefs")).sort());
    const quit = run.started.outcome === "exited" && s.appLog.includes(UNFINISHED) && s.journal?.phase === "staged" && s.key === before.key && s.keyLog.length === before.keyLog.length && counts(mock.hits) === counts(ctx.manifest.mockHits) && !dialogShown(s.appLog);
    const lines = [{ ok: quit, name: "off mode (mock keychain, no test mode) over an unfinished journal: the quit message, journal, data and keychain untouched", detail: `${run.started.outcome}, journal ${JSON.stringify(s.journal?.phase)}, key ${JSON.stringify(s.key)}, mock ${counts(mock.hits)}` }];
    lines.push(...await recoverAndCheck(ctx, run, "then the test build"));
    return lines;
  },
  async "test-refused"(ctx) {
    const lines = [];
    const mock = prepare(ctx.root, "test-refused-mock", ctx.fixture);
    mock.started = await start(ctx.app, mock, { SOLARA_TEST_REKEY: "1" });
    if (mock.started.outcome === "running") { await waitWindow(mock.started.instance); await mock.started.instance.quit(); }
    const a = snapshot(mock);
    const aState = intactState(mock, ctx.manifest);
    lines.push({ ok: mock.started.outcome === "running" && /test re-key refused: SOLARA_TEST_KEYCHAIN isn't file/.test(a.appLog) && !a.journal && !a.rekeyLog && !aState.wrong.length && !points(a.appLog).length, name: "SOLARA_TEST_REKEY=1 without the file keychain: refused and logged, no journal, no key, data on the mock key", detail: `${mock.started.outcome}; ${aState.wrong.join("; ")}; journal ${JSON.stringify(a.journal)}` });
    const word = prepare(ctx.root, "test-refused-word", ctx.fixture);
    word.started = await start(ctx.app, word, { ...REKEY, SOLARA_TEST_REKEY: "yes" }, { until: "dialog", timeout: 90000 });
    const b = snapshot(word);
    const bState = intactState(word, ctx.manifest);
    lines.push({ ok: word.started.outcome === "dialog" && /test re-key refused: SOLARA_TEST_REKEY isn't 1/.test(b.appLog) && !b.journal && !bState.wrong.length, name: "SOLARA_TEST_REKEY=yes: refused and logged, no re-key (Chrome's dialog), data untouched", detail: `${word.started.outcome}; ${bState.wrong.join("; ")}` });
    return lines;
  },
  async rollback(ctx) {
    const run = prepare(ctx.root, "rollback", ctx.fixture);
    const lines = (await migrateAndCheck(ctx, run, REKEY)).map((l) => ({ ...l, name: `first re-key: ${l.name}` }));
    if (!lines.every((l) => l.ok)) return lines;
    const old = join(run.udd, ".rekey-old");
    for (const file of filesUnder(old)) {
      const to = join(run.udd, relative(old, file));
      mkdirSync(join(to, ".."), { recursive: true });
      renameSync(file, to);
    }
    for (const p of [old, join(run.udd, KEY_FILE), join(run.udd, KEY_LOG), join(run.udd, ".safe-storage-rekey.json")]) rmSync(p, { recursive: true, force: true });
    const restored = intactState(run, ctx.manifest);
    lines.push({ ok: !restored.wrong.length, name: "the manual rollback puts the mock-keyed originals back", detail: restored.wrong.join("; ") });
    lines.push(...(await migrateAndCheck(ctx, run, REKEY)).map((l) => ({ ...l, name: `after the rollback: ${l.name}` })));
    return lines;
  },
  async "leftover-old"(ctx) {
    const run = prepare(ctx.root, "leftover-old", ctx.fixture);
    mkdirSync(join(run.udd, ".rekey-old", "Default"), { recursive: true });
    writeFileSync(join(run.udd, ".rekey-old", "Default", "Cookies"), "x");
    run.started = await start(ctx.app, run, REKEY);
    if (run.started.outcome !== "running") return [{ ok: false, name: "reaches Chrome", detail: `${run.started.outcome}; ${snapshot(run).rekeyLog.trim().split("\n").slice(-2).join(" | ")}` }];
    const r = await settle(ctx.app, run, ctx.origin, ctx.profiles);
    const s = snapshot(run);
    const mock = scan(run.udd, MOCK);
    const counts = (h) => JSON.stringify(Object.entries(h).filter(([w]) => !w.endsWith(" prefs")).sort());
    const wrong = compare(r, ctx.manifest, mock);
    return [
      { ok: /leftover re-key folders with no journal: leaving the folders alone/.test(s.rekeyLog) && s.key === MOCK && count(s.keyLog, "add created") === 1 && !s.journal && s.old && existsSync(join(run.udd, ".rekey-old", "Default", "Cookies")) && counts(mock.hits) === counts(ctx.manifest.mockHits) && !dialogShown(s.appLog), name: ".rekey-old with no journal: logged, left alone, the A item added, data still on the mock key", detail: `key ${JSON.stringify(s.key)}, keychain ${s.keyLog.join(", ")}, journal ${JSON.stringify(s.journal)}; ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}` },
      { ok: !wrong.length, name: "every planted value reads back", detail: wrong.join("; ") },
    ];
  },
};

async function syncRead(ctx, run) {
  const app = run.started.instance;
  await waitWindow(app);
  const out = {};
  for (const p of ctx.manifest.profiles) {
    const list = await app.eval(`return acSync.native.readPasswords(${JSON.stringify(p.id === "default" ? "" : p.id)})`, { timeout: 30000 });
    out[p.name] = Array.isArray(list) ? list.map((l) => `${l.username}=${l.password}`).sort() : null;
  }
  return out;
}

async function notMigrated(ctx, run, what, decision, keys) {
  if (run.started.outcome === "running") await run.started.instance.quit();
  const s = snapshot(run);
  const state = intactState(run, ctx.manifest, { key: keys });
  return [{ ok: decision.test(s.rekeyLog) && !state.wrong.length && (!s.journal || s.journal.phase === "abandoned"), name: `${what}: not migrating, data and item unchanged`, detail: `${run.started.outcome}; ${state.wrong.join("; ")}; ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}` }];
}

async function recoverAndCheck(ctx, run, what, extra = {}, opts = {}) {
  run.started = await start(ctx.app, run, { ...REKEY, ...extra });
  if (run.started.outcome === "running") {
    let r;
    try { r = await settle(ctx.app, run, ctx.origin, ctx.profiles); } catch (e) { await stop(run.started.pid); return [{ ok: false, name: `${what}, then a relaunch reads back`, detail: String(e.message) }]; }
    const s = snapshot(run);
    if (s.journal?.phase === "abandoned") {
      const state = intactState(run, ctx.manifest, { key: [MOCK, null] });
      const wrong = compare(r, ctx.manifest, state.scanned);
      return [{ ok: !state.wrong.length && !wrong.length, name: `${what}, then a relaunch: fell back to A, everything reads`, detail: [...state.wrong, ...wrong].join("; ") }];
    }
    const state = migratedState(run, ctx.manifest, opts);
    const wrong = compare(r, ctx.manifest, state.scanned);
    return [{ ok: !state.wrong.length && !wrong.length, name: `${what}, then a relaunch: migrated, everything reads`, detail: [...state.wrong, ...wrong].join("; ") }];
  }
  const s = snapshot(run);
  const state = intactState(run, ctx.manifest, { key: [MOCK, null, s.key] });
  const aborted = run.started.outcome === "exited" && /: quitting/.test(s.rekeyLog);
  return [{ ok: aborted && !state.wrong.length, name: `${what}, then a relaunch: the abort message, dir intact`, detail: `${run.started.outcome}; ${state.wrong.join("; ")}; ${s.rekeyLog.trim().split("\n").slice(-2).join(" | ")}` }];
}

async function runChecks(app, fixture, only, keep) {
  const manifest = JSON.parse(readFileSync(join(fixture, "manifest.json"), "utf8"));
  const root = realpathSync(mkdtempSync(join(tmpdir(), "rekey-e2e-")));
  const ctx = { app: cloneApp(app, root), fixture, manifest, root, only, keep, profiles: manifest.profiles };
  const { server, origin } = await serve();
  ctx.origin = origin;
  const log = join(root, "rekey-e2e.log");
  let failed = 0;
  const names = only.length ? [...new Set(only.map((c) => c.split(":")[0]))] : Object.keys(CASES);
  try {
    for (const name of names) {
      if (!CASES[name]) { console.log(`FAIL  ${name}: no such check (--list)`); failed++; continue; }
      const t = Date.now();
      let lines;
      const first = made.length;
      try { lines = await CASES[name](ctx); } catch (e) { lines = [{ ok: false, name, detail: String(e.stack ?? e) }]; }
      for (const l of lines) {
        const line = `${l.ok ? "PASS" : "FAIL"}  ${name}: ${l.name}${l.ok ? "" : `  (${String(l.detail).slice(0, 600)})`}`;
        console.log(line);
        writeFileSync(log, `${line}\n${l.detail ? `    ${l.detail}\n` : ""}`, { flag: "a" });
        if (!l.ok) failed++;
      }
      if (!keep && lines.every((l) => l.ok)) discard(made.slice(first));
      console.log(`      ${name}: ${((Date.now() - t) / 1000).toFixed(0)} s`);
    }
  } finally {
    server.close();
    for (const pid of binaryPids(binaryOf(ctx.app))) await stop(pid);
  }
  console.log(`${failed ? `${failed} failed` : "all passed"}; runs and logs in ${root}`);
  if (!failed && !keep) {
    execFileSync("chmod", ["-R", "u+w", root]);
    rmSync(root, { recursive: true, force: true });
  }
  return failed;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--list")) {
    for (const [k, v] of Object.entries(CHECKS)) console.log(`${k.padEnd(22)}${v}`);
    return;
  }
  const [cmd, a, b] = args;
  if (cmd === "fixture" && a && b) {
    if (!args.includes("--other-key-only")) await makeFixture(resolve(a), resolve(b));
    return makeOtherKey(resolve(a), resolve(b));
  }
  if (cmd === "run" && a && b) {
    const only = args.slice(3).filter((x) => !x.startsWith("--"));
    process.exitCode = (await runChecks(resolve(a), resolve(b), only, args.includes("--keep"))) ? 1 : 0;
    return;
  }
  if (cmd === "scan" && a) {
    const k = args.indexOf("--key"), kf = args.indexOf("--key-file");
    const secret = k > 0 ? args[k + 1] : kf > 0 ? readFileSync(args[kf + 1], "latin1") : MOCK;
    const r = scan(resolve(a), secret);
    console.log(JSON.stringify({ hits: r.hits, unreadable: r.unreadable }, null, 2));
    return;
  }
  console.error(USAGE);
  process.exit(2);
}

await main();
