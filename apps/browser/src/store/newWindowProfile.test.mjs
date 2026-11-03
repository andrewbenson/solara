import assert from "node:assert/strict";
import { test } from "node:test";
const { newWindowProfile } = await import("./small.ts");

const profiles = { default: { id: "default" }, work: { id: "work" } };

function state(windows, focusOrder = Object.keys(windows)) {
  return { profiles, windows, windowOrder: Object.keys(windows), ui: { focusOrder } };
}

test("New Window opens on the profile of the window it was chosen in", () => {
  const s = state({ a: { id: "a", profileId: "work" }, b: { id: "b", profileId: "default" } });
  assert.equal(newWindowProfile(s, "a"), "work");
  assert.equal(newWindowProfile(s, "b"), "default");
});

test("with no window named, New Window follows the focused window's profile", () => {
  const s = state({ a: { id: "a", profileId: "default" }, b: { id: "b", profileId: "work" } }, ["b", "a"]);
  assert.equal(newWindowProfile(s, null), "work");
});

test("a profile chosen from a menu wins over the window's", () => {
  const s = state({ a: { id: "a", profileId: "work" } });
  assert.equal(newWindowProfile(s, "a", "default"), "default");
});

test("from an incognito window, New Window opens a regular window on the profile it came from", () => {
  const s = state({ p: { id: "p", profileId: "incognito:p:work", incognito: true, originalProfileId: "work" } });
  assert.equal(newWindowProfile(s, "p"), "work");
});

test("from a Little Solara window, New Window opens on that window's profile", () => {
  const s = state({ l: { id: "l", profileId: "work", kind: "small" } });
  assert.equal(newWindowProfile(s, "l"), "work");
});

test("a window whose profile is gone leaves the choice to the default", () => {
  const s = state({ a: { id: "a", profileId: "deleted" } });
  assert.equal(newWindowProfile(s, "a"), undefined);
});
