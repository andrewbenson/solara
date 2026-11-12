import assert from "node:assert/strict";
import { test } from "node:test";
import { registerHooks } from "node:module";
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "../components/littleSolara/actions" && context.parentURL?.endsWith("/lib/windowClose.ts")) return { url: "data:text/javascript,export const closeLittleSolara = () => {}", shortCircuit: true };
    return next(specifier, context);
  },
});
const { useBrowser } = await import("./browser.ts");
const { shellNativeModules } = await import("../test-native/shell.ts");
const { requestClose } = await import("../lib/windowClose.ts");
const S = () => useBrowser.getState();
const shell = shellNativeModules.SolaraShell;

test("retained close skips confirmation, animation and destructive store close", async () => {
  S().hydrate({});
  const id = S().createWindow({ url: "https://a.example/" });
  S().newTab(id, { url: "https://b.example/" });
  S().updateSettings({ warnBeforeClosingWindow: true });
  const before = S();
  const original = { retain: shell.retainLastWindow, confirm: shell.confirm, animate: shell.animateWindowClose };
  const effects = [];
  shell.retainLastWindow = async (candidate) => { effects.push(["retain", candidate]); return true; };
  shell.confirm = async () => { throw new Error("retained close must not confirm"); };
  shell.animateWindowClose = async () => { throw new Error("retained close must not animate destruction"); };
  try {
    await requestClose(id);
    assert.deepEqual(effects, [["retain", id]]);
    assert.equal(S(), before);
  } finally {
    shell.retainLastWindow = original.retain;
    shell.confirm = original.confirm;
    shell.animateWindowClose = original.animate;
  }
});

test("ordinary and private close still respect confirmation cancellation", async () => {
  for (const incognito of [false, true]) {
    S().hydrate({});
    S().createWindow();
    const id = S().createWindow({ url: "https://a.example/", incognito });
    S().newTab(id, { url: "https://b.example/" });
    S().updateSettings({ warnBeforeClosingWindow: true });
    const original = shell.confirm;
    let asked = 0;
    shell.confirm = async () => { asked++; return { confirmed: false, suppressed: false }; };
    try {
      await requestClose(id);
      assert.equal(asked, 1);
      assert.ok(S().windows[id]);
    } finally { shell.confirm = original; }
  }
});

test("a tab arriving during close cancels the native close reservation", async () => {
  S().hydrate({});
  const id = S().createWindow({ url: "https://a.example/" });
  S().updateSettings({ warnBeforeClosingWindow: false });
  const original = { retain: shell.retainLastWindow, animate: shell.animateWindowClose, focus: shell.focusWindow };
  const nativeClosing = new Set();
  let finish;
  shell.retainLastWindow = async (candidate, committingClose) => {
    if (committingClose) nativeClosing.add(candidate);
    return false;
  };
  shell.animateWindowClose = () => new Promise((resolve) => { finish = resolve; });
  shell.focusWindow = async (candidate, cancellingClose) => { if (cancellingClose) nativeClosing.delete(candidate); };
  try {
    await requestClose(id);
    assert.equal(nativeClosing.has(id), true);
    const added = S().newTab(id, { url: "https://arriving.example/" });
    finish();
    await new Promise((resolve) => setImmediate(resolve));
    assert.ok(S().windows[id]);
    assert.ok(S().tabs[added]);
    assert.equal(nativeClosing.has(id), false);
  } finally {
    shell.retainLastWindow = original.retain;
    shell.animateWindowClose = original.animate;
    shell.focusWindow = original.focus;
  }
});
