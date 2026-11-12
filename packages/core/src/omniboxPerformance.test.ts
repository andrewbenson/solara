import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { classifyPaste, fixupUrl, resolveInput } from "./omnibox.ts";
import { buildSuggestions } from "./suggest.ts";

test("dotted dashed text keeps its search and navigation classifications", () => {
  const cases: [string, string | null][] = [
    ["my-post.another-post.x", null],
    ["my-post.another-post.x:", null],
    ["a-b.c-d.e-f.g-h.i:", null],
    ["my-post.another-post.x:8", "https://my-post.another-post.x:8"],
    ["my-post.another-post.x:8080/path", "https://my-post.another-post.x:8080/path"],
    ["my-post.another-post.x:12345", "https://my-post.another-post.x:12345"],
    ["my-post.another-post.x:123456", null],
    ["my-post.another-post.x:x", null],
    ["my-post.another-post.x:/path", null],
    ["my-post.another-post.x/path", null],
    ["my-post.another-post.x/path?x=1", "https://my-post.another-post.x/path?x=1"],
    ["my-post.another-post.x/", "https://my-post.another-post.x/"],
    ["my-post.another-post.com", "https://my-post.another-post.com"],
    ["my-post.another-post.com:", null],
    ["a-b.c-d.e-f.g-h.i:80", "https://a-b.c-d.e-f.g-h.i:80"],
    ["-.".repeat(256), null],
    ["-.".repeat(255) + "-:", null],
    ["a-b.".repeat(127) + "x:", null],
    ["a-b.".repeat(126) + "x:8080/p", "https://" + "a-b.".repeat(126) + "x:8080/p"],
    ["a" + "-".repeat(508) + ".x:", null],
  ];
  for (const [text, url] of cases) {
    const resolved = url ?? `https://www.google.com/search?q=${encodeURIComponent(text)}`;
    assert.equal(fixupUrl(text), url, text);
    assert.equal(resolveInput(text), resolved, text);
    assert.deepEqual(classifyPaste(text), url ? { kind: "go", url } : { kind: "search", query: text }, text);
    const result = buildSuggestions(text, { tabs: [], history: [] });
    assert.equal(result.items[0]?.kind, url ? "page" : "search", text);
    assert.equal(result.items[0]?.url, resolved, text);
    assert.equal(result.completion, "", text);
  }
});

test("every dotted dashed keystroke through 512 characters stays within its parsing budget", (t) => {
  const output = execFileSync(process.execPath, ["--input-type=module", "--eval", `
    import assert from "node:assert/strict";
    import { fixupUrl, resolveInput, classifyPaste } from ${JSON.stringify(new URL("./omnibox.ts", import.meta.url).href)};
    import { buildSuggestions, prepareSuggestions } from ${JSON.stringify(new URL("./suggest.ts", import.meta.url).href)};
    const now = 1794441600000;
    const source = {
      tabs: [{ id: "post", url: "https://my-post.another-post.com/", title: "My post", favicon: null }],
      history: [
        { url: "https://my-post.another-post.com/", title: "My post", favicon: null, visits: 5, lastVisit: now },
        { url: "https://a-b.c-d.com/path", title: "Dashed path", favicon: null, visits: 3, lastVisit: now }
      ]
    };
    prepareSuggestions(source, Infinity);
    const stems = ["my-post.another-post.x", "a-b.c-d.e-f.g-h.i"];
    for (const n of [64, 128, 256, 512]) {
      stems.push("a-b.".repeat(Math.ceil(n / 4)).slice(0, n - 1) + "x");
      stems.push("-.".repeat(n / 2));
      stems.push("a" + "-".repeat(n - 3) + ".x");
    }
    const prefixes = new Set();
    for (const stem of stems) for (const tail of ["", ":", ":8", ":8080", ":123456", ":x", "/path", "/path?x=1", ":8080/path", ":/path"]) {
      const text = stem.slice(0, 512 - tail.length) + tail;
      for (let i = 1; i <= text.length; i++) prefixes.add(text.slice(0, i));
    }
    const runs = {
      parsing: q => { fixupUrl(q); resolveInput(q); classifyPaste(q); },
      suggestions: q => buildSuggestions(q, source, { now })
    };
    const worst = {};
    for (const [name, run] of Object.entries(runs)) {
      for (const q of prefixes) run(q);
      let maximum = 0;
      let slowest = "";
      for (const q of prefixes) {
        const samples = [];
        for (let r = 0; r < 5; r++) {
          const started = performance.now();
          run(q);
          samples.push(performance.now() - started);
        }
        samples.sort((a, b) => a - b);
        if (samples[2] > maximum) { maximum = samples[2]; slowest = q; }
      }
      worst[name] = maximum;
      assert.ok(maximum < 10, name + " took " + maximum + " ms for " + JSON.stringify(slowest));
    }
    process.stdout.write(JSON.stringify({ prefixes: prefixes.size, worst }));
  `], { encoding: "utf8", timeout: 10_000, killSignal: "SIGKILL" });
  const result = JSON.parse(output) as { prefixes: number; worst: Record<string, number> };
  assert.ok(result.prefixes > 2000);
  t.diagnostic(`${result.prefixes} prefixes; worst per-key median ms: ${JSON.stringify(result.worst)}`);
});
