import assert from "node:assert/strict";
import { test } from "node:test";
import { assignPositions } from "./order.ts";

const DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

function shippedAssignPositions(existing: (string | undefined)[]): string[] {
  const BASE = DIGITS.length;
  const digit = (c: string | undefined) => (c === undefined ? 0 : DIGITS.indexOf(c));
  const between = (a: string, b: string | null): string => {
    if (b !== null && a >= b) throw new Error(`positionBetween: ${a} >= ${b}`);
    if (b !== null) {
      let n = 0;
      while ((a[n] ?? "0") === b[n]) n++;
      if (n > 0) return b.slice(0, n) + between(a.slice(n), b.slice(n));
    }
    const da = digit(a[0]);
    const db = b !== null ? digit(b[0]) : BASE;
    if (db - da > 1) return DIGITS[Math.round((da + db) / 2)]!;
    if (b !== null && b.length > 1) return b.slice(0, 1);
    return DIGITS[da]! + between(a.slice(1), null);
  };
  const tails: number[] = [];
  const previous = new Array<number>(existing.length).fill(-1);
  existing.forEach((p, i) => {
    if (p === undefined || !p || p.endsWith("0")) return;
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (existing[tails[mid]!]! < p) lo = mid + 1;
      else hi = mid;
    }
    if (lo > 0) previous[i] = tails[lo - 1]!;
    tails[lo] = i;
  });
  const keep = new Set<number>();
  for (let i = tails.length ? tails[tails.length - 1]! : -1; i >= 0; i = previous[i]!) keep.add(i);
  const out = new Array<string>(existing.length);
  for (const i of keep) out[i] = existing[i]!;
  let before = "";
  for (let i = 0; i < existing.length; i++) {
    if (keep.has(i)) {
      before = out[i]!;
      continue;
    }
    let next: string | null = null;
    for (let j = i + 1; j < existing.length; j++) {
      if (keep.has(j)) {
        next = out[j]!;
        break;
      }
    }
    out[i] = between(before, next);
    before = out[i]!;
  }
  return out;
}

function seeded(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const EDGE_DIGITS = ["0", "1", "9", "A", "V", "Z", "a", "y", "z"];

function base62Position(random: () => number): string | undefined {
  const roll = random();
  if (roll < 0.15) return undefined;
  if (roll < 0.2) return "";
  const length = 1 + Math.floor(random() * 4);
  const pool = random() < 0.5 ? EDGE_DIGITS : [...DIGITS];
  return Array.from({ length }, () => pool[Math.floor(random() * pool.length)]!).join("");
}

const ascending = (out: string[]) => out.every((p, i) => i === 0 || out[i - 1]! < p);
const placeable = (p: string) => /^[0-9A-Za-z]*[1-9A-Za-z]$/.test(p);

test("positions from base-62 anchors are exactly what the shipped allocator gave", () => {
  const edges: (string | undefined)[][] = [
    [],
    [undefined],
    [""],
    ["0"],
    ["a0"],
    ["a", "b"],
    ["a", "a"],
    ["b", "a"],
    ["z", "zz", "zzz"],
    ["1", "10", "11"],
    ["V", "V1", "V01"],
    [undefined, "a", undefined, "b", undefined],
    ["z", undefined, undefined],
    [undefined, undefined, "1"],
    ["1", undefined, "2"],
    ["a0", "a", "a1"],
    ["zz", "a", "z"],
    ["", "0", "00", "1"],
    ["zzzz", undefined],
    ["V", undefined, "V0001"],
    [undefined, "zzzz", undefined, "zzzzV", undefined],
  ];
  for (const existing of edges) assert.deepEqual(assignPositions(existing), shippedAssignPositions(existing), JSON.stringify(existing));
  const random = seeded(62);
  for (let run = 0; run < 5000; run++) {
    const existing = Array.from({ length: Math.floor(random() * 9) }, () => base62Position(random));
    assert.deepEqual(assignPositions(existing), shippedAssignPositions(existing), JSON.stringify(existing));
  }
});

test("an anchor that isn't base-62 is replaced, so positions stay base-62 and ascending, and a lone surrogate is never made", () => {
  const malformed = ["\u{1F600}", "\ud83d", "\ude00", "a\u{1F600}", "-", " ", "\u00e9", "a-b", "\uffff"];
  const random = seeded(7);
  for (let run = 0; run < 3000; run++) {
    const existing = Array.from({ length: 1 + Math.floor(random() * 8) }, () => (random() < 0.4 ? malformed[Math.floor(random() * malformed.length)] : base62Position(random)));
    const out = assignPositions(existing);
    assert.ok(out.every(placeable), JSON.stringify([existing, out]));
    assert.ok(ascending(out), JSON.stringify([existing, out]));
    existing.forEach((p, i) => {
      if (p !== undefined && !placeable(p)) assert.notEqual(out[i], p, JSON.stringify([existing, out]));
    });
    const usable = existing.filter((p): p is string => p !== undefined && placeable(p));
    const runEndingAt = usable.map(() => 1);
    usable.forEach((p, i) => usable.slice(0, i).forEach((q, j) => q < p && (runEndingAt[i] = Math.max(runEndingAt[i]!, runEndingAt[j]! + 1))));
    const longestUsableRun = Math.max(0, ...runEndingAt);
    const kept = out.filter((p, i) => p === existing[i]).length;
    assert.ok(kept >= longestUsableRun, JSON.stringify([existing, out]));
  }
  assert.deepEqual(assignPositions(["a0", "b", "z", "\u{1F600}", undefined, undefined]), ["J", "b", "z", "zV", "zl", "zt"]);
});

test("a truthy non-string position from another Mac is replaced instead of throwing", () => {
  const existing = ["b", 5, true, {}, [], null, "m"] as unknown as (string | undefined)[];
  const out = assignPositions(existing);
  assert.equal(out[0], "b");
  assert.equal(out[6], "m");
  assert.ok(out.every(placeable) && ascending(out), JSON.stringify(out));
});
