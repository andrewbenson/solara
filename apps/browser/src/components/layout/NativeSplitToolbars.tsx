import { useEffect, useRef } from "react";
import { useNativeToolbarModel } from "../NativeToolbar";
import type { ToolbarGeometry } from "./geometry";
import { dropSplitToolbar, feedSplitToolbar, type SplitToolbarHandlers } from "./nativeSplitChrome";

const noHandle = () => null;

export function SplitToolbarFeed({ tabId, windowId, geometry, focused, inSplit = true }: { tabId: string; windowId: string; geometry: ToolbarGeometry; focused: boolean; inSplit?: boolean }) {
  const { json, onClick, onAnchors } = useNativeToolbarModel({ tabId, geometry, windowId, inSplit, windowToolbar: !inSplit, focused }, noHandle);
  const handlers = useRef<SplitToolbarHandlers>({ onClick, onAnchors });
  handlers.current = { onClick, onAnchors };
  useEffect(() => feedSplitToolbar(windowId, tabId, json, handlers), [windowId, tabId, json]);
  useEffect(() => () => dropSplitToolbar(windowId, tabId, handlers), [windowId, tabId]);
  return null;
}
