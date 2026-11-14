import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { sadTabHostState } from "./sadTabState.ts";

const theme = {
  dark: true,
  textPrimary: "#FFFFFF",
  textSecondary: "#FFFFFF99",
  panel: "#2A2729",
  panelBorder: "rgba(255,255,255,0.1)",
  panelShadowOpacity: 0.3,
  goButton: "#F2E8EF",
  goButtonText: "#1B1618",
  card: "unused",
};

test("a crash takes precedence over an unresponsive page in the hosted state", () => {
  assert.equal(sadTabHostState("a", true, true, theme).mode, "crashed");
  assert.equal(sadTabHostState("a", false, true, theme).mode, "unresponsive");
  assert.equal(sadTabHostState("a", false, false, theme).mode, null);
});

test("the hosted state carries the tab identity and every SadTabState decoding field", () => {
  const state = sadTabHostState("little", true, false, theme);
  assert.deepEqual(state, { tabId: "little", mode: "crashed", dark: true, textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, panel: theme.panel, panelBorder: theme.panelBorder, panelShadowOpacity: theme.panelShadowOpacity, goButton: theme.goButton, goButtonText: theme.goButtonText });
  const swift = readFileSync(new URL("../../../../../native/SolaraKit/Sources/SolaraUI/PaneOverlays/SadTabView.swift", import.meta.url), "utf8");
  const body = swift.match(/public struct SadTabState:[^{]+\{([\s\S]*?)public static func decode/)[1];
  for (const [, key] of body.matchAll(/public var (\w+):/g)) assert.ok(key in state, `missing ${key}`);
});
