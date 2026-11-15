export const NATIVE_WORK_REVISION = 1;
export const ROW_COUNTERS = ["created", "bound", "reused", "live"];
export const WORK_COUNTERS = ["layoutApplications", "slotPublishes", "activeAnimationLinks", "liveSubscriptions", "deferredJobs", "pendingDeferredJobs"];
const count = (value, key) => {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`native work: invalid ${key}`);
};
const identity = (value, key) => {
  if (typeof value !== "string" || !value) throw new Error(`native work: missing ${key}`);
};

export function validateNativeWork(value) {
  if (value?.version !== NATIVE_WORK_REVISION) throw new Error(`native work: expected version ${NATIVE_WORK_REVISION}, received ${value?.version ?? "unavailable"}`);
  for (const key of ROW_COUNTERS) count(value.rows?.[key], `rows.${key}`);
  for (const key of WORK_COUNTERS) count(value[key], key);
  if (!Array.isArray(value.groups) || !Array.isArray(value.hosts)) throw new Error("native work: missing groups or hosts");
  const totals = Object.fromEntries(ROW_COUNTERS.map((key) => [key, 0]));
  const keys = new Set();
  for (const group of value.groups) {
    for (const key of ["windowId", "profileId", "kind"]) identity(group[key], key);
    const key = JSON.stringify([group.windowId, group.profileId, group.kind]);
    if (keys.has(key)) throw new Error("native work: duplicate group");
    keys.add(key);
    for (const metric of ROW_COUNTERS) { count(group[metric], metric); totals[metric] += group[metric]; }
  }
  for (const key of ROW_COUNTERS) if (totals[key] !== value.rows[key]) throw new Error(`native work: groups do not sum to rows.${key}`);
  for (const host of value.hosts) {
    identity(host.windowId, "host.windowId");
    identity(host.kind, "host.kind");
    count(host.count, "host.count");
  }
  return value;
}

export function nativeWorkCounts(value) {
  validateNativeWork(value);
  return Object.fromEntries([...ROW_COUNTERS.map((key) => [`rows.${key}`, value.rows[key]]), ...WORK_COUNTERS.map((key) => [key, value[key]])]);
}

export function sidebarWorkCounts(value, windowId) {
  validateNativeWork(value);
  const groups = value.groups.filter((group) => group.windowId === windowId && group.kind.startsWith("sidebar."));
  if (!groups.length) throw new Error(`native work: no sidebar counters for ${windowId}`);
  return Object.fromEntries(ROW_COUNTERS.map((key) => [key, groups.reduce((sum, group) => sum + group[key], 0)]));
}

export async function readNativeWork(app, reset = false) {
  const value = await app.eval(`const module = globalThis.expo.modules.SolaraWindowShell; if (!module || typeof module.nativeWork !== "function") throw new Error("native work counters unavailable in this build"); return module.nativeWork(${reset}).then(JSON.parse);`);
  return validateNativeWork(value);
}

const rectangle = (value, key) => {
  if (!Array.isArray(value) || value.length !== 4 || !value.every(Number.isFinite) || value[2] < 0 || value[3] < 0) throw new Error(`sidebar realization: invalid ${key}`);
};
const intersects = (frame, clip) => frame[2] > 0 && frame[3] > 0 && clip[2] > 0 && clip[3] > 0 && frame[0] < clip[0] + clip[2] && clip[0] < frame[0] + frame[2] && frame[1] < clip[1] + clip[3] && clip[1] < frame[1] + frame[3];

