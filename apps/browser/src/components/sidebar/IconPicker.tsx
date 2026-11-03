import { publishSettingsTopic } from "@solara/settings";
import { useEffect } from "react";
import { hex, useTheme } from "../../lib/theme";
import { useLive } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { setIcon } from "./actions";
import { setSidebarUi, useSidebarUi } from "./state";
import { NO_GROUP_ICON_INK } from "./TabIcon";
import { useSidebarTokens } from "./tokens";

const NATIVE_TOPIC = "sidebar.iconPicker";
const nativePickers: Record<string, object> = {};

function publishNative(windowId: string, state: object | null) {
  if (state) nativePickers[windowId] = state;
  else if (nativePickers[windowId]) delete nativePickers[windowId];
  else return;
  publishSettingsTopic(NATIVE_TOPIC, { windows: nativePickers });
}

addNativeSettingsHandlers({
  [NATIVE_TOPIC]: (windowId: string, id: string, event: string, extra?: { icon?: string | null }) => {
    const picker = useSidebarUi.getState().iconPicker;
    if (!picker || picker.windowId !== windowId || picker.id !== id) return;
    if (event === "choose") setIcon(picker, extra?.icon ?? null);
    if (event === "choose" || event === "close") setSidebarUi({ iconPicker: null });
  },
});

export function IconPicker({ windowId, sidebarWidth }: { windowId: string; sidebarWidth: number }) {
  const picker = useSidebarUi((u) => (u.iconPicker?.windowId === windowId ? u.iconPicker : null));
  return <NativeIconPicker windowId={windowId} picker={picker} sidebarWidth={sidebarWidth} />;
}

type Picker = NonNullable<ReturnType<typeof useSidebarUi.getState>["iconPicker"]>;

function useCurrentIcon(picker: Picker | null) {
  const liveIcon = useLive((s) => (picker?.kind === "live" ? s.folders[picker.id.split("|")[1] ?? ""]?.icon : null));
  return useBrowser((s) => (!picker ? null : picker.kind === "tab" ? s.tabs[picker.id]?.customIcon : picker.kind === "live" ? liveIcon : s.groups[picker.id]?.icon) ?? null);
}

function NativeIconPicker({ windowId, picker, sidebarWidth }: { windowId: string; picker: Picker | null; sidebarWidth: number }) {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  const current = useCurrentIcon(picker);
  const state = picker
    ? {
        id: picker.id,
        kind: picker.kind,
        current,
        anchor: picker.anchor ? [picker.anchor.x, picker.anchor.y, picker.anchor.width, picker.anchor.height] : null,
        sidebarWidth,
        dark: theme.dark,
        shadowOpacity: theme.panelShadowOpacity,
        theme: {
          panel: hex(theme.panel),
          panelBorder: hex(theme.panelBorder),
          urlPill: theme.urlPill,
          textPrimary: theme.textPrimary,
          textSecondary: theme.textSecondary,
          textTertiary: theme.textTertiary,
          placeholder: theme.placeholder,
          icon: theme.icon,
          pickerCellHover: tokens.pickerCellHover,
          noGroupIconInk: theme.dark ? NO_GROUP_ICON_INK.dark : NO_GROUP_ICON_INK.light,
        },
      }
    : null;
  const key = state && JSON.stringify(state);
  useEffect(() => publishNative(windowId, state), [windowId, key]);
  useEffect(() => () => publishNative(windowId, null), [windowId]);
  return null;
}
