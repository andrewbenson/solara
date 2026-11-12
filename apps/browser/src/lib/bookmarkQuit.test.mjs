import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = readFileSync(new URL("./native.ts", import.meta.url), "utf8");
const wiring = source.slice(source.indexOf("  onAppEvent(("), source.indexOf("\n  const windows ="));
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const turn = () => new Promise((resolve) => setImmediate(resolve));
function fixture() {
  let listener;
  let barrier = deferred();
  const events = [];
  const state = {};
  const setup = new Function("onAppEvent", "store", "nativeOwnsWorkspace", "createWindow", "finishAnimatedCloses", "flushPersistence", "replyToTerminate", "resumePersistence", "flushBookmarkJournal", "cancelBookmarkQuit", `let quitting = false; let quitAttempt = 0; ${wiring}; return () => quitting;`);
  const isQuitting = setup((next) => { listener = next; }, { getState: () => state }, () => true, () => {}, () => events.push("closes"), () => events.push("workspace"), async (allow) => { events.push(allow); }, () => events.push("resume"), () => { events.push("bookmark"); return barrier.promise; }, () => events.push("cancel"));
  return { events, isQuitting, emit: (type) => listener({ type }), barrier: () => barrier, next: () => { barrier = deferred(); return barrier; } };
}

test("quit approval waits for the durable bookmark barrier and coalesces duplicate requests", async () => {
  const f = fixture();
  f.emit("willQuit");
  f.emit("willQuit");
  await turn();
  assert.equal(f.isQuitting(), true);
  assert.deepEqual(f.events, ["closes", "workspace", "bookmark"]);
  f.barrier().resolve(true);
  await turn();
  assert.deepEqual(f.events, ["closes", "workspace", "bookmark", true]);
});

for (const failure of ["refused", "rejected"]) {
  test(`a ${failure} bookmark flush cancels quit and reopens persistence`, async () => {
    const f = fixture();
    f.emit("willQuit");
    if (failure === "refused") f.barrier().resolve(false);
    else f.barrier().reject(new Error("disk full"));
    await turn();
    assert.equal(f.isQuitting(), false);
    assert.deepEqual(f.events.slice(-3), ["cancel", "resume", false]);
  });
}

test("quit cancellation invalidates an outstanding barrier before a later quit", async () => {
  const f = fixture();
  f.emit("willQuit");
  const previous = f.barrier();
  f.emit("quitCancelled");
  const next = f.next();
  f.emit("willQuit");
  previous.resolve(true);
  await turn();
  assert.equal(f.events.includes(true), false);
  next.resolve(true);
  await turn();
  assert.equal(f.events.filter((event) => event === true).length, 1);
  assert.equal(f.events.filter((event) => event === "cancel").length, 1);
});
