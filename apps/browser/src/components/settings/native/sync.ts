import { publishSettingsTopic, type SettingsHandler } from "@solara/settings";
import { SyncNative } from "@solara/sync";
import { profileAccent } from "../../../lib/theme";
import { useBrowser } from "../../../store/browser";
import {
  addRemoteProfile,
  chooseSyncFolder,
  DATA_TYPES,
  enterRecoveryPhrase,
  folderInfo,
  resolveHeldPasswords,
  setProfileSynced,
  setTypeSynced,
  stopSync,
  syncNow,
  turnOnSync,
  useSync,
} from "../../../sync/engine";

type DataType = (typeof DATA_TYPES)[number]["id"];

function syncTopic() {
  const sync = useSync.getState();
  const { profiles, profileOrder } = useBrowser.getState();
  return {
    status: sync.status,
    enabled: sync.enabled,
    folder: sync.folder,
    types: sync.types,
    lastSyncedAt: sync.lastSyncedAt,
    error: sync.error,
    pending: sync.pending,
    devices: sync.devices.map((d) => ({ id: d.id, name: d.name, lastSeen: d.lastSeen, current: d.current })),
    localProfiles: profileOrder.flatMap((id) => {
      const p = profiles[id];
      if (!p) return [];
      const link = sync.profiles[p.id];
      const owner = p.dataId ? profiles[p.dataId] : undefined;
      return [
        {
          id: p.id,
          name: p.name,
          accentHex: profileAccent(p),
          icon: p.icon,
          sharesDataWith: owner?.name ?? null,
          synced: link ? link.enabled : null,
        },
      ];
    }),
    passwordsError: sync.passwordsError ?? null,
    heldPasswords: Object.entries(sync.heldPasswords ?? {}).map(([profileId, count]) => ({
      profileId,
      profileName: profileOrder.length > 1 ? (profiles[profileId]?.name ?? null) : null,
      count,
    })),
    remoteProfiles: sync.remoteProfiles.map((p) => ({
      syncId: p.syncId,
      name: p.name,
      accentHex: profileAccent({ color: p.color }),
      icon: p.icon,
      sharesWith: p.sharesWith ?? null,
      waiting: !!p.waiting,
    })),
  };
}

let lastPublished: string | null = null;

function publishSyncState() {
  const topic = syncTopic();
  const json = JSON.stringify(topic);
  if (json === lastPublished) return;
  lastPublished = json;
  publishSettingsTopic("sync.state", topic);
}

type Native = NonNullable<typeof SyncNative>;

const withNative = <T>(use: (native: Native) => Promise<T>): Promise<T | null> => (SyncNative ? use(SyncNative).catch(() => null) : Promise.resolve(null));

export const syncHandlers: Record<string, SettingsHandler> = {
  "sync.state": () => syncTopic(),
  "sync.folderInfo": (path: string | null) => folderInfo(path).catch(() => null),
  "sync.chooseFolder": () => chooseSyncFolder().catch(() => null),
  "sync.inspectCreation": (folder: string) => withNative((n) => typeof n.inspectCreation === "function" ? n.inspectCreation(folder) : Promise.resolve(null)),
  "sync.turnOn": async (folder: string, inspectionID?: string) => {
    const result = await turnOnSync(folder, inspectionID);
    return "error" in result ? result.error : null;
  },
  "sync.enterRecoveryPhrase": (folder: string, text: string) => enterRecoveryPhrase(folder, text),
  "sync.stop": (deleteData: boolean) => stopSync({ deleteData }),
  "sync.syncNow": () => syncNow(),
  "sync.setTypeSynced": (type: DataType, on: boolean) => setTypeSynced(type, on),
  "sync.setProfileSynced": (profileId: string, on: boolean) => setProfileSynced(profileId, on),
  "sync.addRemoteProfile": (syncId: string) => void addRemoteProfile(syncId),
  "sync.resolveHeldPasswords": (profileId: string, restore: boolean) => resolveHeldPasswords(profileId, restore ? "restore" : "confirm"),
  "sync.recoveryWords": () => withNative((n) => n.recoveryWords()),
  "sync.phraseUnavailable": () => withNative((n) => n.phraseUnavailable()),
  "sync.qrCode": () => withNative((n) => n.qrCode()),
  "sync.recoveryKitPreview": (width: number) => withNative((n) => n.recoveryKitPreview(width)),
  "sync.saveRecoveryKit": (format: "pdf" | "text") => withNative((n) => n.saveRecoveryKit(format)),
  "sync.copyRecoveryKit": () => withNative((n) => n.copyRecoveryKit()),
  "sync.shareRecoveryKit": () => withNative((n) => n.shareRecoveryKit()),
  "sync.copyRecoveryPhrase": () => withNative((n) => n.copyRecoveryPhrase()),
  "sync.revealFolder": (path: string) => withNative((n) => n.revealFolder(path)),
};

export function publishSync(): void {
  publishSyncState();
  useSync.subscribe(publishSyncState);
  useBrowser.subscribe((s, prev) => {
    if (s.profiles !== prev.profiles || s.profileOrder !== prev.profileOrder) publishSyncState();
  });
}
