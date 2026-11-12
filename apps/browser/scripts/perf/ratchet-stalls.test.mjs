import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import { flatten } from "./ratchet.mjs";

const zero = { status: "ok", count: 0, totalMs: 0 };
const busy = { status: "ok", count: 2, totalMs: 100 };
const result = (stalls = busy) => ({ probeRevision: 3, typing: { stats: {} }, stalls: { typing: stalls } });

function rig(body) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "ratchet-stalls-")));
  const perf = join(dir, "apps/browser/scripts/perf");
  mkdirSync(perf, { recursive: true });
  mkdirSync(join(dir, "scripts/lib"), { recursive: true });
  copyFileSync(new URL("./ratchet.mjs", import.meta.url), join(perf, "ratchet.mjs"));
  copyFileSync(new URL("../../../../scripts/lib/identity.mjs", import.meta.url), join(dir, "scripts/lib/identity.mjs"));
  const ceilings = { about: "fixture", baseline: {}, revisions: { probe: "3", bench: "7" }, exact: {}, noisy: {}, micro: {}, instr: {}, stallBaseline: { status: "measured", runs: 6 }, stalls: { "typing.stallCount": 2, "typing.stallMs": 100 } };
  const save = (name, value) => { const path = join(perf, name); writeFileSync(path, JSON.stringify(value)); return path; };
  const run = (command, reports, ...args) => spawnSync(process.execPath, [join(perf, "ratchet.mjs"), command, ...reports.map((r, i) => save(`report${i}.json`, { seed: "big", benchRevision: 7, results: r })), ...args], { encoding: "utf8" });
  save("ratchet.json", ceilings);
  try { body({ run, save, ceilings, read: () => JSON.parse(readFileSync(join(perf, "ratchet.json"), "utf8")) }); }
  finally { rmSync(dir, { recursive: true, force: true }); }
}

test("flatten exposes stall totals including zero and the small startup window", () => {
  assert.equal(flatten(result()).counts["typing.stallCount"], 2);
  assert.equal(flatten(result()).counts["typing.stallMs"], 100);
  assert.equal(flatten(result(zero)).counts["typing.stallCount"], 0);
  const small = flatten({ startup: {}, stalls: { startup: busy } }, "small.");
  assert.equal(small.counts["small.startup.stallMs"], 100);
  assert.equal(flatten(result({ status: "pending", reason: "locked" })).counts["typing.stallMs"], undefined);
});

test("CLI gates both stall metrics without named-counter slack", () => rig(({ run }) => {
  assert.equal(run("check", [[result()]]).status, 0);
  const count = run("check", [[result({ ...busy, count: 3 })]]);
  assert.equal(count.status, 1);
  assert.match(count.stdout, /stalls: typing\.stallCount/);
  const time = run("check", [[result({ ...busy, totalMs: 100.001 })]]);
  assert.equal(time.status, 1);
  assert.match(time.stdout, /stalls: typing\.stallMs/);
}));

for (const telemetry of [undefined, { status: "pending", reason: "screen locked" }, { ...busy, count: -1 }, { ...busy, totalMs: null }]) {
  test(`missing or invalid telemetry cannot become zero: ${JSON.stringify(telemetry)}`, () => rig(({ run }) => {
    const missing = result(telemetry);
    if (telemetry === undefined) delete missing.stalls;
    const r = run("check", [[result(zero), missing, result(zero)]]);
    assert.equal(r.status, 1);
    assert.match(r.stdout, /pending: stalls typing/);
    assert.doesNotMatch(r.stdout, /ratchet: ok/);
  }));
}

test("stall medians use complete runs and openClose has one scenario window", () => rig(({ run, ceilings, save }) => {
  ceilings.stalls = { "openClose.stallCount": 2, "openClose.stallMs": 100 };
  save("ratchet.json", ceilings);
  const r = (s) => ({ probeRevision: 3, openClose: {}, stalls: { openClose: s } });
  assert.equal(run("check", [[r(zero), r(busy), r({ ...busy, count: 10, totalMs: 500 })]]).status, 0);
}));

test("an unmeasured baseline remains pending even with healthy telemetry", () => rig(({ run, ceilings, save }) => {
  ceilings.stallBaseline.status = "pending";
  save("ratchet.json", ceilings);
  const r = run("check", [[result(zero)]]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /pending: stalls baseline/);
}));

