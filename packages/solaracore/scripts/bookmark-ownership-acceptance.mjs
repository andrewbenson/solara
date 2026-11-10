import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { randomUUID } from "node:crypto";

export function bookmarkOwnershipAcceptance(host) {
  const { evalApp, until, scratch, data, stopApp, appUp, crashApp, exts, extensionWorker, cdp } = host;
  const native = "globalThis.expo.modules.SolaraSettings";
  const fault = async (value) => JSON.parse(await evalApp(`return ${native}.devBookmarkFault(${JSON.stringify(JSON.stringify(value))})`));
  const writerState = () => evalApp(`return ${native}.bookmarkWriterState()`);
  const snapshot = async (profile = "default") => {
    const value = await evalApp(`return ${native}.bookmarkWriterSnapshot(${JSON.stringify(profile)})`);
    return { ...value, document: JSON.parse(value.document), facts: JSON.parse(value.facts ?? "{}") };
  };
  const projection = () => evalApp(`return JSON.parse(${native}.bookmarkProjection())`);
  const ready = async (profile = "default") => until(`native bookmark ownership and readiness for ${profile}`, async () => {
    if ((await writerState()).state !== "owned") return null;
    try {
      const value = await snapshot(profile);
      return (value.readyForSync ?? value.ready) ? value : null;
    } catch { return null; }
  }, 30000);
  const find = (tree, id) => {
    const queue = [tree.bar, tree.other];
    while (queue.length) {
      const node = queue.shift();
      if (node?.id === id) return node;
      queue.push(...(node?.c ?? []));
    }
    return null;
  };
  const tree = async (engine = "") => fault({ operation: "tree", engine });
  const chromeHas = (id, engine = "") => until(`Chrome bookmark ${id}`, async () => find(await tree(engine), id), 15000);
  const chromeLacks = (id, engine = "") => until(`Chrome removal ${id}`, async () => !find(await tree(engine), id), 15000);
  const add = async (title, profileId = "default") => evalApp(`return ac.bookmarks.addBookmark(${JSON.stringify({ profileId, title, url: `https://bookmark-activation.example/${randomUUID()}` })})`);
  const remove = (id, profile = "default") => evalApp(`return ac.bookmarks.removeBookmark(${JSON.stringify(profile)}, ${JSON.stringify(id)})`);
  const journal = () => JSON.parse(readFileSync(join(data, "bookmarks-pending-native-v1.json"), "utf8")).payload;
  const engineJournal = (engine = "") => journal().engines.find((row) => row.view.engine === engine);
  const assertIsolated = async () => {
    const state = await fault({ operation: "documents" });
    assert.equal(resolve(state.documents), resolve(data));
    assert.ok(resolve(data).startsWith(resolve(scratch) + sep));
    return state;
  };
  let installed;
  const worker = async () => {
    if (!installed) {
      const directory = join(scratch, "bookmark-owner-extension");
      mkdirSync(directory, { recursive: true });
      writeFileSync(join(directory, "manifest.json"), JSON.stringify({ manifest_version: 3, name: "Bookmark owner acceptance", version: "1.0", permissions: ["bookmarks"], background: { service_worker: "worker.js" } }));
      writeFileSync(join(directory, "worker.js"), 'chrome.runtime.onMessage.addListener(() => false); chrome.bookmarks.getTree().then(() => {});\n');
      installed = await exts(`install(${JSON.stringify(directory)}, "")`);
      assert.ok(installed.id, JSON.stringify(installed));
    }
    return extensionWorker(installed.id, "bookmarks.getTree");
  };
  const extension = async (expression) => {
    const result = await cdp(await worker(), "Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    assert.equal(result.exceptionDetails, undefined, JSON.stringify(result));
    return result.result?.value;
  };
  const withReady = async (run) => {
    await assertIsolated();
    await ready();
    return run();
  };

  return {
    noJSWriter: () => withReady(async () => {
      const before = await projection();
      const refusals = await evalApp(`
        const out = [];
        return ["ac_bookmarks_tree", "ac_bookmarks_apply", "ac_bookmarks_watch"].reduce((previous, name) => previous.then(() =>
          Promise.resolve().then(() => globalThis.expo.modules.SolaraCEF.engineCall(name, "", '{"ops":[]}'))
            .then((reply) => { const value = JSON.parse(reply); out.push({ name, refused: typeof value.error === "string" }); })
            .catch(() => { out.push({ name, refused: true }); })
        ), Promise.resolve()).then(() =>
          Promise.resolve().then(() => ${native}.libraryCommand("applyBookmarks", "", {ops: []}))
            .then(() => { out.push({name: "library", refused: false}); }, () => { out.push({name: "library", refused: true}); })
        ).then(() => {
          const s = ac.store.getState();
          let notifications = 0;
          const unsubscribe = ac.store.subscribe(() => notifications++);
          try { ac.store.setState({bookmarks: {nodes: {}, roots: {}}}); out.push({name: "store", refused: false}); }
          catch { out.push({name: "store", refused: true}); }
          unsubscribe();
          return {out, notifications, same: ac.store.getState().bookmarks === s.bookmarks};
        });`);
      assert.ok(refusals.out.every((value) => value.refused), JSON.stringify(refusals));
      assert.equal(refusals.notifications, 0);
      assert.equal(refusals.same, true);
      const id = await add("Native activation fact");
      const after = await snapshot();
      assert.ok(after.document.nodes[id]);
      assert.ok(after.facts[`bm:${id}`], "the actual production owner records the accepted edit fact");
      await chromeHas(id);
      const renamed = "Extension edit without JS submit";
      await extension(`chrome.bookmarks.search({url:${JSON.stringify(after.document.nodes[id].url)}}).then(async (nodes) => {
        if (nodes.length !== 1) throw new Error("fixture bookmark missing or duplicated");
        await chrome.bookmarks.update(nodes[0].id, {title:${JSON.stringify(renamed)}}); return true;
      })`);
      await until("extension edit projected without a UI mutation", async () => {
        const current = await snapshot();
        return current.document.nodes[id]?.title === renamed ? current : null;
      });
      const beforeReload = await projection();
      const reloadToken = randomUUID();
      await evalApp(`globalThis.__bookmarkOwnerReloadToken=${JSON.stringify(reloadToken)}; setTimeout(() => globalThis.nativeModuleProxy.DevSettings.reload(), 50); return true`);
      await until("the reloaded bookmark harness", async () => {
        try { return await evalApp(`return globalThis.__bookmarkOwnerReloadToken !== ${JSON.stringify(reloadToken)} && !!ac.bookmarks && ${native}.bookmarkWriterState().state === "owned"`, 3000); }
        catch { return null; }
      }, 30000);
      await ready();
      const afterReload = await projection();
      assert.equal(afterReload.owner, beforeReload.owner, "JS reload reattaches to the same native lifetime");
      assert.equal((await snapshot()).document.nodes[id]?.title, renamed);
      assert.equal(before.owner, afterReload.owner);
      await remove(id);
      await chromeLacks(id);
      return { refusals, owner: afterReload.owner, nativeFactRecorded: true, extensionReadback: true, reloadRetainedOwner: true };
    }),

    ownerRemap: () => withReady(async () => {
      const original = await snapshot();
      const { alias, other } = await evalApp(`const s = ac.store.getState(); return {
        alias: s.createProfile({name:"Bookmark shared alias",shareWith:"default"}),
        other: s.createProfile({name:"Bookmark independent engine"})
      }`);
      let id;
      try {
        const shared = await ready(alias);
        assert.equal(shared.engine, original.engine);
        id = await add("Shared engine native edit", alias);
        await chromeHas(id, shared.engine);
        const same = await snapshot();
        assert.ok(same.document.nodes[id]);
        assert.equal((await snapshot(alias)).revision, same.revision);
        await evalApp(`ac.store.getState().updateProfile(${JSON.stringify(alias)}, {dataId:${JSON.stringify(other)}}); return true`);
        const moved = await until("alias moved to independent engine", async () => {
          try { const value = await snapshot(alias); return value.engine === other && (value.readyForSync ?? value.ready) ? value : null; }
          catch { return null; }
        });
        assert.equal(moved.document.nodes[id], undefined);
        await evalApp(`ac.store.getState().updateProfile(${JSON.stringify(alias)}, {dataId:"default"}); return true`);
        const returned = await until("alias returned to original engine", async () => {
          try { const value = await snapshot(alias); return value.engine === original.engine && (value.readyForSync ?? value.ready) ? value : null; }
          catch { return null; }
        });
        assert.notEqual(returned.generation, shared.generation);
        const stale = await evalApp(`return Promise.resolve()
          .then(() => ${native}.submitBookmarkMutations(${JSON.stringify(alias)}, '[]', ${JSON.stringify(shared.engine)}, ${JSON.stringify(shared.generation)}, "old-remap-binding"))
          .then(() => false, () => true)`);
        assert.equal(stale, true, "A to B to A refuses an old route binding");
        await evalApp(`ac.store.getState().deleteProfile(${JSON.stringify(alias)}); return true`);
        await until("deleted alias root removed", () => evalApp(`return !ac.store.getState().bookmarks.roots[${JSON.stringify(alias)}]`));
        assert.ok((await snapshot()).document.nodes[id], "remaining alias preserves shared engine bookmarks");
        return { sharedEngine: shared.engine, revokedGeneration: shared.generation, returnedGeneration: returned.generation, staleRefused: stale };
      } finally {
        if (id) await remove(id).catch(() => null);
        await evalApp(`const s=ac.store.getState(); for(const id of ${JSON.stringify([alias,other])}) if(s.profiles[id]) s.deleteProfile(id); return true`).catch(() => null);
      }
    }),

    durableCrash: () => withReady(async () => {
      const state = await snapshot();
      await fault({ operation: "arm", engine: state.engine });
      let id;
      try {
        id = await add("Durable before Chrome push");
        await until("held real native Chrome push", async () => (await fault({ operation: "status" })).phase === "held");
        assert.ok(engineJournal(state.engine).view.document.nodes[id]);
        assert.equal(find(await tree(state.engine), id), null);
        await crashApp();
        await appUp("bookmarks-durable-crash.out.log");
        await ready();
        assert.ok((await snapshot()).document.nodes[id]);
        await chromeHas(id, state.engine);
        return { id, acceptedBeforeChromePush: true, recoveredAfterCrash: true };
      } finally {
        await fault({ operation: "releaseAll" }).catch(() => null);
        if (id) await remove(id).catch(() => null);
      }
    }),

    partialPush: () => withReady(async () => {
      const ids = [];
      let state;
      try {
        for (const name of ["A", "B", "C"]) {
          const id = await add(`Partial push ${name}`);
          ids.push(id);
          await chromeHas(id);
        }
        state = await snapshot();
        await fault({ operation: "arm", engine: state.engine, dropID: ids[1] });
        await evalApp(`return ac.bookmarks.removeBookmarks("default", ${JSON.stringify(ids)})`);
        const held = await until("held A B C native deletion batch", async () => {
          const value = await fault({ operation: "status" });
          return value.phase === "held" ? value : null;
        });
        assert.deepEqual(held.operations.filter((op) => op.op === "remove").map((op) => op.id), ids);
        await fault({ operation: "releasePush" });
        const partial = await until("actual Chrome partial application", async () => {
          const value = await fault({ operation: "status" });
          return value.phase === "completed" ? value : null;
        });
        assert.deepEqual(partial.result, { applied: 1, skipped: 2, invalid: [] });
        assert.ok(find(await tree(state.engine), ids[2]), "Chrome still has C after the failed suffix");
        const pending = await until("failed batch durably retains C deletion", async () => {
          const entry = engineJournal(state.engine);
          return entry.view.failedPushes > 0 && !entry.view.document.nodes[ids[2]] && entry.base.some((node) => node.id === ids[2]) ? entry : null;
        });
        assert.equal((await snapshot()).document.nodes[ids[2]], undefined);
        await crashApp();
        await appUp("bookmarks-partial-push-crash.out.log");
        await ready();
        await chromeLacks(ids[2], state.engine);
        assert.equal((await snapshot()).document.nodes[ids[2]], undefined);
        return { ids, partial: partial.result, pendingRevision: pending.view.revision, cRemovedAfterCrash: true };
      } finally {
        await fault({ operation: "releaseAll" }).catch(() => null);
        for (const id of ids) await remove(id).catch(() => null);
      }
    }),

    legacyUpgrade: () => withReady(async () => {
      const current = journal();
      assert.equal(current.legacyMigration, null, "legacy-upgrade requires a fresh scratch migration history");
      const source = {
        bookmarks: {
          roots: { default: { bar: "legacy-bar", other: "legacy-other" } },
          nodes: {
            "legacy-bar": { id: "legacy-bar", kind: "folder", parentId: null, title: "Bookmarks Bar", addedAt: 1, children: ["legacy-acceptance-record"] },
            "legacy-other": { id: "legacy-other", kind: "folder", parentId: null, title: "Other Bookmarks", addedAt: 1, children: [] },
            "legacy-acceptance-record": { id: "legacy-acceptance-record", kind: "url", parentId: "legacy-bar", title: "Legacy exact \ud800 record", url: "HTTPS://EXAMPLE.COM:443/legacy", addedAt: 1234, ac_sync_key: "legacy-key-\udfff", favicon: null }
          }
        }
      };
      const bytes = JSON.stringify(source);
      await stopApp();
      writeFileSync(join(data, "bookmarks.json"), bytes);
      await appUp("bookmarks-legacy-upgrade.out.log");
      const migrated = await until("native migration push and confirming read", async () => {
        try {
          const value = await ready();
          const matches = Object.values(value.document.nodes).filter((node) => node.title === source.bookmarks.nodes["legacy-acceptance-record"].title);
          return matches.length === 1 && !existsSync(join(data,"bookmarks.json")) ? { value, node: matches[0] } : null;
        } catch { return null; }
      }, 45000);
      assert.equal(migrated.node.syncKey, "legacy-key-\udfff");
      assert.equal(migrated.node.addedAt, 1234);
      assert.equal(migrated.node.url, "https://example.com/legacy");
      assert.equal(migrated.value.facts[`bm:${migrated.node.syncKey}`], undefined, "migration is an unstamped baseline");
      assert.ok(find(await tree(migrated.value.engine), migrated.node.id));
      const completed = journal().legacyMigration;
      assert.ok(Object.values(completed.engines).every((value) => value.stage === "confirmed" || value.stage === "discarded"));
      assert.equal(readFileSync(join(data, `bookmarks-legacy-${completed.source}.json`), "utf8"), bytes);
      await remove(migrated.node.id);
      await chromeLacks(migrated.node.id);
      await stopApp();
      writeFileSync(join(data,"bookmarks.json"), bytes);
      await appUp("bookmarks-legacy-idempotent.out.log");
      await ready();
      assert.equal((await snapshot()).document.nodes[migrated.node.id], undefined, "same legacy source cannot reimport a consumed deletion");
      await chromeLacks(migrated.node.id);
      assert.equal(journal().legacyMigration.source, completed.source);
      return { id: migrated.node.id, source: completed.source, keptExactKeyAndTitle: true, deletedRecordNotReimported: true };
    }),

    relaunchIdempotence: () => withReady(async () => {
      const id = await add("0.3.0 repeat launch");
      await chromeHas(id);
      const before = await snapshot();
      const migration = journal().legacyMigration;
      await stopApp();
      await appUp("bookmarks-return-030.out.log");
      await ready();
      const after = await snapshot();
      assert.equal(after.document.nodes[id]?.title, before.document.nodes[id]?.title);
      assert.equal(after.document.nodes[id]?.url, before.document.nodes[id]?.url);
      assert.deepEqual(journal().legacyMigration, migration, "relaunch does not create another migration");
      assert.equal((await writerState()).state, "owned");
      await chromeHas(id);
      const second = await snapshot();
      assert.equal(Object.values(second.document.nodes).filter((node) => node.id === id).length, 1);
      await remove(id);
      await chromeLacks(id);
      return { id, noSecondMigration: true, oneRecordAfterRelaunch: true };
    })
  };
}
