import { dragPreview } from "@solara/shell";
import { create } from "zustand";
import { lastPicture, startTabPictures } from "../../lib/tabPictures";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { splitOf, type SplitSide } from "../../store/splits";
import { openSplitPane } from "./splitActions";

export type DropTarget = { tabId: string; side: SplitSide };

type TabDrag = {
  tabId: string | null;
  tabIds: string[];
  windowId: string | null;
  x: number;
  y: number;
  lifted: boolean | null;
  onPage: boolean;
  target: DropTarget | null;
  outside: boolean;
  overWindow: string | null;
  overPoint: [number, number] | null;
  insert: { windowId: string; beforeId: string | null } | null;
  owned: boolean;
};

export const useTabDrag = create<TabDrag>()(() => ({
  tabId: null,
  tabIds: [],
  windowId: null,
  x: 0,
  y: 0,
  lifted: null,
  onPage: false,
  target: null,
  outside: false,
  overWindow: null,
  overPoint: null,
  insert: null,
  owned: false,
}));

if (__DEV__) (globalThis as { acTabDrag?: typeof useTabDrag }).acTabDrag = useTabDrag;

startTabPictures();

let dragSeq = 0;
let pointer: [number, number] = [-1, -1];

export function beginTabDrag(windowId: string, tabId: string | null, tabIds: string[], owned: boolean) {
  pointer = [-1, -1];
  ++dragSeq;
  useTabDrag.setState({ ...IDLE, tabId, tabIds, windowId, x: -1, y: -1, owned });
}

export function updateNativeTabDrag(
  x: number,
  y: number,
  outside: boolean,
  overWindow: string | null,
  overPoint: [number, number] | null,
  lifted: boolean | null = null,
  zoneBefore: string | null | false = false,
  zone: { onPage: boolean; target: DropTarget | null } | null = null,
) {
  const drag = useTabDrag.getState();
  if (!drag.tabIds.length || !drag.windowId) return;
  const insert = zoneBefore !== false && overWindow ? { windowId: overWindow, beforeId: zoneBefore } : null;
  pointer = [x, y];
  if (lifted === false && drag.lifted === false && !outside && !drag.outside) return;
  useTabDrag.setState({ x, y, lifted, outside, overWindow, overPoint, insert, ...zone });
}

export function captureDragPage(windowId: string) {
  const drag = dragSeq;
  const { tabId } = useTabDrag.getState();
  const s = useBrowser.getState();
  const w = s.windows[windowId];
  const active = w?.activeTabIds[w.profileId];
  const shown = tabId ?? active;
  const onScreen = !!shown && (shown === active || !!splitOf(s, active)?.tabIds.includes(shown));
  const live = (onScreen && webviews.get(shown)?.capturePicture(0.35).catch(() => null)) || Promise.resolve(null);
  void live.then(async (page) => {
    if (drag !== dragSeq || !useTabDrag.getState().tabIds.length) return;
    if (page) return dragPreview.page(page.data, page.frame);
    const tab = shown ? useBrowser.getState().tabs[shown] : undefined;
    if (!shown || (onScreen && !tab?.url)) return;
    const last = await lastPicture(shown);
    if (drag !== dragSeq || !useTabDrag.getState().tabIds.length) return;
    if (last) return dragPreview.page(last.data, last.frame);
    const now = useBrowser.getState().tabs[shown];
    if (now) dragPreview.placeholder(now.customTitle || now.title || now.url || "New Tab", now.favicon);
  });
}

export function setDropTarget(target: DropTarget | null) {
  if (useTabDrag.getState().owned) return;
  const current = useTabDrag.getState().target;
  if (current?.tabId === target?.tabId && current?.side === target?.side) return;
  useTabDrag.setState({ target });
}

let resolveTarget: ((x: number, y: number, current: DropTarget | null, outside: boolean) => DropTarget | null) | null = null;
export function setTargetResolver(resolver: typeof resolveTarget) {
  resolveTarget = resolver;
}

let resolvePage: ((x: number, y: number, outside: boolean) => boolean) | null = null;
export function setPageResolver(resolver: typeof resolvePage) {
  resolvePage = resolver;
}

export function setOnPage(onPage: boolean) {
  if (useTabDrag.getState().owned || useTabDrag.getState().onPage === onPage) return;
  useTabDrag.setState({ onPage });
}

const IDLE = {
  tabId: null,
  tabIds: [],
  windowId: null,
  lifted: null,
  onPage: false,
  target: null,
  outside: false,
  overWindow: null,
  overPoint: null,
  insert: null,
  owned: false,
} as const;

export function endNativeTabDrag(): { split: boolean; onPage: boolean; pointer: [number, number] } {
  const drag = useTabDrag.getState();
  const { tabId, outside, windowId } = drag;
  const [x, y] = pointer;
  const target = resolveTarget ? resolveTarget(x, y, drag.target, outside) : drag.target;
  const onPage = !outside && !!(drag.lifted ?? (resolvePage ? resolvePage(x, y, outside) : drag.onPage));
  useTabDrag.setState({ ...IDLE, tabIds: [] });
  dragSeq++;
  const split = !!(target && tabId && windowId && openSplitPane(windowId, { tabId, anchorTabId: target.tabId, side: target.side }));
  return { split, onPage, pointer: [x, y] };
}

export function cancelTabDrag() {
  useTabDrag.setState({ ...IDLE, tabIds: [] });
  dragSeq++;
}
