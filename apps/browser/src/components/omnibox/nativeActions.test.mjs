import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";

globalThis.__DEV__ = true;
const { omniboxActionDriver, runOmniboxFallback } = await import("./nativeActions.ts");

beforeEach(() => {
  omniboxActionDriver.disableJS(false);
  omniboxActionDriver.reset();
});

test("owned native actions never execute a JavaScript fallback", () => {
  for (const name of ["open", "switch", "action", "done", "cancel", "contextMenu", "openChip", "extension"]) {
    runOmniboxFallback(name, { nativeActions: true }, () => assert.fail(name));
  }
  assert.deepEqual(omniboxActionDriver.state(), { disabled: false, received: {}, executed: {} });
});

test("unowned actions retain the JavaScript fallback", () => {
  let opened = "";
  runOmniboxFallback("open", { nativeActions: false }, () => { opened = "fallback"; });
  assert.equal(opened, "fallback");
  assert.deepEqual(omniboxActionDriver.state(), { disabled: false, received: { open: 1 }, executed: { open: 1 } });
});

test("disabled JavaScript handlers expose leaked actions without executing them", () => {
  omniboxActionDriver.disableJS(true);
  runOmniboxFallback("switch", undefined, () => assert.fail("disabled fallback executed"));
  assert.deepEqual(omniboxActionDriver.state(), { disabled: true, received: { switch: 1 }, executed: {} });
  omniboxActionDriver.disableJS(false);
  let switched = false;
  runOmniboxFallback("switch", {}, () => { switched = true; });
  assert.equal(switched, true);
});
