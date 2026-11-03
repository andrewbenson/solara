import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const browserRoot = fileURLToPath(new URL("..", import.meta.url));
const generator = fileURLToPath(new URL("../../../native/SolaraKit/Scripts/omnibox-command-source-fixtures.mts", import.meta.url));
const regenerate = `node --import ./src/test-loader.mjs ${generator}`;

test("SolaraKit's omnibox command-source fixture matches what the store produces now", () => {
  const run = spawnSync(process.execPath, ["--no-warnings", "--import", "./src/test-loader.mjs", generator, "--verify"], {
    cwd: browserRoot,
    encoding: "utf8",
    timeout: 60000,
    env: { ...process.env, LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8", TZ: "UTC" },
  });
  assert.equal(run.status, 0, `${run.stdout}${run.stderr}\nThe fixture is stale: from apps/browser run\n  ${regenerate}\nand commit native/SolaraKit/Tests/SolaraOmniboxTests/Fixtures/command-sources.json`);
  assert.match(run.stdout, /^PASS \d+ command source fixtures/m);
});
