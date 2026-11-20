import assert from "node:assert/strict";
import { test } from "node:test";

const { moveToProfileItems } = await import("./moveToProfileItems.ts");

const profile = (id, name) => ({ id, name, color: "blue", icon: null, createdAt: 0 });
const state = (ids) => ({ profileOrder: ids, profiles: Object.fromEntries(ids.map((id) => [id, profile(id, id.toUpperCase())])) });

test("Move to lists every profile directly, then New Profile and a separator before Window", () => {
  const items = moveToProfileItems(state(["home", "work", "school"]), { profileId: "work" }, false);
  assert.deepEqual(items, [
    { id: "profile:home", title: "HOME", checked: false, enabled: true },
    { id: "profile:work", title: "WORK", checked: true, enabled: false },
    { id: "profile:school", title: "SCHOOL", checked: false, enabled: true },
    { id: "profile:new", title: "New Profile…" },
    { separator: true },
  ]);
});

test("a single profile shows checked and disabled, with New Profile still offered", () => {
  assert.deepEqual(moveToProfileItems(state(["home"]), { profileId: "home" }, false), [
    { id: "profile:home", title: "HOME", checked: true, enabled: false },
    { id: "profile:new", title: "New Profile…" },
    { separator: true },
  ]);
});

test("an incognito tab gets no profile items and no separator for them", () => {
  assert.deepEqual(moveToProfileItems(state(["home", "work"]), { profileId: "incognito" }, true), []);
});
