import assert from "node:assert/strict";
import test from "node:test";
import { nativeWorkCounts, validateNativeWork } from "./native-work.mjs";

const sample = () => ({ version: 1, rows: { created: 200, bound: 400, reused: 200, live: 200 }, groups: [{ windowId: "w1", profileId: "default", kind: "tab", created: 200, bound: 400, reused: 200, live: 200 }], layoutApplications: 2, slotPublishes: 3, activeAnimationLinks: 0, liveSubscriptions: 3, deferredJobs: 5, pendingDeferredJobs: 0, hosts: [{ windowId: "w1", kind: "shell", count: 1 }] });

test("native report preserves event counters and live gauges separately", () => {
  const report = sample();
  assert.equal(validateNativeWork(report), report);
  assert.equal(nativeWorkCounts(report)["rows.created"], 200);
  assert.equal(nativeWorkCounts(report)["rows.live"], 200);
  assert.equal(nativeWorkCounts(report).activeAnimationLinks, 0);
});

for (const report of [undefined, null, {}, { ...sample(), version: 2 }, { ...sample(), rows: { created: 0 } }, { ...sample(), slotPublishes: -1 }, { ...sample(), liveSubscriptions: null }, { ...sample(), groups: [] }]) {
  test(`missing, invalid or incompatible native counters cannot become zero: ${JSON.stringify(report)}`, () => {
    assert.throws(() => validateNativeWork(report), /native work/);
  });
}

test("native groups must aggregate to totals and identify their window, profile and kind", () => {
  const report = sample();
  report.groups[0].live--;
  assert.throws(() => validateNativeWork(report), /native work.*live/);
  report.groups[0].live++;
  report.groups[0].profileId = "";
  assert.throws(() => validateNativeWork(report), /native work.*profileId/);
});

test("stamped reports reject a scenario whose native sample is missing", async () => {
  const { collectNativeWork } = await import("./ratchet.mjs");
  const report = { nativeWorkRevision: 1, nativeWorkWindow: "outerScenario", results: [{ typing: { stats: {}, nativeWork: sample() } }] };
  assert.equal(collectNativeWork([report])[0].counts["rows.created"], 200);
  delete report.results[0].typing.nativeWork;
  assert.throws(() => collectNativeWork([report]), /native work/);
  assert.deepEqual(collectNativeWork([{ results: [{ typing: { stats: {} } }] }]), []);
});

test("window contract requires one owner, geometry and explicit page identity census", async () => {
  const { validateWindowContract } = await import("./native-work.mjs");
  const contract = { bounds: [0, 0, 1440, 900], sidebar: [0, 0, 260, 900], topStrip: null, slots: [["react", "RCTRootView"]], ownerCount: 1, hostCounts: { ShellHost: 1, sidebar: 1, topStrip: 0 }, pageIdentities: [{ tabId: "t0", identity: "page-1" }] };
  assert.equal(validateWindowContract(contract), contract);
  assert.throws(() => validateWindowContract({ ...contract, ownerCount: 2 }), /native layout contract/);
  assert.throws(() => validateWindowContract({ ...contract, pageIdentities: undefined }), /native layout contract/);
});

test("append requires the same native mode, revision and explicit outer scenario window", async () => {
  const { validateNativeWorkAppend } = await import("./native-work.mjs");
  const legacy = { results: [{ typing: { stats: {} } }] };
  const native = { nativeWorkRevision: 1, nativeWorkWindow: "outerScenario", results: [{ typing: { stats: {}, nativeWork: sample() } }] };
  assert.doesNotThrow(() => validateNativeWorkAppend(legacy, false));
  assert.doesNotThrow(() => validateNativeWorkAppend(native, true));
  assert.throws(() => validateNativeWorkAppend(legacy, true), /native work/);
  assert.throws(() => validateNativeWorkAppend(native, false), /native work/);
  delete native.results[0].typing.nativeWork;
  assert.throws(() => validateNativeWorkAppend(native, true), /native work/);
});
