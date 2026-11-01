import assert from "node:assert/strict";
import { test } from "node:test";
import { canonical, Clock, emptyScope, syncScope } from "@solara/sync";
import { useBrowser } from "../store/browser.ts";
import { withApplier } from "../store/nativeStore.ts";
import { profileThemesAdapter, profilesAdapter } from "./adapters.ts";
import { syncRedesign } from "./redesignSwitch.ts";

for (const redesign of [false, true]) {
  for (const kind of ["profiles", "themes"]) {
    test(`${redesign ? "redesign" : "legacy"} ${kind}: a refused first key leaves later keys settled and retries once next cycle`, { timeout: 5000 }, async () => {
      const before = useBrowser.getState();
      const previousLane = syncRedesign.on;
      const invalid = { ...before.profiles.default, id: "Saved-MixedCase", name: "Saved invalid", theme: null };
      const valid = { ...before.profiles.default, id: "p-launch-1", name: "Saved valid", theme: null };
      const state = emptyScope();
      const links = {
        [invalid.id]: { syncId: "invalid", themeAdopting: true },
        [valid.id]: { syncId: "valid", themeAdopting: true },
      };
      const prefix = kind === "profiles" ? "prof:" : "pth:";
      const refused = kind === "profiles" ? ["prof:invalid"] : ["pth:invalid", "pth:invalid:angle"];
      const good = kind === "profiles" ? ["prof:valid"] : ["pth:valid", "pth:valid:angle"];
      const remoteTheme = {
        stops: [{ color: { r: 1, g: 0, b: 0, a: 1 }, x: 0.5, y: 0.5 }],
        intensity: 0.5, grain: 0, texture: "grain", translucency: 0.5, mode: "auto",
      };
      for (const [syncId, profile] of [["invalid", invalid], ["valid", valid]]) {
        const key = `${prefix}${syncId}`;
        const value = kind === "profiles" ? { n: `Remote ${syncId}`, c: "blue", i: null } : { t: remoteTheme };
        state.records[key] = { h: "000000001.0000.remote", v: value, o: ["remote", 1] };
        state.base[key] = canonical(kind === "profiles" ? { n: profile.name, c: profile.color, i: profile.icon } : { preset: true });
        state.unapplied.push(key);
        if (kind === "themes") {
          state.records[`${key}:angle`] = { h: "000000001.0000.remote", v: { a: 42 }, o: ["remote", 1] };
          state.base[`${key}:angle`] = canonical({ a: 135 });
          state.unapplied.push(`${key}:angle`);
        }
      }
      const originalBase = { ...state.base };
      const attempts = [];
      try {
        syncRedesign.on = redesign;
        withApplier(() => useBrowser.getState().hydrate({ profiles: { [invalid.id]: invalid, [valid.id]: valid }, profileOrder: [invalid.id, valid.id] }));
        const adapter = kind === "profiles" ? profilesAdapter(() => links) : profileThemesAdapter(() => links, () => state.records, (id) => { delete links[id].themeAdopting; });
        const run = () => syncScope({
          scope: "app", state,
          transport: {
            read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
            write: async () => { assert.fail("Settled and refused keys must not publish"); },
            remove: async () => { assert.fail("Unexpected compaction"); },
          },
          adapters: [{ ...adapter, apply(...args) { attempts.push([...args[1]]); return adapter.apply(...args); } }],
          clock: new Clock("local", null, () => 1), device: "local", now: () => 1,
          options: { writtenKeysOnly: redesign },
        });
        for (let cycle = 0; cycle < 2; cycle++) {
          const result = await run();
          assert.equal(result.published, 0);
          const current = useBrowser.getState().profiles;
          if (kind === "profiles") {
            assert.equal(current[valid.id].name, "Remote valid");
            assert.equal(current[invalid.id].name, "Saved invalid");
          } else {
            assert.equal(current[valid.id].theme?.angle, 42);
            assert.equal(current[invalid.id].theme, null);
            assert.equal(links[invalid.id].themeAdopting, true);
            assert.equal(links[valid.id].themeAdopting, undefined);
          }
          assert.deepEqual(state.unapplied, refused);
          for (const key of refused) assert.equal(state.base[key], originalBase[key]);
          for (const key of good) assert.equal(state.base[key], canonical(state.records[key].v));
          assert.equal(attempts.length, cycle + 1);
        }
        assert.deepEqual(attempts[1], refused);
      } finally {
        syncRedesign.on = previousLane;
        withApplier(() => useBrowser.setState(before, true));
      }
    });
  }
}
