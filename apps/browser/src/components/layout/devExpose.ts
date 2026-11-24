import * as permissions from "../site/permissions";
import * as developerButtons from "../site/DeveloperButtons";
import * as developerMode from "../site/developerMode";
import { usePages } from "./pageState";
import * as splitActions from "./splitActions";
import * as tabDrag from "./tabDrag";
import { devDocks, devPeeks, useDockMotion } from "./dockMotion";
import { useWidths } from "./measuredWidths";
import { nativeWindowAnchorFeed, useCardAnchors, useUrlAnchors } from "./windowLayout";

if (__DEV__) {
  (globalThis as { acLayout?: unknown }).acLayout = { pages: usePages, anchors: useUrlAnchors, cardAnchors: useCardAnchors, nativeAnchors: nativeWindowAnchorFeed, measuredWidths: useWidths, toasts: splitActions.useToasts, splitActions, tabDrag, permissions, peek: devPeeks, dock: devDocks, dockMotion: useDockMotion, developer: { ...developerMode, ...developerButtons } };
}
