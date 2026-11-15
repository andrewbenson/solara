import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const driver = readFileSync(new URL("../../../scripts/swipe-capsule-test.mjs", import.meta.url), "utf8");
const helpers = driver.split("const HELPERS = `")[1].split("`;")[0];
const hermes = new URL("../../../macos/Pods/hermes-engine/destroot/bin/hermes", import.meta.url);

test("capsule driver helpers compile in the app Hermes eval context", { skip: !existsSync(hermes) }, () => {
  const result = spawnSync(hermes.pathname, ["-"], { input: `new Function("ac", ${JSON.stringify(helpers)}); print("parsed");`, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /parsed/);
});

test("default layout inspection compiles in the app Hermes eval context", { skip: !existsSync(hermes) }, () => {
  const source = readFileSync(new URL("../../../scripts/native-layout-default-test.mjs", import.meta.url), "utf8");
  const inspect = source.split("const inspect = () => app.eval(`")[1].split("`);")[0];
  const result = spawnSync(hermes.pathname, ["-"], { input: `new Function("ac", ${JSON.stringify(inspect)}); print("parsed");`, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /parsed/);
});
