#!/usr/bin/env node
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { deflateSync } from "node:zlib";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/") || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error("usage: node share-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-share-"));
const rep = reporter(join(scratch, "share-test.log"), { name: "share-test" });
const data = join(scratch, "data");
const menuLog = join(scratch, "context-menu.json");

function png(width, height) {
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (buf) => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, body) => {
    const head = Buffer.alloc(4); head.writeUInt32BE(body.length);
    const tail = Buffer.alloc(4); tail.writeUInt32BE(crc(Buffer.concat([Buffer.from(type), body])));
    return Buffer.concat([head, Buffer.from(type), body, tail]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const rows = Buffer.concat(Array.from({ length: height }, (_, y) => Buffer.concat([Buffer.from([0]), ...Array.from({ length: width }, (_, x) => Buffer.from([200, (x * 40) % 256, (y * 60) % 256]))])));
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}

const image = png(6, 4);
const fixture = `<!doctype html><title>Share Fixture</title><body style="margin:0;font:16px sans-serif">
<p id="quote" style="position:absolute;left:20px;top:20px">Sharing is caring</p>
<a id="link" style="position:absolute;left:20px;top:80px" href="/target?id=42&gclid=abc">a tracked link</a>
<img id="img" style="position:absolute;left:20px;top:140px;width:120px;height:80px" src="/secret.png">
<video id="vid" style="position:absolute;left:200px;top:140px;width:160px;height:90px;background:#123" src="/clip.mp4?fbclid=7"></video>
<div id="blank" style="position:absolute;left:400px;top:300px;width:200px;height:100px"></div></body>`;
const server = createServer((req, res) => {
  if (req.url.startsWith("/page")) {
    res.writeHead(200, { "content-type": "text/html", "set-cookie": "share=1; Path=/" });
    return res.end(fixture);
  }
  if (req.url === "/secret.png") {
    if (!/(^|; )share=1/.test(req.headers.cookie ?? "")) { res.writeHead(403); return res.end(); }
    res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
    return res.end(image);
  }
  res.writeHead(404);
  res.end();
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const pageUrl = `${origin}/page?id=1&utm_source=newsletter`;

const app = await launch(resolve(appArg), {
  data,
  env: { SOLARA_CONTEXT_MENU_LOG: menuLog },
  session: session({ profiles: ["Personal"], windows: [{ id: "w1", tabIds: ["t0"], activeTabIds: { default: "t0" }, frame: [60, 60, 1200, 800] }],
    tabs: [{ id: "t0", url: pageUrl, title: "Share Fixture" }] }),
  ready: "return !!ac.store",
});
const run = (body, timeout = 30000) => app.eval(body, { timeout });
const until = async (what, test, ms = 8000) => {
  const end = Date.now() + ms;
  for (;;) {
    const value = await test();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(60);
  }
};
const activation = () => (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8").split("\n").filter(Boolean) : []);
const shareLine = async (before) => until("a share sheet line", async () => activation().slice(before).find((line) => line.includes("share sheet (not shown):")) ?? null);

let page;
const box = async (id) => JSON.parse(await page.eval(`JSON.stringify(document.getElementById(${JSON.stringify(id)}).getBoundingClientRect())`));
const rightClick = async (id) => {
  const b = await box(id);
  const at = { x: Math.round(b.x + Math.min(10, b.width / 2)), y: Math.round(b.y + b.height / 2), button: "right", clickCount: 1 };
  await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
  await page.send("Input.dispatchMouseEvent", { type: "mousePressed", ...at });
  await page.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...at });
};
const menuFor = async (id) => {
  rmSync(menuLog, { force: true });
  await rightClick(id);
  return until(`the menu on #${id}`, async () => (existsSync(menuLog) ? JSON.parse(readFileSync(menuLog, "utf8")) : null));
};
const labels = (menu) => menu.items.filter((item) => item.label).map((item) => item.label);
const pick = async (id, title) => {
  const before = activation().length;
  writeFileSync(`${menuLog}.pick`, `${title}\t0\n`);
  await rightClick(id);
  const line = await shareLine(before);
  assert.ok(!existsSync(`${menuLog}.pick`), "the pick was taken");
  return line;
};

try {
  page = await app.page("/page?id=1");
  await until("the fixture image", async () => page.eval(`document.getElementById("img").complete && document.getElementById("img").naturalWidth === 6`));

  await rep.check("selected text offers Share Selection after Copy, and shares the text", async () => {
    await page.eval(`getSelection().selectAllChildren(document.getElementById("quote")); true`);
    try {
      const items = labels(await menuFor("quote"));
      const at = items.indexOf("Share Selection…");
      assert.ok(at > 0, `items: ${items.join(" | ")}`);
      assert.equal(items[at - 1], "Copy");
      const line = await pick("quote", "Share Selection…");
      assert.match(line, /text="Sharing is caring"/);
    } finally {
      await page.eval(`getSelection().removeAllRanges(); true`);
    }
  });

  await rep.check("a link offers Share Link after Copy Link Address, and shares it without its trackers", async () => {
    const items = labels(await menuFor("link"));
    assert.equal(items[items.indexOf("Share Link…") - 1], "Copy Link Address", `items: ${items.join(" | ")}`);
    const line = await pick("link", "Share Link…");
    assert.ok(line.includes(`url=${origin}/target?id=42 `), line);
  });

  await rep.check("an image the page loaded with its cookie is shared as the image itself", async () => {
    const items = labels(await menuFor("img"));
    assert.ok(items.includes("Share Image…"), `items: ${items.join(" | ")}`);
    const line = await pick("img", "Share Image…");
    const [, path, bytes] = /image=(\S+) bytes=(\d+)/.exec(line) ?? [];
    assert.ok(path, line);
    const shared = readFileSync(path);
    assert.equal(Number(bytes), shared.length);
    assert.deepEqual(shared, image, "the shared file holds the page's own PNG");
  });

  await rep.check("a video shares its source without its trackers", async () => {
    const items = labels(await menuFor("vid"));
    assert.ok(items.includes("Share Video…"), `items: ${items.join(" | ")}`);
    const line = await pick("vid", "Share Video…");
    assert.ok(line.includes(`url=${origin}/clip.mp4 `), line);
  });

  await rep.check("the page itself shares its address without trackers and its title", async () => {
    const items = labels(await menuFor("blank"));
    assert.ok(items.includes("Share Page…"), `items: ${items.join(" | ")}`);
    const line = await pick("blank", "Share Page…");
    assert.ok(line.includes(`url=${origin}/page?id=1 title="Share Fixture"`), line);
  });

  await rep.check("File › Share… (⌥⌘S) shares the page in front", async () => {
    const before = activation().length;
    await run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ key: "s", keyCode: 1, modifiers: ["command", "option"] })})`);
    const line = await shareLine(before);
    assert.ok(line.includes(`url=${origin}/page?id=1 title="Share Fixture"`), line);
  });
} finally {
  page?.close();
  await app.quit();
}

try {
  const stalled = await launch(resolve(appArg), {
    data: join(scratch, "stalled"),
    env: { SOLARA_CONTEXT_MENU_LOG: menuLog, SOLARA_TEST_SHARE_IMAGE_STALL: "1" },
    session: session({ profiles: ["Personal"], windows: [{ id: "w1", tabIds: ["t0"], activeTabIds: { default: "t0" }, frame: [60, 60, 1200, 800] }],
      tabs: [{ id: "t0", url: pageUrl, title: "Share Fixture" }] }),
    ready: "return !!ac.store",
  });
  const log = () => (existsSync(join(scratch, "stalled", "activation.log")) ? readFileSync(join(scratch, "stalled", "activation.log"), "utf8").split("\n").filter(Boolean) : []);
  try {
    page = await stalled.page("/page?id=1");
    await until("the fixture image", async () => page.eval(`document.getElementById("img").complete && document.getElementById("img").naturalWidth === 6`));
    await rep.check("an image request the page never answers falls back to sharing the image's link after the deadline", async () => {
      const before = log().length;
      const started = Date.now();
      writeFileSync(`${menuLog}.pick`, "Share Image…\t0\n");
      await rightClick("img");
      const line = await until("the fallback share line", async () => log().slice(before).find((l) => l.includes("share sheet (not shown):")) ?? null, 20000);
      assert.ok(line.includes(`image-link=${origin}/secret.png`), line);
      assert.ok(Date.now() - started >= 9000, `shared after ${Date.now() - started} ms, before the deadline`);
    });
  } finally {
    page?.close();
    await stalled.quit();
  }
} finally {
  server.close();
}
const ok = rep.summary();
if (!keep) rmSync(scratch, { recursive: true, force: true });
process.exit(ok ? 0 : 1);
