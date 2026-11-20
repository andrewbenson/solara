import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const { groupOf } = await import("./organize.ts");
const fixture = JSON.parse(readFileSync(new URL("../../../../native/SolaraKit/Tests/SolaraStoreTests/Cases/group-of.json", import.meta.url), "utf8"));

test("groupOf matches the fixture Swift's Groups.innermostGroupOf is checked against", () => {
  for (const [tabId, groupId] of Object.entries(fixture.expected)) assert.equal(groupOf({ groups: fixture.groups }, tabId)?.id ?? null, groupId, tabId);
});
