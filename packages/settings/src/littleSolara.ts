import { requireOptionalNativeModule } from "expo-modules-core";

type LittleSolaraModule = {
  littleActive(windowId: string): boolean;
  describeLittle(windowId: string): Promise<string>;
  paneSwipe?(windowId: string, tabId: string, json: string): Promise<void>;
};

const native = requireOptionalNativeModule<LittleSolaraModule>("SolaraMedia");

export function littleSolaraShellActive(windowId: string): boolean {
  try {
    return native?.littleActive?.(windowId) ?? false;
  } catch {
    return false;
  }
}

export async function describeLittleSolaraShell(windowId: string): Promise<Record<string, unknown> | null> {
  return native?.describeLittle ? (JSON.parse(await native.describeLittle(windowId)) as Record<string, unknown> | null) : null;
}

export function sendPaneSwipe(windowId: string, tabId: string, message: object) {
  void native?.paneSwipe?.(windowId, tabId, JSON.stringify(message));
}
