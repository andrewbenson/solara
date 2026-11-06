import { permissionWarnings } from "@solara/solaracore";
import { focusPageIfUnclaimed, onHostedEvent, setWindowSheet, type WindowSheetState } from "@solara/settings";
import { useEffect, useMemo, useRef } from "react";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { shownPageId } from "../../store/peek";
import { useWindowId } from "../../store/hooks";
import { useFormColors } from "../settings/controls";
import {
  cancelInstall,
  confirmInstall,
  extensionProfile,
  setPinned,
  useExtensions,
  useWindowExtensions,
  type InstallRequest,
} from "./state";

let nextInstallKey = 0;
const installKeys = new WeakMap<InstallRequest, string>();
const sheetKeys = new Map<string, string>();
let refocusing = false;

function installKey(request: InstallRequest): string {
  if (request.prompt?.requestId != null) return request.prompt.requestId;
  let key = installKeys.get(request);
  if (!key) {
    key = `install:${++nextInstallKey}`;
    installKeys.set(request, key);
  }
  return key;
}

function refocusActivePageOnSheetClose() {
  if (refocusing) return;
  refocusing = true;
  onHostedEvent("extensionSheet", null, (name, payload, windowId) => {
    if (name !== "closed" || payload.key !== sheetKeys.get(windowId)) return;
    sheetKeys.delete(windowId);
    const tabId = shownPageId(useBrowser.getState(), windowId);
    if (tabId) void focusPageIfUnclaimed(windowId, tabId);
  });
}

export function ExtensionOverlays() {
  const windowId = useWindowId();
  const install = useExtensions((e) => (e.install?.windowId === windowId ? e.install : null));
  const pin = useExtensions((e) => e.pinDialog?.windowId === windowId);
  const profile = useBrowser((s) => extensionProfile(s, windowId));
  const list = useWindowExtensions(windowId);
  const theme = useTheme();
  const colors = useFormColors();
  const key = install ? installKey(install) : pin ? "pins" : null;
  const live = useRef({ key, install, pin, profile });
  live.current = { key, install, pin, profile };
  refocusActivePageOnSheetClose();

  useEffect(
    () => onHostedEvent("extensionSheet", windowId, (name, payload) => {
      const { key, install, pin, profile } = live.current;
      if (key === null || payload.key !== key) return;
      if (install) {
        if (name === "confirm" || name === "submit") {
          if (install.status === "error") cancelInstall();
          else void confirmInstall();
        } else if ((name === "cancel" || name === "dismiss") && install.status !== "installing") cancelInstall();
      } else if (pin) {
        if (name === "toggle") void setPinned(profile, String(payload.id), !!payload.pinned);
        else if (name === "done" || name === "dismiss" || name === "submit") useExtensions.setState({ pinDialog: null });
      }
    }),
    [windowId],
  );
  const state = useMemo<WindowSheetState | null>(() => {
    if (key === null) return null;
    const style = { dark: !!theme.dark, panel: theme.panel, panelBorder: theme.panelBorder, panelShadowOpacity: theme.panelShadowOpacity };
    const text = { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTertiary: theme.textTertiary };
    if (install) {
      const pkg = install.pkg;
      const name = pkg?.name ?? "Extension";
      const kind = install.prompt?.type;
      const title = kind === "re-enable" ? `Turn “${name}” back on?` : kind === "permissions" ? `“${name}” needs new permissions` : `Add “${name}”?`;
      const action = kind === "re-enable" ? "Turn On" : kind === "permissions" ? "Allow" : "Add Extension";
      return {
        kind: "install",
        key,
        title,
        busy: install.status === "installing",
        style,
        install: {
          status: install.status,
          title,
          error: install.error ?? null,
          icon: pkg?.icon ?? null,
          warnings: install.prompt ? install.prompt.permissions : pkg ? permissionWarnings(pkg) : [],
          loadedFrom: install.source === "unpacked" ? (pkg?.path ?? "") : null,
          action,
          dark: !!theme.dark,
          theme: text,
          goButton: theme.goButton,
          goButtonText: theme.goButtonText,
        },
      };
    }
    return {
      kind: "pins",
      key,
      title: "Pin Extensions",
      busy: false,
      style,
      pins: {
        extensions: list.map((ext) => ({ id: ext.id, name: ext.name, icon: ext.actionIcon || ext.icon || null, pinned: !!ext.pinned })),
        dark: !!theme.dark,
        theme: { ...text, accent: colors.accent },
        control: colors.control,
        controlBorder: colors.controlBorder,
        goButton: theme.goButton,
        goButtonText: theme.goButtonText,
      },
    };
  }, [key, install, list, theme, colors.accent, colors.control, colors.controlBorder]);
  useEffect(() => {
    if (state) sheetKeys.set(windowId, state.key);
    void setWindowSheet(windowId, state);
  }, [windowId, state]);
  useEffect(() => () => { void setWindowSheet(windowId, null); }, [windowId]);
  return null;
}
