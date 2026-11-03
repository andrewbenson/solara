import assert from "node:assert/strict";
import http from "node:http";
import { once } from "node:events";
import { setTimeout as sleep } from "node:timers/promises";
import test from "node:test";
import { startServer } from "./js-bench.mjs";

async function fixture(t) {
  const server = await startServer(0);
  t.after(() => new Promise((resolve) => { server.closeAllConnections(); server.close(resolve); }));
  const request = (path) => http.get({ hostname: "127.0.0.1", port: server.address().port, path, agent: false });
  const get = (path) => new Promise((resolve, reject) => {
    const req = request(path);
    req.once("error", reject);
    req.once("response", (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, body }));
    });
  });
  return { server, request, get };
}

const escaped = (value) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");

test("heavy run IDs stay in title text and round-trip through resource query attributes", { timeout: 10000 }, async (t) => {
  const { get } = await fixture(t);
  const run = '</title><img id=injected src=x onerror="alert(1)">&\' #?';
  const { status, body } = await get(`/heavy?${new URLSearchParams({ run })}`);
  assert.equal(status, 200);
  assert.ok(body.includes(`<title>Loading ${escaped(run)}</title>`));
  assert.ok(!body.includes("<img id=injected"));
  const resources = [...body.matchAll(/(?:src|href)="([^"]+)"/g)];
  assert.equal(resources.length, 41);
  for (const [, attr] of resources) {
    const url = new URL(attr.replaceAll("&amp;", "&"), "http://localhost");
    assert.equal(url.searchParams.get("r"), run);
  }
});

test("raw fallback path markup remains escaped text", { timeout: 10000 }, async (t) => {
  const { get } = await fixture(t);
  const path = '/name<svg&"\'>';
  const { body } = await get(path);
  const name = new URL(path, "http://localhost").pathname.split("/").pop();
  assert.ok(body.includes(`<title>Page ${escaped(name)}</title>`));
  assert.ok(body.includes(`<p>${escaped(name)}</p>`));
  assert.ok(!body.includes("<svg"));
});

test("ordinary heavy pages keep their exact fixture bytes", { timeout: 10000 }, async (t) => {
  const { get } = await fixture(t);
  for (const run of ["0-1793635200000", "bg-1793635200000", "cen-0-1793635200000", "cenbg-0-1793635200000"]) {
    const images = Array.from({ length: 40 }, (_, i) => `<img src="/img/${i}?d=${40 + ((i * 37) % 900)}&r=${run}" width=40 height=40>`).join("");
    assert.equal((await get(`/heavy?run=${run}`)).body, `<!doctype html><html><head><meta name="theme-color" content="#336699"><title>Loading ${run}</title>
<link rel="icon" href="/favicon.ico?d=300&r=${run}"></head><body><h1>Heavy page</h1>${images}
<script>let n=0;const t=setInterval(()=>{document.title='Heavy '+(++n);if(n>=5)clearInterval(t)},150);</script></body></html>`);
  }
});

test("delays reject malformed and out-of-range integers on both resource routes", { timeout: 10000 }, async (t) => {
  const { get } = await fixture(t);
  for (const route of ["/img/0", "/favicon.ico"]) {
    for (const d of ["NaN", "Infinity", "-1", "2001", "1.5", "", " ", "0x10", "1e2", "2ms"]) {
      assert.equal((await get(`${route}?${new URLSearchParams({ d })}`)).status, 400, `${route} d=${JSON.stringify(d)}`);
    }
    assert.equal((await get(route)).status, 200);
    assert.equal((await get(`${route}?d=0`)).status, 200);
  }
});

test("ordinary delay and inclusive maximum retain their timing", { timeout: 10000 }, async (t) => {
  const { get } = await fixture(t);
  for (const d of [40, 2000]) {
    const start = performance.now();
    assert.equal((await get(`/img/0?d=${d}`)).status, 200);
    assert.ok(performance.now() - start >= d - 10);
  }
});

test("pending delays are capped and aborted connections release capacity", { timeout: 10000 }, async (t) => {
  const { server, request, get } = await fixture(t);
  const requests = [];
  t.after(() => requests.forEach((req) => req.destroy()));
  let received = 0;
  const allReceived = new Promise((resolve) => server.on("request", () => { if (++received === 128) resolve(); }));
  for (let i = 0; i < 128; i++) {
    const req = request("/img/0?d=2000");
    req.on("error", () => {});
    requests.push(req);
  }
  await allReceived;
  try {
    assert.equal((await get("/favicon.ico?d=0")).status, 503);
  } finally {
    const closed = requests.map((req) => new Promise((resolve) => req.once("close", resolve)));
    requests.forEach((req) => req.destroy());
    await Promise.all(closed);
  }
  await sleep(25);
  assert.equal((await get("/img/0?d=0")).status, 200);
});

test("aborting a delayed response clears its timer immediately", { timeout: 10000 }, async (t) => {
  const { server, request } = await fixture(t);
  const original = globalThis.setTimeout;
  let timer;
  globalThis.setTimeout = (fn, ms, ...args) => {
    const result = original(fn, ms, ...args);
    if (ms === 1999) timer = result;
    return result;
  };
  t.after(() => { globalThis.setTimeout = original; });
  const handled = once(server, "request");
  const req = request("/img/0?d=1999");
  req.on("error", () => {});
  await handled;
  const closed = new Promise((resolve) => req.once("close", resolve));
  req.destroy();
  await closed;
  await sleep(25);
  assert.ok(timer);
  assert.equal(timer._destroyed, true);
});
