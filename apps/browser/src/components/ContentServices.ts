import { useEffect } from "react";
import { startChromeTabs } from "../lib/chromeTabs";
import { startPermissionPrompts } from "./site/permissions";
import { startMedia } from "./media/services";
import { startPeeks } from "./peek/actions";


export function useContentServices() {
  useEffect(startPermissionPrompts, []);
  useEffect(startChromeTabs, []);
  useEffect(startMedia, []);
  useEffect(startPeeks, []);
}
