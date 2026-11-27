import { requireOptionalNativeModule } from "expo-modules-core";

type ProfilePagerModule = {
  active(windowId: string): boolean;
  switchTo(windowId: string, profileId: string): Promise<void>;
  step(windowId: string, delta: number): Promise<void>;
  describe(windowId: string): Promise<string>;
};

const native = requireOptionalNativeModule<ProfilePagerModule>("SolaraProfilePager");

export function profilePagerNative(windowId: string): boolean {
  try {
    return native?.active(windowId) ?? false;
  } catch {
    return false;
  }
}

export function switchProfilePager(windowId: string, profileId: string) {
  return native?.switchTo(windowId, profileId);
}

export function stepProfilePager(windowId: string, delta: number) {
  return native?.step(windowId, delta);
}

export async function describeProfilePager(windowId: string) {
  return native ? JSON.parse(await native.describe(windowId)) : null;
}
