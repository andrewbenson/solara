import { SolaraHostedView } from "@solara/settings";
import { useShallow } from "zustand/react/shallow";
import { layout, useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import type { Tab } from "../store/types";
import type { ToolbarGeometry } from "./layout/geometry";
import type { PageState } from "./layout/pageState";
import { NativeToolbar } from "./NativeToolbar";

type ToolbarTab = Pick<Tab, "id" | "url" | "title" | "windowId" | "zoom">;
const toolbarTab = (t: Tab | undefined): ToolbarTab | undefined =>
  t && { id: t.id, url: t.url, title: isWebUrl(t.url) ? "" : t.title, windowId: t.windowId, zoom: t.zoom };
const isWebUrl = (url: string) => /^https?:/i.test(url);
export const useToolbarTab = (tabId: string | undefined) => useBrowser(useShallow((s) => toolbarTab(tabId ? s.tabs[tabId] : undefined)));

export const URL_FIELD = { top: 21.2 - 15, height: 30 } as const;
export const GLYPH = 13;
export const urlFieldRight = (inSplit: boolean, extensionsWidth: number) => (inSplit ? 12 + 2 * 28 : 12) + extensionsWidth;
const LOCK = { left: 7, width: 18, gap: 3 } as const;
const NATIVE_BADGE = { left: 1, size: 28, gap: 5.5 } as const;
export const urlTextLeft = (insecure: boolean, native = false) =>
  !insecure ? 8 : native ? NATIVE_BADGE.left + NATIVE_BADGE.size + NATIVE_BADGE.gap : LOCK.left + LOCK.width + LOCK.gap;
export const insecureLevel = (p: PageState) => {
  const level = p.security?.chromium;
  return level === "warning" || level === "dangerous" ? level : null;
};

type ToolbarProps = {
  tabId: string;
  geometry: ToolbarGeometry;
  windowId: string;
  inSplit: boolean;
  focused: boolean;
  bare?: boolean;
  windowToolbar?: boolean;
};

export function Toolbar(props: ToolbarProps) {
  return <NativeToolbar {...props} />;
}

export function ToolbarBackdrop({ tabId, windowId }: { tabId: string; windowId: string }) {
  const { dark } = useTheme();
  return (
    <SolaraHostedView
      kind="toolbarBackdrop"
      windowId={windowId}
      pointerEvents="none"
      state={JSON.stringify({ tabId, dark })}
      style={{ height: layout.toolbarHeight }}
    />
  );
}
