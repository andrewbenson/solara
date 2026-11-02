import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, afterEach, test } from "node:test";
import { emitPermission, shellNativeModules, solaraCoreNativeModules } from "../../test-native/index.ts";
import { pageOf, setBrowserId } from "../layout/pageState.ts";
const permissionsURL = new URL("./permissions.ts", import.meta.url).href;
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === permissionsURL && specifier === "./DeviceChooser") {
      return { url: "data:text/javascript,export const startDeviceChoosers = () => {};", shortCircuit: true };
    }
    return next(specifier, context);
  },
});
const permissions = await import("./permissions.ts");
after(() => hooks.deregister());

permissions.startPermissionPrompts();
const app = shellNativeModules.SolaraApp;
const cef = solaraCoreNativeModules.SolaraCEF;
const originalRequest = app.requestNotificationPermission;
const originalResolve = cef.resolvePermission;
const tabs = new Set();
let browserId = 700;

function enqueue(tabId, ...kinds) {
  tabs.add(tabId);
  const browser = ++browserId;
  setBrowserId(tabId, browser);
  return kinds.map((permissions, index) => {
    const request = { id: `${tabId}-${index}`, browserId: browser, origin: "https://notify.example", permissions };
    emitPermission(request);
    return request;
  });
}

afterEach(() => {
  for (const tabId of tabs) permissions.dismissPermissions(tabId);
  tabs.clear();
  app.requestNotificationPermission = originalRequest;
  cef.resolvePermission = originalResolve;
  globalThis.__DEV__ = false;
});

test("dev Allow waits for OS authorization and resolves a queued notification with the click decision", async () => {
  globalThis.__DEV__ = true;
  const calls = [];
  let grant;
  app.requestNotificationPermission = () => {
    calls.push(["authorization"]);
    return new Promise((resolve) => { grant = resolve; });
  };
  cef.resolvePermission = async (...args) => { calls.push(args); };
  const [first, notification, last] = enqueue("allow", ["camera"], ["notifications"], ["microphone"]);
  await permissions.answerPermission("allow", first.id, "deny");
  assert.equal(pageOf("allow").permission, notification);
  calls.length = 0;
  const answered = permissions.devAnswerPermission("allow", "allow");
  await Promise.resolve();
  assert.deepEqual(calls, [["authorization"]]);
  assert.equal(pageOf("allow").permission, notification);
  grant(true);
  assert.equal(await answered, true);
  assert.deepEqual(calls, [["authorization"], [notification.id, "accept", true]]);
  assert.equal(pageOf("allow").permission, last);
});

test("dev Deny stores the click decision without requesting OS authorization", async () => {
  globalThis.__DEV__ = true;
  const calls = [];
  app.requestNotificationPermission = async () => { calls.push(["authorization"]); return true; };
  cef.resolvePermission = async (...args) => { calls.push(args); };
  const [notification] = enqueue("deny", ["notifications"]);
  assert.equal(await permissions.devAnswerPermission("deny", "deny"), true);
  assert.deepEqual(calls, [[notification.id, "deny", true]]);
  assert.equal(pageOf("deny").permission, null);
});

test("dev Allow dismisses without remembering when OS authorization is refused", async () => {
  globalThis.__DEV__ = true;
  const calls = [];
  app.requestNotificationPermission = async () => false;
  cef.resolvePermission = async (...args) => { calls.push(args); };
  const [notification] = enqueue("refused", ["notifications"]);
  assert.equal(await permissions.devAnswerPermission("refused", "allow"), true);
  assert.deepEqual(calls, [[notification.id, "dismiss", false]]);
  assert.equal(pageOf("refused").permission, null);
});

test("dev answers with no pending prompt make no native calls", async () => {
  globalThis.__DEV__ = true;
  const calls = [];
  app.requestNotificationPermission = async () => { calls.push(["authorization"]); return true; };
  cef.resolvePermission = async (...args) => { calls.push(args); };
  assert.equal(await permissions.devAnswerPermission("missing", "allow"), false);
  assert.deepEqual(calls, []);
});

test("dev answers are disabled outside development", async () => {
  globalThis.__DEV__ = false;
  const calls = [];
  app.requestNotificationPermission = async () => { calls.push(["authorization"]); return true; };
  cef.resolvePermission = async (...args) => { calls.push(args); };
  const [notification] = enqueue("production", ["notifications"]);
  assert.equal(await permissions.devAnswerPermission("production", "allow"), false);
  assert.deepEqual(calls, []);
  assert.equal(pageOf("production").permission, notification);
});
