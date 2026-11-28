import { requireOptionalNativeModule } from "expo-modules-core";

const native = requireOptionalNativeModule<{ cliIndicatorShown?(): boolean | null; hasDisplayTabShare?(): boolean; protectionReason?(tabId: string, pinned: boolean): string | null }>("SolaraMedia");

export function nativeCliIndicatorShown(): boolean | null {
  try {
    return native?.cliIndicatorShown?.() ?? null;
  } catch {
    return null;
  }
}

export function mediaProtectionReason(tabId: string, pinned: boolean): string | null {
  return native?.protectionReason?.(tabId, pinned) ?? null;
}

export function hasDisplayTabShare(): boolean {
  return native?.hasDisplayTabShare?.() ?? false;
}
