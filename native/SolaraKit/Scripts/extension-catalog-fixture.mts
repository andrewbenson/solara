export function extensionCatalogFixture(native: any, rows: (profile: string) => any[], update: (profile: string, list: any[]) => void) {
  const loading = new Map<string, Promise<any[]>>();
  const trailing = new Map<string, Promise<any[]>>();
  const refreshExtensions = (profile: string): Promise<any[]> => {
    const running = loading.get(profile);
    if (running) return running;
    const job = native.list(profile).then((result: any) => {
      const list = result.extensions.sort((a: any, b: any) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
      update(profile, list);
      return list;
    }).catch((error: any) => {
      console.warn("[extensions] list failed", error);
      return rows(profile);
    }).finally(() => loading.delete(profile));
    loading.set(profile, job);
    return job;
  };
  const refreshExtensionsAfterChange = (profile: string): Promise<any[]> => {
    const running = loading.get(profile);
    if (!running) return refreshExtensions(profile);
    let next = trailing.get(profile);
    if (!next) {
      next = running.then(() => { trailing.delete(profile); return refreshExtensions(profile); });
      trailing.set(profile, next);
    }
    return next;
  };
  const setEnabled = async (profile: string, id: string, enabled: boolean) => {
    update(profile, rows(profile).map((row) => row.id === id ? { ...row, enabled, state: enabled ? "ENABLED" : "DISABLED" } : row));
    try { await native.setEnabled(id, profile, enabled); }
    finally { await refreshExtensions(profile); }
  };
  return { refreshExtensions, refreshExtensionsAfterChange, setEnabled };
}
