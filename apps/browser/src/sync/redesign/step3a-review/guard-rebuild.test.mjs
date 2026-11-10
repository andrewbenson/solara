import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, launch, settle, S, shell } = await import('./world.mjs');
const { sealedState } = await import('../../sealedState.mjs');

test("GUARD-rebuild-settles: a sync-state rollback rebuild ends once passwords are read and applied", () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "p1", Date.now() - 86_400_000));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const backup = new Map(shell.docs);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "p3" });
    await b.sync();
    await w.cycles(engine);
    S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
    await w.cycles(engine);
    shell.docs.clear();
    for (const [name, contents] of backup) shell.docs.set(name, contents);
    const errors = [];
    const realWarn = console.warn, realError = console.error;
    console.warn = (...a) => errors.push(a.map(String).join(" "));
    console.error = (...a) => errors.push(a.map(String).join(" "));
    try {
      const again = await launch();
      again.startSync();
      await settle(60);
      const opened = [];
      for (let i = 0; i < 6; i++) {
        await w.cycles(again, 1);
        { const r = sealedState(shell.docs)[`p:${syncId}`].rebuild; opened.push(r ? (r.settled ?? []).join("+") || "none" : "closed"); }
      }
      assert.notEqual(opened[0], "closed", "control: the relaunch opened a rebuild");
      assert.ok(opened.at(-1) === "closed" || opened.at(-1).includes("pw:"), `the rebuild ends (rebuild open per cycle: ${opened}; logged: ${errors.filter((e) => /TypeError|not iterable|sync/.test(e)).slice(0, 3).join(" | ")})`);
    } finally {
      console.warn = realWarn;
      console.error = realError;
    }
  }));
