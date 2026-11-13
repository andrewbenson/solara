import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;

const { textInk, hexColor } = await import("./profileTheme.ts");
const { profileTheme, inkedTokens } = await import("./theme.ts");

const look = (hex, intensity, mode = "dark", translucency = 1) => {
  const color = hexColor(hex);
  return { stops: [{ x: 0.2, y: 0.2, color }, { x: 0.8, y: 0.8, color }], intensity, mode, grain: 0, texture: "grain", translucency };
};
const profile = (theme) => ({ color: "plum", theme });
const DARK_SELECTED = [18 / 255, 18 / 255, 18 / 255, 0.5];

test("a light colour in dark mode gets dark text, the selected tab's title stays white", () => {
  const theme = profileTheme(profile(look("#E0E0E0", 1)), true, "own");
  assert.equal(theme.dark, true);
  for (const ink of [theme.sidebarInk, theme.stripInk]) {
    assert.equal(ink?.ink, "dark");
    assert.equal(ink.textPrimary, "#000000");
    assert.equal(ink.textTab, "#000000AD");
    assert.equal(ink.icon, "#000000C6");
    assert.equal(ink.tabSelectedText, "#FFFFFF");
  }
});

test("a dark colour keeps white text and a white selected title", () => {
  for (const hex of ["#2D3A8C", "#3FB06C", "#E5534B", "#9B6CF0"]) {
    for (const intensity of [0.3, 0.6, 1]) {
      const theme = profileTheme(profile(look(hex, intensity)), true, "own");
      if (!theme.dark) continue;
      const ink = textInk(theme.custom, true, "sidebar", DARK_SELECTED);
      assert.equal(ink.selectedDark, false, `${hex} at ${intensity}`);
      if (!ink.dark) assert.equal(theme.sidebarInk, null, `${hex} at ${intensity}`);
    }
  }
  assert.equal(profileTheme(profile(look("#2D3A8C", 1)), true, "own").sidebarInk, null);
});

test("ink follows contrast against the band it sits on, not a fixed lightness", () => {
  const mid = look("#C0C0C0", 0.6);
  const ink = textInk(mid, true, "sidebar", DARK_SELECTED);
  const brighter = textInk(look("#C0C0C0", 1), true, "sidebar", DARK_SELECTED);
  const dimmer = textInk(look("#C0C0C0", 0.3), true, "sidebar", DARK_SELECTED);
  assert.equal(dimmer.dark, false);
  assert.equal(brighter.dark, true);
  assert.equal(typeof ink.dark, "boolean");
  const opaque = textInk(look("#A0A0A0", 0.3, "dark", 0), true, "sidebar", DARK_SELECTED);
  const translucent = textInk(look("#A0A0A0", 0.3, "dark", 1), true, "sidebar", DARK_SELECTED);
  assert.equal(opaque.dark, true);
  assert.equal(translucent.dark, false);
});

test("light mode, presets and the setting leave the tokens alone", () => {
  assert.equal(profileTheme(profile(look("#E0E0E0", 1, "light")), false, "own").sidebarInk, null);
  assert.equal(profileTheme({ color: "plum" }, true, "own").sidebarInk, null);
  const theme = profileTheme(profile(look("#E0E0E0", 1)), true, "own");
  const tokens = { textPrimary: "#FFFFFF", textTab: "#FFFFFFC7", tabSelectedText: "#FFFFFF", accent: "#4A77D4" };
  assert.deepEqual(inkedTokens(tokens, theme.sidebarInk, false), tokens);
  const inked = inkedTokens(tokens, theme.sidebarInk, true);
  assert.deepEqual(inked, { textPrimary: "#000000", textTab: "#000000AD", tabSelectedText: "#FFFFFF", accent: "#4A77D4", ink: "dark" });
  assert.equal(tokens.textPrimary, "#FFFFFF");
});
