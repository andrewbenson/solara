import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("./native-bench.mjs", import.meta.url), "utf8");
const between = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));

function driver({ delivered = false, committed = false, code = 0 } = {}) {
  let at = 1000;
  const marks = [];
  const pending = [];
  const context = vm.createContext({
    FatalError: class FatalError extends Error {},
    Date: class extends Date { static now() { return at; } },
    sleep: async (ms) => { at += ms; },
    spawnSync: () => {
      if (delivered) {
        marks.push({ keydown: at, made: at });
        if (committed) pending.push({ journey: "j2", key: "new-tab", t0: at, bar: at + 10 });
      }
      return { status: code, stdout: code === 77 ? "" : JSON.stringify({ at }) + "\n", stderr: code === 77 ? "event-posting access denied" : "" };
    },
    join,
    existsSync: () => true,
    readFileSync: () => "",
    execFileSync: () => {},
    inputContenders: () => "no other Solara instance, test helper or key poster; uitest lock: none",
    here: "unused",
    toolDir: "unused",
    journeyState: async () => ({ pending, samples: {}, counts: {}, marks: {}, queries: [] }),
  });
  vm.runInContext([
    between("function acperf(", "function markerLibrary("),
    between("function postKeys(", "const journeyState ="),
    between("async function waitFor(", "const sampled ="),
    between("async function openNewTab(", "async function newTabKey("),
    "globalThis.openNewTab = openNewTab;",
  ].join("\n"), context);
  return () => context.openNewTab({ pid: 123, dataDir: "/scratch", marks: () => marks });
}

test("undelivered Cmd-T aborts before it can be reported as a missing bar", async () => {
  await assert.rejects(driver()(), (error) => error.name === "Error" && error.constructor.name === "FatalError" && /input delivery stopped/.test(error.message));
});

test("denied event-posting access aborts the entire bench", async () => {
  await assert.rejects(driver({ code: 77 })(), (error) => error.constructor.name === "FatalError" && /access denied/.test(error.message));
});

test("a delivered Cmd-T without a commit remains a missing bar", async () => {
  const result = await driver({ delivered: true })();
  assert.ok(result.press);
  assert.equal(result.bar, null);
});

test("a committed bar is returned only after Cmd-T delivery", async () => {
  const result = await driver({ delivered: true, committed: true })();
  assert.equal(result.press.at, 1000);
  assert.equal(result.bar.pending[0].key, "new-tab");
  assert.equal(result.bar.pending[0].bar, 1010);
});
