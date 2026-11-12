import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "solara-engine-pair-"));
  const script = join(root, "packages/solaracore/scripts/write-engine-pair.sh");
  const js = join(root, "apps/browser/src/nativeApi.tsx");
  const native = join(root, "packages/shell/ios/AppModule.swift");
  const header = join(root, "engine/chromium/src/chrome/browser/solara/public/ac_engine.h");
  const app = join(root, "Solara.app");
  const binary = join(app, "Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework");
  for (const path of [script, js, native, header, binary]) mkdirSync(join(path, ".."), { recursive: true });
  copyFileSync(new URL("./write-engine-pair.sh", import.meta.url), script);
  writeFileSync(binary, "fixture engine");
  const versions = (shell = 41, engine = 40, protocol = 2, bundle = shell) => {
    writeFileSync(js, `export const NATIVE_API_VERSION = ${bundle};\n`);
    writeFileSync(native, `Constant("apiVersion") { () -> Int in ${shell} }\n`);
    writeFileSync(header, `#define AC_NOTIFICATIONS_NATIVE_API_VERSION ${engine}\n#define AC_NOTIFICATIONS_PROTOCOL_VERSION ${protocol}\n`);
  };
  const run = (finalize = "") => spawnSync("bash", [script, app, "test.solara", "1.0", "1", finalize], { encoding: "utf8", timeout: 10000 });
  const value = (field) => spawnSync("plutil", ["-extract", field, "raw", join(app, "Contents/Resources/solara-engine-pair.plist")], { encoding: "utf8", timeout: 3000 }).stdout.trim();
  return { root, versions, run, value };
}

test("a shell API upgrade packages and finalizes the unchanged notification engine contract", () => {
  const f = fixture();
  try {
    f.versions();
    const result = f.run();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.value("nativeApi"), "41");
    assert.equal(f.value("notificationNativeApi"), "40");
    assert.equal(f.value("notificationProtocol"), "2");
    assert.equal(f.run("finalize").status, 0);
    const changed = spawnSync("plutil", ["-replace", "notificationNativeApi", "-integer", "41", join(f.root, "Solara.app/Contents/Resources/solara-engine-pair.plist")], { timeout: 3000 });
    assert.equal(changed.status, 0);
    assert.equal(f.run("finalize").status, 1);
    assert.equal(f.run().status, 0);
    f.versions(42);
    assert.equal(f.run("finalize").status, 1);
  } finally {
    rmSync(f.root, { recursive: true, force: true });
  }
});

test("packaging refuses skewed shell APIs and unsupported notification engine contracts", () => {
  const f = fixture();
  try {
    for (const versions of [[41, 40, 2, 40], [39, 40, 2], [41, 41, 2], [41, 40, 3]]) {
      f.versions(...versions);
      assert.equal(f.run().status, 1, JSON.stringify(versions));
    }
  } finally {
    rmSync(f.root, { recursive: true, force: true });
  }
});
