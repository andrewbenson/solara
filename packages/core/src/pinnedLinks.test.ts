import assert from "node:assert/strict";
import { test } from "node:test";
import { registrableDomain, resolvePinnedLink, unwrapLinkRedirects } from "./pinnedLinks.ts";
import type { PinnedLinkInput } from "./pinnedLinks.ts";

const destination = "https://example.org/article?part=1#heading";
const google = (target: string) => `https://www.google.com/url?q=${encodeURIComponent(target)}`;
const input: PinnedLinkInput = {
  sourceUrl: "https://mail.google.com/mail/u/0/",
  targetUrl: destination,
  pinned: true,
  topApp: false,
  isMainFrame: true,
  userGesture: true,
  navigationType: "link",
  method: "GET",
  download: false,
  hasOpener: false,
  disposition: "current",
  modified: false,
};

test("registrable domains use ICANN, private, wildcard and exception PSL rules", () => {
  for (const [url, expected] of [
    ["https://mail.google.com/a", "google.com"],
    ["https://a.b.example.co.uk/", "example.co.uk"],
    ["https://co.uk/", null],
    ["https://com/", null],
    ["http://intranet/", "intranet"],
    ["https://one.github.io/", "one.github.io"],
    ["https://two.github.io/", "two.github.io"],
    ["https://a.b.ck/", "a.b.ck"],
    ["https://b.ck/", null],
    ["https://x.www.ck/", "www.ck"],
    ["https://x.city.kawasaki.jp/", "city.kawasaki.jp"],
    ["https://食狮.公司.cn/", "xn--85x722f.xn--55qx5d.cn"],
    ["https://Example.COM./", "example.com"],
    ["http://localhost:9000/", "localhost"],
    ["http://one.localhost:9000/", "one.localhost"],
    ["http://192.168.0.1:9000/", "192.168.0.1"],
    ["http://[::1]:9000/", "[::1]"],
    ["file:///tmp/test", null],
    ["broken", null],
  ] as const) assert.equal(registrableDomain(url), expected, url);
});

test("known redirect wrappers unwrap without changing destination content", () => {
  for (const url of [
    `https://google.com/url?q=${encodeURIComponent(destination)}`,
    google(destination),
    `https://www.google.com/url?url=${encodeURIComponent(destination)}`,
    `https://slack-redir.net/link?url=${encodeURIComponent(destination)}`,
    `https://nam01.safelinks.protection.outlook.com/?url=${encodeURIComponent(destination)}&data=opaque`,
    `https://l.facebook.com/l.php?u=${encodeURIComponent(destination)}`,
    `https://www.facebook.com/l.php?u=${encodeURIComponent(destination)}`,
    `https://www.linkedin.com/redir/redirect?url=${encodeURIComponent(destination)}`,
    `https://www.linkedin.com/safety/go?url=${encodeURIComponent(destination)}`,
  ]) assert.equal(unwrapLinkRedirects(url), destination, url);
});

test("nested redirect wrappers unwrap before comparing sites, and the wrapper itself is what opens", () => {
  const nested = google(`https://slack-redir.net/link?url=${encodeURIComponent(destination)}`);
  assert.equal(unwrapLinkRedirects(nested), destination);
  assert.deepEqual(resolvePinnedLink({ ...input, targetUrl: nested }), { target: "peek", url: nested });
  assert.equal(resolvePinnedLink({ ...input, targetUrl: google("https://docs.google.com/document") }), null);
});

test("malformed, missing, ambiguous and non-http wrapper targets are refused", () => {
  for (const target of ["javascript:alert(1)", "data:text/html,hello", "file:///tmp/a", "//example.org/a", "", "%", "https://", "https://example.org/%ZZ", "https://x.org/\nscript", "https://user:pass@example.org/"]) {
    assert.equal(unwrapLinkRedirects(google(target)), null, target);
    assert.equal(resolvePinnedLink({ ...input, targetUrl: google(target) }), null, target);
  }
  assert.equal(unwrapLinkRedirects("https://www.google.com/url"), null);
  assert.equal(unwrapLinkRedirects("https://www.google.com/url?q=%E0%A4%A"), null);
  assert.equal(unwrapLinkRedirects("https://slack-redir.net/link?url=https%3A%2F%2Fa.org&url=https%3A%2F%2Fb.org"), null);
  assert.equal(unwrapLinkRedirects(google(google("javascript:alert(1)"))), null);
  for (const target of ["javascript:alert(1)", "data:text/html,hello", "about:blank"]) assert.equal(unwrapLinkRedirects(target), null);
});

test("lookalike wrapper hosts and paths are not unwrapped", () => {
  for (const url of [
    `https://google.com.evil.example/url?q=${encodeURIComponent(destination)}`,
    `https://www.google.com/search?q=${encodeURIComponent(destination)}`,
    `https://slack-redir.net.evil.example/link?url=${encodeURIComponent(destination)}`,
    `https://safelinks.protection.outlook.com.evil.example/?url=${encodeURIComponent(destination)}`,
    `https://notfacebook.com/l.php?u=${encodeURIComponent(destination)}`,
    `https://www.linkedin.com/other?url=${encodeURIComponent(destination)}`,
  ]) assert.equal(unwrapLinkRedirects(url), url, url);
});

