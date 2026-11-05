import assert from "node:assert/strict";
import { test } from "node:test";
import { keepAwakeCover, normalizeSite, siteHost, sleepAfterMinutes } from "./keepAwakeSites.ts";

test("normalizes what people type the way the native sheet does", () => {
  assert.equal(normalizeSite("chat.example.com"), "chat.example.com");
  assert.equal(normalizeSite("  Example.COM  "), "example.com");
  assert.equal(normalizeSite("https://mail.example.com/inbox?x=1#top"), "mail.example.com");
  assert.equal(normalizeSite("http://user@example.com:8080/"), "example.com");
  assert.equal(normalizeSite(".example.com."), "example.com");
  assert.equal(normalizeSite("localhost"), "localhost");
  assert.equal(normalizeSite("[*.]example.com"), "example.com");
  assert.equal(normalizeSite("*.example.com"), "example.com");
  assert.equal(normalizeSite("intranet"), "intranet");
  assert.equal(normalizeSite("http://wiki:8080/page"), "wiki");
  assert.equal(normalizeSite("http://[::1]:8080/"), "[::1]");
  assert.equal(normalizeSite("::1"), "[::1]");
  assert.equal(normalizeSite("[FE80::1]"), "[fe80::1]");
  assert.equal(normalizeSite("192.168.1.10:3000"), "192.168.1.10");
  assert.equal(normalizeSite("e\u0301.example"), "\u00e9.example");
  for (const bad of ["", "   ", "not a site", "[::1", "[]", "[zz::1]", "a*b.com", "http://"]) assert.equal(normalizeSite(bad), null, bad);
});

test("an exact entry, a parent entry and a lookalike", () => {
  assert.deepEqual(keepAwakeCover(["chat.example.com", "example.com"], "chat.example.com"), { kind: "exact", site: "chat.example.com" });
  assert.deepEqual(keepAwakeCover(["example.com", "b.example.com"], "a.b.example.com"), { kind: "parent", site: "b.example.com" });
  assert.deepEqual(keepAwakeCover(["example.com"], "notexample.com"), { kind: "none" });
  assert.deepEqual(keepAwakeCover(["chat.example.com"], "example.com"), { kind: "none" });
  assert.deepEqual(keepAwakeCover(["example.com"], ""), { kind: "none" });
  assert.deepEqual(keepAwakeCover(["[::1]"], siteHost("http://[::1]:8080/")), { kind: "exact", site: "[::1]" });
});

test("hosts and the sleep delay", () => {
  assert.equal(siteHost("https://Chat.Example.com/x"), "chat.example.com");
  assert.equal(siteHost("not a url"), "");
  assert.equal(siteHost(undefined), "");
  assert.equal(sleepAfterMinutes(120), 120);
  assert.equal(sleepAfterMinutes(7), 30);
  assert.equal(sleepAfterMinutes(undefined), 30);
});
