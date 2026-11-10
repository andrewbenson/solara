import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, reset, onAndSynced, native, realReadPasswords } = await import('./harness.mjs');

const SITE = "https://secret-origin.example";

test("SEALED-fault: a write native refuses shows a fault naming only the key's type, never the origin, username or seal", fixedBy("sealed passwords"), async () => {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  const write = native.write;
  const warned = [];
  const realWarn = console.warn;
  console.warn = (...args) => warned.push(args.map((a) => (a instanceof Error ? `${a.message} ${a.stack}` : String(a))).join(" "));
  try {
    const engine = await onAndSynced();
    let refused = 0;
    let lastSeal = "";
    native.write = async (folder, scope, payload) => {
      const ops = JSON.parse(payload).ops ?? [];
      const sealed = ops.find((op) => op.k.startsWith("pw:"))?.v?.s;
      if (!sealed) return write(folder, scope, payload);
      refused++;
      lastSeal = sealed;
      const error = new Error(`Calling the 'write' function has failed\n→ Caused by: ${ops[0].k}: ${sealed}`);
      error.code = "ERR_SEALED_PASSWORDS";
      throw error;
    };
    here.set(`${SITE}\nsecret-user`, { origin: `${SITE}/`, url: `${SITE}/`, username: "secret-user", password: "secret-password", created: Date.now(), modified: Date.now() });
    await engine.syncNow();
    await settle(60);
    assert.ok(refused > 0, "control: the passwords write reached native and was refused");
    const shown = engine.useSync.getState();
    assert.equal(shown.status, "stalled", "the fault is shown in Settings");
    assert.match(shown.error ?? "", /pw:/, "it names the key's type");
    for (const text of [shown.error ?? "", ...warned]) {
      for (const secret of ["secret-origin", "secret-user", "secret-password", lastSeal]) assert.ok(!text.includes(secret), `"${secret}" stays out of "${text.slice(0, 120)}"`);
    }
  } finally {
    console.warn = realWarn;
    native.write = write;
    native.readPasswords = realReadPasswords;
  }
});
