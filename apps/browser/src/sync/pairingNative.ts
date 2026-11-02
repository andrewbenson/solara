import { pairingNativeTransport, SyncNative } from "@solara/sync";
import { joinFromPairing, resumePairingInitialization, startSync } from "./engine";

let started = false;

export function startPairingSync() {
  if (started) return;
  started = true;
  const host = pairingNativeTransport();
  if (!host || typeof SyncNative?.invalidatePairing !== "function" || typeof SyncNative?.addListener !== "function") {
    startSync();
    return;
  }
  let querying = false;
  let dirty = false;
  let admittedHandle: string | null = null;
  let pendingHandle: string | null = null;
  let retry: ReturnType<typeof setTimeout> | undefined;
  const scheduleRetry = () => {
    if (retry !== undefined || pendingHandle === null) return;
    retry = setTimeout(() => { retry = undefined; void query(); }, 1000);
  };
  const query = async () => {
    if (querying) { dirty = true; return; }
    querying = true;
    clearTimeout(retry);
    retry = undefined;
    try {
      do {
        dirty = false;
        const request = await host.installationRequest();
        pendingHandle = request?.handle ?? null;
        if (request && request.handle !== admittedHandle) {
          const resumed = await resumePairingInitialization(host);
          const result = resumed ? { ok: true } : await joinFromPairing(request, host);
          if ("ok" in result) {
            admittedHandle = request.handle;
            pendingHandle = null;
            clearTimeout(retry);
            retry = undefined;
          }
          else scheduleRetry();
        } else if (request?.handle === admittedHandle) {
          pendingHandle = null;
        }
      } while (dirty);
    } catch { scheduleRetry(); } finally {
      querying = false;
    }
  };
  SyncNative.addListener("pairingInstallationReady", () => { void query(); });
  startSync(host);
  void query();
}
