import assert from "node:assert/strict";
import test from "node:test";
import { nativeWorkCounts, sidebarWorkCounts, validateNativeWork, validateSidebarRealization } from "./native-work.mjs";

const sample = () => ({ version: 1, rows: { created: 200, bound: 400, reused: 200, live: 200 }, groups: [{ windowId: "w1", profileId: "default", kind: "tab", created: 200, bound: 400, reused: 200, live: 200 }], layoutApplications: 2, slotPublishes: 3, activeAnimationLinks: 0, liveSubscriptions: 3, deferredJobs: 5, pendingDeferredJobs: 0, hosts: [{ windowId: "w1", kind: "shell", count: 1 }] });

const realization = () => ({ enabled: true, effectiveClip: [0, 0, 200, 80], logical: [
  { key: "t:a", kind: "tab", region: "scroll", frame: [0, 0, 200, 37], clip: [0, 0, 200, 80], presentation: null },
  { key: "t:b", kind: "tab", region: "scroll", frame: [0, 90, 200, 37], clip: [0, 0, 200, 80], presentation: null },
], bound: [{ key: "t:a", kind: "tab", allocationId: "cell-1", token: 1, frame: [0, 0, 200, 37], clip: [0, 0, 200, 80], presentation: null, label: "A", selected: true, active: true, retired: false }], reuse: [{ kind: "tab", count: 1, highWater: 1 }] });

test("sidebar counter comparisons exclude other surfaces and refuse absent evidence", () => {
  const value = sample();
  assert.throws(() => sidebarWorkCounts(value, "w1"), /no sidebar counters/);
  value.groups[0].kind = "sidebar.tab.full";
  value.groups.push({ windowId: "w2", profileId: "default", kind: "sidebar.tab.full", created: 20, bound: 30, reused: 10, live: 20 });
  for (const key of ["created", "bound", "reused", "live"]) value.rows[key] += value.groups[1][key];
  assert.deepEqual(sidebarWorkCounts(value, "w1"), { created: 200, bound: 400, reused: 200, live: 200 });
});

test("sidebar visibility uses exact target or presentation intersection without overscan", () => {
  const value = realization();
  assert.equal(validateSidebarRealization(value), value);
  value.logical[1].presentation = [0, 70, 200, 37];
  assert.throws(() => validateSidebarRealization(value), /missing visible bindings t:b/);
  value.bound.push({ ...value.bound[0], key: "t:b", allocationId: "cell-2", token: 2, frame: [0, 90, 200, 37], presentation: [0, 70, 200, 37] });
  value.reuse[0].highWater = 2;
  assert.equal(validateSidebarRealization(value), value);
  value.logical[1].presentation = [200, 70, 200, 37];
  assert.throws(() => validateSidebarRealization(value), /offscreen or mismatched binding/);
});

test("sidebar reuse evidence rejects unbounded bins and ambiguous binding identity", () => {
  for (const change of [
    (value) => { delete value.logical[0].clip; },
    (value) => { delete value.logical[0].presentation; },
    (value) => { value.reuse[0].count = 2; },
    (value) => { value.bound[0].token = 0; },
    (value) => { value.bound[0].label = null; },
    (value) => { value.bound[0].frame[1] = 90; },
    (value) => { value.bound[0].clip[2] = 20; },
    (value) => { value.bound.push({ ...value.bound[0] }); },
    (value) => { value.bound = []; },
    (value) => { value.reuse = []; },
  ]) {
    const value = realization();
    change(value);
    assert.throws(() => validateSidebarRealization(value), /sidebar realization/);
  }
});

test("retiring rows survive only a visible presentation interval", () => {
  const value = realization();
  value.bound.push({ ...value.bound[0], key: "retired", allocationId: "cell-2", retired: true, presentation: [0, 70, 200, 37] });
  value.reuse[0].highWater = 2;
  assert.throws(() => validateSidebarRealization(value), /settled retired/);
  assert.equal(validateSidebarRealization(value, { settled: false }), value);
  value.bound[1].presentation = [0, 80, 200, 37];
  assert.throws(() => validateSidebarRealization(value, { settled: false }), /offscreen/);
});

const retiringPicture = () => {
  const value = realization();
  value.logical[1].frame = [0, 37, 200, 37];
  value.bound.push({ ...value.bound[0], key: "t:b", allocationId: "cell-2", frame: [0, 37, 200, 37], label: "B", selected: false, active: false });
  value.bound.push({ ...value.bound[0], key: "picture:closed", allocationId: "picture-1", token: 0, retired: true, picture: true, presentation: [0, 70, 200, 37] });
  value.reuse[0] = { kind: "tab", count: 2, highWater: 2 };
  return value;
};

test("a visible retiring picture does not consume a full cell viewport's reuse-bin demand", () => {
  const value = retiringPicture();
  assert.equal(value.reuse[0].highWater, 2);
  assert.equal(value.reuse[0].count, 2);
  assert.equal(validateSidebarRealization(value, { settled: false }), value);
});

test("a retiring picture with a positive token remains outside reuse-bin cell demand", () => {
  const value = retiringPicture();
  value.bound.at(-1).token = 1;
  assert.equal(validateSidebarRealization(value, { settled: false }), value);
});

test("retiring picture evidence preserves live tokens, unique identities, clipping and bin bounds", () => {
  for (const change of [
    (value) => { value.bound[0].token = 0; },
    (value) => { value.bound.at(-1).retired = false; },
    (value) => { delete value.bound.at(-1).picture; },
    (value) => { value.bound.at(-1).picture = "true"; },
    (value) => { value.bound.at(-1).token = -1; },
    (value) => { value.bound.at(-1).token = 0.5; },
    (value) => { value.bound.at(-1).allocationId = value.bound[0].allocationId; },
    (value) => { value.bound.at(-1).key = value.bound[0].key; },
    (value) => { value.bound.at(-1).presentation = null; },
    (value) => { value.bound.at(-1).presentation[1] = 80; },
    (value) => { value.reuse[0].count = 3; },
    (value) => { value.reuse[0].highWater = 0; value.reuse[0].count = 0; },
  ]) {
    const value = retiringPicture();
    change(value);
    assert.throws(() => validateSidebarRealization(value, { settled: false }), /sidebar realization/);
  }
  assert.throws(() => validateSidebarRealization(retiringPicture()), /settled retired/);
});

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
