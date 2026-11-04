import { attach, sleep } from "../../../../scripts/lib/instance.mjs";

const [pages] = process.argv.slice(2);
const instance = attach(process.env.SMOKE_DATA);
const wanted = [`${pages}/ad.html?restored-work`, `${pages}/ad.html?restored-home`];
const fateOf = `JSON.stringify({ title: document.title, ad: window.ad, complete: document.readyState === "complete", scripts: performance.getEntriesByType("resource").filter((e) => e.name.includes("adsbygoogle")).map((e) => e.decodedBodySize) })`;
const within = (ms, promise, fallback) => Promise.race([promise, sleep(ms).then(() => fallback)]);

async function fate(url) {
  for (const start = Date.now(); Date.now() - start < 30000; await sleep(200)) {
    const target = (await within(3000, instance.targets(), []).catch(() => [])).find((t) => t.type === "page" && t.url === url);
    const session = target && (await within(3000, instance.page((t) => t.id === target.id), null).catch(() => null));
    if (!session) continue;
    const reply = await within(6000, session.send("Runtime.evaluate", { expression: fateOf, returnByValue: true }, { timeout: 5000 }), null).catch(() => null);
    let page;
    try { page = JSON.parse(reply?.result?.value); } catch { continue; }
    if (page.title !== "ad" || !page.complete || (page.ad !== "loaded" && page.ad !== "blocked")) continue;
    if (page.scripts.some((size) => size > 10000)) return "loaded";
    if (page.scripts.length) return `unclear (${page.ad}, ${page.scripts.join("/")} bytes)`;
    return "blocked";
  }
  return "not restored";
}

const fates = await within(40000, Promise.all(wanted.map(fate)), ["timed out", "timed out"]);
const ok = fates.every((f) => f === "blocked");
console.log(`${ok ? "PASS" : "FAIL"}  restored tabs wait for uBlock at launch: no ad loads in either profile  (work ${fates[0]}, home ${fates[1]})`);
process.exit(ok ? 0 : 1);
