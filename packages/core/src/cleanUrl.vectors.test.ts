import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { cleanUrl } from "./cleanUrl.ts";

const vectors: { cases: [string, string][] } = JSON.parse(readFileSync(new URL("./cleanUrl.vectors.json", import.meta.url), "utf8"));

test("cleanUrl matches the vectors the Swift cleaner is tested against", () => {
  assert.ok(vectors.cases.length > 150);
  for (const [input, output] of vectors.cases) assert.equal(cleanUrl(input), output, input);
});

test("the vectors cover every tracking parameter and prefix the cleaner knows", () => {
  const source = readFileSync(new URL("./cleanUrl.ts", import.meta.url), "utf8");
  const names = [...source.matchAll(/"([a-z0-9_\-]+)"/g)].map((m) => m[1]!).filter((n) => !n.includes(".") && n !== "x");
  const inputs = vectors.cases.map(([input]) => input).join(" ");
  for (const name of new Set(names)) assert.ok(inputs.includes(`?${name}`), name);
});