test("redirect nesting has a finite fail-closed limit", () => {
  let url = destination;
  for (let i = 0; i < 12; i++) url = google(url);
  assert.equal(unwrapLinkRedirects(url), null);
});

test("pinned tabs and Top Apps route to the selected target with Peek as default", () => {
  assert.deepEqual(resolvePinnedLink(input), { target: "peek", url: destination });
  assert.deepEqual(resolvePinnedLink({ ...input, target: "invalid" as PinnedLinkInput["target"] }), { target: "peek", url: destination });
  for (const target of ["peek", "tab", "littleSolara"] as const) {
    assert.deepEqual(resolvePinnedLink({ ...input, target }), { target, url: destination });
    assert.deepEqual(resolvePinnedLink({ ...input, pinned: false, topApp: true, target }), { target, url: destination });
    assert.deepEqual(resolvePinnedLink({ ...input, disposition: "newTab", hasOpener: true, target }), { target, url: destination });
  }
});

test("same site ignores scheme, port and subdomain but separates private tenants", () => {
  assert.equal(resolvePinnedLink({ ...input, sourceUrl: "http://a.example.co.uk:8000/", targetUrl: "https://b.example.co.uk:9443/path" }), null);
  assert.deepEqual(resolvePinnedLink({ ...input, sourceUrl: "https://a.github.io/", targetUrl: "https://b.github.io/" }), { target: "peek", url: "https://b.github.io/" });
  assert.equal(resolvePinnedLink({ ...input, sourceUrl: "http://localhost:8000", targetUrl: "http://localhost:9000" }), null);
  assert.deepEqual(resolvePinnedLink({ ...input, sourceUrl: "http://192.168.0.1/", targetUrl: "http://192.168.0.2/" }), { target: "peek", url: "http://192.168.0.2/" });
});

test("forms, POST, redirects, scripts, popups, downloads and explicit modifiers keep normal behavior", () => {
  const exemptions: Partial<PinnedLinkInput>[] = [
    { pinned: false },
    { isMainFrame: false },
    { userGesture: false },
    { navigationType: "form" },
    { method: "POST" },
    { method: "HEAD" },
    { navigationType: "redirect" },
    { navigationType: "script", hasOpener: true, disposition: "newWindow" },
    { navigationType: "script", hasOpener: false, disposition: "newTab" },
    { navigationType: "other" },
    { disposition: "popup", hasOpener: true },
    { download: true },
    { modified: true },
    { sourceUrl: "file:///tmp/a" },
    { targetUrl: "mailto:user@example.org" },
    { targetUrl: "javascript:alert(1)" },
  ];
  for (const exemption of exemptions) assert.equal(resolvePinnedLink({ ...input, ...exemption }), null, JSON.stringify(exemption));
});


test("every wrapper refuses unsafe or malformed destinations", () => {
  const wrappers = [
    (target: string) => `https://google.com/url?q=${encodeURIComponent(target)}`,
    (target: string) => `https://www.google.com/url?url=${encodeURIComponent(target)}`,
    (target: string) => `https://slack-redir.net/link?url=${encodeURIComponent(target)}`,
    (target: string) => `https://nam01.safelinks.protection.outlook.com/?url=${encodeURIComponent(target)}`,
    (target: string) => `https://www.facebook.com/l.php?u=${encodeURIComponent(target)}`,
    (target: string) => `https://www.linkedin.com/redir/redirect?url=${encodeURIComponent(target)}`,
  ];
  for (const wrapper of wrappers) {
    for (const target of ["javascript:alert(1)", "data:text/html,hello", "https://", "https://example.org/%ZZ"]) {
      assert.equal(unwrapLinkRedirects(wrapper(target)), null, wrapper(target));
      const routed = resolvePinnedLink({ ...input, targetUrl: wrapper(target) });
      assert.ok(routed === null || routed.url === wrapper(target), "a refused wrapper is never opened at its decoded target");
      if (wrapper(target).includes("google.com")) assert.equal(routed, null, "a broken Google wrapper from Google stays same-site");
    }
  }
  assert.equal(unwrapLinkRedirects(`https://google.com/url?q=${encodeURIComponent(destination)}&url=${encodeURIComponent(destination)}`), null);
});

test("an empty destination parameter beside the real one doesn't make a wrapper ambiguous", () => {
  const destination = "https://example.org/story?id=7";
  assert.equal(unwrapLinkRedirects(`https://www.google.com/url?q=&url=${encodeURIComponent(destination)}`), destination);
  assert.equal(unwrapLinkRedirects(`https://www.google.com/url?sa=t&q=&url=`), null);
});
