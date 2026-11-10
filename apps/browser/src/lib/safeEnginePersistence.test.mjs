import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { declaration, source } from "../test-native/safe-host/run.mjs";

function persistence(category) {
  const directory = mkdtempSync(join(tmpdir(), "solara-safe-engine-persistence-"));
  try {
    const original = process.env.SOLARA_ENGINE_BRIDGE_FIXTURE
      ? readFileSync(process.env.SOLARA_ENGINE_BRIDGE_FIXTURE, "utf8")
      : source("packages/solaracore/ios/SolaraCoreEngineBridge.mm");
    const bridge = original
      .replace('#import "SolaraCoreEngineBridge.h"', "")
      .replace('#import "SolaraCoreBookmarkURL.h"', "static NSString *SolaraCanonicalBookmarkURL(NSString *url, NSError **error) { return nil; }\nstatic NSString *SolaraCanonicalBookmarkURLUTF16(NSData *units, NSError **error) { return nil; }")
      .replace('#import "SolaraCoreInternal.h"', "")
      .replace('#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"', "");
    const services = source("packages/solaracore/ios/SolaraCoreServices.mm");
    const helpers = services.slice(services.indexOf("NSDictionary *Parse("), services.indexOf("void (^gExtensionsHandler)"));
    const methods = [
      "+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:",
      "+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args secrets:",
      "+ (void)savePassword:", "+ (void)updatePassword:", "+ (void)deletePassword:", "+ (void)password:",
      "+ (void)addresses:", "+ (void)saveAddress:", "+ (void)cards:", "+ (void)saveCard:", "+ (void)deleteAutofillEntry:",
    ].map((signature) => declaration(services, signature));
    const production = [
      source("engine/chromium/src/chrome/browser/solara/public/ac_engine.h"),
      source("packages/solaracore/ios/SolaraCoreEngineBridge.h"),
      "typedef void (^SolaraCoreResult)(NSDictionary *);",
      "@interface SolaraCoreServices : NSObject",
      ...methods.map((method) => `${method.slice(0, method.indexOf("{")).trim()};`),
      "@end", bridge, helpers,
      "@implementation SolaraCoreServices", ...methods, "@end",
    ].join("\n");
    const program = `${directory}/test.mm`;
    const binary = `${directory}/test`;
    const harness = source("apps/browser/src/test-native/safe-host/EnginePersistence.mm");
    writeFileSync(`${directory}/SolaraCore-Swift.h`, source("apps/browser/src/test-native/safe-host/SolaraCore-Swift.h"));
    writeFileSync(program, harness.replace("__PRODUCTION__", production));
    const env = { ...process.env, TMPDIR: directory, CLANG_MODULE_CACHE_PATH: `${directory}/cache` };
    execFileSync("/usr/bin/clang++", ["-std=c++17", "-fobjc-arc", "-fblocks", "-Wno-nullability-completeness", "-framework", "Foundation", program, "-o", binary], { env, stdio: "pipe", timeout: 300000 });
    const safe = JSON.parse(execFileSync(binary, [directory, "safe", category], { env, encoding: "utf8", timeout: 10000 }));
    const normal = JSON.parse(execFileSync(binary, [directory, "normal", category], { env, encoding: "utf8", timeout: 10000 }));
    for (const run of [safe, normal]) {
      assert.equal(run.files.some((name) => name.startsWith("solara.sqlite")), false);
      for (const call of run.received) assert.equal(call.profile, `${directory}/Profile 1`);
      for (const reply of run.results) assert.equal(reply.error, undefined);
    }
    assert.equal(safe.safe, true);
    assert.equal(normal.safe, false);
    assert.deepEqual(normal.login, safe.login);
    assert.deepEqual(normal.web, safe.web);
    assert.deepEqual(normal.cookies, safe.cookies);
    assert.deepEqual(normal.bookmarks, safe.bookmarks);
    assert.deepEqual(normal.history, safe.history);
    return { safe, normal };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("safe-mode password add, edit and delete reach Login Data and survive a separate normal launch", () => {
  const { safe, normal } = persistence("passwords");
  assert.deepEqual(safe.received.map(({ name, args }) => ({ name, args })), [
    { name: "ac_passwords_add", args: { origin: "https://login.example", username: "before", passwordHex: "736563726574" } },
    { name: "ac_passwords_update", args: { origin: "https://login.example", username: "before", newUsername: "after", newPasswordHex: "656469746564" } },
    { name: "ac_passwords_add", args: { origin: "https://obsolete.example", username: "deleted", passwordHex: "676f6e65" } },
    { name: "ac_passwords_remove", args: { origin: "https://obsolete.example", username: "deleted" } },
  ]);
  assert.deepEqual(normal.results, [{ origin: "https://login.example", username: "after", password: "edited" }, {}, {}]);
  assert.deepEqual(normal.login, { "https://login.example|after": { origin: "https://login.example", username: "after", password: "edited" } });
});

test("safe-mode autofill edits and deletion reach Web Data and survive a separate normal launch", () => {
  const { safe, normal } = persistence("autofill");
  assert.deepEqual(safe.received.map(({ name, args }) => ({ name, args })), [
    { name: "ac_autofill_save_address", args: { address: { id: "home", name: "Safe edit", street: "42" } } },
    { name: "ac_autofill_save_address", args: { address: { id: "obsolete", name: "Delete me" } } },
    { name: "ac_autofill_remove", args: { id: "obsolete" } },
    { name: "ac_autofill_save_card", args: { card: { id: "card", name: "Safe card", expMonth: 12, expYear: 2030 }, numberHex: "34313131313131313131313131313131" } },
  ]);
  assert.deepEqual(normal.results, [
    { addresses: [{ id: "home", name: "Safe edit", street: "42", created: 0, modified: 0 }] },
    { cards: [{ id: "card", name: "Safe card", expMonth: 12, expYear: 2030, number: "4111111111111111", created: 0, modified: 0 }] },
  ]);
});

test("explicit safe-mode cookies and autofill imports persist to engine targets into a separate normal launch", () => {
  const { safe, normal } = persistence("import");
  const cookies = { cookies: [{ name: "fixture", value: "safe import", domain: ".example.test", path: "/" }] };
  const autofill = { addresses: [{ name: "Imported address", street: "42 Fixture Street" }], cards: [{ number: "4111111111111111", name: "Imported card" }] };
  assert.deepEqual(safe.received.map(({ name, args }) => ({ name, args })), [
    { name: "ac_cookies_import", args: cookies },
    { name: "ac_autofill_import", args: autofill },
  ]);
  assert.deepEqual(safe.results, [{ imported: 1, rejected: 0, existing: 0 }, { wiped: true }, { addresses: 1, cards: 1 }, { wiped: true }]);
  assert.deepEqual(normal.cookies, cookies);
  assert.deepEqual(normal.results, [
    { addresses: [{ ...autofill.addresses[0], created: 0, modified: 0 }] },
    { cards: [{ ...autofill.cards[0], created: 0, modified: 0 }] },
  ]);
});


test("safe-mode bookmark edits reach the engine Bookmarks boundary and survive a separate normal process", () => {
  const { safe, normal } = persistence("bookmarks");
  assert.deepEqual(safe.received.map(({ name, args }) => ({ name, args })), [{ name: "ac_bookmarks_apply", args: { ops: [
    { op: "add", id: "fixture-bookmark", k: "u", t: "Before", u: "https://before.example/", parent: "bar", a: 42 },
    { op: "update", id: "fixture-bookmark", t: "Safe edit", u: "https://edited.example/" },
    { op: "add", id: "removed-bookmark", k: "u", t: "Removed", u: "https://removed.example/", parent: "bar", a: 43 },
    { op: "remove", id: "removed-bookmark" },
  ] } }]);
  assert.deepEqual(normal.bookmarks, { "fixture-bookmark": { op: "update", id: "fixture-bookmark", k: "u", t: "Safe edit", u: "https://edited.example/", parent: "bar", a: 42 } });
});

test("safe-mode history deletion reaches the engine History boundary and survives a separate normal process", () => {
  const { safe, normal } = persistence("history");
  assert.deepEqual(safe.received.map(({ name, args }) => ({ name, args })), [
    { name: "ac_history_import", args: { rows: [{ u: "https://deleted.example/", t: "Deleted", n: 1, l: 42 }, { u: "https://kept.example/", t: "Kept", n: 1, l: 43 }] } },
    { name: "ac_history_delete_urls", args: { urls: ["https://deleted.example/"] } },
  ]);
  assert.deepEqual(normal.history, { "https://kept.example/": { u: "https://kept.example/", t: "Kept", n: 1, l: 43 } });
});
