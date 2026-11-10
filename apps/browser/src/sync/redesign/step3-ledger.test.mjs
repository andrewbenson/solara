import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, reset, onAndSynced, launch, passwordMac, native, realReadPasswords, realSetTimeout, files, loginDataMark } = await import('./harness.mjs');
const { sealedState } = await import('../sealedState.mjs');

const SITE = "https://site.example";
const loginKey = (user) => `${SITE}\n${user}`;
const syncKey = (user) => `pw:${loginKey(user)}`;
const login = (user, password, modified) => ({ origin: `${SITE}/`, url: `${SITE}/`, username: user, password, created: modified, modified });
const LEDGER = "sync-pw-ledger.json";

async function loginDataWorld(run) {
  reset();
  const here = new Map();
  const world = {
    here,
    offset: 0,
    get mark() {
      return loginDataMark.value;
    },
    set mark(value) {
      loginDataMark.value = value;
    },
    get marks() {
      return loginDataMark.marks;
    },
    set refuseMark(value) {
      loginDataMark.refuse = value;
    },
  };
  shell.passwordStores.set(null, here);
  const shown = () => [...here.values()].map((l) => ({ ...l, modified: l.modified ?? l.created }));
  let frozen = null;
  const realReadMarked = native.readPasswordsWithMark;
  native.readPasswords = async () => (frozen ?? shown());
  native.readPasswordsWithMark = async () => ({ logins: frozen ?? shown(), mark: loginDataMark.value });
  world.freezeChrome = () => (frozen = shown());
  world.thawChrome = () => (frozen = null);
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
  world.ledger = () => JSON.parse(shell.docs.get(LEDGER) ?? "null")?.profiles?.[""] ?? null;
  try {
    await run(world);
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realST;
    native.readPasswords = realReadPasswords;
    native.readPasswordsWithMark = realReadMarked;
  }
}

const markOf = (value) => {
  const m = /^(\d+)@(\d+)$/.exec(value ?? "");
  return m ? { L: Number(m[1]), t: Number(m[2]) } : null;
};

test("LEDGER-mark: an apply that writes a login leaves Login Data's row at L@t, with the ledger at the same L and t at or after the written login's date", fixedBy("step 3"), () =>
  loginDataWorld(async (w) => {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "from B" });
    await b.sync();
    await w.cycles(engine);
    assert.equal(w.here.get(loginKey("me"))?.password, "from B", "control: this Mac took B's login");
    const mark = markOf(w.mark);
    assert.ok(mark, `Login Data carries the row (${w.mark})`);
    assert.equal(w.ledger()?.L, mark.L, `the ledger is at the row's generation (${JSON.stringify(w.ledger())}, marks ${w.marks})`);
    assert.ok(mark.t >= w.here.get(loginKey("me")).created, "t is at or after the date the write produced");
  }),
);

test("LEDGER-row-first: a crash between the row and the ledger leaves the row ahead, and the next launch claims nothing sync wrote", fixedBy("step 3"), () =>
  loginDataWorld(async (w) => {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "first" });
    await b.sync();
    await w.cycles(engine);
    const ledgerBefore = shell.docs.get(LEDGER);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "second" });
    await b.sync();
    await w.cycles(engine);
    assert.equal(w.here.get(loginKey("me"))?.password, "second", "control: this Mac took B's second");
    assert.ok(ledgerBefore, "control: a ledger existed before the second write");
    shell.docs.set(LEDGER, ledgerBefore);
    w.later(2);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "third, newer on B" });
    await b.sync();
    const mark = files().length;
    const again = await launch();
    again.startSync();
    await settle(60);
    await w.cycles(again);
    await b.sync();
    const sent = files().slice(mark).filter(({ file }) => file.device !== "pwMac").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === syncKey("me"));
    assert.deepEqual(sent.map((op) => op.v?.p), [], "nothing sync wrote is published as an edit");
    assert.equal(b.store.get(syncKey("me"))?.p, "third, newer on B");
    assert.equal(w.here.get(loginKey("me"))?.password, "third, newer on B");
  }),
);

test("LEDGER-unconfirmed: an apply Chrome never confirms writes no row and no ledger, and the key stays unapplied", fixedBy("step 3"), () =>
  loginDataWorld(async (w) => {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    await w.cycles(engine);
    const marksBefore = w.marks.length;
    const ledgerBefore = shell.docs.get(LEDGER);
    w.freezeChrome();
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "never confirmed" });
    await b.sync();
    await w.cycles(engine, 2);
    assert.equal(w.marks.length, marksBefore, "no row was written for the unconfirmed apply");
    assert.equal(shell.docs.get(LEDGER), ledgerBefore, "and the ledger didn't move");
    const state = sealedState(shell.docs)[`p:${syncId}`];
    assert.ok(state.unapplied.includes(syncKey("me")), "the key is offered again");
    w.thawChrome();
  }),
);

test("LEDGER-mark-refused: when the row can't be written, no ledger is written either, and nothing is claimed later", () =>
  loginDataWorld(async (w) => {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    await w.cycles(engine);
    const ledgerBefore = shell.docs.get(LEDGER);
    w.refuseMark = true;
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "from B" });
    await b.sync();
    await w.cycles(engine);
    assert.equal(shell.docs.get(LEDGER), ledgerBefore, "no ledger write without its row");
    w.refuseMark = false;
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "newer on B" });
    await b.sync();
    const mark = files().length;
    await w.cycles(engine);
    await b.sync();
    const sent = files().slice(mark).filter(({ file }) => file.device !== "pwMac").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === syncKey("me"));
    assert.deepEqual(sent.map((op) => op.v?.p), [], "the login sync wrote isn't published back");
    assert.equal(b.store.get(syncKey("me"))?.p, "newer on B");
  }),
);

test("LEDGER-upgrade: at first run of the ledger, a login equal to its record is seeded, one Chrome changed after the record is claimed, an older one isn't", fixedBy("step 3"), () =>
  loginDataWorld(async (w) => {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    const t0 = Date.now();
    b.store.set(syncKey("equal"), { o: SITE, u: "equal", p: "same" });
    b.store.set(syncKey("newer"), { o: SITE, u: "newer", p: "folder's" });
    b.store.set(syncKey("older"), { o: SITE, u: "older", p: "folder's" });
    await b.sync();
    w.here.set(loginKey("equal"), login("equal", "same", t0 - 86_400_000));
    w.here.set(loginKey("newer"), login("newer", "changed here later", t0 + 120_000));
    w.here.set(loginKey("older"), login("older", "stale here", t0 - 86_400_000));
    shell.docs.delete(LEDGER);
    w.mark = null;
    w.later(3);
    const mark = files().length;
    await w.cycles(engine);
    await b.sync();
    const sent = new Map(files().slice(mark).filter(({ file }) => file.device !== "pwMac").flatMap(({ file }) => file.ops ?? []).map((op) => [op.k, op.v?.p]));
    assert.equal(sent.has(syncKey("equal")), false, "the equal login isn't published");
    assert.equal(b.store.get(syncKey("newer"))?.p, "changed here later", "the login Chrome changed after its record is claimed");
    assert.equal(w.here.get(loginKey("older"))?.password, "folder's", "the older one takes the folder's value");
    assert.equal(sent.has(syncKey("older")), false);
  }),
);
