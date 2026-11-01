import type { BrowserSource, DiaAutomationStatus, DiaTabsResult, ImportedExtension, ImportKind, ImportResult } from "@solara/import";
import { closeWindow, confirm } from "@solara/shell";
import { publishSettingsTopic, type SettingsHandler } from "@solara/settings";
import { allArcHolders, restoreArcFolders } from "../../../lib/bookmarkGroups";
import { nativeSafeMode } from "../../../store/nativeStore";
import { useBrowser } from "../../../store/browser";
import { MAX_DRAFT_LINKS } from "../../../store/draftGroups";
import { plural } from "../../../store/model";
import type { ProfileColor } from "../../../store/types";
import { useOnboarding } from "../../onboarding/state";
import { applyResult, applySafari, emptyCounts, importArcSpace, importBookmarks, importDiaProfile, openInWebStore, profileColorFor, transientImportRefused, type ImportCounts } from "../../import/apply";
import { importModule } from "../../import/module";
import { IMPORT_WINDOW_ID, takePreferredImportSource } from "../windows";

type Status = "pending" | "active" | "done" | "failed";

type RunRequest = {
  runId: string;
  browserId: string;
  profileIds: string[];
  spaceIds: string[];
  kinds: ImportKind[];
  target: string;
  withoutKey: boolean;
};

const KIND_ORDER: ImportKind[] = ["bookmarks", "history", "passwords", "cookies", "autofill", "tabs", "spaces", "pinnedTabs", "favorites"];

const session: { browsers: BrowserSource[]; abort: AbortController | null; dia: DiaTabsResult | null; diaLaunched: number } = {
  browsers: [],
  abort: null,
  dia: null,
  diaLaunched: 0,
};

const codeOf = (e: unknown) => (e as { code?: string }).code;

function defaultTarget(): string {
  const s = useBrowser.getState();
  const w = s.windows[s.ui.focusedWindowId ?? ""];
  return w && !w.incognito ? w.profileId : s.settings.defaultProfileId;
}

function targets() {
  const s = useBrowser.getState();
  return s.profileOrder.flatMap((id) => {
    const p = s.profiles[id];
    return p ? [{ id: p.id, name: p.name }] : [];
  });
}

async function destination(target: string, index: number, name: string, color?: string, emoji?: string, shareWith?: string | null): Promise<string> {
  if (index === 0) return target;
  const s = useBrowser.getState();
  const clash = s.profileOrder.find((id) => s.profiles[id]!.name.trim().toLowerCase() === name.trim().toLowerCase());
  if (clash) {
    const { confirmed } = await confirm({
      title: "Import as new profile?",
      message:
        "Import this data as a new profile to avoid data loss. If you replace a profile, your passwords, cookies, and payment info will be replaced, while your bookmarks and history will be combined.",
      confirmTitle: "Import as new profile",
      cancelTitle: "Replace this profile",
    });
    if (!confirmed) return clash;
  }
  return s.createProfile({ name, color: profileColorFor(color) as ProfileColor | undefined, icon: emoji ?? null, shareWith });
}

