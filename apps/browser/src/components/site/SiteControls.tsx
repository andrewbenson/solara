import { NativeSiteControls, useNativeSiteControlsShown } from "./NativeSiteControls";

export function SiteControls({ tabId, open, right, left, top }: { tabId: string; open: boolean; right?: number; left?: number; top: number }) {
  const nativeShown = useNativeSiteControlsShown(open);
  return nativeShown.shown ? <NativeSiteControls tabId={tabId} open={open} right={right} left={left} top={top} onClosed={nativeShown.onClosed} /> : null;
}
