import { encodeCommand, nativeSnapshot, nativeStoreStatus } from "@solara/store";
import { nativeWrite } from "../store/nativeStore";
import { COMMAND_PRELUDES, WORKSPACE_COMMANDS } from "../store/nativeWorkspace";

export function installDevNative(ac: object) {
  if (!__DEV__) return;
  Object.defineProperty(ac, "native", {
    value: {
      state() {
        const status = nativeStoreStatus();
        if (!status.active || status.frozen) return null;
        try {
          const snapshot = nativeSnapshot();
          return snapshot?.data ?? null;
        } catch {
          return null;
        }
      },
      status: nativeStoreStatus,
      command(name: string, ...args: unknown[]) {
        if (!WORKSPACE_COMMANDS.has(name)) throw new Error(`Not a workspace command: ${name}`);
        COMMAND_PRELUDES.get(name)?.(...args);
        const response = nativeWrite(encodeCommand(name, args));
        if (!response || response.error) throw new Error(response?.error ?? "The native workspace is unavailable");
        return response.result;
      },
    },
  });
}