test("init commissions zero and noisy stall ceilings from six complete runs", () => rig(({ run, save, read }) => {
  const micro = save("micro.json", {});
  const results = [0, 0, 0, 0, 0, 2].map((count) => result({ status: "ok", count, totalMs: count * 50 }));
  const r = run("init", [results], "--micro", micro, "--no-instr");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(read().stalls["typing.stallCount"], 3);
  assert.equal(read().stalls["typing.stallMs"], 111);
  assert.equal(read().stallBaseline.status, "measured");
  const zeros = run("init", [Array.from({ length: 6 }, () => result(zero))], "--micro", micro, "--no-instr");
  assert.equal(zeros.status, 0, zeros.stderr);
  assert.equal(read().stalls["typing.stallCount"], 0);
  assert.equal(read().stalls["typing.stallMs"], 0);
}));

test("init refuses incomplete stall runs and adopt never raises commissioned ceilings", () => rig(({ run, save, read }) => {
  const micro = save("micro.json", {});
  const incomplete = run("init", [Array.from({ length: 6 }, () => result({ status: "pending", reason: "nap" }))], "--micro", micro, "--no-instr");
  assert.equal(incomplete.status, 2);
  const adopted = run("init", [Array.from({ length: 6 }, () => result({ ...busy, count: 4, totalMs: 200 }))], "--micro", micro, "--no-instr", "--adopt");
  assert.equal(adopted.status, 0, adopted.stderr);
  assert.equal(read().stalls["typing.stallCount"], 2);
  assert.equal(read().stalls["typing.stallMs"], 100);
}));

test("small launch gates separately from the big session", () => rig(({ run, save, ceilings }) => {
  ceilings.stalls["small.launch.stallCount"] = 0;
  ceilings.stalls["small.launch.stallMs"] = 0;
  save("ratchet.json", ceilings);
  const small = save("small.json", { seed: "small", benchRevision: 7, results: [{ probeRevision: 3, launch: { stats: {} }, stalls: { launch: busy } }] });
  const r = run("check", [[result(zero)]], small);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /stalls: small\.launch\.stallCount/);
}));

test("lower keeps stall ceilings without six complete runs and preserves them on unrelated writes", () => rig(({ run, save, ceilings, read }) => {
  ceilings.exact = { "typing.commits": 10 };
  save("ratchet.json", ceilings);
  const one = { ...result(zero), typing: { stats: { commits: 1 } } };
  assert.equal(run("lower", [[one]]).status, 0);
  assert.equal(read().exact["typing.commits"], 1);
  assert.equal(read().stalls["typing.stallCount"], 2);
  const invalid = [one, one, one, one, one, result({ status: "pending", reason: "lost record" })];
  assert.equal(run("lower", [invalid]).status, 0);
  assert.equal(read().stalls["typing.stallCount"], 2);
  assert.equal(run("lower", [Array.from({ length: 6 }, () => one)]).status, 0);
  assert.equal(read().stalls["typing.stallCount"], 0);
  assert.equal(read().stalls["typing.stallMs"], 0);
}));

test("adopt commissions placeholders once and refuses an incomplete commissioning census", () => rig(({ run, save, ceilings, read }) => {
  const micro = save("micro.json", {});
  ceilings.stallBaseline.status = "pending";
  ceilings.stalls["typing.stallCount"] = 0;
  ceilings.stalls["typing.stallMs"] = 0;
  ceilings.stalls["launch.stallCount"] = 0;
  save("ratchet.json", ceilings);
  const results = Array.from({ length: 6 }, () => result(busy));
  assert.equal(run("init", [results], "--micro", micro, "--no-instr", "--adopt").status, 2);
  delete ceilings.stalls["launch.stallCount"];
  save("ratchet.json", ceilings);
  const r = run("init", [results], "--micro", micro, "--no-instr", "--adopt");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(read().stalls["typing.stallCount"], 3);
  assert.equal(read().stallBaseline.status, "measured");
}));

test("an empty report cannot pass the stall gate", () => rig(({ run }) => {
  const r = run("check", [[]]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /pending: stalls.*no scenarios/);
}));