async function run(req: RunRequest) {
  const api = importModule();
  const source = session.browsers.find((b) => b.id === req.browserId);
  if (!api || !source) return { cancelled: true };
  const bySpaces = !!source.sidebar;
  const selected = source.profiles.filter((p) => req.profileIds.includes(p.id) || (bySpaces && p.spaces?.some((s) => req.spaceIds.includes(s.id))));
  const transient = new Set<ImportKind>(["tabs", "spaces", "pinnedTabs", "favorites"]);
  const refused = nativeSafeMode() ? req.kinds.filter((k) => selected.length > 1 || transient.has(k)) : [];
  if (refused.length) transientImportRefused();
  if (nativeSafeMode() && selected.length > 1) return {
    status: Object.fromEntries(refused.map((kind) => [kind, "failed"])),
    failures: refused.map((kind) => ({ kind, profiles: selected.map((p) => p.name) })),
    counts: emptyCounts(), notes: ["Import one source profile into an existing profile in safe mode."],
  };
  const tabsLocked = (p: (typeof selected)[number]) => req.withoutKey && !!p.tabsNeedKey;
  const requested: ImportKind[] = req.kinds.filter((k) => !refused.includes(k)).filter((k) => k !== "tabs" || !selected.every(tabsLocked));
  if (bySpaces && requested.includes("tabs")) requested.push("spaces", "pinnedTabs");
  const order = KIND_ORDER.filter((k) => requested.includes(k));
  const progress = {
    runId: req.runId,
    preparing: bySpaces ? Math.max(1, req.spaceIds.length) : selected.length,
    status: Object.fromEntries([...order.map((k) => [k, "pending"]), ...refused.map((k) => [k, "failed"])]) as Partial<Record<ImportKind, Status>>,
  };
  const setStatus = (kind: ImportKind, next: (current: Status | undefined) => Status) => {
    progress.status = { ...progress.status, [kind]: next(progress.status[kind]) };
    publishSettingsTopic("import.progress", progress);
  };
  publishSettingsTopic("import.progress", progress);
  session.abort?.abort();
  const abort = new AbortController();
  session.abort = abort;
  const total = emptyCounts();
  const failed = new Map<ImportKind, string[]>(refused.map((k) => [k, selected.map((p) => p.name)]));
  const add = (c: ImportCounts) => (Object.keys(total) as (keyof ImportCounts)[]).forEach((k) => (total[k] += c[k]));
  let destinationIndex = 0;
  let activeProfileIndex = 0;
  const found = new Map<string, ImportedExtension>();
  const left: string[] = [];
  let extensionsProfile = "";
  if (source.family === "firefox" && requested.includes("passwords") && !api.isBrowserUnlocked(source.id)) {
    await api.unlockBrowser(source.id).catch(() => {});
  }

  try {
    for (const [profileIndex, profile] of selected.entries()) {
      activeProfileIndex = profileIndex;
      let result: ImportResult;
      const profileKinds = tabsLocked(profile) ? order.filter((k) => k !== "tabs") : order;
      try {
        result = await api.importData(source.id, profile.id, profileKinds, {
          spaceIds: bySpaces ? req.spaceIds : undefined,
          signal: abort.signal,
          onProgress: (p) => {
            if (p.phase === "start") setStatus(p.kind, () => "active");
            if (p.phase === "end") setStatus(p.kind, (current) => (current === "failed" ? current : "done"));
          },
        });
      } catch (e) {
        if (codeOf(e) === "cancelled") return { cancelled: true };
        for (const k of profileKinds) failed.set(k, [...(failed.get(k) ?? []), profile.name]);
        continue;
      }
      for (const k of result.failed) failed.set(k, [...(failed.get(k) ?? []), profile.name]);
      for (const w of result.warnings) {
        if (["undecryptable", "skipped", "locked"].includes(w.code) && !result.failed.includes(w.kind!)) left.push(`${w.message}.`);
      }
      const refused = (k: ImportKind) => {
        const names = failed.get(k) ?? [];
        if (!names.includes(profile.name)) failed.set(k, [...names, profile.name]);
      };

      if (bySpaces) {
        let first: string | null = null;
        for (const space of result.spaces) {
          const name = space.name || "Space";
          const dest = await destination(req.target, destinationIndex++, name, space.color, space.emoji, first);
          first ??= dest;
          const r = importArcSpace(dest, space, result.favicons);
          add({ ...emptyCounts(), tabs: r.tabs, bookmarks: r.bookmarks });
          if (r.skipped) left.push(`${plural(r.skipped, "link")} in ${name}'s folders weren't imported: each folder brings up to ${MAX_DRAFT_LINKS.toLocaleString("en-US")} links.`);
        }
        const dest = first ?? (await destination(req.target, destinationIndex++, result.profile?.name ?? profile.name, result.profile?.color));
        add(await applyResult(dest, result, source.name, profileKinds, refused));
        extensionsProfile ||= dest;
      } else {
        const dest = await destination(req.target, destinationIndex++, result.profile?.name ?? profile.name, result.profile?.color ?? profile.color);
        add(await applyResult(dest, result, source.name, profileKinds, refused));
        extensionsProfile ||= dest;
      }
      if (source.family === "chromium" || source.family === "arc") {
        for (const e of await api.listExtensions(source.id, profile.id).catch(() => [])) found.set(e.id, e);
      }
    }
    const status = Object.fromEntries(
      Object.entries(progress.status).map(([k, v]) => [k, failed.has(k as ImportKind) ? "failed" : v === "failed" ? v : "done"]),
    );
    return {
      status,
      failures: [...failed].map(([kind, names]) => ({ kind, profiles: selected.length > 1 ? names : [] })),
      counts: total,
      notes: left,
      extensions: {
        profileId: extensionsProfile,
        list: [...found.values()].map((e) => ({ id: e.id, name: e.name, webStoreUrl: e.webStoreUrl })),
      },
    };
  } catch (error) {
    const remaining = selected.slice(activeProfileIndex).map((p) => p.name);
    for (const kind of order) failed.set(kind, [...new Set([...(failed.get(kind) ?? []), ...remaining])]);
    return {
      status: Object.fromEntries(Object.keys(progress.status).map((kind) => [kind, "failed"])),
      failures: [...failed].map(([kind, profiles]) => ({ kind, profiles })),
      counts: total,
      notes: [...left, error instanceof Error ? error.message : String(error)],
      extensions: {
        profileId: extensionsProfile,
        list: [...found.values()].map((e) => ({ id: e.id, name: e.name, webStoreUrl: e.webStoreUrl })),
      },
    };
  } finally {
    if (session.abort === abort) session.abort = null;
    api.forgetUnlockedKeys();
  }
}

