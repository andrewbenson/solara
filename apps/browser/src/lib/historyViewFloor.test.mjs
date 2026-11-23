import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const { useBrowser } = await import("../store/browser.ts");
const { MAX_HISTORY } = await import("../store/history.ts");
const { reloadHistory, startHistory } = await import("./history.ts");
const { installAfterFirstWindowScheduler } = await import("./afterFirstWindow.ts");
installAfterFirstWindowScheduler((task) => {
  queueMicrotask(task);
  return () => {};
});
const stub = await import("../test-native/index.ts");

const S = () => useBrowser.getState();
const tick = () => new Promise((r) => setTimeout(r, 0));

const unprotected = () => {
  const shown = new Set((S().history.default ?? []).map((h) => h.url));
  const floor = S().historyFloor.default ?? -Infinity;
  const chrome = [...stub.chromeHistory("")].map(([url, row]) => ({ url, visits: row.visits }));
  return chrome.filter((row) => !shown.has(row.url) && Math.max(...row.visits) > floor).map((row) => row.url);
};

test("a batch that caps the view and then deletes from it still raises the floor over the URL it pushed out", async () => {
  S().hydrate({});
  stub.docs.clear();
  stub.historyDbs.clear();
  const t0 = Date.now() - 30 * 86_400_000;
  for (let i = 0; i < MAX_HISTORY - 1; i++) stub.chromeVisit("", `https://old${i}.example/`, "", t0 + i * 1000);
  const stop = startHistory();
  await reloadHistory();
  assert.equal(S().history.default.length, MAX_HISTORY - 1);
  assert.deepEqual(unprotected(), []);
  stub.chromeVisit("", "https://new1.example/", "", t0 + 10_000_000);
  stub.chromeVisit("", "https://new2.example/", "", t0 + 10_000_001);
  stub.chromeHistoryEvent({ kind: "deleted", profile: "", all: false, urls: ["https://new1.example/"] });
  stub.chromeHistory("").delete("https://new1.example/");
  await tick();
  assert.equal(S().history.default.length, MAX_HISTORY - 1, "the view ends one short of the cap");
  assert.deepEqual(unprotected(), [], "every URL Chrome has that the view doesn't is at or below the floor");
  stop();
});
