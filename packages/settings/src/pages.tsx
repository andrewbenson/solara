import { requireNativeViewManager, requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { forwardRef, type ComponentType, type Ref } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativePageKind = "createProfile" | "calendarPreview" | "meetingAlert";
export type NativePageEvent = { kind: string } & Record<string, unknown>;

export type NativePageProps = ViewProps & {
  kind?: NativePageKind;
  state?: string;
  internalTabId?: string;
  onPageEvent?(e: NativeSyntheticEvent<NativePageEvent>): void;
};

export type NativePageHandle = { focusSearch(): Promise<void> };

export type MeetingAlertEvent = { windowId: string; kind: "dismiss" | "join" | "view"; all?: boolean };

export type NativeHistoryAction = { token: string; profileId: string; windowId: string } & (
  | { kind: "remove" | "deleteSelected"; urls: string[] }
  | { kind: "clearData"; range: string; history: boolean; siteData: boolean }
);

const native = requireOptionalNativeModule<{
  available(): boolean;
  showMeetingAlert(windowId: string, json: string, left: number, top: number): Promise<boolean>;
  hideMeetingAlert(windowId: string): Promise<void>;
  historyActionCurrent(token: string): Promise<boolean>;
  finishHistoryAction(token: string, action: "selection" | "clear" | "clearFailed"): Promise<void>;
  addListener(event: "onHistoryAction", listener: (e: NativeHistoryAction) => void): EventSubscription;
  addListener(event: "onMeetingAlertEvent", listener: (e: MeetingAlertEvent) => void): EventSubscription;
}>("SolaraPages");

export const onNativeHistoryAction = (listener: (e: NativeHistoryAction) => void) => native?.addListener("onHistoryAction", listener);
export const nativeHistoryActionCurrent = (token: string) => native?.historyActionCurrent(token) ?? Promise.resolve(false);
export const finishNativeHistoryAction = (token: string, action: "selection" | "clear" | "clearFailed") =>
  native?.finishHistoryAction(token, action) ?? Promise.resolve();

const meetingAlertFrame = typeof native?.showMeetingAlert === "function" ? native : null;

export const showNativeMeetingAlert = (windowId: string, json: string, left: number, top: number) =>
  meetingAlertFrame?.showMeetingAlert(windowId, json, left, top) ?? Promise.resolve(false);

export const hideNativeMeetingAlert = (windowId: string) => meetingAlertFrame?.hideMeetingAlert(windowId) ?? Promise.resolve();

export const onNativeMeetingAlert = (listener: (e: MeetingAlertEvent) => void) => meetingAlertFrame?.addListener("onMeetingAlertEvent", listener);

let availability: boolean | null = null;

export function nativePagesAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativePageProps & { ref?: Ref<NativePageHandle> }> | null = null;

export const NativePage = forwardRef<NativePageHandle, NativePageProps>(function NativePage(props, ref) {
  View ??= requireNativeViewManager<NativePageProps>("SolaraPages") as unknown as ComponentType<NativePageProps & { ref?: Ref<NativePageHandle> }>;
  return <View ref={ref} {...props} />;
});
