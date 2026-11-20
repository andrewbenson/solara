import assert from "node:assert/strict";
import { test } from "node:test";
const { backAction, knownHistoryFor, reportsKnownHistory } = await import("./backAction.ts");
const { pageOf, patchPage } = await import("./pageState.ts");

const facts = (over = {}) => ({ newTabShown: false, canGoBack: false, engineBack: false, backToNewTab: false, historyKnown: true, opener: undefined, ...over });

test("a page with history goes back in the page, never to the opener", () => {
  assert.equal(backAction(facts({ canGoBack: true, opener: "a" })), "page");
  assert.equal(backAction(facts({ engineBack: true, opener: "a" })), "page");
  assert.equal(backAction(facts({ backToNewTab: true, opener: "a" })), "page");
});

test("a link tab whose history is known to be empty closes to its opener", () => {
  assert.equal(backAction(facts({ opener: "a" })), "opener");
});

test("a link tab whose page hasn't reported its history yet does nothing", () => {
  assert.equal(backAction(facts({ opener: "a", historyKnown: false })), "none");
});

test("no opener and no history does nothing, and a shown New Tab does nothing", () => {
  assert.equal(backAction(facts()), "none");
  assert.equal(backAction(facts({ newTabShown: true, canGoBack: true, opener: "a" })), "none");
});

test("only a report of a real committed page makes the history known", () => {
  assert.equal(reportsKnownHistory("about:blank", false), false, "the early blank report");
  assert.equal(reportsKnownHistory("", false), false, "the initial empty event");
  assert.equal(reportsKnownHistory("https://a.com/", true), false, "still loading");
  assert.equal(reportsKnownHistory("https://a.com/", false), true);
});

test("a tab without an opener selects nothing new when its page's history becomes known, so the swipe doesn't re-render", () => {
  const select = knownHistoryFor(undefined);
  const before = select(pageOf("no-opener"));
  patchPage("no-opener", { historyKnown: true });
  assert.equal(pageOf("no-opener").historyKnown, true);
  assert.equal(select(pageOf("no-opener")), before);
});

test("a link tab with an opener does see its history become known", () => {
  const select = knownHistoryFor("opener");
  assert.equal(select(pageOf("with-opener")), false);
  patchPage("with-opener", { historyKnown: true });
  assert.equal(select(pageOf("with-opener")), true);
});
