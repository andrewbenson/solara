import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import * as policy from "./tabSleepPolicy.ts";

const vectors = JSON.parse(readFileSync(new URL("./tabSleep.vectors.json", import.meta.url), "utf8"));

for (const vector of vectors.candidates) {
  test(vector.name, () => {
    assert.equal(typeof policy.tabSleepCandidates, "function");
    const before = structuredClone(vector);
    assert.deepEqual(policy.tabSleepCandidates(vector), vector.expected);
    assert.deepEqual(vector, before);
  });
}

for (const vector of vectors.unusedProfiles) {
  test(vector.name, () => {
    assert.equal(typeof policy.unusedTabSleepProfiles, "function");
    const before = structuredClone(vector);
    assert.deepEqual(policy.unusedTabSleepProfiles(vector), {
      unusedSince: vector.expectedUnusedSince,
      eligibleIds: vector.expectedEligibleIds,
    });
    assert.deepEqual(vector, before);
  });
}
