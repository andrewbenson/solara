import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node little-solara-links-test.mjs <Debug Solara.app> [--keep-data]

Settings › General › "Open new-tab links from Little Solara in". With Little Solara chosen, a target=_blank rel=opener link (target=_blank alone
implies noopener) in a Little Solara page opens in a second Little Solara window, not as a tab of the main window, and the new page keeps its
opener: once it has settled in its new window, its window.opener.postMessage reaches the page that opened it (OAuth pop-outs depend on this). A plain target=_blank link (noopener) opens in a second
Little Solara too. With Main Window
(the default) the link opens behind as a tab of the main window, as before, also with its opener.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-little-solara-links-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "little-solara-links-test.log"), { name: "little-solara-links-test" });

const OPENER_PAGE = `<!doctype html><title>opener</title><body>
<a id="out" href="/child" target="_blank" rel="opener">open</a>
<a id="plain" href="/child?plain" target="_blank">plain</a>
<script>window.__messages = []; addEventListener("message", (e) => window.__messages.push(String(e.data)));</script>`;
const CHILD_PAGE = `<!doctype html><title>child</title><body>child
<script>if (window.opener) window.opener.postMessage("from-child", "*");</script>`;
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(req.url.startsWith("/child") ? CHILD_PAGE : req.url.startsWith("/opener") ? OPENER_PAGE : "<!doctype html><title>main</title>main");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${origin}/main`, title: "main" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

let app = null;
const run = (body, timeout = 10000) => app.eval(body, { timeout });
const state = () =>
  run(`const s = ac.store.getState();
    const small = Object.values(s.windows).filter((w) => w.kind === "small");
    return { small: small.length, smallUrls: small.flatMap((w) => w.tabIds.map((id) => s.tabs[id]?.url ?? "")), mainTabs: s.windows.w1.tabIds.map((id) => s.tabs[id]?.url ?? "") };`);
const pageEval = async (urlPart, expression, options = {}) => {
  const page = await app.page(urlPart);
  try {
    return await page.eval(expression, { timeout: 4000, ...options });
  } finally {
    page.close();
  }
};
const until = async (what, accept, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await accept().catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error && last.ok) return last;
    await sleep(200);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};

async function clickFromLittleSolara(keeps, landed, link = "out") {
  await run(`const s = ac.store.getState();
    for (const w of Object.values(s.windows)) if (w.kind === "small") s.closeWindow(w.id);
    for (const id of [...s.windows.w1.tabIds]) if (s.tabs[id]?.url?.includes("/child")) s.closeTab(id);
    s.updateSettings({ littleSolaraKeepsNewTabLinks: ${keeps} });
    s.createWindow({ small: true, url: ${JSON.stringify(`${origin}/opener`)} }); return 1;`);
  await until("the opener page loads in Little Solara", async () => ({ ok: (await pageEval("/opener", "document.readyState")) === "complete" }));
  const before = await state();
  await pageEval("/opener", `document.getElementById(${JSON.stringify(link)}).click(), true`, { userGesture: true });
  const child = await until("the linked page loads", async () => ({ ok: (await pageEval("/child", "document.readyState")) === "complete" }));
  const after = await until("the linked page settles where it belongs", async () => {
    const now = await state();
    return { ok: landed(now, before), ...now };
  }).catch(() => state());
  const nonce = `after-adoption-${Date.now()}`;
  const sent = await pageEval("/child", `window.opener ? (window.opener.postMessage(${JSON.stringify(nonce)}, "*"), true) : false`);
  const messages = await until("the opener hears from the settled page", async () => {
    const got = await pageEval("/opener", "window.__messages.join(',')");
    return { ok: got.includes(nonce), got };
  }).catch((e) => ({ ok: false, sent, error: e.message }));
  return { before, after, child, messages };
}

try {
  app = await launch(appArg, { data, session: fixture, ready: "return !!ac.store" });
  rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);

  await rep.check("with Little Solara chosen, a target=_blank link opens in a second Little Solara", async () => {
    const out = await clickFromLittleSolara(true, (now, before) => now.small === before.small + 1 && now.smallUrls.some((u) => u.includes("/child")));
    const inSmall = out.after.small === out.before.small + 1 && out.after.smallUrls.some((u) => u.includes("/child"));
    const notInMain = !out.after.mainTabs.some((u) => u.includes("/child"));
    if (!inSmall || !notInMain) throw new Error(`small ${out.before.small} → ${out.after.small}, small pages ${out.after.smallUrls}, main ${out.after.mainTabs}`);
    if (!out.messages.ok) throw new Error(`the new page lost its opener: ${JSON.stringify(out.messages)}`);
    return { small: out.after.small, messages: out.messages.got };
  });

  await rep.check("with Little Solara chosen, a plain target=_blank link (noopener) opens in a second Little Solara too", async () => {
    const out = await clickFromLittleSolara(true, (now, before) => now.small === before.small + 1 && now.smallUrls.some((u) => u.includes("/child?plain")), "plain");
    const inSmall = out.after.small === out.before.small + 1 && out.after.smallUrls.some((u) => u.includes("/child?plain"));
    const notInMain = !out.after.mainTabs.some((u) => u.includes("/child"));
    if (!inSmall || !notInMain) throw new Error(`small ${out.before.small} → ${out.after.small}, small pages ${out.after.smallUrls}, main ${out.after.mainTabs}`);
    return { small: out.after.small, opener: out.messages.sent ?? "none (noopener)" };
  });

  await rep.check("with Main Window (the default), the link opens as a tab of the main window, opener intact", async () => {
    const out = await clickFromLittleSolara(false, (now) => now.mainTabs.some((u) => u.includes("/child")));
    const inMain = out.after.mainTabs.some((u) => u.includes("/child"));
    if (!inMain || out.after.small !== out.before.small) throw new Error(`small ${out.before.small} → ${out.after.small}, main ${out.after.mainTabs}`);
    if (!out.messages.ok) throw new Error(`the new tab lost its opener: ${JSON.stringify(out.messages)}`);
    return { mainTabs: out.after.mainTabs.length, messages: out.messages.got };
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
