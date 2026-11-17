import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const { settingsAdapter, settingsToReapply } = await import("./adapters.ts");

const S = () => useBrowser.getState();

function folder() {
  const files = new Map();
  let n = 0;
  return {
    write: async (scope, payload) => {
      const id = `f${++n}`;
      files.set(id, { scope, payload });
      return id;
    },
    read: async (scope, known) => {
      const shown = [...files].filter(([, f]) => f.scope === scope);
      return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
    },
    remove: async (_scope, ids) => ids.forEach((id) => files.delete(id)),
  };
}

function device(id, transport) {
  S().hydrate({});
  let browser = S();
  const state = emptyScope();
  const clock = new Clock(id);
  return {
    with(fn) {
      useBrowser.setState(browser, true);
      try {
        return fn();
      } finally {
        browser = S();
      }
    },
    async sync() {
      useBrowser.setState(browser, true);
      try {
        state.unapplied = [...new Set([...state.unapplied, ...settingsToReapply(state.records)])];
        return await syncScope({ scope: "app", state, transport, adapters: [settingsAdapter], clock, device: id });
      } finally {
        browser = S();
      }
    },
  };
}

test("settings: disabling clean-up suggestions syncs and can be enabled again", async () => {
  const transport = folder();
  const a = device("a", transport);
  const b = device("b", transport);
  for (const d of [a, b]) {
    d.with(() => {
      assert.equal(S().settings.suggestTabCleanUp, true);
      const extraction = settingsAdapter.extract(() => undefined);
      assert.equal(extraction.values.has("set:suggestTabCleanUp"), false);
      assert.equal(extraction.ignore("set:suggestTabCleanUp"), true);
    });
    assert.equal((await d.sync()).published, 0);
  }
  a.with(() => S().updateSettings({ suggestTabCleanUp: false }));
  for (const d of [a, b]) await d.sync();
  assert.equal(b.with(() => S().settings.suggestTabCleanUp), false);
  b.with(() => S().updateSettings({ suggestTabCleanUp: true }));
  for (const d of [b, a]) await d.sync();
  assert.equal(a.with(() => S().settings.suggestTabCleanUp), true);
});
