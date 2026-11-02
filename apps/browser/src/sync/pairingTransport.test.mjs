import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const methods = ["addListener", "invalidatePairing", "consumePairingInstallation", "savePairingInstallation", "readPairingInstallation", "recoverPairingInstallation", "stopPairingInstallation", "reconcilePairingApplied", "checkpointPairingApplied", "acknowledgePairingInitialization", "acknowledgePairingReady", "pairingInstallationRequest"];
const installation = () => ({ transaction: "a".repeat(64), folder: "/sync", folderIdentity: "volume:inode", cid: "b".repeat(32), deviceId: "baaaaaaaaaaaaaaaaaaaaaaaaa", account: "baaaaaaaaaaaaaaaaaaaaaaaaa", generation: 1, stopGeneration: 0, phase: "prepared", route: "settings", priorState: "0:ztntfp" });
const request = () => ({ handle: "opaque-handle", folder: "/sync", folderIdentity: "volume:inode", cid: "b".repeat(32), generation: 1, stopGeneration: 0 });
let output = installation();
let failure = null;
let called = 0;
const native = Object.fromEntries(methods.map((name) => [name, async () => { called++; if (failure) throw failure; return output; }]));
globalThis.acTestNativeModules = { SolaraSyncAdapter: native };
const exported = await import("../../../../packages/sync/src/native.ts");
const transport = () => exported.pairingNativeTransport?.(native);

test("pairing transport requires the complete optional capability without exposing native approval authority", () => {
  const host = transport();
  assert.ok(host, "optional native pairing capability supplies a nonsecret host");
  assert.equal("armTrusted" in host, false);
  assert.equal("allow" in host, false);
});

for (const missing of methods) {
  test(`pairing transport refuses a capability without ${missing}`, () => {
    assert.equal(exported.pairingNativeTransport({ ...native, [missing]: undefined }), null);
  });
}

for (const [field, value] of [["transaction", "not-a-transaction"], ["cid", "B".repeat(32)], ["account", "other"], ["generation", Number.MAX_SAFE_INTEGER + 1], ["stopGeneration", -1], ["phase", "admitted"], ["route", "arbitrary"], ["folder", ""], ["folderIdentity", ""], ["priorState", ""], ["E", "fixture-secret"], ["nested", { SAS: "ABC DEF" }]]) {
  test(`pairing transport rejects installation DTO mutation ${field}`, async () => {
    const host = transport();
    assert.ok(host);
    failure = null;
    output = { ...installation(), [field]: value };
    await assert.rejects(host.consumeInstallation("opaque-handle", "0:ztntfp"), /^Error: Pairing is unavailable\.$/);
    const before = called;
    await assert.rejects(host.saveInstallation(output), /^Error: Pairing is unavailable\.$/);
    assert.equal(called, before, "mutated inputs cannot reach native");
  });
}

test("pairing failures serialize a fixed reason with no raw or nested native error payload", async () => {
  const host = transport();
  assert.ok(host);
  const secret = "Païring Mac <ABC DEF> fixture-root";
  failure = Object.assign(new Error(secret), { userInfo: { root: secret, encoded: Buffer.from(secret).toString("base64") }, cause: secret });
  await assert.rejects(host.consumeInstallation("opaque-handle", "0:ztntfp"), (error) => {
    const captured = JSON.stringify({ message: error.message, ...error });
    assert.equal(captured, '{"message":"Pairing is unavailable."}');
    assert.deepEqual(Object.keys(error), []);
    const forms = [secret, JSON.stringify(secret).slice(1, -1), Buffer.from(secret).toString("hex"), Buffer.from(secret).toString("base64"), secret.normalize("NFD"), secret.normalize("NFKC"), "ABC DEF", "ABCDEF"];
    for (const form of forms) assert.equal(captured.includes(form), false, "no secret representation reaches a failure sink");
    return true;
  });
  failure = null;
});

test("pairing transport copies DTOs and refuses nonallowlisted request fields", async () => {
  const host = transport();
  assert.ok(host);
  output = installation();
  const consumed = await host.consumeInstallation("opaque-handle", "0:ztntfp");
  output.folder = "/changed";
  assert.equal(consumed.folder, "/sync");
  output = request();
  assert.deepEqual(await host.installationRequest(), request());
  output = { ...request(), code: "ABC DEF" };
  await assert.rejects(host.installationRequest(), /^Error: Pairing is unavailable\.$/);
});

const operation = () => ({ operationId: `${"a".repeat(64)}:1:prof:r:1`, transaction: "a".repeat(64), generation: 1, key: "prof:r", desired: { n: "Profile", c: "blue", i: null }, before: null, localValue: { n: "Profile", c: "blue", i: null }, disposition: "applied" });

test("pairing receipt returns only the durable outcome fields and copies nested values", async () => {
  const host = transport();
  assert.ok(host);
  const op = operation();
  output = { operationId: op.operationId, transaction: op.transaction, generation: op.generation, key: op.key, disposition: op.disposition, value: op.localValue };
  let receipt;
  await assert.doesNotReject(async () => { receipt = await host.checkpointApplied(op); });
  output.value.n = "Changed after delivery";
  assert.equal(receipt.value.n, "Profile");
  assert.deepEqual(Object.keys(receipt).sort(), ["operationId", "transaction", "generation", "key", "disposition", "value"].sort());
});

for (const value of [{ salt: "private-salt" }, { nested: [{ E: "root" }] }, { code: "ABC DEF" }, { claimedName: "Pairing Mac" }, { privateKey: "key" }]) {
  test(`pairing operation refuses recursive secret sink ${JSON.stringify(Object.keys(value))}`, async () => {
    const host = transport();
    assert.ok(host);
    const before = called;
    await assert.rejects(host.checkpointApplied({ ...operation(), localValue: value }), /^Error: Pairing is unavailable\.$/);
    assert.equal(called, before);
  });
}
