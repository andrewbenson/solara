import { nativeWorkspaceCommand } from "@solara/settings";
import type { Tab } from "../../store/types";
import { internalPageOf, type InternalPageId } from "./internalUrls";

export { INTERNAL_PAGES, internalPageOf, internalQuery } from "./internalUrls";

export const tabDestination = (t: Pick<Tab, "url" | "navigation">) => t.navigation?.url ?? t.url;

export const isInternalTab = (t: Pick<Tab, "url" | "navigation">) => internalPageOf(tabDestination(t)) !== null;

export function openInternalPage(page: InternalPageId, windowId?: string | null, options: { query?: string; background?: boolean } = {}) {
  nativeWorkspaceCommand("openLibraryPage", JSON.stringify({ page, ...options }), windowId ?? null);
}