async function readDia() {
  const api = importModule();
  if (!api) return { error: { code: "unavailable", message: "Importing isn't available" } };
  let result: DiaTabsResult;
  try {
    result = await api.readDiaTabs();
    for (let i = 0; !result.windowCount && Date.now() - session.diaLaunched < 15_000 && i < 8; i++) {
      await new Promise((r) => setTimeout(r, 1500));
      result = await api.readDiaTabs();
    }
  } catch (e) {
    return { error: { code: codeOf(e) ?? "unreadable", message: (e as Error).message } };
  }
  session.dia = result;
  return {
    windowCount: result.windowCount,
    profiles: result.profiles.map((p) => ({ id: p.id, name: p.name, pinned: p.pinned.length, tabs: p.tabs.length })),
  };
}

async function runDia(req: { profileIds: string[]; target: string; pinned: boolean; open: boolean }) {
  const total = emptyCounts();
  const kinds: ImportKind[] = [...(req.open ? ["tabs" as const] : []), ...(req.pinned ? ["pinnedTabs" as const] : [])];
  const result = session.dia;
  const selected = result?.profiles.filter((p) => req.profileIds.includes(p.id)) ?? [];
  let activeProfileIndex = 0;
  try {
    if (transientImportRefused()) throw new Error("Tab import is unavailable in safe mode.");
    if (!result) throw new Error("Read Dia's tabs again before importing.");
    for (const [i, p] of selected.entries()) {
      activeProfileIndex = i;
      const dest = await destination(req.target, i, p.name);
      total.tabs += importDiaProfile(dest, p, { pinned: req.pinned, open: req.open }, result.favicons);
    }
    return { counts: total, status: Object.fromEntries(kinds.map((kind) => [kind, "done"])), failures: [], notes: [] };
  } catch (error) {
    return {
      counts: total,
      status: Object.fromEntries(kinds.map((kind) => [kind, "failed"])),
      failures: kinds.map((kind) => ({ kind, profiles: selected.slice(activeProfileIndex).map((p) => p.name) })),
      notes: [error instanceof Error ? error.message : String(error)],
    };
  }
}

async function safariExport(path: string, target: string) {
  const api = importModule();
  if (!api) return { error: "unavailable" };
  try {
    const data = await api.importSafariExport(path);
    const failed: ImportKind[] = [];
    const counts = await applySafari(target, data, false, (k) => failed.push(k));
    return { counts, failed };
  } catch (e) {
    return { error: codeOf(e) === "unsupported" ? "unsupported" : "invalid" };
  }
}

