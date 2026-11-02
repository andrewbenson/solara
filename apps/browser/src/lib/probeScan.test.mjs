import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const scanner = fileURLToPath(new URL("../../../../scripts/agent/probe-scan", import.meta.url));

function scan(marker) {
  const root = mkdtempSync(join(tmpdir(), "solara-probe-scan-"));
  try {
    const app = join(root, "Solara.app");
    const helpers = join(app, "Contents", "Frameworks", "Helper.app", "Contents", "MacOS");
    mkdirSync(helpers, { recursive: true });
    const source = join(root, "main.c");
    writeFileSync(source, `#include <stdio.h>
int main(void) { puts(${JSON.stringify(marker)}); return 0; }
`);
    const compiled = spawnSync("clang", [source, "-o", join(helpers, "Helper")], { encoding: "utf8" });
    assert.equal(compiled.status, 0, compiled.stderr);
    return spawnSync("bash", [scanner, app], { encoding: "utf8" });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("probe-scan accepts a clean Mach-O", { skip: process.platform !== "darwin" }, () => {
  const result = scan("Solara");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1 Mach-O files clean/);
});

test("probe-scan rejects the system notification override in a nested Mach-O", { skip: process.platform !== "darwin" }, () => {
  const result = scan("SOLARA_NOTIFICATIONS_SYSTEM");
  assert.equal(result.status, 1, result.stdout);
  assert.match(result.stderr, /error:.*Helper/);
});
