import { useEffect } from "react";
import { startChromeTabs } from "../lib/chromeTabs";
import { startPermissionPrompts } from "./site/permissions";
import { startSelectionTools } from "./site/selection";
import { startMedia } from "./media/pip";
import { startPeeks } from "./peek/actions";


export function useContentServices() {
  useEffect(startPermissionPrompts, []);
  useEffect(startChromeTabs, []);
  useEffect(startMedia, []);
  useEffect(startSelectionTools, []);
  useEffect(startPeeks, []);
}