async function safariDirect(target: string, cookies: boolean) {
  const api = importModule();
  if (!api) return { error: "unavailable" };
  session.abort?.abort();
  const abort = new AbortController();
  session.abort = abort;
  try {
    const data = await api.importSafariDirect({ signal: abort.signal });
    const failed: ImportKind[] = [];
    const counts = await applySafari(target, data, cookies, (k) => failed.push(k));
    return { counts, failed };
  } catch (e) {
    if (codeOf(e) === "cancelled") return { cancelled: true };
    return { error: codeOf(e) === "locked" ? "locked" : "unreadable" };
  } finally {
    if (session.abort === abort) session.abort = null;
  }
}

async function bookmarksHtml(target: string) {
  const api = importModule();
  if (!api) return { cancelled: true };
  const path = await api.chooseImportFile("bookmarksHTML");
  if (!path) return { cancelled: true };
  try {
    const root = await api.importBookmarksHTML(path);
    return { counts: { ...emptyCounts(), bookmarks: importBookmarks(target, root, "HTML File") }, failed: [] };
  } catch {
    return { error: "invalid" };
  }
}

function dispose() {
  session.abort?.abort();
  session.abort = null;
  session.dia = null;
  importModule()?.forgetUnlockedKeys();
}

const diaStatus = (status: Promise<DiaAutomationStatus> | undefined) => (status ?? Promise.resolve("denied" as const)).catch((): DiaAutomationStatus => "denied");

export const importHandlers: Record<string, SettingsHandler> = {
  "import.open": () => ({ available: !!importModule(), preferred: takePreferredImportSource(), targets: targets(), defaultTarget: defaultTarget() }),
  "import.listBrowsers": async () => {
    const api = importModule();
    if (!api) return null;
    const list = await api.listBrowsers().catch(() => null);
    if (list) session.browsers = list;
    return list;
  },
  "import.safariFullDiskAccess": () => importModule()?.safariHasFullDiskAccess() ?? false,
  "import.isUnlocked": (browserId: string) => importModule()?.isBrowserUnlocked(browserId) ?? false,
  "import.unlock": (browserId: string) => {
    const api = importModule();
    return api ? api.unlockBrowser(browserId).then(() => true, () => false) : false;
  },
  "import.run": (req: RunRequest) => run(req),
  "import.cancel": () => session.abort?.abort(),
  "import.dispose": () => dispose(),
  "import.diaStatus": () => diaStatus(importModule()?.diaAutomationStatus()),
  "import.requestDia": () => diaStatus(importModule()?.requestDiaAutomation()),
  "import.openDia": async () => {
    const api = importModule();
    if (!api) return false;
    session.diaLaunched = Date.now();
    return api.openDia().then(() => true, () => false);
  },
  "import.readDia": () => readDia(),
  "import.runDia": (req: { profileIds: string[]; target: string; pinned: boolean; open: boolean }) => runDia(req),
  "import.safariExport": (path: string, target: string) => safariExport(path, target),
  "import.safariDirect": (target: string, cookies: boolean) => safariDirect(target, cookies),
  "import.bookmarksHtml": (target: string) => bookmarksHtml(target),
  "import.chooseFile": (kind: "safariExport" | "bookmarksHTML") => importModule()?.chooseImportFile(kind) ?? null,
  "import.openFullDiskAccessSettings": () => importModule()?.openFullDiskAccessSettings(),
  "import.openAutomationSettings": () => importModule()?.openAutomationSettings(),
  "import.openInWebStore": (profileId: string, urls: string[]) => openInWebStore(profileId, urls),
  "import.arcHolders": () => allArcHolders(useBrowser.getState()).length,
  "import.restoreArcFolders": () => {
    if (transientImportRefused()) return allArcHolders(useBrowser.getState()).length;
    for (const id of allArcHolders(useBrowser.getState())) restoreArcFolders(id, null);
    return allArcHolders(useBrowser.getState()).length;
  },
  "import.onboarding": () => useOnboarding.getState().windowId !== null,
  "import.close": () => closeWindow(IMPORT_WINDOW_ID),
};

let lastTargets: string | null = null;

function publishTargets() {
  const list = targets();
  const json = JSON.stringify(list);
  if (json === lastTargets) return;
  lastTargets = json;
  publishSettingsTopic("import.targets", list);
}

export function publishImport(): void {
  publishTargets();
  useBrowser.subscribe((s, prev) => {
    if (s.profiles !== prev.profiles || s.profileOrder !== prev.profileOrder) publishTargets();
  });
}
