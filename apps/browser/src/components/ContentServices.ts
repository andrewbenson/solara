import { useEffect } from "react";
import { startChromeTabs } from "../lib/chromeTabs";
import { startMedia } from "./media/services";
import { startDeviceChoosers } from "./site/DeviceChooser";
import { startPeeks } from "./peek/actions";


export function useContentServices() {
  useEffect(startChromeTabs, []);
  useEffect(startMedia, []);
  useEffect(startDeviceChoosers, []);
  useEffect(startPeeks, []);
}
