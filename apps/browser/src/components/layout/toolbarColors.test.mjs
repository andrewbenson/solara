import assert from "node:assert/strict";
import { test } from "node:test";
import { railToolbarOnFrame, toolbarPalette } from "./toolbarColors.ts";
import { profileTheme, themeFor } from "../../lib/theme.ts";

const solid = (value, mode) => ({
  stops: [{ x: 0.5, y: 0.5, color: { r: value, g: value, b: value, a: 1 } }],
  intensity: 1,
  mode,
  grain: 0,
  texture: "grain",
  translucency: 0,
});

test("a toolbar on the frame uses the sidebar ink and keeps its field and interaction fills", () => {
  const themes = [
    themeFor("purple:dark"),
    themeFor("purple:light"),
    profileTheme({ color: "plum", theme: solid(1, "dark") }, true),
    profileTheme({ color: "plum", theme: solid(0, "light") }, false),
  ];
  for (const theme of themes) {
    for (const site of [null, "#000000", "#FFFFFF"]) {
      const palette = toolbarPalette(theme, site, true);
      assert.equal(palette.background, null);
      assert.equal(palette.text, theme.textPrimary);
      assert.equal(palette.secondary, theme.textSecondary);
      assert.equal(palette.icon, theme.icon);
      assert.equal(palette.iconDisabled, theme.iconDisabled);
      assert.equal(palette.pill, theme.urlPill);
      assert.equal(palette.hover, theme.toolbarHover);
      assert.equal(palette.pressed, theme.toolbarPressed);
    }
  }
});

test("a toolbar inside the card keeps its site fill and matching ink after a frame toolbar was drawn", () => {
  const theme = themeFor("purple:light");
  toolbarPalette(theme, "#000000", true);
  const palette = toolbarPalette(theme, "#000000");
  assert.equal(palette.background, "#000000");
  assert.equal(palette.text, "#FFFFFF");
  assert.equal(palette.pill, "rgba(255,255,255,0.1)");
});

test("a split pane uses frame ink only while focused in the visible sidebar rail", () => {
  for (const [iconsOnly, focused, topTabs, fullscreen, expected] of [
    [true, true, false, false, true],
    [true, false, false, false, false],
    [true, true, true, false, false],
    [true, true, false, true, false],
    [false, true, false, false, false],
  ]) {
    const onFrame = railToolbarOnFrame(iconsOnly, focused, topTabs, fullscreen);
    assert.equal(onFrame, expected);
    assert.equal(toolbarPalette(themeFor("purple:light"), "#000000", onFrame).background, expected ? null : "#000000");
  }
});


test("full sidebar and other card layouts preserve site bands and dividers in light and dark", () => {
  for (const dark of [false, true]) {
    const theme = themeFor(`purple:${dark ? "dark" : "light"}`);
    for (const [iconsOnly, focused, topTabs, fullscreen, sidebarVisible] of [
      [false, true, false, false, true],
      [true, true, true, false, true],
      [true, false, false, false, true],
      [true, true, false, true, true],
      [true, true, false, false, false],
    ]) {
      const onFrame = railToolbarOnFrame(iconsOnly, focused, topTabs, fullscreen, sidebarVisible);
      assert.equal(onFrame, false, JSON.stringify({ iconsOnly, focused, topTabs, fullscreen, sidebarVisible }));
      for (const site of ["#000000", "#FFFFFF", "#A83E64"]) {
        const expected = toolbarPalette(theme, site);
        const actual = toolbarPalette(theme, site, onFrame);
        assert.equal(actual.background, site);
        assert.equal(actual.divider, expected.divider);
        assert.equal(actual.text, expected.text);
        toolbarPalette(theme, site, true);
        assert.deepEqual(toolbarPalette(theme, site, onFrame), expected);
      }
    }
  }
});

test("switching a visible rail to full sidebar restores the site palette immediately", () => {
  for (const mode of ["light", "dark"]) {
    const theme = themeFor(`purple:${mode}`);
    for (const iconsOnly of [false, true, false]) {
      const onFrame = railToolbarOnFrame(iconsOnly, true, false, false, true);
      const palette = toolbarPalette(theme, "#A83E64", onFrame);
      assert.equal(palette.background, iconsOnly ? null : "#A83E64");
      assert.equal(palette.divider, iconsOnly ? toolbarPalette(theme, null).divider : "rgba(255,255,255,0.025)");
    }
  }
});
