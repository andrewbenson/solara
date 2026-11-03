import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = readFileSync(new URL("./dropdownStart.ts", import.meta.url), "utf8");
const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;

function dropdown(compiled, state, Script) {
  const module = { exports: {} };
  const mocks = {
    react: { useMemo: (read) => read() },
    "../../store/browser": { useBrowser: (selector) => selector(state) },
  };
  new Script(compiled).runInNewContext({ exports: module.exports, module, require: (id) => mocks[id] ?? {} });
  return module.exports.useDropdownStart(true, "current", "profile");
}

const stateFor = (url, urls) => ({
  tabs: { current: { url, title: "Current", favicon: null } },
  history: { profile: urls.map((url, index) => ({ url, title: `History ${index}`, favicon: null, lastVisit: 100 - index })) },
});

test("dropdown start excludes the current page with a multiline fragment", () => {
  const url = "https://safe.example/#" + "#".repeat(20) + "\nx";
  const rows = dropdown(code, stateFor(url, ["https://safe.example/", "https://other.example/"]), vm.Script);
  assert.deepEqual(Array.from(rows, (row) => row.url), [url, "https://other.example/"]);
});

test("dropdown start keeps recency, fragments, queries and trailing slashes", () => {
  const urls = ["https://current.example/#part", "https://one.example/#a", "https://one.example/#b", "https://one.example", "https://one.example/?q=1", "https://two.example/", "https://three.example/"];
  const rows = dropdown(code, stateFor("https://current.example/", urls), vm.Script);
  assert.deepEqual(Array.from(rows, (row) => row.url), ["https://current.example/", "https://one.example/#a", "https://one.example", "https://one.example/?q=1", "https://two.example/"]);
});

test("dropdown start finishes malformed fragments within a child deadline", (t) => {
  const output = execFileSync(process.execPath, ["--input-type=module", "--eval", `
    import assert from "node:assert/strict";
    import vm from "node:vm";
    const dropdown = ${dropdown.toString()};
    const stateFor = ${stateFor.toString()};
    const url = "https://safe.example/#" + "#".repeat(400000) + "\\nx";
    const state = stateFor(url, ["https://safe.example/", "https://other.example/"]);
    const at = performance.now();
    const rows = dropdown(${JSON.stringify(code)}, state, vm.Script);
    const elapsed = performance.now() - at;
    assert.deepEqual(Array.from(rows, (row) => row.url), [url, "https://other.example/"]);
    process.stdout.write(JSON.stringify({ elapsed }));
  `], { encoding: "utf8", timeout: 10_000, killSignal: "SIGKILL" });
  t.diagnostic(`dropdownStart child call: ${JSON.parse(output).elapsed.toFixed(3)} ms`);
  assert.ok(JSON.parse(output).elapsed < 1000);
});
