import { mkdtempSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const appArg = process.argv[2];
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error(`usage: node window-close-and-mute-test.mjs <Debug Solara.app under apps/browser/build-*>

In a hidden instance: ⌘W through every regular tab of a window with a pinned tile leaves the window on a New Tab page
and keeps the tile; in a window with no pins, ⌘W on the New Tab page the last tab left closes it; New Window opens on
the profile of the window it's chosen in; and a real page notification from a site is delivered with sound until the
site is muted, then without (the memory notification adapter's delivered row).`);
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "ac-window-close-mute-"));
const rep = reporter(join(scratch, "window-close-and-mute-test.log"), { name: "window-close-and-mute-test" });

const server = createServer((req, res) => {
  const path = req.url.split("?")[0].slice(1) || "page";
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${path}</title><p>${path}</p>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const url = (n) => `${origin}/${n}`;

const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [
    { id: "p", url: url("pinned"), title: "pinned", pinned: true },
    { id: "a", url: url("one"), title: "one" },
    { id: "b", url: url("two"), title: "two" },
  ],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const regular = (w) => S().windows[w] ? S().windows[w].tabIds.filter((id) => S().tabs[id]?.profileId === S().windows[w].profileId && !S().tabs[id].pinned && !Object.values(S().groups).some((g) => g.pinned && g.tabIds.includes(id))) : null;
const activeOf = (w) => S().windows[w].activeTabIds[S().windows[w].profileId];
const closeActive = (w) => ac.runCommand({ command: "closeTab", arg: null, windowId: w });
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 10000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const json = JSON.stringify;

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    ready: "return !!ac.store.getState().windows.w1",
  });
  await until("page one", `return S().tabs.a?.title === "one" || null;`, 15000);

  await rep.check("⌘W through every regular tab keeps a window that has a pinned tile, on a New Tab page", async () => {
    const steps = [];
    for (let i = 0; i < 4; i++) {
      const state = await run(`return { open: !!S().windows.w1, urls: regular("w1")?.map((id) => S().tabs[id].url) ?? null, active: S().windows.w1 && activeOf("w1") };`);
      if (!state.open) break;
      if (json(state.urls) === json([""]) && steps.length) break;
      if (state.active === "p") await run(`S().activate(regular("w1").at(-1)); return true;`);
      await run(`closeActive("w1"); return true;`);
      await sleep(500);
      steps.push(await run(`return { open: !!S().windows.w1, urls: regular("w1")?.map((id) => S().tabs[id].url) ?? null };`));
    }
    await run(`S().activate(regular("w1")[0]); return true;`);
    await run(`closeActive("w1"); return true;`);
    await sleep(800);
    const end = await run(`return { open: !!S().windows.w1, urls: regular("w1")?.map((id) => S().tabs[id].url) ?? null, pinned: S().tabs.p?.windowId };`);
    if (!end.open) throw new Error(`the window closed: ${json({ steps, end })}`);
    if (json(end.urls) !== json([""])) throw new Error(`expected one New Tab page, got ${json({ steps, end })}`);
    if (end.pinned !== "w1") throw new Error(`the pinned tile left: ${json(end)}`);
    const native = await app.snapshot({ windowId: "w1" }).catch((e) => ({ error: e.message }));
    return { steps, end, nativeSnapshot: native.error ? native.error : native.consistent };
  });

  await rep.check("with no pins, ⌘W on the New Tab page left by the last tab closes the window", async () => {
    const w = await run(`const s = S(); const work = s.createProfile({ name: "Work" }); return s.createWindow({ profileId: work, url: ${json(url("work"))} });`);
    await until("work page", `return S().tabs[regular(${json(w)})[0]]?.title === "work" || null;`, 15000);
    await run(`S().setFocusedWindow(${json(w)}); closeActive(${json(w)}); return true;`);
    await until("New Tab page", `const r = regular(${json(w)}); return r && r.length === 1 && S().tabs[r[0]].url === "" ? true : null;`);
    await run(`closeActive(${json(w)}); return true;`);
    await until("window closed", `return S().windows[${json(w)}] ? null : true;`);
    return { window: w, firstWindowStillOpen: await run(`return !!S().windows.w1;`) };
  });

  await rep.check("New Window opens on the profile of the window it's chosen in", async () => {
    const work = await run(`return S().profileOrder.find((id) => S().profiles[id].name === "Work");`);
    const w = await run(`return S().createWindow({ profileId: ${json(work)} });`);
    await run(`S().setFocusedWindow(${json(w)}); return true;`);
    const before = await run(`return Object.keys(S().windows);`);
    await run(`ac.runCommand({ command: "newWindow", arg: null, windowId: ${json(w)} }); return true;`);
    const made = await until("new window", `const ids = Object.keys(S().windows).filter((id) => !${json(before)}.includes(id)); return ids.length ? ids[0] : null;`);
    const profile = await run(`return S().windows[${json(made)}].profileId;`);
    if (profile !== work) throw new Error(`new window is on ${profile}, not ${work}`);
    await run(`S().closeWindow(${json(made)}); S().closeWindow(${json(w)}); return true;`);
    return { work, made };
  });

  await rep.check("a muted site's notification is delivered without sound, an unmuted one with sound", async () => {
    const mode = (await run(`return globalThis.expo.modules.SolaraCEF.notificationDebugSnapshot();`))?.hub?.mode;
    await run(`return globalThis.expo.modules.SolaraCEF.setSiteSetting("", ${json(origin)}, "notifications", "allow").then(() => true);`);
    const post = async (title) => {
      const id = await run(`return S().newTab("w1", { url: ${json(url(title))} });`);
      await until(`${title} page`, `return S().tabs[${json(id)}]?.title === ${json(title)} || null;`, 15000);
      return id;
    };
    const deliver = async (title) => {
      const target = await app.page((t) => t.url === url(title), { timeout: 15000 });
      await target.eval(`new Notification(${json(title)}, { body: ${json(title)} }); true`);
      return until(`delivered ${title}`, `return globalThis.expo.modules.SolaraCEF.notificationDebugSnapshot().then((v) => v.hub?.delivered?.find((r) => r.title === ${json(title)}) ?? null);`, 15000);
    };
    await post("loud");
    const loudRow = await deliver("loud");
    const quiet = await post("quiet");
    await run(`S().setSiteMuted(${json(quiet)}, true); return true;`);
    await until("muted", `return S().tabs[${json(quiet)}].muted === true || null;`);
    const quietRow = await deliver("quiet");
    if (loudRow.sound !== true) throw new Error(`unmuted site delivered without sound: ${json(loudRow)}`);
    if (quietRow.sound !== false) throw new Error(`muted site delivered with sound: ${json(quietRow)}`);
    return { mode, loud: loudRow.sound, quiet: quietRow.sound, profile: quietRow.profile };
  });
} finally {
  if (app) await app.quit().catch(() => app.kill());
  server.close();
}
process.exit(rep.summary() ? 0 : 1);
