import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const sent = [];
const apiVersion = Number(readFileSync(new URL("../nativeApi.tsx", import.meta.url), "utf8").match(/export const NATIVE_API_VERSION = (\d+);/)?.[1]);
assert.ok(apiVersion, "native API version declaration found");
const app = { apiVersion, sidebarPosition: true };
let layoutActive = true;
globalThis.acTestNativeModules = {
  SolaraApp: app,
  SolaraWindowShell: { nativeLayout: () => layoutActive },
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    dispatch: (json) => {
      sent.push(...[JSON.parse(json)].flat());
      return JSON.stringify({ rev: 0, patches: [] });
    },
  },
};
const { startNativeStore, standDown } = await import("./nativeStore.ts");
const side = await import("./sidebarRail.ts");

test("side choices use one native command for Settings and the window menu", () => {
  startNativeStore();
  side.setSidebarPosition("window", "right");
  side.setSidebarPosition(null, "left");
  assert.deepEqual(sent.splice(0), [
    { name: "setSidebarPosition", args: ["window", "right"] },
    { name: "setSidebarPosition", args: [null, "left"] },
  ]);
  standDown();
});

test("side choices refuse invalid values and require the development capability and native workspace", () => {
  startNativeStore();
  assert.throws(() => side.setSidebarPosition("window", "top"), /invalid sidebar position/);
  app.sidebarPosition = false;
  side.setSidebarPosition("window", "right");
  app.sidebarPosition = true;
  standDown();
  side.setSidebarPosition("window", "right");
  assert.deepEqual(sent, []);
});

test("side choices require the matching native API version", () => {
  startNativeStore();
  for (const version of [apiVersion - 1, apiVersion + 1]) {
    app.apiVersion = version;
    side.setSidebarPosition("window", "right");
    assert.equal(side.sidebarPositionSupported("window"), false);
  }
  app.apiVersion = apiVersion;
  assert.equal(side.sidebarPositionSupported("window"), true);
  assert.deepEqual(sent, []);
  standDown();
});

test("the typed replica resolves configuration before the window and defaults old windows to left", () => {
  assert.equal(side.sidebarPositionOf(undefined, {}), "left");
  assert.equal(side.sidebarPositionOf({ sidebarPosition: "right" }, { sidebarPosition: "left" }), "right");
  assert.equal(side.sidebarPositionOf({ sidebarPosition: "right" }, { sidebarPosition: "left", fileOwn: { covered: ["sidebarPosition"], own: {} } }), "left");
});

test("window choices require an adopted native layout even when the process capability is enabled", () => {
  startNativeStore();
  layoutActive = false;
  side.setSidebarPosition("window", "right");
  assert.equal(side.sidebarPositionSupported("window"), false);
  assert.deepEqual(sent, []);
  layoutActive = true;
  standDown();
});
