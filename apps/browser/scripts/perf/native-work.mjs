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

export async function readNativeWork(app, reset = false) {
  const value = await app.eval(`const module = globalThis.expo.modules.SolaraWindowShell; if (!module || typeof module.nativeWork !== "function") throw new Error("native work counters unavailable in this build"); return module.nativeWork(${reset}).then(JSON.parse);`);
  return validateNativeWork(value);
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
