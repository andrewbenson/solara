import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../../../../../", import.meta.url);
export const source = (path) => readFileSync(new URL(path, root), "utf8");

export function declaration(text, signature) {
  const start = text.indexOf(signature);
  assert.notEqual(start, -1, `missing production declaration: ${signature}`);
  assert.equal(text.indexOf(signature, start + signature.length), -1, `ambiguous production declaration: ${signature}`);
  const opening = text.indexOf("{", start);
  let depth = 1;
  let end = opening + 1;
  while (depth && end < text.length) {
    if (text[end] === "{") depth++;
    if (text[end] === "}") depth--;
    end++;
  }
  assert.equal(depth, 0, `unclosed production declaration: ${signature}`);
  return text.slice(start, end);
}

export function runNative(template, production, args = [], swift = false) {
  const directory = mkdtempSync(fileURLToPath(new URL(".safe-host-test-", root)));
  try {
    const program = `${directory}/test.${swift ? "swift" : "mm"}`;
    const binary = `${directory}/test`;
    const harness = source(`apps/browser/src/test-native/safe-host/${template}`);
    assert.equal(harness.split("__PRODUCTION__").length, 2);
    if (!swift) writeFileSync(`${directory}/SolaraCore-Swift.h`, source("apps/browser/src/test-native/safe-host/SolaraCore-Swift.h"));
    writeFileSync(program, harness.replace("__PRODUCTION__", production));
    const env = { ...process.env, TMPDIR: directory, CLANG_MODULE_CACHE_PATH: `${directory}/cache`, SWIFT_MODULECACHE_PATH: `${directory}/cache` };
    const compilation = swift
      ? ["-module-cache-path", `${directory}/cache`, program, "-o", binary]
      : ["-std=c++17", "-fobjc-arc", "-fblocks", "-Wno-nullability-completeness", "-framework", "Foundation", program, "-o", binary];
    try {
      execFileSync(swift ? "/usr/bin/swiftc" : "/usr/bin/clang++", compilation, { env, stdio: "pipe", timeout: 120000 });
    } catch (error) {
      throw new Error(error.stderr?.toString() || error.message);
    }
    return JSON.parse(execFileSync(binary, args, { env, encoding: "utf8", timeout: 10000 }));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
