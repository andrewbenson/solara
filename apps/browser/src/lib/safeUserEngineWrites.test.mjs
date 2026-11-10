import assert from "node:assert/strict";
import { test } from "node:test";
import { runNative, source } from "../test-native/safe-host/run.mjs";

const writes = [
  ["bookmarks", "ac_bookmarks_apply", { ops: [{ op: "update", id: "bookmark-id", t: "Edited in safe mode", u: "https://edited.example/" }] }],
  ["history deletion", "ac_history_delete_urls", { urls: ["https://deleted.example/"] }],
  ["password add", "ac_passwords_add", { origin: "https://login.example", username: "safe", passwordHex: "736563726574" }],
  ["password edit", "ac_passwords_update", { origin: "https://login.example", username: "safe", newUsername: "normal", newPasswordHex: "65646974" }],
  ["password delete", "ac_passwords_remove", { origin: "https://login.example", username: "normal" }],
  ["password exception", "ac_passwords_allow", { origin: "https://login.example" }],
  ["password export", "ac_passwords_export", { path: "/fixture/export.csv" }],
  ["autofill address", "ac_autofill_save_address", { address: { id: "address-id", name: "Safe edit", street: "42 Fixture St" } }],
  ["autofill card", "ac_autofill_save_card", { card: { id: "card-id", name: "Safe edit", expMonth: 12, expYear: 2030 }, numberHex: "34313131" }],
  ["autofill deletion", "ac_autofill_remove", { id: "address-id" }],
  ["explicit history import", "ac_history_import", { rows: [{ u: "https://imported.example/", t: "Imported", n: 2, l: 42 }] }],
  ["explicit visits import", "ac_history_add", { pages: [{ u: "https://imported.example/", t: "Imported", v: [42] }], toleranceMs: 0 }],
  ["explicit cookies import", "ac_cookies_import", { cookies: [{ name: "fixture", valueHex: "31", domain: ".example.test", path: "/" }] }],
  ["explicit autofill import", "ac_autofill_import", { addresses: [{ name: "Imported" }], cards: [] }],
];

function bridge(name, args) {
  const header = source("packages/solaracore/ios/SolaraCoreEngineBridge.h");
  const abi = source("engine/chromium/src/chrome/browser/solara/public/ac_engine.h");
  const implementation = source("packages/solaracore/ios/SolaraCoreEngineBridge.mm")
    .replace('#import "SolaraCoreEngineBridge.h"', "")
    .replace('#import "SolaraCoreBookmarkURL.h"', "static NSString *SolaraCanonicalBookmarkURL(NSString *url, NSError **error) { return nil; }")
    .replace('#import "SolaraCoreInternal.h"', "")
    .replace('#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"', "");
  return runNative("Engine.mm", `${abi}\n${header}\n${implementation}`, [name, JSON.stringify(args)]);
}

for (const [category, name, args] of writes) {
  test(`${category} reaches the engine store with unchanged arguments in safe and normal launches`, () => {
    const results = bridge(name, args);
    assert.equal(results.length, 4);
    for (const result of results) {
      assert.equal(result.callbacks, 1);
      assert.deepEqual(result.reply, { ok: true });
      assert.deepEqual(result.symbols, [name]);
      assert.equal(result.engineCalls, 1);
      assert.equal(result.profileCalls, 1);
      assert.deepEqual(result.received, [{ profile: "fixture-profile", args: JSON.stringify(args) }]);
      if (result.secret) assert.equal(result.wiped, true);
    }
  });
}

for (const name of ["ac_passwords_mark", "ac_favicons_set", "ac_tab_restore_tag", "ac_tab_restore_take", "ac_tab_restore_load", "ac_extensions_configure", "ac_extensions_install", "ac_extensions_install_crx", "ac_extensions_reload", "ac_extensions_set_enabled", "ac_extensions_sync_apply", "ac_extensions_sync_state", "ac_extensions_uninstall"]) {
  test(`${name} stays refused before dispatch in safe mode with a normal control`, () => {
    for (const result of bridge(name, { marker: 42 })) {
      assert.deepEqual(result.reply, result.safe ? { error: "disabled in safe mode" } : { ok: true });
      assert.equal(result.engineCalls, result.safe ? 0 : 1);
      assert.equal(result.profileCalls, result.safe ? 0 : 1);
      assert.equal(result.symbolCalls, result.safe ? 0 : 1);
      if (result.secret) assert.equal(result.wiped, true);
    }
  });
}
