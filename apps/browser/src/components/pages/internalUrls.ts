import { appUrlRoute, type AppPageHost } from "@solara/core";

export type InternalPageId = AppPageHost;

export function internalPageOf(url: string | null | undefined): InternalPageId | null {
  const route = url ? appUrlRoute(url) : null;
  return route?.kind === "page" ? route.page : null;
}
