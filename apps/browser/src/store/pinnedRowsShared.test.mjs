import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const model = await import("./model.ts");
const { groupOf } = await import("./organize.ts");
const { togglePinnedRows, forgetListSpots } = await import("../components/sidebar/movePinned.ts");

const fixture = JSON.parse(readFileSync(new URL("../../../../native/SolaraKit/Tests/SolaraStoreTests/Cases/pinned-rows.json", import.meta.url), "utf8"));
const S = () => useBrowser.getState();
const host = (url) => /^https:\/\/(.*)\.com\/$/.exec(url ?? "")?.[1] ?? url;

function run(steps) {
  const refs = {};
  const ref = (value) => {
    if (typeof value === "string" && value.startsWith("$")) {
      assert.ok(value.slice(1) in refs, `unknown ${value}`);
      return refs[value.slice(1)];
    }
    if (Array.isArray(value)) return value.map(ref);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, ref(v)]));
    return value;
  };
  const hosts = (w, keep) => S().windows[w].tabIds.filter((id) => keep(S().tabs[id])).map((id) => host(S().tabs[id].url));
  for (const step of steps) {
    if (step.window) {
      const w = S().createWindow({ url: `https://${step.window[0]}.com/` });
      const ids = [S().windows[w].tabIds[0]];
      for (const h of step.window.slice(1)) ids.push(S().newTab(w, { url: `https://${h}.com/` }));
      S().activate(ids[0]);
      refs[step.as] = w;
      step.window.forEach((h, i) => { refs[h] ??= ids[i]; });
    } else if (step.group) refs[step.as] = S().groupTabs(ref(step.group), { pinned: false });
    else if (step.rowIn) refs[step.as] = S().windows[ref(step.rowIn)].tabIds.find((id) => S().tabs[id].pinnedAsRow);
    else if (step.tabs) for (const h of step.tabs) refs[h] = S().newTab(ref(step.in), { url: `https://${h}.com/` });
    else if (step.call) {
      const result = S()[step.call](...ref(step.args));
      if (step.as) refs[step.as] = result;
    }
    else if (step.toggle) togglePinnedRows(ref(step.toggle));
    else if (step.expect) {
      const e = step.expect;
      for (const [w, want] of Object.entries(e.rows ?? {})) assert.deepEqual(hosts(ref(w), (t) => model.isPinnedRow(t)), want, `rows of ${w}`);
      for (const [w, want] of Object.entries(e.list ?? {})) assert.deepEqual(hosts(ref(w), (t) => !t.pinned), want, `list of ${w}`);
      for (const [g, want] of Object.entries(e.groupTabs ?? {})) assert.deepEqual(S().groups[ref(g)]?.tabIds, ref(want), `tabs of ${g}`);
      for (const [t, want] of Object.entries(e.pinned ?? {})) assert.equal(S().tabs[ref(t)].pinned, want, `${t} pinned`);
      for (const [t, want] of Object.entries(e.grouped ?? {})) assert.equal(!!groupOf(S(), ref(t)), want, `${t} grouped`);
    } else assert.fail(`unknown step ${JSON.stringify(step)}`);
  }
}

for (const c of fixture.cases) {
  test(`Move to Pinned (shared with Swift): ${c.name}`, () => {
    S().hydrate({});
    S().updateSettings({ newTabOpens: "page", newTabPosition: "bottom", cmdClickCreatesTabGroup: false });
    forgetListSpots();
    run(c.steps);
  });
}
