import { NativePage } from "@solara/settings";
import { useState } from "react";
import { StyleSheet } from "react-native";
import { create } from "zustand";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import type { ProfileColor } from "../../store/types";

export type CreateProfilePreset = { name?: string; shareWith?: string };

type Request = { windowId: string; preset: CreateProfilePreset; resolve: (id: string | null) => void };

const useRequest = create<{ request: Request | null }>(() => ({ request: null }));

export const useCreateProfileOpen = (windowId: string) => useRequest((r) => r.request?.windowId === windowId);

export function requestCreateProfile(windowId?: string, preset: CreateProfilePreset = {}): Promise<string | null> {
  return new Promise((resolve) => {
    const browser = useBrowser.getState();
    const target = windowId ?? browser.ui.focusedWindowId ?? browser.windowOrder[0];
    if (!target || !browser.windows[target]) return resolve(null);
    useRequest.getState().request?.resolve(null);
    useRequest.setState({ request: { windowId: target, preset, resolve } });
  });
}

export function CreateProfileHost() {
  const windowId = useWindowId();
  const request = useRequest((r) => (r.request?.windowId === windowId ? r.request : null));
  if (!request) return null;
  const done = (id: string | null) => {
    useRequest.setState({ request: null });
    request.resolve(id);
  };
  return <NativeCreateProfile windowId={windowId} preset={request.preset} onDone={done} />;
}

let nativeRequests = 0;

function NativeCreateProfile({ windowId, preset, onDone }: { windowId: string; preset: CreateProfilePreset; onDone: (id: string | null) => void }) {
  const theme = useTheme();
  const profiles = useBrowser((s) => s.profiles);
  const profileOrder = useBrowser((s) => s.profileOrder);
  const current = useBrowser((s) => (!s.windows[windowId]?.incognito ? s.windows[windowId]!.profileId : s.settings.defaultProfileId));
  const [key] = useState(() => `create:${++nativeRequests}`);
  const state = JSON.stringify({
    key,
    profiles: profileOrder.filter((id) => profiles[id]).map((id) => ({ id, name: profiles[id]!.name, color: profiles[id]!.color, dataId: profiles[id]!.dataId ?? null })),
    current,
    presetName: preset.name ?? null,
    presetShareWith: preset.shareWith ?? null,
    dark: !!theme.dark,
  });
  return (
    <NativePage
      kind="createProfile"
      state={state}
      style={StyleSheet.absoluteFill}
      onPageEvent={(e) => {
        const ev = e.nativeEvent;
        if (ev.kind === "create") {
          try {
            const id = useBrowser.getState().createProfile({ name: String(ev.name ?? ""), color: ev.color as ProfileColor, shareWith: (ev.shareWith as string | null) ?? null });
            onDone(id);
          } catch (error) {
            console.warn("[profiles] Creation refused", error);
            onDone(null);
          }
        } else if (ev.kind === "cancel") onDone(null);
      }}
    />
  );
}

export function profileNames(names: string[]): string {
  if (names.length <= 2) return names.join(" & ");
  return `${names.slice(0, 2).join(", ")}, & ${names.length - 2} more`;
}

