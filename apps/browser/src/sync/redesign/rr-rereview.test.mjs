import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, S, settle, launch, reset, onAndSynced, passwordMac, appMac, native, realReadPasswords, realSetTimeout, assertNoSeqReused, restoreDocs, useBrowser, files , loginDataMark } = await import('./harness.mjs');

const SITE = "https://site.example";
const loginKey = (user) => `${SITE}\n${user}`;
const syncKey = (user) => `pw:${loginKey(user)}`;
const login = (user, password, modified) => ({ origin: `${SITE}/`, url: `${SITE}/`, username: user, password, created: modified, modified });

async function passwordsWorld(run) {
  reset();
  const here = new Map();
  const world = { here, readable: true, offset: 0 };
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => (world.readable ? [...here.values()] : null);
  const realST = globalThis.setTimeout;
  const realNow = Date.now;
  globalThis.setTimeout = (fn, ms) => (ms === 250 ? realSetTimeout(fn, 0) : 0);
  Date.now = () => realNow() + world.offset;
  world.later = (minutes = 1) => (world.offset += minutes * 60_000);
  world.cycles = async (engine, n = 3) => {
    for (let i = 0; i < n; i++) {
      world.later();
      await engine.syncNow();
      await settle(60);
    }
  };
  try {
    await run(world);
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realST;
    native.readPasswords = realReadPasswords;
  }
}

test("RR1: Login Data restored in place to an older copy reverts nothing on other Macs", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const backup = new Map([...w.here].map(([k, v]) => [k, { ...v }]));
    const markInBackup = loginDataMark.value;
    w.later(60);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2" });
    await b.sync();
    await w.cycles(engine);
    assert.equal(w.here.get(loginKey("me"))?.password, "v2", "control: this Mac took v2");
    w.here.clear();
    for (const [k, v] of backup) w.here.set(k, v);
    loginDataMark.value = markInBackup;
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2", `B keeps v2 (B has ${b.store.get(syncKey("me"))?.p})`);
    assert.equal(w.here.get(loginKey("me"))?.password, "v2", "and this Mac takes v2 back");
  }));

test("RR2: changing most passwords at once doesn't go out until confirmed", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    for (let i = 0; i < 10; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.later(60);
    for (let i = 0; i < 8; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `changed${i}`, Date.now()));
    await w.cycles(engine);
    await b.sync();
    const changed = [...b.store.values()].filter((v) => v.p.startsWith("changed")).length;
    assert.equal(changed, 0, `the held changes don't reach B before the user confirms (B has ${changed} changed)`);
  }));

test("RR3a: another Mac republishing the same value doesn't undo a deletion made here", () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.readable = false;
    w.here.delete(loginKey("me"));
    await w.cycles(engine, 1);
    w.later(30);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v1" });
    b.republish?.(syncKey("me"));
    await b.sync();
    w.readable = true;
    await w.cycles(engine);
    await b.sync();
    assert.ok(!b.store.has(syncKey("me")), `the deletion reaches B (B has ${JSON.stringify(b.store.get(syncKey("me")))})`);
  }));

test("RR3b: a password changed here on day 1 while unreadable loses to the other Mac's change on day 2", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.readable = false;
    w.later(24 * 60);
    w.here.set(loginKey("me"), login("me", "day1-here", Date.now()));
    await w.cycles(engine, 1);
    w.later(24 * 60);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "day2-from-B" });
    await b.sync();
    w.later(24 * 60);
    w.readable = true;
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "day2-from-B", `the later change wins (B has ${b.store.get(syncKey("me"))?.p})`);
  }));

test("RR3c: at upgrade, a login Chrome modified after its record is claimed, an older one isn't", { skip: "needs the ledger's upgrade path: nothing to drive against today's engine" }, () => {});
test("RR4: see FR3 in fr-final-review.test.mjs (the union fallback against a late file)", { skip: "covered by FR3" }, () => {});
test("RR5: an extension edit made before the first bookmark read at launch is published", { skip: "needs the bookmark bridge and the engine in one harness, with a gate on ac_bookmarks_apply" }, () => {});

test("RR6: the history cap's eviction publishes no deletion", async () => {
  reset();
  useBrowser.setState({ historyReady: { default: true } });
  const now = Date.now();
  const entries = Array.from({ length: 50 }, (_, i) => ({ url: `https://h${i}.example/`, title: `H${i}`, favicon: null, visits: 1, lastVisit: now - i * 60_000, visitTimes: [now - i * 60_000] }));
  useBrowser.setState((s) => ({ history: { ...s.history, default: entries } }));
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const evicted = entries.slice(0, 40);
  useBrowser.setState((s) => ({ history: { ...s.history, default: evicted }, historyFloor: { ...s.historyFloor, default: evicted.at(-1).lastVisit } }));
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  const deletions = files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k.startsWith("h:") && op.v === null);
  assert.deepEqual(deletions.map((op) => op.k), [], "evicted history isn't published as deleted");
});

test("RR7: a Mac copied with its Keychain item (no phrase entered) and the original never reuse a seq", { todo: "step 7" }, async () => {
  reset();
  const engine = await onAndSynced();
  const copy = new Map(shell.docs);
  const twin = await launch();
  restoreDocs(copy);
  twin.startSync();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://twin.example/", title: "On the twin" });
  for (let i = 0; i < 2; i++) await twin.syncNow();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://original.example/", title: "On the original" });
  await engine.syncNow();
  await settle();
  assertNoSeqReused();
});

test("RR8: a joining Mac adopts the synced settings instead of overwriting them with its own", async () => {
  reset();
  await onAndSynced();
  const b = appMac("set:");
  await b.sync();
  b.store.set("set:appearance", { v: "dark" });
  await b.sync();
  S().updateSettings({ appearance: "light" });
  shell.docs.clear();
  const joiner = await launch();
  joiner.startSync();
  await settle();
  assert.ok("ok" in (await joiner.enterRecoveryPhrase("/sync", "the phrase")));
  for (let i = 0; i < 3; i++) await joiner.syncNow();
  await settle();
  await b.sync();
  assert.deepEqual(b.store.get("set:appearance"), { v: "dark" }, "the synced choice stands");
  assert.equal(S().settings.appearance, "dark", "and is taken here");
});

test("RR9: a navigation writes nothing to the edit journal", { skip: "needs sync-edits.json to exist" }, () => {});
