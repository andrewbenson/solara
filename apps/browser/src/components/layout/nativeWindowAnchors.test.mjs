import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import * as layout from "./windowLayout.ts";

const require = createRequire(import.meta.url);
const ts = require("typescript");

function mount(windowId, nativeLayout, available) {
  const effects = [];
  const cleanups = [];
  const observations = [];
  const handlers = {};
  const batch = { windowId, windowGeneration: 1, generation: 1, storeRevision: 1, anchors: { content: [10, 6, 500, 700], url: [200, 6, 300, 41] }, sidebar: false, profileTitle: "Personal", profileNameWidth: 52, stripAvailableWidth: 900 };
  const modules = {
    "@solara/settings": {
      windowNativeLayout: () => nativeLayout,
      windowLayoutAnchorsAvailable: () => available,
      observeWindowLayoutAnchors: async (...args) => {
        observations.push(args);
        return { windowGeneration: 1, batch };
      },
    },
    react: { useState: (initial) => [initial()], useEffect: (effect) => effects.push(effect) },
    "../settings/nativeSettings": { addNativeSettingsHandlers: (next) => Object.assign(handlers, next) },
    "./windowLayout": layout,
  };
  const source = readFileSync(new URL("./nativeWindowAnchors.ts", import.meta.url), "utf8");
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  new Function("require", "exports", code)((name) => modules[name], exports);
  const native = exports.useNativeWindowAnchors(windowId);
  for (const effect of effects) {
    const cleanup = effect();
    if (cleanup) cleanups.push(cleanup);
  }
  return { native, observations, handlers, batch, unmount: () => cleanups.forEach((cleanup) => cleanup()) };
}

for (const [name, nativeLayout, available] of [["legacy shell", false, true], ["unavailable native anchors", true, false]]) {
  test(`${name} keeps measured card and URL producers available to the command panel`, async () => {
    const windowId = `measured-${name}`;
    const host = mount(windowId, nativeLayout, available);
    try {
      await Promise.resolve();
      assert.equal(host.native, false);
      assert.deepEqual(host.observations, []);
      assert.equal(layout.nativeWindowAnchorFeed.active(windowId), false);
      const card = { left: 20, top: 8, width: 640, height: 480 };
      const url = { left: 220, top: 8, width: 360 };
      layout.setCardAnchor(windowId, card);
      layout.setUrlAnchor(windowId, url);
      host.handlers["window.layoutAnchors"](windowId, host.batch);
      assert.deepEqual(layout.useCardAnchors.getState()[windowId], card);
      assert.deepEqual(layout.useUrlAnchors.getState()[windowId], url);
    } finally {
      host.unmount();
      layout.dropNativeWindowAnchors(windowId);
    }
  });
}

test("native layout owns command panel anchors until its reader unmounts", async () => {
  const windowId = "native-panel-anchors";
  const host = mount(windowId, true, true);
  try {
    assert.equal(host.native, true);
    assert.equal(layout.nativeWindowAnchorFeed.active(windowId), true);
    await Promise.resolve();
    assert.equal(host.observations.length, 1);
    assert.equal(host.observations[0][1], true);
    layout.setCardAnchor(windowId, { left: 0, top: 0, width: 1, height: 1 });
    layout.setUrlAnchor(windowId, { left: 0, top: 0, width: 1 });
    assert.deepEqual(layout.useCardAnchors.getState()[windowId], { left: 10, top: 6, width: 500, height: 700 });
    assert.deepEqual(layout.useUrlAnchors.getState()[windowId], { left: 200, top: 6, width: 300 });
  } finally {
    host.unmount();
  }
  assert.equal(layout.nativeWindowAnchorFeed.active(windowId), false);
  assert.equal(layout.useUrlAnchors.getState()[windowId], undefined);
  assert.equal(host.observations.at(-1)[1], false);
});
