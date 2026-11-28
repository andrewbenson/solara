import { useEffect } from "react";
import { startChromeTabs } from "../lib/chromeTabs";
import { startDeviceChoosers } from "./site/DeviceChooser";
import { startPeeks } from "./peek/actions";


export function useContentServices() {
  useEffect(startChromeTabs, []);
  useEffect(startDeviceChoosers, []);
  useEffect(startPeeks, []);
}
