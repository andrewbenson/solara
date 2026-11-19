import assert from "node:assert/strict";
import { test } from "node:test";
import { themeFor } from "./theme.ts";

test("an incognito window plays the New Tab power-up in the neutral profile colour", () => {
  const incognito = themeFor("incognito");
  assert.deepEqual(incognito.powerUpPalette, themeFor("neutral:dark").powerUpPalette);
  assert.deepEqual(incognito.powerUpPalette, ["#808080A6"]);
  assert.equal(incognito.powerUpColor, "#808080A6");
});

test("a Neutral profile window keeps the same neutral power-up in light and dark", () => {
  assert.deepEqual(themeFor("neutral:light").powerUpPalette, ["#808080A6"]);
  assert.deepEqual(themeFor("neutral:dark").powerUpPalette, ["#808080A6"]);
});

test("profile colours keep their own power-up", () => {
  assert.deepEqual(themeFor("plum:light").powerUpPalette, ["#B5556B"]);
  assert.notDeepEqual(themeFor("plum:dark").powerUpPalette, themeFor("incognito").powerUpPalette);
});
