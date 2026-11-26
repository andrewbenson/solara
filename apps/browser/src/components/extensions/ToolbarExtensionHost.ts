import { nativeExtensionCommand, nativeExtensionToolbar, onNativeExtensionToolbarChanged } from "@solara/settings";
import { terminateCastRoute, type CastRoute } from "@solara/solaracore";
import { showMenu } from "@solara/shell";
import { useEffect, useState } from "react";
import { useTheme } from "../../lib/theme";
import { toggleCastPicker, useCastRoutes } from "../media/cast";
import { dropToolbarAnchor, setToolbarAnchor } from "./bridge";
import type { Anchor } from "./store";

let nextHost = 0;

export const extensionsFitting = (room: number) => Math.max(1, Math.floor((room + 2) / 30));

export function useNativeToolbarExtensions(windowId: string, tabId: string, limit = Infinity) {
  const [host] = useState(() => String(++nextHost));
  useEffect(() => () => { void nativeExtensionCommand({ command: "releaseToolbar", id: host }); }, [host]);
  const theme = useTheme();
  const routes = useCastRoutes(windowId);
  const input = JSON.stringify({ host, windowId, tabId, limit: Number.isFinite(limit) ? limit : null, routes, accent: theme.accent });
  const [projection, setProjection] = useState<{ width: number; buttons: Record<string, unknown>[] }>({ width: 0, buttons: [] });
  useEffect(() => {
    let live = true;
    let revision = 0;
    const refresh = () => {
      const request = ++revision;
      void nativeExtensionToolbar(JSON.parse(input)).then((next) => { if (live && revision === request) setProjection(next); });
    };
    refresh();
    const subscription = onNativeExtensionToolbarChanged(refresh);
    return () => { live = false; subscription?.remove(); };
  }, [input]);
  const [anchors] = useState(() => new Map<string, Anchor>());
  useEffect(() => () => {
    for (const [slot, anchor] of anchors) dropToolbarAnchor(windowId, tabId, slot, anchor);
    anchors.clear();
  }, [windowId, tabId]);
  const onAnchors = (next: Record<string, [number, number, number, number]>) => {
    for (const [slot, anchor] of anchors) if (!next[slot]) { dropToolbarAnchor(windowId, tabId, slot, anchor); anchors.delete(slot); }
    for (const [slot, [x, y, width, height]] of Object.entries(next)) {
      const anchor = { x, y, width, height };
      anchors.set(slot, anchor);
      setToolbarAnchor(windowId, tabId, slot, anchor);
    }
  };
  const onClick = (id: string, kind: "press" | "menu") => {
    if (id === "ext-cast") {
      if (kind === "menu") return void castMenu(windowId, routes);
      return void toggleCastPicker(windowId, tabId);
    }
    const slot = id === "ext-overflow" ? "*" : id.slice(4);
    return nativeExtensionCommand({ command: id === "ext-overflow" ? "overflow" : kind === "menu" ? "menu" : "openExtension", windowId, tabId, id: slot, anchor: anchors.get(slot) ?? { x: 0, y: 0, width: 28, height: 28 } });
  };
  return { ...projection, onAnchors, onClick };
}

async function castMenu(windowId: string, routes: CastRoute[]) {
  const choice = await showMenu([
    ...routes.map((r) => ({ id: `stop:${r.id}`, title: `Stop Casting to ${r.sink}`, symbol: "stop.circle" })),
    { separator: true as const },
    { id: "open", title: "Cast…", symbol: "tv.and.mediabox" },
  ]);
  if (choice === "open") void toggleCastPicker(windowId);
  else if (choice?.startsWith("stop:")) void terminateCastRoute(choice.slice(5));
}
