import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

let nativePollDeadline = null;
const evaluate = (body, options = {}) => {
  if (nativePollDeadline !== null && nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms left");
  return app.eval(body, { ...options, ...(nativePollDeadline === null ? {} : { timeout: 1000 }) });
};
const acceptSnapshot = async (deadline, accept, ...args) => {
  const previous = nativePollDeadline;
  nativePollDeadline = previous === null ? deadline : Math.min(previous, deadline);
  try {
    return await accept(...args);
  } finally {
    nativePollDeadline = previous;
  }
};

const [appArg, port] = process.argv.slice(2);
if (!appArg) {
  console.error("usage: node hover-shift-test.mjs <Debug Solara.app> [cdpPort]");
  process.exit(2);
}
const pass = "native";
const scratch = mkdtempSync(join(tmpdir(), "ac-hover-shift-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "hover-shift-test.log"), { name: `hover-shift-test ${pass}` });
const file = join(data, "report.pdf");

const ids = ["pin1", "pin2", "a1", "a2", "a3", "b1", "b2", ...Array.from({ length: 12 }, (_, i) => `t${i}`)];
const tab = (id) => {
  const pinned = id.startsWith("pin");
  return { id, url: `https://example.com/?${id}`, title: `Tab ${id} with a title long enough to fade`, pinned,
    pinnedUrl: pinned ? `https://example.com/?${id}` : null };
};

let app;
try {
  app = await launch(resolve(appArg), {
    data, port, files: { "report.pdf": "%PDF-1.4\n" },
    session: session({ profiles: ["Personal", "Work"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t2" } }], tabs: ids.map(tab) }),
    ready: "return !!ac.hoverShift",
  });
  const ac = (body) => evaluate(body, { timeout: 120000 });
  const untilSnapshot = async (what, accept, ms = 8000, args = {}) => {
    const end = Date.now() + ms;
    let last;
    while (Date.now() < end) {
      if (!app.alive) throw new Error(`${what}: app exited`);
      if (Math.min(end, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
      last = await app.snapshot({ windowId: "w1", ...args }, { timeout: 1000 });
      assert.equal(last.schema, 1);
      if (Date.now() < end && last.consistent && await acceptSnapshot(end, accept, last) && Date.now() < end) return last;
      await sleep(60);
    }
    throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
  };
  const hoverNative = async (area, expected) => {
    const first = await untilSnapshot(`${area} hover targets`, (s) => s.windows[0]?.hoverLayout?.targets?.length > 0, 8000, { hoverArea: area });
    const targets = first.windows[0].hoverLayout.targets;
    assert.equal(targets.length, expected, "native/JS hovered target count");
    assert.ok(targets.length <= 128, "bounded hover targets");
    if (area === "downloads") assert.ok(first.windows[0].hoverLayout.hosts > 0, "native downloads host is shown");
    let moved = 0;
    for (const target of targets) {
      const before = await app.snapshot({ windowId: "w1", hoverArea: area }, { timeout: 1000 });
      assert.equal(before.consistent, true);
      const input = await app.probe("input.hover", { windowId: "w1", area, target, on: true });
      assert.equal(input.delivered, true);
      try {
        const during = await app.snapshot({ windowId: "w1", hoverArea: area }, { timeout: 1000 });
        assert.equal(during.consistent, true);
        const a = before.windows[0].hoverLayout, b = during.windows[0].hoverLayout;
        const duringFrames = new Map(b.frames.map((frame) => [frame.id, frame]));
        for (const was of a.frames) {
          const now = duringFrames.get(was.id);
          if (!now) continue;
          const wasGeometry = was.frame ?? was.origin, nowGeometry = now.frame ?? now.origin;
          assert.equal(wasGeometry.length, nowGeometry.length);
          const changed = wasGeometry.some((v, j) => Math.abs(v - nowGeometry[j]) > 0.01);
          const labelMakesRoom = area === "downloads" && was.label && was.frame.slice(0, 2).every((v, j) => Math.abs(v - now.frame[j]) <= 0.01) && Math.abs(was.frame[3] - now.frame[3]) <= 0.01 && now.frame[2] < was.frame[2];
          if (changed && !labelMakesRoom) moved++;
        }
      } finally {
        assert.equal((await app.probe("input.hover", { windowId: "w1", area, target, on: false })).delivered, true);
      }
    }
    assert.equal(moved, 0, `${area}: native element frames stay fixed through hover`);
    return moved;
  };
  const nativeDownloadShifts = async () => {
    const r = JSON.parse(await ac(`return globalThis.expo.modules.SolaraDownloads.devHoverShifts();`));
    if (!r.hosts) throw new Error("the native downloads list isn't shown");
    return { hovered: r.hovered, shifts: r.shifts, forced: r.forced ?? null };
  };

  await ac(`
    const s = ac.store.getState();
    s.createGroup(["a1", "a2", "a3"], { name: "Open group" });
    const shut = s.createGroup(["b1", "b2"], { name: "Shut group", color: "blue" });
    s.updateGroup(shut, { collapsed: true });
    const { store, engine } = ac.live;
    const pr = (n, extra) => ({ number: n, repo: "solara/app", author: "a", authorAvatar: null, draft: false, headRef: "h" + n, baseRef: "main",
      review: null, mergeable: "mergeable", checks: [], comments: 0, unresolvedThreads: 0, additions: 1, deletions: 1, changedFiles: 1, ...extra });
    const item = (n, extra) => ({ id: "pr" + n, source: "github", url: "https://example.com/pr/" + n, title: "Pull request " + n + " with a long title",
      subtitle: "", icon: null, updatedAt: Date.now() - n, section: "authored", pr: pr(n, extra) });
    const items = [item(1, { review: "approved" }), item(2, {}), item(3, { mergeable: "conflicting" })];
    s.upsertDownload({ id: "d1", url: "https://example.com/report.pdf", filename: "report.pdf", path: ${JSON.stringify(file)},
      state: "finished", paused: false, received: 9, total: 9, speed: 0, mimeType: "application/pdf" });
    s.setDownloadsOpen("w1", false);
    return store.createFolder("default", "pullRequests").then((folder) =>
      store.applyFetch(folder, items, {})
        .then(() => store.setStatus(folder, { state: "idle", lastFetch: Date.now(), error: null }))
        .then(() => {
          engine.openLiveItem("w1", folder, items[1], { background: true });
          engine.openLiveItem("w1", folder, items[2], { background: true });
          return true;
        }));
  `);
  await sleep(1500);

  const surfaces = [
    ["sidebar", `ac.store.getState().updateSettings({ tabLayout: "sidebar" });`, ["Sidebar"]],
    ["tab strip", `ac.store.getState().updateSettings({ tabLayout: "top" });`, ["TopTabStrip"]],
    ["downloads", `ac.store.getState().updateSettings({ tabLayout: "sidebar" }); ac.store.getState().setDownloadsOpen("w1", true);`, ["DownloadsPopover"]],
  ];
  for (const [name, setup, scopes] of surfaces) {
    await rep.check(name, async () => {
      await ac(`${setup} return true;`);
      await sleep(1200);
      const native = name === "sidebar";
      const nativeStrip = name === "tab strip" && (await ac(`return globalThis.expo.modules.SolaraHosted.kinds().includes("topStrip");`));
      const nativeDownloads = name === "downloads" && (!!JSON.parse(await ac(`return globalThis.expo.modules.SolaraDownloads.devHoverShifts();`)).hosts);
      const capabilitySnapshot = await untilSnapshot("hosted hover capabilities", async (s) => {
        if (!Array.isArray(s.hostedKinds)) return false;
        if (native) return s.hostedKinds.includes("sidebar") === await ac(`return globalThis.expo.modules.SolaraHosted.kinds().includes("sidebar");`) && s.hostedKinds.includes("sidebar");
        if (name === "tab strip") return s.hostedKinds.includes("topStrip") === await ac(`return globalThis.expo.modules.SolaraHosted.kinds().includes("topStrip");`) && s.hostedKinds.includes("topStrip") === nativeStrip;
        return true;
      });
      if (name === "sidebar") assert.equal(capabilitySnapshot.hostedKinds.includes("sidebar"), native);
      if (name === "tab strip") assert.equal(capabilitySnapshot.hostedKinds.includes("topStrip"), nativeStrip);
      const { hovered, shifts, forced = null } = nativeDownloads
        ? await nativeDownloadShifts()
        : native
        ? await ac(`return globalThis.expo.modules.SolaraHosted.sidebarHoverShifts("w1").then((json) => JSON.parse(json)).then((r) => ({ hovered: r.hovered, shifts: r.shifts.map((s) => ({ hovered: s, view: "native row", before: [], after: [] })) }));`)
        : nativeStrip
        ? await ac(`return globalThis.expo.modules.SolaraTopStrip.hoverShifts("w1").then((json) => JSON.parse(json)).then((r) => ({ hovered: r.hovered.length, shifts: r.shifts.map((s) => ({ hovered: s, view: "native strip item", before: [], after: [] })) }));`)
        : await ac(`return ac.hoverShift.check({ scopes: ${JSON.stringify(scopes)} });`);
      if (!hovered) throw new Error("nothing hover-tracked found");
      if (native || nativeStrip || nativeDownloads) {
        const area = nativeDownloads ? "downloads" : native ? "sidebar" : "topStrip";
        const nativeMoved = await hoverNative(area, hovered);
        assert.equal(nativeMoved, shifts.length, "native/JS hover shift count");
      }
      if (shifts.length) {
        throw new Error([`${shifts.length} views moved or resized (${hovered} hovered)`,
          ...shifts.slice(0, 20).flatMap((s) => [`hovering ${s.hovered}`, `  ${s.view}: ${s.before.join(", ")} -> ${s.after.join(", ")}`])].join("\n"));
      }
      if (forced) rep.say(`${name}: hover tracking areas installed by the check (forced: ${forced})`);
      return `${hovered} hovered views, nothing moved${forced ? ` (forced: ${forced})` : ""}`;
    });
  }
} catch (error) {
  rep.record("setup", { error });
} finally {
  await app?.quit();
  rmSync(data, { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);
