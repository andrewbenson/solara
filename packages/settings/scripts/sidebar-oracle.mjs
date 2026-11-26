import assert from "node:assert/strict";

export function compare(actual, expected, name = "snapshot") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", name);
    assert.ok(Math.abs(actual - expected) <= 1e-12, `${name}: ${actual} != ${expected}`);
  } else if (expected && typeof expected === "object") {
    assert.ok(actual && typeof actual === "object", name);
    assert.equal(Array.isArray(actual), Array.isArray(expected), name);
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort(), name);
    for (const key of Object.keys(expected)) compare(actual[key], expected[key], `${name}.${key}`);
  } else assert.equal(actual, expected, name);
}

export function canonical(raw) {
  const ids = raw.profileOrder;
  const profile = (id) => {
    const index = ids.indexOf(id);
    assert.ok(index >= 0, `unknown profile ${id}`);
    return `p${index}`;
  };
  const windows = raw.windowOrder.map((id) => raw.windows[id]);
  const tabIds = windows.flatMap((w) => w.tabIds);
  assert.equal(new Set(tabIds).size, tabIds.length);
  const tab = (id) => { const n = tabIds.indexOf(id); assert.ok(n >= 0, `missing tab ${id}`); return `t${n}`; };
  const groupIds = Object.keys(raw.groups).sort((a, b) => {
    const first = (id) => Math.min(...raw.groups[id].tabIds.map((t) => tabIds.indexOf(t)));
    const depth = (id, seen = new Set()) => { assert.ok(!seen.has(id), "cyclic groups"); seen.add(id); return raw.groups[id].parentId ? 1 + depth(raw.groups[id].parentId, seen) : 0; };
    return first(a) - first(b) || depth(a) - depth(b) || raw.groups[a].name.localeCompare(raw.groups[b].name);
  });
  const group = (id) => { const n = groupIds.indexOf(id); assert.ok(n >= 0); return `g${n}`; };
  const engine = (p) => raw.profiles[p].dataId ?? p;
  const classes = ids.map((p) => ids.findIndex((other) => engine(other) === engine(p)));
  return {
    profiles: ids.map((id, i) => ({ id: profile(id), name: raw.profiles[id].name, color: raw.profiles[id].color, icon: raw.profiles[id].icon ?? null, dataClass: classes[i], theme: raw.profiles[id].theme ?? null, fileTheme: raw.profiles[id].fileTheme ?? null })),
    windows: windows.map((w) => ({ profile: profile(w.profileId), incognito: !!w.incognito, isSmall: !!w.isSmall, tabs: w.tabIds.map(tab), active: Object.fromEntries(Object.entries(w.activeTabIds).map(([p, t]) => [profile(p), tab(t)])) })),
    tabs: tabIds.map((id) => { const t = raw.tabs[id]; return { id: tab(id), profile: profile(t.profileId), url: t.url, title: t.title, customTitle: t.customTitle ?? null, pinned: !!t.pinned, row: t.pinnedAsRow === true, pinnedUrl: t.pinnedUrl ?? null, unloaded: t.unloaded === true, navigation: t.navigation ?? null }; }),
    groups: groupIds.map((id) => { const g = raw.groups[id]; return { id: group(id), profile: profile(g.profileId), name: g.name, pinned: g.pinned, parent: g.parentId ? group(g.parentId) : null, members: g.tabIds.map(tab), collapsed: g.collapsed }; }),
    splits: Object.values(raw.splits).map((s) => ({ tabs: s.tabIds.map(tab), orientation: s.orientation, sizes: s.sizes })),
    parked: ids.map((id, p) => {
      const value = raw.parkedPins[id];
      if (!value) return { profile: profile(id), tabs: [], groups: [], splits: [] };
      const groupIds = value.groups.map((g) => g.id), parkedIds = value.tabs.map((t) => t.id);
      const group = (id) => { const index = groupIds.indexOf(id); assert.ok(index >= 0); return `park${p}g${index}`; };
      return {
        profile: profile(id),
        tabs: value.tabs.map(({ id, groupId, restoreFrom, ...t }, i) => ({ ...t, id: `park${p}t${i}`, profileId: profile(t.profileId), groupId: groupId ? group(groupId) : null, restoreFrom: restoreFrom ? "restore" : null })),
        groups: value.groups.map(({ id, parentId, ...g }) => ({ ...g, id: group(id), parentId: parentId ? group(parentId) : null })),
        splits: (value.splits ?? []).map((split) => ({ ...split, ids: split.ids.map((id) => { const index = parkedIds.indexOf(id); assert.ok(index >= 0); return `park${p}t${index}`; }) })),
      };
    }),
    bookmarks: ids.map((id) => raw.bookmarks[id]),
    history: ids.map((id) => raw.history[id]),
    cache: ids.map((id) => raw.cache[id]),
    nativeIcons: ids.map((id) => raw.nativeIcons[id]),
    live: raw.live.map((f) => ({ ...f, profile: profile(f.profile) })),
    adoption: raw.adoption,
  };
}

export function facts(snapshot) {
  const groups = new Map(snapshot.groups.map((g) => [g.id, g]));
  const groupPath = (g) => g.parent ? `${groupPath(groups.get(g.parent))}/${g.name}` : g.name;
  return {
    profiles: snapshot.profiles.map(({ name, color, icon, dataClass, theme, fileTheme }) => ({ name, color, icon, dataClass, theme, fileTheme })),
    tabs: snapshot.tabs.filter((t) => !t.url.startsWith("about:blank")).map((t) => ({ profile: t.profile, url: t.url, title: t.title, customTitle: t.customTitle, pinned: t.pinned, row: t.row, pinnedUrl: t.pinnedUrl, unloaded: t.unloaded, navigation: t.navigation, groups: snapshot.groups.filter((g) => g.members.includes(t.id)).map(groupPath) })).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
    parked: snapshot.parked.map((p) => p.tabs.map((t) => ({ url: t.url, title: t.title, profile: t.profileId, pinned: t.pinned, row: t.pinnedAsRow === true, pinnedUrl: t.pinnedUrl ?? null }))),
    groups: snapshot.groups.map((g) => ({ profile: g.profile, path: groupPath(g), pinned: g.pinned, members: g.members.map((id) => snapshot.tabs.find((t) => t.id === id).url) })),
    windows: snapshot.windows.map((w) => ({ incognito: w.incognito, isSmall: w.isSmall })),
    bookmarks: snapshot.bookmarks,
    history: snapshot.history,
    cachePages: snapshot.cache.map((pages) => Object.keys(pages).filter((p) => /^https?:/.test(p)).sort()),
    nativeIconPages: snapshot.nativeIcons.map((pages) => Object.keys(pages).sort()),
    live: snapshot.live,
    adoption: snapshot.adoption,
  };
}
