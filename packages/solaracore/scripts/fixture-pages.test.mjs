import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { acceptancePage, acceptancePathPage, activationPage, activationPathPage, adFirstPage, capturerPage, frameHostResponse, solidPage } from "./fixture-pages.mjs";

const origins = ["https://s.solara-sitedata.com", "https://embed.solara-thirdparty.com", "https://top.solara-elsewhere.com"];
const url = (path, params = {}) => new URL(`${path}?${new URLSearchParams(params)}`, "http://fixture.test");
const payload = `</title><img id="injected" src=x>&'`;
const escaped = "&lt;/title&gt;&lt;img id=&quot;injected&quot; src=x&gt;&amp;&#39;";
const title = (html) => html.match(/<title>(.*?)<\/title>/s)?.[1];

test("#131 activation title and pathname remain text", () => {
  assert.equal(title(activationPathPage(url("/made-1", { t: payload }))), escaped);
  const path = "/&quot;'";
  assert.ok(activationPathPage(url(path)).includes('<body style="font: 20px sans-serif">/&amp;quot;&#39;<script>'));
  assert.equal(title(activationPathPage(url(path))), "&amp;quot;&#39;");
});

test("#132 frame source stays one escaped attribute with its URL intact", () => {
  const src = `${origins[1]}/frame-probe?q=${encodeURIComponent(`\"<&'`)}&second=1`;
  const response = frameHostResponse(url("/frame-host", { src }), origins);
  assert.equal(response.status, 200);
  assert.ok(response.html.includes(`src="${src.replaceAll("&", "&amp;").replaceAll("'", "&#39;")}"`));
  const quote = `${origins[1]}/frame-probe?q=\"'&x=1`;
  const quoted = frameHostResponse(url("/frame-host", { src: quote }), origins);
  assert.equal(quoted.status, 200);
  assert.ok(quoted.html.includes('q=&quot;&#39;&amp;x=1"'));
  assert.equal((quoted.html.match(/<iframe /g) ?? []).length, 1);
});

test("#132 rejects sources outside the fixture origins", () => {
  for (const src of ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "https://evil.test/frame-probe", `${origins[1]}:444/frame-probe`, "http://embed.solara-thirdparty.com/frame-probe", "https://user:pass@embed.solara-thirdparty.com/frame-probe", "//embed.solara-thirdparty.com/frame-probe", "not a URL", ""]) {
    const response = frameHostResponse(url("/frame-host", { src }), origins);
    assert.equal(response.status, 400, src);
    assert.equal(response.html.includes("<iframe"), false, src);
  }
  assert.equal(frameHostResponse(url("/frame-host"), origins).status, 400);
});

test("#133 solid title remains text", () => {
  assert.equal(title(solidPage(url("/solid", { t: payload, c: "ff0000" }))), escaped);
});

test("#134 solid accepts only six hexadecimal CSS color digits", () => {
  for (const c of ["</style><img id=injected>", "red", "fff", "000000; color: red", "1234567", "", "#ff0000", "000000\n"]) {
    const html = solidPage(url("/solid", { c }));
    assert.ok(html.includes("background: #808080 }"), c);
    assert.equal(html.includes("<img"), false, c);
  }
  assert.ok(solidPage(url("/solid", { c: "aBcD09" })).includes("background: #aBcD09 }"));
});

test("#135 capturer title remains text", () => {
  assert.equal(title(capturerPage(url("/capturer", { t: payload }))), escaped);
});

test("acceptance fallback pathname remains title and body text", () => {
  assert.equal(acceptancePathPage("/&quot;'<>"), '<!doctype html><html><head><title>/&amp;quot;&#39;&lt;&gt;</title><link rel="icon" href="/icon.png"></head><body>/&amp;quot;&#39;&lt;&gt;</body></html>');
});

test("ad query URLs encode query values and escape attribute separators", () => {
  const params = { tag: `\"'><img id=injected>&`, next: "a b" };
  const html = adFirstPage(url("/adfirst", params));
  const query = new URLSearchParams(params).toString().replaceAll("&", "&amp;");
  assert.ok(html.includes(`adsbygoogle.js?${query}"`));
  assert.equal(html.includes("<img id=injected>"), false);
});

