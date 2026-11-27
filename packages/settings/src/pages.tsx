import { requireNativeViewManager, requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { forwardRef, type ComponentType, type Ref } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativePageKind = "downloads" | "history" | "bookmarks" | "createProfile" | "calendarPreview" | "meetingAlert";
export type NativePageEvent = { kind: string } & Record<string, unknown>;

export type NativePageProps = ViewProps & {
  kind: NativePageKind;
  state: string;
  onPageEvent?(e: NativeSyntheticEvent<NativePageEvent>): void;
};

export type NativePageHandle = { focusSearch(): Promise<void> };

export type MeetingAlertEvent = { windowId: string; kind: "dismiss" | "join" | "view"; all?: boolean };

const native = requireOptionalNativeModule<{
  available(): boolean;
  showMeetingAlert(windowId: string, json: string, left: number, top: number): Promise<boolean>;
  hideMeetingAlert(windowId: string): Promise<void>;
  addListener(event: "onMeetingAlertEvent", listener: (e: MeetingAlertEvent) => void): EventSubscription;
}>("SolaraPages");

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
