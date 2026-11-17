import { requireNativeViewManager, requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { forwardRef, type ComponentType, type Ref } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NewTabDisposition = "current" | "newTab" | "backgroundTab" | "newWindow";
export type NewTabJourneyMark = "committed" | "focused" | "keystroke" | "suggestions" | "navigate" | "queryInvalidated";
export type NewTabMenuChoice = "cut" | "copy" | "paste" | "selectAll" | "pasteAndGo" | "copyURL";
export type NativeSuggestion = { kind: string } & Record<string, unknown>;

type Event<T> = NativeSyntheticEvent<T & { nativeActions?: boolean }>;

export type NativeNewTabProps = ViewProps & {
  windowId: string;
  tabId: string;
  profileId: string;
  incognito: boolean;
  onboarding: boolean;
  playIntro: boolean;
  panelOpen: boolean;
  under: number;
  dark: boolean;
  theme: Record<string, string>;
  marks: { sun: string; back: string; front: string };
  driven?: boolean;
  offline?: boolean;
  onDriverState?(e: Event<{ json: string }>): void;
  onOpen?(e: Event<{ url: string; disposition: NewTabDisposition }>): void;
  onSwitch?(e: Event<{ tabId: string; url: string; disposition: NewTabDisposition }>): void;
  onAction?(e: Event<{ id: string }>): void;
  onExtension?(e: Event<{ suggestion: NativeSuggestion }>): void;
  onRemoveHistory?(e: Event<{ url: string }>): void;
  onChosen?(e: Event<{ suggestion: NativeSuggestion | null }>): void;
  onOpenChip?(e: Event<Record<string, never>>): void;
  onDictate?(e: Event<Record<string, never>>): void;
  onContextMenu?(e: Event<{ hasSelection: boolean; hasValue: boolean }>): void;
  onJourney?(e: Event<{ mark: NewTabJourneyMark; tabId?: string; query?: string; generation?: string; at?: number }>): void;
  onLatency?(e: Event<{ ms: number; query?: string; generation?: string }>): void;
  onBarLayout?(e: Event<{ height: number; headingHeight: number }>): void;
};

export type NativeNewTabHandle = {
  focus(): Promise<void>;
  applyMenu(choice: NewTabMenuChoice): Promise<void>;
  type(text: string): Promise<void>;
  clear(): Promise<void>;
  key(key: string, mods?: { metaKey?: boolean; altKey?: boolean; shiftKey?: boolean; ctrlKey?: boolean }): Promise<void>;
  select(start: number, end: number): Promise<void>;
  submit(): Promise<void>;
  driverState(): Promise<string>;
  measure(): Promise<{ x: number; y: number; width: number; height: number }>;
};

export type NewTabSourceStatus = { mode: "native-store" | "js-feed"; ready: boolean; epoch: number };

type NewTabModule = {
  sourceStatus(): Promise<NewTabSourceStatus>;
  addListener(event: "onSourceStatus", listener: (status: NewTabSourceStatus) => void): EventSubscription;
  available(): boolean;
  setIdleTabs(json: string, epoch: number, revision: number): Promise<void>;
  setTabs(profileId: string, json: string, epoch: number): Promise<void>;
  setEngineProfile(profileId: string, engineProfile: string, bookmarkEngineProfile: string, epoch: number): Promise<void>;
  setBookmarkIcons(profileId: string, engineProfile: string, json: string): Promise<void>;
  setActions(windowId: string, json: string): Promise<void>;
  setExtensions(windowId: string, json: string): Promise<void>;
  forgetWindow(windowId: string): Promise<void>;
};

const native = requireOptionalNativeModule<NewTabModule>("SolaraNewTab");

let availability: boolean | null = null;

export function nativeNewTabAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativeNewTabProps & { ref?: Ref<NativeNewTabHandle> }> | null = null;

export const NativeNewTab = forwardRef<NativeNewTabHandle, NativeNewTabProps>(function NativeNewTab(props, ref) {
  View ??= requireNativeViewManager<NativeNewTabProps>("SolaraNewTab") as unknown as ComponentType<NativeNewTabProps & { ref?: Ref<NativeNewTabHandle> }>;
  return <View ref={ref} {...props} />;
});

const ignore = () => {};

export const newTabSources = {
  sourceStatus: (): Promise<NewTabSourceStatus> => native?.sourceStatus() ?? Promise.resolve({ mode: "js-feed", ready: true, epoch: 0 }),
  onSourceStatus: (listener: (status: NewTabSourceStatus) => void): (() => void) => {
    let active = true;
    let epoch = -1;
    const receive = (status: NewTabSourceStatus) => {
      if (!active || status.epoch <= epoch) return;
      epoch = status.epoch;
      listener(status);
    };
    const subscription = native?.addListener("onSourceStatus", receive);
    void native?.sourceStatus().then(receive).catch(ignore);
    return () => {
      active = false;
      subscription?.remove();
    };
  },
  setIdleTabs: (snapshot: unknown, epoch: number, revision: number) => native?.setIdleTabs(JSON.stringify(snapshot), epoch, revision).catch(ignore),
  setTabs: (profileId: string, rows: unknown[], epoch: number) => native?.setTabs(profileId, JSON.stringify(rows), epoch).catch(ignore),
  setEngineProfile: (profileId: string, engineProfile: string, bookmarkEngineProfile: string, epoch: number) => native?.setEngineProfile(profileId, engineProfile, bookmarkEngineProfile, epoch).catch(ignore),
  setBookmarkIcons: (profileId: string, engineProfile: string, icons: Record<string, string>) => native?.setBookmarkIcons(profileId, engineProfile, JSON.stringify(icons)).catch(ignore),
  setActions: (windowId: string, rows: unknown[]) => native?.setActions(windowId, JSON.stringify(rows)).catch(ignore),
  setExtensions: (windowId: string, rows: unknown[]) => native?.setExtensions(windowId, JSON.stringify(rows)).catch(ignore),
  forgetWindow: (windowId: string) => native?.forgetWindow(windowId).catch(ignore),
};
