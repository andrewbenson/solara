import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const script = readFileSync(new URL("../../../../../packages/solaracore/ios/page_script.js", import.meta.url), "utf8");
const source = script.match(/const scrollDirection = (\(\) => \{[\s\S]*?\n {2}\});\n/)?.[1];
assert.ok(source, "page_script.js defines scrollDirection");
const scrollDirection = new Function(`return ${source}`)();

function page({ range = 2000, height = 800 } = {}) {
  const d = scrollDirection();
  d.rebase(0);
  const sent = [];
  let now = 1000;
  return {
    sent,
    d,
    to(y, { dt = 16, viewport = height, max = range, user = true } = {}) {
      now += dt;
      const state = d.scrolled(y, max, viewport, now, user);
      if (state) sent.push(state);
      return state;
    },
    pause(ms = 500) {
      now += ms;
    },
    resize(viewport) {
      d.resized(viewport, now);
    },
  };
}

test("scrolling down past the threshold reports down once per gesture", () => {
  const p = page();
  for (let y = 4; y <= 200; y += 4) p.to(y);
  assert.deepEqual(p.sent, ["down"]);
  p.pause();
  for (let y = 204; y <= 300; y += 4) p.to(y);
  assert.deepEqual(p.sent, ["down", "down"]);
});

test("jitter under the thresholds doesn't flip it", () => {
  const p = page();
  for (let y = 10; y <= 300; y += 10) p.to(y);
  for (const y of [295, 300, 292, 299, 290, 300]) p.to(y);
  assert.deepEqual(p.sent, ["down"]);
  p.to(287);
  assert.deepEqual(p.sent, ["down", "up"]);
  for (const y of [290, 300, 305]) p.to(y);
  assert.deepEqual(p.sent, ["down", "up"]);
  p.to(320);
  assert.deepEqual(p.sent, ["down", "up", "down"]);
});

test("the top of the page reports top", () => {
  const p = page();
  for (let y = 20; y <= 200; y += 20) p.to(y);
  for (let y = 180; y >= 0; y -= 20) p.to(y);
  assert.deepEqual(p.sent, ["down", "up", "top"]);
});

test("a page with little to scroll never hides the bar", () => {
  const p = page({ range: 100 });
  for (let y = 5; y <= 100; y += 5) p.to(y);
  assert.deepEqual(p.sent, []);
});

test("the bar's own resize moving the scroll position doesn't flip it back (no loop)", () => {
  const p = page({ range: 1000 });
  for (let y = 10; y <= 1000; y += 10) p.to(y);
  assert.deepEqual(p.sent, ["down"]);
  p.resize(821);
  p.to(979, { viewport: 821, max: 979 });
  p.to(979, { viewport: 821, max: 979 });
  assert.deepEqual(p.sent, ["down"]);
  const q = page({ range: 1000 });
  for (let y = 10; y <= 1000; y += 10) q.to(y);
  q.to(979, { viewport: 821, max: 979 });
  assert.deepEqual(q.sent, ["down"]);
  q.pause(400);
  for (let y = 975; y >= 940; y -= 5) q.to(y, { viewport: 821, max: 979 });
  assert.deepEqual(q.sent, ["down", "up"]);
});

test("a quick reversal right after the bar hides still shows it", () => {
  const p = page({ range: 3000 });
  for (let y = 10; y <= 300; y += 10) p.to(y);
  assert.deepEqual(p.sent, ["down"]);
  p.resize(821);
  for (let y = 290; y >= 250; y -= 10) p.to(y, { viewport: 821 });
  assert.deepEqual(p.sent, ["down", "up"]);
});

test("a page that only scrolls a little once hidden still shows it going up", () => {
  const p = page({ range: 130 });
  for (let y = 10; y <= 130; y += 10) p.to(y);
  assert.deepEqual(p.sent, ["down"]);
  p.resize(821);
  p.to(109, { viewport: 821, max: 109 });
  p.pause(400);
  for (let y = 105; y >= 80; y -= 5) p.to(y, { viewport: 821, max: 109 });
  assert.deepEqual(p.sent, ["down", "up"]);
});

test("the page scrolling itself (scroll restoration, a chat) doesn't hide it", () => {
  const p = page();
  p.to(3000, { user: false });
  for (let y = 3020; y <= 3400; y += 20) p.to(y, { user: false });
  assert.deepEqual(p.sent, []);
  p.pause();
  p.to(3410);
  p.to(3440);
  assert.deepEqual(p.sent, ["down"]);
  p.to(0, { user: false });
  assert.deepEqual(p.sent, ["down", "top"]);
});

test("one jump (End, Space) counts", () => {
  const p = page();
  p.to(1200);
  assert.deepEqual(p.sent, ["down"]);
});