export function validateSidebarRealization(value, { settled = true } = {}) {
  const fail = (key) => { throw new Error(`sidebar realization: invalid ${key}`); };
  if (value?.enabled !== true) fail("enabled");
  rectangle(value.effectiveClip, "effectiveClip");
  for (const key of ["logical", "bound", "reuse"]) if (!Array.isArray(value[key])) fail(key);
  const logical = new Map();
  const expected = new Set();
  for (const item of value.logical) {
    for (const key of ["key", "kind", "region"]) if (typeof item[key] !== "string" || !item[key]) fail(`logical.${key}`);
    if (logical.has(item.key)) fail("duplicate logical key");
    rectangle(item.frame, `${item.key}.frame`);
    rectangle(item.clip, `${item.key}.clip`);
    if (item.presentation !== null) rectangle(item.presentation, `${item.key}.presentation`);
    logical.set(item.key, item);
    if (intersects(item.frame, item.clip) || item.presentation !== null && intersects(item.presentation, item.clip)) expected.add(item.key);
  }
  const keys = new Set();
  const allocations = new Set();
  const demand = new Map();
  for (const row of value.bound) {
    for (const key of ["key", "kind", "allocationId"]) if (typeof row[key] !== "string" || !row[key]) fail(`bound.${key}`);
    const picture = row.picture === true;
    if (row.picture !== undefined && typeof row.picture !== "boolean" || picture && row.retired !== true) fail(`picture ${row.key}`);
    if (!Number.isSafeInteger(row.token) || row.token < (picture ? 0 : 1) || typeof row.label !== "string" || typeof row.selected !== "boolean" || typeof row.active !== "boolean" || typeof row.retired !== "boolean") fail(`binding ${row.key}`);
    rectangle(row.frame, `${row.key}.bound.frame`);
    rectangle(row.clip, `${row.key}.bound.clip`);
    if (row.presentation !== null) rectangle(row.presentation, `${row.key}.bound.presentation`);
    if (keys.has(row.key) || allocations.has(row.allocationId)) fail("duplicate binding identity");
    keys.add(row.key);
    allocations.add(row.allocationId);
    if (!picture) demand.set(row.kind, (demand.get(row.kind) ?? 0) + 1);
    if (row.retired) {
      if (settled || row.presentation === null || !intersects(row.presentation, row.clip)) fail(`offscreen or settled retired ${row.key}`);
    } else {
      if (!expected.delete(row.key) || logical.get(row.key)?.kind !== row.kind) fail(`offscreen or mismatched binding ${row.key}`);
      const item = logical.get(row.key);
      if (row.frame.some((value, index) => Math.abs(value - item.frame[index]) > 0.5)) fail(`mismatched frame ${row.key}`);
      if (row.clip.some((value, index) => Math.abs(value - item.clip[index]) > 0.5)) fail(`mismatched clip ${row.key}`);
      if (!intersects(row.frame, row.clip) && (row.presentation === null || !intersects(row.presentation, row.clip))) fail(`invisible bound view ${row.key}`);
    }
  }
  if (expected.size) fail(`missing visible bindings ${[...expected].join(",")}`);
  const kinds = new Set();
  for (const bin of value.reuse) {
    if (typeof bin.kind !== "string" || !bin.kind || kinds.has(bin.kind)) fail("reuse.kind");
    kinds.add(bin.kind);
    for (const key of ["count", "highWater"]) if (!Number.isSafeInteger(bin[key]) || bin[key] < 0) fail(`reuse.${key}`);
    if (bin.count > bin.highWater || (demand.get(bin.kind) ?? 0) > bin.highWater) fail(`unbounded reuse ${bin.kind}`);
  }
  for (const kind of demand.keys()) if (!kinds.has(kind)) fail(`missing reuse bound ${kind}`);
  return value;
}

export async function readSidebarRealization(app, windowId, options) {
  const value = await app.eval(`const module = globalThis.expo.modules.SolaraHosted; if (!module || typeof module.sidebarRealization !== "function") throw new Error("native sidebar realization probe unavailable"); return module.sidebarRealization(${JSON.stringify(windowId)}).then(JSON.parse);`, { timeout: 5000 });
  if (!Array.isArray(value?.pages) || !value.pages.length) throw new Error("sidebar realization: missing profile pages");
  const profiles = new Set();
  for (const page of value.pages) {
    if (typeof page.profileId !== "string" || !page.profileId || profiles.has(page.profileId)) throw new Error("sidebar realization: missing or duplicate profile identity");
    profiles.add(page.profileId);
    validateSidebarRealization(page.realization, options);
  }
  return value;
}

export function validateWindowContract(value) {
  const fail = (field) => { throw new Error(`native layout contract: invalid ${field}`); };
  if (value?.ownerCount !== 1 || value?.hostCounts?.ShellHost !== 1) fail("owner count");
  for (const key of ["sidebar", "topStrip"]) if (!Number.isSafeInteger(value.hostCounts[key]) || value.hostCounts[key] < 0) fail(`hostCounts.${key}`);
  for (const key of ["bounds", "sidebar", "topStrip"]) {
    if (key !== "bounds" && value[key] === null) continue;
    if (!Array.isArray(value[key]) || value[key].length !== 4 || !value[key].every(Number.isFinite)) fail(key);
  }
  if (value.nativeLayout) {
    if (value.hostCounts.WindowLayoutController !== 1) fail("window controller count");
    if (value.controllerStoreSubscriptions !== 1 || value.childStoreSubscriptions !== 0 || value.legacyLayoutStoreSubscriptions !== 0) fail("layout store subscriptions");
  }
  if (!Array.isArray(value.slots) || !Array.isArray(value.pageIdentities)) fail("slots or page identities");
  for (const page of value.pageIdentities) if (typeof page.tabId !== "string" || !page.tabId || typeof page.identity !== "string" || !page.identity) fail("page identity");
  return value;
}

export function validateNativeWorkAppend(report, enabled) {
  if ((report.nativeWorkRevision !== undefined) !== enabled) throw new Error("native work: append requires the same native counter mode");
  if (enabled && (report.nativeWorkRevision !== NATIVE_WORK_REVISION || report.nativeWorkWindow !== "outerScenario")) throw new Error("native work: incompatible append revision or measurement window");
  const names = ["startup", "launch", "persistence", "idle", "typing", "switchTabs", "openClose", "scroll", "pageLoad", "hover", "profileSwipe", "storeUpdate", "idleLate"];
  for (const result of report.results) for (const name of names) {
    if (!result[name]) continue;
    if (enabled) validateNativeWork(result[name].nativeWork);
    else if (result[name].nativeWork !== undefined) throw new Error("native work: unstamped append contains native samples");
  }
}
