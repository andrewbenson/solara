import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

const cli = process.env.SOLARA_STORE_CLI;

if (!cli) {
  test("durable pin publication reaches the native settlement queue", { skip: "SOLARA_STORE_CLI is required" }, () => {});
} else {
  let history = [];
  let redesign = false;
  const sent = [];
  const now = 1000;
  const request = (input) => {
    history.push({ now, sinceRev: 0, ...input });
    const replay = spawnSync(cli, ["serve", "--launch", "durable-pins", "--now", String(now)], {
      input: history.map((entry) => JSON.stringify(entry)).join("\n") + "\n",
      encoding: "utf8", timeout: 20_000, maxBuffer: 16 * 1024 * 1024,
    });
    assert.equal(replay.error, undefined);
    assert.equal(replay.status, 0, replay.stderr);
    const lines = replay.stdout.trim().split("\n");
    assert.equal(lines.length, history.length, replay.stdout);
    return JSON.parse(lines.at(-1));
  };
  const dispatch = (name, args = []) => {
    const response = request({ op: "dispatch", commands: { name, args } });
    assert.equal(response.error, undefined);
    assert.equal(response.busy, undefined);
    return response.result;
  };
  const snapshot = () => request({ op: "snapshot" });
  globalThis.acTestNativeModules = {
    SolaraStoreAdapter: {
      status: () => ({ active: true, syncRedesign: redesign }),
      useSyncOrigins: () => true,
      snapshot: () => JSON.stringify(snapshot()),
      catchUp: (sinceRev) => JSON.stringify(request({ op: "catchUp", sinceRev })),
      dispatch(json, sinceRev) {
        const decoded = JSON.parse(json);
        sent.push(decoded.commands ?? decoded);
        return JSON.stringify(request({ op: "dispatch", commands: decoded, sinceRev }));
      },
    },
  };

  const { useBrowser } = await import("../store/browser.ts");
  const { startNativeStore, standDown, withApplier } = await import("../store/nativeStore.ts");
  const { workspaceFromSnapshot } = await import("../store/nativeWorkspace.ts");
  const { pinnedRowsAdapter } = await import("./pinned.ts");
  const { syncRedesign } = await import("./redesignSwitch.ts");
  const { Clock, emptyScope, publish, flush } = await import("@solara/sync");

  for (const on of [false, true]) {
    test(`durable publication queues native settlement through a held newer user choice, redesign ${on}`, async () => {
      standDown();
      history = [];
      sent.length = 0;
      const window = dispatch("createWindow", [{ url: "https://keep.example" }]);
      const changed = dispatch("newTab", [window, { url: "https://newer.example", background: true }]);
      const matched = dispatch("newTab", [window, { url: "https://matched.example", background: true }]);
      dispatch("pinTabs", [[changed, matched], true, true]);
      dispatch("applyState", [{ pinChoices: { default: { [changed]: 11, [matched]: 12 } } }]);
      redesign = on;
      syncRedesign.on = on;
      startNativeStore();
      withApplier(() => useBrowser.setState(workspaceFromSnapshot(useBrowser.getState(), snapshot().data)));
      const state = emptyScope();
      const clock = new Clock("durable");
      const keys = await publish(state, [pinnedRowsAdapter("default")], clock, "durable", now);
      assert.deepEqual(keys, new Set([`pinrow:${changed}`, `pinrow:${matched}`]));
      assert.deepEqual(snapshot().data.pinChoices.default, { [changed]: 11, [matched]: 12 });
      let durable;
      let persistReached;
      const reached = new Promise((resolve) => { persistReached = resolve; });
      const waiting = new Promise((resolve) => { durable = resolve; });
      let writes = 0;
      const flushing = flush(state, { write: async () => `file-${++writes}` }, "p", "durable", now, {
        persist: async (batches) => {
          assert.equal(batches.length, 1);
          persistReached();
          await waiting;
        },
      });
      await reached;
      dispatch("beginTransaction");
      durable();
      await flushing;
      assert.equal(writes, 1);
      assert.equal(sent.at(-1).name, "settlePinChoices");
      assert.deepEqual(snapshot().data.pinChoices.default, { [changed]: 11, [matched]: 12 });
      dispatch("applyState", [{ pinChoices: { default: { [changed]: 21, [matched]: 12 } } }]);
      dispatch("endTransaction");
      assert.deepEqual(snapshot().data.pinChoices.default, { [changed]: 21 });
      standDown();
    });
  }
}
