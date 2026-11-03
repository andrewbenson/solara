import assert from "node:assert/strict";
import test from "node:test";
import { pageExtensionButtons, pageExtensionsWidth, WEBKIT_PILL_ACTION, WEBKIT_PILL_WIDTH } from "./webkitPill.ts";

const pinned = [{ id: "ext-cast", icon: "tv" }, { id: "ext:abc", icon: "" }];

test("a WebKit page swaps every toolbar extension, cast included, for the WebKit pill", () => {
  const [pill, ...rest] = pageExtensionButtons("webkit", pinned);
  assert.equal(rest.length, 0);
  assert.equal(pill.id, "webkit");
  assert.equal(pill.label, "WebKit");
  assert.equal(pill.icon, "safari");
  assert.equal(pill.info.title, "This page is open in WebKit");
  assert.match(pill.info.message, /^Extensions, the ad blocker, password autofill and casting don't run here\.$/);
  assert.equal(pill.info.action, "Open Page in Chromium");
  assert.equal(pill.info.actionId, WEBKIT_PILL_ACTION);
  assert.equal(pageExtensionsWidth("webkit", 0), WEBKIT_PILL_WIDTH);
});

test("a Chromium page keeps its extensions and their width", () => {
  assert.equal(pageExtensionButtons("chromium", pinned), pinned);
  assert.equal(pageExtensionsWidth("chromium", 64), 64);
});
