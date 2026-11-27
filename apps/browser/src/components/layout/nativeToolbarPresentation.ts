import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { useSyncExternalStore } from "react";

type NativeToolbarPresentation = {
  scrolledDown(tabId: string): boolean;
  sidebarToggleVisible(windowId: string): boolean;
  addListener(event: "onToolbarLayoutChanged", listener: () => void): EventSubscription;
  addListener(event: "onToolbarScrollChanged", listener: (event: { tabId: string }) => void): EventSubscription;
};

const native = requireOptionalNativeModule<NativeToolbarPresentation>("SolaraAutoHide");

export const toolbarScrolledDown = (tabId: string) => native?.scrolledDown(tabId) ?? false;
export const onToolbarScrollChanged = (listener: (tabId: string) => void) =>
  native?.addListener("onToolbarScrollChanged", ({ tabId }) => listener(tabId));


const subscribeGeometry = (listener: () => void) => {
  const subscription = native?.addListener("onToolbarLayoutChanged", listener);
  return () => subscription?.remove();
};

export const useToolbarSidebarToggle = (windowId: string) =>
  useSyncExternalStore(subscribeGeometry, () => native?.sidebarToggleVisible(windowId) ?? true);