test("page helpers preserve intentionally authored body and extra markup", () => {
  assert.equal(acceptancePage("Page A", '<a id="next" href="/b">to B</a>', "<style>body { margin: 0 }</style>"), '<!doctype html><html><head><title>Page A</title><link rel="icon" href="/icon.png"><style>body { margin: 0 }</style></head><body><a id="next" href="/b">to B</a></body></html>');
  assert.equal(activationPage("Ask", "ask", "window.ask = () => true;"), '<!doctype html><html><head><title>Ask</title><link rel="icon" href="data:,"></head><body style="font: 20px sans-serif">ask<script>window.ask = () => true;</script></body></html>');
});

test("actual fixture inputs preserve the original HTML bytes", () => {
  const cases = [
    ["solidPage", "/solid", "020908ee889bb54187f5ed03d8b0fc45065ba72303ebcf420939fe05f99233f7"],
    ["solidPage", "/solid?c=ff0000&t=Red", "b41d0c6b9aad1a6bdc7d921e996ad736b5f6b2a99668ba57f285498ed1de1ead"],
    ["solidPage", "/solid?c=00ff00&t=Green", "4567096f65b0bbbc9a97c6ba1cd94ff74ca011559a4a92f0d124c108ccf8031c"],
    ["solidPage", "/solid?c=0000ff&t=Blue", "e3fe3fe1607fee01894565cf431798aa89dec1405d9101689f8ca7135f7f6fde"],
    ["capturerPage", "/capturer", "0ac5dc470de0714b2c6d4e1038be1fe98afab7432552f5621ef7e13172c870e3"],
    ["capturerPage", "/capturer?t=CallA", "7d058e197b7ecb8c3b5c7dee5814be5ae7643ca1cc0560ac0308cfaccb60e91c"],
    ["capturerPage", "/capturer?t=CallB", "cba279efa8e5d3c14eb4bfc55e48a2096eec4271218db9dadda12b58190576c0"],
    ["adFirstPage", "/adfirst?first-personal-123456", "caf09b91455039a9974b8f508677056a1438bc80c47205408c24cbdf29adfeb9"],
    ["adFirstPage", "/adfirst?private-first-123456", "24da120361e1845eebdfba3ab4b96828349f22e69220ceb50c9e5cf07ed12f22"],
    ["frameHostResponse", "/frame-host?src=https%3A%2F%2Fembed.solara-thirdparty.com%2Fframe-probe%3Fset", "e6b48f3265c02e69e53e05ac315b2b0685c5322052a2914da63c87e683f5ab3c"],
    ["frameHostResponse", "/frame-host?src=https%3A%2F%2Fs.solara-sitedata.com%2Fframe-probe%3Fset", "4c8b0aa9d58b53d36de77c0f3764bb8ed08df3e3cfec970b1428bce4a607649e"],
    ["frameHostResponse", "/frame-host?src=https%3A%2F%2Fembed.solara-thirdparty.com%2Fframe-probe", "7e49f4f1849f47a860e57f3c2f7aef847270e862ade8284a0b55f051e5e81dbc"],
    ["frameHostResponse", "/frame-host?src=https%3A%2F%2Fs.solara-sitedata.com%2Fframe-probe", "b83f69a892c0a9350b0fa05bfb9f54f8f713935780c78915c58c33d6d9dea0dd"],
  ];
  for (const [name, path, hash] of cases) {
    const result = { solidPage, capturerPage, adFirstPage, frameHostResponse }[name](new URL(path, "https://fixture.test"), origins);
    const html = typeof result === "string" ? result : result.html;
    assert.equal(createHash("sha256").update(html).digest("hex"), hash, path);
  }
  assert.equal(activationPathPage(new URL("/made-1?t=Made", "https://fixture.test")), '<!doctype html><html><head><title>Made</title><link rel="icon" href="data:,"></head><body style="font: 20px sans-serif">/made-1<script></script></body></html>');
  assert.equal(acceptancePathPage("/unknown"), '<!doctype html><html><head><title>/unknown</title><link rel="icon" href="/icon.png"></head><body>/unknown</body></html>');
});
