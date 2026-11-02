import assert from "node:assert/strict";
import { test } from "node:test";
import { dialogOver } from "./dialog-window.mjs";

const level = (w) => (w.layer <= -1000000 + 2000 && w.layer > -2000000 ? w.layer + 1000000 : w.layer);
const app = { id: 10, layer: 0, alpha: 1, x: 80, y: 411, w: 1280, h: 800, title: "" };
const sidebar = { id: 11, layer: 0, alpha: 1, x: 80, y: 411, w: 300, h: 800, title: "" };
const dialog = { id: 20, layer: 0, alpha: 1, x: 496, y: 458, w: 448, h: 385, title: "" };

test("a new dialog-sized window centred over the app window is the dialog, with no title to go on", () => {
  const found = dialogOver([app, sidebar], [dialog, app, sidebar], level);
  assert.equal(found?.dialog.id, 20);
  assert.equal(found?.owner.id, 10);
});

test("the dialog's title is ignored, readable or not", () => {
  const titled = { ...dialog, title: "Choose where to save your passkey for localhost" };
  assert.equal(dialogOver([app], [titled, app], level)?.dialog.id, 20);
});

test("a window that was already there before the click isn't the dialog", () => {
  assert.equal(dialogOver([dialog, app], [dialog, app], level), null);
});

test("a new window off to one side of the app window, or hanging over its edge, isn't the dialog", () => {
  const aside = { ...dialog, x: app.x + app.w + 20 };
  assert.equal(dialogOver([app], [aside, app], level), null);
  const overEdge = { ...dialog, x: app.x + app.w - 100 };
  assert.equal(dialogOver([app], [overEdge, app], level), null);
});

test("Chrome's passkey dialog as the 0.1.1 smoke saw it: over the page area beside the sidebar, below the toolbar", () => {
  const shownApp = { id: 22033, layer: -1000000, alpha: 1, x: 80, y: 411, w: 1280, h: 800, title: "" };
  const shown = { id: 22040, layer: -1000000, alpha: 1, x: 587, y: 458, w: 448, h: 385, title: "" };
  assert.equal(dialogOver([shownApp], [shown, shownApp], level)?.dialog.id, 22040);
});

test("a new full-size window or a tiny one isn't the dialog", () => {
  assert.equal(dialogOver([app], [{ ...app, id: 30 }, app], level), null);
  assert.equal(dialogOver([app], [{ ...dialog, w: 40, h: 20, x: 700, y: 600 }, app], level), null);
});

test("hidden-instance layers are normalised, so a dialog over an alpha-0 app window is still found", () => {
  const hiddenApp = { ...app, layer: -1000000, alpha: 0 };
  const hiddenDialog = { ...dialog, layer: -999000 };
  assert.equal(dialogOver([hiddenApp], [hiddenDialog, hiddenApp], level)?.dialog.id, 20);
});
