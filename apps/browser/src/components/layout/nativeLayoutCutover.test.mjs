import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("the default window root has no RN layout measurement or legacy layout host", () => {
  const app = source("../../App.tsx");
  for (const name of ["onLayout=", "DockedLayout", "TopTabStrip", "SidePanelRoom", "useFullscreenTab", "ProfileTint"]) {
    assert.equal(app.includes(name), false, name);
  }
  assert.match(app, /pointerEvents="box-none"/);
  assert.match(app, /useNativeWindowAnchors/);
  assert.match(app, /require\("\.\/LegacyWindow"\)/);
});

test("native content guests never import a renderer or RN pane geometry", () => {
  const card = source("../ContentCard.tsx");
  for (const name of ["splitGeometry", "onLayout=", "Animated", "<WebView", "DropTargets", "SplitDividers", "useNativePageTops", "toolbarAutoHide", "useDockMotion"]) {
    assert.equal(card.includes(name), false, name);
  }
  assert.match(card, /require\("\.\/LegacyContentCard"\)/);
  assert.match(card, /<NativePaneFallback/);
});

test("the legacy path retains its own composition and renderer", () => {
  const legacy = source("../../LegacyWindow.tsx");
  assert.match(legacy, /<DockedLayout/);
  assert.match(legacy, /<SidePanelRoom/);
  assert.match(legacy, /onLayout=/);
  const card = source("../LegacyContentCard.tsx");
  assert.match(card, /<WebView/);
  assert.match(card, /splitGeometry/);
});
